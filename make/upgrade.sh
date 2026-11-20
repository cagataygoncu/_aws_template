#!/usr/bin/env bash
# upgrade.sh - bring a generated project up to a newer template version.
#
# Usage (from the template root):
#     ./make/upgrade.sh run   <project_dir> [ref]     upgrade; ref defaults to the latest tag
#     ./make/upgrade.sh guess <project_dir> [--write] find the version an unstamped
#                                                     project was made from
#
# run - a 3-way merge, the way `git merge` does it, per file:
#
#   old      the project's recorded version (.template.env), rendered again
#   new      the target version, rendered with the same answers
#   project  the project as it is now
#
# Each path is classified with the target version's template_manifest.txt:
#
#   template  the template's change from old to new is merged in. A file the
#             project never touched is replaced; a file both changed gets
#             git merge-file, and clashing edits get conflict markers.
#   seed      the project owns it: created if the template added it and the
#             project lacks it, otherwise left alone. The template's change
#             goes into seed.patch, for a person to port.
#   stamp     .template.env, rewritten at the end to name the new version.
#
# A file the project deleted stays deleted. A path no rule covers is treated
# as seed, the safe side. Afterwards make/versions.sh sync rewrites the synced
# version lines from the merged mise.toml.
#
# The project must be a clean git checkout; the work happens on a new branch,
# template-upgrade/<version> (NO_BRANCH=1 to stay on the current one), and
# nothing is committed. The report and seed.patch go into the project's
# .git/template-upgrade/<version>/, so they are never committed by accident.
# Exits 1 when there are conflicts to resolve.
#
# guess - for a project made before .template.env existed. Renders recent
# template commits (GUESS_LIMIT, default 30) with the project's language and
# name, and ranks them by how many lines of template-owned files differ from
# the project. --write stamps the best match, so `run` can start from it.
#
# Bash 3.2 compatible.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
template_dir=$(dirname "$script_dir")

die() {
    echo "$*" >&2
    exit 2
}

# One value from a stamp, without sourcing it: a stamp is data, not code.
stamp_value() {
    local stamp=$1 key=$2
    sed -n "s/^${key}=//p" "$stamp" | tail -1 | sed -e "s/^'//" -e "s/'$//"
}

# Every file under a directory, as relative paths.
list_files() {
    (cd "$1" && find . -type f -not -path './.git/*' | sed 's|^\./||' | sort)
}

is_text() {
    LC_ALL=C grep -Iq . "$1" 2> /dev/null || [[ ! -s "$1" ]]
}

same() {
    cmp -s "$1" "$2"
}

require_clean_project() {
    local project=$1
    git -C "$project" rev-parse --git-dir > /dev/null 2>&1 \
        || die "Error: $project is not a git checkout"
    if [[ -n "$(git -C "$project" status --porcelain)" ]]; then
        die "Error: $project has uncommitted changes - commit or stash them first"
    fi
}

latest_tag() {
    git -C "$template_dir" describe --tags --abbrev=0 2> /dev/null \
        || die "Error: the template has no tag - tag a release first"
}

# ---- run ---------------------------------------------------------------------

