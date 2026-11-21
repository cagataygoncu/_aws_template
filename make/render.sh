#!/usr/bin/env bash
# render.sh - render one project from any version of this template.
#
# Usage:
#     ./make/render.sh <ref> <language> <project_name> <destination>
#
# <ref>   a git ref of this template (v1.0.0, a commit, HEAD), or `.` for the
#         working tree, uncommitted changes included.
#
# A ref is rendered from `git archive`, never from the working tree, so the
# result is what that version produced, whatever is checked out now. Its own
# make/bootstrap.sh does the work: an old version renders with its old rules.
# The render then gets a .template.env naming the ref's commit, which an
# archive cannot work out for itself.
#
# LANGUAGE_VERSION and OTP_VERSION are cleared, so a render gets the version's
# defaults. Pass RENDER_LANGUAGE_VERSION / RENDER_OTP_VERSION to set them -
# an upgrade does, for a project stamped before versions moved to mise.toml.
#
# Used by render_all.sh and upgrade.sh.

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $(basename "$0") <ref|.> <language> <project_name> <destination>" >&2
    exit 1
fi

ref=$1
language=$2
project_name=$3
destination=$4

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
template_dir=$(dirname "$script_dir")

run_bootstrap() {
    local bootstrap=$1
    env -u LANGUAGE_VERSION -u OTP_VERSION \
        ${RENDER_LANGUAGE_VERSION:+LANGUAGE_VERSION="$RENDER_LANGUAGE_VERSION"} \
        ${RENDER_OTP_VERSION:+OTP_VERSION="$RENDER_OTP_VERSION"} \
        "$bootstrap" "$language" "$project_name" "$destination" > /dev/null
}

if [[ "$ref" == . ]]; then
    run_bootstrap "$template_dir/make/bootstrap.sh"
    exit 0
fi

commit=$(git -C "$template_dir" rev-parse --verify --quiet "${ref}^{commit}") \
    || { echo "Error: '$ref' is not a commit of this template" >&2; exit 2; }
version=$(git -C "$template_dir" describe --tags --always "$commit")

archive_dir=$(mktemp -d)
trap 'rm -rf "${archive_dir:?}"' EXIT
git -C "$template_dir" archive "$commit" | tar -x -C "$archive_dir"

[[ -x "$archive_dir/make/bootstrap.sh" ]] \
    || { echo "Error: $version has no make/bootstrap.sh" >&2; exit 2; }
run_bootstrap "$archive_dir/make/bootstrap.sh"

# The archive is not a git checkout, so its bootstrap stamped "unknown" (or,
# before stamps existed, nothing). The version is known here.
{
    echo "# The template version this project was generated from, and the answers"
    echo "# given. Rewritten by every template upgrade; do not edit by hand."
    printf 'TEMPLATE_VERSION=%q\n' "$version"
    printf 'LANGUAGE=%q\n' "$language"
    printf 'PROJECT_NAME=%q\n' "$project_name"
} > "$destination/.template.env"
