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

# The same file the Makefile includes, so `make <command>` and
# `./make/commands.sh <command>` cannot disagree about which project they are
# acting on. Anything already in the environment wins, which is what makes
# `PROJECT_NAME=other make deploy-cicd` work.
PROJECT_CONFIG="${PROJECT_CONFIG:-project.env}"
if [[ -f "$PROJECT_CONFIG" ]]; then
    # ${!key} and printf -v, not zsh's ${(P)key} and typeset -g: this script
    # runs under bash, and macOS ships bash 3.2, which has neither declare -g
    # nor associative arrays.
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key// /}"
        case "$key" in ''|\#*) continue ;; esac
        [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$value"
    done < "$PROJECT_CONFIG"
fi

PROJECT_NAME="${PROJECT_NAME:-}"
TARGET="${TARGET:-}"
[[ -n "$PROJECT_NAME" ]] \
    || die_early "ERROR: PROJECT_NAME is not set. Declare it in ${PROJECT_CONFIG}, or: PROJECT_NAME=<name> ./make/commands.sh ..."
[[ -n "$TARGET" ]] \
    || die_early "ERROR: TARGET is not set (lambda, service/task, service/server). Declare it in ${PROJECT_CONFIG}, or: TARGET=<target> ./make/commands.sh ..."

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

# The environment file ECS reads at task start. It lives in the repo, is NOT in
# the image, and the pipeline never uploads it - `sync-config` does, and
# `config` says whether it is there.
CONFIG_FILE_NAME="${CONFIG_FILE_NAME:-container_config.env}"

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
# Set to true by delete_all, which lists both stacks and asks once. Nothing
# reads it from the environment on purpose: a prompt this skips is a stack
# deleted, so the only way to skip it is a command that has already asked.
CONFIRMED=false

confirm() {
    local message=$1
    local reply

    [[ "$CONFIRMED" == true ]] && return 0

    read -r -p "${message} in ${AWS_PROFILE}? (y/n) " reply
    [[ $reply == [Yy] ]] || die "aborted"
}

# Print the parameters file of a deployment target, after checking it exists.
# A target is the path under targets/ that holds a cicd_parameters.json:
# lambda, service/task, service/server. The last segment on its own also
# works - `task` and `server` - since nothing else under targets/ is called
# that, and the directory nesting is an implementation detail of which
# Dockerfile they share rather than something worth typing.
#
#   parameters_file lambda            -> targets/lambda/cicd_parameters.json
#   parameters_file service/server    -> targets/service/server/cicd_parameters.json
#   parameters_file server            -> targets/service/server/cicd_parameters.json
#
parameters_file() {
    local target=$1
    local path="targets/${target}/cicd_parameters.json"
    [[ -f "$path" ]] && { echo "$path"; return 0; }

    # Not a path: try it as the last segment of one. Ambiguity is reported
    # rather than resolved - picking one of two would be exactly the silent
    # wrong-target mistake the explicit names exist to prevent.
    local matches
    matches=$(find targets -mindepth 2 -name cicd_parameters.json \
        -path "*/${target}/cicd_parameters.json" 2>/dev/null | sort)

    if [[ $(echo "$matches" | grep -c .) -eq 1 ]]; then
        echo "$matches"
        return 0
    fi

    if [[ -n "$matches" ]]; then
        echo "ERROR: ambiguous target '${target}' - name it in full:" >&2
        echo "$matches" | sed -e 's|^targets/||' -e 's|/cicd_parameters.json$||' \
            -e 's|^|  - |' >&2
        exit 1
    fi

    echo "ERROR: unknown target '${target}'" >&2
    echo "" >&2
    echo "available targets:" >&2
    targets >&2
    exit 1
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
#   container_port service/task    -> the target's ContainerPort
#
container_port() {
    local target=$1
    # The port comes from the target's own parameters, the same value the
    # deployment sends as ContainerPort - not from a second copy in
    # project.env, which could disagree with it. Lambda has no port of its
    # own: the runtime interface emulator always listens on 8080.
    if [[ "$target" == lambda ]]; then
        echo "$LAMBDA_RUNTIME_PORT"
        return 0
    fi
    deployment_value "$target" "$(parameter_value "$target" DeploymentCfnFilename)" ContainerPort
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
    local parameters deployment_file docker_file base_image template_version config_object

    # Resolved before anything is printed: assigned separately (not with
    # local), so an unknown target fails the command instead of printing a
    # half-filled header with empty values.
    parameters=$(parameters_file "$target")
    deployment_file=$(parameter_value "$target" DeploymentCfnFilename)
    docker_file=$(parameter_value "$target" DockerFilename)
    base_image=$(parameter_value "$target" BaseImageURI)
    # The gig-cfn-templates release this target's nested stacks come from, and
    # the environment file its tasks read - both live in the deployment
    # template rather than cicd_parameters.json, so neither showed up here.
    template_version=$(nested_version "$deployment_file")
    config_object=$(config_uri "$target")

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
    echo "TEMPLATE_VERSION    ${template_version:-<none - this target pulls no nested stacks>}"
    echo "CONFIG_OBJECT       ${config_object:-<none - this target reads no environment file>}"
    echo "BUILD_PLATFORM      ${BUILD_PLATFORM:-$(build_platform "$target")}"
    echo "CONTAINER_PORT      $(container_port "$target")"
    echo "RUN_ENV             ${RUN_ENV:-}"
    echo "TEMPLATE_BUCKET     ${TEMPLATE_BUCKET}"
    echo "CODECOMMIT_SSH_HOST ${CODECOMMIT_SSH_HOST}"
    # Where `push` sends the branch. The remote is named after the stack, so
    # a project with several stacks has several remotes and the one in use is
    # not obvious from `git remote -v` alone.
    echo "GIT_PUSHES_TO       ${STACK_NAME}/main -> $(git remote get-url "$STACK_NAME" 2>/dev/null || echo '<no such remote - deploy-cicd, or remote>')"
    echo "AWS_CONFIG_HOST_DIR ${AWS_CONFIG_HOST_DIR}"
    # Only when set: these are arguments to `upload`, not project settings, so
    # unset is the normal case and printing it every time says nothing.
    [[ -n "${REMOTE_HOST:-}" ]] && echo "REMOTE_HOST         ${REMOTE_HOST}"
    [[ -n "${REMOTE_DIR:-}" ]] && echo "REMOTE_DIR          ${REMOTE_DIR}"
    parameters_report "$target"
    echo "---"
}

# ---------------------------------------------------------------------------
# stacks
#
# Two stacks per project:
#   <project>-cicd   the pipeline, created from targets/common/cicd.yaml
#   <project>        the service itself, created by that pipeline
# ---------------------------------------------------------------------------

# Static checks on the source, before anything is built, validated or
# deployed. The command is the language layer's, filled in by bootstrap.sh -
# there is no language-agnostic linter, and inferring one from the files lying
# around is exactly the kind of guess this script avoids.
#
# Change it here if the project adopts a different tool. Empty means this
# project has no linter, which `lint` reports rather than passing silently.
#
#   lint
#
LINT_TOOL="{{LINT_TOOL}}"
LINT_COMMAND="{{LINT_COMMAND}}"
LINT_INSTALL="{{LINT_INSTALL}}"

lint() {
    lint_source
    echo
    lint_templates
}

# The language layer's own checks - ruff, go vet, clang-format, whichever.
lint_source() {
    [[ -n "$LINT_COMMAND" ]] || die "ERROR: no linter configured for this project.
  Set LINT_TOOL, LINT_COMMAND and LINT_INSTALL near the top of make/commands.sh."

    if ! command -v "$LINT_TOOL" > /dev/null 2>&1; then
        die "ERROR: ${LINT_TOOL} is not installed.
  ${LINT_INSTALL}"
    fi

    # Printed, not silent: the command is a constant in this file rather than
    # something passed in, and knowing which checks ran is the point.
    echo "running: ${LINT_COMMAND}"
    # eval, because the value is a shell line with its own quoting and may
    # chain two checks - a lint and a format check. It is a constant defined
    # above, never an argument.
    eval "$LINT_COMMAND"
    echo "source ok"
}

# cfn-lint over every CloudFormation template in the repository, which is more
# than `validate` sees: validate checks the two templates one target uses,
# this checks all of them, so a target you are not deploying today cannot rot
# unnoticed.
#
# Missing cfn-lint is fatal here, unlike in validate. validate has its own
# checks and treats cfn-lint as a bonus; lint has no other job, so quietly
# doing half of it is the silent-skip this script exists to avoid.
lint_templates() {
    if ! command -v cfn-lint > /dev/null 2>&1; then
        die "ERROR: cfn-lint is not installed.
  pip install cfn-lint, or conda install -c conda-forge cfn-lint"
    fi

    local template
    for template in $(cfn_templates); do
        require_file "$template"
        # Warnings are printed but do not fail, the same rule validate uses:
        # templates legitimately carry unused parameters and W-level style
        # findings, and a lint that cries wolf gets ignored.
        cfn-lint --non-zero-exit-code error "$template"
        echo "ok  ${template}"
    done
}

# Every CloudFormation template this project owns: the pipeline's, and one per
# target. Taken from the targets rather than by globbing *.yaml, which would
# also pick up the buildspecs - those are YAML but not templates, and cfn-lint
# reports them as errors.
cfn_templates() {
    echo "$CICD_FILE_NAME"
    deployment_files
}

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

        # Only deployment templates take parameters the pipeline does not pass.
        # A parameter with no default AND no value in deployment_parameters.json
        # is one CloudFormation will refuse the deploy over.
        # Which file supplies this template's parameters: the pipeline stack is
        # deployed from cicd_parameters.json, the deployment stack from the
        # target's deployment_parameters.json.
        local missing name value present source_file unset_names="" placeholder_names=""
        if [[ "$template" == "$CICD_FILE_NAME" ]]; then
            source_file=$(parameters_file "$target")
        else
            source_file=$(parameter_value "$target" DeploymentParametersFilename 2>/dev/null || true)
        fi

        missing=$(required_parameters "$template")
        for name in $missing; do
            if [[ "$template" == "$CICD_FILE_NAME" ]]; then
                value=$(parameter_value "$target" "$name" 2>/dev/null || true)
                present=$([[ -n "$value" ]] && echo yes || true)
            else
                value=$(deployment_parameter "$target" "$name")
                present=$(deployment_parameter_present "$target" "$name")
            fi

            if [[ -z "$present" ]]; then
                unset_names+="${name} "
            elif [[ "$value" == "<set me>" ]]; then
                placeholder_names+="${name} "
            fi
        done
        if [[ -n "$unset_names$placeholder_names" ]]; then
            [[ -n "$unset_names" ]] && echo "    missing: ${unset_names% }"
            [[ -n "$placeholder_names" ]] && echo "    still <set me>: ${placeholder_names% }"
            echo "    set them in ${source_file:-the parameters file for this target}"
        fi

        # Pinning an old release is legitimate, so this reports rather than
        # fails - but silently sitting twelve releases back is not a decision
        # anyone made.
        local pinned latest
        pinned=$(nested_version "$template")
        if [[ -n "$pinned" ]]; then
            latest=$(latest_template_version)
            if [[ -n "$latest" && "$pinned" != "$latest" ]]; then
                echo "    TemplateVersion ${pinned}, latest published ${latest} - make template-version ${latest}"
            fi
        fi
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
    # The task definition names an environment file ECS fetches at start. It is
    # not in the image and nothing in the pipeline uploads it, so a missing
    # object does not fail here - it fails much later, as the task refusing to
    # start with ResourceInitializationError.
    local config_object
    config_object=$(config_uri "$target")
    if [[ -n "$config_object" ]] && ! aws s3 ls "$config_object" > /dev/null 2>&1; then
        die "ERROR: ${config_object} does not exist - the task will not start. Upload it first: make sync-config ${target}"
    fi

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

    # Deliberately not calling pipeline here: the push has only just landed, so
    # what it would print is the PREVIOUS execution's state, which reads as if
    # this one already finished. Run `make pipeline` when you want to look.
    echo "pushed - the pipeline starts on the CodeCommit event: make pipeline"
}

# Print the state of every pipeline stage as a table. The pipeline is named
# after the CICD stack.
#
#   pipeline
#
pipeline() {
    # lastStatusChange lives on the action, not the stage, so it comes from the
    # stage's last action. Without a time a stage that says Succeeded looks
    # current whether it finished ten seconds or ten days ago.
    printf '%-12s %-12s %s\n' "STAGE" "STATUS" "LAST CHANGE"
    aws codepipeline get-pipeline-state \
        --name "${CICD_STACK_NAME}-CodePipeline" \
        --query 'stageStates[*].[stageName,latestExecution.status,actionStates[-1].latestExecution.lastStatusChange]' \
        --output text \
        | awk -F'\t' '{
            when = $3
            sub(/\.[0-9]+/, "", when)
            printf "%-12s %-12s %s\n", $1, ($2 == "None" ? "-" : $2), (when == "None" ? "-" : when)
        }'
    echo ""
    echo "read at $(date '+%Y-%m-%dT%H:%M:%S%z')"
}

