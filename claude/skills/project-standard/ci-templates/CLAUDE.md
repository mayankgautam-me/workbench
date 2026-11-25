# ci-templates

Reusable GitHub Actions workflows of the project standard, one per part kind, at
`.github/workflows/<kind>.yml`, each with only `on: workflow_call`. Projects call them from their own
`checks.yml` and `release.yml` with `uses: mayankgautam-me/ci-templates/.github/workflows/<kind>.yml@v1.10`.
README.md shows the calls.

## Where to change things

- This repository is published from the project-standard skill: the source is
  `~/.workbench/claude/skills/project-standard/ci-templates/` in the workbench repository. Change the files
  there, never here; a change made only here is lost at the next publish.
- Publishing a version: copy the source over this clone (`rsync -a --delete --exclude .git <source>/ ./`), commit it
  on `main` as "v<version>", tag it `v<version>` (the skill's `templates/project/make/VERSION`, now `v1.10`) and push
  `main` and the tag. A published tag is never moved: projects on an older version (`@v1.9`, `@v1.8`, `@v1.7`, `@v1.6`, `@v1.5`, `@v1.4`, `@v1.3`, `@v1.2`, `@v1.1`, `@v1.0`) keep calling it until
  the skill's update mode moves their `uses:` lines to the new tag (`reference/standard.md` section 10).

## Rules for the workflows

- Every step runs a `make` target, so CI runs what a developer runs locally; no build logic lives in YAML.
- Inputs: `part`, `part_dir` and the kind's own flags. Secrets passed by the caller: `SECRETS_DEPLOY_KEY`,
  `SOPS_AGE_KEY`, for hardware `KICAD_LIBRARY_DEPLOY_KEY` (not used with the input `library: local`), and for altium
  `ALTIUM_LIBRARY_DEPLOY_KEY` (the Altium library submodule).
- Repository variables read (each optional, with a default in the workflow): `SECRETS_REPO`,
  `KICAD_LIBRARY_REPO`, `KICAD_LIB_PREFIX`, `ALTIUM_LIBRARY_REPO`, `STD_APT_PACKAGES`, `STD_IBOM_COMMIT`, `MACOS_CI` (macOS jobs run
  only when it is `true`; app-flutter's `store-ios` is gated by its `store` input instead, 1.10), and `STD_RUNNER`, `STD_RUNNER_LINUX_ARM`, `STD_RUNNER_MACOS`, `STD_RUNNER_WINDOWS`
  (a runner label; without one the job runs on a GitHub-hosted runner).
- Organisation variables do not reach private repositories on GitHub Free, so a project sets these on the
  repository (`make ci-setup` sets `SECRETS_REPO`, `KICAD_LIBRARY_REPO` and `ALTIUM_LIBRARY_REPO`).
- The repository is public: no private project, organisation, host or secret names in any file or comment.

- Actions are `actions/*` pinned by a full commit SHA with a version comment. The one exception is app-flutter
  (1.9): `subosito/flutter-action` and `android-actions/setup-android`, pinned the same way, because no Flutter
  image is published past 3.44. `tests/ci.bats` holds the allowed pins.

## Checking a change

In the workbench: `cd ~/.workbench/claude && bats skills/project-standard/tests/ci.bats` parses every workflow
and checks its jobs, inputs and make calls. `make ci-lint` in a project runs actionlint on its own workflows.
