# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make local-build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.
#
# Note: Elixir on Lambda is unusual — the BEAM VM startup cost is high.
# Most Elixir AWS workloads run as long-lived containers (use the
# `service/server` target). This is a starting point if you really need it.
# It builds a Mix release and packages it for the `provided.al2` custom
# runtime via a `bootstrap` shell script that boots the release.

ARG BASE_IMAGE_URI
# The builder is a separate image from the runtime: this stage needs Elixir,
# Erlang and apt, while the final stage must be the Lambda custom runtime
# (provided.al2023) the release actually runs on. The release embeds its ERTS,
# so the two images do not have to match.
# mise-sync: ARG BUILDER_IMAGE_URI=public.ecr.aws/docker/library/elixir:${mise:elixir}-otp-${mise:erlang}
ARG BUILDER_IMAGE_URI=public.ecr.aws/docker/library/elixir:${mise:elixir}-otp-${mise:erlang}
ARG ENV
ARG DEBUG

################################################################################################
# Builder stage - Mix release
FROM ${BUILDER_IMAGE_URI} AS builder

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
# Final stage - copy release into Lambda runtime image
FROM ${BASE_IMAGE_URI} AS final

ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}

# Update the release name to match the `app:` key in mix.exs.
COPY --from=builder /app/_build/prod/rel/{{PROJECT_NAME}} ${LAMBDA_RUNTIME_DIR}/release

# `bootstrap` is the entrypoint Lambda's `provided.al2*` runtime expects.
# Replace this with a real handler that talks to the Lambda Runtime API.
RUN printf '#!/bin/sh\nexec ${LAMBDA_RUNTIME_DIR}/release/bin/{{PROJECT_NAME}} start\n' \
    > ${LAMBDA_RUNTIME_DIR}/bootstrap \
    && chmod +x ${LAMBDA_RUNTIME_DIR}/bootstrap

CMD ["bootstrap"]
