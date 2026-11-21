## Next.js

The Next.js tools, and how to run, test and debug. Tool versions are in
`mise.toml`.

### Tools

`mise.toml` installs node, cfn-lint and uv. npm packages come from
`package.json` and `package-lock.json`: run `npm install` once after
`make local-dev-setup`.

### Run

```zsh
npm run dev                          # next dev, with hot reload
PORT={{CONTAINER_PORT}} node server.mjs       # the server the image runs
```

`.env.local` holds the local settings (NextAuth, Cognito). Git ignores it in
this project: put real values there, never in git.

### Test

There are no unit tests yet: `make test` reports that there is nothing to
run. When you add some, set `TEST_COMMAND` in `make/commands.sh`, so `make
test` and the pipeline run them. Until then:

```zsh
npm run build      # next build: type errors fail it
make lint          # tsc --noEmit, next lint, cfn-lint
```

### Debug (F5)

| Configuration | Starts |
|---|---|
| Server: server.mjs | the production server on port {{CONTAINER_PORT}} |
| Next dev server | `npm run dev` |

### Devcontainer

The dev image is the official node image (bookworm-slim) plus both package
lists. There is no lambda target: a Next.js app is a server.
