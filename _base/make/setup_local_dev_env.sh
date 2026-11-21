#!/usr/bin/env bash
#
# setup_local_dev_env.sh - install the project's toolchain with mise.
#
# mise.toml lists everything this project builds and develops with: the
# language (python, go, node, elixir and erlang), and the command-line tools
# `make lint` and the editor use (cfn-lint, gopls, cmake, ...). This installs
# all of it with `mise install`. For a python project it also fills ./.venv,
# which mise creates, from requirements.txt and
# .devcontainer/requirements_dev.txt.
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

# A python project: ./.venv is mise's (the _.python.venv entry in mise.toml),
# created the first time the environment is loaded. Fill it.
requirements=()
[[ -f requirements.txt ]] && requirements+=(-r requirements.txt)
[[ -f .devcontainer/requirements_dev.txt ]] && requirements+=(-r .devcontainer/requirements_dev.txt)
if (( ${#requirements[@]} )); then
    # Private packages come from GitHub over ssh (git+ssh:// lines). Check the
    # way in first: a failure deep in pip's output is easy to miss, and leaves
    # a ./.venv with nothing in it.
    # Files, not a pipe into grep -q: under pipefail that pipe reports failure
    # whenever grep stops reading early. The key may come from the ssh agent
    # or from ~/.ssh/config, so the test is a real login, not ssh-add -l.
    if grep -qs '^[^#]*git+ssh://' requirements.txt .devcontainer/requirements_dev.txt; then
        echo "Checking ssh access to GitHub, for the git+ssh packages..."
        # ssh -T exits 1 even on success (GitHub gives no shell): read the text.
        github=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
            -T git@github.com 2>&1 || true)
        if [[ "$github" != *"successfully authenticated"* ]]; then
            die "Error: ssh cannot log in to GitHub, and requirements.txt installs packages
  from GitHub over ssh (git+ssh://). ssh -T git@github.com said:
    ${github:-<nothing>}
  Add your GitHub key to the ssh agent, then run make local-dev-setup again:
    ssh-add ~/.ssh/<your key>"
        fi
    fi

    echo "Installing python packages into ./.venv..."
    mise exec -- python -m pip install --quiet --upgrade pip
    if ! mise exec -- python -m pip install "${requirements[@]}"; then
        die "
Error: pip could not install the requirements - the reason is above.
  ./.venv exists but is incomplete, so imports will fail in the editor.
  Fix the cause, then run make local-dev-setup again."
    fi
    echo "Installed $(mise exec -- python -m pip list 2> /dev/null | tail -n +3 | wc -l | tr -d ' ') packages into ./.venv."
fi

echo
echo "Done. Installed:"
mise ls --current --local 2> /dev/null | sed 's/^/  /' || true
echo
echo "With mise activated in your shell, these are on PATH in this directory"
echo "(and ./.venv is active, for python). Without it: mise exec -- <command>."
