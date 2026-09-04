#!/usr/bin/env bash
# bootstrap.sh — scaffold a new AWS service project from this template.
#
# Usage:
#     ./make/bootstrap.sh <language> <project_name> [destination_dir]
#
# <language>      one of: python | golang | typescript | cpp | nextjs | elixir
# <project_name>  snake_case (e.g. my_cool_service)
# [destination_dir]  optional; defaults to ../<project_name> relative to this script
#
# Behaviour:
#   1. Validates language and project name.
#   2. Copies _base/ into the destination.
#   3. Overlays <language>/ on top (rsync, language layer wins on conflicts).
#   4. Substitutes a few common placeholders in text files, including the
#      language's base container images.

set -euo pipefail

# ---- args ---------------------------------------------------------------

if [[ $# -lt 2 || $# -gt 3 ]]; then
    cat >&2 <<EOF
Usage: $(basename "$0") <language> <project_name> [destination_dir]

  language        python | golang | typescript | cpp | nextjs | elixir
  project_name    snake_case (e.g. my_cool_service)
  destination_dir optional; defaults to ../<project_name>
EOF
    exit 1
fi

language=$1
project_name=$2
# This script lives in make/; the layers it copies are one level up, and the
# default destination is a sibling of the template itself.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
template_dir=$(dirname "$script_dir")
destination_dir=${3:-"$(dirname "$template_dir")/$project_name"}

# ---- validation ---------------------------------------------------------

valid_languages=(python golang typescript cpp nextjs elixir)
language_ok=false
for lang in "${valid_languages[@]}"; do
    if [[ "$language" == "$lang" ]]; then
        language_ok=true
        break
    fi
done
if [[ "$language_ok" != true ]]; then
    echo "Error: unknown language '$language'. Valid: ${valid_languages[*]}" >&2
    exit 2
fi

if [[ ! "$project_name" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "Error: project_name must be snake_case (e.g. my_cool_service)" >&2
    exit 3
fi

base_dir="$template_dir/_base"
language_dir="$template_dir/$language"

# ---- language-specific deployment values ---------------------------------
# The CFN target scaffolding is language-agnostic except for the handful of
# values that name the language's own image and entrypoints. _base/ carries
# placeholders; the language fills them in.
#
#   language_version     the toolchain version, single source for this
#                        language: the image tags below are built from it and
#                        it is substituted into environment.yaml, the
#                        devcontainer Dockerfile and the lambda builder image.
#                        Each default can be overridden for one project:
#                        make new python my_project LANGUAGE_VERSION=3.13
#   otp_version          elixir only, the OTP release its image is tagged with
#   base_image_lambda    runtime image the deployed function runs on
#   base_image_service   image a long-running container is built on and runs on
#   container_cmd_lambda the handler the lambda base image invokes
#   container_port       the port that image's app listens on (its EXPOSE)
#   container_workdir    where that image leaves the built artefact
#   container_*_task     how ECS starts the service/task target
#   container_*_server   how ECS starts the service/server target
#
# The cmd values include their own YAML quoting, and a !Sub only where they
# reference a CloudFormation parameter - an unnecessary !Sub is a cfn-lint
# warning. \${ContainerPort} is escaped so the shell leaves it for CFN.

# Which deployment targets this language layer can actually serve. Anything
# not listed is deleted after the overlay rather than shipped broken: a target
# directory that cannot build is worse than a missing one, because it looks
# deployable until the pipeline fails. Overridden per language below.
supported_targets="lambda service/task service/server"

case "$language" in
    python)
        language_version="${LANGUAGE_VERSION:-3.12}"
        base_image_lambda="public.ecr.aws/lambda/python:${language_version}"
        base_image_service="public.ecr.aws/docker/library/python:${language_version}"
        # src/ and lib/ sit at / with PYTHONPATH=/
        container_cmd_lambda="src.main_lambda.lambda_handler_1"
        container_port="5040"
        container_workdir="/"
        container_entrypoint_task="python"
        container_cmd_task="'src/main_task.py'"
        container_entrypoint_server="uvicorn"
        container_cmd_server="!Sub 'src.main_server:app --host 0.0.0.0 --port \${ContainerPort}'"
        # Shell-ready twins of the container_* values above, for the README's
        # `make local-run` examples: those carry CloudFormation quoting, and python's
        # server value is a !Sub expression, so neither can be pasted.
        run_entrypoint_task="python"
        run_cmd_task="src/main_task.py"
        run_entrypoint_server="uvicorn"
        run_cmd_server="src.main_server:app --host 0.0.0.0 --port ${container_port}"
        run_cmd_lambda="src.main_lambda.lambda_handler_1"
        # `make lint` - the static checks this language runs before a
        # build. Empty would mean the project has no linter.
        lint_tool="ruff"
        lint_command="ruff check . && ruff format --check ."
        lint_install="pip install ruff, or conda install -c conda-forge ruff"
        ;;
    golang)
        # 1.26 is the floor: aws-lambda-go v1.55 and gopls both require it.
        language_version="${LANGUAGE_VERSION:-1.26}"
        base_image_lambda="public.ecr.aws/lambda/provided:al2023"
        base_image_service="public.ecr.aws/docker/library/golang:${language_version}-bookworm"
        # A compiled binary takes no arguments, but the ECS module splits the
        # cmd into the container's Command and cannot take an empty one - so
        # env runs the binary, exec-ing it, which keeps it PID 1.
        container_cmd_lambda="bootstrap"
        container_port="5040"
        container_workdir="/app/build"
        container_entrypoint_task="/usr/bin/env"
        # One binary per entrypoint, the same shape as python's
        # src/main_task.py and src/main_server.py - so the command picks the
        # target rather than the binary having to work out which it is.
        container_cmd_task="'/app/build/task'"
        container_entrypoint_server="/usr/bin/env"
        container_cmd_server="'/app/build/server'"
        # Shell-ready twins of the container_* values above, for the README's
        # `make local-run` examples: those carry CloudFormation quoting, and python's
        # server value is a !Sub expression, so neither can be pasted.
        run_entrypoint_task="/usr/bin/env"
        run_cmd_task="/app/build/task"
        run_entrypoint_server="/usr/bin/env"
        run_cmd_server="/app/build/server"
        run_cmd_lambda="bootstrap"
        # `make lint` - the static checks this language runs before a
        # build. Empty would mean the project has no linter.
        lint_tool="go"
        # gofmt -l exits 0 whatever it finds, so the grep is what fails the
        # command - and it still prints which files need formatting.
        lint_command="go vet ./... && ! gofmt -l src tests | grep ."
        lint_install="the Go toolchain is the linter here - install Go, or open the devcontainer"
        ;;
    cpp)
        # No single toolchain version: the images are named by distro release.
        language_version="${LANGUAGE_VERSION:-bookworm}"
        base_image_lambda="public.ecr.aws/lambda/provided:al2023"
        base_image_service="public.ecr.aws/docker/library/debian:${language_version}"
        container_cmd_lambda="bootstrap"
        container_port="5040"
        container_workdir="/app/build"
        container_entrypoint_task="/usr/bin/env"
        container_cmd_task="'/app/build/main'"
        container_entrypoint_server="/usr/bin/env"
        container_cmd_server="'/app/build/main'"
        # Shell-ready twins of the container_* values above, for the README's
        # `make local-run` examples: those carry CloudFormation quoting, and python's
        # server value is a !Sub expression, so neither can be pasted.
        run_entrypoint_task="/usr/bin/env"
        run_cmd_task="/app/build/main"
        run_entrypoint_server="/usr/bin/env"
        run_cmd_server="/app/build/main"
        run_cmd_lambda="bootstrap"
        # `make lint` - the static checks this language runs before a
        # build. Empty would mean the project has no linter.
        lint_tool="clang-format"
        # \$( ) escaped so bootstrap writes the substitution out rather than
        # running it here, where there is no src/ to find.
        lint_command="clang-format --dry-run --Werror \$(find src tests -name '*.cpp' -o -name '*.hpp' -o -name '*.h')"
        lint_install="apt-get install clang-format, or brew install clang-format"
        ;;
    typescript)
        language_version="${LANGUAGE_VERSION:-22}"
        base_image_lambda="public.ecr.aws/lambda/nodejs:${language_version}"
        base_image_service="public.ecr.aws/docker/library/node:${language_version}-bookworm-slim"
        # tsc keeps the source tree under build/, so src/main_task.ts becomes
        # build/src/main_task.js - the path the images run.
        container_cmd_lambda="build/src/main_lambda.handler"
        container_port="5040"
        container_workdir="/app"
        container_entrypoint_task="node"
        container_cmd_task="'build/src/main_task.js'"
        container_entrypoint_server="node"
        container_cmd_server="'build/src/main_server.js'"
        # Shell-ready twins of the container_* values above, for the README's
        # `make local-run` examples: those carry CloudFormation quoting, and python's
        # server value is a !Sub expression, so neither can be pasted.
        run_entrypoint_task="node"
        run_cmd_task="build/src/main_task.js"
        run_entrypoint_server="node"
        run_cmd_server="build/src/main_server.js"
        run_cmd_lambda="build/src/main_lambda.handler"
        # `make lint` - the static checks this language runs before a
        # build. Empty would mean the project has no linter.
        lint_tool="npx"
        # Types first: eslint checks style, not types, and a type error is the
        # one that stops the build.
        lint_command="npx tsc --noEmit && npx eslint ."
        lint_install="install Node, or open the devcontainer"
        ;;
    nextjs)
        language_version="${LANGUAGE_VERSION:-20}"
        base_image_lambda="public.ecr.aws/lambda/nodejs:${language_version}"
        base_image_service="public.ecr.aws/docker/library/node:${language_version}-bookworm-slim"
        container_cmd_lambda="src/lambda.handler"
        container_port="3000"
        container_workdir="/app"
        container_entrypoint_task="node"
        container_cmd_task="'server.mjs'"
        container_entrypoint_server="node"
        container_cmd_server="'server.mjs'"
        # Shell-ready twins of the container_* values above, for the README's
        # `make local-run` examples: those carry CloudFormation quoting, and python's
        # server value is a !Sub expression, so neither can be pasted.
        run_entrypoint_task="node"
        run_cmd_task="server.mjs"
        run_entrypoint_server="node"
        run_cmd_server="server.mjs"
        run_cmd_lambda="src/lambda.handler"
        # `make lint` - the static checks this language runs before a
        # build. Empty would mean the project has no linter.
        # A Next.js app is a server. The lambda target existed but never
        # worked - its Dockerfile ran src/lambda.handler, and no such file was
        # ever built - so the layer does not offer it.
        supported_targets="service/task service/server"
        lint_tool="npx"
        # tsc first: next lint checks style, not types, and a type error is the
        # one that stops the build. .eslintrc.json ships with the layer so
        # next lint does not stop to ask how to configure itself.
        lint_command="npx tsc --noEmit && npm run lint"
        lint_install="install Node, or open the devcontainer"
        ;;
    elixir)
        language_version="${LANGUAGE_VERSION:-1.19}"
        otp_version="${OTP_VERSION:-27}"
        base_image_lambda="public.ecr.aws/lambda/provided:al2023"
        base_image_service="public.ecr.aws/docker/library/elixir:${language_version}-otp-${otp_version}"
        # Release name: keep in step with the `app:` key in mix.exs.
        container_cmd_lambda="bootstrap"
        container_port="4000"
        container_workdir="/app"
        container_entrypoint_task="/app/bin/${project_name}"
        container_cmd_task="'start'"
        container_entrypoint_server="/app/bin/${project_name}"
        container_cmd_server="'start'"
        # Shell-ready twins of the container_* values above, for the README's
        # `make local-run` examples: those carry CloudFormation quoting, and python's
        # server value is a !Sub expression, so neither can be pasted.
        run_entrypoint_task="/app/bin/${project_name}"
        run_cmd_task="start"
        run_entrypoint_server="/app/bin/${project_name}"
        run_cmd_server="start"
        run_cmd_lambda="bootstrap"
        # `make lint` - the static checks this language runs before a
        # build. Empty would mean the project has no linter.
        lint_tool="mix"
        lint_command="mix format --check-formatted && mix compile --warnings-as-errors"
        lint_install="install Elixir, or open the devcontainer"
        ;;
