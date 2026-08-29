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

RUN go install -v golang.org/x/tools/gopls@latest \
    && go install -v github.com/go-delve/delve/cmd/dlv@latest \
    && go install -v golang.org/x/tools/gopls@latest

COPY ./src /app/src
COPY ./go.mod /app/go.mod
COPY ./go.sum /app/go.sum

WORKDIR /app

RUN --mount=type=ssh \
    git config --global url."git@github.com:GIGTennis/".insteadOf "https://github.com/GIGTennis/" && \
    export GOPRIVATE=github.com/GIGTennis/* && \
    export GONOSUMDB=github.com/GIGTennis/* && \
    export GIT_SSH_COMMAND="ssh -v" && \
    go mod tidy && go build -o /app/build/main src/*.go

################################################################################################
# FROM release AS final
FROM ${BASE_IMAGE_URI} AS final

COPY --from=builder /app/build/main /app/build/main

WORKDIR /app/build

EXPOSE 5040

