# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make build` and by the
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
ARG BUILDER_IMAGE_URI=public.ecr.aws/docker/library/elixir:{{LANGUAGE_VERSION}}-otp-{{OTP_VERSION}}
ARG ENV
ARG DEBUG

################################################################################################
# Builder stage - Mix release
FROM ${BUILDER_IMAGE_URI} AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
RUN sed /^StrictHostKeyChecking/d /etc/ssh/ssh_config; \
    echo StrictHostKeyChecking no >> /etc/ssh/ssh_config

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN --mount=type=ssh mix deps.get --only prod && mix deps.compile

COPY .formatter.exs ./
COPY lib ./lib
COPY config ./config 2>/dev/null || true

RUN mix compile && mix release

################################################################################################
# Final stage - copy release into Lambda runtime image
FROM ${BASE_IMAGE_URI} AS final

ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}

# Update the release name to match the `app:` key in mix.exs.
COPY --from=builder /app/_build/prod/rel/example ${LAMBDA_RUNTIME_DIR}/release

# `bootstrap` is the entrypoint Lambda's `provided.al2*` runtime expects.
# Replace this with a real handler that talks to the Lambda Runtime API.
RUN printf '#!/bin/sh\nexec ${LAMBDA_RUNTIME_DIR}/release/bin/example start\n' \
    > ${LAMBDA_RUNTIME_DIR}/bootstrap \
    && chmod +x ${LAMBDA_RUNTIME_DIR}/bootstrap

CMD ["bootstrap"]