esac

if [[ ! -d "$base_dir" ]]; then
    echo "Error: _base/ not found at $base_dir" >&2
    exit 4
fi
if [[ ! -d "$language_dir" ]]; then
    echo "Error: $language/ not found at $language_dir" >&2
    exit 4
fi
if [[ -e "$destination_dir" ]]; then
    echo "Error: destination '$destination_dir' already exists. Refusing to overwrite." >&2
    exit 5
fi

# ---- assembly -----------------------------------------------------------

echo ">>> Creating $destination_dir"
mkdir -p "$destination_dir"

# Common rsync excludes: never carry caches/build artefacts/OS junk.
rsync_excludes=(
    --exclude='.DS_Store'
    --exclude='__pycache__'
    --exclude='.pytest_cache'
    --exclude='.hypothesis'
    --exclude='venv'
    --exclude='.git/'
    --exclude='node_modules'
    --exclude='.next'
    --exclude='dist'
    --exclude='build'
    --exclude='_build'
    --exclude='deps'
    --exclude='.elixir_ls'
    --exclude='vendor'
    --exclude='*.pyc'
    --exclude='erl_crash.dump'
    # Each language layer documents itself in LAYER.md, for whoever maintains
    # this template. It describes the layer, not the project built from it, so
    # it must not ship - and it would overwrite _base/README.md if it did,
    # since the language layer rsyncs second.
    --exclude='LAYER.md'
)

