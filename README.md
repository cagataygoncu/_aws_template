# _aws_template

Multi-language AWS service template with a single shared infra layer.

This is the consolidated replacement for the per-language templates that
previously lived alongside it (`aws-service-template`, `aws_service_template_go`,
`aws-server-template-python`, `aws-next-template`, `devcontainer_template/`).

## How this fits with `gig-cloudformation`

Two repositories, two jobs: this one describes a *service*, `gig-cloudformation`
describes the account it runs in and the CloudFormation modules the service is
assembled from. A generated project depends on it in two separate ways.

### 1. Base stacks — imported by name, resolved at deploy time

`gig-cfn-templates/projects/aolabs/aolabs-base.yaml` is deployed once and
long-lived. It exports the shared infrastructure under its own `ProjectName`
(`aolabs`), and the deployment templates import it:

| Target | imports |
|---|---|
| `service/task`, `service/server` | `<network>-VpcId`, `<network>-PublicSubnetOneId` / `TwoId`, `<cluster>-ClusterId` |
| `lambda` | `<network>-PrivateSubnetOneId` / `TwoId`, `<network>-CacheClientSecurityGroupId` |

The export names are the stack's prefix plus a fixed suffix, so the templates
carry the prefix as `NetworkStackName` and `ClusterStackName` (both defaulting
to `aolabs`) and derive the fourteen `!ImportValue`s from it. Deploying into
different networking is one default, not fourteen strings. Because a single
stack exports both the subnets and the security group, they cannot end up in
different VPCs — a pairing that fails the deploy. The lambda's `SubnetIds` and
`SecurityGroupIds` still take explicit ids, which override the derivation.

Note the prefix is that stack's **`ProjectName`**, not its stack name — the
older `aus-summer-2026.yaml` exported under `${AWS::StackName}` instead.

### 2. The template library — pulled from S3, by version

`gig-cfn-templates/templates/**` holds the reusable modules. Tagging a release
publishes the whole tree to `s3://gig-cfn-templates/<tag>/`, and each
deployment template nests the modules it needs from exactly one release:

```yaml
TemplateURL: !Sub 'https://gig-cfn-templates.s3.ap-southeast-2.amazonaws.com/${TemplateVersion}/templates/compute/lambda-0010.yaml'
```

| Target | modules |
|---|---|
| `lambda` | `compute/lambda-0010.yaml`, `compute/lambda-integration.yaml` |
| `service/task` | `compute/gig-020-000-ecs-srvc.cfn.yaml` |
| `service/server` | `compute/alb-020-010.yaml`, `compute/ecs-srv-alb-0020.yaml` |

All three are on `v1.10.2`. `service/server` uses `ecs-srv-alb-0020` rather
than `0030` because `0030` dropped `ContainerEnvironmentFile` after v1.6.32 in
favour of `S3BucketList` and `SecurityGroupIds`; `0020` also deploys the
deploy-time task-convergence monitor itself, so the template does not wire one
up.

The version lives in exactly one place per target — the `TemplateVersion`
parameter's `Default` in that target's `deployment.yaml`. It is deliberately
*not* also set in `cicd_parameters.json`: two copies could disagree, and the
one that won would depend on whether the deploy went through the pipeline.

### Releasing a change, then taking it

```zsh
cd ~/Dropbox/my/dev/gig-cloudformation
make validate gig-cfn-templates/templates/compute/<module>.yaml
make release patch                  # tags vX.Y.Z; CI syncs the tree to S3
```

```zsh
cd <project>
make template-version               # what each target is on
make template-version vX.Y.Z        # checks the bucket, then writes
make validate lambda                # ... and the other targets
make push                           # the pipeline reads the template from the repo
```

### What breaks across releases, and why the check exists

A module's parameters are not stable between releases, and neither are its
paths. Both have bitten this template:

- `ecs-srv-alb-0030` **dropped** `ContainerEnvironmentFile` after v1.6.32 — a
  blind bump to v1.10.2 fails with *Parameters: [ContainerEnvironmentFile] do
  not exist in the template*.
