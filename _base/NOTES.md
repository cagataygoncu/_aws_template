# {{PROJECT_NAME}} — notes

The details and reasons behind the steps in [README.md](README.md). Read a
section at a time: `grep -n '^#' NOTES.md` lists them. The {{LANGUAGE}}
commands and debug configurations have their own section, after **Development**.

## Project name and target

Both are declared in `project.env`. Between them they decide *which* AWS
resources a command touches and *what* gets put in them, and neither is
inferred from anything:

```zsh
# project.env
PROJECT_NAME=my-own-service      # <- yours, not whatever it says now
TARGET=server                    # <- lambda, task or server
```

**`PROJECT_NAME` must be unique to this deployment.** Two projects sharing a
name do not get two deployments — they get one, and the second person to run
`make deploy-cicd` deploys *into the first one's stacks*.

It names both CloudFormation stacks and, through them, the ECR repository,
the CodeCommit repository, the pipeline, the artifact bucket, the IAM roles,
the ECS service and the environment file's path in S3. The pipeline deploys
with `StackName: !Ref ProjectName`, so a shared name is not a collision that
fails loudly — **it is a silent overwrite of someone else's running service**.

**`TARGET` decides what this project deploys** — a Lambda function
(`lambda`), a Fargate task with no load balancer (`task`), or one behind an
ALB with a domain (`server`). It selects the Dockerfile, the deployment
template and the base image, so a wrong value builds and deploys the wrong
thing without ever failing.

It does **not** give you a second deployment. The stack is named after
`PROJECT_NAME` whatever the target, so changing `TARGET` and pushing again
rewrites the *same* stack — the Lambda function is deleted and an ECS
service created in its place, or the reverse. To run two shapes side by
side, give the second one its own `PROJECT_NAME`.

Check both before the first deploy, and any time you are not certain what
this working copy is pointed at:

```zsh
make info | head -4
```

## Commands

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

The last segment on its own is enough — `lambda`, `task`, `server` — since
nothing else under `targets/` shares those names. The nesting only exists
because the two service targets share one Dockerfile; it is not something you
need to type. A name that matched two targets would be reported rather than
guessed at.

`TARGET` in `project.env` selects the one this project deploys; pass one
positionally to override for a single run:

```zsh
make local-build               # uses $(TARGET)
make local-build lambda        # just this once
```

Per-target facts — the deployment template, the Dockerfile, the base image, the
CodeBuild image — all come from that target's `cicd_parameters.json`, so a
local `make local-build` and the pipeline's build cannot drift apart.

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
`make local-run` publishes to and the port the deployment sends are the same value,
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
TARGET=lambda make local-build
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
make sync-config               # upload it, and again whenever it changes
```

`make deploy-cicd` refuses to run when that object is missing, because a
missing file does not fail the deployment — it fails the task minutes later
with `ResourceInitializationError`.

It is configuration, never secrets. Put those in Secrets Manager and read them
with the task role - see **Configuration** below.

The `lambda` target uses the same file, by a different route: Lambda has no S3
environment file — that is an ECS task-definition feature — so `make
sync-config` writes the same values into the `EnvironmentVariables` parameter
in `targets/lambda/deployment_parameters.json`, which the module expands into
the function's `Environment.Variables`. That is a change to the repository
rather than to a bucket, so **commit and push it** — the deployed function
keeps its old environment until the pipeline runs. `make config` reports
whether the two are in step.

Both read `TARGET` from `project.env`, so neither needs the target spelled out;
pass one positionally only to act on a target this project is not set to.

### Configuration: the secret, the config object, the block

Three pieces. `container_config.env` says where the other two are, the secret
holds the credentials and API keys, and the config object holds everything
else:

| Where | What |
| --- | --- |
| Secrets Manager, named by `AWS_SECRET_NAME` | credentials, API keys - nothing else |
| `s3://<CONFIG_BUCKET>/<CONFIG_KEY>` (local copy `services/<basename of CONFIG_KEY>`; the default key sits under the stack name, beside the environment file) | every other setting, as JSON: profiles and blocks |
| `container_config.env` | `AWS_SECRET_NAME`, `CONFIG_BUCKET`, `CONFIG_KEY`, `CONFIG_BLOCK` |

A secret has a size limit, and settings do not need one: keeping only
credentials and keys in it leaves the settings free to grow, and lets them be
read, reviewed and versioned like code.

The secret, keyed by ids of your choosing:

