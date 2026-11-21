# Upgrading an existing project

## The automated way (v1.0.0 and later)

```zsh
make upgrade-guess "$PROJECT" WRITE=1    # only if the project has no .template.env
make upgrade "$PROJECT"                  # to the latest tag; or: make upgrade "$PROJECT" v1.1.0
```

`make upgrade` does the copying and merging described below, file by file, on
a new branch. It writes a report and a `seed.patch` into the project's
`.git/template-upgrade/<version>/`. You resolve the conflicts it marks, port
`seed.patch` by hand, then run `make lint`. The `cg-aws-template-upgrade`
skill walks through all of it. How it decides is in NOTES.md, **Upgrading a
project that already exists**. The rest of this file is the manual procedure
it automates, and the per-release **Changes to expect**, which still say what
each change means for a project.

## The manual way

Projects made with `make/bootstrap.sh` are **copies**, not clones — nothing links a
generated project back to this template, so there is no `git pull` that brings
template changes in. Upgrading is a deliberate, file-by-file copy, done by
whoever has `_aws_template` checked out locally, and pushed to the project's
own repository as an ordinary commit.

`aws-service-template` is the worked example throughout: it lives in the team's
GitHub account, while `_aws_template` stays on one machine.

The same applies to the template itself: `_base/` carries the
`gig-cfn-templates` release new projects inherit, so
`make template-version [version]` at the template root is worth running when a
new release is published.

```zsh
export TEMPLATE=~/Dropbox/my/_templates/_aws_template
export PROJECT=~/Dropbox/my/_templates/aws-service-template
export LANGUAGE=python          # python | golang | typescript | cpp | nextjs | elixir
```

## What is owned by whom

The upgrade is only as safe as this table. Copy the first group without
thinking; look at every file in the second; never touch the third.

`template_manifest.txt` at the template root is the machine-readable form of
this table, rule by rule, checked against every language by `make check`.
`make classify <path>...` names the owner of a project path: `template` (the
first three rows), `seed` (the project row) or `stamp` (`.template.env`).
Where the table and the manifest disagree, the manifest is right.

| Owner | Files | Action |
|---|---|---|
| **Template** (`_base/`) | `Makefile`, `make/setup_local_dev_env.sh`, `targets/common/{cicd,buildspec,buildspec_test}.yaml`, `.github/workflows/`, `.dockerignore`, `.gitignore`, `tests/integration/` | copy verbatim |
| **Template, with placeholders** | `make/commands.sh`, `README.md` | copy, then substitute — see below |
| **Language** (`<language>/`) | `targets/{lambda,service}/Dockerfile`, `environment.yaml`, `.devcontainer/`, `.vscode/` | copy, then re-substitute placeholders |
| **Project** | `src/`, `lib/`, `tests/unit/`, `requirements.txt` / `go.mod` / `mix.exs` / `package.json`, `project.env`, `container_config.env`, `data/`, `targets/*/deployment.yaml`, `targets/*/cicd_parameters.json`, `targets/*/deployment_parameters.json` | never overwrite — diff and merge by hand |

`deployment.yaml`, `cicd_parameters.json` and `deployment_parameters.json` sit
in the project column because real projects edit them: added resources, tuned
CPU/memory, their own `ProjectName`, `DomainName` and `RunTests`. Read the
template's version, port the change, keep the project's values.

`make/commands.sh` moved out of the "copy verbatim" row when `make lint`
arrived: it now carries `{{LINT_TOOL}}`, `{{LINT_COMMAND}}` and
`{{LINT_INSTALL}}` near the top, filled in per language by `bootstrap.sh`.
Copying it straight in leaves the placeholders, and `make lint` then reports
`{{LINT_TOOL}} is not installed`. Take the values from
`<language>/layer.env`.

