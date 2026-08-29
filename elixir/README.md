# Elixir language layer

Elixir Mix project, devcontainer, and editor settings for an AWS service.

When `bootstrap.sh elixir <project_name>` runs, this folder is merged with
`_base/` to produce a working project skeleton.

Structure:
- `lib/`            — application modules (entry: `lib/example.ex`, `lib/module1.ex`)
- `test/`           — ExUnit tests
- `mix.exs`         — Mix project definition
- `.formatter.exs`  — formatter config
- `.iex.exs`        — IEx startup hooks
- `.devcontainer/`  — Elixir devcontainer
- `.vscode/`        — VS Code settings tuned for ElixirLS