```json
{
    "credentials": {
        "cred_1": { "username": "gig", "password": "..." }
    },
    "api_keys": {
        "api_key_1": "<key>"
    }
}
```

Nothing in the secret says where anything is: the deployment carries its own
config location, so a second deployment reading a different object needs no
second secret. A setting names a credential by id - `"NATS_CREDENTIAL":
"cred_1"` - so the same user name can sit under two ids with a different
password each. Any setting ending in `_CREDENTIAL` is checked at startup: an id
the secret does not hold fails it.

The config object, `services/service_settings.json` to start with:

```json
{
    "_README": { "WORKERS": "How many requests the service works on at once." },
    "profiles": {
        "default": { "EXAMPLE_ENDPOINT": "https://example.com", "EXAMPLE_CREDENTIAL": "cred_1" }
    },
    "service": { "PROFILE": "default", "WORKERS": 4 }
}
```

- `CONFIG_BLOCK` picks the block a deployment runs - `service` here. A second
  deployment of the same code can run another block from the same object.
- A block may name a `PROFILE`: settings several blocks share. The block's own
  keys win over its profile's.
- `_README` documents every key, in the file itself.

Each language reads it the same way, with a loader the template keeps in step
across languages: `src/config.py`, `src/app/config.go`, `src/config.ts`,
`config.mjs` (nextjs), `lib/config.ex`, `src/config.cpp`. Everything is read
once, at startup, so a change takes a restart. With `MODE=local` nothing comes
from AWS: the loader reads the local copy, has no credentials, and takes
`CONFIG_KEY` and `CONFIG_BLOCK` from `container_config.env` when the
environment lacks them - so F5 and a local run need no setup. nextjs puts the
settings, and each API key under its id, into `process.env` before Next starts,
so `{"api_keys": {"AUTH_SECRET": "..."}}` gives NextAuth its `AUTH_SECRET`. The
C++ loader reads only the local copy: online mode needs the AWS SDK for C++,
which the layer does not ship.

A unit test resolves the shipped block, so a broken file fails `make test` and
the pipeline. Editing config:

```zsh
# edit services/service_settings.json, then
make test
make sync-config      # uploads container_config.env and the config object it names
```

`make sync-config` uploads the environment file and the object together, and
`make config` reports both, including whether the remote copy still matches the
local one. Every target reads the object from S3, `lambda` included: on
`lambda` the environment file travels with the template as
`EnvironmentVariables`, which is how `CONFIG_BUCKET` and `CONFIG_KEY` still
reach the function, and the execution role's `S3BucketList` covers the object.

Leave `CONFIG_BUCKET` and `CONFIG_KEY` empty when the service reads no such
object - neither command then mentions it - and `AWS_SECRET_NAME` empty when it
has no secrets.

## Development

### Where the code runs

There are three places to run the code. Use the first one unless you have a
reason not to.

| Place | Use it for | Set up with |
|---|---|---|
| **Your Mac, with mise** (the main way) | editing, unit tests, debugging, `make` commands | `make local-dev-setup` |
| **The devcontainer** (`.devcontainer/`) | code that needs a Linux system library, and a clean Linux toolchain | VS Code: *Reopen in Container* |
| **The deployed image** (`make local-build`, `.devcontainer/service/`, `.devcontainer/lambda/`) | checking what actually ships | `make local-build <target>` |

Three files decide what each place has:

- `mise.toml`: the language and tool versions on your Mac, and the version
  of every base image.
- `system_packages.txt` (runtime) and `system_packages_build.txt` (build):
  Debian packages for the devcontainer and the deployed images. Add a C
  library here, not in a Dockerfile.
- `.vscode/launch.json`: the debug configurations, the same on the Mac and
  in the devcontainer.

### Set up your Mac

Once per machine:

```zsh
curl https://mise.run | sh                        # or: brew install mise
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc    # after any other environment's activation
```

Once per clone, and again after you edit `mise.toml` or a requirements file:

```zsh
make local-dev-setup
```

This installs the tools in `mise.toml` with `mise install`. For python it
also fills `./.venv`. With mise activated, the tools are on `PATH` inside the
project. `make` commands find them even without activation.

Put `mise activate` after any other environment manager in `~/.zshrc`.
Otherwise an older tool from that environment can shadow a pinned one when
you type its name. `make` commands are not affected.

