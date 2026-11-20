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
FROM ${BASE_IMAGE_URI} AS builder

COPY ./.devcontainer/.bashrc /root/.bashrc

COPY ./.devcontainer/requirements_dev.txt /requirements_dev.txt

################################################################################################
# Dependencies stage - isolated layer for pip installations
FROM ${BASE_IMAGE_URI} AS dependencies

ARG ENV

# Debian packages from system_packages_build.txt and system_packages.txt - edit the list, not this step.
COPY system_packages_build.txt /tmp/system_packages_build.txt
COPY system_packages.txt /tmp/system_packages.txt
RUN packages=$(cat /tmp/system_packages_build.txt /tmp/system_packages.txt | sed -e 's/#.*//' | xargs); \
    if [ -n "$packages" ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages \
        && rm -rf /var/lib/apt/lists/*; \
    fi

RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
RUN sed /^StrictHostKeyChecking/d /etc/ssh/ssh_config; \
    echo StrictHostKeyChecking no >> /etc/ssh/ssh_config

# Copy dev files only (will be removed later if not dev environment)
COPY --from=builder /root/.bashrc /root/.bashrc
COPY --from=builder /requirements_dev.txt /.devcontainer/requirements_dev.txt

# Remove dev files if not in dev environment
RUN if [ "$ENV" != "dev" ]; then \
    rm -rf /.devcontainer; \
fi

COPY requirements.txt requirements.txt

RUN --mount=type=ssh --mount=type=cache,target=/root/.cache/pip \
    export GIT_SSH_COMMAND="ssh -v" && \
    pip3 install --upgrade -r requirements.txt

################################################################################################
# Use dependencies stage as base (inherits system packages and Python dependencies)
FROM dependencies

# Set environment variables, re-declared to convert to ENV variables
ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}

WORKDIR /

COPY ./src ./src
COPY ./lib ./lib

EXPOSE 5040

ENV PYTHONPATH=/
