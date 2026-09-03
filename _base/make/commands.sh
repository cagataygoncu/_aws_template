#!/usr/bin/env bash
#
# commands.sh - every operation on this project, as a named function.
#
# Run directly, or through the Makefile which passes its arguments straight
# through. Running directly is the way to debug: each function is standalone,
# takes its arguments positionally, and holds no shared state. Either way it
# runs from the project root, which is where its relative paths resolve.
#
#   ./make/commands.sh deploy-cicd lambda
#   ./make/commands.sh help
#
# Everything a command needs about a deployment target - the deployment
# template, the Dockerfile, the base image - is read from that target's
# targets/<target>/cicd_parameters.json, so there is one source of truth.

set -euo pipefail

# ---------------------------------------------------------------------------
# configuration
#
# Override any of these per invocation:
#
#   PROJECT_NAME=lambda-test-1 ./make/commands.sh deploy-cicd lambda
#   AWS_PROFILE=gig-prod ./make/commands.sh outputs
# ---------------------------------------------------------------------------

# No defaults. Both used to fall back - PROJECT_NAME to the directory basename,
# TARGET to service/task - and both are values that select WHICH thing every
# other command acts on. A directory basename in particular is a trap: a repo
# whose folder is named after an older deployment would silently target that
# deployment's stack whenever commands.sh ran without the Makefile exporting
# these.
#
# The Makefile sets and exports both, so this only fires when commands.sh is
# run directly, which is exactly when a wrong guess would be invisible.
die_early() {
    echo "$1" >&2
    exit 1
}

PROJECT_NAME="${PROJECT_NAME:-}"
TARGET="${TARGET:-}"
[[ -n "$PROJECT_NAME" ]] \
    || die_early "ERROR: PROJECT_NAME is not set. Run through the Makefile, or: PROJECT_NAME=<name> ./make/commands.sh ..."
[[ -n "$TARGET" ]] \
    || die_early "ERROR: TARGET is not set (lambda, service/task, service/server). Run through the Makefile, or: TARGET=<target> ./make/commands.sh ..."

# CloudFormation stack names, and so the ProjectName parameter the pipeline
# names its stack after, allow no underscores - but project directories here
# are snake_case. Every AWS resource is named from this, not PROJECT_NAME.
STACK_NAME="${PROJECT_NAME//_/-}"

AWS_PROFILE="${AWS_PROFILE:-gig-nonprod}"
AWS_REGION="${AWS_REGION:-ap-southeast-2}"
AWS_DEFAULT_REGION="${AWS_REGION}"
export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION

CICD_STACK_NAME="${STACK_NAME}-cicd"
CICD_FILE_NAME="targets/common/cicd.yaml"

# Remote host for `upload`, an entry in ~/.ssh/config. No default: naming the
# wrong box is worse than being asked.
REMOTE_HOST="${REMOTE_HOST:-}"
# No default either: a directory you cannot see in the command is one you
# cannot recall later. Relative paths resolve against the remote home.
REMOTE_DIR="${REMOTE_DIR:-}"

# Bucket the deployment templates pull their nested stacks from, by version.
TEMPLATE_BUCKET="${TEMPLATE_BUCKET:-gig-cfn-templates}"

# Where the AWS config lives ON THE HOST. `docker run -v` paths are resolved by
# the daemon, so inside a devcontainer $HOME/.aws would name a path in the
# container, not the one the daemon can see. The devcontainer sets this to the
# host's home; on the host the default is already right.
AWS_CONFIG_HOST_DIR="${AWS_CONFIG_HOST_DIR:-$HOME/.aws}"

# The ssh config host alias that fronts CodeCommit for this account. See
# ~/.ssh/config; the CodeCommit remote is ssh://<host>/v1/repos/<repo>.
CODECOMMIT_SSH_HOST="${CODECOMMIT_SSH_HOST:-aws-${AWS_PROFILE}}"

CAPABILITIES=(CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND)

# Local container port per target. The container always listens on 8080; the
# lambda runtime emulator is mapped to 9000 to keep both runnable at once.
LOCAL_PORT_LAMBDA=9000
LOCAL_PORT_SERVICE=8080

# The port the app listens on inside the container. Per language - node serves
# 3000, a release 4000, uvicorn 5040 - so the project's Makefile sets it, and it
# matches ContainerPort in the deployment template. No fallback: 8080 used to
# stand in, which silently published the wrong port for every project that does
# not use it. The lambda runtime emulator always listens on 8080, whatever the
# language, and that one is a fact rather than a choice.
CONTAINER_PORT="${CONTAINER_PORT:-}"
[[ -n "$CONTAINER_PORT" ]] \
    || die_early "ERROR: CONTAINER_PORT is not set. Run through the Makefile, or: CONTAINER_PORT=<port> ./make/commands.sh ..."
LAMBDA_RUNTIME_PORT=8080