`README.md` is template-owned now — `_base/README.md` documents every command
and is bootstrapped into new projects. Projects that added their own notes
(a link to the team's runbook, say) should re-apply them after copying rather
than skipping the copy.

## Placeholders

`_base/` and the language layers are not directly usable — `make/bootstrap.sh`
substitutes a set of `{{TOKENS}}`, and a straight copy into an existing project
skips that step. After copying, check for leftovers — this catches every one of
them, whatever they are called:

```zsh
cd "$PROJECT"
grep -rn '{{[A-Z_]\{2,\}}}' . \
    --exclude-dir=.git --exclude-dir=venv --exclude-dir=node_modules --exclude-dir=build
```

(The `[A-Z_]` class matters: `commands.sh` legitimately contains
`{{json .Config.Entrypoint}}` in its `docker inspect` format strings.)

Where they appear, and what fills them:

| Token | In | Filled from |
|---|---|---|
| `{{PROJECT_NAME}}`, `{{LANGUAGE}}` | `README.md`, `environment.yaml`, devcontainer | the `make new` arguments |
| `{{LANGUAGE_VERSION}}`, `{{OTP_VERSION}}` (before 2026-11) | `environment.yaml`, Dockerfiles, `.vscode/` | now `${mise:<tool>}`, from `mise.toml` — see **Since 2026-11** |
| `{{BASE_IMAGE_LAMBDA}}`, `{{BASE_IMAGE_SERVICE}}` | `targets/*/cicd_parameters.json` | `<language>/layer.env` |
| `{{CONTAINER_*}}` | `targets/*/deployment.yaml` | `<language>/layer.env` |
| `{{RUN_*}}` | `README.md` | `<language>/layer.env` — shell-ready twins of the `CONTAINER_*` values |
| `{{LINT_TOOL}}`, `{{LINT_COMMAND}}`, `{{LINT_INSTALL}}` | `make/commands.sh` | `<language>/layer.env` |
| `{{TEST_COMMAND}}`, `{{TEST_MASKS}}` | `make/commands.sh` | `<language>/layer.env` (`test_command`, `test_masks`) |

`<language>/layer.env` is the reference for all of them: one file per
language, holding the base images, the entrypoint ECS starts the
container with, and the lint command.

## The upgrade

### 1. Start clean, on a branch

```zsh
cd "$PROJECT"
git status --short                      # must be empty
git switch -c template-upgrade
```

### 2. See what actually differs

```zsh
diff -rq "$TEMPLATE/_base" . \
    --exclude=.git --exclude=venv --exclude=node_modules --exclude=.DS_Store

diff -rq "$TEMPLATE/$LANGUAGE/targets" targets
```

`Only in $TEMPLATE/_base: ...` lines are new files to add. `Files ... differ`
lines are the ones to judge, using the ownership table above.

When the upgrade is finished, re-running the first diff should report nothing
but the files that differ permanently: the three `cicd_parameters.json` and
three `deployment_parameters.json` (the template holds placeholders and
`<set me>` defaults where a project holds its own values), `project.env`,
`container_config.env`, and `README.md` if the project added notes of its own.
Anything else still differing is unfinished.

### 3. Copy the template-owned files

```zsh
cp "$TEMPLATE/_base/Makefile"   Makefile
mkdir -p make
cp "$TEMPLATE/_base/make/"*.sh  make/
chmod +x make/*.sh

# projects made before make/ existed keep the scripts at the root
git rm -f commands.sh setup_local_dev_env.sh 2>/dev/null || true

cp "$TEMPLATE/_base/targets/common/"*.yaml    targets/common/
cp "$TEMPLATE/_base/.github/workflows/"*.yml  .github/workflows/
cp "$TEMPLATE/_base/.dockerignore"            .dockerignore
```

The `Makefile` needs no edits any more — it holds no project values at all.
They live in **`project.env`**, which a project owns and an upgrade creates
once if it is missing:

```zsh
[[ -f project.env ]] || cp "$TEMPLATE/_base/project.env" project.env
```

Then fill it in, taking the values from the old `Makefile` before you discard
it:

```
PROJECT_NAME=my-service          # must be a valid CFN stack name; underscores
                                 #   become hyphens, nothing else is fixed up
TARGET=task                      # lambda, task or server
AWS_PROFILE=gig-nonprod
AWS_REGION=ap-southeast-2
CONFIG_FILE_NAME=container_config.env
```

Nothing is inferred: `PROJECT_NAME` used to default to the directory basename,
which silently targeted whatever stack the folder happened to be named after.
A missing `project.env` is now an error rather than a fallback.

`CONTAINER_PORT` is not in that list — it moved to each target's
`deployment_parameters.json`, so the port `make local-run` publishes and the
port the deployment sends are one value read from one place.

Then fill in the lint placeholders `make/commands.sh` arrived with:

```zsh
grep -n '{{LINT_' make/commands.sh
```

Take the three values from `$TEMPLATE/$LANGUAGE/layer.env` — for python that is `ruff`,
`ruff check . && ruff format --check .`, and the pip/conda install line.

### 4. Copy the language-owned files

```zsh
cp "$TEMPLATE/$LANGUAGE/targets/lambda/Dockerfile"   targets/lambda/Dockerfile
cp "$TEMPLATE/$LANGUAGE/targets/service/Dockerfile"  targets/service/Dockerfile

cp "$TEMPLATE/$LANGUAGE/mise.toml"                   mise.toml   # then restore the project's versions
cp -r "$TEMPLATE/$LANGUAGE/.vscode/"                 .vscode/
git rm -q environment.yaml 2>/dev/null || true      # gone since v2.0.0
```

`.vscode/launch.json` carries `{{CONTAINER_PORT}}` in the layers that bind a
port — substitute it with the same value the target's
`deployment_parameters.json` holds, or the server configuration launches
against a literal placeholder. The grep in **Placeholders** above catches it.

If the project's `Dockerfile` has project-specific lines (an extra `apt-get`,
a different `EXPOSE`), diff instead of copying and re-apply them.