run() {
    local project=${1:?usage: upgrade.sh run <project_dir> [ref]}
    project=$(cd "$project" && pwd)
    local ref=${2:-$(latest_tag)}
    local stamp="$project/.template.env"

    [[ -f "$stamp" ]] || die "Error: $project has no .template.env.
  Find the version it was made from first: make upgrade-guess $project"

    local language project_name old_commit dirty stamp_lv stamp_otp
    language=$(stamp_value "$stamp" LANGUAGE)
    project_name=$(stamp_value "$stamp" PROJECT_NAME)
    old_commit=$(stamp_value "$stamp" TEMPLATE_COMMIT)
    dirty=$(stamp_value "$stamp" TEMPLATE_DIRTY)
    # Stamps from before versions moved to mise.toml recorded them; both
    # renders get them, so a project's chosen toolchain is not reset.
    stamp_lv=$(stamp_value "$stamp" LANGUAGE_VERSION)
    stamp_otp=$(stamp_value "$stamp" OTP_VERSION)

    [[ -n "$language" && -n "$project_name" && -n "$old_commit" ]] \
        || die "Error: $stamp lacks LANGUAGE, PROJECT_NAME or TEMPLATE_COMMIT"
    [[ "$old_commit" != unknown ]] \
        || die "Error: $stamp names no commit - run: make upgrade-guess $project WRITE=1"
    if [[ "$dirty" == true && -z "${FORCE:-}" ]]; then
        die "Error: $project was rendered from uncommitted template changes, so
  its old render cannot be repeated and the merge would be guesswork.
  FORCE=1 runs it against commit ${old_commit:0:7} anyway."
    fi
    git -C "$template_dir" cat-file -e "${old_commit}^{commit}" 2> /dev/null \
        || die "Error: commit $old_commit is not in this template's history"

    local new_commit old_version new_version
    new_commit=$(git -C "$template_dir" rev-parse --verify --quiet "${ref}^{commit}") \
        || die "Error: '$ref' is not a commit of this template"
    old_version=$(git -C "$template_dir" describe --tags --always "$old_commit")
    new_version=$(git -C "$template_dir" describe --tags --always "$new_commit")
    if [[ "$old_commit" == "$new_commit" ]]; then
        echo "$project is already on $new_version"
        return 0
    fi
    if git -C "$template_dir" merge-base --is-ancestor "$new_commit" "$old_commit" && [[ -z "${FORCE:-}" ]]; then
        die "Error: $new_version is older than $old_version, the project's version.
  That would be a downgrade; FORCE=1 runs it anyway."
    fi

    require_clean_project "$project"

    local work
    work=$(mktemp -d)
    # shellcheck disable=SC2064 - expand now: work is local to this function.
    trap "rm -rf '${work:?}'" EXIT

    echo "upgrading $project ($language) from $old_version to $new_version"
    echo ">>> rendering both versions"
    RENDER_LANGUAGE_VERSION="$stamp_lv" RENDER_OTP_VERSION="$stamp_otp" \
        "$script_dir/render.sh" "$old_commit" "$language" "$project_name" "$work/old"
    RENDER_LANGUAGE_VERSION="$stamp_lv" RENDER_OTP_VERSION="$stamp_otp" \
        "$script_dir/render.sh" "$new_commit" "$language" "$project_name" "$work/new"

    git -C "$template_dir" show "$new_commit:template_manifest.txt" > "$work/manifest.txt" 2> /dev/null \
        || die "Error: $new_version has no template_manifest.txt - upgrade to v1.0.0 or later"

    if [[ -z "${NO_BRANCH:-}" ]]; then
        local branch="template-upgrade/$new_version"
        git -C "$project" switch -q -c "$branch" \
            || die "Error: could not create branch $branch (does it exist already?)"
        echo ">>> on branch $branch"
    fi

    local report_dir
    report_dir="$(git -C "$project" rev-parse --absolute-git-dir)/template-upgrade/$new_version"
    mkdir -p "$report_dir"
    : > "$report_dir/seed.patch"

    { list_files "$work/old"; list_files "$work/new"; } | sort -u > "$work/paths"
    # One classify call for every path: each call re-reads the manifest.
    # shellcheck disable=SC2046 - paths contain no spaces.
    MANIFEST_FILE="$work/manifest.txt" "$script_dir/manifest.sh" classify $(cat "$work/paths") \
        > "$work/classes"

    local class path o n p ho hn hp
    local updated=0 merged=0 added=0 removed=0 conflicts=0 seeds=0
    : > "$work/report"
    note() { printf '| %s | `%s` | %s |\n' "$1" "$2" "$3" >> "$work/report"; }

    # ---- versions first ----
    # mise.toml is merged before anything else, and where the project and the
    # template both changed a line, the project's value wins: a version the
    # project chose is a decision, not a conflict. The template's new default
    # is reported. Then both renders' synced lines are rewritten from the
    # merged file, so a Dockerfile FROM or devcontainer.json line differs
    # between old, new and project only where something besides the version
    # changed - and version lines never conflict.
    local mise_new="$work/new/mise.toml" mise_old="$work/old/mise.toml" mise_project="$project/mise.toml"
    if [[ -f "$mise_new" && -f "$mise_project" ]]; then
        [[ -f "$mise_old" ]] || : > "$mise_old"
        if ! same "$mise_old" "$mise_new" && ! same "$mise_project" "$mise_new"; then
            if same "$mise_project" "$mise_old"; then
                cp -p "$mise_new" "$mise_project"
                note template mise.toml "versions moved to the template's new defaults"
            else
                cp "$mise_project" "$work/merge"
                if git merge-file -q "$work/merge" "$mise_old" "$mise_new"; then
                    note template mise.toml "merged"
                else
                    cp "$mise_project" "$work/merge"
                    git merge-file -q --ours "$work/merge" "$mise_old" "$mise_new" || true
                    note template mise.toml "kept the project's versions where both changed; the template's are now: $(
                        MISE_FILE="$mise_new" "$work/new/make/versions.sh" show | tr -s ' ' '=' | paste -sd ' ' -)"
                fi
                cat "$work/merge" > "$mise_project"
                merged=$((merged + 1))
            fi
        fi
    elif [[ -f "$mise_new" && ! -f "$mise_project" ]]; then
        # A project from before mise.toml: it starts on the versions its old
        # render used, when those are known, rather than on new defaults.
        cp -p "$mise_new" "$mise_project"
        added=$((added + 1))
        note template mise.toml "added - check the versions against the project's Dockerfiles"
    fi
    if [[ -f "$mise_project" && -x "$work/new/make/versions.sh" ]]; then
        local side
        for side in old new; do
            (cd "$work/$side" && MISE_FILE="$mise_project" "$work/new/make/versions.sh" sync > /dev/null 2>&1) || true
        done
    fi
    # Marked done, so the loop below leaves it alone.
    sed -i.bak '/^template mise\.toml$/d' "$work/classes" && rm -f "$work/classes.bak"

    while read -r class path; do
        o="$work/old/$path"
        n="$work/new/$path"
        p="$project/$path"
        [[ -f "$o" ]] && ho=1 || ho=""
        [[ -f "$n" ]] && hn=1 || hn=""
        [[ -f "$p" ]] && hp=1 || hp=""

        case "$class" in
            stamp) continue ;;
            unclassified)
                class=seed
                note seed "$path" "no manifest rule - treated as seed"
                ;;
        esac

        if [[ "$class" == seed ]]; then
            if [[ -n "$hn" && -z "$hp" && -z "$ho" ]]; then
                mkdir -p "$(dirname "$p")"
                cp -p "$n" "$p"
                added=$((added + 1))
                note seed "$path" "added - new in the template"
            elif [[ -n "$hp" ]] && ! { [[ -n "$ho" && -n "$hn" ]] && same "$o" "$n"; }; then
                # The template changed it (or added/removed it) but the
                # project owns it: record the change, touch nothing.
                if [[ -n "$ho$hn" ]]; then
                    local from=/dev/null to=/dev/null
                    [[ -n "$ho" ]] && from=$o
                    [[ -n "$hn" ]] && to=$n
                    diff -u --label "a/$path" --label "b/$path" "$from" "$to" \
                        >> "$report_dir/seed.patch" || true
                    seeds=$((seeds + 1))
                    note seed "$path" "template changed it - review seed.patch"
                fi
            fi
            continue
        fi

        # template
        if [[ -n "$ho" && -n "$hn" ]]; then
            same "$o" "$n" && continue
            if [[ -z "$hp" ]]; then
                note template "$path" "changed in the template; the project deleted it - left deleted"
                continue
            fi
            if same "$p" "$o"; then
                cp -p "$n" "$p"
                updated=$((updated + 1))
                continue
            fi
            if same "$p" "$n"; then
                continue
            fi
            if ! is_text "$p" || ! is_text "$n"; then
                conflicts=$((conflicts + 1))
                note template "$path" "CONFLICT - binary, changed by both; the project's copy is kept"
                continue
            fi
            cp "$p" "$work/merge"
            if git merge-file -L project -L "template $old_version" -L "template $new_version" \
                    "$work/merge" "$o" "$n"; then
                cat "$work/merge" > "$p"
                merged=$((merged + 1))
                note template "$path" "merged - both changed it, no overlap"
            else
                cat "$work/merge" > "$p"
                conflicts=$((conflicts + 1))
                note template "$path" "CONFLICT - resolve the markers"
            fi
        elif [[ -n "$hn" ]]; then
            if [[ -z "$hp" ]]; then
                mkdir -p "$(dirname "$p")"
                cp -p "$n" "$p"
                added=$((added + 1))
                note template "$path" "added - new in the template"
            elif ! same "$p" "$n"; then
                cp "$p" "$work/merge"
                : > "$work/empty"
                git merge-file -L project -L "(none)" -L "template $new_version" \
                    "$work/merge" "$work/empty" "$n" || true
                cat "$work/merge" > "$p"
                conflicts=$((conflicts + 1))
                note template "$path" "CONFLICT - the template added a file the project already has"
            fi
        elif [[ -n "$ho" && -n "$hp" ]]; then
            if same "$p" "$o"; then
                rm -f "$p"
                removed=$((removed + 1))
                note template "$path" "removed - the template dropped it"
            else
                note template "$path" "the template dropped it; the project changed it - kept"
            fi
        fi
    done < "$work/classes"

    # The merged mise.toml decides the versions; rewrite the lines that copy it.
    local sync_note=""
    if [[ -x "$project/make/versions.sh" && -f "$project/mise.toml" ]]; then
        if sync_note=$(cd "$project" && ./make/versions.sh sync 2>&1); then
            :
        else
            conflicts=$((conflicts + 1))
            note template mise.toml "CONFLICT - versions.sh sync failed: $(echo "$sync_note" | tail -1)"
        fi
    fi

    cp "$work/new/.template.env" "$stamp"

    {
        echo "# Template upgrade: $old_version -> $new_version"
        echo
        echo "Project: \`$(basename "$project")\` ($language). Nothing is committed."
        echo
        echo "| Updated | Merged | Added | Removed | Conflicts | Seed changes |"
        echo "|---|---|---|---|---|---|"
        echo "| $updated | $merged | $added | $removed | $conflicts | $seeds |"
        echo
        echo "Updated files (the project had not changed them) are not listed."
        echo
        if [[ -s "$work/report" ]]; then
            echo "| Class | Path | Outcome |"
            echo "|---|---|---|"
            cat "$work/report"
        fi
        echo
        echo "Seed changes: \`seed.patch\` beside this file. Port what applies, keeping the project's values."
        echo
        echo "Template commits in this upgrade:"
        echo
        git -C "$template_dir" log --format='- %h %s' "$old_commit..$new_commit"
        if [[ -n "$sync_note" ]]; then
            echo
            echo "Version sync:"
            echo
            echo '```'
            echo "$sync_note"
            echo '```'
        fi
    } > "$report_dir/report.md"

    echo ">>> done: $updated updated, $merged merged, $added added, $removed removed," \
        "$conflicts conflict(s), $seeds seed change(s) to review"
    echo "report:     $report_dir/report.md"
    [[ -s "$report_dir/seed.patch" ]] && echo "seed patch: $report_dir/seed.patch"
    echo "next:       resolve conflicts, port seed.patch, then make lint && git diff"
    (( conflicts == 0 ))
}

