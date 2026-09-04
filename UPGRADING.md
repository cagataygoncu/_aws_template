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
export LANGUAGE=python          # the layer this project was bootstrapped from
```

## What is owned by whom

The upgrade is only as safe as this table. Copy the first group without
thinking; look at every file in the second; never touch the third.

| Owner | Files | Action |
|---|---|---|
| **Template** (`_base/`) | `Makefile`, `make/commands.sh`, `make/setup_local_dev_env.sh`, `targets/common/{cicd,buildspec,buildspec_test}.yaml`, `.github/workflows/`, `.dockerignore`, `.gitignore`, `tests/integration/` | copy verbatim |
| **Language** (`<language>/`) | `targets/{lambda,service}/Dockerfile`, `environment.yaml`, `.devcontainer/`, `.vscode/` | copy, then re-substitute placeholders |
| **Project** | `src/`, `lib/`, `tests/unit/`, `requirements.txt` / `go.mod` / `mix.exs` / `package.json`, `container_config.env`, `data/`, `README.md`, `targets/*/deployment.yaml`, `targets/*/cicd_parameters.json` | never overwrite — diff and merge by hand |

`deployment.yaml` and `cicd_parameters.json` sit in the project column because
real projects edit them: added resources, tuned CPU/memory, their own
`ProjectName` and `RunTests`. Read the template's version, port the change,
keep the project's values.

## Placeholders

`_base/` and the language layers are not directly usable — `make/bootstrap.sh`
substitutes four tokens, and a straight copy into an existing project skips
that step. After copying, check for leftovers:

```zsh
cd "$PROJECT"
grep -rn '{{PROJECT_NAME}}\|{{LANGUAGE}}\|{{BASE_IMAGE_LAMBDA}}\|{{BASE_IMAGE_SERVICE}}' . \
    --exclude-dir=.git --exclude-dir=venv --exclude-dir=node_modules
```

`{{PROJECT_NAME}}` appears in `environment.yaml`; `{{BASE_IMAGE_*}}` in
`_base/targets/*/cicd_parameters.json` and `{{CONTAINER_*}}` in
`_base/targets/service/*/deployment.yaml` — all files you merge by hand rather
than copy. The per-language values live in the `case` block in `make/bootstrap.sh`;
that is the reference when a project's `BaseImageURI`, or the entrypoint ECS
starts its container with, needs updating.

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
but the three `cicd_parameters.json` files — those differ permanently, because
the template holds `{{BASE_IMAGE_*}}` placeholders and a project holds its own
`ProjectName` and `RunTests`. Anything else still differing is unfinished.

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
```

`Makefile` needs two edits afterwards. Set `TARGET` to the target this project
deploys, and replace `{{CONTAINER_PORT}}` with the port the app listens on
inside the container (5040 for the Python layer) — it is the only placeholder
in the file. Check `PROJECT_NAME` too: it defaults to the directory name, which
must be a valid CloudFormation stack name (underscores are replaced with
hyphens automatically; anything else is not).

### 4. Copy the language-owned files

```zsh
cp "$TEMPLATE/$LANGUAGE/targets/lambda/Dockerfile"   targets/lambda/Dockerfile
cp "$TEMPLATE/$LANGUAGE/targets/service/Dockerfile"  targets/service/Dockerfile

cp "$TEMPLATE/$LANGUAGE/environment.yaml"            environment.yaml
sed -i '' "s/{{PROJECT_NAME}}/$(basename "$PROJECT")/" environment.yaml
```

If the project's `Dockerfile` has project-specific lines (an extra `apt-get`,
a different `EXPOSE`), diff instead of copying and re-apply them.

### 5. Merge the project-owned files by hand

```zsh
diff "$TEMPLATE/_base/targets/lambda/deployment.yaml" targets/lambda/deployment.yaml
diff "$TEMPLATE/_base/targets/service/task/cicd_parameters.json" targets/service/task/cicd_parameters.json
```

Take the template's structural changes, keep the project's values.

### 6. Verify before pushing

```zsh
make info                       # project, stacks, account, resolved files
make targets
make validate lambda            # once per target the project still has
make validate service/task

make local-build                      # the pipeline builds the same way
make local-run ENTRYPOINT=python CMD="src/main_task.py" TARGET=service/task
make local-logs
make stop
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

What an upgrade from a pre-2026-08-29 project involves. Each entry says what to
do in the project being upgraded.

| Change | Action in the project |
|---|---|
| `Makefile` + `commands.sh` at the project root — every deploy, inspect, teardown and local-run command | copy both; set `TARGET` in the Makefile |
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

## When a project has drifted too far

If a project has heavily edited its `targets/`, do not sync those at all —
take `Makefile`, `commands.sh` and `setup_local_dev_env.sh` only. They need
just three things from a project, and nothing else:

- `targets/<target>/cicd_parameters.json` carrying `DeploymentCfnFilename`,
  `DockerFilename` and `BaseImageURI`
- `targets/common/cicd.yaml` publishing `CodeCommitRepositoryName`,
  `EcrRepositoryName` and `ArtifactStoreName` as stack outputs
- a pipeline named `<project>-cicd-CodePipeline`

Any project that satisfies those gets the full command set with no other
changes.
