# Upgrading an existing project

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
`{{LINT_TOOL}} is not installed`. Take the values from the language's `case`
block in `make/bootstrap.sh`.

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
| `{{LANGUAGE_VERSION}}`, `{{OTP_VERSION}}` | `environment.yaml`, Dockerfiles, `.vscode/` | `language_version` in the `case` block |
| `{{BASE_IMAGE_LAMBDA}}`, `{{BASE_IMAGE_SERVICE}}` | `targets/*/cicd_parameters.json` | the `case` block |
| `{{CONTAINER_*}}` | `targets/*/deployment.yaml` | the `case` block |
| `{{RUN_*}}` | `README.md` | the `case` block — shell-ready twins of the `CONTAINER_*` values |
| `{{LINT_TOOL}}`, `{{LINT_COMMAND}}`, `{{LINT_INSTALL}}` | `make/commands.sh` | the `case` block |

The `case` block in `make/bootstrap.sh` is the reference for all of them: one
entry per language, holding the base images, the entrypoint ECS starts the
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

Take the three values from the language's `case` block in
`$TEMPLATE/make/bootstrap.sh` — for python that is `ruff`,
`ruff check . && ruff format --check .`, and the pip/conda install line.

### 4. Copy the language-owned files

```zsh
cp "$TEMPLATE/$LANGUAGE/targets/lambda/Dockerfile"   targets/lambda/Dockerfile
cp "$TEMPLATE/$LANGUAGE/targets/service/Dockerfile"  targets/service/Dockerfile

cp "$TEMPLATE/$LANGUAGE/environment.yaml"            environment.yaml
cp -r "$TEMPLATE/$LANGUAGE/.vscode/"                 .vscode/

sed -i '' "s/{{PROJECT_NAME}}/$(basename "$PROJECT")/" environment.yaml
```

`.vscode/launch.json` carries `{{CONTAINER_PORT}}` in the layers that bind a
port — substitute it with the same value the target's
`deployment_parameters.json` holds, or the server configuration launches
against a literal placeholder. The grep in **Placeholders** above catches it.

If the project's `Dockerfile` has project-specific lines (an extra `apt-get`,
a different `EXPOSE`), diff instead of copying and re-apply them.

A layer that does not support every target has no Dockerfile to copy for it —
`nextjs` has no `targets/lambda/`, for instance. `supported_targets` in the
`case` block says which a layer offers.

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
| `BaseImageURI` is per language — values in the `make/bootstrap.sh` `case` block | check the project's `cicd_parameters.json` matches its language |
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
| **`make lint`** — the language's own checks plus cfn-lint over every template | fill in `{{LINT_TOOL}}`, `{{LINT_COMMAND}}`, `{{LINT_INSTALL}}` in `commands.sh` from the `case` block |
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
