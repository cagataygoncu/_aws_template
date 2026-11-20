# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make local-build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.
ARG BASE_IMAGE_URI

################################################################################################
# Builder stage - install everything and compile the TypeScript
FROM ${BASE_IMAGE_URI} AS builder

# Debian packages from system_packages_build.txt - edit the list, not this step.
COPY system_packages_build.txt /tmp/system_packages_build.txt
RUN packages=$(cat /tmp/system_packages_build.txt | sed -e 's/#.*//' | xargs); \
    if [ -n "$packages" ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages \
        && rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /app

# package.json alone first: this layer only rebuilds when the dependencies
# change, not on every source edit.
COPY package.json package-lock.json* ./
RUN npm install

COPY tsconfig.json ./
COPY ./src ./src
COPY ./lib ./lib

RUN npm run build

################################################################################################
# Dependencies stage - production node_modules only, no devDependencies
FROM ${BASE_IMAGE_URI} AS dependencies

# Debian packages from system_packages_build.txt - edit the list, not this step.
COPY system_packages_build.txt /tmp/system_packages_build.txt
RUN packages=$(cat /tmp/system_packages_build.txt | sed -e 's/#.*//' | xargs); \
    if [ -n "$packages" ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages \
        && rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --omit=dev

################################################################################################
# Final stage - the compiled JavaScript and the runtime dependencies, nothing else
FROM ${BASE_IMAGE_URI} AS final

# Debian packages from system_packages.txt - edit the list, not this step.
COPY system_packages.txt /tmp/system_packages.txt
RUN packages=$(cat /tmp/system_packages.txt | sed -e 's/#.*//' | xargs); \
    if [ -n "$packages" ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages \
        && rm -rf /var/lib/apt/lists/*; \
    fi

ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}
ENV NODE_ENV=production

WORKDIR /app

COPY --from=dependencies /app/node_modules ./node_modules
COPY --from=builder /app/build ./build
COPY package.json ./

EXPOSE {{CONTAINER_PORT}}

# Overridden per target by ContainerEntryPoint and ContainerCmd in the
# deployment template - task and server run different files out of the same
# image. This is what a bare `docker run` gets.
CMD ["node", "build/src/main_server.js"]