A layer that does not support every target has no Dockerfile to copy for it —
`nextjs` has no `targets/lambda/`, for instance. `supported_targets` in
`layer.env` says which a layer offers.

### 5. Merge the project-owned files by hand

```zsh
diff "$TEMPLATE/_base/targets/lambda/deployment.yaml" targets/lambda/deployment.yaml
diff "$TEMPLATE/_base/targets/service/task/cicd_parameters.json" targets/service/task/cicd_parameters.json
diff "$TEMPLATE/_base/targets/service/task/deployment_parameters.json" targets/service/task/deployment_parameters.json
```

Take the template's structural changes, keep the project's values.

`deployment_parameters.json` is the newer of the three and the one most likely
to be missing entirely. Every parameter the deployment takes now lives there
and **none of them has a default in the template** — CloudFormation refuses the
deploy naming anything you left out, which is the point: a parameter with a
default is one that can hold a stale value in the stack with nothing in the
repo to show it. `make validate` lists what is missing, and `<set me>` marks a
value the template cannot choose for you, such as `DomainName`.

### 6. Verify before pushing

```zsh
make info                       # project, stacks, account, resolved files
make targets
make config                     # the environment file, and whether it is in step

make lint                       # source, and cfn-lint over every template
make validate lambda            # once per target the project still has
make validate task

make local-build                # the pipeline builds the same way
make local-run                  # with no arguments: prints the exact line for
                                #   this target, then run what it tells you
make local-logs
make local-stop
```

`make validate` calls AWS but changes nothing. The first command that touches
infrastructure is `make deploy-cicd`, and the first that deploys is
`make push`.

### 7. Commit and push

```zsh
git add -A
git commit -m "Sync with _aws_template: make/commands.sh, ..."
git push -u origin template-upgrade
```

Open the PR in the team's GitHub account as usual. The template itself is not
a dependency of anything, so nothing else needs releasing.

## Changes to expect

What an upgrade involves, oldest first. Each entry says what to do in the
project being upgraded; skip any group the project is already past.

### Since 2026-08-29

