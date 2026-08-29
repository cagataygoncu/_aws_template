# README

The devcontainer for a bootstrapped project - VS Code offers it, and the two
target-image variants beside it, in the *Reopen in Container* picker.

## What installs what

- `Dockerfile` provides the language toolchain, pinned to the same version as
  the target images (`language_version` in `make/bootstrap.sh`).
- `post_create.sh` installs the AWS CLI and the Docker CLI, both chosen by
  `uname -m` so they work in an amd64 or an arm64 image. There are no Python
  requirements files in this layer.

## Editing it

- `devcontainer.json` names the container after the project and forwards the
  language's port; both come from `make/bootstrap.sh` placeholders.
- `build.args.ENV` / `build.args.DEBUG` reach the Dockerfile as build args.