CONTAINER_NAME="${STACK_NAME}-local"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Print a message to stderr and exit non-zero.
#
#   die "ERROR: no such target: service/tsak"
#
die() {
    echo "$1" >&2
    exit 1
}

# Exit with a usage line unless enough arguments were supplied.
# Call it as the first line of a command function, passing $# through.
#
#   require_args 2 $# "run <entrypoint> <cmd> [target]"
#
require_args() {
    local expected=$1 actual=$2 usage=$3
    (( actual >= expected )) || die "usage: ./make/commands.sh ${usage}"
}

# Exit unless the given path is an existing regular file.
#
#   require_file targets/lambda/deployment.yaml
#
require_file() {
    local path=$1
    [[ -f "$path" ]] || die "ERROR: no such file: ${path}"
}

# Exit unless an executable is on PATH.
#
#   require_command jq
#   require_command docker
#
require_command() {
    local name=$1
    command -v "$name" > /dev/null 2>&1 || die "ERROR: ${name} is not installed"
}

# Ask before doing something irreversible. Names the profile, because the
# stack name alone does not say which account it is in.
#
#   confirm "delete stack ${stack}"
#
confirm() {
    local message=$1
    local reply
    read -r -p "${message} in ${AWS_PROFILE}? (y/n) " reply
    [[ $reply == [Yy] ]] || die "aborted"
}

# Print the parameters file of a deployment target, after checking it exists.
# A target is the path under targets/ that holds a cicd_parameters.json:
# lambda, service/task, service/server.
#
#   parameters_file lambda            -> targets/lambda/cicd_parameters.json
#   parameters_file service/server    -> targets/service/server/cicd_parameters.json
#
parameters_file() {
    local target=$1
    local path="targets/${target}/cicd_parameters.json"

    if [[ ! -f "$path" ]]; then
        echo "ERROR: unknown target '${target}'" >&2
        echo "" >&2
        echo "available targets:" >&2
        targets >&2
        exit 1
    fi
    echo "$path"
}

# Print one CloudFormation parameter value out of a target's parameters file.
#
#   parameter_value lambda DeploymentCfnFilename   -> targets/lambda/deployment.yaml
#   parameter_value lambda DockerFilename          -> targets/lambda/Dockerfile
#   parameter_value lambda BaseImageURI            -> public.ecr.aws/lambda/python:3.12
#
parameter_value() {
    local target=$1 key=$2 path
    require_command jq

    # Assigned first, not inlined: parameters_file exits on an unknown target,
    # and that exit has to fail this function rather than a subshell of it.
    path=$(parameters_file "$target") || exit 1

    jq -r --arg key "$key" \
        '.[] | select(.ParameterKey == $key) | .ParameterValue' \
        "$path"
}

# Print the local port a target's container is published on.
#
#   local_port lambda          -> 9000
#   local_port service/task    -> 8080
#
local_port() {
    local target=$1
    [[ "$target" == lambda ]] && echo "$LOCAL_PORT_LAMBDA" || echo "$LOCAL_PORT_SERVICE"
}

# Print the port inside the container that the published port maps to.
#
#   container_port lambda          -> 8080  (the runtime emulator)
#   container_port service/task    -> $CONTAINER_PORT
#
container_port() {
    local target=$1
    [[ "$target" == lambda ]] && echo "$LAMBDA_RUNTIME_PORT" || echo "$CONTAINER_PORT"
}

# True when a stack exists in this account and region.
#
#   stack_exists my_service && echo yes
#
stack_exists() {
    local stack=$1
    aws cloudformation describe-stacks --stack-name "$stack" > /dev/null 2>&1
}

# Block until a stack finishes an operation. On failure, print the failed
# events before exiting, so the reason is visible without a second command.
# The operation is the middle word of the aws waiter name.
#
#   wait_for_stack my_service-cicd create
#   wait_for_stack my_service delete
#
wait_for_stack() {
    local stack=$1 operation=$2

    echo "waiting for ${stack} ..."
    if ! aws cloudformation wait "stack-${operation}-complete" --stack-name "$stack"; then
        events "$stack"
        die "ERROR: ${stack} did not reach ${operation}-complete"
    fi
    echo "${stack}: ${operation} complete"
}

# ---------------------------------------------------------------------------
# targets
# ---------------------------------------------------------------------------

# List the deployment targets this project still has, one per line. The
# template ships all four; a real project usually deletes the ones it does
# not use.
#
#   targets
#
targets() {
    find targets -name cicd_parameters.json \
        | sed -e 's|^targets/||' -e 's|/cicd_parameters.json$||' \
        | sort \
        | sed 's|^|  - |'
}

