#!/usr/bin/env bash
# versions.sh - mise.toml is the one place this project writes a tool version.
#
# Every other file that needs a version either reads mise.toml when it is
# used, or carries a synced copy that this script keeps in step:
#
#   read when used   BaseImageURI in targets/*/cicd_parameters.json holds a
#                    pattern such as public.ecr.aws/lambda/python:${mise:python}.
#                    make/commands.sh expands it for local builds; the
#                    pipeline's buildspec.yaml expands it at build time, so a
#                    pushed version bump reaches the next build.
#   synced           files that cannot read another file - Dockerfile FROM and
#                    ARG defaults, devcontainer.json, .vscode/settings.json,
#                    go.mod. Each synced line
#                    sits under a comment holding its pattern:
#
#                        # mise-sync: FROM public.ecr.aws/docker/library/python:${mise:python}
#                        FROM public.ecr.aws/docker/library/python:3.12
#
#                    `sync` rewrites the line under every such comment.
#
# A ${mise:<name>} token resolves to <name> in mise.toml's [tools] section, or
# its [vars] section. <name> is the key as written, quotes dropped:
# ${mise:python}, ${mise:pipx:cfn-lint}. Values come from for values mise does not install (the Debian release the
# cpp images are built on).
#
# Usage:
#     ./make/versions.sh show                 every value in mise.toml
#     ./make/versions.sh get <name>           one value
#     ./make/versions.sh expand <text>        text with ${mise:...} resolved
#     ./make/versions.sh set <name> <value>   change a value in mise.toml
#     ./make/versions.sh sync                 rewrite the synced lines
#     ./make/versions.sh check                fail if any synced line is stale
#
# Run from the project root. Overridable: MISE_FILE. Needs bash and a POSIX
# awk only - mise itself is not required, and the pipeline has none.

set -euo pipefail

MISE_FILE="${MISE_FILE:-mise.toml}"

# A marker is a comment line - # or // first, then "mise-sync: " - so text
# that only mentions the marker (this file's own code, say) is not one.
MARKER_ERE='^[[:space:]]*(#|//)[[:space:]]*mise-sync: '

# Folders never scanned for mise-sync lines: environments, dependencies and
# build output, none of which belong to the project's own sources.
SKIP_DIRS=(.git venv node_modules build dist _build deps .next .elixir_ls vendor)

die() {
    echo "$*" >&2
    exit 1
}

require_mise_file() {
    [[ -f "$MISE_FILE" ]] || die "ERROR: $MISE_FILE not found - run from the project root"
}