| Change | Action in the project |
|---|---|
| `Makefile` + `commands.sh` at the project root — every deploy, inspect, teardown and local-run command | copy both; `TARGET` went in the Makefile then, and in `project.env` now — see the 2026-09 group |
| `tests/deployment/deploy.sh` and `run_local.sh` removed — `commands.sh` replaces both | delete them; move any local edits into `commands.sh` |
| `tests/deployment/README.md` merged into the project's root `README.md` | merge, keeping the project's own notes |
| `setup_local_dev_env.sh` moved to `_base/`, generalised, reachable as `make local-dev-setup` | copy over the old copy |
| `environment.yaml` is now per language, not shared | copy from the language layer, substitute `{{PROJECT_NAME}}` |
| `BaseImageURI` is per language — values in `<language>/layer.env` (once the `make/bootstrap.sh` `case` block) | check the project's `cicd_parameters.json` matches its language |
| golang / cpp / elixir lambda Dockerfiles take a separate `BUILDER_IMAGE_URI` | copy the Dockerfile; the ARG has a working default |
| `targets/service/server/cicd_parameters.json` pointed `DeploymentCfnFilename` at the nonexistent `targets/server/deployment.yaml` | fix the path if the project still has the bug |
| `service/task_alb` removed — `service/task` (no ALB) and `service/server` (ALB + domain) are the two service targets | delete the directory; move to `service/server` if the project used it |
| Container entrypoint, cmd, workdir and port are per language, and the port now agrees across the Dockerfile, `ContainerPort` and the Makefile | check the project's values match its language's Dockerfile |
| The `VpcA-*` / `ClusterA-*` imports are behind `NetworkStackName` / `ClusterStackName` parameters | port the change; keep the project's own stack names as the defaults |
| `ContainerEnvironmentFile` is derived from `ConfigBucket` / `ProjectName` / `ConfigFileName`, overridable with `ContainerEnvironmentFileArn` | check the project's config file lives under its own name in the bucket |
| `service.env` renamed to `container_config.env`, matching the S3 object it is uploaded as | `git mv service.env container_config.env` |
| `commands.sh` and `setup_local_dev_env.sh` moved to `make/` | move them; the Makefile's `COMMANDS` points there |
| The lambda handler is per language, and DynamoDB policy ARNs use `${AWS::Region}` / `${AWS::AccountId}` instead of a literal account | copy both; the ARNs resolve to the same values in the current account |
| Nested-stack `TemplateURL`s use a `TemplateVersion` parameter instead of a version hardcoded per URL | copy; then `make template-version` to see what each target is on |
| `service/task` pointed at `v1.6.30/templates/compute/gig-020-000-ecs-srvc.cfn.yaml`, which is not in the bucket — that target could not deploy | the `TemplateVersion` default of `v1.10.2` fixes it |
| `service/server` moved from `ecs-srv-alb-0030` to `ecs-srv-alb-0020`, dropping its own `TaskMonitorStack` — `0020` deploys one internally | expect the nested service stack to be replaced |
| The lambda's `SubnetIds` / `SecurityGroupIds` are derived from `NetworkStackName` (`<stack>-PrivateSubnet*Id`, `<stack>-CacheClientSecurityGroupId`), with explicit ids still overriding | set `NetworkStackName` to the base stack this project runs in — `aolabs` by default, from `aolabs-base.yaml`; note the derived SG is the cache **client** group |
| Dockerfiles carry `# check=skip=InvalidDefaultArgInFrom`; `ENV PYTHONPATH=/` no longer expands an unset variable | copy the Dockerfiles |

### Since 2026-09

| Change | Action in the project |
|---|---|
| **`project.env`** holds `PROJECT_NAME`, `TARGET`, `AWS_PROFILE`, `AWS_REGION` and `CONFIG_FILE_NAME`. Both the Makefile and `commands.sh` read it, so `./make/commands.sh <cmd>` behaves exactly like `make <cmd>` | create it from `_base/project.env`, move the values out of the old Makefile, and delete them there |
| **Nothing is inferred.** `PROJECT_NAME` no longer falls back to the directory basename, and `TARGET` has no default | set both explicitly; a missing `project.env` is now an error |
| **`deployment_parameters.json`** per target — every deployment parameter, none with a template default. The pipeline passes it to CloudFormation as `TemplateConfiguration` | add the file; run `make validate` and it names anything still missing |
| `ContainerPort` moved from the Makefile into `deployment_parameters.json` | delete `CONTAINER_PORT` from the Makefile; check the value matches the app's bind port |
| **Command renames**: `build` → `local-build`, `run` → `local-run`, `config-upload` → `sync-config` | copy `Makefile` and `commands.sh`; update any scripts, CI or aliases that called the old names |
| **`make lint`** — the language's own checks plus cfn-lint over every template | fill in `{{LINT_TOOL}}`, `{{LINT_COMMAND}}`, `{{LINT_INSTALL}}` in `commands.sh` from `<language>/layer.env` |
| **Target short names**: `lambda`, `task`, `server` resolve to the full path under `targets/` | optional — the full paths still work |
| **One docker tag per target** (`<project>:lambda`, `<project>:service-task`) instead of a shared `:latest` | nothing to do; `docker rmi <project>:latest` reclaims the old one |
| `make local-run` with no ENTRYPOINT/CMD prints the exact line for the target rather than running the image's default | nothing to do |
| `make delete-all` lists both stacks and asks once, instead of once per stack | nothing to do |
| `make info` reports the git remote `make push` uses, and the parameters of both templates | nothing to do |
| **Template modules v1.10.16** scope ECS names by project: the task definition family, ECS service, autoscaling role and log group are all `${ProjectName}-${ServiceName}-*` | `make template-version v1.10.16`; **expect the ECS service and log group to be replaced** on the next deploy, and old log groups to be left behind |
| The lambda log group is `/aws/lambda/${ProjectName}-${LambdaFunctionName}-LogGroup`; the task role's log policy uses a trailing wildcard to match it | copy `targets/lambda/deployment.yaml`; the old group is deleted with its logs |
| `MemorySize` and `Timeout` are `deployment_parameters.json` values, not hardcoded in `deployment.yaml` | set both; the old hardcoded values were 4096 MB and the module's 900s default |
| The deployment publishes `LambdaFunctionName` — the deployed, project-scoped name `aws lambda invoke` takes | copy the outputs block |
| **`process_request` is minimal in every language layer**: read the secret, hash the input. The Redis cache example is gone | only if the project still runs the stub; a real service has replaced it already |
| **New `typescript` layer** — a plain Node service, distinct from `nextjs` | nothing for existing projects |
| **`nextjs` has no lambda target** — a layer now declares `supported_targets`, and unsupported ones are deleted at bootstrap | delete `targets/lambda` from a Next.js project; it never built |
| `_base/README.md` is the project README, bootstrapped with `{{RUN_*}}` examples per language | copy it, then re-apply any project-specific notes |

