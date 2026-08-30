#!/bin/bash

set -ex

echo -e "running postCreateCommand, post_create.sh\n"

# The AWS CLI is a devcontainer tool, not an application dependency: the code
# talks to AWS through the SDK, and the deployed images have no CLI in them.
# It is here because the make targets shell out to `aws`. Installed into the
# container, never into the image - the service and lambda variants are for
# looking at the deployed image as it is.
#
# The installer is architecture-specific and these images are not all the same
# architecture: the dev image pins linux/amd64, the target variants follow the
# host. An x86_64 installer in an arm64 container dies with "rosetta error:
# failed to open elf".
# The installer ships as a zip, and the target variants are the deployed
# images - lean, and without unzip. Missing it exits 127, which under set -e
# takes the whole postCreateCommand down ("failed with exit code 127. Skipping
# any further user-provided commands"), so install it if we can and carry on
# without the CLI if we cannot.
install_unzip() {
    command -v unzip > /dev/null 2>&1 && return 0
    if command -v apt-get > /dev/null 2>&1; then
        apt-get update && apt-get install -y --no-install-recommends unzip
    elif command -v dnf > /dev/null 2>&1; then
        dnf install -y unzip
    elif command -v microdnf > /dev/null 2>&1; then
        microdnf install -y unzip
    elif command -v yum > /dev/null 2>&1; then
        yum install -y unzip
    fi
    command -v unzip > /dev/null 2>&1
}

if command -v aws > /dev/null 2>&1; then
    echo "aws cli already present: $(aws --version)"
elif ! install_unzip; then
    echo "WARNING: no unzip and no package manager to install it - skipping the AWS CLI"
else
    AWS_CLI_ARCH=$(uname -m)
    curl "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_CLI_ARCH}.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
fi

curl -L "https://raw.githubusercontent.com/scop/bash-completion/refs/heads/main/bash_completion" \
    -o /etc/bash_completion

# Docker CLI only - no daemon in here. It talks to the host's daemon through
# the mounted socket, so `make build` / `make run` work inside the container.
# A build context is streamed to the daemon, but `docker run -v` paths are
# resolved on the host: that is what AWS_CONFIG_HOST_DIR is for.
if command -v docker > /dev/null 2>&1; then
    echo "docker cli already present: $(docker --version)"
else
    DOCKER_ARCH=$(uname -m)
    curl -fsSL "https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-27.3.1.tgz" \
        | tar -xz -C /usr/local/bin --strip-components=1 docker/docker
fi

# Go development tools, listed in .devcontainer/tools_dev.txt - the analogue of
# requirements_dev.txt. Installed here rather than in the Dockerfile so every
# variant that has a Go toolchain gets them, including the target images the
# picker offers. GOTOOLCHAIN=auto because dlv and gopls track the newest Go
# release and the official image pins GOTOOLCHAIN=local.
TOOLS_FILE="$(dirname "$0")/tools_dev.txt"
if [ -f "$TOOLS_FILE" ] && command -v go > /dev/null 2>&1; then
    while read -r tool; do
        case "$tool" in ''|\#*) continue ;; esac
        echo "installing $tool"
        GOTOOLCHAIN=auto go install -v "$tool" || echo "WARNING: $tool failed to install"
    done < "$TOOLS_FILE"
elif [ -f "$TOOLS_FILE" ]; then
    echo "WARNING: no go toolchain in this image - skipping $TOOLS_FILE"
fi
