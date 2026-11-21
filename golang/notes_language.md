## Go

The Go tools, and how to run, test and debug. Tool versions are in
`mise.toml`.

### Tools

`mise.toml` installs go, gopls (the language server), dlv (the debugger),
cfn-lint and uv. Go modules come from `go.mod`.

### Run

```zsh
MODE=local go run ./src/main_task                    # the task
MODE=local PORT={{CONTAINER_PORT}} go run ./src/main_server   # the server
```

### Test

```zsh
go test ./tests/...              # all unit tests
go test ./tests/... -run Name    # one test
make test                        # as the pipeline: in the base image, JUnit to reports/
make lint                        # go vet, gofmt, cfn-lint
```

### Debug (F5)

| Configuration | Starts |
|---|---|
| Debug current entrypoint | the package of the open file |
| Task | `src/main_task` |
| Server | `src/main_server` on port {{CONTAINER_PORT}} |
| Lambda handler | `src/main_lambda` |
| Unit tests | `tests/unit`, under the debugger |

All of them set `MODE=local`. dlv debugs natively on the Mac. In the
devcontainer it attaches through `ptrace`, which the container allows.

### Devcontainer

The dev image is the official golang image plus both package lists.
`post_create.sh` installs the tools in `.devcontainer/tools_dev.txt` (gopls,
dlv). A cgo dependency, such as a C library, needs its `-dev` package in
`system_packages_build.txt` and its runtime package in `system_packages.txt`.
