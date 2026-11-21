# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make local-build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.
ARG BASE_IMAGE_URI

################################################################################################
# Dependencies stage - install node_modules
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

COPY package.json package-lock.json ./
# Private packages come from GitHub over ssh: the agent is mounted for this
# step only, and GitHub's host key is trusted first. Without git and ssh (in
# system_packages_build.txt) the key step is skipped and npm runs as before.
RUN --mount=type=ssh (mkdir -p -m 0700 ~/.ssh \
        && ssh-keyscan github.com >> ~/.ssh/known_hosts) 2> /dev/null || true; \
    npm ci --omit=dev

################################################################################################
# Build stage - build the Next.js app (needs devDependencies for tailwindcss, postcss, typescript)
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

COPY package.json package-lock.json ./
# Private packages come from GitHub over ssh: the agent is mounted for this
# step only, and GitHub's host key is trusted first. Without git and ssh (in
# system_packages_build.txt) the key step is skipped and npm runs as before.
RUN --mount=type=ssh (mkdir -p -m 0700 ~/.ssh \
        && ssh-keyscan github.com >> ~/.ssh/known_hosts) 2> /dev/null || true; \
    npm ci

COPY . .

RUN npm run build

################################################################################################
# Production stage - minimal image
FROM ${BASE_IMAGE_URI}

# Debian packages from system_packages.txt - edit the list, not this step.
COPY system_packages.txt /tmp/system_packages.txt
RUN packages=$(cat /tmp/system_packages.txt | sed -e 's/#.*//' | xargs); \
    if [ -n "$packages" ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages \
        && rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /app

ENV NODE_ENV=production

COPY --from=dependencies /app/node_modules ./node_modules
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/package.json ./
COPY --from=builder /app/server.mjs ./

EXPOSE 3000