echo ">>> Copying _base/ -> destination"
rsync -a "${rsync_excludes[@]}" "$base_dir/" "$destination_dir/"

echo ">>> Overlaying $language/ -> destination"
rsync -a "${rsync_excludes[@]}" "$language_dir/" "$destination_dir/"

# ---- targets this language cannot serve ---------------------------------
# _base ships all three, so anything the layer does not support is removed
# here rather than left to fail at deploy time.
for target in lambda service/task service/server; do
    case " $supported_targets " in
        *" $target "*) continue ;;
    esac
    if [[ -d "$destination_dir/targets/$target" ]]; then
        rm -rf "${destination_dir:?}/targets/$target"
        echo "    removed targets/$target - not supported by the $language layer"
    fi
    # The devcontainer variant that builds that target's image goes with it.
    if [[ "$target" == lambda && -d "$destination_dir/.devcontainer/lambda" ]]; then
        rm -rf "${destination_dir:?}/.devcontainer/lambda"
        echo "    removed .devcontainer/lambda"
    fi
done

# service/ holds only the Dockerfile the two service targets share, so it goes
# once both of them have.
if [[ -d "$destination_dir/targets/service" ]] \
    && [[ -z "$(find "$destination_dir/targets/service" -name cicd_parameters.json)" ]]; then
    rm -rf "${destination_dir:?}/targets/service"
    echo "    removed targets/service - no service target left to use it"
