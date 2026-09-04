# TypeScript layer

A plain Node + TypeScript service — not a web app. For a Next.js app with
pages, auth and SSR, use the `nextjs` layer instead; this one is the direct
TypeScript counterpart to the `python` and `golang` layers, with the same
three targets and the same `processRequest` shape.

## Layout

```
src/main.ts          getMode, processRequest - mirrors python's src/main.py
src/main_task.ts     the task target: loop forever
src/main_server.ts   the server target: node:http on ContainerPort
src/main_lambda.ts   the lambda target: exports handler
lib/package_a/       f1 - mirrors python's lib/package_a/module_x.py
tests/unit/          node:test, run against the compiled output
```

## Build

`tsc` compiles to `build/`, preserving the directory structure — so
`src/main_task.ts` becomes `build/src/main_task.js`, which is what the
deployment templates' `ContainerCmd` names. The images run the compiled
JavaScript; `tsx` is a devDependency so the debugger can run the TypeScript
directly without a build step in between.

## Dependencies

Deliberately few. `@aws-sdk/client-secrets-manager` is the only runtime
dependency — the server uses `node:http` and the tests use `node:test`, both
built in. Add express or fastify when the routes justify it; a template should
not make that choice for you.

## Lint

`npx tsc --noEmit && npx eslint .` — types first, since a type error is the one
that breaks the build. The eslint flat config is `eslint.config.mjs`.