# Show what a command would actually act on: the account, the stacks, and
# the files resolved out of the target's parameters file. Worth running
# before anything destructive.
#
#   info
#   info lambda
#   TARGET=service/server info
#
info() {
    local target="${1:-$TARGET}"
    local parameters deployment_file docker_file base_image

    # Resolved before anything is printed: assigned separately (not with
    # local), so an unknown target fails the command instead of printing a
    # half-filled header with empty values.
    parameters=$(parameters_file "$target")
    deployment_file=$(parameter_value "$target" DeploymentCfnFilename)
    docker_file=$(parameter_value "$target" DockerFilename)
    base_image=$(parameter_value "$target" BaseImageURI)

    echo "---"
    echo "PROJECT_NAME        ${PROJECT_NAME}"
    echo "STACK_NAME          ${STACK_NAME}"
    echo "TARGET              ${target}"
    echo "AWS_PROFILE         ${AWS_PROFILE}"
    echo "AWS_REGION          ${AWS_REGION}"
    echo "AWS_ACCOUNT         $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
    echo "CICD_STACK_NAME     ${CICD_STACK_NAME}"
    echo "DEPLOYMENT_STACK    ${STACK_NAME}"
    echo "CICD_FILE_NAME      ${CICD_FILE_NAME}"
    echo "CICD_PARAMETERS     ${parameters}"
    echo "DEPLOYMENT_FILE     ${deployment_file}"
    echo "DOCKER_FILE         ${docker_file}"
    echo "BASE_IMAGE_URI      ${base_image}"
    echo "BUILD_PLATFORM      ${BUILD_PLATFORM:-$(build_platform "$target")}"
    echo "CONTAINER_PORT      $(container_port "$target")"
    echo "RUN_ENV             ${RUN_ENV:-}"
    echo "TEMPLATE_BUCKET     ${TEMPLATE_BUCKET}"
    echo "CODECOMMIT_SSH_HOST ${CODECOMMIT_SSH_HOST}"
    echo "AWS_CONFIG_HOST_DIR ${AWS_CONFIG_HOST_DIR}"
    echo "REMOTE_HOST         ${REMOTE_HOST:-<unset, upload takes it as an argument>}"
    echo "REMOTE_DIR          ${REMOTE_DIR:-<unset, upload takes it as an argument>}"
    echo "---"
}

# ---------------------------------------------------------------------------
# stacks
#
# Two stacks per project:
#   <project>-cicd   the pipeline, created from targets/common/cicd.yaml
#   <project>        the service itself, created by that pipeline
# ---------------------------------------------------------------------------

# Check the cicd template and the target's deployment template parse and are
# well formed. Runs automatically before deploy-cicd. Also runs cfn-lint when
# it is installed.
#
#   validate
#   validate lambda
#
validate() {
    local target="${1:-$TARGET}"
    local deployment_file
    deployment_file=$(parameter_value "$target" DeploymentCfnFilename)

    local template
    for template in "$CICD_FILE_NAME" "$deployment_file"; do
        require_file "$template"
        aws cloudformation validate-template --template-body file://"$template" > /dev/null
        if command -v cfn-lint > /dev/null 2>&1; then
            # Warnings are printed but do not fail: templates legitimately
            # carry unused parameters and W-level style findings.
            cfn-lint --non-zero-exit-code error "$template"
        fi
        echo "ok  ${template}"
    done
}

# Create or update the CICD stack, then wire this repo's CodeCommit remote.
# ProjectName in the parameters file is overridden with PROJECT_NAME, so the
# same target can be deployed under a throwaway name for testing.
#
#   deploy-cicd lambda
#   PROJECT_NAME=lambda-test-1 deploy-cicd lambda
#
deploy_cicd() {
    local target="${1:-$TARGET}"
    require_command jq

    local parameters
    parameters=$(parameters_file "$target")

    validate "$target"

    echo ""
    echo "deploying ${CICD_STACK_NAME} (${target}) to ${AWS_PROFILE}"

    # aws cloudformation deploy takes Key=Value overrides, not a parameters
    # file, so the JSON is flattened and ProjectName replaced.
    local overrides
    overrides=$(jq -r --arg project "$STACK_NAME" \
        '.[] | "\(.ParameterKey)=\(if .ParameterKey == "ProjectName" then $project else .ParameterValue end)"' \
        "$parameters" | tr '\n' ' ')

    # shellcheck disable=SC2086 - overrides is a deliberately word-split list.
    aws cloudformation deploy \
        --capabilities "${CAPABILITIES[@]}" \
        --stack-name "$CICD_STACK_NAME" \
        --template-file "$CICD_FILE_NAME" \
        --parameter-overrides ${overrides}

    remote
}

# Point the git remote named after the project at the CodeCommit repository
# the CICD stack created, adding or updating it as needed. Pushing to that
# remote is what triggers the pipeline.
#
#   remote
#
remote() {
    local repository url
    repository=$(output_value CodeCommitRepositoryName "$CICD_STACK_NAME" 2>/dev/null || true)
    [[ -n "$repository" && "$repository" != None ]] \
        || die "ERROR: no CodeCommitRepositoryName on ${CICD_STACK_NAME} - deploy-cicd first"

    url="ssh://${CODECOMMIT_SSH_HOST}/v1/repos/${repository}"

    if git remote get-url "$STACK_NAME" > /dev/null 2>&1; then
        git remote set-url "$STACK_NAME" "$url"
    else
        git remote add "$STACK_NAME" "$url"
    fi
    echo "remote ${STACK_NAME} -> ${url}"
}

