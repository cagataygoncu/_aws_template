# {{PROJECT_NAME}}

A {{LANGUAGE}} service deployed to AWS as a Lambda function or a Fargate task,
built from `_aws_template`.

Everything is driven by `make`, which passes through to `./make/commands.sh` —
one function per command. Run `make help` for the full list, or
`./make/commands.sh <command> ...` directly when debugging (from the project
root, where the script's relative paths resolve).

---

> [!WARNING]
> ## Set `PROJECT_NAME` before you deploy anything
>
> **`PROJECT_NAME` in `project.env` must be unique to this deployment.** Two
> projects sharing a name do not get two deployments — they get one, and the
> second person to run `make deploy-cicd` deploys *into the first one's
> stacks*.
>
> ```zsh
> # project.env
> PROJECT_NAME=my-own-service      # <- yours, not whatever it says now
> ```
>
> `PROJECT_NAME` names both CloudFormation stacks and, through them, the ECR
> repository, the CodeCommit repository, the pipeline, the artifact bucket, the
> IAM roles, the ECS service and the environment file's path in S3. The pipeline
> deploys with `StackName: !Ref ProjectName`, so a shared name is not a
> collision that fails loudly — **it is a silent overwrite of someone else's
> running service**.
>
> Check it before the first deploy, and any time you are not certain what this
> working copy is pointed at:
>
> ```zsh
> make info | head -3
> ```

---

## Quick start

```zsh
make info                      # what every command is about to act on
make config                    # is the environment file where ECS expects it?
make config-upload             # put it there - nothing else will

make build                     # the image the pipeline builds, same platform
make run ENTRYPOINT=... CMD="..."   # run it locally, MODE=local
make local-logs                # follow what it is doing
make stop

make validate                  # cicd.yaml + this target's deployment.yaml
make deploy-cicd               # create the pipeline stack, wire the git remote
make push <branch>             # push <branch> to CodeCommit main, start it
make pipeline                  # stage states, and when each last changed
make pipeline-errors           # why the last run failed, if it did
make url                       # where it ended up

make delete-stack              # the service stack only
make delete-cicd               # the pipeline stack; empties ECR + artifacts first
make delete-all                # both, service first
```

`make push` does not print the pipeline state: the push has only just landed,
so what you would see is the *previous* execution's. `make pipeline` shows each
stage with the time it last changed, which is how you tell a stage that just
ran from one still showing last week's result.

Teardown is ordered on purpose. The service stack goes first because the
pipeline stack owns the ECR repository its images live in and the artifact
bucket; `delete-cicd` empties both before deleting, since CloudFormation will
not remove a non-empty bucket or repository. `delete-all` does the two in the
right order. Deleting the service stack also releases its Route 53 record and
ACM certificate, so a stack that later wants that domain needs this to happen
first.

Read `make info` before anything that writes. It prints the project, both stack
names, the account, the resolved files, the build platform and the container
port — everything the other commands act on, with nothing inferred silently.

## Targets

A *target* is the path under `targets/` holding a `cicd_parameters.json`:
`lambda`, `service/task` (no load balancer) or `service/server` (behind an ALB,
with a domain). `make targets` lists the ones this project still has.

`TARGET` in `project.env` selects the one this project deploys; pass one
positionally to override for a single run:

```zsh
make build                     # uses $(TARGET)
make build lambda              # just this once
```

Per-target facts — the deployment template, the Dockerfile, the base image, the
CodeBuild image — all come from that target's `cicd_parameters.json`, so a
local `make build` and the pipeline's build cannot drift apart.

## Nothing is guessed

`PROJECT_NAME`, `TARGET`, `AWS_PROFILE` and `AWS_REGION` are declared in
**`project.env`**, and nowhere else:

```
PROJECT_NAME=my-service
TARGET=service/task
AWS_PROFILE=gig-nonprod
AWS_REGION=ap-southeast-2
CONFIG_FILE_NAME=container_config.env
```

Everything the *deployment* takes lives in the target's
`deployment_parameters.json` instead — including `ContainerPort`, so the port
`make run` publishes to and the port the deployment sends are the same value,
read from the same place.

Both the `Makefile` and `make/commands.sh` read that one file, so
`./make/commands.sh <command>` behaves exactly like `make <command>`, and
neither can guess. A missing `project.env` is an error, not a fallback.

(Not to be confused with `container_config.env`, which is the environment the
*running container* gets. `project.env` never leaves your machine and the
pipeline never sees it.)

That matters more than it sounds: `PROJECT_NAME` used to default to the
directory basename, so a repo whose folder was named after an older deployment
would silently target that deployment's stack.

An override on the command line still wins, for a one-off:

```zsh
make deploy-cicd PROJECT_NAME=lambda-test-1
TARGET=lambda make build
```

`make push` takes the branch explicitly, because it pushes to the remote's
`main` whatever the local branch is called — the thing being deployed is worth
saying out loud.

## The environment file

ECS fetches `container_config.env` from
`s3://<ConfigBucket>/<ProjectName>/container_config.env` when a task starts. It
is **not** in the image, and neither the build nor the pipeline uploads it:

```zsh
make config                    # where it is read from, and whether it is there
make config-upload             # upload it, and again whenever it changes
```

`make deploy-cicd` refuses to run when that object is missing, because a
missing file does not fail the deployment — it fails the task minutes later
with `ResourceInitializationError`.

It is configuration, never secrets. Put those in Secrets Manager and read them
with the task role.

The `lambda` target uses the same file, by a different route: Lambda has no S3
environment file — that is an ECS task-definition feature — so
`make config-upload lambda` writes the same values into the
`EnvironmentVariables` default of `targets/lambda/deployment.yaml`, which the
module expands into the function's `Environment.Variables`. That is a change to
the repository rather than to a bucket, so **commit and push it** for the
pipeline to deploy it. `make config lambda` reports whether the two are in
step.

## Develop in the devcontainer

Open in VS Code and *Reopen in Container*. The picker offers:

| Config | builds | for |
|---|---|---|
| `.devcontainer/` | `.devcontainer/Dockerfile` | day-to-day work: toolchain, debugger, dev dependencies |
| `.devcontainer/service/` | `targets/service/Dockerfile` | the image `service/task` and `service/server` deploy |
| `.devcontainer/lambda/` | `targets/lambda/Dockerfile` | the image the `lambda` target deploys |

**Use the root config for day-to-day work and debugging.** The target variants
exist so you can see what actually ships; every dev tool added to them is one
more difference between what you test and what deploys.

You usually do not need to open them at all — the root container has the Docker
socket mounted, so `make build`, `make run`, `make invoke` and `make shell`
drive the real image from inside it. Open a target variant when you want to sit
inside the deployed image and look around: what got baked in, a missing CA
certificate, whether the environment file landed.

`~/.aws`, `~/.gitconfig`, `~/.ssh/config` and the host's Docker socket are
mounted; `post_create.sh` installs the AWS and Docker CLIs and the development
tools listed in `.devcontainer/tools_dev.txt` (or `requirements_dev.txt`), so
they reach every variant rather than being baked into one image. No private key
is ever mounted: git authenticates through the forwarded ssh agent, so run
`ssh-add ~/.ssh/<key>` on the machine you are sitting at.

`make local-dev-setup` is not needed in there — the image *is* the environment.

`docker run -v` paths are resolved by the daemon on the host, so `commands.sh`
mounts `$AWS_CONFIG_HOST_DIR` (set by `devcontainer.json` to the host's
`~/.aws`) rather than `$HOME/.aws`, which inside the container would name a
path the host cannot see.

F5 runs `.vscode/launch.json` against the same entry points the target images
run, with `MODE=local` so a debug session uses the in-memory cache instead of
Secrets Manager — the same thing `RUN_ENV` does for `make run`.

The devcontainer image is **not** pinned to a platform: it follows the host, so
it is native on both an Apple Silicon laptop and an x86_64 builder. Debuggers
attach through `ptrace`, which fails against an emulated process. The deployed
images still build for the platform the pipeline builds for.

### When a rebuild cannot pull the base image

`Your authorization token has expired` — an ECR Public login token lasts 12
hours, and docker keeps presenting an expired one instead of falling back to an
anonymous pull. `.devcontainer/init.sh` and `make build` both refresh it now;
by hand it is:

```zsh
aws ecr-public get-login-password --region us-east-1 \
    | docker login --username AWS --password-stdin public.ecr.aws
```

The region is always `us-east-1`, whatever you deploy to. If your buildx
builder uses the `docker-container` driver it caches credentials of its own, so
`docker login` alone will not reach it — `docker buildx stop <builder>` makes
it pick them up.

`toomanyrequests: Rate exceeded` — the same command; authenticating raises the
anonymous limit.

`error getting credentials - err: exec: "docker-credential-osxkeychain":
executable file not found in $PATH` — `~/.docker/config.json` sets
`"credsStore": "osxkeychain"`, so the Docker CLI invokes that helper on every
pull. If it lives only in `~/.docker/bin/`, a terminal finds it and VS Code does
not. Fix it once in Docker Desktop → Settings → Advanced → install CLI tools
**System**. That moves the binaries rather than copying them, so if VS Code then
reports `Command not found: '~/.docker/bin/docker'`, a setting is pinned to the
old path — `dev.containers.dockerPath` in user settings.

## Set up the local toolchain

Only needed outside the devcontainer. Needs micromamba:

```zsh
"${SHELL}" <(curl -L micro.mamba.pm)
micromamba self-update

# Or on macOS:
brew install micromamba
```

Then:

```zsh
make local-dev-setup           # create/update ./venv from environment.yaml
micromamba activate ./venv
```

## Check what you are about to touch

```zsh
make info                      # project, stacks, account, resolved files
make info lambda               # ... for a different target
make targets                   # targets this project still has
make config                    # the environment file
make template-version          # the gig-cfn-templates release each target pulls
make aws-info
```

## Deploy

Two stacks: `{{PROJECT_NAME}}-cicd` (the pipeline, from
`targets/common/cicd.yaml`) and `{{PROJECT_NAME}}` (the service, created by that
pipeline).

```zsh
make validate                  # cicd.yaml + the target's deployment.yaml
make config-upload             # once, and whenever the env file changes
make deploy-cicd               # create/update the pipeline, wire the git remote
make push <branch>             # push it to CodeCommit main, starting the pipeline
make pipeline                  # stage states
make pipeline-stop             # abandon the running execution
```

Every parameter the pipeline resolves lives in `cicd_parameters.json` — include
each one, even where the template's default is correct. `aws cloudformation
deploy` keeps the *previous* value for anything you do not override, so a
parameter omitted from that file can hold a stale value in the stack forever,
with nothing in the repo to show it.

Deploy under a throwaway name to test the template itself:

```zsh
make deploy-cicd lambda PROJECT_NAME=lambda-test-1
```

### Deploying one repository as two stacks

A rewrite, a new season, a v2 alongside the running service: one repository,
two independent deployments.

**`PROJECT_NAME` is the separation, not the branch.** Branches decide *which
code* a pipeline builds; `PROJECT_NAME` decides *which AWS resources exist*.

#### The trap

`cicd.yaml`'s deploy action is:

```yaml
StackName: !Ref ProjectName
```

So a second pipeline stack that kept the same `PROJECT_NAME` would deploy
**into the first one's service stack** — different pipeline, same target,
production overwritten. Renaming only the stacks is not enough. Change
`PROJECT_NAME` and everything below separates on its own:

| Resource | For `PROJECT_NAME=my-service-v2` |
|---|---|
| CloudFormation stacks | `my-service-v2`, `my-service-v2-cicd` |
| S3 artifact bucket | `my-service-v2-cicd-artifact-store` |
| ECR repository | `my-service-v2-cicd-ecr-repository` |
| CodeCommit repository | `my-service-v2-cicd-CodeCommitRepository` |
| CodePipeline / CodeBuild | `my-service-v2-cicd-CodePipeline`, `-CodeBuildProject` |
| IAM roles | `my-service-v2-cicd-{CfnRole,CodeBuildRole,CodePipelineRole}` |
| Pipeline log group | `/aws/codepipeline/my-service-v2` |
| ECS service / task role | `my-service-v2-server`, `my-service-v2-TaskRole` |
| Environment file | `s3://gig-config/my-service-v2/container_config.env` |
| git remote (local) | `my-service-v2` |

#### What does not separate on its own

The pipeline passes only `ImageName` and `ProjectName` to the deployment
stack, so anything else has to be set in the target's `deployment.yaml`:

- **`DomainName`** — two stacks cannot create the same Route 53 record. Give
  the second one its own subdomain. It has no default for this reason:
  CloudFormation refuses the deploy until you set it.
- **`HostedZoneId`** — likewise, and likewise no default.
- **The environment file** — the path follows `ProjectName`, so the object at
  the *new* path does not exist yet. `make config-upload` puts it there;
  `make deploy-cicd` refuses to run until it is.

`ServiceName` needs no change: every resource built from it is prefixed with
`ProjectName`, so `my-service-v2-server` cannot collide with `my-service-server`.

#### Worked example

Working on a `modernise` branch, deploying beside a live `my-service`:

```zsh
git checkout -b modernise

# 1. Name the second deployment, in project.env. Nothing infers it: the
#    directory is still named after the ORIGINAL project, and a fallback to
#    the basename would deploy into the live stack.
#      PROJECT_NAME=my-service-v2

# 2. In targets/<target>/deployment.yaml, set what does not separate:
#      DomainName:   'my-service-v2.example.com'
#      HostedZoneId: 'Z0123456789ABCDEFGHIJ'

make info                      # read every name before creating anything
make validate                  # templates, and what still has no default
make config-upload             # the environment file, at the NEW path

make deploy-cicd               # creates my-service-v2-cicd, adds the git remote
make push modernise            # to the new remote only - see below
make pipeline
```

#### Two remotes, one repository

`make deploy-cicd` adds a git remote **named after the stack**, so the
repository ends up with one per deployment:

```
origin          git@github.com:org/my-service.git
my-service      ssh://.../my-service-cicd-CodeCommitRepository        (the live one)
my-service-v2   ssh://.../my-service-v2-cicd-CodeCommitRepository     (the new one)
```

`make push <branch>` pushes to the remote named after **this** project's stack,
so it reaches only that pipeline. Each pipeline watches `main` in its own
CodeCommit repository and never sees the other's pushes. The branch name is
local: `make push modernise` lands as `main` on the far side, which is what the
pipeline triggers on.

The corollary is worth stating: `git push aws main` or pushing to the *old*
remote by hand deploys the new code to the *old* stack. The explicit branch
argument exists partly for this.

#### Confirm you have not touched the original

After the second deployment, the first stack's `LastUpdatedTime` should be
unchanged and its service still at whatever count it was:

```zsh
aws cloudformation describe-stacks --stack-name my-service \
    --query 'Stacks[0].[StackStatus,LastUpdatedTime]' --output text
aws ecs describe-services --cluster <cluster> --services my-service-server \
    --query 'services[0].[desiredCount,runningCount]' --output text
```

#### Cutting over, later

Both stacks run side by side until you choose. Cutover is a DNS change —
point the original domain at the new load balancer — followed by
`make delete-all PROJECT_NAME=my-service` once the new one has proven itself.
Deleting the old stack releases its domain, so if the new one is to take that
name, delete first and then deploy with it.

## Inspect

```zsh
make outputs                   # deployment stack outputs
make outputs {{PROJECT_NAME}}-cicd
make url                       # invoke URL, whichever output the target uses
make events                    # failed stack events - first thing to read on a rollback
make logs                      # lambda: from the stack output; ECS: make logs /ecs/<name>
make output-value LambdaFunctionUrl
```

## Run locally

The image is built from the same Dockerfile and base image the pipeline uses,
both read from the target's `cicd_parameters.json`. `~/.aws` is mounted
read-only and `AWS_PROFILE` passed through, so no credentials end up in the
container's environment.

`ENTRYPOINT` and `CMD` are whatever that target's image runs — for this project:

```zsh
# task
make run ENTRYPOINT={{RUN_ENTRYPOINT_TASK}} CMD="{{RUN_CMD_TASK}}" TARGET=service/task

# server - the app binds {{CONTAINER_PORT}}; make run publishes it on 8080
make run ENTRYPOINT={{RUN_ENTRYPOINT_SERVER}} CMD="{{RUN_CMD_SERVER}}" TARGET=service/server
open http://localhost:8080

# lambda - the image entrypoint is kept on purpose, so the handler is the command
make run ENTRYPOINT= CMD="{{RUN_CMD_LAMBDA}}" TARGET=lambda
make invoke JSON='{"test": 1}'

# anything the code reads itself goes in RUN_ENV, which REPLACES the default
# MODE=local - so keep MODE= in whatever you pass
make run ENTRYPOINT={{RUN_ENTRYPOINT_TASK}} CMD="{{RUN_CMD_TASK}}" TARGET=service/task \
    RUN_ENV="MODE=local SECRET_NAME=my-settings DEBUG=1"

# the online path, against the real services it needs
make run ENTRYPOINT={{RUN_ENTRYPOINT_TASK}} CMD="{{RUN_CMD_TASK}}" TARGET=service/task \
    RUN_ENV="MODE=online SECRET_NAME=my-settings"

make local-logs
make shell
make stop
```

`make run` with neither is refused rather than guessed: the image's own default
would run, and for a python image that is a bare `python3` which reads EOF,
exits 0 and logs nothing — a broken run that looks like a successful one.

The authoritative values are `ContainerEntryPoint` and `ContainerCmd` in the
target's `deployment.yaml`. Those carry CloudFormation quoting, so drop the
surrounding quotes when passing them here. For reference, across the language
layers:

| Language | task / server entrypoint | task command | server command | lambda command |
|---|---|---|---|---|
| python | `python` / `uvicorn` | `src/main_task.py` | `src.main_server:app --host 0.0.0.0 --port <port>` | `src.main_lambda.lambda_handler_1` |
| golang | `/usr/bin/env` | `/app/build/task` | `/app/build/server` | `bootstrap` |
| cpp | `/usr/bin/env` | `/app/build/main` | `/app/build/main` | `bootstrap` |
| nextjs | `node` | `server.mjs` | `server.mjs` | `src/lambda.handler` |
| elixir | `/app/bin/<release>` | `start` | `start` | `bootstrap` |

Go and C++ go through `/usr/bin/env` because the ECS module splits the command
into the container's `Command` and cannot take an empty one; `env` execs the
binary, which keeps it PID 1.

The container gets only the AWS variables by default — `AWS_PROFILE`,
`AWS_REGION` and a read-only mount of `~/.aws`, so no credentials end up in its
environment. Everything the code reads itself goes in `RUN_ENV`, a
space-separated `KEY=VALUE` list. A value containing spaces needs `docker run`
by hand.

`make info` prints the `RUN_ENV` a bare `make run` would use, so what the
container gets is visible without reading the Makefile.

`RUN_ENV` defaults to `MODE=local` in the Makefile, which is what makes a local
run work with no AWS-backed services: the code reads `MODE` and defaults to
`online`, so deployed code sets nothing and runs online while `make run` opts
out. To exercise the online path locally, pass what it needs —
`RUN_ENV="MODE=online SECRET_NAME=my-settings"`.

`make build` builds for the platform the pipeline builds for, not the one your
laptop runs. It reads `CodeBuildImage` from the target's
`cicd_parameters.json` — `amazonlinux2-x86_64-standard` gives `linux/amd64`, an
`aarch64` CodeBuild image gives `linux/arm64`. That matters because the
deployed runtime is x86_64 by default: `lambda-0010.yaml` sets no
`Architectures` and the ECS modules set no `RuntimePlatform`, so AWS defaults
both to x86_64, and an arm64 image would not run there at all.

On Apple Silicon that means an emulated build, which is slower — Docker
Desktop's Rosetta option helps a lot. For a fast native build while iterating,
override it, remembering the result is not what deploys:

```zsh
make build BUILD_PLATFORM=linux/arm64
```

`ENTRYPOINT`, `CMD`, `JSON` and `RUN_ENV` are make variables rather than
positional arguments, because make splits its goals on whitespace and `CMD`
usually contains some.

## Work on a remote host

To work on a box that has no clone of this repository — a project with no
remote yet, or changes you do not want to commit just to move them:

```zsh
make upload <host> <directory>            # rsync the working tree over ssh
make upload gig-builder-aolabs dev DRY_RUN=1    # what would transfer
make upload gig-builder-aolabs dev WITH_GIT=1   # take the history too
```

The host is an entry in `~/.ssh/config`, so it inherits whatever that entry
says, including a `ProxyCommand`. Both arguments are required. `venv`,
`node_modules`, build output and `.git` are excluded — a macOS venv is useless
on Linux and is exactly what makes a devcontainer fail there.

Once the repository has a remote, `git clone` on the far side is the better
tool.

## Tear down

```zsh
make delete-stack              # the service stack
make delete-cicd               # the pipeline stack; empties ECR + artifacts first
make delete-all                # both, service first
```

## Notes

- `PROJECT_NAME` is sanitised into the stack name: underscores are not allowed
  in CloudFormation stack names, so `my_service` deploys as `my-service` and
  `my-service-cicd`.
- `make template-version <version>` moves every target to a gig-cfn-templates
  release, checking the bucket before it writes. It is the only place that
  version lives.
