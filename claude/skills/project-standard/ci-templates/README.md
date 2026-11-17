# ci-templates

The source of the reusable GitHub Actions workflows in `mayankgautam-me/ci-templates`, tagged `v1.6` (`v1.4`, `v1.3`, `v1.2`, `v1.1` and `v1.0` stay,
for the projects not updated yet). Each file here is one part kind, at `.github/workflows/<kind>.yml`, and it has
only `on: workflow_call`. A project's `.github/workflows/checks.yml` (pushes and pull requests) and `release.yml`
(tags) call them with `uses:`. Every script line calls `make`, so CI runs what a developer runs locally. The v8
GitLab templates are gone from this folder; they stay in git history and under the `v8` tag.

## Calling a kind

```yaml
# project's .github/workflows/checks.yml
name: checks
on:
  push:
    branches: [main]
  pull_request:
jobs:
  cloud-api:
    uses: mayankgautam-me/ci-templates/.github/workflows/cloud-worker.yml@v1.6
    with:
      part: cloud-api
      part_dir: cloud/api
      deploy_staging: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}
    secrets:
      SECRETS_DEPLOY_KEY: ${{ secrets.SECRETS_DEPLOY_KEY }}
      SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
```

```yaml
# project's .github/workflows/release.yml: tags <part>-v<version> (make <part>-bump makes them)
on:
  push:
    tags: ['*-v*']
permissions:
  contents: write
jobs:
  tag:   # the part of the tag, see ci_tag_job in scripts/scaffold.sh
  firmware:
    needs: tag
    if: needs.tag.outputs.part == 'firmware'
    uses: mayankgautam-me/ci-templates/.github/workflows/zephyr.yml@v1.6
    with:
      part: firmware
      part_dir: firmware
      run_release: true
    secrets:
      SECRETS_DEPLOY_KEY: ${{ secrets.SECRETS_DEPLOY_KEY }}
      SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
```

```yaml
# project's .github/workflows/production.yml: the only production path, started by hand
on:
  workflow_dispatch:
    inputs:
      confirm:
        description: 'type production to publish'
        required: true
        default: ''
      source_run_id:
        description: 'run that built the artifacts (empty: none)'
        required: false
        default: ''
permissions:
  contents: write
jobs:
  firmware:
    uses: mayankgautam-me/ci-templates/.github/workflows/zephyr.yml@v1.6
    with:
      part: firmware
      part_dir: firmware
      run_check: false
      run_build: false
      confirm: ${{ inputs.confirm }}
      source_run_id: ${{ inputs.source_run_id }}
    secrets:
      SECRETS_DEPLOY_KEY: ${{ secrets.SECRETS_DEPLOY_KEY }}
      SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
```

