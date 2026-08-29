# Next.js language layer

Next.js (TypeScript + Tailwind) source, devcontainer, and editor settings
for a web-facing AWS service.

When `bootstrap.sh nextjs <project-name>` runs, this folder is merged with
`_base/` to produce a working project skeleton. Note that for nextjs the
relevant deploy target from `_base/targets/` is `service/server`; the
others (`lambda`, `service/task`) can be deleted from
a generated project.

Structure:
- `src/app/`           — Next.js App Router pages, API routes, layouts
- `src/components/`    — Reusable React components
- `src/lib/`           — Helpers (sessions, etc.)
- `src/middleware.ts`  — Next.js middleware
- `src/auth.ts`        — Auth.js config
- `server.mjs`         — Custom server entry
- `package.json`       — npm dependencies
- `tsconfig.json`      — TypeScript config
- `next.config.mjs`    — Next config
- `tailwind.config.ts` — Tailwind config
- `.devcontainer/`     — Node.js devcontainer
- `.vscode/`           — VS Code settings tuned for Node/TS