### Since 2026-11

| Change | Action in the project |
|---|---|
| **`.template.env`** — bootstrap records the template commit and the answers (`LANGUAGE`, `PROJECT_NAME`) a project was made from, so its render can be repeated. It holds no tool versions | add it by hand once this upgrade is done: the commit you upgraded to as `TEMPLATE_COMMIT` and `TEMPLATE_VERSION`, `TEMPLATE_DIRTY=false`, and the project's own answers. Copy the shape from a fresh `make new` |
| **`mise.toml`** is the one record of the project's tool versions. `BaseImageURI` in `cicd_parameters.json` names the version as `${mise:<tool>}`, resolved by `commands.sh` and, at build time, by `buildspec.yaml`. Every other version line sits under a `mise-sync:` comment that `make sync-versions` rewrites; `make lint` fails while one is stale | copy `mise.toml` from the language layer and set the project's current versions in it. Copy `make/versions.sh`, `Makefile`, `make/commands.sh`, `make/setup_local_dev_env.sh`, `targets/common/buildspec.yaml` and `.devcontainer/`. Then replace the version in each `BaseImageURI` with its token (`public.ecr.aws/lambda/python:${mise:python}`), add the `mise-sync:` comments above the version lines (take them from a fresh `make new`), and run `make sync-versions && make lint` |
| `make versions` lists the versions and the image each target resolves to | nothing to do |

### Since v1.1.0

Run `make upgrade <project> v1.1.0`. It applies the template-class row below
on its own. Nothing in this release needs porting by hand.

| Change | Action in the project |
|---|---|
| **`make upgrade`** and **`make upgrade-guess`** at the template root automate this file | stamp a project made before v1.0.0 with `make upgrade-guess <project> WRITE=1`, commit the stamp, then run `make upgrade` |
| `tests/integration/task_integration_validation.py` (template) no longer imports `src.utilities`. That module is in no language layer, so the import always failed. The file now reads `example_requests.json` with `json.load` and passes the python layer's ruff | nothing: `make upgrade` merges it. If the project edited the same lines, resolve the conflict |
| The same file's `X-API-Key` header is now a placeholder, `ExampleApiKey1234567890`. The literal key it used to carry is removed | if the project's copy still carries the old literal key, remove it and read the key from the environment. Treat the old key as exposed |
| `make render-all` at the template root renders and checks every language; `make render-all REF=<tag>` renders a past release | nothing: template maintainers only |

### Since v1.1.1

nextjs only. The other languages receive nothing.

| Change | Action in the project |
|---|---|
| `.env.local` (seed) ships with the template. It was git-ignored in the template, so releases and upgrades never carried it, and only `make new` from a working tree did | nothing if the project has one: `make upgrade` leaves it alone. A project without one gets the template's copy; fill in its values |
| `next-env.d.ts` (template) ships with the template, for the same reason | nothing: `make upgrade` adds it |
| Layer ignore files are stored as `gitignore` in the template and renamed at bootstrap; a project's `.gitignore` is unchanged | nothing |

### Since v1.2.0

Every language. Run `make upgrade <project> v1.2.0`; nothing needs porting by hand.