# Copy this project to a remote host over ssh, for working on a box that has no
# clone of it - a project not on GitHub yet, or local changes you do not want to
# commit just to move them. `git clone` on the remote is still the right tool
# once the repository exists somewhere.
#
# The host is an entry in ~/.ssh/config, so it inherits whatever that entry
# says - including a ProxyCommand, which is how the gig-builder boxes are
# reached (they have no inbound port; see the builder Makefile's ssh-config).
#
#   upload gig-builder-aolabs dev
#   upload gig-builder-aolabs /media/data/projects
#   REMOTE_HOST=... REMOTE_DIR=... upload
#   upload gig-builder-aolabs dev DRY_RUN=1     # print what would transfer
#
# Both arguments are required. Neither has a default: a host or a directory you
# cannot see in the command is one you cannot recall months later, and it makes
# uploading to the wrong place silent. A relative directory resolves against the
# remote home.
#
# Lands in <dir>/<project>. Excludes what should be rebuilt on the far side
# rather than copied: the venv is the big one - a macOS interpreter is useless
# on Linux, and it is the mistake that makes a devcontainer silently fail
# there.
upload() {
    local host="${1:-$REMOTE_HOST}"
    local directory="${2:-$REMOTE_DIR}"
    [[ -n "$host" ]] \
        || die "ERROR: which host? upload <host> <directory>, or export REMOTE_HOST=... (an entry in ~/.ssh/config)"
    [[ -n "$directory" ]] \
        || die "ERROR: which directory on ${host}? upload ${host} <directory>, or export REMOTE_DIR=... (relative to the remote home)"

    local -a options
    options=(
        --archive --compress --human-readable --partial --progress
        --exclude "venv/" --exclude ".venv/" --exclude "node_modules/"
        --exclude "build/" --exclude "_build/" --exclude "deps/"
        --exclude "__pycache__/" --exclude "*.pyc" --exclude ".mypy_cache/"
        --exclude ".pytest_cache/" --exclude ".DS_Store"
    )
    # .git is excluded by default: rsyncing over an existing clone's history is
    # a good way to corrupt it. WITH_GIT=1 includes it, which is what you want
    # for a project that has no remote yet and whose history would otherwise
    # not survive the trip.
    [[ -n "${WITH_GIT:-}" ]] || options+=(--exclude ".git/")
    [[ -n "${DRY_RUN:-}" ]] && options+=(--dry-run)

    # One round trip: create the directory and learn its absolute path, so the
    # lines printed at the end are ones you can actually paste.
    local destination
    destination=$(ssh "$host" "mkdir -p \"${directory}/${PROJECT_NAME}\" && cd \"${directory}/${PROJECT_NAME}\" && pwd") \
        || die "ERROR: cannot reach ${host} - check ~/.ssh/config, and that the box is running"

    # Trailing slash on the source: copy the contents into <destination>, not
    # into <destination>/<project>.
    rsync "${options[@]}" "${PWD}/" "${host}:${destination}/"

    echo ""
    echo "uploaded to ${host}:${destination}"
    echo "  ssh ${host}"
    echo "  code --folder-uri \"vscode-remote://ssh-remote+${host}${destination}\""
}

# Push a branch to CodeCommit as main, which starts the pipeline. Defaults to
# the current branch, so a feature branch can be deployed without renaming.
#
#   push
#   push dev
#
push() {
    # The branch is required. It used to default to whatever was checked out,
    # and this pushes to the remote's main whatever the local name - so the
    # branch that gets deployed is worth saying out loud.
    local branch="${1:-}"
    [[ -n "$branch" ]] \
        || die "ERROR: which branch? push <branch> - it is pushed to ${STACK_NAME}/main. Current branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

    git push "$STACK_NAME" "${branch}:main"
    pipeline
}

# Print the state of every pipeline stage as a table. The pipeline is named
# after the CICD stack.
#
#   pipeline
#
pipeline() {
    aws codepipeline get-pipeline-state \
        --name "${CICD_STACK_NAME}-CodePipeline" \
        --query 'stageStates[*].[stageName,latestExecution.status]' \
        --output table
}

# Stop the pipeline execution that is currently in progress.
#
#   pipeline-stop
#
pipeline_stop() {
    local execution
    execution=$(aws codepipeline list-pipeline-executions \
        --pipeline-name "${CICD_STACK_NAME}-CodePipeline" \
        --query 'pipelineExecutionSummaries[?status==`InProgress`]|[0].pipelineExecutionId' \
        --output text)

    [[ -n "$execution" && "$execution" != None ]] || die "no execution in progress"

    aws codepipeline stop-pipeline-execution \
        --pipeline-name "${CICD_STACK_NAME}-CodePipeline" \
        --pipeline-execution-id "$execution" \
        --abandon
}

