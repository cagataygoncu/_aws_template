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

# Cache deps separately from app code for faster rebuilds
COPY mix.exs mix.lock ./
RUN --mount=type=ssh mix deps.get --only prod && mix deps.compile

COPY .formatter.exs ./
COPY lib ./lib
COPY config ./config 2>/dev/null || true

RUN mix compile && mix release

################################################################################################
# Final stage - minimal runtime with just the release artefacts
FROM ${BASE_IMAGE_URI} AS final

ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libstdc++6 \
    libssl3 \
    locales \
    ncurses-bin \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

WORKDIR /app

# Update the release name to match the `app:` key in mix.exs.
COPY --from=builder /app/_build/prod/rel/{{PROJECT_NAME}} /app

EXPOSE 4000

CMD ["/app/bin/{{PROJECT_NAME}}", "start"]
