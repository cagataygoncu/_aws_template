# _aws_template Makefile
#
# Scaffolding for the template itself. Generated projects carry their own
# Makefile and commands.sh (from _base/) for deployment - run `make help`
# inside one of those.
#
#   make new python my_match_stats            creates ../my_match_stats
#   make new golang my_ranking_pipeline /tmp/rp
#   make languages
#   make template-version [version]           gig-cfn-templates release _base/ ships
#   make check                                shell + Makefile syntax
#
# `new` is a pass-through to ./make/bootstrap.sh, which holds the logic.

BOOTSTRAP := ./make/bootstrap.sh

# Toolchain version for the new project, empty meaning the language's default
# in make/bootstrap.sh. OTP_VERSION applies to elixir only.
#
#   make new python my_project LANGUAGE_VERSION=3.13
LANGUAGE_VERSION ?=
OTP_VERSION      ?=
export LANGUAGE_VERSION
export OTP_VERSION

# Positional arguments: every goal after the target name. They are declared
# phony no-ops so make does not try to build them. The target itself is never
# in this list, so a mistyped target still fails.
ARGS := $(filter-out $(firstword $(MAKECMDGOALS)),$(MAKECMDGOALS))
ifneq ($(ARGS),)
.PHONY: $(ARGS)
$(ARGS): ; @:
endif

.DEFAULT_GOAL := help

.PHONY: help new languages template-version check

help:
	@echo "usage: make <target> [arguments]"
	@echo ""
	@echo "  new       <language> <project_name> [destination]   scaffold a project"
	@echo "            add LANGUAGE_VERSION=... to override the toolchain version"
	@echo "  languages                                           languages available"
	@echo "  template-version [version]                          gig-cfn-templates release"
	@echo "                                                      that _base/ ships"
	@echo "  check                                               syntax-check the template"
	@echo ""
	@echo "A generated project has its own Makefile: cd into it and run 'make help'."

new:       ; @$(BOOTSTRAP) $(ARGS)
# Read out of make/bootstrap.sh rather than listed here, and rather than taken
# from the directory listing, which also shows any project scaffolded in place.
languages: ; @sed -n 's/^valid_languages=(\(.*\))$$/\1/p' $(BOOTSTRAP) | tr ' ' '\n' | sed 's|^|  - |'

# Runs inside _base/, which is a project layout as far as commands.sh cares:
# it has targets/ and its own commands.sh.
template-version: ; @cd _base && ./make/commands.sh template-version $(ARGS)

check:
	@for script in make/bootstrap.sh _base/make/commands.sh; do \
	    bash -n "$$script" && echo "ok  $$script"; \
	done
	@zsh -n _base/make/setup_local_dev_env.sh && echo "ok  _base/make/setup_local_dev_env.sh"
	@$(MAKE) --dry-run --directory=_base help > /dev/null && echo "ok  _base/Makefile"
