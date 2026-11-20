# TypeScript in {{PROJECT_NAME}}

The TypeScript side of [development.md](development.md): the tools, how to run,
test and debug. Tool versions are in `mise.toml`.

## Tools

`mise.toml` installs node, cfn-lint and uv. npm packages come from
`package.json`: run `npm install` once after `make local-dev-setup`.

## Run

```zsh
npm run build                 # tsc -> build/
MODE=local npm run task       # node build/src/main_task.js
MODE=local npm run server     # node build/src/main_server.js
```

## Test

```zsh
npm run build && npm test     # node --test on build/tests/unit
make lint                     # tsc --noEmit, eslint, cfn-lint
```

`npm test` runs the compiled tests, so build first.

## Debug (F5)

| Configuration | Starts |
|---|---|
| Debug current entrypoint | the open file, with tsx (no build step) |
| Task | `src/main_task.ts`, with tsx |
| Server | `src/main_server.ts` on port {{CONTAINER_PORT}}, with tsx |
| Unit tests | `npm test` |

All of them set `MODE=local`.

## Devcontainer

The dev image is the official node image (bookworm-slim) plus both package
lists. A native npm module needs its build tools in
`system_packages_build.txt`.