# ---- guess -------------------------------------------------------------------

detect_language() {
    local project=$1
    if [[ -f "$project/mix.exs" ]]; then echo elixir
    elif [[ -f "$project/go.mod" ]]; then echo golang
    elif [[ -f "$project/CMakeLists.txt" ]]; then echo cpp
    elif [[ -f "$project/package.json" ]] && grep -q '"next"' "$project/package.json"; then echo nextjs
    elif [[ -f "$project/package.json" ]]; then echo typescript
    elif [[ -f "$project/requirements.txt" ]]; then echo python
    else return 1
    fi
}

guess() {
    local project=${1:?usage: upgrade.sh guess <project_dir> [--write]}
    project=$(cd "$project" && pwd)
    local write=${2:-${WRITE:+--write}}
    local limit=${GUESS_LIMIT:-30}

    local language project_name
    language=${LANGUAGE:-$(detect_language "$project")} \
        || die "Error: cannot tell the language of $project - pass LANGUAGE=..."
    # The name the project was bootstrapped with: snake_case, as make new
    # demands. project.env holds the stack name, with hyphens.
    project_name=${PROJECT_NAME:-$(sed -n 's/^PROJECT_NAME=//p' "$project/project.env" 2> /dev/null | tr '-' '_')}
    project_name=${project_name:-$(basename "$project" | tr '-' '_')}

    local work
    work=$(mktemp -d)
    # shellcheck disable=SC2064 - expand now: work is local to this function.
    trap "rm -rf '${work:?}'" EXIT

    echo "ranking the last $limit template commits against $project ($language, $project_name)"
    local project_classes
    list_files "$project" | grep -v '^vault_doc/' > "$work/project_paths" || true
    # shellcheck disable=SC2046 - paths contain no spaces.
    project_classes=$("$script_dir/manifest.sh" classify $(cat "$work/project_paths"))
    local commit path score files r classes
    : > "$work/scores"
    for commit in $(git -C "$template_dir" rev-list --first-parent --max-count="$limit" HEAD); do
        r="$work/r-$commit"
        if ! "$script_dir/render.sh" "$commit" "$language" "$project_name" "$r" 2> /dev/null; then
            continue
        fi
        # Score only template-owned files: seed files are the project's own,
        # and differ whatever version made them.
        list_files "$r" > "$work/paths"
        # shellcheck disable=SC2046 - paths contain no spaces.
        classes=$("$script_dir/manifest.sh" classify $(cat "$work/paths"))
        score=0
        files=0
        while read -r class path; do
            [[ "$class" == template && -f "$project/$path" ]] || continue
            files=$((files + 1))
            score=$((score + $(diff "$r/$path" "$project/$path" 2> /dev/null | grep -c '^[<>]' || true)))
        done <<< "$classes"
        # A template-owned file the project has but this render lacks came
        # from a later version: count its lines too, or every older commit
        # that predates the file would tie with the right one.
        while read -r class path; do
            [[ "$class" == template && ! -f "$r/$path" ]] || continue
            score=$((score + $(wc -l < "$project/$path")))
        done <<< "$project_classes"
        printf '%s %s %s\n' "$score" "$commit" "$files" >> "$work/scores"
        printf '.'
    done
    echo

    [[ -s "$work/scores" ]] || die "Error: no commit rendered"
    echo
    printf '%-8s %-9s %-11s %s\n' "lines" "commit" "date" "version"
    sort -s -n -k1,1 "$work/scores" | head -5 | while read -r score commit files; do
        printf '%-8s %-9s %-11s %s\n' "$score" "${commit:0:7}" \
            "$(git -C "$template_dir" log -1 --format=%ad --date=short "$commit")" \
            "$(git -C "$template_dir" describe --tags --always "$commit")"
    done

    local best
    # Stable sort over newest-first input: a tie goes to the newer commit.
    best=$(sort -s -n -k1,1 "$work/scores" | head -1 | cut -d' ' -f2)
    echo
    if [[ "$write" == --write ]]; then
        [[ -e "$project/.template.env" ]] && die "Error: $project/.template.env exists - not overwriting"
        "$script_dir/render.sh" "$best" "$language" "$project_name" "$work/best" > /dev/null
        cp "$work/best/.template.env" "$project/.template.env"
        echo "wrote $project/.template.env for ${best:0:7}; commit it, then: make upgrade $project"
    else
        echo "best match ${best:0:7}. To stamp it: make upgrade-guess $project WRITE=1"
    fi
}

case "${1:-}" in
    run)   shift; run "$@" ;;
    guess) shift; guess "$@" ;;
    *)
        echo "Usage: $(basename "$0") run <project_dir> [ref] | guess <project_dir> [--write]" >&2
        exit 1
        ;;
esac
