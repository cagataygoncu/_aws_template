# github_env.sh - how git reaches private GitHub repositories: a token or ssh.
#
# Sourced, not run: by mise.toml's [env] (the shell), make/commands.sh (every
# make command, the pipeline included), make/setup_local_dev_env.sh, and the
# Dockerfiles' install steps. POSIX sh, because a Dockerfile RUN is sh.
#
# Every language fetches private packages with git - pip's git+ URLs, go
# modules, npm git dependencies, mix git: deps, CMake FetchContent - so one
# git setting covers them all. It is set through GIT_CONFIG_* environment
# variables: nothing is written to ~/.gitconfig or to disk.
#
#   GITHUB_TOKEN set    HTTPS. git rewrites git@github.com: and
#                       ssh://git@github.com/ URLs to https://github.com/, and
#                       a credential helper answers with $GITHUB_TOKEN - read
#                       from the environment when git asks, never written
#                       into a URL or a log.
#   GITHUB_TOKEN empty  ssh, the key in your agent. Only go needs help: it
#                       fetches over https, so the GOPRIVATE module prefixes
#                       are rewritten to git@github.com:.
#
# A token for your Mac: export GITHUB_TOKEN="$(gh auth token)" (GitHub CLI),
# or a fine-grained token with read access to the repositories.

_github_n=0
_github_add() {
    export "GIT_CONFIG_KEY_${_github_n}=$1"
    export "GIT_CONFIG_VALUE_${_github_n}=$2"
    _github_n=$((_github_n + 1))
}

if [ -n "${GITHUB_TOKEN:-}" ]; then
    _github_add url.https://github.com/.insteadOf git@github.com:
    _github_add url.https://github.com/.insteadOf ssh://git@github.com/
    # git appends the action (get, store, erase); answer only get.
    _github_add credential.https://github.com.helper \
        '!f() { test "$1" = get || return 0; echo username=x-access-token; echo "password=${GITHUB_TOKEN}"; }; f'
    # Fail rather than prompt: there is nobody to answer in a build.
    export GIT_TERMINAL_PROMPT=0
else
    for _github_prefix in $(printf '%s' "${GOPRIVATE:-}" | tr ',' ' '); do
        case "$_github_prefix" in
            github.com/*)
                _github_path=${_github_prefix#github.com/}
                _github_path=${_github_path%\*}
                _github_add "url.git@github.com:${_github_path}.insteadOf" "https://github.com/${_github_path}"
                ;;
        esac
    done
fi
export GIT_CONFIG_COUNT="$_github_n"

unset _github_n _github_prefix _github_path
unset -f _github_add
