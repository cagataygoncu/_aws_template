FROM --platform=linux/amd64 public.ecr.aws/docker/library/golang:{{LANGUAGE_VERSION}}-bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    libssl-dev \
    curl \
    libcurl4-openssl-dev \
    unzip \
    zlib1g \
    zlib1g-dev \
    libprotobuf-c-dev \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
RUN sed /^StrictHostKeyChecking/d /etc/ssh/ssh_config; \
    echo StrictHostKeyChecking no >> /etc/ssh/ssh_config

# RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
#     unzip awscliv2.zip && \
#     ./aws/install && \
#     rm -rf aws awscliv2.zip

RUN go install -v golang.org/x/tools/gopls@latest \
    && go install -v github.com/go-delve/delve/cmd/dlv@latest

################################################################################################
FROM --platform=linux/amd64 public.ecr.aws/docker/library/golang:{{LANGUAGE_VERSION}}-bookworm AS release

RUN go install -v golang.org/x/tools/gopls@latest

################################################################################################
# FROM release AS final
FROM builder AS final

EXPOSE 8000

