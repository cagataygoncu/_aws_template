# Matches the elixir base image in targets/service/Dockerfile.
# mise-sync: FROM public.ecr.aws/docker/library/elixir:${mise:elixir}-otp-${mise:erlang}
FROM public.ecr.aws/docker/library/elixir:${mise:elixir}-otp-${mise:erlang}

# Debian packages from system_packages_build.txt and system_packages.txt - edit the list, not this step.
COPY system_packages_build.txt /tmp/system_packages_build.txt
COPY system_packages.txt /tmp/system_packages.txt
RUN packages=$(cat /tmp/system_packages_build.txt /tmp/system_packages.txt | sed -e 's/#.*//' | xargs); \
    if [ -n "$packages" ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages \
        && rm -rf /var/lib/apt/lists/*; \
    fi

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
