# No --platform pin: this image follows the host architecture, so it is native
# on both an Apple Silicon Mac and the x86_64 builder. debugpy runs in-process
# and needs no ptrace, so unlike the go and cpp layers nothing was broken by
# the pin - it only cost emulation speed on every pip install and test run.
# The deployed images take their platform from the build command
# (build_platform() in make/commands.sh), so they still match Fargate.
# mise-sync: FROM public.ecr.aws/docker/library/python:${mise:python}
FROM public.ecr.aws/docker/library/python:${mise:python}

# Debian packages from system_packages_build.txt and system_packages.txt - edit the list, not this step.
COPY system_packages_build.txt /tmp/system_packages_build.txt
COPY system_packages.txt /tmp/system_packages.txt
RUN packages=$(cat /tmp/system_packages_build.txt /tmp/system_packages.txt | sed -e 's/#.*//' | xargs); \
    if [ -n "$packages" ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages \
        && rm -rf /var/lib/apt/lists/*; \
    fi

RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
RUN sed /^StrictHostKeyChecking/d /etc/ssh/ssh_config; \
    echo StrictHostKeyChecking no >> /etc/ssh/ssh_config

COPY .devcontainer/.bashrc /root/.bashrc
COPY .devcontainer/.inputrc /root/.inputrc

COPY ./.devcontainer/requirements_dev.txt /.devcontainer/requirements_dev.txt

# The same list the target images install - one source of truth for the
# runtime dependencies. Dev-only tools stay in .devcontainer/requirements_dev.txt.
COPY requirements.txt requirements.txt

# How git reaches private GitHub repositories - a token (the github_token
# build secret) or the ssh agent: make/github_env.sh.
COPY make/github_env.sh /tmp/github_env.sh
RUN --mount=type=ssh --mount=type=secret,id=github_token,required=false export GITHUB_TOKEN="$(cat /run/secrets/github_token 2> /dev/null)" && . /tmp/github_env.sh && export GIT_SSH_COMMAND="ssh -v" && pip3 install --no-cache-dir --upgrade -r requirements.txt

WORKDIR /

ENV PYTHONPATH=/
