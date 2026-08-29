# Makefile
#
# Every target is a pass-through to ./make/commands.sh, which holds the actual
# logic as one function per command. Run `make help` for the full list, or
# `./make/commands.sh <command> ...` directly when debugging.
#
#   make local-dev-setup               create/update ./venv from environment.yaml
#   make template-version [version]     nested gig-cfn-templates release
#   make info          [target]
#   make validate      [target]
#   make deploy-cicd   [target]        create/update the pipeline stack
#   make push          [branch]        push to CodeCommit, start the pipeline
#   make pipeline                      stage states
#   make outputs       [stack]
#   make url
#   make logs          [log-group]
#   make delete-all
#   make build         [target]
#   make run           ENTRYPOINT=... CMD="..." [RUN_ENV="KEY=VALUE ..."]
#
# A target is the path under targets/ holding a cicd_parameters.json:
# lambda, service/task, service/server. Set TARGET below to
# the one this project deploys, and it becomes the default everywhere:
#
#   make deploy-cicd                   uses $(TARGET)
#   make deploy-cicd lambda            just this once
#
# Override the project or the account per invocation:
#
#   make deploy-cicd lambda PROJECT_NAME=lambda-test-1
#   make outputs AWS_PROFILE=gig-prod

PROJECT_NAME ?= $(notdir $(CURDIR))
TARGET       ?= service/task
AWS_PROFILE  ?= gig-nonprod
AWS_REGION   ?= ap-southeast-2
# The port the app listens on inside the container - what `make run` publishes
# to, and what ContainerPort defaults to in the deployment template.
CONTAINER_PORT ?= {{CONTAINER_PORT}}
export PROJECT_NAME
export TARGET
export AWS_PROFILE
export AWS_REGION
export CONTAINER_PORT
export BUILD_PLATFORM

# Arguments for `make run`. Quoted here rather than passed positionally,
# because make splits its goals on whitespace and CMD usually contains some.
ENTRYPOINT ?=
CMD        ?=
JSON       ?= {}
# Platform `make build` builds for. Empty derives it from the target's
# CodeBuildImage, so a local image matches what the pipeline produces. Set
# linux/arm64 for a fast native build that is NOT what deploys.
BUILD_PLATFORM ?=

# Application environment for `make run`, as "KEY=VALUE KEY2=VALUE2".
# MODE=local is the default because this target only ever runs on a dev
# machine; the deployed code sets nothing and so runs online. Overriding this
# variable replaces it, so keep MODE=... in whatever you pass.
RUN_ENV    ?= MODE=local

COMMANDS := ./make/commands.sh

# Positional arguments: every goal after the target name. They are declared
# phony no-ops so make does not try to build them. The target itself is never
# in this list, so a mistyped target still fails.
ARGS := $(filter-out $(firstword $(MAKECMDGOALS)),$(MAKECMDGOALS))
ifneq ($(ARGS),)
.PHONY: $(ARGS)
$(ARGS): ; @:
endif

.DEFAULT_GOAL := help

.PHONY: help local-dev-setup info targets template-version aws-info validate deploy-cicd remote push pipeline \
        pipeline-stop outputs output-value url events logs delete-stack \
        delete-cicd delete-all build run invoke local-logs shell stop

help:          ; @$(COMMANDS) help
local-dev-setup: ; @$(COMMANDS) local-dev-setup
info:          ; @$(COMMANDS) info          $(ARGS)
targets:       ; @$(COMMANDS) targets
template-version: ; @$(COMMANDS) template-version $(ARGS)
aws-info:      ; @$(COMMANDS) aws-info

validate:      ; @$(COMMANDS) validate      $(ARGS)
deploy-cicd:   ; @$(COMMANDS) deploy-cicd   $(ARGS)
remote:        ; @$(COMMANDS) remote
push:          ; @$(COMMANDS) push          $(ARGS)
pipeline:      ; @$(COMMANDS) pipeline
pipeline-stop: ; @$(COMMANDS) pipeline-stop

outputs:       ; @$(COMMANDS) outputs       $(ARGS)
output-value:  ; @$(COMMANDS) output-value  $(ARGS)
url:           ; @$(COMMANDS) url
events:        ; @$(COMMANDS) events        $(ARGS)
logs:          ; @$(COMMANDS) logs          $(ARGS)

delete-stack:  ; @$(COMMANDS) delete-stack
delete-cicd:   ; @$(COMMANDS) delete-cicd
delete-all:    ; @$(COMMANDS) delete-all

build:         ; @$(COMMANDS) build         $(ARGS)
run:           ; @RUN_ENV="$(RUN_ENV)" $(COMMANDS) run "$(ENTRYPOINT)" "$(CMD)" "$(TARGET)"
invoke:        ; @$(COMMANDS) invoke        '$(JSON)'
local-logs:    ; @$(COMMANDS) local-logs
shell:         ; @$(COMMANDS) shell
stop:          ; @$(COMMANDS) stop
