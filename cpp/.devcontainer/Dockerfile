# FROM --platform=linux/amd64 public.ecr.aws/ubuntu/ubuntu:24.04
# No --platform pin, unlike the target Dockerfiles: this image follows the host
# architecture on purpose. gdb debugs through ptrace, and ptrace on an emulated
# process fails, so a pinned image gets as far as building and then dies with
# an i/o error the moment the debugger attaches. The pin here was linux/arm64,
# which is native on an Apple Silicon Mac but emulated on the x86_64 builder -
# so debugging worked in one place and not the other. The deployed images get
# their platform from the build command (build_platform() in
# make/commands.sh); fidelity to them comes from the service and lambda
# variants, not from here.
#
# The image itself is {{BASE_IMAGE_SERVICE}}, substituted at bootstrap from the
# same value the deployed service image uses - debian:bookworm by default. It
# was hardcoded to ubuntu:22.04, so the dev container and the deployed image
# were different distributions and LANGUAGE_VERSION never reached this file.
FROM {{BASE_IMAGE_SERVICE}} AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libssl-dev libcurl4-openssl-dev openssh-client

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    cmake \
    git \
    apt-utils iproute2 procps lsb-release \
    zip unzip tar curl wget \
    libcurl4-openssl-dev uuid-dev libpulse-dev \
    zlib1g \
    zlib1g-dev \
    libprotobuf-c-dev \
    gdb \
    libgl1-mesa-dev libglfw3-dev

RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
RUN sed /^StrictHostKeyChecking/d /etc/ssh/ssh_config; \
    echo StrictHostKeyChecking no >> /etc/ssh/ssh_config

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip

# Download bash completion script
RUN curl -L "https://raw.githubusercontent.com/scop/bash-completion/refs/heads/main/bash_completion" -o /etc/bash_completion

########################################################################################################
FROM {{BASE_IMAGE_SERVICE}} AS release

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libssl-dev libcurl4-openssl-dev openssh-client

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    libcurl4 \
    zlib1g \
    libprotobuf-c1

########################################################################################################
FROM builder AS nats_build
# Install NATS C client
WORKDIR /workspace
RUN git clone https://github.com/nats-io/nats.c.git /workspace/nats.c \
    && cd /workspace/nats.c \
    && mkdir build \
    && cd build \
    && cmake .. \
    && make \
    && make install \
    && ldconfig

RUN mkdir -p /deps && \
    mkdir -p /deps/lib && cp -r /usr/local/lib/* /deps/lib/ && \
    mkdir -p /deps/include && cp -r /usr/local/include/* /deps/include/

########################################################################################################
FROM builder AS aws_sdk_build
# WORKDIR /workspace
# RUN git clone https://github.com/Microsoft/vcpkg.git /workspace/vcpkg \
#     && cd /workspace/vcpkg \
#     && ./bootstrap-vcpkg.sh \
#     && echo 'export PATH=$PATH:/workspace//vcpkg' >> ~/.bashrc

# WORKDIR /workspace
# RUN VERBOSE=1 vcpkg install aws-sdk-cpp[core,s3,dynamodb,secretsmanager]

# Install AWS SDK
# cmake .. -DBUILD_ONLY="s3;dynamodb;lambda;ecs;cloudformation;cloudfront;medialive;mediaconnect;cloudwatch" -DCMAKE_BUILD_TYPE=Release
# https://github.com/awsdocs/aws-doc-sdk-examples/tree/main/cpp/example_code
WORKDIR /workspace
RUN git clone --recurse-submodules https://github.com/aws/aws-sdk-cpp /workspace/aws-sdk-cpp \
    && cd /workspace/aws-sdk-cpp \
    && mkdir build \
    && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Debug -DCMAKE_PREFIX_PATH=/usr/local/ -DCMAKE_INSTALL_PREFIX=/usr/local/ -DBUILD_TESTS=OFF -DBUILD_SAMPLES=OFF -DBUILD_ONLY="core;s3;dynamodb;secretsmanager" \
    && make \
    && make install

RUN mkdir -p /deps && \
    mkdir -p /deps/lib && cp -r /usr/local/lib/* /deps/lib/ && \
    mkdir -p /deps/include && cp -r /usr/local/include/* /deps/include/

########################################################################################################
# FROM release AS final
FROM builder AS final
# FROM nats_build AS final
# FROM aws_sdk_build AS final

WORKDIR /workspace

RUN echo "set auto-load safe-path /" >> /root/.gdbinit \
    && chmod 0600 /root/.gdbinit

COPY --from=nats_build /deps/include/ /usr/local/include/
COPY --from=nats_build /deps/lib/ /usr/local/lib/

COPY --from=aws_sdk_build /deps/include/ /usr/local/include/
COPY --from=aws_sdk_build /deps/lib/ /usr/local/lib/

RUN ln -s /usr/local/lib/libnats.so.3.10.0 /usr/lib/libnats.so.3.10.0 \
    && ln -s /usr/local/lib/libnats_static.a /usr/lib/libnats_static.a