`mise.toml` lists the language and the tools `make lint` and the editor use:
cfn-lint everywhere, gopls and dlv for go, cmake, ninja and clang-format for
C++. Re-run `make local-dev-setup` after editing `mise.toml` or a
requirements file.

### System packages

Libraries mise cannot install, such as a C library, its headers or a
compiler, go in two lists of Debian package names:

| File | Installed into | For |
|---|---|---|
| `system_packages.txt` | the deployed service image (final stage) and the devcontainer | what the app needs to run |
| `system_packages_build.txt` | the build stage of the deployed images and the devcontainer | compilers and `-dev` headers |

One package per line. The Dockerfiles read the lists, so add a package there,
not in a Dockerfile. The host cannot use these Linux libraries: build and
test code that needs them in the devcontainer. A lambda's final image is
Amazon Linux, which the lists do not reach; install there with `dnf` in its
Dockerfile.

### Private packages

Shared code lives in private GitHub repositories (`github.com/GIGTennis/...`),
fetched with a token or over ssh. Declare one in the language's own
dependency file - ssh URLs work for both routes:

| Language | Where | Example |
|---|---|---|
| python | `requirements.txt` | `git+ssh://git@github.com/GIGTennis/<repo>.git@<tag>#subdirectory=<package>` |
| go | `go.mod` | `require github.com/GIGTennis/<module> <version>` |
| typescript, nextjs | `package.json` | `"<name>": "git+ssh://git@github.com:GIGTennis/<repo>.git#<tag>"` |
| elixir | `mix.exs` | `{:<name>, git: "git@github.com:GIGTennis/<repo>.git", tag: "<tag>"}` |
| C++ | `CMakeLists.txt` | `FetchContent_Declare(<name> GIT_REPOSITORY git@github.com:GIGTennis/<repo>.git GIT_TAG <tag>)` |

Git fetches them in every language, by one of two routes, chosen by
`make/github_env.sh`:

| Route | When | How |
|---|---|---|
| **Token** (HTTPS) | `GITHUB_TOKEN` is set | git rewrites `git@github.com:` and `ssh://git@github.com/` URLs to HTTPS, and a credential helper answers with the token. Set through `GIT_CONFIG_*` environment variables only: nothing is written to disk or into a URL |
| **ssh** | `GITHUB_TOKEN` is empty | your ssh key, from the agent or `~/.ssh/config`. Go modules in `GOPRIVATE` are rewritten to ssh |

On your Mac, the token from the GitHub CLI is the simplest:

```zsh
gh auth login                                   # once
export GITHUB_TOKEN="$(gh auth token)"          # in ~/.zshrc, before mise activate
```

A fine-grained token with read access to the repositories works too.

Where each place gets access:

| Where | Token route | ssh route |
|---|---|---|
| your shell, `make` | `mise.toml` sources `make/github_env.sh` | the same |
| `make local-dev-setup` | checks the token with the GitHub API first | checks `ssh -T git@github.com` first |
| `make test` | the token and git settings are passed into the container | the ssh agent is forwarded |
| devcontainer | `remoteEnv` passes `GITHUB_TOKEN` in | the ssh agent is forwarded |
| `make local-build` | a BuildKit secret (`--secret id=github_token`): never in an image layer | `docker build --ssh` |
| the pipeline | set `GitHubTokenSecretArn` in each target's `cicd_parameters.json` to a Secrets Manager secret holding the token, then `make deploy-cicd`. A GitHub App installation token suits CI best: short-lived and not a person's | the ssh key in Secrets Manager, as before |

Go also needs to know which modules are private: `GOPRIVATE` is set in
`mise.toml`'s `[env]` and in `.vscode/settings.json` (`go.toolsEnvVars`, for
gopls). Another organisation means editing both.

If `make local-dev-setup` says GitHub refused access, fix the route it checked:

```zsh
export GITHUB_TOKEN="$(gh auth token)"           # token route
ssh-add ~/.ssh/<your GitHub key>                 # ssh route (with GITHUB_TOKEN unset)
```

### Tool versions

`mise.toml` is the only place this project writes a tool version. The base
images (`BaseImageURI` in `targets/*/cicd_parameters.json`) name it as
`${mise:<tool>}`. `make local-build` resolves that token, and so does the
pipeline at each build. Every other copy sits under a `mise-sync:` comment:
the devcontainer images, `.vscode/settings.json` and `go.mod`.

To move a version:

