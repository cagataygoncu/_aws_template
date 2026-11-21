# No --platform pin here, unlike the target Dockerfiles: this image follows the
# host architecture on purpose. Delve debugs through ptrace, and ptrace on an
# emulated process fails - an amd64 container on an arm64 Mac gets as far as
# building and then dies with "Unable to retrieve goroutines: input/output
# error". The deployed images get their platform from the build command
# (build_platform() in make/commands.sh derives it from CodeBuildImage), so
# they still match Fargate; fidelity to them comes from the service and lambda
# variants, not from here.
# mise-sync: FROM public.ecr.aws/docker/library/golang:${mise:go}-bookworm AS builder
FROM public.ecr.aws/docker/library/golang:${mise:go}-bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

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

# RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
#     unzip awscliv2.zip && \
#     ./aws/install && \
#     rm -rf aws awscliv2.zip

# Development tools are installed by .devcontainer/post_create.sh from
# tools_dev.txt, so every variant gets them - not just this image.

# Resolve the modules while the ssh agent is still reachable. --mount=type=ssh
# (devcontainer.json passes --ssh=default) exists during the build only; the
# running container gets no agent unless one is mounted in, so a `go build`
# from dlv would try to fetch the private gig_utils_go over ssh and fail with
# "git@github.com: Permission denied (publickey)". Downloading here puts every
# module in /go/pkg/mod, and the debugger then builds offline.
#
# Adding a dependency later needs the agent again: rebuild the container, or
# mount the agent in - see the commented mount in devcontainer.json.
COPY ./go.mod ./go.sum /app/
WORKDIR /app
# How git reaches private GitHub repositories - a token (the github_token
# build secret) or the ssh agent: make/github_env.sh.
COPY make/github_env.sh /tmp/github_env.sh
RUN --mount=type=ssh --mount=type=secret,id=github_token,required=false \
    export GOPRIVATE=github.com/GIGTennis/* \
    && export GITHUB_TOKEN="$(cat /run/secrets/github_token 2> /dev/null)" && . /tmp/github_env.sh \
    && go mod download

################################################################################################
# mise-sync: FROM public.ecr.aws/docker/library/golang:${mise:go}-bookworm AS release
FROM public.ecr.aws/docker/library/golang:${mise:go}-bookworm AS release


################################################################################################
# FROM release AS final
FROM builder AS final

EXPOSE 8000

