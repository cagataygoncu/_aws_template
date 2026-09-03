# Golang language layer

Go source, devcontainer, and editor settings for an AWS service.

When `bootstrap.sh golang <project_name>` runs, this folder is merged with
`_base/` to produce a working project skeleton.

Structure:
- `src/`            — application code (entry point: `main.go`)
- `tests/unit/`     — Go unit tests (`*_test.go`)
- `.devcontainer/`  — Go devcontainer
- `.vscode/`        — VS Code launch / settings / tasks tuned for Go
- `go.mod`/`go.sum` — module declaration & dependencies