# Print every output of a stack as a table. Defaults to the deployment stack;
# pass the cicd stack name for the pipeline's outputs.
#
#   outputs
#   outputs my_service-cicd
#
outputs() {
    local stack="${1:-$STACK_NAME}"

    aws cloudformation describe-stacks \
        --stack-name "$stack" \
        --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
        --output table
}

# Print one output value, unquoted, for use in a shell variable.
#
#   output-value LambdaFunctionUrl
#   output-value CodeCommitRepositoryName my_service-cicd
#   URL=$(./commands.sh output-value APIInvokeURL)
#
output_value() {
    local key=$1 stack="${2:-$STACK_NAME}"
    require_args 1 $# "output-value <output-key> [stack-name]"

    aws cloudformation describe-stacks \
        --stack-name "$stack" \
        --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
        --output text
}

# Print the invoke URL of the deployed service, whichever output the target
# happens to publish it under.
#
#   url
#
url() {
    local key value
    for key in APIInvokeURL ApiInvokeURL LambdaFunctionUrl; do
        value=$(output_value "$key" 2>/dev/null || true)
        if [[ -n "$value" && "$value" != None ]]; then
            echo "$value"
            return 0
        fi
    done
    die "ERROR: ${STACK_NAME} publishes no invoke URL output"
}

# Print the most recent FAILED events for a stack - the first thing to look
# at when a create or update rolls back.
#
#   events
#   events my_service-cicd
#
events() {
    local stack="${1:-$STACK_NAME}"

    aws cloudformation describe-stack-events \
        --stack-name "$stack" \
        --query 'StackEvents[?contains(ResourceStatus, `FAILED`)].[LogicalResourceId,ResourceStatusReason]' \
        --max-items 15 \
        --output table
}

# Follow the deployed service's CloudWatch logs. The log group is taken from
# the stack outputs for lambda targets; ECS targets do not publish one, so
# pass the group name.
#
#   logs
#   logs /ecs/my_service
#
logs() {
    local group="${1:-$(output_value LambdaFunctionLogGroupName 2>/dev/null || true)}"

    [[ -n "$group" && "$group" != None ]] \
        || die "ERROR: no log group output on ${STACK_NAME} - pass one: logs <log-group>"

    echo "tailing ${group} - ctrl-c to stop"
    aws logs tail "$group" --follow --format short
}

# ---------------------------------------------------------------------------
# teardown
# ---------------------------------------------------------------------------

# Delete the deployment stack - the service, not the pipeline. The pipeline
# recreates it on the next push.
#
#   delete-stack
#
delete_stack() {
    if ! stack_exists "$STACK_NAME"; then
        echo "stack not found: ${STACK_NAME} (skipping)"
        return 0
    fi

    confirm "delete stack ${STACK_NAME}"

    aws cloudformation delete-stack --stack-name "$STACK_NAME"
    wait_for_stack "$STACK_NAME" delete
}

# Delete the CICD stack, emptying its ECR repository and artifact bucket
# first - CloudFormation cannot delete either while it holds objects - and
# dropping the git remote afterwards.
#
#   delete-cicd
#
delete_cicd() {
    if ! stack_exists "$CICD_STACK_NAME"; then
        echo "stack not found: ${CICD_STACK_NAME} (skipping)"
        return 0
    fi

    confirm "delete stack ${CICD_STACK_NAME}"

    local repository bucket
    repository=$(output_value EcrRepositoryName "$CICD_STACK_NAME" 2>/dev/null || true)
    bucket=$(output_value ArtifactStoreName "$CICD_STACK_NAME" 2>/dev/null || true)

    if [[ -n "$repository" && "$repository" != None ]]; then
        empty_ecr_repository "$repository"
    fi
    if [[ -n "$bucket" && "$bucket" != None ]]; then
        aws s3 rm --recursive "s3://${bucket}" > /dev/null 2>&1 || true
    fi

    aws cloudformation delete-stack --stack-name "$CICD_STACK_NAME"
    wait_for_stack "$CICD_STACK_NAME" delete

    if git remote get-url "$STACK_NAME" > /dev/null 2>&1; then
        git remote remove "$STACK_NAME"
        echo "removed git remote ${STACK_NAME}"
    fi
}

# Delete every image in an ECR repository, so the repository itself can be
# deleted with its stack.
#
#   empty_ecr_repository my_service-cicd-ecr-repository
#
empty_ecr_repository() {
    local repository=$1
    require_command jq

    aws ecr describe-repositories --repository-names "$repository" > /dev/null 2>&1 || {
        echo "ECR repository not found: ${repository} (skipping)"
        return 0
    }

    local images
    images=$(aws ecr list-images --repository-name "$repository" --query 'imageIds[*]' --output json)
    if [[ "$(echo "$images" | jq 'length')" == "0" ]]; then
        echo "no images in ${repository}"
        return 0
    fi

    aws ecr batch-delete-image \
        --repository-name "$repository" \
        --image-ids "$images" > /dev/null
    echo "emptied ECR repository ${repository}"
}