- `gig-020-000-ecs-srvc.cfn.yaml` **moved** from `gig_apps/` to
  `templates/compute/` — the old `v1.6.30/templates/compute/…` URL is a 404, so
  `service/task` could not deploy at all.
- The three `database/*` modules are pinned at **v1.6.42** upstream because the
  `custom-resource-parse-json-lambda.yaml` they nest is no longer in the source
  tree, and so is absent from later releases.

`make validate` cannot catch any of this: CloudFormation does not fetch nested
`TemplateURL`s while validating, so a wrong version passes clean and fails at
deploy. That is why `make template-version <version>` `head-object`s every
nested key in the bucket first and refuses to write if one is missing. Before a
bump that crosses several releases, also diff the modules' `Parameters` against
what the deployment template passes.

### The contract in both directions

- **This repo → the modules**: each `deployment.yaml` may only pass parameters
  the module of that release declares, and must pass every one that has no
  default.
- **The modules → their own nested stacks**: `ecs-srv-alb-0020`, `lambda-0010`,
  `network/api-0010` and the `database/*` modules take `TemplateS3Bucket` and
  `TemplateVersion` instead of hardcoding a version, so a module can be told to
  stay inside the caller's release rather than dragging in an older one.

## Layout

```
_aws_template/
├── _base/              # shared across all languages — single source of truth
│   ├── Makefile        # `make deploy-cicd`, `make local-run`, ... → make/commands.sh
│   ├── make/           # what the Makefile shells out to
│   │   ├── commands.sh             # the deploy/local-run logic, one function per command
│   │   └── setup_local_dev_env.sh  # `make local-dev-setup`: ./venv from environment.yaml
│   ├── targets/        # CFN deployment scaffolding (NO Dockerfiles — those
│   │                   #   live in each language's targets/ overlay)
│   │   ├── common/         # buildspec.yaml, buildspec_test.yaml, cicd.yaml
│   │   ├── lambda/         # deployment.yaml, cicd_parameters.json
│   │   └── service/        # task/ (no ALB), server/ (ALB + domain)
│   ├── tests/
│   │   └── integration/    # integration test runner & example requests
│   ├── .github/workflows/  # task-integration.yml
│   ├── .gitignore
│   ├── .dockerignore
│   └── container_config.env                # the env file to upload to S3
│
├── python/             # Python language layer
│   ├── src/, lib/, tests/unit/, .vscode/
│   ├── requirements.txt                      # runtime deps: images AND devcontainer
│   ├── .devcontainer/                        # VS Code: Reopen in Container
│   ├── environment.yaml                      # python + pip -r requirements
│   └── targets/{lambda,service}/Dockerfile   # Python multi-stage (pip)
├── golang/             # Go language layer
│   ├── src/, tests/unit/, go.mod, go.sum, .devcontainer/, .vscode/
│   ├── environment.yaml                      # go, gopls, delve
│   └── targets/{lambda,service}/Dockerfile   # multi-stage `go build`
├── cpp/                # C++ language layer
│   ├── src/, CMakeLists.txt, .gdbinit, .devcontainer/, .vscode/
│   ├── environment.yaml                      # cxx-compiler, cmake, ninja
│   └── targets/{lambda,service}/Dockerfile   # CMake build + provided.al2 for lambda
├── nextjs/             # Next.js language layer (TS, Tailwind)
│   ├── src/, package.json, tsconfig.json, next.config.mjs, .devcontainer/, .vscode/
│   ├── environment.yaml                      # nodejs
│   └── targets/{lambda,service}/Dockerfile   # npm ci + Next build
├── elixir/             # Elixir Mix project layer
│   ├── lib/, test/, mix.exs, mix.lock, .devcontainer/, .vscode/
│   ├── environment.yaml                      # elixir (pulls erlang/OTP)
│   └── targets/{lambda,service}/Dockerfile   # mix release multi-stage
│
├── make/
│   └── bootstrap.sh    # scaffold a new project: _base/ + <language>/
├── Makefile            # `make new <language> <project>` → make/bootstrap.sh
├── UPGRADING.md        # sync an existing project with template changes
└── README.md           # this file
```

### Tool versions

Each language's toolchain version is written **once**, as `language_version` in
the `case` block in `make/bootstrap.sh`, and everything else is built from it:

