## Elixir

The Elixir tools, and how to run, test and debug. Tool versions are in
`mise.toml`.

### Tools

`mise.toml` installs elixir, erlang (the OTP release), cfn-lint and uv. The
first `mise install` builds Erlang from source, which takes several minutes.
Dependencies come from `mix.exs`: run `mix deps.get` once.

### Run

```zsh
MODE=local mix run --no-halt       # the application
iex -S mix                         # an interactive shell with the app loaded
```

### Test

```zsh
mix test                           # tests in test/
mix test test/app_test.exs:12      # one test, by line
make test                          # as the pipeline: in the base image (no JUnit report)
make lint                          # mix format --check-formatted, compile warnings, cfn-lint
```

### Debug (F5)

| Configuration | Starts |
|---|---|
| Run the application | `mix run`, with `MODE=local` |
| Unit tests | `mix test` |

Both use the ElixirLS debugger. `IEx.pry` works in `iex -S mix`.

### Devcontainer

The dev image is the official elixir image for the versions in `mise.toml`
(no Erlang build) plus both package lists. The image builders set
`ERL_FLAGS="+JMsingle true"` so a linux/amd64 build survives emulation on an
arm64 Mac.