# Delete both stacks, deployment first - it holds the ECS service and lambda
# that reference the pipeline's images.
#
#   delete-all
#
delete_all() {
    delete_stack
    delete_cicd
}

# ---------------------------------------------------------------------------
# nested template versions
# ---------------------------------------------------------------------------

# Print the deployment template of every target, deduplicated. Several targets
# can share one file, and a project deletes the targets it does not use.
#
#   deployment_files
#
deployment_files() {
    local target
    for target in $(targets | sed 's/^ *- *//'); do
        parameter_value "$target" DeploymentCfnFilename
    done | sort -u
}

# Show, or set, the gig-cfn-templates release the nested stacks are pulled
# from - the TemplateVersion parameter of each deployment template, which is
# the only place it lives.
#
# With no argument it lists what each template is on. With a version it checks
# every nested template exists in the bucket at that version FIRST, and only
# writes the files if they all do: `validate` cannot catch a bad version,
# because CloudFormation does not fetch nested TemplateURLs when validating.
#
#   template-version
#   template-version v1.10.3
#
template_version() {
    local version="${1:-}"
    local file current

    if [[ -z "$version" ]]; then
        for file in $(deployment_files); do
            current=$(nested_version "$file")
            printf '  %-42s %s\n' "$file" "${current:-none}"
        done
        return 0
    fi

    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "ERROR: not a version: ${version}"

    # The keys are the same whatever the version, so they can be read from the
    # files as they stand and checked before anything is written.
    local keys missing=0 key
    keys=$(grep -ho 'templates/[^"]*\.yaml' $(deployment_files) | sort -u)
    [[ -n "$keys" ]] || die "ERROR: no nested templates found in the deployment files"

    echo "checking s3://${TEMPLATE_BUCKET}/${version}/ ..."
    for key in $keys; do
        if aws s3api head-object --bucket "$TEMPLATE_BUCKET" --key "${version}/${key}" \
            > /dev/null 2>&1; then
            printf '  ok       %s\n' "$key"
        else
            printf '  MISSING  %s\n' "$key"
            missing=1
        fi
    done
    (( missing == 0 )) || die "ERROR: ${version} is incomplete - nothing changed"

    for file in $(deployment_files); do
        current=$(nested_version "$file")
        [[ -n "$current" ]] || continue
        set_nested_version "$file" "$version"
        printf '  %-42s %s -> %s\n' "$file" "$current" "$version"
    done
}

# Print the TemplateVersion default of one deployment template, empty if it
# has no such parameter.
#
#   nested_version targets/lambda/deployment.yaml
#
nested_version() {
    local file=$1
    awk '
        /^[[:space:]]*TemplateVersion:[[:space:]]*$/ { found = 1; next }
        found && /^[[:space:]]*Default:/ {
            match($0, /"[^"]*"/)
            print substr($0, RSTART + 1, RLENGTH - 2)
            exit
        }
        found && /^[[:space:]]*[A-Za-z]/ && !/^[[:space:]]*(Type|Default|Description):/ { exit }
    ' "$file"
}

# Rewrite the TemplateVersion default of one deployment template.
#
#   set_nested_version targets/lambda/deployment.yaml v1.10.3
#
set_nested_version() {
    local file=$1 version=$2 tmp
    tmp=$(mktemp)
    awk -v version="$version" '
        /^[[:space:]]*TemplateVersion:[[:space:]]*$/ { found = 1 }
        found && /^[[:space:]]*Default:/ { sub(/"[^"]*"/, "\"" version "\""); found = 0 }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# local development environment
# ---------------------------------------------------------------------------

# Create or update ./venv from environment.yaml - the language toolchain this
# project builds and tests with. Kept as its own script rather than a function
# here, because it is what a fresh clone runs before anything else and is
# often run on its own.
#
#   local-dev-setup
#   ENV_PREFIX=./venv-3.13 local-dev-setup
#
local_dev_setup() {
    require_file ./make/setup_local_dev_env.sh
    ./make/setup_local_dev_env.sh
}

# ---------------------------------------------------------------------------
# local docker
#
# The same image the pipeline builds, run on this machine. The Dockerfile and
# base image come from the target's parameters file, so local and deployed
# builds cannot drift apart.
# ---------------------------------------------------------------------------

# Print the platform a target's image must be built for. The deployed runtime
# decides this, and it is x86_64 unless the templates say otherwise: neither
# lambda-0010 nor the ECS modules set an architecture, so AWS defaults both to
# x86_64, and CodeBuild builds for whatever its own image is. Following the
# CodeBuild image keeps a local build the same shape as the pipeline's, rather
# than the shape of the machine it runs on.
#
#   build_platform lambda          -> linux/amd64
#   BUILD_PLATFORM=linux/arm64 build ...   # native, fast, not what deploys
#
build_platform() {
    local target=$1 image
    image=$(parameter_value "$target" CodeBuildImage)
    case "$image" in
        *aarch64*|*arm64*) echo "linux/arm64" ;;
        *)                 echo "linux/amd64" ;;
    esac
}

