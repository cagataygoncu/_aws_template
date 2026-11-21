#!/usr/bin/env bash
#
# setup_local_dev_env.sh - install the project's toolchain with mise.
#
# mise.toml lists everything this project builds and develops with: the
# language (python, go, node, elixir and erlang), and the command-line tools
# `make lint` and the editor use (cfn-lint, gopls, cmake, ...). This installs
# all of it with `mise install`, then the project's dependencies with the
# language's own tool (pip into ./.venv, go mod download, npm install, mix
# deps.get) - after checking ssh access to GitHub when any are private.
#
#   ./make/setup_local_dev_env.sh     # or: make local-dev-setup
#
# Safe to re-run: mise skips what is installed, pip what is satisfied. Run it
# again after editing mise.toml or a requirements file.
#
# A library mise cannot install - a C library, its headers - is not handled
# here. List it in system_packages.txt (runtime) or system_packages_build.txt
# (build only); the devcontainer and the deployed images install those.
#
# Needs mise:
#
#   curl https://mise.run | sh        # or: brew install mise
#   echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
#
# Run from the project root.

set -euo pipefail

die() {
    echo "$*" >&2
    exit 1
}

command -v mise > /dev/null 2>&1 || die "Error: mise is not installed.

Install it with:
  curl https://mise.run | sh
Or on macOS:
  brew install mise

Then activate it in your shell, once:
  echo 'eval \"\$(mise activate zsh)\"' >> ~/.zshrc"

[[ -f mise.toml ]] || die "Error: mise.toml not found - run from the project root"

# The synced version lines (Dockerfiles, devcontainer.json, ...) follow
# mise.toml, so a version edited there reaches them before anything installs.
./make/versions.sh sync

# mise runs nothing from a config file it has not been told to trust. This
# project's own mise.toml is trusted here, and only that file.
mise trust --quiet mise.toml

echo "Installing the tools in mise.toml..."
mise install

# The dependencies, installed by the language's own tool under mise: pip into
# ./.venv (python), go mod download, npm install, mix deps.get. Filled in per
# language by bootstrap; empty when the language has nothing to install.
DEPS_COMMAND='{{DEPS_COMMAND}}'

# Dependency files that can name a private GitHub repository. Any of them
# reaching GitHub over ssh, or naming a module GOPRIVATE covers, means the
# install needs an ssh login to GitHub.
DEPENDENCY_FILES=(requirements.txt .devcontainer/requirements_dev.txt go.mod package.json mix.exs CMakeLists.txt)

needs_github_ssh() {
    local private_ere='git\+ssh://|git@github\.com:|ssh://git@github\.com|"github:'
    # GOPRIVATE (set in mise.toml for go) as a prefix: github.com/GIGTennis/*
    # matches github.com/GIGTennis/ in go.mod.
    local prefix GOPRIVATE="${GOPRIVATE:-}"
    for prefix in ${GOPRIVATE//,/ }; do
        private_ere+="|${prefix%\*}"
    done
    # Files, not a pipe into grep -q: under pipefail that pipe reports
    # failure whenever grep stops reading early.
    grep -Eqs "^[^#]*(${private_ere})" "${DEPENDENCY_FILES[@]}"
}

# The key may come from the ssh agent or from ~/.ssh/config, so the test is a
# real login, not ssh-add -l. ssh -T exits 1 even on success (GitHub gives no
# shell), so its text decides.
check_github_ssh() {
    echo "Checking ssh access to GitHub, for the private packages..."
    local github
    github=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        -T git@github.com 2>&1 || true)
    if [[ "$github" != *"successfully authenticated"* ]]; then
        die "Error: ssh cannot log in to GitHub, and this project's dependencies include
  private packages fetched over ssh. ssh -T git@github.com said:
    ${github:-<nothing>}
  Add your GitHub key to the ssh agent, then run make local-dev-setup again:
    ssh-add ~/.ssh/<your key>"
    fi
}

if [[ -n "$DEPS_COMMAND" ]]; then
    # mise's environment: GOPRIVATE and the git rewrite for go, ./.venv for
    # python. Then this project's tools first on PATH, ./.venv before all:
    # mise keeps entries added after its activation (a micromamba base, say)
    # ahead of its own, and a pip from there installs into that environment.
    eval "$(mise env --shell bash 2> /dev/null)" || true
    mise_paths=$(mise bin-paths 2> /dev/null | paste -sd: - || true)
    [[ -n "$mise_paths" ]] && PATH="$mise_paths:$PATH"
    [[ -n "${VIRTUAL_ENV:-}" ]] && PATH="$VIRTUAL_ENV/bin:$PATH"
    export PATH
    if [[ -n "${VIRTUAL_ENV:-}" && "$(command -v python)" != "$VIRTUAL_ENV/bin/python" ]]; then
        die "Error: python resolves to $(command -v python), not ${VIRTUAL_ENV}/bin/python.
  Installing would write into that environment instead. Nothing was installed."
    fi
    if needs_github_ssh; then
        check_github_ssh
    fi

    echo "Installing the dependencies: ${DEPS_COMMAND}"
    if ! sh -c "$DEPS_COMMAND"; then
        die "
Error: the dependencies did not install - the reason is above.
  The environment is incomplete, so imports will fail in the editor.
  Fix the cause, then run make local-dev-setup again."
    fi
    if [[ -x .venv/bin/python ]]; then
        echo "Installed $(.venv/bin/python -m pip list 2> /dev/null | tail -n +3 | wc -l | tr -d ' ') packages into ./.venv."
    else
        echo "Dependencies installed."
    fi
fi

echo
echo "Done. Installed:"
mise ls --current --local 2> /dev/null | sed 's/^/  /' || true
echo
echo "With mise activated in your shell, these are on PATH in this directory"
echo "(and ./.venv is active, for python). Without it: mise exec -- <command>."
