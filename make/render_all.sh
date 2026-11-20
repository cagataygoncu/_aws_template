#!/usr/bin/env bash
# render_all.sh - render every language and check each result.
#
# Usage (from the template root):
#     ./make/render_all.sh                    working tree, every language
#     REF=v1.0.0 ./make/render_all.sh         a released version
#     OUT=/tmp/renders ./make/render_all.sh   keep the renders, to diff two refs
#     LANGUAGES="python golang" ./make/render_all.sh
#     LINT=1 BUILD=1 ./make/render_all.sh     also run each project's checks
#
# A change to _base/ reaches every language at once, so this is how a template
# change is proven: each language is rendered as demo_app, then checked.
#
#   placeholders  no {{UPPER_CASE}} token left unfilled
#   versions      every mise-sync line agrees with mise.toml
#   scripts       make/*.sh parse (bash -n; zsh -n for the zsh one)
#   json          every strict JSON file parses (devcontainer.json and
#                 .vscode/ are JSON with comments, and are skipped)
#   cfn-lint      every CloudFormation template, if cfn-lint is installed
#   lint          LINT=1: the language's own `make lint` source check, if its
#                 tool is installed (eslint and mix need their deps first)
#   build         BUILD=1: `make local-build` for every target (docker)
#
# A check whose tool is missing is reported as skipped, not passed. Exits 1 if
# any check failed.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
template_dir=$(dirname "$script_dir")

REF="${REF:-.}"
LINT="${LINT:-}"
BUILD="${BUILD:-}"

if [[ -n "${OUT:-}" ]]; then
    out_dir=$OUT
    if [[ -e "$out_dir" ]]; then
        echo "Error: OUT=$out_dir already exists" >&2
        exit 2
    fi
    mkdir -p "$out_dir"
else
    out_dir=$(mktemp -d)
    trap 'rm -rf "${out_dir:?}"' EXIT
fi

if [[ -n "${LANGUAGES:-}" ]]; then
    # shellcheck disable=SC2206 - a space-separated list, split on purpose.
    languages=($LANGUAGES)
else
    languages=()
    for layer in "$template_dir"/*/layer.env; do
        languages+=("$(basename "$(dirname "$layer")")")
    done
fi

failures=0
results=()

# Record one check's outcome: ok, FAIL or skipped.
record() {
    local language=$1 check=$2 outcome=$3
    results+=("$(printf '%-11s %-13s %s' "$language" "$check" "$outcome")")
    [[ "$outcome" == FAIL* ]] && failures=$((failures + 1))
    return 0
}

check_placeholders() {
    local left
    left=$(grep -rn '{{[A-Z_]\{2,\}}}' . --exclude-dir=.git 2>/dev/null | head -5 || true)
    [[ -z "$left" ]] && echo ok || { echo "$left" >&2; echo FAIL; }
}

check_versions() {
    [[ -x make/versions.sh ]] || { echo "skipped (no make/versions.sh)"; return; }
    ./make/versions.sh check > /dev/null 2>&1 && echo ok || echo FAIL
}

check_scripts() {
    local script failed=""
    for script in make/*.sh; do
        # By shebang: setup_local_dev_env.sh was a zsh script before v2.0.0,
        # and a render of an older ref still has that one.
        if head -1 "$script" | grep -q zsh; then
            zsh -n "$script" 2> /dev/null || failed+="$script "
        else
            bash -n "$script" 2> /dev/null || failed+="$script "
        fi
    done
    [[ -z "$failed" ]] && echo ok || echo "FAIL: $failed"
}

check_json() {
    command -v jq > /dev/null || { echo "skipped (no jq)"; return; }
    local file failed=""
    while IFS= read -r file; do
        jq empty "$file" > /dev/null 2>&1 || failed+="$file "
    done < <(find . -name '*.json' -not -path './.devcontainer/*' -not -path './.vscode/*' \
                 -not -name 'tsconfig.json' -not -path '*/node_modules/*')
    [[ -z "$failed" ]] && echo ok || echo "FAIL: $failed"
}

check_cfn_lint() {
    command -v cfn-lint > /dev/null || { echo "skipped (no cfn-lint)"; return; }
    local templates
    templates=$(find targets -name '*.yaml' -not -name 'buildspec*.yaml' | sort)
    # shellcheck disable=SC2086 - a list of paths without spaces.
    cfn-lint --non-zero-exit-code error $templates > /dev/null 2>&1 && echo ok || echo FAIL
}

check_lint() {
    local tool
    tool=$(sed -n 's/^LINT_TOOL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' make/commands.sh | head -1)
    if [[ -z "$tool" ]] || ! command -v "$tool" > /dev/null; then
        echo "skipped (no ${tool:-linter})"
        return
    fi
    # eslint and mix run from the project's own dependencies, which a fresh
    # render does not have; installing them is a network step this skips.
    if [[ -f package.json && ! -d node_modules ]]; then
        echo "skipped (needs npm install)"
        return
    fi
    if [[ -f mix.exs && ! -d deps ]]; then
        echo "skipped (needs mix deps.get)"
        return
    fi
    ./make/commands.sh lint > /dev/null 2>&1 && echo ok || echo FAIL
}

check_build() {
    command -v docker > /dev/null || { echo "skipped (no docker)"; return; }
    local target failed=""
    for target in $(find targets -name cicd_parameters.json \
            | sed -e 's|^targets/||' -e 's|/cicd_parameters.json$||' | sort); do
        ./make/commands.sh local-build "$target" > /dev/null 2>&1 || failed+="$target "
    done
    [[ -z "$failed" ]] && echo ok || echo "FAIL: $failed"
}

echo "rendering ${REF/#./the working tree} into $out_dir"
for language in "${languages[@]}"; do
    destination="$out_dir/$language"
    if ! "$script_dir/render.sh" "$REF" "$language" demo_app "$destination" 2> "$out_dir/$language.err"; then
        record "$language" render "FAIL: $(head -1 "$out_dir/$language.err")"
        continue
    fi
    record "$language" render ok
    pushd "$destination" > /dev/null
    record "$language" placeholders "$(check_placeholders 2> /dev/null)"
    record "$language" versions "$(check_versions)"
    record "$language" scripts "$(check_scripts)"
    record "$language" json "$(check_json)"
    record "$language" cfn-lint "$(check_cfn_lint)"
    [[ -n "$LINT" ]] && record "$language" lint "$(check_lint)"
    [[ -n "$BUILD" ]] && record "$language" build "$(check_build)"
    popd > /dev/null
done

echo
printf '%-11s %-13s %s\n' language check result
printf '%s\n' "${results[@]}"
echo
if (( failures > 0 )); then
    echo "Error: $failures check(s) failed" >&2
    exit 1
fi
echo "ok  every language renders and passes its checks"
