# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make local-build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.
#
# C++ Lambda Dockerfile.
# Uses the AWS Lambda C++ Runtime (https://github.com/awslabs/aws-lambda-cpp).
# Build a custom-runtime executable named `bootstrap` for `provided.al2` /
# `provided.al2023`. Make sure your CMakeLists.txt links against
# `aws-lambda-runtime` and produces a target named `bootstrap`.

ARG BASE_IMAGE_URI
# The builder is a separate image from the runtime: this stage needs a C++
# toolchain and apt, while the final stage must be the Lambda custom runtime
# (provided.al2023) the function actually runs on. Point this at an AL2023
# builder if the binary hits a glibc mismatch at runtime.
# mise-sync: ARG BUILDER_IMAGE_URI=public.ecr.aws/docker/library/debian:${mise:debian}
ARG BUILDER_IMAGE_URI=public.ecr.aws/docker/library/debian:${mise:debian}
ARG ENV
ARG DEBUG

################################################################################################
# Builder stage
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

COPY ./CMakeLists.txt /app/CMakeLists.txt
COPY ./src /app/src

WORKDIR /app

RUN --mount=type=ssh \
    cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt \
    && cmake --build build --parallel \
    && cmake --install build

################################################################################################
# Final stage
FROM ${BASE_IMAGE_URI} AS final

ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}

# AWS Lambda's `provided.al2*` runtimes look for /var/runtime/bootstrap.
COPY --from=builder /opt/bin/bootstrap ${LAMBDA_RUNTIME_DIR}/bootstrap

CMD ["bootstrap"]