```zsh
# edit mise.toml, e.g. python = "3.13"
make sync-versions             # rewrite every mise-sync line from mise.toml
make versions                  # the versions, and the image each target uses
make lint                      # fails while any synced line is stale
```

`make local-dev-setup` and opening the devcontainer both sync first. A
devcontainer that finds stale lines stops and asks for a rebuild, because the
editor has already read the old values. mise itself is optional: the scripts
read `mise.toml` without it.

### The development loop

Each step is slower than the one before, and closer to production. Start at
the top. At the first failure, go back to editing.

| Step | Command | What it proves | Needs |
|---|---|---|---|
| 1. Unit tests | the language's runner (see the language section), F5 *Unit tests*, or `make test` | the logic works | `make test`: Docker |
| 2. Debug | F5 in VS Code | you can step through the failing path | nothing else |
| 3. Lint | `make lint` | versions agree with `mise.toml`, the code passes its linter, the CloudFormation templates pass cfn-lint | `make local-dev-setup` |
| 4. Build the image | `make local-build <target>` | the Dockerfile builds with the system packages | Docker |
| 5. Run the image | `make local-run ...`; for lambda, `make invoke JSON='<json>'` | the deployed image starts and answers | Docker |
| 6. Validate | `make validate <target>` | the templates and parameters are deployable | AWS credentials |
| 7. Deploy | `git push` / `make push` | the pipeline builds and deploys it | the pipeline stack |
| 8. Inspect | `make url`, `make logs`, `make events` | it runs in AWS | AWS credentials |

**`MODE=local`.** Deployed code reads its config object from S3 and its
secret from Secrets Manager. With `MODE=local`, it reads the local copy in
`services/` and no secret. Every debug configuration sets it, and `make
local-run` sets it by default. Run without it to test the real path against
AWS.

`make local-run` starts the container the way ECS does: it loads
`container_config.env` with `--env-file`, and `RUN_ENV` wins over it. The
image has no `services/`, so `make local-run` mounts it read-only into the
image's working directory.

### Debugging

Press **F5** in VS Code and pick a configuration. The configurations start
the same entry points the deployed images run: the task, the server, the
lambda handler, the unit tests. The language section lists them.

The same `.vscode/launch.json` works on your Mac and in the devcontainer.
Debug in the devcontainer when the code needs a Linux system library, or for
C++, whose debugger (gdb) is installed there.

The devcontainer follows your Mac's CPU architecture, so the debugger runs
natively. The deployed images build for the pipeline's architecture, which
can be emulated on your Mac. Debug the dev container, not a deployed image.

When the deployed image behaves differently from an F5 run, open
`.devcontainer/service/` or `.devcontainer/lambda/`. They build the deployed
image, so you can look at what it actually contains. `make shell` opens a
shell in a running `make local-run` container.

### Testing

| Level | Where the tests live | Runs |
|---|---|---|
| Unit | `tests/unit/` (elixir: `test/`) | the language's runner on your Mac, F5, or `make test` |
| Lint | the language's linter, plus cfn-lint | `make lint` |
| Image | the Dockerfile | `make local-build`, then `make local-run` / `make invoke` |
| Deployment | the CloudFormation templates | `make validate <target>` |

**`make test`** runs the unit tests the way the pipeline does: inside the
service base image, at the versions in `mise.toml`, with the project mounted.
It writes a JUnit report to `reports/unit_tests.xml` (elixir writes none).
Run it before you push: a pass here is a pass in the pipeline.

The language's own runner is faster for the edit-test loop. `make test` is
the check that the tests pass on Linux, at the pinned versions, with a clean
dependency install.

**The pipeline's test stage** runs when `RunTests` is `"true"` in the
target's `cicd_parameters.json`. It runs `make test` in CodeBuild, before
the image is built, and publishes the JUnit report as a CodeBuild test
report. A failing test stops the deployment. A project without unit tests
yet (cpp and nextjs, at first) passes the stage with a note.

```
CodeBuild test stage  ->  ./make/commands.sh test  ->  docker run <service base image> <test command>
```

### The devcontainer

Open the project in VS Code and choose *Reopen in Container*. The picker
offers three configurations:

| Config | Builds | Use it for |
|---|---|---|
| `.devcontainer/` | `.devcontainer/Dockerfile` | day-to-day Linux work: toolchain, debugger, system packages |
| `.devcontainer/service/` | `targets/service/Dockerfile` | looking inside the deployed service image |
| `.devcontainer/lambda/` | `targets/lambda/Dockerfile` | looking inside the deployed lambda image |