# Stop the pipeline execution that is currently in progress.
#
#   pipeline-stop
# Why the last pipeline run failed. `pipeline` says which stage; this says
# what, and where the detail lives - which differs by action, so it keys off
# the action's provider rather than the stage's name. A pipeline with renamed
# or extra stages reports just the same.
#
#   pipeline-errors
#
pipeline_errors() {
    local pipeline_name execution
    pipeline_name="${CICD_STACK_NAME}-CodePipeline"

    # No --max-items: with --output text the CLI appends its pagination marker,
    # so a scalar query comes back as the value AND a "None" line. The API
    # already returns newest first, so [0] is the last execution.
    # || true, because set -e would otherwise kill the script on a failing aws
    # call and the message below - the one that says what is actually wrong -
    # would never print.
    execution=$(aws codepipeline list-pipeline-executions \
        --pipeline-name "$pipeline_name" \
        --query 'pipelineExecutionSummaries[0].pipelineExecutionId' \
        --output text 2>/dev/null || true)
    [[ -n "$execution" && "$execution" != None ]] \
        || die "ERROR: no pipeline ${pipeline_name}, or it has never run - make deploy-cicd first"

    local failures
    failures=$(aws codepipeline list-action-executions \
        --pipeline-name "$pipeline_name" \
        --filter "pipelineExecutionId=${execution}" \
        --query "actionExecutionDetails[?status=='Failed'].[stageName,actionName,input.actionTypeId.provider,lastUpdateTime,output.executionResult.externalExecutionSummary,output.executionResult.externalExecutionUrl]" \
        --output text 2>/dev/null || true)

    if [[ -z "$failures" ]]; then
        echo "no failed actions in the last execution (${execution})"
        return 0
    fi

    echo "execution ${execution}"

    echo "$failures" | while IFS=$'\t' read -r stage action provider when summary url; do
        echo ""
        echo "${stage}/${action} (${provider}) failed at ${when%.*}"
        [[ "$summary" != "None" && -n "$summary" ]] && echo "  ${summary}"
        [[ "$url" != "None" && -n "$url" ]] && echo "  console: ${url}"

        # Where to look next depends on what the action is, not what the stage
        # was called.
        case "$provider" in
            CloudFormation) pipeline_error_cloudformation ;;
            CodeBuild)      pipeline_error_codebuild "$stage" ;;
        esac
    done
}

