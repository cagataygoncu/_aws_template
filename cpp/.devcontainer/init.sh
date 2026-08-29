#!/bin/bash

set -ex

echo -e "running initializeCommand, init.sh\n"

# The devcontainer binds these from the host; a missing directory fails
# container creation before any of it is visible in the log.
mkdir -p "$HOME/data"

ssh-add -l

xhost + host.docker.internal