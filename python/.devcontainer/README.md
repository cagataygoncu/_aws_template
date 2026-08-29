# README

The devcontainer for a bootstrapped project - VS Code offers it, and the two
target-image variants beside it, in the *Reopen in Container* picker.

## What installs what

- `Dockerfile` installs the project's **root `requirements.txt`**, the same
  list the target images install. There is no second copy here.
- `requirements_dev.txt` is dev-only tooling (pytest, black, pylint, ...),
  installed by `post_create.sh`. The target Dockerfiles copy it into the image
  too, but only when built with `ENV=dev` - which the `service` and `lambda`
  variants do.
- `post_create.sh` also installs the AWS CLI and the Docker CLI, both chosen by
  `uname -m` so they work in an amd64 or an arm64 image.

## Editing it

- `devcontainer.json` names the container after the project and forwards the
  language's port; both come from `make/bootstrap.sh` placeholders.
- `build.args.ENV` / `build.args.DEBUG` reach the Dockerfile as build args.
