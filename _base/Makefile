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
#   make config        [target]        where the env file is read from, is it there
#   make config-upload [target]        upload it - the pipeline does not
#   make deploy-cicd   [target]        create/update the pipeline stack
#   make push      <branch>            push <branch> to CodeCommit main
#   make upload    <host> <directory>  rsync this project to a remote host
#   make pipeline                      stage states, with times
#   make pipeline-errors               why the last run failed
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
# `make upload` copies the working tree to a box over ssh, for a project that
# has no remote to clone from yet, or changes you do not want to commit just to
# move them. The host is an entry in ~/.ssh/config; the directory is relative
# to the remote home unless it starts with /. Both are required - neither has a
# default, because a destination you cannot see in the command is one you
# cannot recall later:
#
#   make upload gig-builder-aolabs dev
#   make upload gig-builder-aolabs /media/data/projects
#   make upload gig-builder-aolabs dev DRY_RUN=1     what would transfer
#   make upload gig-builder-aolabs dev WITH_GIT=1    take the history too
#
# PROJECT_NAME and TARGET have no fallback inside commands.sh: they select
# which stack and which target everything else acts on, so they are declared
# here where you can see them, and running commands.sh directly without them
# fails rather than guessing. Override either for one invocation:
#
#   make deploy-cicd PROJECT_NAME=lambda-test-1
#   TARGET=lambda make build
#
# Override the project or the account per invocation:
#
#   make deploy-cicd lambda PROJECT_NAME=lambda-test-1
#   make outputs AWS_PROFILE=gig-prod

# PROJECT_NAME, TARGET, AWS_PROFILE and AWS_REGION come from project.env, not
# from here: a value inferred by a script is one you cannot see, and
# PROJECT_NAME inferred from the directory name silently targets whatever stack
# the folder happens to be called after. commands.sh reads the same file, so a
# direct ./make/commands.sh behaves identically.
#
# Override one for a single run in the usual way, which still wins:
#   make deploy-cicd PROJECT_NAME=lambda-test-1
PROJECT_CONFIG ?= project.env
ifeq ($(wildcard $(PROJECT_CONFIG)),)
$(error $(PROJECT_CONFIG) not found - it declares PROJECT_NAME, TARGET, AWS_PROFILE and AWS_REGION)
endif
include $(PROJECT_CONFIG)
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
# Exported so `make info` reports the value `make run` would use. It must come
# AFTER the assignment: `export VAR` on its own defines VAR as empty, and the
# ?= above would then decline to set it - which silently drops MODE=local.
export RUN_ENV

# `make upload` destination. Neither has a default on purpose: pass them on the
# command line, or export them for a shell that is working on one box.
REMOTE_HOST ?=
REMOTE_DIR  ?=
export REMOTE_HOST
export REMOTE_DIR
export DRY_RUN
export WITH_GIT

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

.PHONY: help local-dev-setup info targets template-version aws-info validate config config-upload deploy-cicd remote push pipeline \
        pipeline-stop upload outputs output-value url events logs delete-stack \
        delete-cicd delete-all build run invoke local-logs shell stop

help:          ; @$(COMMANDS) help
local-dev-setup: ; @$(COMMANDS) local-dev-setup
info:          ; @$(COMMANDS) info          $(ARGS)
targets:       ; @$(COMMANDS) targets
template-version: ; @$(COMMANDS) template-version $(ARGS)
aws-info:      ; @$(COMMANDS) aws-info

validate:      ; @$(COMMANDS) validate      $(ARGS)
config:        ; @$(COMMANDS) config        $(ARGS)
config-upload: ; @$(COMMANDS) config-upload $(ARGS)
deploy-cicd:   ; @$(COMMANDS) deploy-cicd   $(ARGS)
remote:        ; @$(COMMANDS) remote
push:          ; @$(COMMANDS) push          $(ARGS)
upload:        ; @$(COMMANDS) upload        $(ARGS)
pipeline:      ; @$(COMMANDS) pipeline
pipeline-errors: ; @$(COMMANDS) pipeline-errors
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