What happens when it opens:

1. `init.sh` runs on your Mac. It checks the ssh agent, syncs the version
   lines from `mise.toml`, and refreshes the ECR Public login. If versions
   were out of step, it syncs them and stops: rebuild the container.
2. Docker builds the image. Both package lists are installed.
3. VS Code installs its server in the container. After a VS Code update it
   downloads the server again (about 200 MB), which can take minutes.
4. `post_create.sh` installs the AWS CLI, the Docker CLI and the dev tools.

The container mounts `~/.aws`, `~/.gitconfig`, `~/.ssh/config` and the
Docker socket. `make local-build`, `make local-run` and `make invoke` work
inside it, through your Mac's Docker. No private key is mounted: git uses
the forwarded ssh agent, so run `ssh-add ~/.ssh/<key>` on your Mac.

`make local-dev-setup` is not needed in the devcontainer: the image is the
environment.

**Use the root config for day-to-day work and debugging.** The target variants
exist so you can see what actually ships; every dev tool added to them is one
more difference between what you test and what deploys.

You usually do not need to open them at all — the root container has the Docker
socket mounted, so `make local-build`, `make local-run`, `make invoke` and `make shell`
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
run, with `MODE=local` so a debug session skips the Secrets Manager read —
the same thing `RUN_ENV` does for `make local-run`.

The devcontainer image is **not** pinned to a platform: it follows the host, so
it is native on both an Apple Silicon laptop and an x86_64 builder. Debuggers
attach through `ptrace`, which fails against an emulated process. The deployed
images still build for the platform the pipeline builds for.

#### When a rebuild cannot pull the base image

`Your authorization token has expired` — an ECR Public login token lasts 12
hours, and docker keeps presenting an expired one instead of falling back to an
anonymous pull. `.devcontainer/init.sh` and `make local-build` both refresh it now;
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

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make lint` fails with "disagree with mise.toml" | a version changed in `mise.toml` only | `make sync-versions` |
| A tool runs an unexpected version | another environment comes first on `PATH` | `mise activate` after it in `~/.zshrc`; `make` commands are not affected |
| *Reopen in Container* stops after "versions were out of step" | `init.sh` synced `mise.toml` changes | rebuild the container |
| *Reopen in Container* sits at "Downloading VS Code Server" | a VS Code update needs a new server | wait; it is cached afterwards |
| The container log shows `Exit code 1` lines | VS Code checks for files that a new container does not have yet | nothing: these are not errors |
| A build fails with "authorization token has expired" | an old ECR Public login | `init.sh` refreshes it; or `docker logout public.ecr.aws` |
| `ssh-keyscan` or a private git dependency fails in a build | no ssh agent key | `ssh-add ~/.ssh/<key>` on your Mac |
| A C library is missing in the image | it is not in a package list | add it to `system_packages.txt` or `system_packages_build.txt` |
| `make test` cannot fetch a private git dependency | no ssh agent key | `ssh-add ~/.ssh/<key>` on your Mac; the pipeline loads its own key |
| `make test` passes but the language's runner fails, or the reverse | different versions or dependencies on your Mac | trust `make test`: it uses the pinned versions; then `make local-dev-setup` |

{{LANGUAGE_NOTES}}

## Check what you are about to touch

```zsh
make info                      # project, stacks, account, resolved files
make info lambda               # ... for a different target
make targets                   # targets this project still has
make config                    # the environment variables
make template-version          # the gig-cfn-templates release each target pulls
make aws-info
```

## Deploy

Two stacks: `{{PROJECT_NAME}}-cicd` (the pipeline, from
`targets/common/cicd.yaml`) and `{{PROJECT_NAME}}` (the service, created by that
pipeline).

```zsh
make validate                  # cicd.yaml + the target's deployment.yaml
make sync-config               # once, and whenever the env file changes
make deploy-cicd               # check existing stacks, create/update the pipeline, wire the git remote
make push <branch>             # push it to CodeCommit main, starting the pipeline
make pipeline                  # stage states
make pipeline-stop             # abandon the running execution
```

Before it deploys, `make deploy-cicd` checks both stacks:

| It finds | It does |
|---|---|
| neither stack | says both will be created, and goes on |
| one or both stacks | lists each with its status and when it last changed, then asks `(y/n)` in a terminal (elsewhere it warns and goes on) |
| a pipeline that deploys another target | says so: its next run would replace `{{PROJECT_NAME}}` with this target's template |
| a stack mid-operation (`*_IN_PROGRESS`) | stops: wait for it (`make events`) |
| a pipeline in `ROLLBACK_COMPLETE` | stops: it cannot be updated, so `make delete-cicd` first |

A stack you did not expect usually means `PROJECT_NAME` in `project.env`
names another project. Answer `n` and fix it.

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
  the *new* path does not exist yet. `make sync-config` puts it there;
  `make deploy-cicd` refuses to run until it is.

`ServiceName` needs no change: every resource built from it is prefixed with
`ProjectName`, so `my-service-v2-server` cannot collide with `my-service-server`.

#### Worked example

Working on a `new-branch` branch, deploying beside a live `my-service`:

```zsh
git checkout -b new-branch

