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
