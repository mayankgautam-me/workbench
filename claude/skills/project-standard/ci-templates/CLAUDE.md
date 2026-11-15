# ci-templates

Reusable GitHub Actions workflows of the project standard, one per part kind, at
`.github/workflows/<kind>.yml`, each with only `on: workflow_call`. Projects call them from their own
`checks.yml` and `release.yml` with `uses: mayankgautam-me/ci-templates/.github/workflows/<kind>.yml@v1.0`.
README.md shows the calls.

## Where to change things

- This repository is published from the project-standard skill: the source is
  `~/.workbench/claude/skills/project-standard/ci-templates/` in the workbench repository. Change the files
  there, never here; a change made only here is lost at the next publish.
- Publishing: copy the source over this clone (`rsync -a --delete --exclude .git <source>/ ./`), amend the one
  commit, force-push `main`, and move the `v1.0` tag to the new commit (`git tag -f v1.0`,
  `git push -f origin v1.0`). The repository keeps exactly one commit and one tag; projects pin the tag.
- A new major version of the standard gets a new tag (`v2.0`) instead of moving `v1.0`, and the projects' `uses:`
  lines move to it with `make update`-style refreshes.

## Rules for the workflows

- Every step runs a `make` target, so CI runs what a developer runs locally; no build logic lives in YAML.
- Inputs: `part`, `part_dir` and the kind's own flags. Secrets passed by the caller: `SECRETS_DEPLOY_KEY`,
  `SOPS_AGE_KEY`, and for hardware `KICAD_LIBRARY_DEPLOY_KEY`.
- Repository variables read (each optional, with a default in the workflow): `SECRETS_REPO`,
  `KICAD_LIBRARY_REPO`, `KICAD_LIB_PREFIX`, `STD_APT_PACKAGES`, `STD_IBOM_COMMIT`, `MACOS_CI` (macOS jobs run
  only when it is `true`), and `STD_RUNNER`, `STD_RUNNER_LINUX_ARM`, `STD_RUNNER_MACOS`, `STD_RUNNER_WINDOWS`
  (a runner label; without one the job runs on a GitHub-hosted runner).
- Organisation variables do not reach private repositories on GitHub Free, so a project sets these on the
  repository (`make ci-setup` sets `SECRETS_REPO` and `KICAD_LIBRARY_REPO`).
- The repository is public: no private project, organisation, host or secret names in any file or comment.

## Checking a change

In the workbench: `cd ~/.workbench/claude && bats skills/project-standard/tests/ci.bats` parses every workflow
and checks its jobs, inputs and make calls. `make ci-lint` in a project runs actionlint on its own workflows.