```bash
python)
    language_version="3.12"
    base_image_lambda="public.ecr.aws/lambda/python:${language_version}"
    base_image_service="public.ecr.aws/docker/library/python:${language_version}"
```

`{{LANGUAGE_VERSION}}` is then substituted into the files that would otherwise
repeat it — `environment.yaml`, the devcontainer Dockerfile, the lambda
builder's `BUILDER_IMAGE_URI`, and the Python interpreter paths in
`.vscode/settings.json`. Bumping Python to 3.13 for everyone is one edit, not
six.

For a single project — trying a version before the team moves to it — pass it
to `make new` instead of editing the table:

```bash
make new python my_match_stats LANGUAGE_VERSION=3.13
make new elixir my_event_router LANGUAGE_VERSION=1.20 OTP_VERSION=28
```

`bootstrap.sh` prints what it used, so a scaffold says which toolchain it is
on:

```
Toolchain: python 3.13
    service image  public.ecr.aws/docker/library/python:3.13
    lambda image   public.ecr.aws/lambda/python:3.13
```

Nothing checks that the version exists as an image tag — a wrong one fails at
the first `make local-build` or devcontainer open, not at scaffold time.

| Language | `language_version` | also |
|----------|--------------------|------|
| python   | `3.12`             | Ruff formats and lints it, per `ruff.toml` |
| golang   | `1.23`             | |
| cpp      | `bookworm`         | a distro release, not a toolchain version |
| nextjs   | `20`               | |
| elixir   | `1.19`             | `otp_version="27"` → `{{OTP_VERSION}}` |

Two versions deliberately stay put: `TemplateVersion` (the gig-cfn-templates
release, which `make template-version` owns) and the `runtime-versions:` key in
`targets/common/buildspec.yaml`, which names CodeBuild's own toolchain rather
than the application's — the build only runs `docker`, so it is unrelated to
the image being built.

### Base images per language

The CFN target scaffolding is language-agnostic except for one value: the image
each target builds `FROM`, passed to the pipeline as `BaseImageURI` and into the
Dockerfile as `BASE_IMAGE_URI`. Rather than copy every
`cicd_parameters.json` file into every language layer to change one line,
`_base/` carries a placeholder and `make/bootstrap.sh` substitutes the language's
image — the same mechanism as `{{PROJECT_NAME}}`:

| Language | `{{BASE_IMAGE_LAMBDA}}`              | `{{BASE_IMAGE_SERVICE}}`                        |
|----------|--------------------------------------|-------------------------------------------------|
| python   | `lambda/python:3.12`                 | `docker/library/python:3.12`                    |
| golang   | `lambda/provided:al2023`             | `docker/library/golang:1.23-bookworm`           |
| cpp      | `lambda/provided:al2023`             | `docker/library/debian:bookworm`                |
| nextjs   | `lambda/nodejs:20`                   | `docker/library/node:20-bookworm-slim`          |
| elixir   | `lambda/provided:al2023`             | `docker/library/elixir:1.19-otp-27`             |

(all under `public.ecr.aws/`)

The golang, cpp and elixir lambda Dockerfiles build with `apt-get` but must
*run* on the Lambda custom runtime, so their builder stage takes its own
`BUILDER_IMAGE_URI` ARG with a language default — nothing has to pass it, and
the pipeline still controls the runtime image through `BaseImageURI`.

The same mechanism fills in how ECS starts the container, which is equally
language-specific — `{{CONTAINER_PORT}}`, `{{CONTAINER_WORKDIR}}`,
`{{CONTAINER_ENTRYPOINT_TASK}}`, `{{CONTAINER_CMD_TASK}}` and the two `_SERVER`
equivalents in `_base/targets/service/*/deployment.yaml`:

| Language | port | workdir | task | server |
|----------|------|--------------|---------------------------|---------------------------------|
| python   | 5040 | `/`          | `python src/main_task.py` | `uvicorn src.main_server:app …` |
| golang   | 5040 | `/app/build` | `env /app/build/main`     | `env /app/build/main`           |
| cpp      | 5040 | `/app/build` | `env /app/build/main`     | `env /app/build/main`           |
| nextjs   | 3000 | `/app`       | `node server.mjs`         | `node server.mjs`               |
| elixir   | 4000 | `/app`       | `/app/bin/example start`  | `/app/bin/example start`        |

