# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make local-build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.

# Define build arguments
ARG BASE_IMAGE_URI
# The builder is a separate image from the runtime: this stage needs a Go
# toolchain and apt, while the final stage must be the Lambda custom runtime
# (provided.al2023) the function actually runs on.
# mise-sync: ARG BUILDER_IMAGE_URI=public.ecr.aws/docker/library/golang:${mise:go}-bookworm
ARG BUILDER_IMAGE_URI=public.ecr.aws/docker/library/golang:${mise:go}-bookworm
ARG ENV
ARG DEBUG
ARG GITHUB_TOKEN

################################################################################################
# Builder stage - compile a static binary for AWS Lambda (provided.al2 / al2023)
FROM ${BUILDER_IMAGE_URI} AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Debian packages from system_packages_build.txt - edit the list, not this step.
COPY system_packages_build.txt /tmp/system_packages_build.txt
RUN packages=$(cat /tmp/system_packages_build.txt | sed -e 's/#.*//' | xargs); \
    if [ -n "$packages" ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages \
        && rm -rf /var/lib/apt/lists/*; \
    fi

RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
RUN sed /^StrictHostKeyChecking/d /etc/ssh/ssh_config; \
    echo StrictHostKeyChecking no >> /etc/ssh/ssh_config

COPY ./src /app/src
COPY ./go.mod /app/go.mod
COPY ./go.sum /app/go.sum

WORKDIR /app

# Build a CGO-disabled static binary named `bootstrap` — the entrypoint expected
# by AWS Lambda's `provided.al2` and `provided.al2023` runtimes.
# How git reaches private GitHub repositories - a token (the github_token
# build secret) or the ssh agent: make/github_env.sh.
COPY make/github_env.sh /tmp/github_env.sh
RUN --mount=type=ssh --mount=type=secret,id=github_token,required=false \
    export GOPRIVATE=github.com/GIGTennis/* && \
    export GONOSUMDB=github.com/GIGTennis/* && \
    export GITHUB_TOKEN="$(cat /run/secrets/github_token 2> /dev/null)" && . /tmp/github_env.sh && \
    export GIT_SSH_COMMAND="ssh -v" && \
    go mod tidy && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -tags lambda.norpc -ldflags="-s -w" -o /app/build/bootstrap ./src/main_lambda

################################################################################################
# Final stage - copy the bootstrap binary into the Lambda runtime image
FROM ${BASE_IMAGE_URI} AS final

ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}

COPY --from=builder /app/build/bootstrap ${LAMBDA_RUNTIME_DIR}/bootstrap

CMD ["bootstrap"]