# Build the target's image, tagged <project>:latest. Forwards the ssh agent
# so Dockerfiles that pull private repositories work.
#
#   build
#   build lambda
#
build() {
    local target="${1:-$TARGET}"
    require_command docker

    local dockerfile base_image platform
    dockerfile=$(parameter_value "$target" DockerFilename)
    base_image=$(parameter_value "$target" BaseImageURI)
    platform="${BUILD_PLATFORM:-$(build_platform "$target")}"
    require_file "$dockerfile"

    local ssh_args=()
    if [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh-add -l > /dev/null 2>&1; then
        ssh_args=(--ssh default)
    else
        echo "warning: no ssh agent - a build needing private repos will fail" >&2
        echo '  eval "$(ssh-agent -s)" && ssh-add ~/.ssh/github_id_rsa' >&2
    fi

    # An ECR Public login token lasts 12 hours, and docker keeps presenting an
    # expired one instead of falling back to an anonymous pull - the build then
    # fails on the FROM with "Your authorization token has expired". Refresh it,
    # or drop it so anonymous pulls resume. Never fatal: a build that does not
    # pull from ECR Public should not care.
    if [[ "$base_image" == public.ecr.aws/* ]] && command -v aws > /dev/null 2>&1; then
        if aws ecr-public get-login-password --region us-east-1 2>/dev/null \
            | docker login --username AWS --password-stdin public.ecr.aws > /dev/null 2>&1; then
            :
        else
            echo "warning: could not refresh the ECR Public token - anonymous pull" >&2
            docker logout public.ecr.aws > /dev/null 2>&1 || true
        fi
    fi

    echo "building ${STACK_NAME}:latest from ${dockerfile} (${base_image}, ${platform})"
    # ${a[@]+"${a[@]}"} - bash 3.2, which macOS ships, treats an empty array
    # as unset under set -u.
    docker build \
        --platform "$platform" \
        ${ssh_args[@]+"${ssh_args[@]}"} \
        --build-arg BASE_IMAGE_URI="$base_image" \
        -t "${STACK_NAME}:latest" \
        --file "$dockerfile" \
        .
}

# Build, then run the image detached as <project>-local, with the current
# profile's AWS credentials mounted. Pass an empty entrypoint to keep the
# image's own - which is what lambda images need, their command being the
# handler.
#
#   run "" src.main_lambda.lambda_handler_1 lambda
#   run python src/main_task.py service/task
#   run uvicorn "src.main_server:app --host 0.0.0.0 --port 8080" service/server
#
# Application environment variables come from RUN_ENV, since the container
# gets only the AWS ones by default:
#
#   RUN_ENV="REDIS_SECRET_NAME=my-settings DEBUG=1" run "" src.main_lambda.lambda_handler_1 lambda
#
run() {
    local entrypoint=$1 cmd=$2 target="${3:-$TARGET}"
    require_args 2 $# "run <entrypoint> <cmd> [target]"
    require_command docker

    build "$target"

    local port target_port
    port=$(local_port "$target")
    target_port=$(container_port "$target")

    docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true

    local entrypoint_args=()
    [[ -n "$entrypoint" ]] && entrypoint_args=(--entrypoint "$entrypoint")

    # RUN_ENV is a space-separated KEY=VALUE list, deliberately word-split.
    # A value containing spaces needs docker run by hand.
    local env_args=()
    local pair
    for pair in ${RUN_ENV:-}; do
        env_args+=(--env "$pair")
    done

    # shellcheck disable=SC2086 - cmd is a deliberately word-split argument list.
    docker run --detach \
        --name "$CONTAINER_NAME" \
        --publish "${port}:${target_port}" \
        --env AWS_PROFILE="$AWS_PROFILE" \
        --env AWS_REGION="$AWS_REGION" \
        --env AWS_DEFAULT_REGION="$AWS_REGION" \
        --volume "${AWS_CONFIG_HOST_DIR}/:/root/.aws:ro" \
        ${env_args[@]+"${env_args[@]}"} \
        ${entrypoint_args[@]+"${entrypoint_args[@]}"} \
        "${STACK_NAME}:latest" ${cmd} > /dev/null

    # A server keeps the port open; a task runs to completion and exits, so
    # report what the container is actually doing rather than a URL nothing
    # is listening on. One second is enough for a script that fails on import.
    sleep 1
    if [[ -n "$(docker ps --quiet --filter "name=^${CONTAINER_NAME}$")" ]]; then
        echo "${CONTAINER_NAME} running"
        if [[ "$target" == lambda ]]; then
            echo "invoke: make invoke JSON='{\"test\": 1}'"
        else
            # Published either way; only a process that serves HTTP answers it.
            echo "port:   localhost:${port} -> container ${target_port}, if the process serves HTTP"
        fi
    else
        local status
        status=$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null)
        echo "${CONTAINER_NAME} exited (${status}) - nothing is listening on ${port}"
    fi
    echo "logs:   make local-logs"
    echo "stop:   make stop"
}

# POST a JSON payload to the local lambda runtime emulator.
#
#   invoke
#   invoke '{"test": 1}'
#   invoke @data/test.json
#
invoke() {
    local payload="${1:-{\}}"

    curl --silent --show-error \
        --header 'content-type: application/json' \
        --data "$payload" \
        "http://localhost:${LOCAL_PORT_LAMBDA}/2015-03-31/functions/function/invocations"
    echo ""
}

# Follow the local container's logs.
#
#   local-logs
#
local_logs() {
    docker logs --follow "$CONTAINER_NAME"
}

# Open a shell inside the running local container.
#
#   shell
#
shell() {
    docker exec -it "$CONTAINER_NAME" /bin/bash
}

# Stop and remove the local container.
#
#   stop
#
stop() {
    docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
    echo "stopped ${CONTAINER_NAME}"
}

# ---------------------------------------------------------------------------
# misc
# ---------------------------------------------------------------------------

# Show which account the current settings actually resolve to.
#
#   aws-info
#   AWS_PROFILE=gig-prod aws-info
#
aws_info() {
    echo "---"
    echo "AWS_PROFILE         ${AWS_PROFILE}"
    echo "AWS_REGION          ${AWS_REGION}"
    echo "AWS_ACCOUNT         $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
    echo "---"
}

# Print the command list. Also what an unknown command prints, to stderr.
#
#   help
#
help() {
    cat <<EOF
usage: ./make/commands.sh <command> [arguments]

project
  local-dev-setup                             create/update ./venv from environment.yaml
  info           [target]                     resolved config for a target
  targets                                     deployment targets in this project
  template-version [version]                  gig-cfn-templates release of the
                                              nested stacks; checks the bucket
                                              before it writes
  aws-info
  help

pipeline
  validate       [target]                     cicd + deployment templates
  deploy-cicd    [target]                     create/update the pipeline stack
  remote                                      point git remote at CodeCommit
  upload         <host> <directory>           rsync this project to a remote
                                              host; DRY_RUN=1 to preview
  push           <branch>                     push <branch> to CodeCommit main,
                                              starting the pipeline
  pipeline                                    stage states
  pipeline-stop                               abandon the running execution

deployment
  outputs        [stack]                      default: ${STACK_NAME}
  output-value   <output-key> [stack]
  url                                         invoke URL of the service
  events         [stack]                      failed events, most recent first
  logs           [log-group]                  follow CloudWatch logs

teardown
  delete-stack                                the service stack
  delete-cicd                                 the pipeline stack, emptied first
  delete-all                                  both, service first

local docker
  build          [target]
  run            <entrypoint> <cmd> [target]  build, then run detached
                                              RUN_ENV="K=V K2=V2" for app env vars
  invoke         [json]                       POST to the local lambda emulator
  local-logs
  shell
  stop

Defaults: PROJECT_NAME=${PROJECT_NAME} TARGET=${TARGET} AWS_PROFILE=${AWS_PROFILE}
Override any of them in the environment, or edit the Makefile for the project.

  PROJECT_NAME=lambda-test-1 ./make/commands.sh deploy-cicd lambda
  ./make/commands.sh run uvicorn "src.main_server:app --host 0.0.0.0 --port 8080" service/server
EOF
}

# ---------------------------------------------------------------------------
# dispatch
#
# Command name, function name and make target are the same word throughout:
# `make outputs` -> `./make/commands.sh outputs` -> `outputs()`. Kebab in the
# command and the target, snake in the function.
# ---------------------------------------------------------------------------

command=${1:-help}
shift 2>/dev/null || true

case "$command" in
    local-dev-setup) local_dev_setup   ;;
    info)           info         "$@" ;;
    targets)        targets           ;;
    template-version) template_version "$@" ;;
    validate)       validate     "$@" ;;
    deploy-cicd)    deploy_cicd  "$@" ;;
    remote)         remote            ;;
    upload)         upload       "$@" ;;
    push)           push         "$@" ;;
    pipeline)       pipeline          ;;
    pipeline-stop)  pipeline_stop     ;;
    outputs)        outputs      "$@" ;;
    output-value)   output_value "$@" ;;
    url)            url               ;;
    events)         events       "$@" ;;
    logs)           logs         "$@" ;;
    delete-stack)   delete_stack      ;;
    delete-cicd)    delete_cicd       ;;
    delete-all)     delete_all        ;;
    build)          build        "$@" ;;
    run)            run          "$@" ;;
    invoke)         invoke       "$@" ;;
    local-logs)     local_logs        ;;
    shell)          shell             ;;
    stop)           stop              ;;
    aws-info)       aws_info          ;;
    help|-h|--help) help              ;;
    *)              echo "ERROR: unknown command '${command}'" >&2
                    echo "" >&2
                    help >&2
                    exit 1 ;;
esac