Each matches that language's Dockerfile — where it leaves its build output,
and what it `EXPOSE`s. `{{CONTAINER_PORT}}` reaches three places that have to
agree: `ContainerPort` in both deployment templates, `CONTAINER_PORT` in the
project's Makefile (which is the container-side port `make local-run` publishes to),
and the app's own bind port. Next.js serves 3000 and an Elixir release 4000, so
a single 5040 default was wrong for both. The
compiled languages go through `env` because the ECS module builds the
container's `Command` with `!Split [" ", …]` and cannot take an empty one;
`env` execs the binary, so it still runs as PID 1. The server cmd is a `!Sub`,
so it can reference `${ContainerPort}` — the Python one does.

The lambda target needs only one of these: `{{CONTAINER_CMD_LAMBDA}}`, the
handler. Every AWS Lambda base image — python, nodejs and provided alike —
ships the same `/lambda-entrypoint.sh` and `/var/task`, so those stay literal.
The handler is `src.main_lambda.lambda_handler_1` for python,
`src/lambda.handler` for nextjs, and `bootstrap` for the three custom-runtime
languages.

### Why Dockerfiles live in each language folder

The CFN deployment scaffolding (`deployment.yaml`, `cicd_parameters.json`,
`buildspec.yaml`, `cicd.yaml`) is genuinely language-agnostic — same shape
whether you're shipping a Go binary or a Next.js bundle. But the `Dockerfile`
itself is unavoidably language-specific (pip vs. npm vs. `go build` vs. CMake
vs. mix release). So the Dockerfiles live under each language's `targets/`,
and the bootstrap rsync overlays them on top of the shared `_base/targets/`.

## Usage

```bash
make new <language> <project_name> [destination_dir]
```

Examples:

```bash
make new python  my_match_stats           # creates ../my_match_stats
make new golang  my_ranking_pipeline
make new cpp     my_audio_processor
make new nextjs  my_coach_dashboard
make new elixir  my_event_router

make languages                            # languages available
make check                                # syntax-check the template's scripts
```

`make new` is a pass-through to `./make/bootstrap.sh <language> <project_name>
[destination_dir]`, which is also fine to run directly. With no destination it
creates a sibling of the template directory, whatever directory you run it
from.

The script:

1. Validates the language and that `project_name` is snake_case.
2. Copies `_base/` into the destination.
3. Overlays the chosen language layer on top (language layer wins on conflicts).
4. Substitutes the placeholders in any text file that contains them:
   `{{PROJECT_NAME}}`, `{{LANGUAGE}}`, the two `{{BASE_IMAGE_*}}` images and the
   `{{CONTAINER_*}}` values that say how the container is started.

### Then point the new project at the current templates

A new project inherits the `gig-cfn-templates` release `_base/` was last set
to, which is not necessarily the newest one. Check it, and move it if there is
a later release:

```bash
cd ../my_match_stats
make template-version                     # what the new project inherited
make template-version v1.10.3             # the current release, if newer
make validate lambda                      # ... and its other targets
```

