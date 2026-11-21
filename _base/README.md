# {{PROJECT_NAME}}

A {{LANGUAGE}} service on AWS, deployed as a Lambda function or a Fargate task.
Every command is `make <command>`; `make help` lists them all.

Each step below has its reasons and details in [NOTES.md](NOTES.md), which
also has the {{LANGUAGE}} commands and debug configurations.

## 1. Set up (once)

1. Install mise, and activate it after any other environment manager:

   ```zsh
   curl https://mise.run | sh
   echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
   ```

2. Install the toolchain from `mise.toml`, and the dependencies. Private
   packages come from GitHub over ssh, so load your key first:

   ```zsh
   ssh-add ~/.ssh/<your GitHub key>
   make local-dev-setup
   ```

3. Set `PROJECT_NAME` and `TARGET` in `project.env`. `PROJECT_NAME` must be
   unique to this deployment: a shared name deploys into another project's
   stacks. `TARGET` is `lambda`, `task` or `server`.
4. Check what every command will act on:

   ```zsh
   make info
   ```

## 2. Develop

1. Run the unit tests, as the pipeline runs them:

   ```zsh
   make test
   ```

2. Debug: press F5 in VS Code and pick a configuration.
3. Run the checks before you push:

   ```zsh
   make lint
   ```

4. Need a Linux library? Add its Debian package to `system_packages.txt`
   (runtime) or `system_packages_build.txt` (build). Then work in the
   devcontainer: VS Code, *Reopen in Container*.
5. Change a tool version: edit `mise.toml`, then run:

   ```zsh
   make sync-versions
   make local-dev-setup
   ```

## 3. Run the deployed image locally

1. Build the image the pipeline builds:

   ```zsh
   make local-build
   ```

2. Run it with `MODE=local`:

   ```zsh
   make local-run ENTRYPOINT={{RUN_ENTRYPOINT_TASK}} CMD="{{RUN_CMD_TASK}}" TARGET=task
   make local-run ENTRYPOINT={{RUN_ENTRYPOINT_SERVER}} CMD="{{RUN_CMD_SERVER}}" TARGET=server   # on localhost:8080
   make local-run ENTRYPOINT= CMD="{{RUN_CMD_LAMBDA}}" TARGET=lambda
   make invoke JSON='{"test": 1}'                                         # lambda only
   ```

3. Look at it, then stop it:

   ```zsh
   make local-logs
   make shell
   make local-stop
   ```

## 4. Deploy

1. Validate the templates and parameters:

   ```zsh
   make validate
   ```

2. Upload the environment file, now and whenever it changes:

   ```zsh
   make sync-config
   ```

3. Create or update the pipeline stack. It warns about existing stacks and
   asks before it goes on: answer `n` if a stack is not this project's.

   ```zsh
   make deploy-cicd
   ```

4. Push a branch. It lands as `main` in CodeCommit and starts the pipeline:

   ```zsh
   make push <branch>
   ```

5. Follow the pipeline, and find the service:

   ```zsh
   make pipeline
   make pipeline-errors           # if a stage failed
   make url
   ```

## 5. Inspect

```zsh
make outputs                   # the service stack's outputs
make events                    # failed stack events, newest first
make logs                      # the service's CloudWatch logs
```

## 6. Tear down

```zsh
make delete-all                # the service stack, then the pipeline stack
```

To remove only one: `make delete-stack` (service) or `make delete-cicd`
(pipeline, after emptying its ECR repository and artifact bucket).