# 1. Name the second deployment, in project.env. Nothing infers it: the
#    directory is still named after the ORIGINAL project, and a fallback to
#    the basename would deploy into the live stack.
#      PROJECT_NAME=my-service-v2

# 2. In targets/<target>/deployment.yaml, set what does not separate:
#      DomainName:   'my-service-v2.example.com'
#      HostedZoneId: 'Z0123456789ABCDEFGHIJ'

make info                      # read every name before creating anything
make validate                  # templates, and what still has no default
make sync-config               # the environment file, at the NEW path

make deploy-cicd               # creates my-service-v2-cicd, adds the git remote
make push new-branch           # to the new remote only - see below
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
local: `make push new-branch` lands as `main` on the far side, which is what the
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

## Call the deployed service

### lambda

The function is deployed as `{{PROJECT_NAME}}-<LambdaFunctionName>`, which is
not the `LambdaFunctionName` parameter — the nested module scopes it by
project. Take it from the stack rather than assembling it:

```zsh
FUNCTION=$(make output-value LambdaFunctionName)

aws lambda invoke --function-name "$FUNCTION" \
    --cli-read-timeout 0 \
    --cli-binary-format raw-in-base64-out \
    --payload '{"test": 1}' \
    /dev/stdout
```

That is the direct API call and it uses your `AWS_PROFILE`, so it is the one to
reach for first.

**`--cli-read-timeout 0` is not optional.** `invoke` is synchronous and blocks
for as long as the function runs, up to its `Timeout` (900s by default here).
The CLI's own read timeout is 60s and it *retries* on expiry, so a function
that takes longer than a minute looks like a hang and is silently invoked
again. `0` disables the timeout; `make logs` in another terminal shows what it
is actually doing.

To hand it off and not wait at all:

```zsh
aws lambda invoke --function-name "$FUNCTION" --invocation-type Event \
    --cli-binary-format raw-in-base64-out --payload '{"test": 1}' /dev/null
```

A first invoke is also slower than the rest: a cold start pulls the image, and
a VPC-attached function attaches an ENI before any of your code runs.

The function URL is a second route, and it is **`AuthType: AWS_IAM`** — a plain
`curl` gets 403. It has to be SigV4-signed, so send credentials with it:

```zsh
set -a; source project.env; set +a          # AWS_PROFILE, AWS_REGION
eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env)"

URL=$(make output-value LambdaFunctionUrl)

curl -sS -X POST "$URL" \
    --aws-sigv4 "aws:amz:${AWS_REGION}:lambda" \
    --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
    -H "x-amz-security-token: ${AWS_SESSION_TOKEN}" \
    -H "content-type: application/json" \
    -d '{"test": 1}'
```

`--aws-sigv4` needs curl 8; `brew install curl` if the system one is older.

The two paths differ in what the handler receives: `aws lambda invoke` delivers
the payload as the event, while the function URL wraps it in an API Gateway v2
request and the body arrives as a JSON string in `event["body"]`.

### service/server

`make url` prints the invoke URL, and there is no IAM in front of it:

```zsh
curl -sS "$(make url)/api/status"
```

## Run locally

The image is built from the same Dockerfile and base image the pipeline uses,
both read from the target's `cicd_parameters.json`. `~/.aws` is mounted
read-only and `AWS_PROFILE` passed through, so no credentials end up in the
container's environment.

`ENTRYPOINT` and `CMD` are whatever that target's image runs — for this project:

