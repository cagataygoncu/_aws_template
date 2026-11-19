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
#   make check                                shell + Makefile syntax, manifest
#   make classify src/main.py                 who owns a project file
#   make render-all [REF=v1.0.0] [LINT=1]     render and check every language
#   make upgrade ../my_project [v1.1.0]       merge a newer release into a project
#   make upgrade-guess ../old_project         which version an unstamped project is on
#
# `new` is a pass-through to ./make/bootstrap.sh, which holds the logic.

BOOTSTRAP := ./make/bootstrap.sh

# Toolchain version for the new project, empty meaning the language's default
# in <language>/mise.toml. It is written into the new project's mise.toml,
# which stays its one record. OTP_VERSION applies to elixir only.
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

.PHONY: help new languages template-version check check-manifest classify render-all \
        upgrade upgrade-guess

help:
	@echo "usage: make <target> [arguments]"
	@echo ""
	@echo "  new       <language> <project_name> [destination]   scaffold a project"
	@echo "            add LANGUAGE_VERSION=... to override the toolchain version"
	@echo "  languages                                           languages available"
	@echo "  template-version [version]                          gig-cfn-templates release"
	@echo "                                                      that _base/ ships"
	@echo "  check                                               syntax-check the template,"
	@echo "                                                      then check-manifest"
	@echo "  check-manifest                                      every generated file has an"
	@echo "                                                      owner in template_manifest.txt"
	@echo "  classify  <path>...                                 owner of a project path"
	@echo "  render-all                                          render every language and check it;"
	@echo "            REF=<tag> OUT=<dir> LANGUAGES=\"a b\" LINT=1 BUILD=1"
	@echo "  upgrade   <project_dir> [ref]                       merge a release (default: latest tag)"
	@echo "            into a project, on a new branch; NO_BRANCH=1 FORCE=1"
	@echo "  upgrade-guess <project_dir>                         rank template commits against an"
	@echo "            unstamped project; WRITE=1 stamps the best match"
	@echo ""
	@echo "A generated project has its own Makefile: cd into it and run 'make help'."

new:       ; @$(BOOTSTRAP) $(ARGS)
# A language is a folder with a layer.env - the same rule make/bootstrap.sh
# uses. A project scaffolded in place has none, so it is not listed.
languages: ; @for layer in */layer.env; do echo "  - $${layer%/layer.env}"; done

# Runs inside _base/, which is a project layout as far as commands.sh cares:
# it has targets/ and its own commands.sh.
template-version: ; @cd _base && ./make/commands.sh template-version $(ARGS)

check:
	@for script in make/*.sh _base/make/commands.sh _base/make/versions.sh; do \
	    bash -n "$$script" && echo "ok  $$script"; \
	done
	@zsh -n _base/make/setup_local_dev_env.sh && echo "ok  _base/make/setup_local_dev_env.sh"
	@$(MAKE) --dry-run --directory=_base help > /dev/null && echo "ok  _base/Makefile"
	@$(MAKE) --no-print-directory check-manifest

check-manifest: ; @./make/manifest.sh check
classify:       ; @./make/manifest.sh classify $(ARGS)

# Passed explicitly, so a value set on the command line reaches the script
# whatever make's export rules say.
render-all: ; @REF="$(REF)" OUT="$(OUT)" LANGUAGES="$(LANGUAGES)" LINT="$(LINT)" BUILD="$(BUILD)" ./make/render_all.sh
upgrade:    ; @NO_BRANCH="$(NO_BRANCH)" FORCE="$(FORCE)" ./make/upgrade.sh run $(ARGS)
upgrade-guess: ; @WRITE="$(WRITE)" GUESS_LIMIT="$(GUESS_LIMIT)" ./make/upgrade.sh guess $(ARGS)
