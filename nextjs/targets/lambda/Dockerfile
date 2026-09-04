# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make local-build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.
#
# Note: deploying Next.js as a Lambda is uncommon — most projects use the
# `service/server` target (long-running container behind ALB / API GW).
# This Dockerfile is a starting point for Node.js handlers if you need it;
# review carefully before using it for a Next.js project.

ARG BASE_IMAGE_URI
ARG ENV
ARG DEBUG

################################################################################################
# Dependencies stage
FROM ${BASE_IMAGE_URI} AS dependencies

WORKDIR /var/task

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

################################################################################################
# Final stage - copy dependencies + handler source into Lambda image
FROM ${BASE_IMAGE_URI}

ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}

WORKDIR /var/task

COPY --from=dependencies /var/task/node_modules ./node_modules
COPY ./src ./src

# Update the handler path to point to your exported handler (file.export).
CMD ["src/lambda.handler"]