`make template-version <version>` edits the `TemplateVersion` default in each
target's `deployment.yaml`, and verifies every nested module exists in the
bucket at that version before writing — so a release that was never published,
or one that does not carry a module this project uses — is refused rather than
discovered at deploy time. See
[What breaks across releases](#what-breaks-across-releases-and-why-the-check-exists).

To keep future projects current instead of fixing each one after the fact, bump
the template itself — this repo's own `_base/`:

```bash
make template-version                     # what _base/ ships
make template-version v1.10.3             # every project scaffolded from now on
```

## Deploying a generated project: `make`

Every generated project gets a `Makefile` and a `make/` directory from `_base/`.
The Makefile is a thin pass-through — one line per command — and
`make/commands.sh` holds the logic as one function per command, so the same
operation can be run either way (both from the project root, which is where the
scripts' relative paths resolve):

```bash
make deploy-cicd lambda        # === ./make/commands.sh deploy-cicd lambda
make help                      # the full command list
```

This replaces the long `export VAR=...` / `aws cloudformation ...` sequences
that used to be copied out of the deployment notes.

A *target* is the path under `targets/` holding a `cicd_parameters.json`:
`lambda`, `service/task` (no load balancer) or `service/server` (behind an ALB,
with a domain). Set `TARGET` once at the top of the project's Makefile and every
command defaults to it; pass one positionally to override for a single run.

`cicd_parameters.json` sets the **pipeline** stack's parameters — which target
to deploy, which Dockerfile to build, which base image. The pipeline forwards
only `ImageName` (the image it just built) and `ProjectName` to the deployment
stack; everything else a deployment needs comes from its own template's
parameter defaults.

Forwarding more is possible — declare it in `cicd.yaml`, add it to the deploy
action's `ParameterOverrides`, and declare it in **every** target's
`deployment.yaml`, since the action fails on a parameter a target template does
not have — but it puts the value in two places that can disagree, and which one
wins depends on whether the deploy went through the pipeline. Prefer the
template default. (Values in the JSON must also contain no spaces:
`commands.sh` passes them to `aws cloudformation deploy` as `Key=Value` shell
words.)

The container's environment file follows the project: `ConfigBucket`,
the `ProjectName` the pipeline passes in, and `ConfigFileName` compose
`s3://gig-config/<project>/container_config.env`. The repo's own
`container_config.env` is the file to upload there — same name on both sides,
so the connection is visible. `ContainerEnvironmentFileArn` overrides the whole
ARN when a project shares someone else's file.

The VPC, cluster and CloudFormation modules a deployment stands on all come
from `gig-cloudformation` — that is its own section:
[How this fits with `gig-cloudformation`](#how-this-fits-with-gig-cloudformation).

### Set up the local toolchain

Needs micromamba:

```bash
"${SHELL}" <(curl -L micro.mamba.pm)
micromamba self-update

# Or on macOS:
brew install micromamba
```

Then, in the project:

```bash
make local-dev-setup           # create/update ./venv from environment.yaml
micromamba activate ./venv
```

`environment.yaml` comes from the language layer, so `./venv` holds that
language's toolchain — a Python interpreter, a Go toolchain with `gopls` and
`delve`, a C++ compiler with CMake and Ninja, Node, or Elixir. It is a
micromamba prefix inside the project, so nothing is installed system-wide and
deleting the project deletes the environment with it.

### Develop inside the devcontainer

Each language layer ships a `.devcontainer/`, so a generated project opens in
VS Code with *Reopen in Container* and no further setup. `bootstrap.sh` names
the container after the project and forwards that language's port, and the
image matches the one the service is built on — python 3.12, node 20, elixir
1.19-otp-27, go 1.23, Ubuntu for C++.

The container binds `~/.aws`, `~/.gitconfig`, `~/.ssh/config` and `~/data` from
the host read-only, and forwards the ssh agent so builds can pull private
repositories. No private key is mounted: the agent is the only credential path,
which is what lets the same config work on a remote host that deliberately
holds no keys.

`initializeCommand` runs `.devcontainer/init.sh` on the host and creates every
one of those paths first. A bind mount whose source does not exist fails
container creation outright — `invalid mount config for type "bind"` — before
any of it is visible in the log. Your laptop has them all; a fresh EC2 host
reached over Remote-SSH has almost none.

The AWS CLI is a devcontainer tool, not an image dependency: the deployed
images have no CLI and do not need one — application code uses the SDK, and
CodeBuild's own image supplies the CLI the buildspec calls. `post_create.sh`
installs it into the container only, and skips the install when the tool is
already on PATH.

`make local-dev-setup` is not needed in there — the image *is* the
environment. Everything else works, including the docker-backed commands: the
host's Docker socket is mounted and `post_create.sh` installs the Docker CLI
(client only, no daemon in the container), and `~/.aws` plus the AWS CLI are
there for `validate`, `outputs`, `logs`, `deploy-cicd` and `push`.

One subtlety that the templates handle for you: a build context is *streamed*
to the daemon, so `make local-build` just works, but `docker run -v` paths are
resolved by the daemon **on the host** — inside the container `$HOME/.aws`
would name a path the host cannot see. `commands.sh` mounts
`$AWS_CONFIG_HOST_DIR` instead, which `devcontainer.json` sets to the host's
`~/.aws` and which defaults to `$HOME/.aws` on the host. Ports published by
`make local-run` land on the host, not on the devcontainer's forwarded port.

#### Opening the deployed image instead

Each project ships three configurations, and VS Code offers them in the
*Reopen in Container* picker:

| Config | builds | for |
|---|---|---|
| `.devcontainer/` | `.devcontainer/Dockerfile` | day-to-day work: editors, linters, dev dependencies |
| `.devcontainer/service/` | `targets/service/Dockerfile` | the image `service/task` and `service/server` deploy |
| `.devcontainer/lambda/` | `targets/lambda/Dockerfile` | the image the `lambda` target deploys |

The two target variants pass the language's own `BASE_IMAGE_URI` and build with
`ENV=dev`, which is what keeps `/.devcontainer/requirements_dev.txt` in the
Python image rather than being stripped. Reach for them when something behaves
differently in the deployed image than in the dev one — a missing system
library, a different Python patch version, an import that only resolves because
a dev dependency happens to be installed.

The workspace is bind-mounted over the source baked into the image, so you edit
the repo, not the copy inside the image. The lambda variant clears the
entrypoint (`runArgs: ["--entrypoint", ""]`): that image's entrypoint is the
runtime emulator, which exits immediately with no handler to serve.

#### When a rebuild cannot pull the base image

Both failures below are host setup, not the config — the plain `.devcontainer/`
config hits them too, since its Dockerfile also starts `FROM public.ecr.aws/...`.

`error getting credentials - err: exec: "docker-credential-osxkeychain":
executable file not found in $PATH` — `~/.docker/config.json` sets
`"credsStore": "osxkeychain"`, so the Docker CLI invokes that helper on every
pull, including anonymous public ones. If the helper lives only in
`~/.docker/bin/`, a terminal finds it and VS Code does not. Fix it once in
Docker Desktop → Settings → Advanced → install CLI tools **System**, which
symlinks `docker` and the helpers into `/usr/local/bin`.

`toomanyrequests: Rate exceeded` — ECR Public rate-limits anonymous pulls.
Authenticating raises the limit for 12 hours; the region is always
`us-east-1`, whatever you deploy to:

```bash
aws ecr-public get-login-password --region us-east-1 \
    | docker login --username AWS --password-stdin public.ecr.aws
```

Pre-pulling from a working terminal also unblocks a rebuild: the devcontainer
CLI only pulls a base image that `docker inspect --type image` cannot find.

Docker Desktop's **System** CLI install moves the binaries rather than copying
them: it creates `/usr/local/bin/docker` and removes `~/.docker/bin/docker`. If
VS Code then reports `Command not found: '~/.docker/bin/docker'`, a setting is
pinned to the old path — `dev.containers.dockerPath` in user settings.


### Run and debug the app

`.vscode/launch.json` in each language layer drives F5 against the entry points
the target Dockerfiles run, so debugging matches deployment:

| Language | configurations |
|---|---|
| python | Task (`src/main_task.py`), Server (`uvicorn src.main_server:app`), Core (`src/main.py`), Unit tests, Current File |
| golang | Run `src`, Unit tests |
| cpp | Run `build/cpp_sample` (build first with CMake) |
| nextjs | Server (`server.mjs`), Next dev server |
| elixir | Run the application (`mix run --no-halt`), Unit tests |

All three configurations — dev, service and lambda — carry the same
`customizations.vscode` block, so the debugger and language tooling are
installed whichever image you open. The Python one includes
**`ms-python.debugpy`** explicitly: the debugger has been a separate extension
from `ms-python.python` since 2023, and without it F5 does nothing in the
container. The interpreter path is per image — `/usr/local/bin/python` in the
dev and service images, `/var/lang/bin/python` in the Lambda one, which keeps
its runtime elsewhere — and `ruff.interpreter` names it too.

The devcontainers also mask `./venv` with an empty volume. On a Mac that
directory holds a macOS interpreter; bind-mounted into a Linux container it is
visible but unrunnable, and the Python extension will select it and fail to
start the debug adapter with no message at all. Hiding it removes the trap; a
`make local-dev-setup` run *inside* a container fills the volume with a Linux
environment instead.

`.vscode/settings.json` deliberately does **not** pin
`python.defaultInterpreterPath`: workspace settings override the
devcontainer's, so a path to the host's `./venv` would follow you into the
container where it does not exist, leaving the Python extension and Black with
no interpreter at all. On the host the extension finds `./venv` on its own.

The configurations set `MODE=local`, the same thing the Makefile's `RUN_ENV`
default does for `make local-run`, so a debug session skips the Secrets Manager read.
The Python configurations also set `PYTHONPATH` to the
workspace, matching `ENV PYTHONPATH=/` in the images, and the server binds the
language's own port — the one `devcontainer.json` forwards.

Debugging runs the code *in the devcontainer itself*, against the image's
interpreter or toolchain. `make local-run` is the other thing: it builds the real
target image and runs that. Use the first while writing code, the second to
check the image the pipeline will build.

### Check what you are about to touch

```bash
make info                      # project, stacks, account, resolved files
make info lambda               # ... for a different target
make targets                   # targets this project still has
```

### Deploy

```bash
make validate                  # cicd.yaml + the target's deployment.yaml
make deploy-cicd               # create/update <project>-cicd, wire the git remote
make push                      # push current branch to CodeCommit, start pipeline
make pipeline                  # stage states
make pipeline-stop             # abandon the running execution
```

### Inspect

```bash
make outputs                   # deployment stack outputs
make outputs my-svc-cicd       # pipeline stack outputs
make url                       # invoke URL, whichever output the target uses
make events                    # failed stack events - first thing to read on a rollback
make logs                      # follow lambda logs (ECS: make logs /ecs/<name>)
```

### Tear down

```bash
make delete-stack              # the service stack
make delete-cicd               # the pipeline stack; empties ECR + artifacts first
make delete-all                # both, service first
```

### Run locally

The image is built from the same Dockerfile and base image the pipeline uses.
`~/.aws` is mounted read-only and `AWS_PROFILE` passed through, so no
credentials end up in the container's environment.

```bash
# lambda: keep the image entrypoint, pass the handler as the command
make local-run ENTRYPOINT= CMD="src.main_lambda.lambda_handler_1" TARGET=lambda
make invoke JSON='{"test": 1}'

# task
make local-run ENTRYPOINT=python CMD="src/main_task.py" TARGET=service/task

# server - bind the container port (CONTAINER_PORT in the Makefile);
# make local-run publishes it on localhost:8080
make local-run ENTRYPOINT=uvicorn CMD="src.main_server:app --host 0.0.0.0 --port 5040" TARGET=service/server

make local-logs
make shell
make stop
```

`ENTRYPOINT` and `CMD` are the `ContainerEntryPoint` and `ContainerCmd` the
target's `deployment.yaml` sends, minus the CloudFormation quoting.
`bootstrap.sh` fills those in per language, so they differ by layer:

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

A generated project does not carry this table — its own values are the only
ones that apply there, and `make local-run` with neither argument prints them.

`make local-build` builds for the platform the pipeline builds for, not the one your
laptop runs. It reads `CodeBuildImage` from the target's
`cicd_parameters.json` — `amazonlinux2-x86_64-standard` gives `linux/amd64`,
an `aarch64` CodeBuild image gives `linux/arm64`. That matters because the
deployed runtime is x86_64 by default: `lambda-0010.yaml` sets no
`Architectures` and the ECS modules set no `RuntimePlatform`, so AWS defaults
both to x86_64, and an arm64 image would not run there at all.

On Apple Silicon that means an emulated build, which is slower — Docker
Desktop's Rosetta option helps a lot. For a fast native build while iterating,
override it, remembering the result is not what deploys:

```bash
make local-build BUILD_PLATFORM=linux/arm64
```

`make info` prints the platform it will use.

The container gets only the AWS variables by default. Anything the code reads
itself — a secret name, a feature flag — goes in `RUN_ENV`:

```bash
make local-run ENTRYPOINT= CMD="src.main_lambda.lambda_handler_1" TARGET=lambda \
    RUN_ENV="SECRET_NAME=my-settings DEBUG=1"
```

It is a space-separated `KEY=VALUE` list; a value containing spaces needs
`docker run` by hand. Overriding `RUN_ENV` replaces it wholesale, so keep
anything the Makefile's default sets — in the Python layer that is
`MODE=local`, which is how a local run opts out of the AWS-backed code paths
that deployed code takes by default.

`ENTRYPOINT`, `CMD`, `JSON` and `RUN_ENV` are make variables rather than positional
arguments, because make splits its goals on whitespace and `CMD` usually
contains some.

### Defaults and overrides

Defaults live at the top of the project's Makefile (`PROJECT_NAME`, `TARGET`,
`AWS_PROFILE`, `AWS_REGION`) and can be overridden per invocation:

```bash
make deploy-cicd lambda PROJECT_NAME=lambda-test-1    # throwaway name for a test deploy
make outputs AWS_PROFILE=gig-prod
```

Two things keep the commands honest:

- **One source of truth per target.** The deployment template, the Dockerfile
  and the base image all come from that target's `cicd_parameters.json`, so a
  local `make local-build` and the pipeline's build cannot drift apart.
- **`PROJECT_NAME` is sanitised into `STACK_NAME`.** Project directories are
  snake_case; CloudFormation stack names allow no underscores. `my_service`
  deploys as stacks `my-service` and `my-service-cicd`.

## Upgrading a project that already exists

Generated projects are copies, so template changes do not flow to them on their
own. [UPGRADING.md](UPGRADING.md) is the procedure — what to copy verbatim,
what to merge by hand, what never to touch — worked through with
`aws-service-template` as the example.

## Maintenance philosophy

- **Anything truly shared lives in `_base/`** — change once, every new project picks
  it up. The CFN target scaffolding, `Makefile`, `commands.sh`, GitHub workflow,
  integration test runner, `.gitignore`, etc. all sit here.
- **Anything language-specific lives under that language's folder** — `src/`,
  `tests/unit/`, `.devcontainer/`, `.vscode/`, `environment.yaml`, dependency
  files (`requirements.txt`, `go.mod`, `CMakeLists.txt`, `package.json`,
  `mix.exs`).
- **The `_base/targets/` set is the union of all known target types** — `lambda`,
  `service/task` (no load balancer) and `service/server` (behind an ALB, with a
  domain). A given project rarely needs all three; delete the ones you don't
  need from the generated project (e.g. nextjs typically only uses
  `service/server`).

## Adding a new language

1. Create a folder `<language>/` with the same shape as the existing ones.
2. Add the language to the `valid_languages` array in `make/bootstrap.sh`.
3. Add a case to the switch in `make/bootstrap.sh`: `language_version` first,
   then `base_image_lambda` and `base_image_service` built from it — without
   them the placeholders substitute to empty.
4. Write `<language>/environment.yaml` describing the local toolchain, so
   `make local-dev-setup` works in the generated project.
   The base-image case block also sets `container_workdir` and the four
   entrypoint/cmd values — they must match that language's Dockerfile.
5. Add a case to the "Next steps" switch at the bottom of `make/bootstrap.sh`.
6. Write a short `<language>/README.md` describing what's inside.

## Notes on the originals

The five source templates this consolidates:

| Source                                   | Used for                                                         |
|------------------------------------------|------------------------------------------------------------------|
| `aws-service-template`                   | `_base/` (most complete CFN targets, tests, .github, devcontainer) |
| `aws-server-template-python`             | `python/` source layout (cleaner `src/` structure)               |
| `aws_service_template_go`                | `golang/` source + devcontainer + .vscode                        |
| `aws-next-template`                      | `nextjs/` source + Next/TS/Tailwind config                       |
| `devcontainer_template/{c++,nodejs,elixir}` | `cpp/`, `nextjs/.devcontainer`, `elixir/` scaffolds            |

The originals are left in place — nothing was deleted from them.
