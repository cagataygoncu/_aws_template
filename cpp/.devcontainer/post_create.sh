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
if command -v aws > /dev/null 2>&1; then
    echo "aws cli already present: $(aws --version)"
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