A project declares one job per part and kind, and sets the `permissions` the release needs (the callee's jobs
ask for `contents: write` and `packages: write`; the caller's `GITHUB_TOKEN` must allow them). The change filter is
not in these files: the project's `checks.yml` decides which parts run, with `paths:` or its own job `if:`.

## Inputs

| Input | Type, default | Meaning |
|---|---|---|
| `part` | string, required | The part's name, the prefix of its make targets (`<part>-check`). |
| `part_dir` | string, required | The part's folder, relative to the repository root. |
| `run_check` | boolean, `true` | Run the check job. |
| `run_build` | boolean, `true` | Run the build job. |
| `run_release` | boolean, `false` | Run the release job(s): `make <part>-github-release`, on a tag. |
| `confirm` | string, `''` | Pass `production` to run the production jobs (`publish`, `deploy-production`). Free private repositories have no environment protection rules, so this input is the gate. A cloud-worker or web-pages part's tag job passes it (`confirm: production`): the tag deploys production, and `deploy-production` runs only on a tag or a manual run, never on a branch push. |
| `source_run_id` | string, `''` | Kinds that publish built images (`NOBUILD=1`) and the firmware kinds: the run that holds the `<part>-build` artifact, when it is not this run. Empty means this run. cloud-worker still accepts it and ignores it. |
| `deploy_staging` | boolean, `false` | cloud-worker, web-pages, docker: deploy to staging. |
| `production_only` | boolean, `false` | cloud-worker, web-pages: the part has no staging, so `deploy-staging` is skipped. Production deploys the same way either way. |
| `target` | string, `''` | app-flutter: the store target (`appbundle` by default, or `ios`). |
| `library` | string, `shared` | hardware: `shared` checks out the KiCad library (`KICAD_LIBRARY_REPO`) for the 3D models; `local` checks out none, for a board whose own `sym-lib-table` and `fp-lib-table` are its library (`<part>_LIBRARY := local`; the scaffold writes `library: local` on its jobs). |

## Secrets

Declared in each file's `secrets:` block and passed explicitly by the caller (no `secrets: inherit`).

| Secret | Used by | Meaning |
|---|---|---|
| `SECRETS_DEPLOY_KEY` | every kind that decrypts | SSH private key of a read-only deploy key on the secrets repo. |
| `SOPS_AGE_KEY` | the jobs that decrypt or sign | The CI age key, for the production and staging jobs only. Dependency installs run with it unset (`env -u SOPS_AGE_KEY make ...`). |
| `KICAD_LIBRARY_DEPLOY_KEY` | hardware | SSH private key of a read-only deploy key on the KiCad library (for the 3D models). Not read with `library: local`. |
| `ALTIUM_LIBRARY_DEPLOY_KEY` | altium | SSH private key of a read-only deploy key on the Altium library, the project's submodule (1.4). |

## Variables

Repository or organization variables (`vars.`), not secrets.

| Variable | Meaning |
|---|---|
| `SECRETS_REPO` | The project's secrets repository, e.g. `<owner>/secrets` (one per owner; `make ci-setup` sets it from the project's `SECRETS_REMOTE`). Checked out sparsely (the project's folder and `recipients`) into `.ci/secrets` inside the workspace; `SECRETS_DIR` points there. |
| `KICAD_LIBRARY_REPO` | The KiCad library, e.g. `<owner>/kicad-library`. Optional; when set, the hardware jobs check it out with LFS and export `KICAD_LIBRARY_DIR` and the `<prefix>_LIB_DIR`, `_3DMODEL_DIR`, `_DATASHEET_DIR` paths. |
| `KICAD_LIB_PREFIX` | Optional, default `FABROLABS`: the prefix of those path variables. |
| `ALTIUM_LIBRARY_REPO` | The Altium library, e.g. `<owner>/altium-library`. Optional; when set, the altium job checks it out at the commit the project's submodule pins (`make <part>-lib-ref`), pulls only its symbols and footprints from LFS (cached per commit) and the check runs the library's check too. |
| `STD_APT_PACKAGES` | Optional: extra Debian packages (space separated) that every apt install adds, e.g. `libudev-dev`. |
| `STD_IBOM_COMMIT` | Optional: InteractiveHtmlBom commit for hardware; default `5c192e794cd66fde04bab11810601b711bf8581b` (v2.12.0). |
| `STD_RUNNER` | Optional: the runner label of every Linux job; default `ubuntu-24.04`. Set it to a self-hosted amd64 Linux runner with Docker to run all CI there. |
| `STD_RUNNER_WINDOWS` | Optional: the runner label of app-tauri's Windows jobs; defaults `windows-2025` and `windows-11-arm`. |
| `STD_RUNNER_LINUX_ARM` | Optional: the runner label of the linux-arm64 release jobs; default `ubuntu-24.04-arm`. |
| `STD_RUNNER_MACOS` | Optional: the runner label of the macOS jobs; default `macos-latest`. |
| `MACOS_CI` | macOS jobs run only when it equals `true`. Unset, every macOS job is skipped (macOS minutes are the most expensive). |

## Who can call it

This repository is public, so a project of any owner (a personal account or an organization) calls it with no
setting; its projects set `CI_TEMPLATES_REPO` to it (the project-standard default). `<owner>` in this README is the calling
project's owner. A private copy of these workflows would need, on that copy, Settings > Actions > General > Access to
allow the callers' repositories. The private `secrets`, `kicad-library` and `altium-library` repositories are read with deploy keys.

## Deploy keys

Create one ed25519 key pair per private repository read by CI, and store the private half as a secret of the
caller project:

```sh
ssh-keygen -t ed25519 -N '' -C ci-secrets -f ./ci-secrets
gh repo deploy-key add ./ci-secrets.pub --repo <owner>/secrets          # read-only: no --allow-write
gh secret set SECRETS_DEPLOY_KEY --repo <owner>/<project> < ./ci-secrets
rm ./ci-secrets ./ci-secrets.pub
```

`SOPS_AGE_KEY` is set the same way (`gh secret set SOPS_AGE_KEY`), by `make secrets-ci` from the project's
standard make targets. Keep the deploy keys read-only.

## Runners

Labels used, all listed for private repositories on the GitHub-hosted runner page
(https://docs.github.com/en/actions/reference/runners/github-hosted-runners):

| Label | Used for |
|---|---|
| `ubuntu-24.04` | most jobs, and the image-based jobs (`container:`) |
| `ubuntu-24.04-arm` | the linux-arm64 release jobs |
| `windows-2025` | Windows x64 release (app-tauri) |
| `windows-11-arm` | Windows arm64 release (app-tauri) |
| `macos-latest` | macOS jobs (app-xcode, app-tauri macOS and iOS), gated by `MACOS_CI` |

The page lists these labels for private repositories but states no plan limit for them. Re-check the arm64 and
Windows arm64 labels on a real run before relying on them; the Windows arm64 image's Visual Studio components are
not verified (the job adds the ARM64 C++ tools when missing, as v8 did).

Billing (https://docs.github.com/en/billing/concepts/product-billing/github-actions): Linux is billed at 1x the
minutes, Windows at 2x, macOS at 10x. The page does not state a separate multiplier for arm64 runners; treat that
as unconfirmed and check the usage report after the first arm64 run.

## Kinds and jobs

| Kind | Jobs | Notes |
|---|---|---|
| `cloud-worker` | check, build, deploy-staging, deploy-production, release | staging on a push to main (`deploy_staging`, not `production_only`); production (`make <part>-deploy ENV=production`) on the tag or a manual run with `confirm`, one at a time per part, token read-only; release after a successful deploy, the CHANGELOG notes only |
| `web-pages` | check, build, deploy-staging, deploy-production, release | as cloud-worker |
| `docker` | check, build, deploy-staging, release | pushes to `ghcr.io/<owner>` with `GITHUB_TOKEN` (`DOCKER_REGISTRY`, the owner in lowercase), labelled `org.opencontainers.image.source` with the repository so the package inherits its access; `packages: write` |
| `go`, `python` | check, build, release | python artifact `<part>-dist` |
| `zephyr`, `espidf`, `pio`, `arm-gcc`, `circuitpython` | check, build, release (NOBUILD=1 from the build artifact), publish (production) | `publish` needs `confirm` and the production key; zephyr also builds a part on upstream Zephyr (`<part>_ZEPHYR`) in the same image |
| `silabs` | check, build, release (NOBUILD=1), publish (production) | on the runner itself, no image: `<part>-setup` installs the pinned slt, slc, the Simplicity SDK and WiseConnect (about 2 GB), kept in the Actions cache per version; a `SIGN=1` build needs Simplicity Commander on the runner |
| `hardware` | check, build, release | KiCad image, library (none with `library: local`) and InteractiveHtmlBom; release publishes the fab files, BOMs, STEP and WRL |
| `altium` | check | Altium runs on Windows only, so CI checks the layout, the documents and the Git LFS pointers (no LFS pull); `run_build` and `run_release` do nothing. The Release is made where the OutJob's outputs are: `make <part>-github-release FORCE=1` |
| `mechanical` | check, build, release | FreeCAD from Ubuntu 24.04 (0.21, not pinned): open and recompute every model, export STEP and STL; release attaches the exports and the models |
| `app-tauri` | check, build, release-linux-amd64, release-linux-arm64, release-windows-x64, release-windows-arm64, release-macos (MACOS_CI), publish-ios (MACOS_CI, production), publish-android (production) | arm64 Windows builds NSIS only (make decides); `.aab`/mapping kept as artifacts for 7 days |
| `app-flutter` | check, build, release-linux-amd64, release-linux-arm64, publish (production) | `publish` takes `target` |
| `app-xcode` | check, build, release-macos, publish (production) | all macOS, all gated by `MACOS_CI` |
| `app-android` | check, build, publish (production) | no release job: the release files are made on the Mac (`make <part>-github-release FORCE=1 PLATFORM=android`), as in v8 |

Images are pinned by tag or digest, as in v8: `node:22.22-bookworm`, `rust:1.99.1-bookworm`,
`ghcr.io/cirruslabs/flutter:3.44.0`, `ghcr.io/cirruslabs/android-sdk:36`, `golang:1.27-bookworm`,
`python:3.13-slim-bookworm`, `python:3.12-slim` (digest), `espressif/idf:v5.5` (digest),
`ghcr.io/nrfconnect/sdk-nrf-toolchain:v3.2.1` (digest), `debian:trixie-20261104-slim` (digest),
`kicad/kicad:10.0.8` (digest). The docker and circuitpython builds use the runner's Docker, not Docker in Docker.

## Release files and production

- `make <part>-github-release` builds or reads the part's files and attaches them to the GitHub Release of the tag
  (`release.sh` uses `gh` with `GH_TOKEN`). The files that are not attached (`*.aab`, `*-mapping.txt`) are kept as
  workflow artifacts for 7 days by the publish jobs of app-flutter, app-tauri and app-android.
- Store, OTA and production jobs need `confirm: production` (a manual run; a cloud-worker or web-pages tag job passes it:
  the tag deploys production, then the notes-only Release). Nothing in these files publishes on a branch push.
- The firmware kinds release and publish the build job's image (`NOBUILD=1`). The build artifact travels between runs
  by name (`<part>-build`), from `source_run_id` when the publish run is not the build run.

## Keys and the CI key

`SOPS_AGE_KEY` is passed to the decrypting jobs only (build of signed firmware, staging and production deploys, the
publish jobs). Free private repositories have no environments, so there is no per-environment key scope: the
project's workflows decide which jobs receive the secret. Keep the production key out of the staging workflow's caller.

## Migration from the v8 GitLab templates

- `base.yml` is gone: its helpers are inlined in each file (GitHub has no include). The mise install keeps its pinned
  version and sha256 checks, and adds the macOS digests from the same release.
- `!reference`, `extends`, `rules`, `when: manual`, `artifacts` and the `CI_*` variables have no direct
  equivalent here: `workflow_call` inputs, `if:`, `confirm`, `upload-artifact`/`download-artifact` and the
  `github` context replace them. There is no cache for the Zephyr NCS sources in v9; the other caches are listed under Caches.
- The Windows jobs clone the secrets repo with actions/checkout and run the make targets directly under Git Bash.
- Projects move from `.gitlab-ci.yml` to the workflows above, and from `glab` to `gh` for the Release and the secrets.

## Not verified yet

- The arm64 Windows and macOS jobs have not run on a real runner; the macOS mise tarball is taken from the v2026.11.3
  release assets and not yet extracted.
- The secrets repo and the KiCad library are checked out under `.ci/`; `download-artifact` with `run-id` across runs,
  the LFS pull of one part and the pinned gh install have not run on GitHub.
- `actionlint` (without shellcheck) passes on these workflows and on the callers of a scaffold with every kind.
- silabs, altium and mechanical (1.1) have not run on GitHub yet.
