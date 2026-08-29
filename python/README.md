# Python language layer

Python source, tests, devcontainer, and editor settings for an AWS service.

When `bootstrap.sh python <project_name>` runs, the contents of this folder
are merged with `_base/` to produce a working project skeleton.

Structure:
- `src/`              — application code
  - `main.py`         — `process_request()`, the shared entry point; `get_mode()`
                        picks the online or local code path from `MODE`
  - `main_lambda.py`  — lambda handlers (target `lambda`)
  - `main_task.py`    — long-running task loop (target `service/task`)
  - `main_server.py`  — FastAPI app (target `service/server`)
- `lib/package_a/`    — internal library scaffold (rename to your project namespace)
- `tests/unit/`       — Python unit tests (pytest)
- `.devcontainer/`    — Python devcontainer (Conda + pip dev deps)
- `.vscode/`          — VS Code launch / settings / tasks tuned for Python
- `requirements.txt`  — runtime dependencies