```zsh
# task
make local-run ENTRYPOINT={{RUN_ENTRYPOINT_TASK}} CMD="{{RUN_CMD_TASK}}" TARGET=service/task

# server - the app binds {{CONTAINER_PORT}}; make local-run publishes it on 8080
make local-run ENTRYPOINT={{RUN_ENTRYPOINT_SERVER}} CMD="{{RUN_CMD_SERVER}}" TARGET=service/server
open http://localhost:8080

# lambda - the image entrypoint is kept on purpose, so the handler is the command
make local-run ENTRYPOINT= CMD="{{RUN_CMD_LAMBDA}}" TARGET=lambda
make invoke JSON='{"test": 1}'

# anything the code reads itself goes in RUN_ENV, which REPLACES the default
# MODE=local - so keep MODE= in whatever you pass
make local-run ENTRYPOINT={{RUN_ENTRYPOINT_TASK}} CMD="{{RUN_CMD_TASK}}" TARGET=task \
    RUN_ENV="MODE=local AWS_SECRET_NAME=my-settings DEBUG=1"

# the online path, against the real services it needs
make local-run ENTRYPOINT={{RUN_ENTRYPOINT_TASK}} CMD="{{RUN_CMD_TASK}}" TARGET=task \
    RUN_ENV="MODE=online AWS_SECRET_NAME=my-settings"

# a service with no local mode: give it what it actually reads at startup
make local-run ENTRYPOINT={{RUN_ENTRYPOINT_SERVER}} CMD="{{RUN_CMD_SERVER}}" TARGET=server \
    RUN_ENV="AWS_SECRET_NAME=my-service-api-keys LOG_LEVEL=debug"

make local-logs
make shell
make local-stop
```

`make local-run` with neither is refused rather than guessed: the image's own default
would run, and for a python image that is a bare `python3` which reads EOF,
exits 0 and logs nothing — a broken run that looks like a successful one.

The authoritative values are `ContainerEntryPoint` and `ContainerCmd` in the
target's `deployment.yaml`. Those carry CloudFormation quoting, so drop the
surrounding quotes when passing them here — or run `make local-run` with neither and
read them off the error, which prints the exact line for the target, port
substituted:

```
$ make local-run TARGET=lambda
ERROR: no ENTRYPOINT and no CMD - the image would run its own default ...
  lambda deploys this, from targets/lambda/deployment.yaml:
    make local-run ENTRYPOINT="/lambda-entrypoint.sh" CMD="{{RUN_CMD_LAMBDA}}" TARGET=lambda
```

### RUN_ENV

The container starts with the AWS variables and nothing else — `AWS_PROFILE`,
`AWS_REGION` and a read-only mount of `~/.aws`, so no credentials end up in its
environment. Everything the code reads itself goes in `RUN_ENV`, a
space-separated `KEY=VALUE` list. A value containing spaces needs `docker run`
by hand.

**It replaces the default rather than adding to it.** The Makefile sets
`RUN_ENV ?= MODE=local`, which is what lets a local run work with no
AWS-backed services: the code reads `MODE` and defaults to `online`, so
deployed code sets nothing and runs online while `make local-run` opts out.
Pass your own `RUN_ENV` and `MODE=local` is gone unless you repeat it.

`make info` prints the `RUN_ENV` a bare `make local-run` would use, and
`make help` shows the current default in its examples, so what the container
gets is visible without reading the Makefile.

Not every service has a local mode. One that reads its configuration at
startup and refuses to serve without it needs those values passed, `MODE` or
no `MODE` — this is the shape of failure when they are missing:

```
tournament-simulator-local exited (1) - nothing is listening on 8080

    INF Environment variables LOG_LEVEL= AWS_SECRET_NAME=
    ERR Failed to start server error="AWS_SECRET_NAME is not set"
```

The container ran, logged what it was given, and stopped. `make local-run`
prints the exit code and the last lines of the log for exactly this reason:

```zsh
make local-run ENTRYPOINT={{RUN_ENTRYPOINT_SERVER}} CMD="{{RUN_CMD_SERVER}}" \
    RUN_ENV="AWS_SECRET_NAME=my-service-api-keys"
```

The values the *deployed* container gets are in `container_config.env`, which
is uploaded to S3 and read by ECS — `make local-run` does not load it. When a
local run needs the same environment, copy the values into `RUN_ENV`.

### Build platform

`make local-build` builds for the platform the pipeline builds for, not the one your
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
make local-build BUILD_PLATFORM=linux/arm64
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
