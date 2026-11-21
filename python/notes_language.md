## Python

The Python tools, and how to run, test and debug. Tool versions are in
`mise.toml`.

### Tools

`mise.toml` installs python, uv, cfn-lint and ruff. `make local-dev-setup`
creates `./.venv` and installs `requirements.txt` (runtime) and
`.devcontainer/requirements_dev.txt` (pytest, ruff, debugpy and the rest).
With mise activated, `./.venv` is active inside the project.

### Run

```zsh
MODE=local python src/main_task.py                                        # the task
MODE=local uvicorn src.main_server:app --port {{CONTAINER_PORT}} --reload # the server
```

### Test

```zsh
python -m pytest tests/unit          # all unit tests
python -m pytest tests/unit -k name  # one test by name
make test                            # as the pipeline: in the base image, JUnit to reports/
make lint                            # ruff check, ruff format --check, cfn-lint
```

### Debug (F5)

| Configuration | Starts |
|---|---|
| Task: src/main_task.py | the task entry point |
| Server: uvicorn src.main_server:app | the server on port {{CONTAINER_PORT}}, with reload |
| Core: src/main.py | `process_request` on its own |
| Unit tests | pytest on `tests/unit`, under the debugger |
| Python: Current File | the open file |

All of them set `MODE=local` and `PYTHONPATH` to the project root.
Breakpoints work on the Mac and in the devcontainer.

### Devcontainer

The dev image is the official python image. `post_create.sh` installs
`requirements_dev.txt` into the container's python, so the container needs
no `./.venv`. A volume hides the Mac's `./.venv`, which cannot run on Linux.
