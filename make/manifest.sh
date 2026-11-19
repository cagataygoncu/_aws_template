#!/usr/bin/env bash
# manifest.sh - read template_manifest.txt: who owns each file of a project.
#
# Usage:
#     ./make/manifest.sh classify <path>...   print "<class> <path>" per path
#     ./make/manifest.sh check                render every language, fail on
#                                             any file no rule matches
#
# Paths are relative to a generated project's root. The classes and the
# matching rules are described at the top of template_manifest.txt. Written
# for bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
template_dir=$(dirname "$script_dir")
# MANIFEST_FILE reads another version's rules: an upgrade classifies with the
# manifest of the version it upgrades to.
manifest_file="${MANIFEST_FILE:-$template_dir/template_manifest.txt}"

# The rules, in file order, as two parallel arrays.
rule_classes=()
rule_patterns=()

load_rules() {
    local class pattern rest
    while read -r class pattern rest; do
        [[ -z "$class" || "$class" == \#* ]] && continue
        case "$class" in
            stamp|template|seed) ;;
            *) echo "Error: $manifest_file: unknown class '$class'" >&2; exit 2 ;;
        esac
        if [[ -z "$pattern" || -n "$rest" ]]; then
            echo "Error: $manifest_file: want '<class> <pattern>', got '$class $pattern $rest'" >&2
            exit 2
        fi
        rule_classes+=("$class")
        rule_patterns+=("$pattern")
    done < "$manifest_file"
}

# Index of the first rule matching a path, or nothing.
rule_index() {
    local path=$1 i
    for i in "${!rule_patterns[@]}"; do
        # Unquoted on the right: a glob, so * matches across /.
        # shellcheck disable=SC2053
        if [[ "$path" == ${rule_patterns[$i]} ]]; then
            echo "$i"
            return
        fi
    done
}

classify() {
    local path index
    for path in "$@"; do
        path=${path#./}
        index=$(rule_index "$path")
        if [[ -n "$index" ]]; then
            echo "${rule_classes[$index]} $path"
        else
            echo "unclassified $path"
        fi
    done
}

# Render every language with the working tree's bootstrap and classify each
# file. Fails on unclassified files; warns on rules no language uses, which
# are either stale or a typo.
check() {
    local language layer path index unclassified=0 i
    local rule_used=()
    # Global, not local: the EXIT trap runs after this function has returned.
    work_dir=$(mktemp -d)
    trap 'rm -rf "${work_dir:?}"' EXIT

    for i in "${!rule_patterns[@]}"; do rule_used[$i]=false; done

    for layer in "$template_dir"/*/layer.env; do
        language=$(basename "$(dirname "$layer")")
        "$script_dir/bootstrap.sh" "$language" manifest_check "$work_dir/$language" > /dev/null
        while IFS= read -r path; do
            path=${path#./}
            index=$(rule_index "$path")
            if [[ -z "$index" ]]; then
                echo "unclassified  $language: $path"
                unclassified=$((unclassified + 1))
            else
                rule_used[$index]=true
            fi
        done < <(cd "$work_dir/$language" && find . -type f | sort)
    done

    for i in "${!rule_patterns[@]}"; do
        if [[ "${rule_used[$i]}" != true ]]; then
            echo "warning: rule matches no file in any language: ${rule_classes[$i]} ${rule_patterns[$i]}"
        fi
    done

    if (( unclassified > 0 )); then
        echo "Error: $unclassified file(s) match no rule in template_manifest.txt" >&2
        exit 1
    fi
    echo "ok  template_manifest.txt classifies every file of every language"
}

load_rules
case "${1:-}" in
    classify) shift; classify "$@" ;;
    check)    check ;;
    *)
        echo "Usage: $(basename "$0") classify <path>... | check" >&2
        exit 1
        ;;
esac
