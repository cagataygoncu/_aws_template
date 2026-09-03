# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.

# Define build arguments
ARG BASE_IMAGE_URI
ARG ENV
ARG DEBUG
ARG GITHUB_TOKEN

################################################################################################
FROM ${BASE_IMAGE_URI} AS builder

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

# gopls and dlv track the newest Go release, and the official golang image sets
# GOTOOLCHAIN=local, which forbids fetching a newer toolchain to build them:
#   gopls@v0.23.0 requires go >= 1.26.0 (running go 1.25.14; GOTOOLCHAIN=local)
# GOTOOLCHAIN=auto lets the tool build with whatever it needs, while the
# application below still builds with the pinned language_version.

COPY ./src /app/src
COPY ./go.mod /app/go.mod
COPY ./go.sum /app/go.sum

WORKDIR /app

RUN --mount=type=ssh \
    git config --global url."git@github.com:GIGTennis/".insteadOf "https://github.com/GIGTennis/" && \
    export GOPRIVATE=github.com/GIGTennis/* && \
    export GONOSUMDB=github.com/GIGTennis/* && \
    export GIT_SSH_COMMAND="ssh -v" && \
    go mod tidy \
    && go build -o /app/build/task   ./src/main_task \
    && go build -o /app/build/server ./src/main_server

################################################################################################
# FROM release AS final
FROM ${BASE_IMAGE_URI} AS final

ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}

# One binary per entrypoint; ContainerCmd in the target's deployment.yaml picks
# which one runs, the same way python selects src/main_task.py or
# src.main_server:app.
COPY --from=builder /app/build/task   /app/build/task
COPY --from=builder /app/build/server /app/build/server

WORKDIR /app/build

EXPOSE 5040

