# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.

# Define build arguments
ARG BASE_IMAGE_URI
# The builder is a separate image from the runtime: this stage needs a Go
# toolchain and apt, while the final stage must be the Lambda custom runtime
# (provided.al2023) the function actually runs on.
ARG BUILDER_IMAGE_URI=public.ecr.aws/docker/library/golang:{{LANGUAGE_VERSION}}-bookworm
ARG ENV
ARG DEBUG
ARG GITHUB_TOKEN

################################################################################################
# Builder stage - compile a static binary for AWS Lambda (provided.al2 / al2023)
FROM ${BUILDER_IMAGE_URI} AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
RUN sed /^StrictHostKeyChecking/d /etc/ssh/ssh_config; \
    echo StrictHostKeyChecking no >> /etc/ssh/ssh_config

COPY ./src /app/src
COPY ./go.mod /app/go.mod
COPY ./go.sum /app/go.sum

WORKDIR /app

# Build a CGO-disabled static binary named `bootstrap` — the entrypoint expected
# by AWS Lambda's `provided.al2` and `provided.al2023` runtimes.
RUN --mount=type=ssh \
    git config --global url."git@github.com:GIGTennis/".insteadOf "https://github.com/GIGTennis/" && \
    export GOPRIVATE=github.com/GIGTennis/* && \
    export GONOSUMDB=github.com/GIGTennis/* && \
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
