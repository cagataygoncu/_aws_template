# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.
ARG BASE_IMAGE_URI

################################################################################################
# Dependencies stage - install node_modules
FROM ${BASE_IMAGE_URI} AS dependencies

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

################################################################################################
# Build stage - build the Next.js app (needs devDependencies for tailwindcss, postcss, typescript)
FROM ${BASE_IMAGE_URI} AS builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

RUN npm run build

################################################################################################
# Production stage - minimal image
FROM ${BASE_IMAGE_URI}

WORKDIR /app

ENV NODE_ENV=production

COPY --from=dependencies /app/node_modules ./node_modules
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/package.json ./
COPY --from=builder /app/server.mjs ./

EXPOSE 3000
