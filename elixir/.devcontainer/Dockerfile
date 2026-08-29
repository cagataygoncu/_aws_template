# Matches the elixir base image in targets/service/Dockerfile.
FROM public.ecr.aws/docker/library/elixir:{{LANGUAGE_VERSION}}-otp-{{OTP_VERSION}}

COPY ./.devcontainer/.bashrc /root/.bashrc

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get -y install --no-install-recommends \
        curl unzip git procps iproute2 lsb-release ca-certificates openssh-client \
        tree inotify-tools build-essential \
    && rm -rf /var/lib/apt/lists/*

# After openssh-client, which slim images do not ship.
RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
RUN sed /^StrictHostKeyChecking/d /etc/ssh/ssh_config; \
    echo StrictHostKeyChecking no >> /etc/ssh/ssh_config

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /workspace