fi

# ---- placeholder substitution -------------------------------------------
# Replace a few obvious placeholders in text files. Conservative: only
# touches files that contain the exact tokens; portable sed across macOS
# and Linux by writing to a temp file.

# Escape a value so sed treats it as literal replacement text. Two characters
# bite here: & means "the whole match", so the && in a lint command would
# expand to the placeholder twice, and | is the delimiter these expressions
# use, so a pipe ends the s/// early and sed dies with "unterminated `s'
# command". A backslash escapes both, and itself.
sed_replacement() {
    printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

substitute_in_file() {
    local file=$1
    local tmp
    tmp=$(mktemp)
    # | as the sed delimiter: the image URIs contain slashes.
    sed \
        -e "s/{{PROJECT_NAME}}/$project_name/g" \
        -e "s/{{LANGUAGE}}/$language/g" \
        -e "s|{{LANGUAGE_VERSION}}|$language_version|g" \
        -e "s|{{OTP_VERSION}}|${otp_version:-}|g" \
        -e "s|{{BASE_IMAGE_LAMBDA}}|$base_image_lambda|g" \
        -e "s|{{BASE_IMAGE_SERVICE}}|$base_image_service|g" \
        -e "s|{{CONTAINER_CMD_LAMBDA}}|$container_cmd_lambda|g" \
        -e "s|{{CONTAINER_PORT}}|$container_port|g" \
        -e "s|{{CONTAINER_WORKDIR}}|$container_workdir|g" \
        -e "s|{{CONTAINER_ENTRYPOINT_TASK}}|$container_entrypoint_task|g" \
        -e "s|{{CONTAINER_CMD_TASK}}|$container_cmd_task|g" \
        -e "s|{{CONTAINER_ENTRYPOINT_SERVER}}|$container_entrypoint_server|g" \
        -e "s|{{CONTAINER_CMD_SERVER}}|$container_cmd_server|g" \
        -e "s|{{RUN_ENTRYPOINT_TASK}}|$run_entrypoint_task|g" \
        -e "s|{{RUN_CMD_TASK}}|$run_cmd_task|g" \
        -e "s|{{RUN_ENTRYPOINT_SERVER}}|$run_entrypoint_server|g" \
        -e "s|{{RUN_CMD_SERVER}}|$run_cmd_server|g" \
        -e "s|{{RUN_CMD_LAMBDA}}|$run_cmd_lambda|g" \
        -e "s|{{LINT_TOOL}}|$(sed_replacement "$lint_tool")|g" \
        -e "s|{{LINT_COMMAND}}|$(sed_replacement "$lint_command")|g" \
        -e "s|{{LINT_INSTALL}}|$(sed_replacement "$lint_install")|g" \
        "$file" > "$tmp" && cat "$tmp" > "$file"
    # cat back into the original rather than mv over it: mv gives the file
    # mktemp's 0600, which silently stripped the executable bit from
    # make/commands.sh in every project this ever bootstrapped.
    rm -f "$tmp"
}

echo ">>> Substituting placeholders (project name, language, images, entrypoints)"
while IFS= read -r -d '' file; do
    if grep -qE '\{\{(PROJECT_NAME|LANGUAGE|LANGUAGE_VERSION|OTP_VERSION|BASE_IMAGE_[A-Z]+|CONTAINER_[A-Z_]+|RUN_[A-Z_]+|LINT_[A-Z_]+)\}\}' "$file" 2>/dev/null; then
        substitute_in_file "$file"
    fi
done < <(find "$destination_dir" -type f \
            -not -path '*/.git/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/_build/*' \
            -not -path '*/deps/*' \
            -print0)

echo
echo "Done. Project scaffolded at:"
echo "    $destination_dir"
echo
echo "Toolchain: ${language} ${language_version}${otp_version:+ / OTP ${otp_version}}"
echo "    service image  ${base_image_service}"
echo "    lambda image   ${base_image_lambda}"
echo
echo "Next steps:"
echo "    cd $destination_dir"
echo "    make local-dev-setup && micromamba activate ./venv"
case "$language" in
    python)
        echo "    python -m pytest tests/unit"
        ;;
    golang)
        echo "    go mod tidy && go test ./tests/..."
        ;;
    cpp)
        echo "    cmake -S . -B build && cmake --build build"
        ;;
    typescript)
        echo "    npm install && npm run build && npm test"
        ;;
    nextjs)
        echo "    npm install && npm run dev"
        ;;
    elixir)
        echo "    mix deps.get && mix test"
        ;;
esac
echo "    Open in VS Code -> Reopen in Container"
echo
echo "Then, in the new project:"
echo "    make help                   # every deploy / local-run command"
echo "    make template-version       # gig-cfn-templates release inherited from the template"
echo "    Set TARGET in project.env: lambda, task or server."
echo
echo "Review targets/ and remove the deployment targets you don't need"
echo "(e.g. nextjs typically only needs targets/service/server)."