# A failed CloudFormation deploy: the pipeline only reports that CloudFormation
# refused, and the reason is in the stack's own events.
pipeline_error_cloudformation() {
    local state
    echo ""
    echo "  stack events:"
    events "$STACK_NAME" 2>/dev/null | sed 's/^/  /' | head -12

    state=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
    [[ -n "$state" && "$state" != None ]] || return 0

    echo ""
    echo "  ${STACK_NAME} is ${state}"

    # These two cannot be updated at all, only deleted, so every subsequent run
    # fails identically until the stack is gone. Everything else is either
    # updatable or transient.
    case "$state" in
        ROLLBACK_COMPLETE|REVIEW_IN_PROGRESS)
            echo "  A stack in this state can only be deleted, never updated, so every"
            echo "  run will fail the same way until it is:"
            echo "    make delete-stack     then push again"
            ;;
        *_IN_PROGRESS)
            echo "  Still working - the next run may simply need it to finish."
            ;;
    esac
}

# A failed build or test: the reason is in the build log, not in anything
# CodePipeline records.
pipeline_error_codebuild() {
    local stage=$1 project
    project=$(aws codepipeline get-pipeline --name "${CICD_STACK_NAME}-CodePipeline" \
        --query "pipeline.stages[?name=='${stage}'].actions[0].configuration.ProjectName | [0]" \
        --output text 2>/dev/null)
    [[ -n "$project" && "$project" != None ]] || return 0

    echo ""
    echo "  build log:  make logs /aws/codebuild/${project}"
}

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
    local group="${1:-}"
    [[ -n "$group" ]] || group=$(service_log_group)

    if [[ -z "$group" || "$group" == None ]]; then
        local candidates
        # Search the service name too: an ECS log group can be named after it
        # alone, with nothing of the project in it.
        local service_name
        service_name=$(deployment_value "$TARGET" "$(parameter_value "$TARGET" DeploymentCfnFilename)" ServiceName 2>/dev/null || true)
        candidates=$(aws logs describe-log-groups \
            --query "logGroups[?contains(logGroupName, '${STACK_NAME}') || contains(logGroupName, '${service_name:-$STACK_NAME}')].logGroupName" \
            --output text 2>/dev/null | tr '\t' '\n' | grep . || true)

        if [[ -n "$candidates" ]]; then
            die "ERROR: cannot work out which log group ${STACK_NAME} writes to. Pass one:
$(echo "$candidates" | sed 's/^/    make logs /')"
        fi
        die "ERROR: no log group for ${STACK_NAME} - nothing is deployed yet, or it has never run.
  make pipeline    to see whether it deployed
  make logs <log-group>    to tail one by name"
    fi

    echo "tailing ${group} - ctrl-c to stop"
    aws logs tail "$group" --follow --format short
}

# The log group the DEPLOYED application writes to - not the pipeline's, not
# the build's, and not the task monitor's, all of which are named after the
# project too and would otherwise match.
#
# Lambda publishes its group as a stack output. ECS does not, so it comes from
# the task definition the service actually runs, which is where the answer
# genuinely lives rather than a name this script guessed.
service_log_group() {
    local group
    group=$(output_value LambdaFunctionLogGroupName 2>/dev/null || true)
    if [[ -n "$group" && "$group" != None ]]; then
        echo "$group"
        return 0
    fi

    # Ask the stack what it built rather than guessing a name. The nested ECS
    # modules have named the task definition ${ServiceName}-TaskDefinition in
    # one release and ${ProjectName}-${ServiceName}-TaskDefinition in another,
    # so any convention this script encodes is wrong for some version of it.
    local service task_definition
    service=$(stack_resource_id "$STACK_NAME" AWS::ECS::Service)
    if [[ -n "$service" ]]; then
        task_definition=$(aws ecs describe-services \
            --cluster "${service%%/*}" --services "${service##*/}" \
            --query 'services[0].taskDefinition' --output text 2>/dev/null || true)
    fi

    # Nothing running: fall back to the definition the family still holds,
    # under either naming, so a rolled-back stack can still be read.
    if [[ -z "$task_definition" || "$task_definition" == None ]]; then
        local service_name family
        service_name=$(deployment_value "$TARGET" "$(parameter_value "$TARGET" DeploymentCfnFilename)" ServiceName)
        for family in "${STACK_NAME}-${service_name}-TaskDefinition" "${service_name}-TaskDefinition"; do
            task_definition=$(aws ecs describe-task-definition --task-definition "$family" \
                --query 'taskDefinition.taskDefinitionArn' --output text 2>/dev/null || true)
            [[ -n "$task_definition" && "$task_definition" != None ]] && break
        done
    fi

    # A rolled-back or torn-down stack deregisters its task definitions, and
    # describe-task-definition refuses a family whose revisions are all
    # INACTIVE - but the revision is still there by arn, and still names the
    # log group the old tasks wrote to.
    if [[ -z "$task_definition" || "$task_definition" == None ]]; then
        local service_name family
        service_name=$(deployment_value "$TARGET" "$(parameter_value "$TARGET" DeploymentCfnFilename)" ServiceName)
        for family in "${STACK_NAME}-${service_name}-TaskDefinition" "${service_name}-TaskDefinition"; do
            task_definition=$(aws ecs list-task-definitions --family-prefix "$family" \
                --status INACTIVE --sort DESC \
                --query 'taskDefinitionArns[0]' --output text 2>/dev/null || true)
            [[ -n "$task_definition" && "$task_definition" != None ]] && break
        done
    fi

    if [[ -n "$task_definition" && "$task_definition" != None ]]; then
        group=$(aws ecs describe-task-definition --task-definition "$task_definition" \
            --query 'taskDefinition.containerDefinitions[0].logConfiguration.options."awslogs-group"' \
            --output text 2>/dev/null | grep -v '^None$' || true)
        [[ -n "$group" ]] && { echo "$group"; return 0; }
    fi

    # Last resort, and the only guess in here: the name the ECS modules use.
    # Checked against the account rather than assumed, so a wrong guess reports
    # nothing instead of tailing something that is not this service.
    local service_name candidate
    service_name=$(deployment_value "$TARGET" "$(parameter_value "$TARGET" DeploymentCfnFilename)" ServiceName)
    for candidate in "/aws/ecs/${STACK_NAME}-${service_name}-LogGroup" \
                     "/ecs/${STACK_NAME}-${service_name}-LogGroup" \
                     "/ecs/${service_name}-LogGroup"; do
        if aws logs describe-log-groups --log-group-name-prefix "$candidate" \
            --query "logGroups[?logGroupName=='${candidate}'] | [0].logGroupName" \
            --output text 2>/dev/null | grep -qv '^None$'; then
            echo "$candidate"
            return 0
        fi
    done
    return 0
}