| Change | Action in the project |
|---|---|
| **`.gitignore`** (template) is now `_base/gitignore` + `<language>/gitignore`. The shared part ignores `/venv/` (the environment `make local-dev-setup` creates), OS and editor files, `.env`, `*.pem` and `*.log` | python, golang, cpp: nothing, `make upgrade` adds the file. typescript, nextjs, elixir: nothing, the shared entries merge in above the language's own |
| python, golang and cpp get language entries for the first time: bytecode and tool caches, `build/` trees, debugger and test binaries | if the project already committed such files (a `venv/` or `build/`, say), remove them from git: `git rm -r --cached venv build` |

### Since v2.0.0

**Breaking.** mise replaces micromamba for the local toolchain. Every
language. Run `make upgrade <project> v2.0.0`, then do the steps marked
"by hand".

| Change | Action in the project |
|---|---|
| **mise installs the toolchain.** `mise.toml` (template) now lists the tools too: cfn-lint everywhere, gopls and dlv for go, cmake, ninja and clang-format for cpp. `make local-dev-setup` runs `mise install`, and for python fills `./venv` | by hand, once per machine: install mise (`curl https://mise.run \| sh`) and add `eval "$(mise activate zsh)"` to `~/.zshrc`. Per project: move the old micromamba `./venv` aside (`mv venv venv.micromamba`), because mise creates a plain python venv there. Then run `make local-dev-setup` |
| **`environment.yaml` is removed** | upgrading to v2.1.0 or later deletes it, if the project never edited it. Upgrading to exactly v2.0.0: by hand, because that manifest no longer names it. If the project added packages to it, move them: a command-line tool to `mise.toml`, a C library to `system_packages_build.txt` (or `system_packages.txt`), a python package to `requirements.txt`. Then `git rm environment.yaml` |
| **`system_packages.txt`** (runtime) and **`system_packages_build.txt`** (build), Debian package names (seed) | nothing: `make upgrade` adds them with the packages the Dockerfiles used to name. By hand: if the project added `apt-get install` lines to its Dockerfiles, move those packages into the lists. The merged Dockerfiles install from the lists |
| Every Dockerfile installs system packages with one shared step that reads the lists; the devcontainer installs both lists (template) | nothing, unless the project's own Dockerfile edits conflict. Then keep the shared step and move the packages into the lists |
| `make` commands load mise's environment themselves, so `make lint` finds cfn-lint and the rest without shell activation | nothing |
| cpp: **no lambda target.** It never built: nothing produced the `bootstrap` executable (seed files in `targets/lambda/`) | by hand: delete `targets/lambda` and `.devcontainer/lambda` unless the project built its own Lambda runtime. `seed.patch` shows the template's removal |
| cpp: the builder installs `openssh-client`, for `ssh-keyscan` | nothing: it is in the new `system_packages_build.txt` |
| elixir: the Dockerfiles no longer `COPY` a missing `config/` or `.formatter.exs`; builder stages set `ERL_FLAGS="+JMsingle true"`, so the build survives QEMU emulation on an arm64 Mac; the lambda release name is the project's, not `example` | nothing: `make upgrade` merges them. A project with `config/` adds `COPY config ./config` to its builder stage |
| nextjs: `package-lock.json` (seed) ships, so `npm ci` works; `.dockerignore` lets `server.mjs` and the Next config files into the build | nothing if the project has its own lock file: it is left alone. Otherwise `make upgrade` adds the template's; run `npm install` to refresh it |

### Since v2.1.0

Every language. Run `make upgrade <project> v2.1.0`; nothing needs doing by hand.

| Change | Action in the project |
|---|---|
| **The integration test runner and its GitHub workflow are gone**: `tests/integration/` and `.github/workflows/task-integration.yml`. Both were broken: the workflow built `targets/task/Dockerfile`, which no longer exists | nothing: `make upgrade` deletes untouched copies, and the folders they leave empty. A copy the project edited is kept and named in the report; delete it or keep it as the project's own |
| **`retired`** is a new class in `template_manifest.txt`: files the template dropped. `environment.yaml` is retired too | nothing: an upgrade to v2.1.0 or later removes an untouched `environment.yaml` |

### Since v2.1.1

Every language. Run `make upgrade <project> v2.1.1`, then `make local-dev-setup`.