# The awk that reads mise.toml into v[name]: bare `name = "value"` keys in
# [tools] and [vars]. Shared by every command so they cannot disagree.
# shellcheck disable=SC2016 - awk code, not shell.
AWK_READ_MISE='
# A key is bare (python) or quoted ("pipx:cfn-lint"). key_of returns it, or
# "" for a line that is not `key = "value"`; value_at is where the value
# starts (its opening quote), for set_value to rewrite it.
function key_of(line, rest, key) {
    rest = line
    sub(/^[ \t]*/, "", rest)
    if (rest ~ /^"[^"]+"[ \t]*=[ \t]*"/) {
        key = substr(rest, 2)
        sub(/".*$/, "", key)
    } else if (rest ~ /^[A-Za-z0-9_-]+[ \t]*=[ \t]*"/) {
        key = rest
        sub(/[ \t]*=.*$/, "", key)
    } else {
        return ""
    }
    value_at = index(line, "=")
    value_at += index(substr(line, value_at + 1), "\"")
    return key
}
function read_mise(line, name, value) {
    if (line ~ /^[ \t]*\[/) {
        section = line
        gsub(/^[ \t]*\[[ \t]*|[ \t]*\].*$/, "", section)
        return
    }
    if (section != "tools" && section != "vars") return
    name = key_of(line)
    if (name == "") return
    value = substr(line, value_at + 1)
    sub(/".*$/, "", value)
    v[name] = value
}
function expand(text, out, rest, start, close_at, name) {
    out = ""
    rest = text
    while ((start = index(rest, "${mise:")) > 0) {
        out = out substr(rest, 1, start - 1)
        rest = substr(rest, start + 7)
        close_at = index(rest, "}")
        if (close_at == 0) {
            printf "ERROR: unterminated ${mise: in: %s\n", text > "/dev/stderr"
            failed = 1
            return text
        }
        name = substr(rest, 1, close_at - 1)
        rest = substr(rest, close_at + 1)
        if (!(name in v)) {
            printf "ERROR: %s has no value for %s (needed by: %s)\n", mise_file, name, text > "/dev/stderr"
            failed = 1
            return text
        }
        out = out v[name]
    }
    return out rest
}
'

show() {
    require_mise_file
    awk -v mise_file="$MISE_FILE" "$AWK_READ_MISE"'
        { read_mise($0) }
        END { for (name in v) printf "%-10s %s\n", name, v[name] }
    ' "$MISE_FILE" | sort
}

get() {
    local name=${1:?usage: versions.sh get <name>}
    expand "\${mise:${name}}"
}

expand() {
    local text=${1?usage: versions.sh expand <text>}
    require_mise_file
    # The text goes in through the environment, not -v, so awk does not
    # interpret backslashes in it.
    TEXT="$text" awk -v mise_file="$MISE_FILE" "$AWK_READ_MISE"'
        { read_mise($0) }
        END {
            result = expand(ENVIRON["TEXT"])
            if (failed) exit 2
            print result
        }
    ' "$MISE_FILE"
}

# Rewrite name's value in place, keeping the rest of the line (a trailing
# comment, say). Fails if mise.toml does not already declare it: adding a tool
# is an edit to make by hand, not a side effect of a typo.
set_value() {
    local name=${1:?usage: versions.sh set <name> <value>} value=${2:?usage: versions.sh set <name> <value>}
    require_mise_file
    local tmp
    tmp=$(mktemp)
    if ! NAME="$name" VALUE="$value" awk "$AWK_READ_MISE"'
        /^[ \t]*\[/ {
            section = $0
            gsub(/^[ \t]*\[[ \t]*|[ \t]*\].*$/, "", section)
        }
        (section == "tools" || section == "vars") && !done && key_of($0) == ENVIRON["NAME"] {
            # Keep everything around the value: the key, a trailing comment.
            tail = substr($0, value_at + 1)
            sub(/^[^"]*"/, "", tail)
            $0 = substr($0, 1, value_at) ENVIRON["VALUE"] "\"" tail
            done = 1
        }
        { print }
        END { if (!done) exit 3 }
    ' "$MISE_FILE" > "$tmp"; then
        rm -f "$tmp"
        die "ERROR: $MISE_FILE declares no $name in [tools] or [vars]"
    fi
    # cat back rather than mv, so the file keeps its permissions.
    cat "$tmp" > "$MISE_FILE"
    rm -f "$tmp"
    echo "$MISE_FILE: $name = \"$value\""
}

# Files holding at least one mise-sync comment, NUL-separated.
synced_files() {
    local prune=() dir
    for dir in "${SKIP_DIRS[@]}"; do
        prune+=(-name "$dir" -o)
    done
    # Markdown is skipped: a README showing a mise-sync example in a code
    # block must not have the line under it rewritten.
    find . \( "${prune[@]}" -false \) -prune -o -type f -not -name '*.md' -print0 \
        | xargs -0 grep -lE --null "$MARKER_ERE" 2>/dev/null || true
}

# Print a file with every synced line rewritten. The pattern is the text after
# "mise-sync: " up to the end of the comment line; the rewritten line keeps
# the indentation it had, so JSON and YAML stay laid out as they were.
render_synced() {
    local file=$1
    awk -v mise_file="$MISE_FILE" -v file="$file" "$AWK_READ_MISE"'
        FNR == NR { read_mise($0); next }
        pending {
            indent = $0
            sub(/[^ \t].*$/, "", indent)
            print indent expand(pattern)
            pending = 0
            next
        }
        {
            print
            at = index($0, "mise-sync: ")
            if ($0 ~ /^[ \t]*(#|\/\/)[ \t]*mise-sync: /) {
                pattern = substr($0, at + 11)
                sub(/[ \t]+$/, "", pattern)
                pending = 1
            }
        }
        END {
            if (pending) {
                printf "ERROR: %s ends on a mise-sync comment with no line under it\n", file > "/dev/stderr"
                failed = 1
            }
            if (failed) exit 2
        }
    ' "$MISE_FILE" "$file"
}

# sync and check share this walk: mode=write rewrites, mode=check only reports.
walk_synced() {
    local mode=$1 file tmp stale=0
    require_mise_file
    tmp=$(mktemp)
    while IFS= read -r -d '' file; do
        file=${file#./}
        render_synced "$file" > "$tmp" || { rm -f "$tmp"; exit 2; }
        if ! cmp -s "$tmp" "$file"; then
            stale=$((stale + 1))
            if [[ "$mode" == write ]]; then
                cat "$tmp" > "$file"
                echo "synced  $file"
            else
                echo "stale   $file"
            fi
        fi
    done < <(synced_files)
    rm -f "$tmp"

    if [[ "$mode" == check ]]; then
        if (( stale > 0 )); then
            die "ERROR: $stale file(s) disagree with $MISE_FILE - run: make sync-versions"
        fi
        echo "versions ok"
    elif (( stale == 0 )); then
        echo "versions already match $MISE_FILE"
    fi
}

case "${1:-}" in
    show)   show ;;
    get)    shift; get "$@" ;;
    expand) shift; expand "$@" ;;
    set)    shift; set_value "$@" ;;
    sync)   walk_synced write ;;
    check)  walk_synced check ;;
    *)
        echo "Usage: $(basename "$0") show | get <name> | expand <text> | set <name> <value> | sync | check" >&2
        exit 1
        ;;
esac