# The physical id of the first resource of a type in a stack, nested stacks
# included - which is where the ECS service lives.
#
#   stack_resource_id my-service AWS::ECS::Service
#
stack_resource_id() {
    local stack=$1 type=$2 id nested
    id=$(aws cloudformation list-stack-resources --stack-name "$stack" \
        --query "StackResourceSummaries[?ResourceType=='${type}'].PhysicalResourceId | [0]" \
        --output text 2>/dev/null || true)
    if [[ -n "$id" && "$id" != None ]]; then
        echo "$id"
        return 0
    fi

    for nested in $(aws cloudformation list-stack-resources --stack-name "$stack" \
        --query "StackResourceSummaries[?ResourceType=='AWS::CloudFormation::Stack'].PhysicalResourceId" \
        --output text 2>/dev/null | tr '\t' '\n'); do
        id=$(stack_resource_id "$nested" "$type")
        [[ -n "$id" ]] && { echo "$id"; return 0; }
    done
    return 0
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
    local present=()

    if stack_exists "$STACK_NAME"; then
        present+=("$STACK_NAME")
    fi
    if stack_exists "$CICD_STACK_NAME"; then
        present+=("$CICD_STACK_NAME")
    fi

    if [[ ${#present[@]} -eq 0 ]]; then
        echo "no stacks found: ${STACK_NAME}, ${CICD_STACK_NAME}"
        return 0
    fi

    # Both stacks named before a single prompt, rather than one prompt each
    # part way through the teardown - by the time the second was asked the
    # first was already gone, so it was not a question that could be answered
    # no.
    echo "stacks to delete:"
    printf '  %s\n' "${present[@]}"
    if [[ ${#present[@]} -eq 1 ]]; then
        confirm "delete it"
    else
        confirm "delete both"
    fi

    CONFIRMED=true
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

# Parameters in a deployment template that have no Default, minus the two the
# pipeline supplies (ImageName from the build, ProjectName from the cicd
# stack). Anything left has to be set in the template itself before the first
# deploy, or CloudFormation refuses it with "Parameters: [X] must have values"
# - which is the point: better a refusal than inheriting the template's value
# and creating a record in someone else's hosted zone.
#
#   required_parameters targets/service/server/deployment.yaml
#
required_parameters() {
    # Built on template_parameters rather than parsing again: this used to
    # assume a 3-or-4 space indent, which is right for a deployment template
    # and wrong for cicd.yaml, whose parameters sit at two - so nested keys
    # like AllowedValues were reported as parameters.
    local file=$1 name
    for name in $(template_parameters "$file"); do
        case "$name" in
            ImageName|ProjectName) continue ;;
        esac
        [[ -z "$(has_default "$file" "$name")" ]] && echo "$name"
    done
    return 0
}


# Turn the environment file into the JSON blob lambda-0010.yaml expects.
# Comments and blank lines are dropped; everything else is KEY=VALUE.
#
#   env_to_json container_config.env
#
env_to_json() {
    local file=$1
    awk -F= '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        NF < 2 { next }
        {
            key = $1
            sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
            value = substr($0, index($0, "=") + 1)
            sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
            gsub(/"/, "\\\"", value)
            entries[n++] = "  \"" key "\": \"" value "\""
        }
        END {
            print "{"
            for (i = 0; i < n; i++) print entries[i] (i < n - 1 ? "," : "")
            print "}"
        }
    ' "$file"
}

# Print the EnvironmentVariables default of a lambda deployment template,
# leading whitespace stripped so it can be compared with env_to_json output.
lambda_env_json() {
    awk '
        /^[[:space:]]*EnvironmentVariables:[[:space:]]*$/ {
            match($0, /^[[:space:]]*/); indent = RLENGTH; found = 1; next
        }
        found && /^[[:space:]]*Default:[[:space:]]*>-/ { collecting = 1; found = 0; next }
        collecting {
            # The block ends at the first blank line, or the first line no more
            # indented than the parameter itself - a sibling key or a comment.
            if ($0 ~ /^[[:space:]]*$/) exit
            match($0, /^[[:space:]]*/)
            if (RLENGTH <= indent) exit
            line = $0
            sub(/^[[:space:]]+/, "", line)
            print line
        }
    ' "$1"
}

# Rewrite that default from a file holding the JSON. awk -v cannot carry
# newlines, so the payload arrives as a path rather than a value.
#
# Lambda has no S3 environment file - that is an ECS task-definition feature -
# so the same container_config.env becomes the function's Environment.Variables
# through the ParseJsonMacro in lambda-0010.yaml. It lands in the repository
# rather than a bucket, so it is committed and deployed like any other template
# change.
set_lambda_env_json() {
    local file=$1 json_file=$2 tmp
    tmp=$(mktemp)
    awk -v jsonfile="$json_file" '
        /^[[:space:]]*EnvironmentVariables:[[:space:]]*$/ {
            match($0, /^[[:space:]]*/); indent = RLENGTH; found = 1; print; next
        }
        found && /^[[:space:]]*Default:[[:space:]]*>-/ {
            print
            while ((getline line < jsonfile) > 0) print sprintf("%*s", indent + 4, "") line
            close(jsonfile)
            skipping = 1; found = 0; next
        }
        skipping {
            if ($0 ~ /^[[:space:]]*$/) { skipping = 0 }
            else {
                match($0, /^[[:space:]]*/)
                if (RLENGTH <= indent) skipping = 0
                else next
            }
        }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# A value from the target's deployment_parameters.json, the file CodePipeline
# hands CloudFormation as the action's TemplateConfiguration. Empty if the file
# or the key is absent.
#
#   deployment_parameter service/server DomainName
#
deployment_parameter() {
    local file
    file=$(parameter_value "$1" DeploymentParametersFilename 2>/dev/null || true)
    [[ -n "$file" && -f "$file" ]] || return 0
    jq -r --arg key "$2" '.Parameters[$key] // empty' "$file" 2>/dev/null || true
}

# Whether the file lists the parameter at all. "" is a real value - it means
# "none", as for ContainerEnvironmentFileArn - so presence and emptiness are
# different questions. A value of <set me> is neither: it is a placeholder the
# template ships and the project has not replaced.
deployment_parameter_present() {
    local file
    file=$(parameter_value "$1" DeploymentParametersFilename 2>/dev/null || true)
    [[ -n "$file" && -f "$file" ]] || return 0
    jq -e --arg key "$2" '.Parameters | has($key)' "$file" > /dev/null 2>&1 && echo yes || true
}

# Every parameter name in a template's Parameters block, in order. The two
# kinds of template indent differently - cicd.yaml by two spaces,
# deployment.yaml by four - so the indent of the first parameter sets what
# counts, which also keeps nested keys out.
#
#   template_parameters targets/common/cicd.yaml
#
template_parameters() {
    awk '
        /^Parameters:[[:space:]]*$/ { in_parameters = 1; next }
        /^[A-Za-z][A-Za-z0-9]*:/ { in_parameters = 0 }
        !in_parameters { next }
        /^[[:space:]]+[A-Za-z][A-Za-z0-9]*:[[:space:]]*$/ {
            match($0, /^[[:space:]]*/)
            if (indent == 0) indent = RLENGTH
            if (RLENGTH != indent) next
            name = $1; sub(/:$/, "", name)
            print name
        }
    ' "$1"
}

# Whether a parameter declares a Default at all. `Default: ''` is a real
# default meaning "empty"; no Default line means CloudFormation will refuse the
# deploy until a value is given, and the two must not read the same.
has_default() {
    local file=$1 parameter=$2
    awk -v want="$parameter" '
        $0 ~ "^[[:space:]]*" want ":[[:space:]]*$" { found = 1; next }
        found && /^[[:space:]]*Default:/ { print "yes"; exit }
        found && /^[[:space:]]*[A-Za-z]/ && !/^[[:space:]]*(Type|Description|AllowedValues|AllowedPattern|NoEcho|MinLength|MaxLength):/ { exit }
    ' "$file"
}

# A parameter default as one line: continuations joined, runs of whitespace
# collapsed, and anything very long cut - a bucket list is 200 characters and
# would wrap the report into uselessness.
default_summary() {
    local value
    value=$(template_default "$1" "$2" | tr '\n' ' ')
    value="${value//\\/ }"
    value=$(echo "$value" | tr -s ' ' | sed 's/^ *//; s/ *$//')
    if (( ${#value} > 44 )); then
        echo "${value:0:41}..."
    else
        echo "$value"
    fi
}

# The parameters of both templates and the value each will actually get: from
# cicd_parameters.json where it is listed, from the template default where it
# is not, and from the pipeline for the two it passes through. A parameter
# missing from the json does not fall back to the template default on an
# update - CloudFormation keeps whatever the stack already holds - so seeing
# which is which is the point.
parameters_report() {
    local target="$1" deployment_file name value

    echo ""
    echo "cicd.yaml            ${CICD_FILE_NAME}"
    echo "                     + $(parameters_file "$target")"
    for name in $(template_parameters "$CICD_FILE_NAME"); do
        value=$(parameter_value "$target" "$name" 2>/dev/null || true)
        if [[ "$name" == ProjectName ]]; then
            printf '  %-24s %-46s %s\n' "$name" "$STACK_NAME" "(from PROJECT_NAME, overrides the file)"
        elif [[ -n "$value" ]]; then
            printf '  %-24s %s\n' "$name" "$value"
        else
            printf '  %-24s %-46s %s\n' "$name" "$(default_summary "$CICD_FILE_NAME" "$name")" "(template default - not in the json)"
        fi
    done

    deployment_file=$(parameter_value "$target" DeploymentCfnFilename)
    [[ -f "$deployment_file" ]] || return 0

    local parameters_file
    parameters_file=$(parameter_value "$target" DeploymentParametersFilename 2>/dev/null || true)

    echo ""
    echo "deployment.yaml      ${deployment_file}"
    [[ -n "$parameters_file" ]] && echo "                     + ${parameters_file}"
    for name in $(template_parameters "$deployment_file"); do
        local sent
        sent=$(deployment_parameter "$target" "$name")
        # Same cut as a template default: a 200-character bucket list would
        # wrap the report into uselessness.
        (( ${#sent} > 44 )) && sent="${sent:0:41}..."

        case "$name" in
            ImageName)   printf '  %-24s %-46s %s\n' "$name" "" "(from the build)" ;;
            ProjectName) printf '  %-24s %-46s %s\n' "$name" "$STACK_NAME" "(from the pipeline)" ;;
            *)
                if [[ "$sent" == "<set me>" ]]; then
                    printf '  %-24s %-46s %s\n' "$name" "$sent" "(NOT SET - the deploy will be wrong)"
                elif [[ -n "$(deployment_parameter_present "$target" "$name")" ]]; then
                    printf '  %-24s %-46s %s\n' "$name" "${sent:-''}" "(sent every deploy)"
                elif [[ -z "$(has_default "$deployment_file" "$name")" ]]; then
                    printf '  %-24s %-46s %s\n' "$name" "" "(NO VALUE - the deploy will be refused)"
                else
                    value=$(default_summary "$deployment_file" "$name")
                    printf '  %-24s %-46s %s\n' "$name" "${value:-''}" "(template default)"
                fi
                ;;
        esac
    done
}

# Print the Default of any parameter in a deployment template, empty if the
# parameter or its default is absent. Handles quoted and bare values.
#
#   template_default targets/service/task/deployment.yaml ConfigBucket
#
template_default() {
    local file=$1 parameter=$2
    awk -v want="$parameter" '
        $0 ~ "^[[:space:]]*" want ":[[:space:]]*$" { found = 1; next }
        found && /^[[:space:]]*Default:/ {
            line = $0
            sub(/^[[:space:]]*Default:[[:space:]]*/, "", line)
            # A YAML value continued with a trailing backslash spans lines; the
            # rest of it is as much the default as the first line is.
            while (line ~ /\\$/ && (getline nextline) > 0) {
                sub(/\\$/, "", line)
                sub(/^[[:space:]]+/, "", nextline)
                line = line nextline
            }
            gsub(/^['"'"'"]|['"'"'"][[:space:]]*$/, "", line)
            print line
            exit
        }
        found && /^[[:space:]]*[A-Za-z]/ && !/^[[:space:]]*(Type|Default|Description|AllowedValues|NoEcho):/ { exit }
    ' "$file"
}

# The s3 URI of the environment file a target's tasks read at startup, exactly
# as the deployment template composes it. ContainerEnvironmentFileArn wins when
# set, which is how a project points at a shared file.
#
#   config_uri service/task
#
config_uri() {
    local target="${1:-$TARGET}"
    local file bucket name arn
    file=$(parameter_value "$target" DeploymentCfnFilename)
    [[ -f "$file" ]] || return 0

    # These are parameters like any other, so they come from
    # deployment_parameters.json, falling back to a template default for a
    # project that has not moved its values there yet.
    arn=$(deployment_value "$target" "$file" ContainerEnvironmentFileArn)
    if [[ -n "$arn" ]]; then
        echo "s3://${arn#arn:aws:s3:::}"
        return 0
    fi

    bucket=$(deployment_value "$target" "$file" ConfigBucket)
    name=$(deployment_value "$target" "$file" ConfigFileName)
    [[ -n "$bucket" && -n "$name" ]] || return 0
    echo "s3://${bucket}/${STACK_NAME}/${name}"
}

# What a deployment parameter will actually be: the value the parameters file
# sends, or the template's default if that file does not list it. Anything
# reading a parameter has to ask this rather than the template, now that the
# templates carry no defaults.
deployment_value() {
    local target=$1 template=$2 name=$3 value
    value=$(deployment_parameter "$target" "$name")
    [[ -n "$value" ]] && { echo "$value"; return 0; }
    [[ -n "$(deployment_parameter_present "$target" "$name")" ]] && return 0
    template_default "$template" "$name"
}

# Seconds since a file was last modified, empty if there is no such file.
# stat takes different flags on macOS and in the Linux devcontainers, and this
# runs in both.
file_age_seconds() {
    local path=$1 mtime
    [[ -f "$path" ]] || return 0
    mtime=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null) || return 0
    [[ -n "$mtime" ]] || return 0
    echo $(( $(date +%s) - mtime ))
}

# An ECR Public login token lasts 12 hours, and docker keeps presenting an
# expired one instead of falling back to an anonymous pull - the build then
# fails on the FROM with "Your authorization token has expired". Refresh it,
# or drop it so anonymous pulls resume. Never fatal: a build that does not pull
# from ECR Public should not care.
#
# The refresh is a network round trip costing around three seconds, which was
# most of what a fully cached rebuild took - the build itself is about one. So
# it happens at most once per token lifetime, tracked by a stamp file. Losing
# the stamp costs one extra refresh and never correctness; a token revoked
# early still falls back to an anonymous pull.
ECR_PUBLIC_LOGIN_MAX_AGE_SECONDS=$(( 11 * 3600 ))

ecr_public_login() {
    local stamp age
    # Per profile: the token is issued against whichever credentials asked for
    # it, so one profile's login says nothing about another's.
    stamp="${TMPDIR:-/tmp}/.ecr-public-login-$(echo "$AWS_PROFILE" | tr -c 'A-Za-z0-9_.-' '_')"

    age=$(file_age_seconds "$stamp")
    if [[ -n "$age" ]] && (( age < ECR_PUBLIC_LOGIN_MAX_AGE_SECONDS )); then
        echo "ecr public: token from $(( age / 60 ))m ago, still valid"
        return 0
    fi

    if aws ecr-public get-login-password --region us-east-1 2>/dev/null \
        | docker login --username AWS --password-stdin public.ecr.aws > /dev/null 2>&1; then
        : > "$stamp"
        echo "ecr public: token refreshed"
    else
        rm -f "$stamp"
        echo "warning: could not refresh the ECR Public token - anonymous pull" >&2
        docker logout public.ecr.aws > /dev/null 2>&1 || true
    fi
}

# The local image tag for a target. One tag per target, not one per project:
# with a shared :latest, building the lambda image silently replaced the
# service one, leaving a dangling layer set and no way to tell from
# `docker images` which target the survivor came from.
#
# The tag is the target's last segment - the same name TARGET takes and
# `make info` prints - resolved first, so `server` and `service/server` tag
# one image rather than building it twice. The service/ nesting exists only
# because the two service targets share a Dockerfile; it is not worth carrying
# into a tag.
#
# It falls back to the full path when two targets share a last segment, which
# no language layer does today: there the leaf name identifies neither, and a
# tag that silently covered both would be the collision this function exists
# to prevent. Slashes are not legal in a tag, so service/task becomes
# service-task.
#
#   image_tag task            -> my-service:task
#   image_tag service/task    -> my-service:task
#
image_tag() {
    local target="${1:-$TARGET}" path leaf
    path=$(parameters_file "$target") || exit 1
    path=${path#targets/}
    path=${path%/cicd_parameters.json}

    leaf=${path##*/}
    if [[ $(targets | sed -e 's/^ *- *//' -e 's|.*/||' | grep -cx "$leaf") -le 1 ]]; then
        echo "${STACK_NAME}:${leaf}"
        return 0
    fi
    echo "${STACK_NAME}:${path//\//-}"
}

# The target project.env declares, as opposed to $TARGET which an invocation
# may have overridden - the Makefile passes TARGET positionally either way, so
# the two are always equal by the time a command sees them. Used to decide
# whether a command printed back to the user has to name the target: for the
# project's own target it does not, and printing it suggests it must be typed
# every time.
declared_target() {
    [[ -f "$PROJECT_CONFIG" ]] || return 0
    sed -n 's/^[[:space:]]*TARGET[[:space:]]*=[[:space:]]*//p' "$PROJECT_CONFIG" \
        | head -1 | tr -d '[:space:]'
}

# The ContainerEntryPoint / ContainerCmd this target's deployment sends to its
# nested stack. Unlike the values in deployment_parameters.json these are
# written into the deployment template itself, so they are read from the line
# rather than from a parameter - the CloudFormation quoting and the one !Sub
# they use stripped off, leaving something that can be pasted into `make local-run`.
#
#   container_run_value lambda ContainerCmd   -> src.main_lambda.lambda_handler_1
#
container_run_value() {
    local target=$1 key=$2 template value
    template=$(parameter_value "$target" DeploymentCfnFilename 2>/dev/null || true)
    [[ -n "$template" && -f "$template" ]] || return 0

    value=$(grep -m1 -E "^[[:space:]]*${key}:[[:space:]]" "$template" 2>/dev/null \
        | sed -e "s/^[[:space:]]*${key}:[[:space:]]*//" -e 's/[[:space:]]*$//')
    [[ -n "$value" ]] || return 0

    value=${value#!Sub }
    value=${value#\'}
    value=${value%\'}
    value=${value#\"}
    value=${value%\"}

    # The only substitution these carry, and the one that would otherwise be
    # pasted literally into a docker command.
    if [[ "$value" == *'${ContainerPort}'* ]]; then
        value=${value//\$\{ContainerPort\}/$(container_port "$target")}
    fi

    echo "$value"
}

# Where this target reads its environment file from, and whether it is there.
#
#   config
#   config service/server
#
config() {
    local target="${1:-$TARGET}" uri file
    uri=$(config_uri "$target")

    # Lambda has no S3 environment file - that is an ECS task-definition
    # feature - so the same file becomes the function's Environment.Variables,
    # written into the deployment template rather than uploaded.
    if [[ -z "$uri" ]]; then
        file=$(parameter_value "$target" DeploymentParametersFilename 2>/dev/null || true)
        if [[ -n "$file" && -f "$file" ]] \
            && jq -e '.Parameters | has("EnvironmentVariables")' "$file" > /dev/null 2>&1; then
            echo "local   ${CONFIG_FILE_NAME}"
            echo "remote  ${file} (EnvironmentVariables)"
            echo "        not a bucket: these values travel with the template,"
            echo "        so changing them is a commit and a push, not an upload"
            if [[ ! -f "$CONFIG_FILE_NAME" ]]; then
                echo "status  no local ${CONFIG_FILE_NAME}"
            elif [[ "$(env_to_json "$CONFIG_FILE_NAME" | tr -s ' \n' ' ')" \
                == "$(jq -r '.Parameters.EnvironmentVariables' "$file")" ]]; then
                echo "status  in step"
            else
                echo "status  DIFFERS from ${CONFIG_FILE_NAME}"
                echo "        sync-config writes the local file into ${file},"
                echo "        then commit and push it - the function is unchanged until"
                echo "        the pipeline redeploys"
            fi
            return 0
        fi
        echo "${target}: no environment file - this target reads none"
        return 0
    fi

    echo "local   ${CONFIG_FILE_NAME}"
    echo "remote  ${uri}"

    if aws s3 ls "$uri" > /dev/null 2>&1; then
        if [[ ! -f "$CONFIG_FILE_NAME" ]]; then
            # Reporting "present" here would imply the two agree, when there is
            # nothing local to agree with - usually CONFIG_FILE_NAME naming a
            # file this project does not use.
            echo "status  present remotely, but there is no local ${CONFIG_FILE_NAME}"
            echo "        set CONFIG_FILE_NAME in project.env to the file this project keeps"
        elif ! aws s3 cp "$uri" - 2>/dev/null | diff -q - "$CONFIG_FILE_NAME" > /dev/null 2>&1; then
            echo "status  present, DIFFERS from the local file - sync-config to replace it"
        else
            echo "status  present"
        fi
    else
        echo "status  MISSING - the task will fail to start: sync-config"
    fi
}

# Upload the local environment file to where the deployment expects it. It is
# not part of the image and the pipeline never touches it, so it has to be put
# there once, and again whenever it changes.
sync_config() {
    local target="${1:-$TARGET}" uri file
    uri=$(config_uri "$target")
    require_file "$CONFIG_FILE_NAME"

    if [[ -n "$uri" ]]; then
        aws s3 cp "$CONFIG_FILE_NAME" "$uri"
        return 0
    fi

    # No S3 object: a lambda target carries the same values as the
    # EnvironmentVariables parameter, which now lives in the target's
    # deployment_parameters.json like every other parameter. That is a change
    # to the repository, not to a bucket, so it has to be committed and pushed.
    file=$(parameter_value "$target" DeploymentParametersFilename)
    [[ -n "$file" && -f "$file" ]] \
        || die "ERROR: ${target} reads no environment file"
    jq -e '.Parameters | has("EnvironmentVariables")' "$file" > /dev/null 2>&1 \
        || die "ERROR: ${target} has no EnvironmentVariables parameter"

    local tmp
    tmp=$(mktemp)
    jq --arg env "$(env_to_json "$CONFIG_FILE_NAME" | tr -s ' \n' ' ')" \
        '.Parameters.EnvironmentVariables = $env' "$file" > "$tmp" && mv "$tmp" "$file"

    echo "wrote ${CONFIG_FILE_NAME} into ${file} (EnvironmentVariables)"
    echo "  it deploys with the template - commit and push it"
}

# The newest release in the template bucket. Empty if the bucket cannot be
# listed - being offline must not stop a validate.
#
# Sorted numerically field by field rather than with sort -V, which BSD sort
# does not reliably have: v1.10.14 must beat v1.10.2, and a lexical sort puts
# them the other way round.
latest_template_version() {
    aws s3 ls "s3://${TEMPLATE_BUCKET}/" 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -u \
        | sed 's/^v//' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1 \
        | sed 's/^/v/'
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
        local latest
        latest=$(latest_template_version)

        for file in $(deployment_files); do
            current=$(nested_version "$file")
            if [[ -n "$latest" && -n "$current" && "$current" != "$latest" ]]; then
                printf '  %-42s %-10s behind %s\n' "$file" "${current}" "$latest"
            else
                printf '  %-42s %s\n' "$file" "${current:-none}"
            fi
        done

        [[ -n "$latest" ]] && echo "  latest published: ${latest}"
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
    # The deployment templates carry no defaults any more - every parameter is
    # supplied by the target's deployment_parameters.json - so the version
    # lives there too. The argument is still a deployment template, so callers
    # do not change; it is mapped to the parameters file beside it.
    local file=$1 parameters
    parameters="$(dirname "$file")/deployment_parameters.json"
    [[ -f "$parameters" ]] || return 0
    jq -r '.Parameters.TemplateVersion // empty' "$parameters" 2>/dev/null || true
}

# Rewrite the TemplateVersion default of one deployment template.
#
#   set_nested_version targets/lambda/deployment.yaml v1.10.3
#
set_nested_version() {
    local file=$1 version=$2 parameters tmp
    parameters="$(dirname "$file")/deployment_parameters.json"
    [[ -f "$parameters" ]] || return 0
    tmp=$(mktemp)
    jq --arg version "$version" '.Parameters.TemplateVersion = $version' "$parameters" > "$tmp" \
        && mv "$tmp" "$parameters"
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
local_build() {
    local target="${1:-$TARGET}"
    require_command docker

    local dockerfile base_image platform tag
    tag=$(image_tag "$target")
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

    if [[ "$base_image" == public.ecr.aws/* ]] && command -v aws > /dev/null 2>&1; then
        ecr_public_login
    fi

    echo "building ${tag} from ${dockerfile} (${base_image}, ${platform})"
    # ${a[@]+"${a[@]}"} - bash 3.2, which macOS ships, treats an empty array
    # as unset under set -u.
    docker build \
        --platform "$platform" \
        ${ssh_args[@]+"${ssh_args[@]}"} \
        --build-arg BASE_IMAGE_URI="$base_image" \
        -t "$tag" \
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
#   RUN_ENV="SECRET_NAME=my-settings DEBUG=1" run "" src.main_lambda.lambda_handler_1 lambda
#
local_run() {
    local entrypoint=$1 cmd=$2 target="${3:-$TARGET}"
    require_args 2 $# "run <entrypoint> <cmd> [target]"
    require_command docker

    local_build "$target"

    local port target_port
    port=$(local_port "$target")
    target_port=$(container_port "$target")

    docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true

    # Neither given means the image's own ENTRYPOINT/CMD runs - a value nobody
    # chose. For the python service image that is a bare `python3`, which reads
    # EOF, exits 0 and logs nothing, so the run looks like it did something.
    if [[ -z "$entrypoint" && -z "$cmd" ]]; then
        local image_entrypoint image_cmd
        image_entrypoint=$(docker inspect --format '{{json .Config.Entrypoint}}' "$(image_tag "$target")" 2>/dev/null)
        image_cmd=$(docker inspect --format '{{json .Config.Cmd}}' "$(image_tag "$target")" 2>/dev/null)
        # Quote back what THIS target deploys rather than an example from
        # another one - the three targets take entirely different arguments,
        # and a lambda handler pasted into a service run does nothing useful.
        local want_entrypoint want_cmd deployment_file target_arg=""
        deployment_file=$(parameter_value "$target" DeploymentCfnFilename)
        want_entrypoint=$(container_run_value "$target" ContainerEntryPoint)
        want_cmd=$(container_run_value "$target" ContainerCmd)
        # Named only when it is not the project's own target. Compared against
        # project.env rather than $TARGET, which carries the override.
        [[ "$target" != "$(declared_target)" ]] && target_arg=" TARGET=${target}"

        if [[ -n "$want_cmd" ]]; then
            die "ERROR: no ENTRYPOINT and no CMD - the image would run its own default (entrypoint ${image_entrypoint:-?}, cmd ${image_cmd:-?}).
  ${target} deploys this, from ${deployment_file}:
    make local-run ENTRYPOINT=\"${want_entrypoint}\" CMD=\"${want_cmd}\"${target_arg}"
        fi

        die "ERROR: no ENTRYPOINT and no CMD - the image would run its own default (entrypoint ${image_entrypoint:-?}, cmd ${image_cmd:-?}).
  What this target runs is ContainerEntryPoint and ContainerCmd in ${deployment_file}; drop the CloudFormation quotes:
    make local-run ENTRYPOINT=<entrypoint> CMD=\"<arguments>\"${target_arg}"
    fi

    local entrypoint_args=()
    [[ -n "$entrypoint" ]] && entrypoint_args=(--entrypoint "$entrypoint")

    echo "running: ${entrypoint:-<image entrypoint>} ${cmd}"

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
        "$(image_tag "$target")" ${cmd} > /dev/null

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
        echo "logs:   make local-logs"
        echo "stop:   make local-stop"
        return 0
    fi

    # It died. The reason is in the container's log and nowhere else, so print
    # it rather than asking for another command - an image that fails on import
    # or on a missing environment variable is the common case, and "exited (1)"
    # on its own says nothing.
    local status output
    status=$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null)
    echo "${CONTAINER_NAME} exited (${status:-unknown}) - nothing is listening on ${port}"
    echo ""

    output=$(docker logs --tail 40 "$CONTAINER_NAME" 2>&1)
    if [[ -n "$output" ]]; then
        echo "$output" | sed 's/^/    /'
    else
        echo "    (no output - the process wrote nothing before exiting)"
    fi
    echo ""
    echo "full log: make local-logs        (the container is left in place)"

    # A task that ran to completion exits 0; only a non-zero status is a
    # failure to report as one.
    [[ "$status" == "0" ]] && return 0
    return 1
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
#   local-stop
#
local_stop() {
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
  lint                                        static checks: the source, and
                                              cfn-lint over every template
  validate       [target]                     cicd + deployment templates
  deploy-cicd    [target]                     create/update the pipeline stack
  config         [target]                     where the environment file is read
                                              from, and whether it is there
  sync-config    [target]                     put it where the deployment reads
                                              it - the pipeline never does
  remote                                      point git remote at CodeCommit
  upload         <host> <directory>           rsync this project to a remote
                                              host; DRY_RUN=1 to preview
  push           <branch>                     push <branch> to CodeCommit main,
                                              which starts the pipeline
  pipeline                                    stage states, with the time each
                                              last changed
  pipeline-errors                             why the last run failed, and
                                              where the detail lives
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
  delete-all                                  both, service first; lists them
                                              and asks once

local docker
  local-build    [target]
  local-run      <entrypoint> <cmd> [target]  build, then run detached
                                              RUN_ENV="K=V K2=V2" for app env vars
  invoke         [json]                       POST to the local lambda emulator
  local-logs
  shell
  local-stop

Defaults: PROJECT_NAME=${PROJECT_NAME} TARGET=${TARGET} AWS_PROFILE=${AWS_PROFILE}
Declared in project.env. Override any of them for a single run.

  PROJECT_NAME=lambda-test-1 make deploy-cicd lambda

RUN_ENV is the environment the container's own code reads - the container gets
only the AWS variables otherwise. It REPLACES the default (currently
"${RUN_ENV:-<unset>}"), so keep anything you still need:

  make local-run ENTRYPOINT={{RUN_ENTRYPOINT_SERVER}} CMD="{{RUN_CMD_SERVER}}" \\
      RUN_ENV="MODE=local SECRET_NAME=my-service-settings"

A service with no local mode needs whatever it actually reads at startup,
MODE included or not:

  make local-run ENTRYPOINT={{RUN_ENTRYPOINT_SERVER}} CMD="{{RUN_CMD_SERVER}}" \\
      RUN_ENV="SECRET_NAME=my-service-api-keys LOG_LEVEL=debug"

It is a space-separated KEY=VALUE list; a value containing spaces needs
docker run by hand.
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
    lint)           lint              ;;
    validate)       validate     "$@" ;;
    deploy-cicd)    deploy_cicd  "$@" ;;
    remote)         remote            ;;
    config)         config       "$@" ;;
    sync-config)    sync_config  "$@" ;;
    upload)         upload       "$@" ;;
    push)           push         "$@" ;;
    pipeline)       pipeline          ;;
    pipeline-errors) pipeline_errors  ;;
    pipeline-stop)  pipeline_stop     ;;
    outputs)        outputs      "$@" ;;
    output-value)   output_value "$@" ;;
    url)            url               ;;
    events)         events       "$@" ;;
    logs)           logs         "$@" ;;
    delete-stack)   delete_stack      ;;
    delete-cicd)    delete_cicd       ;;
    delete-all)     delete_all        ;;
    local-build)    local_build  "$@" ;;
    local-run)      local_run    "$@" ;;
    invoke)         invoke       "$@" ;;
    local-logs)     local_logs        ;;
    shell)          shell             ;;
    local-stop)     local_stop        ;;
    aws-info)       aws_info          ;;
    help|-h|--help) help              ;;
    *)              echo "ERROR: unknown command '${command}'" >&2
                    echo "" >&2
                    help >&2
                    exit 1 ;;
esac
