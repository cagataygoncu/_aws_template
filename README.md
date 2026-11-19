# _aws_template

Multi-language AWS service template with a single shared infra layer. It
replaces the per-language templates that lived alongside it
(`aws-service-template`, `aws_service_template_go`, `aws-server-template-python`,
`aws-next-template`, `devcontainer_template/`).

Details are in [NOTES.md](NOTES.md), read by section (see **Where the details
are**). [UPGRADING.md](UPGRADING.md) is the procedure for bringing an existing
project up to date.

## What it does

`make new <language> <project_name>` builds a project in four steps:

1. Copy `_base/`, the shared layer: Makefile, `make/commands.sh`, CloudFormation
   targets, buildspecs, integration tests, GitHub workflow.
2. Overlay `<language>/` on top: source, tests, Dockerfiles, devcontainer,
   `.vscode/`, `environment.yaml`, `mise.toml`. The language layer wins on
   conflicts.
3. Fill the `{{PLACEHOLDERS}}` from `<language>/layer.env`, then write every
   version line from `mise.toml`.
4. Write `.template.env`, the stamp: the template commit and the answers given.

## Layout

```
_aws_template/
├── _base/                  # shared by every language
│   ├── Makefile, make/     # project commands: commands.sh, versions.sh, setup_local_dev_env.sh
│   ├── targets/            # common/ (cicd, buildspecs), lambda/, service/{task,server}/
│   └── tests/integration/, .github/workflows/, project.env, container_config.env
├── python/ golang/ typescript/ cpp/ nextjs/ elixir/   # language layers, each with:
│   ├── layer.env           # placeholder values (never shipped)
│   ├── mise.toml           # default tool versions (shipped)
│   ├── LAYER.md            # what the layer holds (never shipped)
│   └── src/, tests/, targets/*/Dockerfile, .devcontainer/, .vscode/, environment.yaml
├── make/
│   ├── bootstrap.sh        # make new
│   ├── manifest.sh         # make classify, make check-manifest
│   ├── render.sh           # render one project from any version (a tag, a commit, or .)
│   ├── render_all.sh       # make render-all
│   └── upgrade.sh          # make upgrade, make upgrade-guess
├── template_manifest.txt   # who owns each generated file
├── Makefile, README.md, NOTES.md, UPGRADING.md
```

## Commands

Run at the template root:

```bash
make new python my_match_stats                 # creates ../my_match_stats
make new golang my_pipeline /tmp/my_pipeline   # explicit destination
make new python my_project LANGUAGE_VERSION=3.13   # start on another version
make languages                                 # folders with a layer.env
make check                                     # script syntax + check-manifest
make classify src/main.py                      # owner: template, seed or stamp
make template-version [vX.Y.Z]                 # gig-cfn-templates release _base/ ships
make render-all [REF=v1.0.0] [LINT=1] [BUILD=1]  # render and check every language
make upgrade ../my_project [v1.1.0]            # merge a release into a project, on a branch
make upgrade-guess ../old_project [WRITE=1]    # stamp a project made before stamps
```

Three skills drive these: `cg-aws-template-new`, `cg-aws-template-release`
(check, diff what projects receive, write notes, tag) and
`cg-aws-template-upgrade` (upgrade, resolve conflicts, port seed changes).

A generated project has its own `make help`. The commands you use most:
`make local-dev-setup`, `make lint`, `make local-build`, `make local-run`,
`make deploy-cicd <target>`, `make push`, `make versions`, `make sync-versions`.

## Conventions

- **One source per fact.** Shared files live in `_base/`, language files in
  `<language>/`, Dockerfiles in each language's `targets/`.
- **A language is a folder with a `layer.env`.** It holds the placeholder
  values `bootstrap.sh` substitutes (images, entrypoints, lint command). The
  variables are documented in `make/bootstrap.sh`.
- **Tool versions are written once, in `mise.toml`.** Other files name them as
  `${mise:<tool>}`. `BaseImageURI` resolves when used: by `commands.sh`
  locally, and by `buildspec.yaml` at each pipeline build. Lines that cannot
  read a file sit under a `mise-sync:` comment, which `make sync-versions`
  rewrites. `make lint` fails on drift. mise itself is optional, and
  micromamba installs the toolchain.
- **Placeholders** are `{{UPPER_CASE}}`, filled once by bootstrap.
  `${mise:<tool>}` tokens stay in the project and resolve when used.
- **Ownership** is in `template_manifest.txt`, where the first matching rule
  wins. `template` files take upgrades by 3-way merge. `seed` files belong to
  the project once made. `stamp` is `.template.env`. `make check` fails on any
  generated file no rule covers.
- **Commit before `make new`.** A render from uncommitted changes is stamped
  `TEMPLATE_DIRTY=true` and cannot be repeated for an upgrade.
- **The `gig-cfn-templates` release** is set in each target's
  `deployment_parameters.json` (`TemplateVersion`), never in
  `cicd_parameters.json`.

## Current state

| Language | Default versions (`mise.toml`) | Targets |
|---|---|---|
| python | `python = "3.12"` | lambda, task, server |
| golang | `go = "1.26"` | lambda, task, server |
| typescript | `node = "22"` | lambda, task, server |
| cpp | `debian = "bookworm"` (`[vars]`) | lambda, task, server |
| nextjs | `node = "20"` | task, server |
| elixir | `elixir = "1.19"`, `erlang = "27"` | lambda, task, server |

- `_base/` ships `gig-cfn-templates` `v1.10.16`.
- Releases are tagged; `v1.0.0` is the first, and the baseline for upgrades.
- `make upgrade` merges `template` files 3-way, keeps a version the project
  chose in `mise.toml`, and writes `report.md` and `seed.patch` to the
  project's `.git/template-upgrade/<version>/`. See NOTES.md, **Upgrading a
  project that already exists**.

## Where the details are

Sections of [NOTES.md](NOTES.md):

| Section | Covers |
|---|---|
| How this fits with `gig-cloudformation` | base stacks imported by name, the module library by version, releasing, what breaks across releases |
| Layout | the full tree, tool versions, base images per language, why Dockerfiles live per language |
| Usage | `make new` in detail, pointing a new project at current templates |
| Deploying a generated project: `make` | toolchain, devcontainer, run and debug, deploy, inspect, tear down, run locally, overrides |
| Upgrading a project that already exists | the stamp and the manifest; links to UPGRADING.md |
| Maintenance philosophy | what goes in `_base/` and what goes in a layer |
| Adding a new language | the step-by-step checklist |
| Notes on the originals | which old template each layer came from |
