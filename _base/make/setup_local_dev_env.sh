#!/bin/zsh
#
# setup_local_dev_env.sh - create or update the project's local dev environment.
#
# The toolchain is described by environment.yaml, which each language layer
# ships: a Python interpreter, a Go toolchain, a C++ compiler and CMake, Node,
# or Elixir. Everything lands in ./venv, so nothing is installed system-wide
# and removing the project removes the environment with it.
#
#   ./make/setup_local_dev_env.sh     # or: make local-dev-setup
#   ENV_PREFIX=./venv-3.13 ./make/setup_local_dev_env.sh
#
# Run from the project root. Overridable: ENV_PREFIX, ENV_FILE.
#
# Needs micromamba:
#
#   "${SHELL}" <(curl -L micro.mamba.pm)
#   micromamba self-update
#
# Or on macOS: brew install micromamba

set -e

ENV_PREFIX="${ENV_PREFIX:-./venv}"
ENV_FILE="${ENV_FILE:-environment.yaml}"

# Python projects pin their packages in requirements files rather than in
# environment.yaml; other languages have none of these.
PIP_REQUIREMENTS=()
[[ -f requirements.txt ]] && PIP_REQUIREMENTS+=(-r requirements.txt)
[[ -f .devcontainer/requirements_dev.txt ]] && PIP_REQUIREMENTS+=(-r .devcontainer/requirements_dev.txt)

if ! command -v micromamba &> /dev/null; then
    echo "Error: micromamba is not installed"
    echo ""
    echo "Install it with:"
    echo '  "${SHELL}" <(curl -L micro.mamba.pm)'
    echo "  micromamba self-update"
    echo ""
    echo "Or on macOS:"
    echo "  brew install micromamba"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: $ENV_FILE not found"
    exit 1
fi

if [[ -d "$ENV_PREFIX" ]]; then
    echo "Environment already exists at $ENV_PREFIX"
    echo -n "Do you want to update it? (y/n): "
    read -r response

    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "Updating environment..."
        micromamba env update --file "$ENV_FILE" --prefix "$ENV_PREFIX"

        if (( ${#PIP_REQUIREMENTS} )); then
            echo -n "Do you want to force reinstall pip packages? (y/n): "
            read -r force_reinstall

            if [[ "$force_reinstall" =~ ^[Yy]$ ]]; then
                echo "Force reinstalling pip packages..."
                micromamba run -p "$ENV_PREFIX" pip install --force-reinstall "${PIP_REQUIREMENTS[@]}"
            fi
        fi

        echo "Environment updated successfully!"
    else
        echo "Skipping update."
        exit 0
    fi
else
    echo "Creating new environment at $ENV_PREFIX"
    micromamba env create --file "$ENV_FILE" --prefix "$ENV_PREFIX"
    echo "Environment created successfully!"
fi

echo ""
echo "To activate the environment, run:"
echo "  micromamba activate $ENV_PREFIX"
echo "To deactivate the environment, run:"
echo "  micromamba deactivate"