| Change | Action in the project |
|---|---|
| **Every tool in `mise.toml` is pinned** (template): cfn-lint 1.60.1, uv 0.13.9; gopls 0.24.0 and dlv 1.27.2 for go; cmake 4.5.0, ninja 1.13.2 and clang-format 23.1.5 for cpp; ruff 0.17.5 for python. They were `"latest"`, so machines linted with different versions | run `make local-dev-setup` to install the pins. A tool line the project changed keeps the project's value; the report names the template's |
| python: `.devcontainer/requirements_dev.txt` (template) pins `cfn-lint` and `ruff` from `mise.toml` through `mise-sync` lines | nothing: `make local-dev-setup` reinstalls them into `./venv` |
| `make/versions.sh` reads quoted keys: `${mise:pipx:cfn-lint}` | nothing |
| `make/commands.sh` puts `./venv` and the pinned tools first on PATH, so a tool from another environment (an old micromamba base, say) cannot shadow a pin | nothing. Outside `make`, the shell still decides: put `eval "$(mise activate zsh)"` after any other environment's activation in `~/.zshrc`, or remove micromamba's |

### Since v2.2.0

Every language. Run `make upgrade <project> v2.2.0`; then check the
pipeline's test stage below.

| Change | Action in the project |
|---|---|
| **`make test`** runs the unit tests in the service base image, at the versions in `mise.toml`, and writes a JUnit report to `reports/` (template: `make/commands.sh`, `Makefile`) | nothing: run it before you push. cpp and nextjs have no unit tests yet, so it reports that there is nothing to run |
| **The pipeline's test stage works for every language.** `targets/common/buildspec_test.yaml` (template) runs `./make/commands.sh test`. It used to `pip install -r tests/requirements.txt`, which no project had, so a target with `RunTests` set to `"true"` failed its test stage | by hand, if the project turned `RunTests` off to get past that failure: set it back to `"true"` in `cicd_parameters.json` and run `make deploy-cicd <target>`. If the project edited `buildspec_test.yaml`, resolve the merge |
| **`docs/development.md`** (with two diagrams) and **`docs/language.md`**: setup, the development loop, debugging, testing, the devcontainer, troubleshooting (template) | nothing: `make upgrade` adds them |
| The project README's Quick start begins with `make local-dev-setup`, `make test` and `make lint` (template) | nothing |
| `.gitignore` ignores `/reports/`, the JUnit output (template) | nothing |
| cpp: the F5 configuration ran `build/cpp_sample`, which CMake never builds; it now builds, then debugs `build/main` (template: `.vscode/launch.json`) | nothing |
| typescript: `make test` runs `npm install`, which writes `package-lock.json` if the project has none | commit the lock file |

### Since v2.3.0

Every language. Run `make upgrade <project> v2.3.0`.

| Change | Action in the project |
|---|---|
| **`make deploy-cicd` checks existing stacks first** (template: `make/commands.sh`): it lists the pipeline and service stacks that exist, flags a pipeline that deploys another target, stops on a stack mid-operation or a pipeline in `ROLLBACK_COMPLETE`, and asks `(y/n)` in a terminal | nothing. Answer `n` if a listed stack is not this project's, and fix `PROJECT_NAME` |
| **`README.md` is numbered steps only** (template); its explanations move to a new **`NOTES.md`** (template) | nothing if the project never edited its README. If it did, the merge conflicts heavily: keep the new README, and move the project's own notes into `NOTES.md` |
| **`docs/development.md` and its four diagram files are retired**: their text is in `NOTES.md`, and diagrams no longer ship with projects | nothing: `make upgrade` deletes untouched copies |
| `docs/language.md` links `README.md` and `NOTES.md` (template) | nothing |

### Since v2.3.1

Projects receive nothing. Template maintainers only.

| Change | Action in the project |
|---|---|
| `make upgrade-guess` failed with "Argument list too long" on a project with a local `venv/`: it listed every file on disk. It now uses `git ls-files`, and classifies paths in `xargs` batches | nothing |

### Since v2.4.0

Every language. Run `make upgrade <project> v2.4.0`.

