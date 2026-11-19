#!/bin/bash

set -e

echo -e "running initializeCommand, init.sh\n"

# Every bind mount in devcontainer.json must already exist on the host, or
# container creation dies before anything reaches the log:
#   invalid mount config for type "bind": bind source path does not exist
# The Mac has all of these; a fresh remote host (an EC2 builder reached over
# Remote-SSH) has almost none.
mkdir -p "$HOME/data" "$HOME/.aws" "$HOME/.ssh"
touch "$HOME/.gitconfig" "$HOME/.ssh/config"

# No private key is mounted: git inside the container authenticates through the
# forwarded ssh agent. Empty here means the container will not be able to reach
# a private repository - run `ssh-add ~/.ssh/<key>` on the machine you are
# sitting at, not on the host running docker.
ssh-add -l || echo "WARNING: no keys in the ssh agent"

# mise.toml is the one record of the tool versions; the Dockerfiles and
# devcontainer.json files this build reads carry synced copies of them.
# Syncing here catches a version edited in mise.toml without
# `make sync-versions`. The editor has already read devcontainer.json by now,
# so if anything changed the build stops rather than run on stale values.
if [[ -x ./make/versions.sh ]]; then
    sync_output=$(./make/versions.sh sync)
    echo "$sync_output"
    if grep -q '^synced' <<< "$sync_output"; then
        echo "ERROR: versions were out of step with mise.toml and are now synced."
        echo "Rebuild the container to use them."
        exit 1
    fi
fi

# The base images come from ECR Public. A login token lasts 12 hours, and once
# it expires docker keeps sending it instead of falling back to an anonymous
# pull - the rebuild then dies with "Your authorization token has expired".
# Refresh it here; if that is not possible (no credentials, offline) drop the
# stale one so anonymous pulls work again.
if command -v aws >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
    if aws ecr-public get-login-password --region us-east-1 2>/dev/null \
        | docker login --username AWS --password-stdin public.ecr.aws >/dev/null 2>&1; then
        echo "ecr public: token refreshed"
    else
        echo "WARNING: could not refresh the ECR Public token - falling back to anonymous pulls"
        docker logout public.ecr.aws >/dev/null 2>&1 || true
    fi
fi
