# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# BASE_IMAGE_URI has no default on purpose: the image comes from the
# target's cicd_parameters.json, passed in by `make local-build` and by the
# pipeline's buildspec. Skipping the lint keeps that one source of truth.
ARG BASE_IMAGE_URI

################################################################################################
# Builder stage - compile the TypeScript with the dev dependencies present
FROM ${BASE_IMAGE_URI} AS builder

WORKDIR /var/task

COPY package.json package-lock.json* ./
RUN npm install

COPY tsconfig.json ./
COPY ./src ./src
COPY ./lib ./lib

RUN npm run build

################################################################################################
# Dependencies stage - production node_modules only, no devDependencies
FROM ${BASE_IMAGE_URI} AS dependencies

WORKDIR /var/task

COPY package.json package-lock.json* ./
RUN npm install --omit=dev

################################################################################################
# Final stage - the runtime image, with its own entrypoint kept
FROM ${BASE_IMAGE_URI} AS final

ARG ENV
ARG DEBUG
ENV APP_ENV=${ENV}
ENV DEBUG_MODE=${DEBUG}

WORKDIR /var/task

COPY --from=dependencies /var/task/node_modules ./node_modules
COPY --from=builder /var/task/build ./build
COPY package.json ./

# The handler, as <path>.<export>. Set by ContainerCmd in the deployment
# template; this is what a bare `docker run` gets.
CMD ["build/src/main_lambda.handler"]
