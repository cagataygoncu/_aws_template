#!/usr/bin/env bash
# bootstrap.sh — scaffold a new AWS service project from this template.
#
# Usage:
#     ./make/bootstrap.sh <language> <project_name> [destination_dir]
#
# <language>      a folder with a layer.env: python | golang | typescript | cpp | nextjs | elixir
# <project_name>  snake_case (e.g. my_cool_service)
# [destination_dir]  optional; defaults to ../<project_name> relative to this script
#
# Behaviour:
#   1. Validates language and project name.
#   2. Copies _base/ into the destination.
#   3. Overlays <language>/ on top (rsync, language layer wins on conflicts).
#   4. Substitutes a few common placeholders in text files, including the
#      language's base container images. The values come from
#      <language>/layer.env.
#   5. Writes .template.env: the template version and the answers this
#      project was made from, so the same render can be repeated later.

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

# A language is any folder holding a layer.env, so adding one needs no edit
# here. A project scaffolded inside the template has no layer.env (it is never
# shipped), so it does not show up as a language.
valid_languages=()
for layer in "$template_dir"/*/layer.env; do
    valid_languages+=("$(basename "$(dirname "$layer")")")
done
if [[ ! "$language" =~ ^[a-z]+$ || ! -f "$template_dir/$language/layer.env" ]]; then
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
# placeholders; <language>/layer.env fills them in. Every layer.env sets:
#
#   language_tool        the mise.toml entry LANGUAGE_VERSION=... overrides.
#                        Versions are not set here: they live in
#                        <language>/mise.toml, which ships to the project and
#                        stays its one record of them. One project can start
#                        on another version:
#                        make new python my_project LANGUAGE_VERSION=3.13
#                        (and OTP_VERSION=... for elixir's erlang entry)
#   base_image_lambda    runtime image the deployed function runs on, as a
#   base_image_service   pattern: image a long-running container runs on.
#                        Both name the version as \${mise:<tool>}, resolved
#                        from the project's mise.toml at build time
#   container_cmd_lambda the handler the lambda base image invokes
#   container_port       the port that image's app listens on (its EXPOSE)
#   container_workdir    where that image leaves the built artefact
#   container_*_task     how ECS starts the service/task target
#   container_*_server   how ECS starts the service/server target
#   run_*                shell-ready twins of the container_* values, for the
#                        README's `make local-run` examples
#   lint_tool, lint_command, lint_install    what `make lint` runs
#   healthcheck_command  what the container health check runs; empty = none
#   test_command         `make test`: the unit tests, run in the service base
#                        image; empty = the layer has none yet
#   test_masks           folders `make test` keeps off the host (a throwaway
#                        volume each), such as node_modules
#   supported_targets    optional; the targets the layer can serve
#   next_steps           the build/test line printed once the project exists
#
# The cmd values include their own YAML quoting, and a !Sub only where they
# reference a CloudFormation parameter - an unnecessary !Sub is a cfn-lint
# warning. \${ContainerPort} is escaped so the shell leaves it for CFN.

# Which deployment targets this language layer can actually serve. Anything
# not listed is deleted after the overlay rather than shipped broken: a target
# directory that cannot build is worse than a missing one, because it looks
# deployable until the pipeline fails. A layer.env may override it.
supported_targets="lambda service/task service/server"

# Each layer's values live in its own layer.env, not in a case block here, so
# a future upgrade script can read exactly the values a past render used.
# shellcheck source=/dev/null
source "$language_dir/layer.env"

if [[ ! -d "$base_dir" ]]; then
    echo "Error: _base/ not found at $base_dir" >&2
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
    --exclude='.venv'
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
    # The layer's notes: joined into NOTES.md below, not shipped on their own.
    --exclude='notes_language.md'
    # The layer's placeholder values: input to this script, not project code.
    # What a project needs to repeat the render is in .template.env instead.
    --exclude='layer.env'
)

echo ">>> Copying _base/ -> destination"
rsync -a "${rsync_excludes[@]}" "$base_dir/" "$destination_dir/"

echo ">>> Overlaying $language/ -> destination"
# The layer's gitignore is joined to _base's below, not copied over it.
rsync -a "${rsync_excludes[@]}" --exclude='/gitignore' "$language_dir/" "$destination_dir/"

# The project's .gitignore is _base/gitignore (shared: venv, OS files, local
# secrets) followed by <language>/gitignore. Both are stored without the dot:
# a real .gitignore would also act on this template repo - nextjs's ignores
# .env.local, so git never tracked the .env.local every nextjs project needs.
if [[ -f "$destination_dir/gitignore" ]]; then
    {
        cat "$destination_dir/gitignore"
        if [[ -f "$language_dir/gitignore" ]]; then
            echo
            echo "# ---- $language ----"
            echo
            cat "$language_dir/gitignore"
        fi
    } > "$destination_dir/.gitignore"
    rm -f "$destination_dir/gitignore"
fi

# NOTES.md: the shared notes, with the language's section in place of the
# {{LANGUAGE_NOTES}} line. The layer keeps it as notes_language.md, so a
# project has one notes file, not two.
if [[ -f "$destination_dir/NOTES.md" ]]; then
    notes_tmp=$(mktemp)
    awk -v notes="$language_dir/notes_language.md" '
        $0 == "{{LANGUAGE_NOTES}}" {
            while ((getline line < notes) > 0) print line
            next
        }
        { print }
    ' "$destination_dir/NOTES.md" > "$notes_tmp"
    cat "$notes_tmp" > "$destination_dir/NOTES.md"
    rm -f "$notes_tmp"
fi

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

# Escaped once here, not once per file: each is a subshell and a sed.
lint_tool_sed=$(sed_replacement "$lint_tool")
lint_command_sed=$(sed_replacement "$lint_command")
lint_install_sed=$(sed_replacement "$lint_install")
healthcheck_command_sed=$(sed_replacement "$healthcheck_command")
test_command_sed=$(sed_replacement "$test_command")
test_masks_sed=$(sed_replacement "$test_masks")

substitute_in_file() {
    local file=$1
    local tmp
    tmp=$(mktemp)
    # | as the sed delimiter: the image URIs contain slashes.
    sed \
        -e "s/{{PROJECT_NAME}}/$project_name/g" \
        -e "s/{{LANGUAGE}}/$language/g" \
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
        -e "s|{{LINT_TOOL}}|$lint_tool_sed|g" \
        -e "s|{{LINT_COMMAND}}|$lint_command_sed|g" \
        -e "s|{{LINT_INSTALL}}|$lint_install_sed|g" \
        -e "s|{{HEALTHCHECK_COMMAND}}|$healthcheck_command_sed|g" \
        -e "s|{{TEST_COMMAND}}|$test_command_sed|g" \
        -e "s|{{TEST_MASKS}}|$test_masks_sed|g" \
        "$file" > "$tmp" && cat "$tmp" > "$file"
    # cat back into the original rather than mv over it: mv gives the file
    # mktemp's 0600, which silently stripped the executable bit from
    # make/commands.sh in every project this ever bootstrapped.
    rm -f "$tmp"
}

echo ">>> Substituting placeholders (project name, language, images, entrypoints)"
while IFS= read -r -d '' file; do
    if grep -qE '\{\{(PROJECT_NAME|LANGUAGE|BASE_IMAGE_[A-Z]+|CONTAINER_[A-Z_]+|RUN_[A-Z_]+|LINT_[A-Z_]+|HEALTHCHECK_COMMAND|TEST_COMMAND|TEST_MASKS)\}\}' "$file" 2>/dev/null; then
        substitute_in_file "$file"
    fi
done < <(find "$destination_dir" -type f \
            -not -path '*/.git/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/_build/*' \
            -not -path '*/deps/*' \
            -print0)

# ---- tool versions ----------------------------------------------------------
# The project's mise.toml came with the layer. A version asked for on the
# command line goes into it, then every synced line (Dockerfile FROM,
# devcontainer.json, go.mod, ...) is written from it - the same
# `make sync-versions` the project runs after its own version bumps.

versions() {
    (cd "$destination_dir" && ./make/versions.sh "$@")
}

echo ">>> Writing tool versions from mise.toml"
if [[ -n "${LANGUAGE_VERSION:-}" ]]; then
    versions set "$language_tool" "$LANGUAGE_VERSION" | sed 's/^/    /'
fi
if [[ -n "${OTP_VERSION:-}" ]]; then
    versions set erlang "$OTP_VERSION" | sed 's/^/    /'
fi
versions sync > /dev/null

# ---- stamp ----------------------------------------------------------------
# .template.env records what this project was made from: the template version
# (a tag, or git describe output, which git resolves back to the commit) and
# the answers given here. That is all a later upgrade needs to repeat this
# exact render, then the render of a newer version, and merge the difference
# into the project. The layer values are not copied in: they follow from the
# commit. Tool versions are not answers either: they live in the project's
# mise.toml, which the template owns, so an upgrade moves a project that kept
# the old default to the new one, and keeps a version the project chose.
#
# A render from uncommitted template changes cannot be repeated: git describe
# marks it -dirty, and an upgrade refuses such a stamp.

template_version=unknown
if git -C "$template_dir" rev-parse --git-dir > /dev/null 2>&1; then
    template_version=$(git -C "$template_dir" describe --tags --always --dirty)
fi

{
    echo "# The template version of this project. Do not edit by hand."
    printf 'TEMPLATE_VERSION=%q\n' "$template_version"
    printf 'LANGUAGE=%q\n' "$language"
    printf 'PROJECT_NAME=%q\n' "$project_name"
} > "$destination_dir/.template.env"

echo
echo "Done. Project scaffolded at:"
echo "    $destination_dir"
echo
echo "Template:  ${template_version}"
if [[ "$template_version" == unknown || "$template_version" == *-dirty ]]; then
    echo "    warning: the template had uncommitted changes (or is not a git"
    echo "    checkout), so .template.env cannot reproduce this render. Commit"
    echo "    the template first if this project is meant to be upgradable."
fi
echo "Toolchain (mise.toml):"
versions show | sed 's/^/    /'
echo "    service image  $(versions expand "$base_image_service")"
echo "    lambda image   $(versions expand "$base_image_lambda")"
echo
echo "Next steps:"
echo "    cd $destination_dir"
echo "    make local-dev-setup        # mise install; needs mise"
echo "    ${next_steps}"
echo "    Open in VS Code -> Reopen in Container"
echo
echo "Then, in the new project:"
echo "    make help                   # every deploy / local-run command"
echo "    make template-version       # gig-cfn-templates release inherited from the template"
echo "    Set TARGET in project.env: lambda, task or server."
echo
echo "Review targets/ and remove the deployment targets you don't need"
echo "(e.g. nextjs typically only needs targets/service/server)."
