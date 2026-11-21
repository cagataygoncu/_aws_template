# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make local-build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.

# Define build arguments
ARG BASE_IMAGE_URI
ARG ENV
ARG DEBUG

################################################################################################
# Builder stage - assemble a Mix release (no compiled deps escape this stage)
FROM ${BASE_IMAGE_URI} AS builder

# The Erlang JIT crashes (exit 139) when this stage runs under QEMU, as it
# does for a linux/amd64 build on an arm64 Mac. One code mapping avoids that;
# it is harmless on a native build. Builder only: the runtime keeps defaults.
ENV ERL_FLAGS="+JMsingle true"

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

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Cache deps separately from app code for faster rebuilds
COPY mix.exs mix.lock ./
# How git reaches private GitHub repositories - a token (the github_token
# build secret) or the ssh agent: make/github_env.sh.
COPY make/github_env.sh /tmp/github_env.sh
RUN --mount=type=ssh --mount=type=secret,id=github_token,required=false export GITHUB_TOKEN="$(cat /run/secrets/github_token 2> /dev/null)" && . /tmp/github_env.sh && mix deps.get --only prod && mix deps.compile

COPY lib ./lib
# A project that adds config/ (config.exs, runtime.exs) adds: COPY config ./config
# COPY cannot skip a missing source, so the layer, which has none, copies none.

RUN mix compile && mix release

################################################################################################
# Final stage - minimal runtime with just the release artefacts
FROM ${BASE_IMAGE_URI} AS final

ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}

ENV DEBIAN_FRONTEND=noninteractive
# Debian packages from system_packages.txt - edit the list, not this step.
COPY system_packages.txt /tmp/system_packages.txt
RUN packages=$(cat /tmp/system_packages.txt | sed -e 's/#.*//' | xargs); \
    if [ -n "$packages" ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages \
        && rm -rf /var/lib/apt/lists/*; \
    fi
RUN locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

WORKDIR /app

# Update the release name to match the `app:` key in mix.exs.
COPY --from=builder /app/_build/prod/rel/{{PROJECT_NAME}} /app

EXPOSE 4000

CMD ["/app/bin/{{PROJECT_NAME}}", "start"]
