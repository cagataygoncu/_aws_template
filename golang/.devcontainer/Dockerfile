# No --platform pin here, unlike the target Dockerfiles: this image follows the
# host architecture on purpose. Delve debugs through ptrace, and ptrace on an
# emulated process fails - an amd64 container on an arm64 Mac gets as far as
# building and then dies with "Unable to retrieve goroutines: input/output
# error". The deployed images get their platform from the build command
# (build_platform() in make/commands.sh derives it from CodeBuildImage), so
# they still match Fargate; fidelity to them comes from the service and lambda
# variants, not from here.
FROM public.ecr.aws/docker/library/golang:{{LANGUAGE_VERSION}}-bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    libssl-dev \
    curl \
    libcurl4-openssl-dev \
    unzip \
    zlib1g \
    zlib1g-dev \
    libprotobuf-c-dev \
    && rm -rf /var/lib/apt/lists/*

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
RUN --mount=type=ssh \
    git config --global url."git@github.com:GIGTennis/".insteadOf "https://github.com/GIGTennis/" \
    && export GOPRIVATE=github.com/GIGTennis/* \
    && go mod download

################################################################################################
FROM public.ecr.aws/docker/library/golang:{{LANGUAGE_VERSION}}-bookworm AS release


################################################################################################
# FROM release AS final
FROM builder AS final

EXPOSE 8000