| Change | Action in the project |
|---|---|
| **`.template.env` holds only `TEMPLATE_VERSION`, `LANGUAGE` and `PROJECT_NAME`** (stamp). `TEMPLATE_VERSION` is a tag or `git describe` output; `-dirty` marks a render from uncommitted changes. `TEMPLATE_COMMIT` and `TEMPLATE_DIRTY` are gone | nothing: `make upgrade` rewrites the stamp, and still reads the old form |
| **Nothing a project receives names the template repository**: the stamp header and the `.gitignore` comments are neutral | nothing. Commit messages are the project's: say "the template" and the version |
| **python: the venv is `.venv/`**, not `venv/` (template: `mise.toml`, `.vscode/settings.json`, the devcontainer volume, `make test`) | run `make local-dev-setup`: mise creates `.venv`. Then delete the old `venv/` (micromamba's, before v2.0.0); `.gitignore` ignores both |

### Since v2.4.1

Every language. Run `make upgrade <project> v2.4.1`; nothing needs doing by hand.

| Change | Action in the project |
|---|---|
| **The language's notes are a section of `NOTES.md`** (template), after **Development**. `docs/language.md` is retired | nothing: `make upgrade` merges `NOTES.md` and deletes an untouched `docs/language.md` |
| `README.md` points to `NOTES.md` for the language's commands (template) | nothing |
| The upgrade report says "updated - the project had not changed it" for an untouched `mise.toml` | nothing: template maintainers only |

### Since v2.5.0

Every language. Run `make upgrade <project> v2.5.0`, then `make local-dev-setup`.

| Change | Action in the project |
|---|---|
| **`make local-dev-setup` installs the dependencies in every language** (template: `make/setup_local_dev_env.sh`): pip into `./.venv`, `go mod download`, `npm install`, `mix deps.get`. It runs them with `./.venv` and the pinned tools first on `PATH`, and refuses if `python` is not `./.venv`'s | run `make local-dev-setup` once. Load your GitHub key first: `ssh-add ~/.ssh/<key>` |
| **Private packages** (`github.com/GIGTennis/...`): before installing, it logs in to GitHub over ssh whenever a dependency file names a private repository, and stops with GitHub's message if the key is refused. `NOTES.md` (template) has a **Private packages** section with the form for each language | nothing |
| go: `mise.toml` sets `GOPRIVATE` and a project-scoped git rewrite to ssh; `.vscode/settings.json` passes them to gopls (template) | nothing |
| typescript, nextjs: each `npm` step in the Dockerfiles mounts the ssh agent (template) | by hand: add `git` and `openssh-client` to `system_packages_build.txt` (seed) - `seed.patch` has the lines. Without them, private npm packages cannot be fetched in the image |
| typescript: `make test` installs `git` in its image when `package.json` uses git dependencies (template) | nothing |

### Since v2.6.0

Every language. Run `make upgrade <project> v2.6.0`.

| Change | Action in the project |
|---|---|
| **Private repositories with a token**: with `GITHUB_TOKEN` set, git fetches them over HTTPS with the token; without it, over ssh as before. `make/github_env.sh` (template) decides, and `mise.toml`, `make`, `make local-dev-setup`, `make test`, `make local-build` and every Dockerfile install step use it | nothing to keep ssh. For the token route: `export GITHUB_TOKEN="$(gh auth token)"` |
| go: `mise.toml` keeps only `GOPRIVATE`; the ssh rewrite now comes from `make/github_env.sh`. The Dockerfiles no longer set a global git rewrite (template) | nothing |
| Pipeline: optional `GitHubTokenSecretArn` puts a Secrets Manager token in both CodeBuild projects; without it the ssh key is fetched as before (template: `cicd.yaml`, both buildspecs) | to use a token: add `{"ParameterKey": "GitHubTokenSecretArn", "ParameterValue": "<secret arn>"}` to each target's `cicd_parameters.json` (seed), then `make deploy-cicd` |
| The build no longer passes `--build-arg GITHUB_TOKEN`: build arguments are stored in the image history. The token is a BuildKit secret now | nothing |
| Devcontainers pass `GITHUB_TOKEN` in through `remoteEnv` (template) | nothing |

| The per-language values moved from the `case` block in `make/bootstrap.sh` into `<language>/layer.env`; the rendered output is byte-identical | nothing to do |

## When a project has drifted too far

If a project has heavily edited its `targets/`, do not sync those at all —
take `Makefile`, `make/commands.sh` and `make/setup_local_dev_env.sh` only.
They need four things from a project, and nothing else:

- `project.env` declaring `PROJECT_NAME`, `TARGET`, `AWS_PROFILE`,
  `AWS_REGION` and `CONFIG_FILE_NAME`
- `targets/<target>/cicd_parameters.json` carrying `DeploymentCfnFilename`,
  `DockerFilename`, `DeploymentParametersFilename` and `BaseImageURI`
- `targets/common/cicd.yaml` publishing `CodeCommitRepositoryName`,
  `EcrRepositoryName` and `ArtifactStoreName` as stack outputs
- a pipeline named `<project>-cicd-CodePipeline`

Any project that satisfies those gets the full command set with no other
changes. `make lint` additionally needs the three `LINT_*` values filled in;
without them it reports that it has no linter configured rather than passing
silently.
