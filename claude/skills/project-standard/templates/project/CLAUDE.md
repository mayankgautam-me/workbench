# @@PROJECT@@

A project-standard project (version in `make/VERSION`). Parts are listed in `make/project.mk`.

## Rules

- Use the `make` commands for every stage of work; do not call wrangler, west, idf.py, pio,
  kicad-cli, flutter, gradle, xcodebuild, docker or sops directly when a `make` target does it.
  `make help` lists them; `make <part>-<verb>` addresses one part.
- Run `make check` before saying a change is done.
- Secrets are never in this repo: no `.env`, `.dev.vars`, key or certificate files. A new secret is a
  line in `secrets.schema`, then `make secrets-set NAME=... ENV=...` (the user types the value).
  Never print a secret value.
- `ENV` is `local` (default), `staging` or `production`. Anything touching production, and any
  destroy, wipe, reset or erase, needs `CONFIRM=<env>` on the command line. Ask the user before
  running such a command; never add `CONFIRM` on your own.
- Files whose first line says `managed` come from the project-standard skill: change them through
  the skill, not by hand. Project-only targets go in `make/local.mk` with a `## ` description.
- Never edit a KiCad board or schematic while KiCad has it open.
- Keep `PLAN.md` up to date as work starts and finishes.

## Documents

`docs/README.md` indexes every document. Keep the docs current in the same change as the work:

- A user-visible change to a part gets a line under `## [Unreleased]` in `<part dir>/CHANGELOG.md`, under
  `### Added`, `### Changed` or `### Fixed`. The release notes come from there.
- A change to a part's interfaces, protocol, API, data, flashing, manufacturing or distribution updates its
  doc in `docs/<part>/` (and `docs/architecture.md` when parts connect differently). A new doc gets a line in
  `docs/README.md`.
- Docs are Markdown; diagrams are Mermaid blocks; images are SVG, or PNG, in `docs/images/` or
  `docs/<part>/images/`.
- Never commit a binary document (PDF, Word, Excel, PowerPoint, OpenDocument): `.gitignore` ignores them. A
  generated PDF, such as a schematic, is attached to a release; a datasheet belongs in the shared library.

## Stages

| Stage | Commands |
|---|---|
| Tools | `make setup`, `make doctor`, `make update` |
| Run locally | `make dev`, `make stop`, `make status`, `make logs`, `make reset CONFIRM=local` |
| Test | `make check`, `make test`, `make test-e2e`, `make test-device`, `make format` |
| Cloudflare auth (one token per project) | `make cf-login`, `make cf-logout`, `make cf-whoami`, `make cf-token-check ENV=` |
| Cloudflare resources | `make cf-provision ENV=`, `cf-status`, `cf-migrate`, `cf-seed`, `cf-secrets`, `cf-backup`, `cf-wipe`, `cf-destroy` |
| Secrets | `make secrets-init`, `secrets-set`, `secrets-edit`, `secrets-list`, `secrets-check`, `secrets-keygen`, `secrets-rotate`, `secrets-ci` |
| Deploy | `make deploy ENV=staging` (CI on a push to main), production from a part's release tag in CI (`make deploy ENV=production CONFIRM=production` for a hotfix by hand), `make smoke ENV=`, `make test-remote ENV=staging`, `make preview`, `make versions`, `make rollback` |
| CI | `make ci-setup` (once, you run it), `make ci-lint`, `make ci-status`, `make ci-logs`, `make ci-run`, `make ci-local JOB=` |
| Firmware | `<part>-build`, `-flash`, `-erase`, `-monitor`, `-debug`, `-size`, `-config`, `-release` |
| Hardware | `<part>-setup`, `-new NAME=`, `-check`, `-build`, `-bom`, `-release` |
| Apps | `<part>-dev`, `-build`, `-logs`, `-release TARGET=` |
| Release | `make version`, `make <part>-bump LEVEL=patch`, `make <part>-release-assets`, `make clean`, `make distclean` |

## Releasing a part

Each part releases on its own, from its tag `<part>-v<version>`:

1. The part's `CHANGELOG.md` has its changes under `## [Unreleased]` (bump refuses an empty one).
2. `make <part>-bump LEVEL=patch` (or `minor`, `major`, `VERSION=x.y.z`) sets the version in the part's own
   version file, moves the Unreleased notes under the new version, commits those two files and makes the tag. It
   pushes nothing.
3. The user pushes with `make release-push`: the branch, then each new release tag in its own push (GitHub starts no
   workflow for the tags of a push that carries more than three). Ask before pushing a tag; never push one on your own.
4. The tag's release workflow creates the GitHub Release `<part> <version>` (release files, notes). The store bundles and mapping files are kept as workflow artifacts.
   Publishing to a device, a store or production stays a manual job in that workflow, with `CONFIRM`.

`make <part>-release-assets` shows locally what the Release will contain, in `<dir>/release/<version>/` (ignored).
