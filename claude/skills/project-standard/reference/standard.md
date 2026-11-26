# The project standard, v1.5

One set of commands for every stage of work, the same in every project: firmware, boards, enclosures,
Cloudflare services, apps and containers alike. The tools stay what they are (west, idf.py, pio, slc,
kicad-cli, freecadcmd, wrangler, flutter, gradle, xcodebuild, docker, go, uv); only the commands in front of
them are the same everywhere.

- `make <verb>` runs a stage for the whole project, `make <part>-<verb>` for one part.
- Everything runs from the project root.
- `make help` lists the commands this project uses, grouped by stage and then by part (`ALL=1`: every one).

## Contents

1. Project shape (and Documents)
2. Parts and kinds
3. Environments and guards
4. The stages and their commands
5. Secrets
6. CI/CD
7. Cloudflare API token permissions
8. First time on a new Mac
9. Per-user configuration

## 1. Project shape

```
<project>/
  Makefile            3 lines: includes make/project.mk and make/common.mk        managed
  make/project.mk     PROJECT, PORT_BASE, PARTS, per-part settings                 yours
  make/common.mk      the stage commands, guards, help, secrets loading            managed
  make/kinds/<k>.mk   one per kind the parts use                                   managed
  make/bin/*.sh       secrets.sh, cf.sh, lib.sh, release.sh, ghcr.sh ...            managed
  make/local.mk       targets only this project needs, with `## ` descriptions      yours
  make/VERSION        the standard version the managed files came from (1)         managed
  Brewfile            system tools (brew bundle)
  mise.toml           node / pnpm / python / go / rust versions
  secrets.schema      the name of every secret, per environment, and who uses it   (no values)
  .github/workflows/  checks.yml and release.yml: call the shared CI templates, one job per part
  .gitattributes      Git LFS for 3D and CAD models only (*.step *.stp, *.fcstd and *.FCStd; *.wrl with a KiCad
                      board), and Altium's binary documents with an altium part (not images, documents or build
                      output); KiCad files stay text, an Altium project and OutJob -text (byte-exact)
  .gitignore          one for the whole project: base lines + each kind's build outputs, a hardware or altium
                      part's <dir>/production/ (altium: <dir>/outputs/ too), SvelteKit / Vite outputs for app-tauri
                      and web-pages, binary documents (*.pdf *.docx *.xlsx *.pptx ...)
  firmware/ hardware/ mechanical/ cloud/ web/ app/   a part's folder: its kind's folder, or <kind folder>/<part>/ (below)
  scripts/
    <part dir>/README.md      purpose, build and run, configuration, interfaces, links to its docs   yours
    <part dir>/CHANGELOG.md   Keep a Changelog; releases are tagged <part>-v<version>               yours
  docs/
    README.md                 index of every doc                                                    yours
    architecture.md           the parts (Mermaid), data flow, where each part runs                  yours
    operations.md             runbook: deploy, rollback, backup, checks (only with a deployable part) yours
    references.md             links to the datasheets and manuals the project works from         yours
    <part>/                   the kind's docs (see Documents below)                                 yours
    images/  <part>/images/   SVG, or PNG
  tests/smoke/        quick checks against a deployed environment  (only with a cloud-worker or web-pages part)
  tests/remote/       the deployed test suite (staging)            (only with a cloud-worker or web-pages part)
  README.md CLAUDE.md PLAN.md
```

Folders are lowercase. Each part lives in the folder of its kind:

| Kinds | Folder |
|---|---|
| zephyr, espidf, pio, arm-gcc, circuitpython, silabs | `firmware/` |
| hardware, altium | `hardware/` (a KiCad board and an Altium board in one project: `hardware/<part>/` each) |
| mechanical | `mechanical/` (FreeCAD models: enclosures, brackets, jigs) |
| cloud-worker, docker, go, python | `cloud/` (a go or python part that runs on a device, such as an agent on a Linux board, goes in `firmware/`) |
| web-pages | `web/` |
| app-flutter, app-tauri, app-xcode, app-android | `app/` |

A project with one part of a kind uses that folder itself (`firmware/`). A project with several gives each its own
subfolder, named for the part. Several firmware parts are each named for the chip they run on, lowercase (`nrf9151`, `stm32f042`,
`esp32s3`), and each README says the chip's role on the board; a project's only firmware part stays `firmware`. `firmware/nrf9151/` and `firmware/stm32f042/` are the parts
`nrf9151` and `stm32f042` (`PARTS := nrf9151:zephyr:firmware/nrf9151 stm32f042:arm-gcc:firmware/stm32f042`), released
as `nrf9151-v<version>` and `stm32f042-v<version>`, with their docs in `docs/nrf9151/` and `docs/stm32f042/`. When a
second part of a kind arrives, the first moves into its own subfolder in the same change (`git mv`, then the paths
that name it).

An altium part's folder has a fixed layout, which `make <part>-check` enforces and `make <part>-layout` prints the
moves to (4.10, Altium):

```
hardware/
  <Board>.PrjPcb  <Board>.SchDoc  <Board>.PcbDoc  <Board>.OutJob     the project, top sheet, layout and output job
  <Board>.PrjPcbVariants                                             the assembly variants, when the board has them
  sheets/NN-Name.SchDoc  sheets/NN-Name.Harness                      the other sheets, numbered in order
  library/<Board>.SchLib  library/<Board>.PcbLib  library/models/*.step   the board's own library and 3D models
  VERSION  README.md  CHANGELOG.md
  outputs/  production/                                              generated (OutJob, make <part>-build), ignored
```

The BOM is the one the OutJob writes, `outputs/**/*BOM*.csv` (and its `.xlsx` when it writes one), never a committed
copy (1.5): `make <part>-build` requires the CSV, the Release attaches both, and `make <part>-bom` hands the CSV to the
`bom` skill. A `bom/` folder left from 1.4 is a warning (check, doctor, audit) to remove it.

"Managed" files start with the line
`# project-standard v1.5 (managed: ...)` and are refreshed by the skill's update mode; never edit
them in a project. Your own targets go in `make/local.mk`, written like this, and show under
"project" in `make help`:

```make
.PHONY: render-case
render-case: ## Render the enclosure for the README
	@./scripts/render-case.sh
```

There is no `.env.example`: `secrets.schema` replaces it.

### Documents

Docs are Markdown in git; diagrams are Mermaid blocks inside them (GitHub renders them); images are SVG, or PNG
in `docs/images/` or `docs/<part>/images/`. **Binary documents are never committed**: `.gitignore`
ignores `*.pdf *.doc *.docx *.xls *.xlsx *.ppt *.pptx *.odt *.ods *.odp`, and no LFS line routes them. A generated
PDF, such as a schematic, is a release asset; a datasheet belongs in the shared library, not in a project.

The scaffold writes every doc below once, with its headings and a one-line italic hint per section, and never
overwrites one that exists: a later `scaffold.sh --force` adds only the missing ones (in a part folder that
exists too, without its starter code). `CLAUDE.md` tells Claude to keep them current: a CHANGELOG entry under
`## [Unreleased]` for each user-visible change, `docs/<part>/` updated when an interface, the protocol or the data
changes.

| Doc | What it holds | When |
|---|---|---|
| `docs/README.md` | Index of every doc, project and per part | always |
| `docs/architecture.md` | The parts as a Mermaid diagram (a node per part; the links are drawn by hand), data flow, where each part runs, external services | always |
| `docs/operations.md` | Runbook: environments, deploy, rollback, backup and restore, checks, incidents | with a cloud-worker, web-pages or docker part |
| `docs/references.md` | Links to the reference documents (datasheets, reference manuals, application notes, drawings), one line per document, `- [Title (MPN) — Vendor](URL)`, grouped under `##` headings (datasheets by category, then per vendor or module). Links only: nothing is downloaded or committed (since 1.2; the audit warns about a 1.1 table with `File` or `SHA256` columns) | always (since 1.1) |
| `<part dir>/README.md` | Purpose, Build and run (the kind's make commands), Configuration (`make/project.mk` settings), Interfaces, Docs (links) | every part |
| `<part dir>/CHANGELOG.md` | [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/): `## [Unreleased]` with `### Added`, `### Changed`, `### Fixed`; a release becomes `## [<version>] - YYYY-MM-DD`, tagged `<part>-v<version>` | every part |

Per kind, in `docs/<part>/`:

| Kind | Docs |
|---|---|
| zephyr, espidf, pio, arm-gcc, circuitpython | `protocol.md` (transports, commands, messages, versioning, errors); `flashing.md` (images, bootloader, updating, recovery, factory programming, board revisions) |
| silabs | `protocol.md` and `flashing.md` as above; `power.md` (power modes, measurements, budget, battery life, how to measure with `make <part>-power`) |
| hardware, altium | `bringup.md` (before power, first power, programming, functional tests, results, known issues); `manufacturing.md` (fabrication, stackup, design rules, assembly, suppliers, revisions) |
| altium (also) | `library.md` (the shared Altium library: its submodule, what is in it, adding a part, the check; 1.4) |
| mechanical | `assembly.md` (parts, fasteners and bought parts, assembly order, printing and machining, revisions) |
| cloud-worker | `api.md` (base URLs, authentication, endpoints, errors, limits); `data.md` (D1 tables, KV keys, R2 layout, queues, migrations, backup) |
| web-pages | none beyond the README |
| app-flutter, app-tauri, app-xcode, app-android | `distribution.md` (identifiers, signing, channels, permissions, updates) |
| docker, go, python | `usage.md` (running, commands or endpoints, configuration, environment, logs and health) |

In `PLAN.md` each part's component claims `<dir>/**` and `docs/<part>/**`; the root component claims
`docs/*.md` and `docs/images/**`. The audit warns (area `docs`) for each missing doc of the set and for each
committed binary document (fix: `git rm --cached`, it stays in history; attach it to a release).

## 2. Parts and kinds

`make/project.mk` lists the parts as `name:kind[:dir]` (dir defaults to name):

```make
PROJECT   := demo
PORT_BASE := 8100
PARTS := \
  firmware:zephyr \
  hardware:hardware \
  cloud-api:cloud-worker:cloud/api \
  cloud-web:web-pages:cloud/web
firmware_BOARD := nrf9151dk/nrf9151/ns
```

| Kind | For | Tools behind it |
|---|---|---|
| `zephyr` | Zephyr / nRF Connect SDK firmware | west, sysbuild, MCUboot, nrfutil / J-Link / probe-rs |
| `espidf` | ESP32 firmware | idf.py, esptool, espsecure |
| `pio` | PlatformIO firmware | pio |
| `arm-gcc` | bare-metal Cortex-M (libopencm3, CubeMX export) | arm-none-eabi-gcc, openocd, st-link, dfu-util |
| `circuitpython` | CircuitPython boards | circup, the CIRCUITPY drive |
| `silabs` | Silicon Labs firmware: slc projects (`*.slcp`) on the Simplicity SDK and WiseConnect, SiWx917 / SiWG917 M4 | slt, slc, the GNU Arm toolchain slt installs, Simplicity Commander, J-Link |
| `hardware` | KiCad 10 boards | kicad-cli, the `bom` and `jlcpcb` skills |
| `altium` | Altium Designer boards (Altium runs on Windows; nothing here runs it) | the board's OutJob, Git LFS, gerbv (optional) |
| `mechanical` | FreeCAD models (`*.FCStd`, in Git LFS) | freecadcmd (headless FreeCAD) |
| `cloud-worker` | Cloudflare Worker with D1, KV, R2, Queues, DO | wrangler (pinned in the part's package.json) |
| `web-pages` | static site, Astro site (`astro.config.*`), Vite app or Next static export on a static-assets Worker on its custom domain, its only address (the default since v34: `scaffold.sh --domain <part>=<host>`); on Cloudflare Pages only when asked for (`--pages <part>`, a `wrangler.jsonc` with `pages_build_output_dir`: Pages always keeps `*.pages.dev`) | wrangler pages, wrangler deploy |
| `app-flutter` / `app-tauri` / `app-xcode` / `app-android` | apps | flutter / tauri + cargo / xcodebuild / gradle |
| `docker` | container images and compose services | docker buildx, compose |
| `go` | Go services | go, golangci-lint |
| `python` | Python packages and services | uv, ruff, pytest |

Per-part settings are `<part>_<VAR> := value` in `project.mk` (each kind file documents its own:
`_BOARD`, `_NCS`, `_ZEPHYR`, `_TARGET`, `_IDF`, `_SDK`, `_WISECONNECT`, `_LIBRARY`, `_FLUTTER_VERSION`, `_PORT_OFFSET`, `_URL_<env>`,
`_SCHEME`, `_IMAGE`, ...). A value on the command line wins.

Firmware SDKs are pinned per part and installed once per machine into `~/.toolchains/<tool>-<version>`
(`ncs-v3.2.1`, `zephyr-v4.3.0`, `zephyr-sdk-0.17.4`, `idf-v5.5`, `slt-1.1.1`), so two projects on different versions
live side by side. slt keeps the Simplicity SDK and WiseConnect it installs in its own folder (`~/.silabs/slt`). Dev ports are `PORT_BASE` + the part's offset, so two projects can run `make dev` at once.

## 3. Environments and guards

| Variable | Values | Meaning |
|---|---|---|
| `ENV` | `local` (default), `staging`, `production` | which environment a command works on; anything else is an error |
| `CONFIRM` | the env's name, `erase`, `fuse`, `teardown` or `prune` | required, on the command line: the env's name for anything touching `production` (app releases included) and for every destroy, wipe, reset; `CONFIRM=erase` for erase / recover; `CONFIRM=fuse` for eFuse burns; `CONFIRM=teardown` and `CONFIRM=prune` for removing the shared installs (4.1) |
| `PART` | a part name | restrict a root verb to one part (`make deploy ENV=staging PART=cloud-api`) |
| `NO_COLOR` | set | plain output |

`CONFIRM` only counts when it is typed on the command line; one exported in the shell, set in a
file or smuggled in through `MAKEFLAGS` in the environment does not (make reads the argv of its own
process to tell, and stops with an error). `make -i` / `--ignore-errors` is refused outright, because
it would let a failed guard line carry on to the next one; for the same reason every guard shares its
shell line with the action it protects (`guard && action`), in this standard's files and in
`make/local.mk`. Every target that touches production has one: deploy, promote, rollback, preview,
test-remote, `cf-login`, `cf-logout`, `cf-migrate`, `cf-provision`, `cf-secrets` (also with `ROTATE=`),
`cf-seed`, and `secrets-set`, `-rotate`, `-edit`, `-import` with `ENV=production`.
`make cf-destroy ENV=production CONFIRM=production` additionally asks you to type
the project name on the terminal (`/dev/tty` only; nothing in the environment can answer for you),
and CI cannot destroy production at all. Firmware verbs at the root (`make flash`,
`make monitor`) run only when exactly one part has them; otherwise they list the part targets.

## 4. The stages and their commands

### 4.1 Tools and development environment

| Command | Does |
|---|---|
| `make setup` | `brew bundle`, `mise install`, the pinned SDKs into `~/.toolchains`, each part's dependencies (pnpm, pub, gradle, west update, pio pkg, uv), git hooks, git-lfs. Writes the project's usage record and the installed ledger (below). Safe to re-run; it also puts back whatever `make teardown` removed. |
| `make doctor` | Read-only check of all of the above, plus the Cloudflare token, secrets completeness, KiCad library variables, probes and serial ports, the Docker daemon. Prints what is wrong and the command that fixes it. |
| `make update` | Bumps pinned versions on purpose (NCS, IDF, Node...), then runs `setup`. |
| `make teardown` | The opposite of `setup` for this project. Without `CONFIRM` it only lists what it would remove, with sizes and a total. With `CONFIRM=teardown` it removes the project's build and dependency folders (what each part's `distclean` removes, `clean` for a kind without one), the project's usage record, and the shared installs no other standard project records. Homebrew packages are never removed; it lists the Brewfile's so you can decide. |
| `make prune` | Machine wide, from any standard project. Without `CONFIRM` it only lists; with `CONFIRM=prune` it removes every shared tool version, SDK or rustup target the standard installed and no current project records, the stale usage records, and trims the pnpm store. |

#### Setup on demand

A part's commands set the part up first when it is not ready, so a fresh clone needs no `make setup` before its first
`make cloud-logs ENV=production` or `make firmware-check`: the command prints
`> cloud: not set up yet, running make cloud-setup first`, runs that part's own `setup`, then does its work. The check
costs milliseconds (files and their times; no network, no package manager), so a ready part goes straight on. What
"ready" means per kind (the kind's `<kind>_ready` helper, `std_ready` in `common.mk`):

| Kind | Ready when | Commands that set up first |
|---|---|---|
| cloud-worker, web-pages, app-tauri | `node_modules` was installed after the last change to `package.json` and its lockfile (setup's `node_modules/.std-setup`, or npm's or pnpm's own stamp); no `package.json`: always | the ones that run the part's packages: dev, check, test, format, build, deploy, smoke, preview, promote, versions, rollback, logs, status, the cloud-worker extras and the root `cf-*` commands that run wrangler |
| app-flutter | `.dart_tool` fetched after the last change to `pubspec.yaml` / `pubspec.lock`; the pods installed where a Podfile and `pod` exist | dev, check, test, build, release, release-assets (not with `NOBUILD=1`) |
| zephyr | the NCS (or upstream Zephyr) workspace of the pinned version is updated (`.std-updated`) and its toolchain is there: the image's (`<part>_TOOLCHAIN_ENV`), or the venv's west with the requirements and the pinned Zephyr SDK | check, build, flash, debug, size, config |
| silabs | setup's stamp: slt, slc and the pinned Simplicity SDK and WiseConnect are installed and trusted | check, build, flash, debug, size |
| espidf | the pinned ESP-IDF and its tools for `TARGETS` are installed (in CI: an image's `IDF_PATH`) | check, build, flash, erase, monitor, debug, size, config, the fuse commands |
| pio | `.pio/.std-setup` is newer than `platformio.ini` | check, test, build, flash, erase, monitor, debug, size, config |
| circuitpython | the build image exists | build |
| docker | the `project-standard` buildx builder exists | build, release |
| arm-gcc, go, python, app-android, app-xcode | always: their setup only checks a tool, or the tool fetches what it needs itself (go, uv run, gradle, xcodebuild) | none |
| hardware | never chained: its setup writes KiCad's global settings and only with `APPLY=1` | none |
| altium, mechanical | always: nothing to install per project (Altium is on Windows; freecadcmd comes from the Brewfile) | none |

Never chained: `setup` itself, `doctor`, `clean`, `distclean`, `version`, `bump`, and nothing that needs you (secrets,
`cf-login`, Touch ID, `CONFIRM`, a probe): only the part's own `setup` runs. The root commands (`make check`, `make build`
...) chain through the part targets they fan out to. CI runs `<part>-setup` first, so the check passes there and nothing
more runs. A refused command (no `CONFIRM`) may still have set the part up first; setting up changes nothing remote.

#### Parts not started yet

A part declared in `make/project.mk` whose folder does not have the file its kind builds from yet is *not started*
(`<part>_START`, set by the kind; a project may override it in `make/project.mk`; `std_started` in `common.mk`):

| Kind | Started when the part folder has |
|---|---|
| hardware | a `*.kicad_pro` (`make <part>-new NAME=...` makes one) |
| zephyr, espidf | `CMakeLists.txt` |
| pio | `platformio.ini` |
| arm-gcc | `CMakeLists.txt` or `Makefile` |
| circuitpython | `src` |
| silabs | a `*.slcp` |
| altium | a `*.PrjPcb` |
| mechanical | a `*.FCStd` (in the folder or one level down) |

Until then its `setup`, `check`, `test` and `build` (hardware: `check` and `build`; its `setup` only configures KiCad and still runs) print `> <part>: not started yet (no <file> in <dir>): check
skipped` (the verb they are) and exit 0, and run no tool and no setup on demand, so CI (and the root `make check`)
passes on a project whose parts are declared before they are written. `doctor` reports it as a warning, not a
problem. `flash`, `release`, `release-assets` and `github-release` still refuse (`error <part>: not started yet (no
<file> in <dir>): nothing to release`, non-zero). The CI templates keep the build outputs with
`if-no-files-found: ignore`, so the skipped build uploads nothing and passes. The other kinds have no `<part>_START`
and are always started.

#### Teardown and prune: records, ledger and safety (since v17)

Both commands are destructive, so they list first. Removing needs `CONFIRM=teardown` or `CONFIRM=prune` on the command line
(section 3); a wrong value, one from the environment or several words are refused and nothing is removed.

Two files in `${XDG_STATE_HOME:-~/.local/state}/project-standard/` (machine wide, outside every project) drive them:

- `uses/<PROJECT>-<hash>`: the project's **usage record**. The hash is the first 12 hex digits of the SHA-256 of the
  project root's physical path, so two projects with one name, or a copy moved elsewhere, never share a record. Lines:
  `path <absolute root>`, `project <name>`, `mise <tool>@<version>` for each tool of the project's own `mise.toml` that is
  installed, `sdk <absolute physical folder>` for each folder directly under `STD_TOOLCHAINS` the project uses
  (`ncs-<ver>`, `zephyr-sdk-<ver>`, `esp-idf-<ver>`, `esp-idf-tools`), `rustup <toolchain> <target>` for each target an
  app-tauri release added or found on the active toolchain. The record never shrinks while a setup runs: a full `make setup`
  records what it intends to use before it installs (the project's installed tools, each SDK folder before it is made) and
  builds the new record beside the old one (`<record>.next`); the last line of `setup` swaps it in, which a failed or
  interrupted setup never reaches. So a half-done setup, or another project's teardown or prune running meanwhile, can never
  see the project's items gone. A setup of one part (`PART=`) only adds.
- `installed`: the **ledger**, every item (same `mise|sdk|rustup ...` lines) the standard itself installed: a mise version
  that `mise install` added and the project's own `mise.toml` asks for (a global tool, or a version some other install put
  there meanwhile, is not claimed), an SDK folder `setup` created, a rustup target that was missing. The ledger and the
  records keep the physical absolute path of an SDK and the toolchain of a rustup target, so a later `STD_TOOLCHAINS` or
  default toolchain changes nothing. Only ledger items are ever removed, so a tool you installed yourself, and any SDK or
  version the standard found already there, is never touched. When the list from before the install cannot be read, nothing
  is claimed. Lines from before v17 (a bare SDK name, a rustup target without a toolchain) are not valid any more: they are
  reported and never removed.

A record is **stale** when its project folder is gone but its parent folder is there: it counts for nothing, and `make prune`
lists it and, with `CONFIRM=prune`, removes it. It is **unreachable** when the parent is missing too, or the path is under
`/Volumes` of a drive that is not mounted: it is kept, listed, and its items stay protected.

An item is removed only when it is a valid line, is in the ledger, and no other record (a stale one aside) names it.
Lines are read with CR and surrounding blanks stripped; a ledger line that is not valid is never removed, and a record line
that is not valid protects whatever it plausibly names (any word of it found in the item); both are listed as ignored lines.
Valid is: `mise tool@version`; `sdk` an absolute path of plain characters whose folder is not `/`, `$HOME` or a parent of
`$HOME`; `rustup <toolchain> <target>`. Removal: `mise uninstall <tool>@<version>` (never a version the global mise config
uses, and none when that config cannot be read); `rm -rf` of exactly the recorded folder, only when it is a plain folder
(not a link) whose physical path is the recorded one; `rustup target remove --toolchain <toolchain> <target>`. Each removal
drops the ledger line. The host target and toolchains are never removed. The ledger protects what you installed, not
projects that are not on the standard: **a project without a record that relies on a tool version or SDK the standard
installed can lose it** when the last standard project stops needing it. Both commands print a line saying so under the
list: read the list before you add `CONFIRM`. `esp-idf-tools` is shared by every ESP-IDF version, and stays while any
project records it.

`make prune` also trims caches: `pnpm store prune` (only packages no project references); `cargo cache --autoclean`
(extracted sources and git checkouts; the downloaded crates stay) when `cargo-cache` is installed, otherwise it says it
skipped; Docker is skipped, because a part's images go with its own `distclean` and the standard's other images cannot be
told apart from yours. After a teardown, `make setup` (or `make doctor`, which says what is missing) brings back what the
project needs; a prune is undone the same way, by the next `setup` of the project that needs the item.

### 4.2 Running locally

| Command | Does |
|---|---|
| `make dev` | Starts the local stack: compose services, `wrangler dev` with local D1 / KV / R2 and migrations applied, frontends, the app on a simulator when asked. `make <part>-dev` starts one part. |
| `make stop` | Stops what `dev` started, including processes still holding the project's ports. |
| `make status` | What runs, on which port, and the state of the local data. |
| `make logs` | Follows the logs of the running parts. |
| `make reset CONFIRM=local` | Wipes local state (`.wrangler/state`, compose volumes), then re-migrates and re-seeds. |

`wrangler dev` gets its secrets from the process environment (`CLOUDFLARE_INCLUDE_PROCESS_ENV=true`
under `secrets.sh exec --env local`). There is no `.dev.vars` file, generated or otherwise.

### 4.3 Testing

| Command | Does |
|---|---|
| `make check` | The gate before every commit and in CI: format check, lint, typecheck and unit tests across all parts (TS: biome or eslint, tsc, vitest; Go: gofmt, go vet, `go test -race`; Python: ruff, pytest; Flutter: dart format / analyze / test; Rust: clippy, cargo test; Swift: xcodebuild test; Android: gradle lint and test; firmware: build with `-Werror` and host or `native_sim` tests; KiCad: ERC and DRC; shell: shellcheck). |
| `make test` | Unit tests only; `TEST=<pattern>` runs one. |
| `make test-e2e` | Playwright or integration tests against `make dev`. |
| `make test-device` | Optional: flashes the connected board and asserts on its serial output. |
| `make format` | Rewrites formatting. |

### 4.4 Cloudflare account and token

One API token per project, for all its environments, stored in the secrets repo: the same value in
`staging.env.sops` and `production.env.sops` (never in `common`, which the developer keys open). wrangler
reads `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from the environment `make` gives it, so a staging
command gets the staging copy and a production command the production copy; never run `wrangler login`.

| Command | Does |
|---|---|
| `make cf-login` | Opens the dashboard's token form pre-filled with the project name and the permissions its `wrangler.jsonc` files need (section 7), asks for the token (hidden), verifies it and the account, stores the token for staging and for production and the account id in `common`, then checks the permissions. No `ENV` needed; `ENV=staging` does the same, and `ENV=production` needs `CONFIRM=production` like every production command. |
| `make cf-logout` | Removes the token from staging and production and prints the dashboard link to revoke it. |
| `make cf-whoami` | The account, and the token's status and expiry. Reads both copies (one unlock each) and says, with exit 1, when they differ or only one is stored, as after a `cf-login` that stopped half way. |
| `make cf-token-check ENV=` | Verifies the project's one token and probes every API its cloud-worker and web-pages parts and its OTA bucket need, the same list `cf-login` asks for (section 7: Workers, D1, KV, R2, Queues, Pages); without `ENV`, the production copy. A project with no Cloudflare part and no `OTA_BUCKET` says so. On a Mac it also fails when the other environment's copy differs or is missing. |

### 4.5 Cloudflare resources

The bindings under each environment of a part's `wrangler.jsonc` (`env.local`, `env.staging`,
`env.production`) are the single source of truth. Only `wrangler.jsonc` (or `wrangler.json`) is read;
a `wrangler.toml` must be converted first.

A part whose `wrangler.jsonc` has no `env.staging` is **production-only**: `make <part>-deploy ENV=production
CONFIRM=production` deploys it directly (check, build, migrate, deploy, smoke), every `ENV=staging` command of it is
refused before anything is unlocked (wrangler would otherwise deploy the top-level config as a new
`<name>-staging` Worker), and `promote` stays for parts that have staging. In CI a push to main deploys nothing for
it and its tag deploys production, like any cloud part (section 6). Adding `env.staging` later makes it a normal part;
change its CI job too (`production_only: false`).

What the `cf-*` commands manage: D1 databases, KV namespaces, R2 buckets and Queues, with the queues that
consumers read and their dead-letter queues (`queues.consumers[].dead_letter_queue`) counted as declared. Every
other binding (Durable Objects, `send_email`, Workers AI, `unsafe` rate limits, Workflows, Containers, service
bindings, Access) is passed to wrangler on deploy as it is written, and is not provisioned, checked or backed up.

| Command | Does |
|---|---|
| `make cf-provision ENV=` | Creates what is missing (D1, KV, R2, Queues including dead-letter queues; a Pages project with `make <part>-provision`) and writes the ids back into `wrangler.jsonc`, keeping its comments. D1, R2 and Queues are found by their exact name, and a KV binding that already has an id keeps it. Then, once for the project (not with `PART=` of a cloud-worker part), the OTA bucket: every bucket `OTA_BUCKET` and the `<part>_OTA_BUCKET`s in `make/project.mk` name (each once) is created when missing (`> R2 OTA bucket <b> exists` / `ok created R2 OTA bucket <b>`), so a project whose only Cloudflare resource is that bucket (firmware, hardware and app parts) is provisioned too; one bucket serves every env (objects go under `<project>/<part>/<env>/`), so `ENV=staging` or `ENV=production` both make it, and `ENV=local` creates nothing. `OTA_PUBLIC := r2dev` turns the bucket's public r2.dev URL on and prints it; without it the bucket stays private and one line says how to make it public (section 9). Safe to re-run. |
| `make cf-status ENV=` | Declared against existing; flags missing or extra. The OTA bucket gets a row too (`r2 (OTA) <bucket>`: missing, or ok with its r2.dev URL on or off). |
| `make cf-migrate ENV=` | D1 migrations (`--local` for local, `--remote` otherwise). |
| `make cf-seed ENV=` | Loads `<part>/seed/*.sql` into local or staging. Refuses production. |
| `make cf-secrets ENV=` | Pushes every secret `secrets.schema` marks `cf` with `wrangler secret bulk` from stdin, never a file. `ROTATE=NAME` makes a new value first. |
| `make cf-backup ENV=` | D1 export, every KV key with its value, and the R2 bucket info (not its objects) into `~/Backups/<project>/<env>-<date>.tar.age`, encrypted to the Secure Enclave keys and the recovery key (never the developer keys). Only D1 and KV data are in it: **Durable Object storage is not backed up** (the backup says so when the env binds Durable Objects), nor are R2 objects or queue messages. |
| `make cf-wipe ENV= CONFIRM=` | Backup, then delete the data and keep the resources. |
| `make cf-destroy ENV= CONFIRM=` | Backup, then delete the worker and resources of that env (dead-letter queues included). Deleting the Worker also deletes its Durable Object storage, which is not in the backup. Production also asks for the project name. Wipe and destroy refuse D1, R2 and queue names that do not start with `<project>-<env>` and a Worker name that does not end with `-<env>`; an adopted project with older names keeps those two commands refused, on purpose. Neither ever deletes or empties the OTA bucket: it is shared by every env, and they act on the Worker's bindings only (delete it in the dashboard if you mean to). |

`cf-wipe` and `cf-destroy` refuse while the backup cannot hold something that is declared: wrangler
cannot list or download R2 objects, so with an R2 bucket in `env.<env>` they stop until you have copied
the objects yourself and add `R2_UNBACKED=1` to the command line (an environment variable does not
count). They also refuse unless every D1 database, R2 bucket and Queue name in `env.<env>` starts with
`<project>-<env>` and a Worker `name` set in `env.<env>` ends with `-<env>` or starts with
`<project>-<env>`: the naming rule that keeps a wrong `ENV=` or a copied config away from another
environment's data (`make scaffold` writes a starter `wrangler.jsonc` that follows it).

Names, per environment (`local`, `staging`, `production`):

| Resource | Name | Example |
|---|---|---|
| Worker | `<project>-<env>-<part>` | `cryptoguard-production-cloud` |
| D1, R2, Queue | `<project>-<env>-<name>` | `cryptoguard-production-db`, `cryptoguard-production-firmware`, `cryptoguard-production-webhooks` |
| Dead-letter queue | the queue's name and `-dlq` | `cryptoguard-production-webhooks-dlq` |
| KV namespace | `<project>-<env>-<binding>` (the title `cf-provision` gives it) | `cryptoguard-production-sessions` |

Everything starts with `<project>-<env>`, the Worker too. Workers scaffolded before this rule are named
`<project>-<part>-<env>` (ending with `-<env>`), which wipe and destroy still accept; renaming a deployed Worker
means a new Worker, so they keep their names.

#### Cloudflare Access for a part (1.7)

`make <part>-access ENV=staging|production` puts a cloud-worker or web-pages part behind Cloudflare Access, from its
settings in `make/project.mk`, and is safe to run again: it finds each piece by name and makes only what is missing.

| Setting | Default | Meaning |
|---|---|---|
| `<part>_ACCESS_HOST` | the custom domain of `env.<ENV>` in the part's `wrangler.jsonc` (its route with `"custom_domain": true`; an error when there is none or several) | the host Access guards; `<part>_ACCESS_HOST_<env>` sets it for one env |
| `<part>_ACCESS_PATH` | empty: the whole host | a path under it, `/admin` |
| `<part>_ACCESS_EMAIL_DOMAINS` | empty | who may sign in: email domains, space-separated (`fabrolabs.com`) |
| `<part>_ACCESS_EMAILS` | empty | and single addresses, space-separated |
| `<part>_ACCESS_SESSION` | `24h` | the application's session duration |

It needs `CF_TOKEN_PERMS := access` in `make/project.mk` (the token's Access permissions, section 7) and the two
`secrets.schema` rows `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` for the env; without either it says the fix
and stops before any unlock (`make cf-login` again after adding `access`; `scaffold.sh --force` appends the rows to a
project whose `make/project.mk` has Access settings). It runs under `secrets.sh exec --env <ENV>` like every `cf-*`
command (one unlock), and production needs `CONFIRM=production`. What it finds or makes, named `<project>-<env>-<part>`:

| Piece | Name | Made with |
|---|---|---|
| the team | the account's Zero Trust organization (none: it stops and says to set Zero Trust up once in the dashboard) | `GET /accounts/<id>/access/organizations` (`auth_domain`) |
| service token | the one whose client id is `CF_ACCESS_CLIENT_ID` in the env's secrets, else `<name>`, else a new `<name>` (no expiry) | `/access/service_tokens`, `.../<id>/rotate` |
| Allow policy | `<name>-allow`, reusable: one `email_domain` rule per domain and one `email` rule per address, set to exactly the settings on every run (an address taken out is removed); none when both settings are empty (only the service token passes) | `/access/policies` |
| Service Auth policy | `<name>-service`, reusable: the service token | `/access/policies` |
| application | `<name>`, self-hosted on `host[/path]`, the two policies attached, the session duration; an existing self-hosted application on that domain under another name is used as it is | `/access/apps` |

A new token's client id and secret go straight into the env's secrets (`secrets.sh set`, the value on stdin); the
secret is never printed or logged, and Cloudflare shows it only once. A token that exists while its secret is not in the
secrets stops the command: `ROTATE=1` gives it a new secret (the old one stops working at once) and stores it. Then
the application's aud and the team domain go into `env.<ENV>.vars` of the part's `wrangler.jsonc` as `ACCESS_AUD` and
`ACCESS_TEAM_DOMAIN` (`<team>.cloudflareaccess.com`), for the Worker to check the `Cf-Access-Jwt-Assertion` it gets:
a textual edit that keeps comments, replacing the values that are there and adding the keys inside `vars` (or a `vars`
object at the start of the env block); when the file's shape does not allow it, it prints the lines to add and exits 1.
Deploy afterwards so the Worker has them. A Pages site has no Worker vars: that step is skipped. `DRY=1` reads
everything and prints the plan (`would create ...`) without changing anything, and needs no `CONFIRM`. Each line says
what it found, created or updated.

`make <part>-access-check ENV=` is read only: a GET of the part's health path (`<part>_URL_<ENV>` and `<part>_HEALTH`,
else `https://<host><path>/`) without the service token must be stopped by Access (a redirect to
`*.cloudflareaccess.com`, or 401 or 403), and the same GET with the token, sent as the smoke sends it, must get through.
One `ok` or `fail` line each. `make doctor` checks, for every part with Access settings, `CF_TOKEN_PERMS` and the two
`secrets.schema` rows.

### 4.6 Secrets

| Command | Does |
|---|---|
| `make secrets-init` | Creates `<project>/` in the project's secrets repo (5.1; `~/.secrets` for the default owner, `~/.secrets-<owner>` for another) from `secrets.schema` and asks for each missing value; `GEN=1` generates those the schema allows. Clones the repo when it is not here, and starts it when its remote is empty (5.2). |
| `make secrets-set NAME= ENV=` | Hidden prompt (or stdin when not a terminal), `sops set`, commit and push of the secrets repo. |
| `make secrets-edit ENV=` | `sops edit` for `ENV=local` and `ENV=common` only, commit and push. sops writes the plain text to a temp file and editors keep more copies (swap, undo, backup, viminfo), so vim and neovim are started with `-n -i NONE` and swap/undo/backup switched off, in a private temp folder that is removed afterwards; any other editor is used as it is, with a warning. Staging and production refuse: use `secrets-set` or `secrets-import`. |
| `make secrets-list` | Names, envs and users from the schema and which are present; never values. |
| `make secrets-check` | Missing names (a row whose description starts with `optional:` is a warning, not a problem), wrong recipients, and secret files tracked in the project repo (patterns + gitleaks; a gitleaks finding in a file git ignores, such as `.next/` or `node_modules/`, does not count). |
| `make secrets-keygen NAME= TYPE=` | A signing key generated straight into `keys/<name>.sops` (`ed25519`, `ecdsa-p256`, `rsa-3072`, `mcuboot-ecdsa-p256`, `espsecure-v2`); never overwrites. |
| `make secrets-rotate NAME= ENV=` | New value (generated or asked), set, then a hint to run `cf-secrets`. |
| `make secrets-ci` | Creates the project's CI age key and stores it as the GitHub Actions secret `SOPS_AGE_KEY` of the project repository (section 5). |
| `make secrets-enroll` | New Mac: clones the secrets repo, creates this Mac's keys, publishes their public halves. |
| `make secrets-recovery` | Creates the offline recovery key, once: its private half is shown on the terminal only and never stored; write it down. `FORCE=1` replaces it. |
| `make secrets-add-machine HOST=` | On an enrolled Mac: re-encrypts everything to the new Mac. |
| `make secrets-remove-machine HOST=` | Removes a lost Mac and lists the values to rotate. |

### 4.7 Deployment and deployment testing

| Command | Does |
|---|---|
| `make deploy ENV=staging` | `check` and `build` of the parts that deploy (cloud-worker, web-pages, docker; not firmware, apps or boards, 1.10), `cf-migrate`, deploy (Worker, Pages or container), then `smoke`. Stops at the first failure. |
| `make smoke ENV=` | The health endpoint and `tests/smoke` against the deployed URLs. |
| `make test-remote ENV=staging` | The full suite in `tests/remote` against staging; production only with `CONFIRM`. |
| `make preview` | `wrangler versions upload`, prints the preview URL, smoke-tests it. |
| `make promote CONFIRM=production` | Deploys to production the version that passed on staging, from a Mac. CI does not promote: a cloud part's tag deploys production (section 6). |
| `make versions ENV=` / `make rollback ENV= CONFIRM=` | Deployed versions / back to the previous one. |

### 4.8 CI

| Command | Does |
|---|---|
| `make ci-lint` | `actionlint` of `.github/workflows/`. |
| `make ci-status` / `make ci-logs` | `gh run list` for the current branch / `gh run view --log-failed` of its last failed run. |
| `make ci-run` | `gh workflow run checks.yml` on the current branch (the workflow has a manual trigger). |
| `make ci-local JOB=<job>` | Runs one job of `checks.yml` here, in Docker, with `act`; without `JOB` it lists the jobs. Jobs run as linux/amd64 like GitHub's Linux runners (`CI_LOCAL_PLATFORM=` for the machine's own). Partial: the reusable workflows come from the public `CI_TEMPLATES_REPO` with no token (`GITHUB_TOKEN` in the environment only for a private one, or a step that calls the GitHub API), and some steps may not run here. Run it from a normal clone, not a git worktree. |
| `make ci-setup` | Sets up CI once the GitHub repository exists: the CI age key (`secrets-ci`), the read-only deploy keys (made in `~/.ssh` when missing, added to the project's secrets repo and, with a hardware part, the KiCad library, with an altium part the Altium library, when not there yet), their repository secrets, and the variables `SECRETS_REPO` (the `owner/name` of `SECRETS_REMOTE`), `KICAD_LIBRARY_REPO` and `ALTIUM_LIBRARY_REPO`. Safe to run again. Prints no values. |
| `make ci-setup-help` | Prints the commands `ci-setup` runs, for you to run by hand. Prints no values. |

### 4.9 Firmware (every firmware kind)

| Command | Does |
|---|---|
| `<part>-build` | Builds for the part's board into `<dir>/build/`. |
| `<part>-flash` | `PROBE=` picks the tool (probe-rs, jlink, openocd, nrfutil, dfu, stlink, esptool, pio); `PORT` is detected. |
| `<part>-erase` / `<part>-recover CONFIRM=erase` | Full erase / unlock a protected chip. |
| `<part>-monitor` | Serial console, port detected, also logged to `build/monitor.log`. |
| `<part>-debug` | GDB through the probe. |
| `<part>-size` / `<part>-config` | RAM / ROM report / menuconfig. |
| `<part>-keygen` | The signing key, created in the secrets repo. |
| `<part>-provision SERIAL=` | Per-device setup: identity, certificates, modem firmware, first flash. |
| `<part>-power DURATION=` | Current profile (zephyr, silabs): the samples into `build/power.csv`, and the sample count, duration, average, minimum and maximum current (and average power when the voltage is known) printed and kept in `build/power.txt`. zephyr: `POWER=ppk2` (Nordic Power Profiler Kit II, through the `ppk2-api` python package) or `joulescope`, through `<part>_POWER_PYTHON`. silabs: Simplicity Commander's energy monitor (AEM) on the kit. |
| `<part>-power-live` / `<part>-power-avg` | silabs: the AEM current and voltage streamed at `AEM_RATE_HZ` / the average over `AEM_WINDOW_MS`. |
| `<part>-release` | Signed OTA image to the OTA store (`OTA_BUCKET` in `make/project.mk`) as `<ver>/` and `latest/`; `PROMOTE=1` marks it stable. In CI: the production job of `release.yml` (`confirm` = `production`). The GitHub Release is separate (4.12). With no OTA bucket (`OTA_BUCKET` and `<part>_OTA_BUCKET` empty: a project without Cloudflare) it prints `> <part>: no OTA bucket (no Cloudflare in this project): firmware publish skipped` and exits 0, `make help` leaves it out (`ALL=1` lists it), and `scaffold.sh` writes no `<part>-production` job for the firmware parts when the project has no Cloudflare part and its `project.mk` sets no OTA bucket. |

**Upstream Zephyr.** A zephyr part builds on the nRF Connect SDK by default (`<part>_NCS`). `<part>_ZEPHYR := v4.3.0`
(and no `<part>_NCS`) builds it on upstream Zephyr instead: setup runs `west init -m
https://github.com/zephyrproject-rtos/zephyr --mr <ver>` into `~/.toolchains/zephyr-<ver>`; the venv, the Zephyr SDK,
build, flash and release are the same. `PROBE=commander` flashes through west's Silicon Labs Commander runner (for a
SiWx917 on Zephyr; `<part>_DEVICE` is its `--device` for erase), next to probe-rs, jlink, openocd and nrfutil.

**silabs.** An slc project (`*.slcp`) on the Simplicity SDK and WiseConnect, for SiWx917 / SiWG917 (M4). slt,
Silicon Labs' Simplicity Tools CLI, is pinned per part (`<part>_SLT`) and installed into `~/.toolchains/slt-<ver>`;
it installs slc, a Java runtime, the GNU Arm toolchain, the Simplicity SDK (`<part>_SDK`), WiseConnect
(`<part>_WISECONNECT`) and Simplicity Commander (`<part>_COMMANDER`, `1.25.0`) into its own folder, `~/.silabs/slt`
(`slt install wiseconnect/<version>`: a bare `wiseconnect` would install the latest and a newer SDK; likewise
`commander/<version>`). The default `<part>_SLT_INSTALL` is `slc-cli wiseconnect/<WISECONNECT> commander/<COMMANDER>`;
an empty `<part>_COMMANDER` leaves Commander out. The kind uses `SILABS_COMMANDER`, else `commander` on `PATH`, else
`SILABS_COMMANDER_PATHS`, else the one slt installed (`slt where commander/<COMMANDER>`; on macOS the package is
`Commander.app` and the CLI `Commander.app/Contents/MacOS/commander`). A part set up before Commander joined
`SLT_INSTALL` gets it from `make <part>-setup`, which installs `commander/<COMMANDER>` when no Commander is found, and
doctor names that as the fix. slt's packages, Commander among them, are not in the toolchain ledger (only
`~/.toolchains/slt-<ver>` is), so `make teardown` and `make prune` leave them. A build is `slc generate --overwrite-all` (a makefile project) into `<dir>/build/<board>`, then
the generated makefile with the pinned GNU Arm toolchain (`<part>_GCC`, `12.2.rel1`); `<part>_BOARD` is the slc board
(`brd4338a`, spaces stripped). slc generate gets no `--toolchain`: on a SiWx917 the device brings WiseConnect's
`wiseconnect_toolchain_gcc_standard`, which provides `toolchain_gcc`, and `--toolchain gcc` added the Simplicity SDK's
`toolchain_gcc` as well ("Project is invalid even after autoselecting dependencies": the two are exclusive); the `.slcp`
needs no toolchain line. The `.rps` image (what the SiWx917 boots and OTA delivers) comes from the `.slcp`'s post-build
profile, two top-level lines:

```yaml
post_build:
  profile: wiseconnect_soc
```

It is a key of the `.slcp`, not a component: WiseConnect's `utilities/postbuild_profile/wiseconnect_soc.slpb` turns
`<name>.out` into `<name>.rps` (`create_rps`) and the `.rps` into the `.hex`, `.s37` and `_isp.bin`. slc then writes
`<name>.slpb` and a post-build rule `"$(POST_BUILD_EXE)" postbuild "./<name>.slpb" --parameter build_dir:"$(OUTPUT_DIR)"`
with `POST_BUILD_EXE` empty, and the kind passes `POST_BUILD_EXE=<Simplicity Commander>` to the generated makefile. With
a post-build, `build` needs Commander and refuses without it (`check` skips the post-build with a warning, so a runner
without Commander still compiles); without one, the build makes no `.rps` and release refuses, naming the two lines.
`make <part>-test` runs the host
unit tests, the Makefile in `<dir>/test/` (else `<dir>/tests/`), with the Mac's `cc` and `BUILD_DIR=<dir>/build/test`
(no Makefile: nothing to run); `clean` removes `<dir>/build`, so a test build is cleaned only when it is under it. Flash,
erase and the energy monitor go through Simplicity Commander (`PROBE=commander`, the default; `PROBE=jlink` flashes with J-Link),
the console through the kit's J-Link VCOM port, debug through the J-Link GDB server. `<part>_SIGN := 1` signs the
`.rps` with the ECDSA P-256 key `silabs-m4` from the secrets repo (`make <part>-keygen`; the `secrets.schema` row is
`optional:`); the release is the `.rps` to the OTA bucket, as for the other firmware kinds.

A firmware part builds one image per env (PlatformIO `default_envs`, say one per board revision), but a
board takes one: with pio, flash, erase, monitor, debug and provision refuse unless exactly one env is
selected (`PIO_ENV=<env>`, `<part>_PIO_ENV` in `make/project.mk`, or a `platformio.ini` that names only one).

A firmware part with nothing in its folder yet (no `CMakeLists.txt` for zephyr and espidf, `platformio.ini` for pio,
`CMakeLists.txt` or `Makefile` for arm-gcc, `src` for circuitpython, a `*.slcp` for silabs) is not started: setup, check, test and build
print `> <part>: not started yet (no <file> in <dir>): <verb> skipped` and exit 0, doctor warns, flash and release
refuse (4.1, Parts not started yet).

Signing keys reach the build through a temporary file only (`secrets.sh with-file`, the `{}`
placeholder), removed when the command exits. Every firmware build is signed with the real key, so
`make build` (and `make deploy`, which builds) asks for Touch ID once per firmware part: the image
you test is the image you ship. eFuse burns and similar one-way operations need
`CONFIRM=fuse`.

#### Defines per environment (1.8)

A firmware build can be pointed at an environment by the same `ENV` the cloud parts use, for example a device's
server URL. `make/project.mk` declares, per env and each optional:

```make
firmware_ENV_DEFINES_staging    := CLOUD_URL="wss://api-staging.example.com/d/ws" LOG_LEVEL=3
firmware_ENV_DEFINES_production := CLOUD_URL="wss://api.example.com/d/ws" LOG_LEVEL=1
```

`<part>_ENV_DEFINES_<env>` (env `local`, `staging` or `production`) is a list of `NAME` or `NAME=value` words, split
at spaces outside double quotes. A double-quoted value keeps its quotes, so `CLOUD_URL="wss://..."` is the C string
literal `"wss://..."` (`#define CLOUD_URL "wss://..."`), spaces and slashes included; a `\"` inside it stays. `make
<part>-build ENV=staging` compiles with `-DCLOUD_URL="wss://api-staging.example.com/d/ws" -DLOG_LEVEL=3`, and so do
`check`, `flash` and `release`, which build first (a release builds with the defines of the `ENV` it uploads to).
With no setting for `ENV` nothing is passed and the code's own defaults apply (`#ifndef CLOUD_URL ... #endif`). A
malformed setting (an unclosed quote, a word that is not `NAME[=value]`) stops the build. `$` is make's: write `$$`.

How each kind passes them:

| Kind | How |
|---|---|
| espidf | idf.py `-D STD_ENV_DEFINES=<A=1;B="x">` (a CMake list, so no `;` in a value), applied by a block in the part's top `CMakeLists.txt` (below). The build stops when a define is set and the file never names `STD_ENV_DEFINES`; `make audit` warns with the block. A `CMakeLists.txt` with the block gets it on every build, `-D STD_ENV_DEFINES=` (empty) for an env without defines: it is a CMake cache variable, kept until it is set again (1.12). |
| pio | `PLATFORMIO_BUILD_FLAGS` (each define a single-quoted `'-DNAME=value'`, which PlatformIO splits like a shell), on top of `build_flags` and of a `PLATFORMIO_BUILD_FLAGS` already in the environment; for every pio command, so an upload builds what build built. |
| zephyr | west build `-- -D<APP>_EXTRA_CPPFLAGS=<flags>` with sysbuild (the app image only, MCUboot is built without them), `-DEXTRA_CPPFLAGS=<flags>` without. Zephyr splits it as a shell would. Passed on every build, empty for an env without defines (a cache variable, 1.12). |
| arm-gcc | A CMake project: `CFLAGS` and `CXXFLAGS` when CMake configures the build folder (a new one whenever the defines change). A Makefile project: `STD_ENV_CFLAGS` in its environment, which its `Makefile` must use: `CFLAGS += $(STD_ENV_CFLAGS)` (and `CXXFLAGS` for C++); the build stops when the Makefile never names it, and `make audit` warns. |
| silabs | Appended to `CC` and `CXX` on the generated makefile's make line, as `check` adds `-Werror` (the generated makefile has no variable of its own for extra defines). |
| circuitpython | None: the code is Python, copied as it is, with no compile step. Per-env settings go in the code's own files (`settings.toml`); `make audit` warns about a setting. |

The espidf block, after `include($ENV{IDF_PATH}/tools/cmake/project.cmake)` and before `project()`:

```cmake
# project-standard 1.8: the defines of make <part>-build ENV=<env> (<part>_ENV_DEFINES_<env>)
foreach(std_define IN LISTS STD_ENV_DEFINES)
  idf_build_set_property(COMPILE_DEFINITIONS "${std_define}" APPEND)
endforeach()
```

**Which env a build is for.** Every build writes `std-env` into its build folder: `env=<ENV>`, then its defines one
per line (`<dir>/build/<board>/std-env` for zephyr, silabs and espidf's `<dir>/build/<target>`, `<dir>/.pio/build/<env>/std-env`
for pio, the output folder for arm-gcc). A build whose stamp records other defines than `ENV`'s is made again from
scratch first (the build folder removed; an arm-gcc Makefile's `clean` target), since CMake caches and plain
makefiles would keep the old ones. A flash or release with `NOBUILD=1` (no build first) refuses a build whose
defines differ from `ENV`'s: `the build in <dir> was made for ENV=staging, and <part>_ENV_DEFINES_production
differs: build it again with ENV=production`. Only the defines are compared: two envs with the same defines (or
none) share a build. A build without a stamp (from before 1.8) counts as one without defines when it is checked, and
a build folder that holds files but no stamp is made again from scratch before a build (1.12). In CI, the build job
builds with `ENV=production` when the run releases (`run_release` on a tag, or `confirm` `production`) and with
`ENV=local` otherwise, so the publish job's `NOBUILD=1` release ships a production build; the stamp travels in the
build artifact (it is not a dot file, which `upload-artifact` would leave out). The GitHub Release files
(`release-assets`) are the build's files whatever `ENV` says.

**One run per build folder, the image checked before it is used (1.12).** Two runs for different envs in one build
folder at once (`make <part>-release ENV=staging` and `ENV=production` in two terminals) once shipped staging's image
as production's: the staging run rebuilt the folder while the production run built and uploaded from it. Now:

- Every build, flash and release holds the build folder's lock from before its env check to its stamp, flash or
  upload. A second run waits up to `STD_FW_LOCK_WAIT` seconds (10), then stops: `<dir> is in use by another run: pid
  <n> (make <part>-build ENV=staging)`. The lock is a directory in `TMPDIR` named after the folder's path
  (`std-fw-lock-<cksum>`) holding the pid of the shell that holds it; it goes when that shell exits, also on Ctrl-C.
  A lock whose pid is gone (a run killed with `kill -9`) is taken over with a warning; a live one never is (the
  message names the directory to remove when no such process runs). A make started inside the holding shell
  (`$(MAKE) ...` in the same recipe line) shares it.
- The build also writes `std-env.sha256`: `<sha256>  <path>` for each image it made (espidf: the app, bootloader and
  partition table; zephyr: `merged.hex`, `dfu_application.zip`, the `zephyr.hex`/`.bin`/`.signed.*` images; pio:
  `firmware.bin`/`.hex`/`.uf2`/`.elf`; arm-gcc: the elf and bin; silabs: `.hex`, `.out`, `.rps`, `-signed.rps`). A
  build removes it first and writes it last, so a build that fails or still runs has none.
- A flash and a release check, under the lock and right before they use the folder, that the build was made for
  `ENV`'s defines and that every recorded image is still the file there (`<image> is not the image the build for
  ENV=staging made (another build changed it)`); a release also needs the image it uploads to be recorded (a build
  from before 1.12 is refused: build it again), and the upload compares the file's sha256 with the record once more.

A project's own OTA or upload target (in `make/local.mk`) does the same with `std_fw_image_check`, in the recipe line
that uploads, before the upload:

```make
<part>-ota: $(if $(NOBUILD),,<part>-build)
	@$(STD_FW_SH) $(call std_fw_image_check,<part>,$(<part>_BUILD),$(<part>_BUILD)/<app>.bin) \
	  say "uploading sha256 $$image_sha"; <the upload of $(<part>_BUILD)/<app>.bin>
```

It takes the folder's lock for the rest of that shell (no build can replace the image until the upload is done; a
`trap ... EXIT` set after it must call `std_fw_unlock`), refuses a build made for another env's defines, a changed
image and a build with no record of the image, and sets `$$image_sha` to the image's sha256. The image is a path in
the build folder (or relative to it); `<part>_BUILD` is the folder for espidf (`<dir>/build/<target>`), zephyr and
silabs; pio's is `<dir>/.pio/build/<env>`, arm-gcc's `<part>_OUT`. The build target stays a prerequisite (a separate
run); only the check and the upload share the recipe line.

### 4.10 Hardware (KiCad 10, Altium) and mechanical (FreeCAD)

| Command | Does |
|---|---|
| `<part>-setup` | Checks, or with `APPLY=1` writes, KiCad's library tables and path variables for the shared library (`KICAD_LIBRARY_DIR` from the user config, else the library KiCad's own `<prefix>_LIB_DIR` points at). With `<part>_LIBRARY := local`, checks the board's own tables instead and writes nothing. |
| `<part>-new NAME=` | A board from the template: title block, JLCPCB rules and stackup, library wired in. |
| `<part>-check` | ERC, then DRC with schematic parity; non-zero exit on errors. |
| `<part>-build` | Gerbers, drill, positions, BOM, schematic PDF, STEP, WRL and iBOM into `outputs/`. |
| `<part>-bom` | Hands sourcing and pricing to the `bom` skill. |
| `<part>-release` | The board's GitHub Release, the same as `<part>-github-release` (4.12): the fab zip (also kept as `production/<Board>_v<rev>.zip`) and every output attached to the Release. Since v7 the tag `<part>-v<rev>` comes from `make <part>-bump`, not from release. |

A hardware part with no `*.kicad_pro` yet is not started: check and build print `> <part>: not started yet (no
*.kicad_pro in <dir>): check skipped` and exit 0, doctor warns, release refuses (4.1, Parts not started yet).

**A board's own library.** By default a hardware part uses the shared KiCad library: `KICAD_LIBRARY_DIR` on the Mac,
and in CI the repository `KICAD_LIBRARY_REPO` checked out with its deploy key (`make ci-setup` adds the key to
`KICAD_LIBRARY_PROJECT`, section 9). `<part>_LIBRARY := local` in `make/project.mk` makes the board's own
`sym-lib-table` and `fp-lib-table` its library: every entry points inside the project (`${KIPRJMOD}/...`; KiCad's
own `${KICAD<n>_...}` libraries are fine), and setup and doctor check those tables instead of the shared library's
variables. Its CI jobs pass `library: local` to `hardware.yml`, which then checks out no KiCad library (the scaffold
writes it when `make/project.mk` sets the value; add it by hand to a workflow that exists), and `ci-setup` adds no
KiCad deploy key when every hardware part is local.

Never edit a board or schematic while KiCad has it open.

#### Altium

Altium Designer is Windows only and licensed, so nothing in the standard runs it: the board's OutJob, run in Altium,
writes the outputs into `<dir>/outputs/` (never committed). The kind checks the project, verifies the outputs and
packages them.

| Command | Does |
|---|---|
| `<part>-setup` | Adds the shared Altium library as a submodule (`ALTIUM_LIBRARY`) when the project has none, checks it out when it is not, and installs its tools' requirements in `<dir>/.venv` (1.4, below). |
| `<part>-check` | The `.PrjPcb` and every document it lists (each `DocumentPath=` relative, inside the layout, present; one into the Altium library, such as its DbLib, is accepted wherever the library is), the folder layout (section 1), Markdown docs in `docs/<part>/` and not in the part folder, and Git LFS: every Altium binary (`.SchDoc .PcbDoc .SchLib .PcbLib .IntLib .Harness .PrjPcbVariants`) is an LFS pointer and covered by an LFS line, and the `.PrjPcb` and `.OutJob` are `-text`. Then `<part>-lib-check` once the library is checked out (a submodule not checked out is a warning). Fails on any violation. |
| `<part>-lib-check` | The library's `tools/check.py project <dir>/<Board>.PrjPcb --root <library>`, from `<dir>/.venv` (`WARN=1` adds `--warn`). Without the library checked out it fails with the `git submodule update --init` command. |
| `<part>-layout` | Prints the `git mv` commands and the `DocumentPath=` edits that move an existing project into the layout; moves nothing. |
| `<part>-build` | Verifies the OutJob's outputs in `outputs/` (Gerber or ODB++, drill, pick and place, a BOM CSV `*BOM*.csv`, PDF), renders the Gerbers with gerbv when it is installed, and writes the fab zip `production/<Board>_v<rev>.zip`. |
| `<part>-bom` | Hands the OutJob's BOM (`outputs/**/*BOM*.csv`) to the `bom` skill for sourcing and pricing; run the OutJob in Altium first (1.5). |
| `<part>-release` / `<part>-github-release` | The board's GitHub Release from the outputs here (4.12). |
| `<part>-clean` | Removes `outputs/`, which only the OutJob in Altium makes again. `make teardown` never removes it (it removes `production/` and `release/`). |

The `.gitattributes` lines for Altium's binaries are `lockable` (`*.SchDoc filter=lfs diff=lfs merge=lfs -text
lockable`, and the same for the others, `*.PrjPcbVariants` among them: it is an OLE compound file): they never merge,
so `git lfs lock` before editing one. The `.PrjPcb` and the `.OutJob` are text, but Altium writes them with CRLF and
the `.PrjPcb` with a UTF-8 BOM, so `*.PrjPcb -text` and `*.OutJob -text` keep them byte-exact between Windows and a
Mac (1.2; `make <part>-check`, doctor and the audit report a missing line, and `scaffold.sh --force` appends it). `.gitignore` gets
Altium's history, logs, previews and locks (`History/`, `Project Logs for */`, `__Previews/`, `*.PcbDocPreview` ...) and
the part's `outputs/` and `production/`. In CI only the check runs (`altium.yml`, on the LFS pointers, nothing pulled);
release.yml has no job for the part. After `make <part>-bump` and `make release-push`, the Release is made where the
outputs are: `make <part>-github-release FORCE=1` on the Windows machine that ran the OutJob (Git Bash), or on a Mac
the outputs were copied to.

**The shared Altium library (1.4).** An altium part takes its parts from one library shared by every board of the owner,
the repository `ALTIUM_LIBRARY_PROJECT` (`owner/name`, default `<owner>/altium-library`; `make/project.mk`, else the
user config, else the default, section 9), as the KiCad boards take theirs from `kicad-library`. Unlike KiCad's, it is a
git submodule of the project, at `ALTIUM_LIBRARY` (`make/project.mk`, default `hardware/altium-library`), because an
Altium project names its DbLib by a path relative to itself, the same on every machine. The library holds `parts.csv`
(one row per MPN), `Library.DbLib` (Altium's view of it), `sym/<name>.SchLib`, `fp/<name>.PcbLib`, `models/<MPN>.step`
(Git LFS, lockable) and `tools/check.py` with `tools/requirements.txt`; its check is
`python3 tools/check.py library` (the library itself) and `python3 tools/check.py project <X>.PrjPcb [--root DIR]
[--warn]`, exit 0 when clean and 1 on findings.

- The scaffold adds no submodule (it makes no network call): it documents it in the part's README and
  `docs/<part>/library.md`. `make <part>-setup` adds it (`git submodule add`, the URL `ALTIUM_LIBRARY_URL`:
  `../<name>.git` when the library has the project's own GitHub owner, so it follows `origin` over https or ssh, else
  `https://github.com/<owner>/<name>.git`), then commit `.gitmodules` and the submodule. In a fresh clone setup runs
  `git submodule update --init -- <ALTIUM_LIBRARY>`. Setup never moves a checked-out library: to take a newer one,
  `git -C <ALTIUM_LIBRARY> pull`, then `git add <ALTIUM_LIBRARY>` and commit the new pin.
- Setup makes `<dir>/.venv` with `ALTIUM_PYTHON` (default `python3`) and installs `tools/requirements.txt` (olefile),
  again only when that file changes. `.venv/` is in `.gitignore`; `make teardown` removes it.
- `make <part>-doctor` names the library repository and where it came from, and warns when there is no submodule, when
  it is not checked out, and when the checkout is behind (or otherwise not at) the pinned commit, each with its command.
  The audit warns about an altium part without the submodule, with the fix.
- In CI, `altium.yml` asks `make <part>-lib-ref` for the submodule's path and pinned commit and, when the repository
  variable `ALTIUM_LIBRARY_REPO` is set, checks the library out there at that commit with the read-only deploy key
  `ALTIUM_LIBRARY_DEPLOY_KEY`, pulls from LFS only its symbols and footprints (every `.step`/`.stp` is left out, cached per
  library commit) and the part's `.SchDoc` and `.PcbDoc` files, installs the tools and runs `<part>-check`. `make ci-setup` adds the
  key to `ALTIUM_LIBRARY_PROJECT` and sets the variable whenever the project has an altium part.

#### Mechanical (FreeCAD)

| Command | Does |
|---|---|
| `<part>-check` | Opens every `*.FCStd` of the part (subfolders too) with freecadcmd and recomputes it; checks that each model is in Git LFS. |
| `<part>-build` | Exports every visible body or part (a PartDesign Body, an App::Part or a top-level Part shape) to STEP and STL in `outputs/<file>-<label>.step` / `.stl`. |
| `<part>-release` / `<part>-github-release` | The STEP and STL exports and the `.FCStd` sources attached to the GitHub Release (4.12). |

`FREECADCMD` (user config or environment) names freecadcmd when it is neither on `PATH` nor in FreeCAD.app (the
Homebrew cask `freecad`). Git matches `.gitattributes` patterns with case on Linux, so the template has both
`*.fcstd` and FreeCAD's own `*.FCStd`. CI uses Ubuntu 24.04's FreeCAD (0.21, not pinned): a model saved by FreeCAD
1.x may not recompute the same there; such a project runs the check on its own runner (`STD_RUNNER`).

The revision of an altium or mechanical part is `<dir>/VERSION`, as a hardware part's: a first bump starts at a plain
number, and each major revision keeps its own files in the Release `latest`.

### 4.11 Apps, containers, versions, housekeeping

| Command | Does |
|---|---|
| `<part>-dev` / `-build` / `-logs` | Same for Flutter, Tauri, Xcode and Android. |
| `<part>-release TARGET=ios\|android\|macos\|linux` | Signs with keys from the secrets repo and uploads (TestFlight, Play, the OTA bucket), notarizes, or builds deb / AppImage. Needs `CONFIRM=production`. |
| `<part>-build` / `<part>-release` (docker) | buildx for amd64 and arm64; release pushes `ghcr.io/<owner>/<image>:<sha>` (and `:<version>` on the tag `<part>-v<version>`). Every build and push carries the OCI labels `org.opencontainers.image.source` (the repository: `GITHUB_REPOSITORY` in CI, else the GitHub `origin`), `.revision`, `.version` (on the tag) and `.created`, and the same annotations on the pushed index when buildx has `--annotation`: the label links the ghcr.io package to its repository, so it inherits the repository's access. The registry is `DOCKER_REGISTRY`, the project owner's `ghcr.io/<owner>` in lowercase (section 9). |
| `<part>-setup` / `<part>-doctor` (docker) | setup also logs docker in to ghcr.io with gh's token (`gh auth token`, on stdin; not in CI, which logs in with `GITHUB_TOKEN`); doctor warns when gh's token lacks `write:packages` (`gh auth refresh -s write:packages`) or docker has no ghcr.io login. |
| `<part>-prune-images` (docker) | Lists the image's versions in ghcr.io that are untagged or tagged only with git shas and older than 30 days (`KEEP_DAYS=`), never a platform manifest of a version that stays; `CONFIRM=prune` deletes them. |
| `make version` / `make bump PART= LEVEL=patch\|minor\|major` | Show each part's version / release one part (4.12). |
| `make hooks` | The pre-commit hook: format check, gitleaks, LFS check, large-file guard (files over `STD_MAX_FILE_MB`, 5 MB by default, not in LFS; KiCad design files `.kicad_pcb`, `.kicad_sch`, `.kicad_pro` are skipped, since they are text that git stores as deltas and diffs). |
| `make clean` / `make distclean` | Build output / also project-local dependencies. Shared toolchains are never removed (`make teardown` and `make prune`, 4.1, are the commands that do). |
| `make help` | The commands by stage and by part, only those the project's parts use (no Cloudflare group without a cloud part or an `OTA_BUCKET`, and only the token commands, `cf-provision` and `cf-status` with the bucket alone; no `flash` without firmware); `make help ALL=1` lists every one. |

### 4.12 Releases

Each part releases on its own, as `<part> <version>`, from its own tag `<part>-v<version>`. Every part of every
kind has a version and a GitHub Release.

**Making one.** Write what changed under `## [Unreleased]` in `<dir>/CHANGELOG.md` as the work lands, then:

```sh
make <part>-bump LEVEL=patch          # or minor, major; or VERSION=1.4.0 (also a pre-release: 1.5.0-rc1)
make release-push                    # the branch, then each new release tag in its own push
```

The push starts `release.yml` on the tag (section 6). For a cloud-worker or web-pages part the tag push is also the
production deploy: the tag's job checks, builds, runs `make <part>-deploy ENV=production CONFIRM=production`, and only
after that deploy succeeds makes the Release, which then means "this version is live". Push release tags with `make release-push`, not one `git push` of
several: GitHub starts no workflow for the tags of a push that carries more than three, and the tags would sit there
with no Release. A tag that origin has with another commit is refused; moving a published tag is done by hand.

GitHub marks one Release of a repository **Latest**. Since v20 that is the Release **`latest`** (tag `latest`, title
`<project> latest`): it holds the newest files of every part, and the part Releases are made with `--latest=false`.
Its files keep their names from one version to the next, so `.../releases/download/latest/<file>` always gets the
newest: the version is taken out of the name and the part put in front (`app-1.0.0-linux-amd64.deb` is
`app-linux-amd64.deb`, `rev4-firmware.bin` is `firmware-rev4-firmware.bin`). A hardware, altium or mechanical part keeps one group per major
version, so every board revision has its files (`hardware-v3-...`, `hardware-v4-...`). Each group has its own
`<group>-SHA256SUMS`; the part's own checksum files are left out. Its notes are a table of each group's version and
Release.

- `release.yml`'s last job, `latest`, runs `make <part>-release-latest VERSION=<version>` once the tag's part job has
  passed, one at a time across the repository. From a Mac, `make <part>-github-release FORCE=1` updates it itself.
- `make <part>-release-latest [VERSION=x.y.z]` copies a published Release by hand (the first time, or after a fix).
  A version older than the group's, a pre-release or a draft leaves it as it is; a newer one replaces the group's
  files and removes the names it no longer has.
- `make latest` prints each part's newest published Release (name, date, page), and `make latest PART=<part>` one part's.

| Command | Does |
|---|---|
| `<part>-bump LEVEL=\|VERSION=` | Sets the version in the kind's own source (below), moves the Unreleased notes under `## [<version>] - <date>` and leaves a fresh empty Unreleased (Added, Changed, Fixed), commits only those files (`<part>: release <version>`) and makes the annotated tag `<part>-v<version>`. Prints the push command; never pushes. Refuses an empty Unreleased (`FORCE=1` releases without notes), an existing tag and the version it already has. Root `make bump PART=<part>` (needs `PART` when several parts have it). |
| `<part>-release-assets` | Builds (unless `NOBUILD=1`), then collects the release files into `<dir>/release/<version>/` with `SHA256SUMS`. `<dir>/release/` is in `.gitignore`. cloud-worker and web-pages have no release files: it says so and builds nothing. |
| `<part>-github-release` | Release assets, then creates the GitHub Release `<part> <version>` with the CHANGELOG section as its notes and the files attached (or updates it when it exists: safe to re-run); cloud-worker and web-pages: the notes only (`release.sh create --notes-only`). Runs in the release job of the tag `<part>-v<version>` (`release.yml`) and does nothing on another part's tag; it refuses a tag that does not match the version, a run without a tag, and a Mac unless `FORCE=1` is on the command line. No `CONFIRM`: it publishes to the project's own repository, not to production. |

LEVEL keeps the number of components: `1.4.2` patch is `1.4.3`, minor `1.5.0`, major `2.0.0`; `1.2` minor is `1.3`;
a board revision `2` is `3` whatever the level; patch on a pre-release `1.5.0-rc1` releases `1.5.0`.

**Version sources**

| Kind | Version lives in | bump also |
|---|---|---|
| zephyr | `<dir>/VERSION`, Zephyr format (`VERSION_MAJOR`, `VERSION_MINOR`, `PATCHLEVEL`, `EXTRAVERSION` for a pre-release), or plain | creates it in Zephyr format when missing |
| espidf, pio, arm-gcc, circuitpython, silabs | `<dir>/VERSION` (Zephyr format or plain), else `<dir>/version.txt` | creates a plain `VERSION` when missing |
| hardware | `<dir>/VERSION`, else the `rev` of the board's title block | writes `VERSION` (the title block is left as it is; say so in the board) |
| altium, mechanical | `<dir>/VERSION` (a revision, as hardware) | creates it on the first bump |
| go, docker, cloud-worker, web-pages | `<dir>/VERSION` (plain) | creates it on the first bump |
| app-flutter | `pubspec.yaml` `version: x.y.z+build` | counts the build number up |
| app-tauri | `src-tauri/tauri.conf.json` `"version"` (or the `package.json` it points to) | sets the same version in the `[package]` table of `src-tauri/Cargo.toml` (not a dependency's), the top-level `"version"` of `package.json` and, when it is tracked, the app's own entry in `src-tauri/Cargo.lock`, each when it exists |
| app-android | `app/build.gradle.kts` `versionName` | counts `versionCode` up |
| app-xcode | the marketing version (agvtool) | `agvtool next-version -all`; refuses without agvtool (a Mac with Xcode) |
| python | `pyproject.toml` `version` of `[project]` | refuses a dynamic version |

**The Release.** Named `<part> <version>`, on the tag `<part>-v<version>`; its notes are the CHANGELOG section of
that version. Every file is a release asset of it, with a download link on the Release page. Every Release has `SHA256SUMS`
(`sha256sum -c SHA256SUMS` in the folder checks a download), or one `SHA256SUMS-<platform>` per platform for the app kinds
(below). Release assets stay until someone deletes them; an old Release goes with `gh release delete <part>-v<version>`
(ask first: it cannot be undone). A docker part's image stays in `ghcr.io/<owner>`; its `image.json` is attached.

**Platforms (since v8; GitHub runners since v9).** An app part builds per `PLATFORM` (`macos`, `ios`, `android`, `linux-amd64`, `linux-arm64`, `windows`; default: this machine, from `release.sh host-platform`). Each platform is built on its own host and writes its own `SHA256SUMS-<platform>`; the jobs attach their files to the same Release, so a file name must carry its platform.

| Platform | Built by | Notes |
|---|---|---|
| macos | a Mac: `make <part>-github-release FORCE=1`; a CI job on `macos-latest`, only when the repository variable `MACOS_CI` is `true` | Tauri: universal `.dmg` and `.app.zip`; Flutter: universal `.zip`; signed with the production secrets when present |
| ios | a Mac: `PLATFORM=ios FORCE=1` (app-xcode: the default, since v8, is ios; a macOS app passes `PLATFORM=macos`) | dSYMs zip; the TestFlight build number is a line under `### Builds` in the Release notes; no ipa |
| android | a Mac: `PLATFORM=android FORCE=1` (app-android always builds android) | release apk attached; `.aab` and R8 mapping are workflow artifacts only |
| linux-amd64 | the release job on `ubuntu-24.04` | Tauri deb, rpm, AppImage; Flutter `.tar.gz` (no deb yet) |
| linux-arm64 | the release job on `ubuntu-24.04-arm` | the same files as linux-amd64 |
| windows | the release jobs on `windows-2025` (x64) and `windows-11-arm` (arm64) | Tauri x64 `.msi` and `.exe`; arm64 `.exe` only (WiX cannot build an arm64 `.msi`). The arm64 image's Visual Studio components are not verified: the job adds the ARM64 C++ tools when they are missing. Not yet run on GitHub |

Signing is used only when the secrets hold it, and the build says when it is unsigned. Tauri macOS and iOS run inside the
production secrets (`secrets.sh exec --env production`): `APPLE_SIGNING_IDENTITY`, `APPLE_API_KEY`, `APPLE_API_ISSUER`, and
the key file `appstore-api-key` as `APPLE_API_KEY_PATH` (the export is in the wrapper). Tauri Windows is signed by
`sign-windows.sh` (signtool from the Windows SDK) with the key file `windows-codesign` and the staging variable
`WINDOWS_CERT_PASSWORD`, only in a CI job that has the secrets (see the windows row). app-android is signed with the key
file `android-keystore` when it exists. Flutter (Android, iOS archive, macOS) and Tauri Android run inside the production
secrets but the helper does not sign them: their Gradle or Xcode settings must read the environment, which is not wired by
default. The optional names are in `secrets.schema` (the scaffold writes the ones each app kind reads: section 5). Trade-off: signtool takes the
Windows password only as `/p`, so it is on signtool's command line while it runs (visible to processes of the same user on
the runner); the password is never in the project.

Duplicate creation is safe: when two jobs create the Release at the same moment, the second create is refused, the
Release is read again and updated instead (up to four tries). A Release's `### Builds` lines written by one platform
survive another platform's update (jq or python3 reads the description; without either, build lines are not kept).
Store bundles (`*.aab`) and mapping files (`*-mapping.txt`) are never Release assets: they are kept as workflow
artifacts (7 days in the app workflows) and must be downloaded promptly.

**Assets per kind** (what each kind's build already makes; a file the build did not make is skipped with a line
saying so, a missing required one fails):

| Kind | Files in the Release |
|---|---|
| zephyr | `dfu_application.zip` (signed, OTA), `merged.hex` (MCUboot and the app, factory programming), `zephyr.signed.bin`, `zephyr.signed.hex`, `zephyr.elf`, `zephyr.map`; without MCUboot `zephyr.bin`, `zephyr.hex` |
| espidf | the app `.bin` (signed with secure boot), `bootloader.bin`, `partition-table.bin`, `flash_args` (paths flattened to the release folder), `factory-<target>.bin` (`esptool merge_bin` of flash_args, where esptool is on PATH), `.elf`, `.map` |
| pio | per env (`PIO_ENV`, else `default_envs`, else every `[env:*]`): `<env>-firmware.bin` / `.hex` / `.uf2`, `<env>-firmware.elf` |
| arm-gcc | `<name>.bin`, `.hex` (objcopy when the build has none), `.elf`, `.map` |
| circuitpython | `<board>-firmware.uf2` / `.bin`, `<part>-<version>-code.zip` (the content of `<dir>/src`) |
| silabs | `<name>.hex` (factory programming), `<name>.out` (ELF), `<name>-signed.rps` (with `SIGN=1`) and `<name>.rps` (OTA), and the `.map`, `.s37` and `.bin` when the build made them |
| hardware | `<Board>_v<rev>.zip` (Gerbers and drill), `-bom.csv`, `-bom-jlcpcb.csv`, `-pos.csv`, `-cpl-jlcpcb.csv`, `.ipc356` (IPC-D-356 netlist, when kicad-cli exports it), `-schematic.pdf`, `-ibom.html`, `.step`, `.wrl`, `-top.png` / `-bottom.png` (after `make <part>-render`), `-erc.rpt`, `-drc.rpt` |
| altium | `<Board>_v<rev>.zip` (Gerbers and drill, or the ODB++ set), the pick and place, BOM (CSV, and xlsx when the OutJob writes one) and PDF files of `outputs/`; made with `make <part>-github-release FORCE=1` where the outputs are, not by CI (4.10) |
| mechanical | every `.step` and `.stl` of `outputs/`, and the `.FCStd` models |
| cloud-worker | none: the Release carries the CHANGELOG notes only. What a Worker releases is its production deploy, which the tag's job makes before the Release. The `latest` Release has nothing to copy for it |
| web-pages | none, as cloud-worker: the notes only, after the tag's production deploy |
| app-flutter | per PLATFORM (since v8): android `-android.apk` (linked), `.aab` and `-android-mapping.txt` (workflow artifact only); ios `-ios-dSYMs.zip` (the build number goes to the notes); macos `-macos-universal.zip`; linux-amd64 and linux-arm64 `-<platform>.tar.gz`; windows `-windows-x64.zip` (Flutter's arm64 Windows build needs an arm64 host: not built) |
| app-tauri | per PLATFORM (since v8): macos `-macos-universal.dmg` and `.app.zip`; linux-amd64 and linux-arm64 `-<platform>.deb`, `.rpm`, `.AppImage`; windows `-windows-x64.msi`, `-windows-x64.exe` and `-windows-arm64.exe`; ios `-ios-dSYMs.zip` (build number in the notes); android `-android.apk` (`.aab` workflow artifact only). Spaces in names become dashes, updater files are not released |
| app-xcode | per PLATFORM (since v8): ios or macos `-<platform>-dSYMs.zip` from the archive; for ios the TestFlight build number goes to the notes. The ipa is store-signed and goes to TestFlight only |
| app-android | `-android.apk` (one apk; ABI splits are refused), `.aab` and `-android-mapping.txt` (workflow artifact only), from `assembleRelease bundleRelease` |
| docker | `image.json`: registry, image, tag (the version), digest and platforms of the image the release pushed. The image stays in `ghcr.io/<owner>` |
| go | `<part>-<version>-<os>-<arch>` for `<part>_PLATFORMS` (default linux and darwin, amd64 and arm64) |
| python | the wheel and the sdist of the version (PyPI only with `make <part>-release PUBLISH=1 CONFIRM=production`) |

**Publishing stays manual, except where the tag is the step.** The GitHub Release is automatic on the tag; what reaches
a device or a store is not. In `release.yml` those jobs stay, each behind a `workflow_dispatch` run with `confirm` set to
`production`: firmware `<part>-release` (the OTA bucket) and the app `<part>-release` jobs (TestFlight, Play, the OTA
channel). Three kinds publish on the tag without a click, because pushing the tag (`make release-push`, which asks
first) is the deliberate step: a cloud-worker or web-pages part deploys production, then makes its Release; a docker
part's image goes to `ghcr.io/<owner>` (its release job pushes it); and a board's release is its GitHub Release. A cloud
part's `<part>-production` job in `release.yml` stays for a hotfix by hand (below).

## 5. Secrets

### Design

There is one private secrets repo per GitHub owner (1.8): the projects of one account or organization share its
`<owner>/secrets`, and a project of another owner never sees them. The secrets repo follows the project's owner, read
from its git remote `origin` (section 5.1). Files are encrypted with [sops](https://github.com/getsops/sops) and
[age](https://age-encryption.org); a value is plain text only inside the process that needs it.

```
~/.secrets-<owner>/    one per owner, for example ~/.secrets-fabrolabs-innovations, ~/.secrets-mayankgautam-me,
                       each laid out the same (before 1.8 the one repo was ~/.secrets: see 5.4):
  .sops.yaml                  generated from recipients/ by secrets.sh; never edit it by hand
  recipients/se/<host>.txt    a Mac's Secure Enclave key (public half)
  recipients/dev/<host>.txt   a Mac's dev key (public half)
  recipients/recovery.txt     the offline recovery key (public half)
  recipients/ci/<p>.txt       project p's CI key; <p>-production.txt its production CI key
  <project>/common.env.sops   dotenv, values encrypted, names readable (diffs make sense)
  <project>/local.env.sops
  <project>/staging.env.sops
  <project>/production.env.sops
  <project>/keys/<name>.sops  signing keys and other files (MCUboot, secure boot, .p8, Play JSON, SSH)
  .git/hooks/pre-commit       refuses anything that is not sops-encrypted outside recipients/ (rewritten before every commit;
                              never a tracked folder, and the repo's core.hooksPath is pinned to it)
```

### Who can decrypt what

| Files | Opened by |
|---|---|
| `common.env` | every Mac's Secure Enclave key and dev key, the recovery key, the project's CI key **and its production CI key** (a production deploy needs the account id in `common`) |
| `local.env` | every Mac's Secure Enclave key and dev key, the recovery key, the project's CI key |
| `staging.env`, `keys/*` | every Mac's Secure Enclave key, the recovery key, the project's CI key |
| `production.env` | every Mac's Secure Enclave key, the recovery key, the project's production CI key |

| Identity | Lives in | Unlock |
|---|---|---|
| Secure Enclave key, one per Mac (`age-plugin-se`, `--access-control=any-biometry`) | the Secure Enclave; `~/.config/project-standard/age/se.txt` is only a reference to it | Touch ID |
| Dev key, one per Mac | the login Keychain (`project-standard-age-dev`), handed to sops in its own process only | the login session: `make dev` never asks for a fingerprint |
| Recovery key | offline, printed, in your safe | used to enrol a Mac when no enrolled Mac is at hand |
| CI key per project | the repository secret `SOPS_AGE_KEY` of the project's GitHub repository, set by `make secrets-ci` from stdin (one secret: Free private repositories have no environment-scoped secrets) | the jobs that decrypt or sign: the staging deploy, the signing jobs and the production run |
| CI production key per project | the same secret: the production key is the same age key today (`recipients/ci/<p>-production.txt` holds the same public key) | the production run (`confirm` = `production`) and a cloud part's tag deploy |

A leaked CI key reaches staging and production, because the key is the same today. A stolen laptop without your
fingerprint still opens only local development values.

### 5.1 Which secrets repo a project uses

`make/common.mk` works it out once per `make` run (one `git remote get-url origin`, run only when the project root
holds `.git`):

1. The owner, `GITHUB_OWNER`: in GitHub Actions `GITHUB_REPOSITORY_OWNER` (or the owner part of `GITHUB_REPOSITORY`);
   else the owner of the remote `origin` when it is on github.com (`https://github.com/<owner>/<repo>[.git]`,
   `git@github.com:<owner>/<repo>[.git]`, `ssh://git@github.com/<owner>/<repo>`); else, with no GitHub origin yet,
   the user config's `GITHUB_OWNER` (`make doctor` says so). The user config's owner is the *default owner*.
2. `SECRETS_REMOTE`: `https://github.com/<owner>/secrets.git`. The user config's `SECRETS_REMOTE` is the default
   owner's repo (say, its SSH address): it applies only to that owner's projects, never to a project of another owner.
3. `SECRETS_DIR`: `~/.secrets-<owner>`, the same rule for every owner, the default owner included. The user config's
   `SECRETS_DIR` is used only for a project with no owner at all (no GitHub origin, no `GITHUB_OWNER`), else `~/.secrets`.

So a `fabrolabs-innovations` project uses `~/.secrets-fabrolabs-innovations` and the configured remote, and
`ai-trade`, whose origin is `github.com/mayankgautam-me/ai-trade`, uses `~/.secrets-mayankgautam-me`, cloned from
`https://github.com/mayankgautam-me/secrets.git`. A last-resort override for one project, in `make/project.mk`
(`?=`, so CI's own `SECRETS_DIR` in the environment still wins; `:=` would beat it):

```make
SECRETS_DIR    ?= $(HOME)/.secrets-vault
SECRETS_REMOTE ?= https://github.com/<owner>/vault.git
```

The environment and the command line win over all of this. `make ci-setup` puts the deploy key on the project's
secrets repo and sets the CI variable `SECRETS_REPO` to its `owner/name` (from `SECRETS_REMOTE`, which must be on
GitHub), so the CI jobs clone the same repo.

### 5.2 Starting the secrets repo of a new owner

Create the empty private repository once (`gh repo create <owner>/secrets --private`), then, in a project of that
owner (its origin set):

```bash
make secrets-init
```

When `SECRETS_DIR` does not exist yet and the remote is empty, `secrets-init` (and `secrets-enroll`) starts the repo:
it clones the empty remote into `SECRETS_DIR` (branch `main`, `origin` = `SECRETS_REMOTE`), installs the pre-commit
hook and pins `core.hooksPath`, copies from another secrets repo on this Mac (the default owner's
`~/.secrets-<owner>` first, else the first other `~/.secrets-*` with Mac recipients) the public recipients of every
Mac, `recipients/se/*.txt` and `recipients/dev/*.txt`, and `recipients/recovery.txt` (never the CI keys of its
projects, never a private key), generates `.sops.yaml`, commits "new secrets repo: the Macs and the recovery key" and
pushes. Then it creates the project's files as usual. It prints:

```
> new secrets repo at ~/.secrets-<owner> (origin https://github.com/<owner>/secrets.git)
ok copied 5 public recipient(s) from ~/.secrets-fabrolabs-innovations: Macs: mac-a mac-b; the recovery key
ok secrets repo ~/.secrets-<owner> started and pushed to https://github.com/<owner>/secrets.git
```

The recovery key is the same for every owner's repo. A remote that already has content is cloned as it is, with
nothing copied. A remote that cannot be cloned stops with what to do (create it, `gh auth status`). With no other
secrets repo on this Mac to copy from, it says to enroll this Mac in the new repo (`make secrets-enroll`, then
`make secrets-recovery` for a recovery key of its own).

### 5.3 Macs across several secrets repos

Each owner's repo has its own `recipients/`. The machine commands (`secrets-enroll`, `secrets-add-machine`,
`secrets-remove-machine`, `secrets-recovery`, `secrets-sync`) act on the project's `SECRETS_DIR`, so run them in a
project of the owner whose repo they should change. A Mac enrolled before a repo was started is in it already (its
recipients were copied). A Mac enrolled later is added to each repo by itself: `make secrets-enroll` in a project of
that owner reuses the Mac's Secure Enclave and Keychain keys and adds their public halves to that repo; then
`make secrets-add-machine HOST=<mac>` there on a Mac already in it. Retiring a Mac means `secrets-remove-machine` in a
project of every owner.

### 5.4 Moving the pre-1.8 `~/.secrets`

Before 1.8 the one secrets repo was `~/.secrets`; it is the default owner's, and its place is now
`~/.secrets-<owner>`. Nothing moves it for you. While `~/.secrets` exists and `~/.secrets-<owner>` does not, the
secrets commands of every project stop (they would otherwise clone a second checkout, or start a new repo with no Macs
to copy) and, like `make doctor`, print the commands, which you run once per Mac:

```bash
mv "$HOME/.secrets" "$HOME/.secrets-<owner>"
git -C "$HOME/.secrets-<owner>" config core.hooksPath "$HOME/.secrets-<owner>/.git/hooks"
```

The second line re-pins the pre-commit hook, whose path is absolute. The secrets commands also re-pin it on their
next run when it points elsewhere, so it is a belt-and-braces step. Nothing else in the repo holds its path; the
Secure Enclave reference (`~/.config/project-standard/age/se.txt`) and the Keychain key do not move.

### How a command gets its secrets

`make` wraps every recipe that needs secrets in `secrets.sh exec --env <ENV> -- <command>`: it
decrypts `common` and that env into the command's environment and `exec`s it. Nothing is written to
disk: not even the temp file bash 3.2 makes for a here-document, so no script feeds a value to a loop
that way. For `staging` and `production` only the names `secrets.schema` declares for that env (and for
`common`) are exported; any other name in the file is skipped with a warning, so a planted name cannot
reach a deploy. For every env a list of names is never exported (`PATH`, `HOME`, `TMPDIR`, `LD_*`,
`DYLD_*`, `BASH_ENV`, `NODE_OPTIONS`, `GIT_*`, `SSH_*`, `npm_config_*`, `PYTHON*`, `MAKEFLAGS`,
`CONFIRM`, `CF_SH_INNER`, `STD_*`, `SOPS_*` and the like), and a secret name may not start with `sops_`.
`secrets.sh get` decodes a value exactly as `exec` does: the two-character sequence backslash-n inside a
stored value becomes a newline in both, so a value that really contains a literal backslash-n cannot be
stored faithfully (multi-line values such as PEM text are what the encoding is for). Key files go through `secrets.sh with-file NAME -- cmd ... {}`: a mode-600 temp file in a
mode-700 folder, removed when the command exits. Before decrypting, the secrets repo is pulled
(`git pull --ff-only`, at most once an hour, silent offline).

### secrets.schema

Committed in every project. One line per secret:

```
# NAME                 envs                       used-by        gen   description
CLOUDFLARE_API_TOKEN   staging,production         auth,ci        no    the project's one token, see section 7
CLOUDFLARE_ACCOUNT_ID  common                     auth,ci        no    account id
JWT_SECRET             local,staging,production   cf             32    HMAC key for sessions
mcuboot                keys                       firmware       mcuboot-ecdsa-p256  MCUboot signing key
```

`envs`: `common`, `local`, `staging`, `production`, or `keys` for a key file. `used-by`: `cf` (a Worker
secret, pushed to Cloudflare by `cf-secrets`), `auth` (a credential the tooling uses, such as the
Cloudflare token; never pushed to a Worker, and `cf-secrets` also skips every `CLOUDFLARE_*` name),
`ci`, `local`, `firmware`, `app`. `gen`: `no`, a byte count for a
random value, or a key type.

A description that starts with `optional:` marks a value the project can do without (an app's signing and store
names: without them the build is unsigned or the upload is not possible, and the release helper says so). Missing,
it is a warning in `secrets-check` and `make doctor` (`optional, not set: NAME (env)`, `optional key not set: NAME`),
never a problem, and `secrets-list` shows it as `not set (optional)`; every other missing row is an error.

The scaffold writes the rows the project's parts use, and nothing for parts it does not have:

- `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`: with a cloud-worker or web-pages part, or when
  `make/project.mk` sets `OTA_BUCKET` (or a `<part>_OTA_BUCKET`) for the firmware or app OTA uploads to R2. An
  existing `secrets.schema` is kept; the scaffold says when it lacks the Cloudflare rows the project needs.
- The app kinds, all `optional:`, each written only for the kinds that read it:

| Row | envs | Written for | Read by |
|---|---|---|---|
| `APPLE_SIGNING_IDENTITY`, `APPLE_API_KEY`, `APPLE_API_ISSUER` | production | app-tauri | the Tauri macOS build (signing, notarisation) |
| `appstore-api-key` | keys | app-tauri, app-flutter, app-xcode | the App Store Connect upload of `<part>-release`; Tauri macOS notarisation (`APPLE_API_KEY_PATH`) |
| `play-service-account` | keys | app-tauri, app-flutter, app-android | the Play upload of `<part>-release` |
| `android-keystore`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | keys, production | app-android | its release build (`build.gradle.kts` reads them) |
| `windows-codesign`, `WINDOWS_CERT_PASSWORD` | keys, staging | app-tauri | `sign-windows.sh` in the CI Windows job |

app-xcode signs with Xcode's own settings and its App Store Connect key id and issuer are `<part>_ASC_KEY_ID` and
`<part>_ASC_ISSUER` in `make/project.mk`, so it gets `appstore-api-key` only. Flutter and Tauri Android are not signed
by the helper (4.12), so they get no keystore rows.

### Moving an existing key into the secrets repo

`secrets-keygen` creates new keys. To bring an existing key file in (adopt), import it; it is
encrypted straight from the file and committed, and no copy is made:

```sh
make secrets-import NAME=<name> FILE=/path/to/key.pem
```

`ENV=<env>` with a dotenv `FILE` imports its values into that environment instead (an old
`.dev.vars` or `.prod.vars`, say), refusing names that already exist.

An existing key, or an existing name in the environment, is refused; `FORCE=1` on the command line replaces it
(a rotated App Store Connect key, say). A key is encrypted into a temp file and moved over the old one, so a failed
encrypt leaves the old key as it was (1.11). `secrets-keygen` never replaces a key: devices and stores trust its
public half, so a deliberate replacement is a `secrets-import ... FORCE=1` of the new key.

Add its `keys` line to `secrets.schema`, `git rm --cached` the plain file in the project, and plan
a rotation: the old file stays in the project's git history.

### A new Mac

See section 8. In short: `make secrets-enroll` on the new Mac, then
`make secrets-add-machine HOST=<new>` on an enrolled one (or with the recovery key). Once per owner's secrets repo:
run both in a project of each owner (5.3).

### A lost or retired Mac

On an enrolled Mac, in a project of each owner (5.3): `make secrets-remove-machine HOST=<lost>`. It removes its public keys, re-encrypts
every file without them, and lists every value that Mac could read. Old ciphertext stays in git
history, so rotate those values (`make secrets-rotate NAME= ENV=`, then `make cf-secrets ENV=`)
and revoke its tokens.

### CI

`make secrets-ci` creates the project's CI age key, stores its private half as the GitHub Actions secret `SOPS_AGE_KEY`
of the project's repository (from stdin, never on a command line), adds the public half to `recipients/ci/` and
`.sops.yaml`, and re-encrypts. Every job that decrypts gets `SOPS_AGE_KEY` passed to it explicitly; dependency installs
(`make <part>-setup`) run with it unset. Each job reads the project's secrets repository (the variable `SECRETS_REPO`,
5.1) with `SECRETS_DEPLOY_KEY`, a read-only SSH deploy key (section 6). The same `make` wrapper decrypts. Set up once per project with `make ci-setup`.

## 6. CI/CD

The shared workflows live in one GitHub repository, `CI_TEMPLATES_REPO` (`owner/name`, default
`mayankgautam-me/ci-templates`), tagged `v1.12` (`v1.11`, `v1.10`, `v1.9`, `v1.8`, `v1.7`, `v1.6`, `v1.5`, `v1.4`, `v1.3`, `v1.2`, `v1.1` and `v1.0` stay for projects not updated yet). It is a setting of its
own, independent of the project's `GITHUB_OWNER`: projects of every owner call the same repository. It is read from `make/project.mk`, else the user config (section 9),
else the default. Each file is one kind, at `.github/workflows/<kind>.yml`, and a project calls it with
`uses: <CI_TEMPLATES_REPO>/.github/workflows/<kind>.yml@v1.13`. The steps only call `make`. The default repository is
public, so any repository can call it with no setting. Only a private `CI_TEMPLATES_REPO` needs, on that repository,
Settings > Actions > General > Access to allow the callers' repositories (`make ci-setup` warns when it is not public).
The audit reports a `uses:` line on another repository (such as the pre-1.7 `<owner>/ci-templates`) as outdated.

A project has two workflow files, written by `scaffold.sh` when they are missing (an existing file is kept):

- `checks.yml` runs on pushes and pull requests, and by hand. A `changes` job decides which parts run: a part runs only when
  its folder, `make/`, `Makefile`, `mise.toml` or `.github/workflows/` changed. Each part calls its kind's workflow for
  check and build.
- `release.yml` runs on a tag `<part>-v<version>` and runs only that part's check, build and release jobs (for a
  cloud-worker or web-pages part: and its production deploy, before the Release). Its manual run
  (`workflow_dispatch`) holds the production jobs, which need `confirm` = `production`.

| Job | When | Runs |
|---|---|---|
| check | a push or pull request that changed the part; a release tag | `make <part>-check` |
| build | the same | `make <part>-build`; artifacts kept 7 days |
| deploy-staging | a push to the default branch (cloud-worker, web-pages, docker; not a production-only part) | `make <part>-deploy ENV=staging`, then `test-remote` |
| deploy-production | cloud-worker, web-pages: the part's tag `<part>-v<version>`; or `release.yml` run by hand with part and `confirm` = `production` (a hotfix, on the ref chosen in the run) | `make <part>-deploy ENV=production CONFIRM=production`, with or without staging (CI does not promote) |
| production | other kinds: `release.yml` run by hand with `confirm` = `production` | the kind's production step: OTA upload, store publishing |
| release | a tag `<part>-v<version>` | `make <part>-github-release` (automatic: release files and the GitHub Release; a cloud part: the notes only, after deploy-production succeeded); `make <part>-release` (manual, behind `confirm`: OTA image, app stores) |

The flow of a cloud part: a push to `main` runs check and build, and deploys staging when the part has staging. Its tag
(`make <part>-bump`, then `make release-push`) runs check, build, the production deploy, then the Release with the
CHANGELOG notes; the `latest` job finds no files to copy. Production never deploys on a branch push. By hand:
`make <part>-deploy ENV=production CONFIRM=production` on a Mac, or `release.yml` from the Actions tab with the part and
`confirm` = `production` (no Release; `promote` stays a Mac command for a part with staging).

**Production gate.** Free private repositories have no environment protection rules, so the production, store and OTA
jobs are gated by the `confirm` input, which must equal `production`. It mirrors `CONFIRM=`: without it those jobs are
skipped, and no workflow publishes on a branch push. Only someone with write access can start the run or push a tag.
A cloud part's tag job in `release.yml` passes `confirm: production` itself: the tag push replaces `CONFIRM=production`.
The reusable workflow also refuses a production deploy outside a tag or a manual run, and its release job needs the
deploy to have succeeded, so a tag job without `confirm: production` deploys nothing and makes no Release (the audit
warns about such a `release.yml`). The production secrets (`SOPS_AGE_KEY`, `SECRETS_DEPLOY_KEY` and, through them, the
Cloudflare token in `production.env`) reach that deploy job only; its token only reads the repository, and one
production deploy of a part runs at a time.

**Tags.** `release.yml` starts with a `tag` job that takes the part from the tag (everything before the last `-v`, so
`app-viewer-v1.0` is `app-viewer`). A release job needs it and runs only when `needs.tag.outputs.part` is its own part,
an exact comparison. The make target refuses a tag that does not match the part's version. `checks.yml` does not repeat
that work for the tag.

**The 1.1 kinds.** `silabs.yml` runs check, build, release and the OTA publish like the other firmware kinds, on the
runner itself (no image): `<part>-setup` installs the pinned slt, slc, the Simplicity SDK, WiseConnect and (1.3)
Simplicity Commander (about 2 GB), kept in the Actions cache per version and saved right after setup (a cache saved
before Commander was in it gets Commander from that setup, which installs it when none is found); Commander is needed to
build a `.slcp` with a `post_build` (it makes the `.rps`, 4.9; check skips the post-build without it) and for `SIGN=1`. `mechanical.yml` runs check, build (STEP and STL, kept 7 days) and release,
with Ubuntu 24.04's FreeCAD. `altium.yml` runs the check only, on the LFS pointers, with the shared Altium library
checked out at its pinned commit when `ALTIUM_LIBRARY_REPO` is set (1.4): `checks.yml` has a job for an
altium part and `release.yml` none, and its `run_build` and `run_release` do nothing (4.10, Altium). `hardware.yml`
takes `library: shared` (default) or `local`: with `local` it checks out no KiCad library (4.10). A project whose only
parts are altium has no `latest` job in `release.yml`.

A production-only part (section 4.5) has no deploy-staging job: a push to main deploys nothing for it, and its tag
deploys production like any cloud part. The caller passes `production_only: true`, and `scaffold.sh` sets it for the parts named with `--production-only` and for cloud-worker and
web-pages parts whose `wrangler.jsonc` has no `env.staging`.

Workflows use `if:` and `workflow_call` inputs, with no `only:` or `except:`. Images are pinned by tag or digest in the
templates. `test-device` needs a self-hosted runner with a board attached and is optional; hosted runners never run it.
A push cancels the superseded run of the same branch in `checks.yml`.

Project-wide settings are repository variables, set once with `gh variable set --repo <owner>/<project>`, not repeated
on each job:

- `SECRETS_REPO` = `<owner>/secrets`: the project's secrets repository (section 5.1; `make ci-setup` sets it from
  `SECRETS_REMOTE`), checked out sparsely (the project's folder and
  `recipients`) beside the project; `SECRETS_DIR` points there.
- `KICAD_LIBRARY_REPO` = `<owner>/kicad-library`: the shared KiCad library for the hardware jobs (3D models only, see
  Limits and billing). `make ci-setup` sets it from `KICAD_LIBRARY_PROJECT` (section 9), and not at all when every
  hardware part has its own library (`<part>_LIBRARY := local`).
- `ALTIUM_LIBRARY_REPO` = `<owner>/altium-library`: the shared Altium library, checked out by the altium jobs at the
  commit the project's submodule pins (4.10). `make ci-setup` sets it from `ALTIUM_LIBRARY_PROJECT` when the project
  has an altium part.
- `STD_APT_PACKAGES`: extra Debian packages for every apt install, e.g. `libudev-dev` for the `hidapi` crate.
- `STD_RUNNER`: the runner label for every Linux job (default `ubuntu-24.04`, GitHub's). Set it on the organization to
  a self-hosted runner's label (a Linux machine with Docker, amd64, since the jobs run amd64 containers) and every
  project's CI runs there; unset it to go back to GitHub's runners.
- `STD_RUNNER_LINUX_ARM`: the runner label of the linux-arm64 release jobs (default `ubuntu-24.04-arm`): an arm64
  Linux runner with Docker.
- `STD_RUNNER_MACOS`: the runner label of the macOS jobs (default `macos-latest`): a self-hosted Mac with Xcode. They
  still run only when `MACOS_CI` is `true`.
- `STD_RUNNER_WINDOWS`: the runner label for app-tauri's Windows jobs (x64 and arm64; defaults `windows-2025` and
  `windows-11-arm`). Set it to a self-hosted Windows 11 runner's label (an ARM VM builds x64 under emulation).
- `MACOS_CI` = `true`: enables the macOS jobs. Unset, they are skipped, because macOS minutes are the most expensive.

**Keys.** The jobs read the secrets repository and, with a hardware part, the KiCad library (with an altium part, the
Altium library) with read-only SSH deploy keys, one per repository. `make ci-setup` creates and stores them (`make ci-setup-help` prints the same steps as commands). The public key goes
to the other repository with `gh repo deploy-key add` (without `--allow-write`), and the private key is stored as the
project's secret `SECRETS_DEPLOY_KEY` (or `KICAD_LIBRARY_DEPLOY_KEY`, `ALTIUM_LIBRARY_DEPLOY_KEY`). Values reach `gh` on stdin, never on a command line.

**Actions.** Only `actions/*` is used, each pinned by full commit SHA with a version comment: `actions/checkout` v7.0.1
(`3d3c42e5aac5ba805825da76410c181273ba90b1`), `actions/upload-artifact` v7.0.2
(`cf430e030ddbb5b0abf93d22962f4752f3646cd9`), `actions/download-artifact` v8.0.2
(`9000827ccba6bdab643e8b6fd33ac0654aef8333`), and `actions/cache` v6.1.0
(`55cc8345863c7cc4c66a329aec7e433d2d1c52a9`) for the caches.

`make ci-local JOB=<job>` runs a job on the Mac before pushing (section 4.8). It is partial: act fetches the reusable
workflows from the public `CI_TEMPLATES_REPO` with no token, but some of their steps (macOS runners, GitHub API calls)
may not run locally.

### Limits and billing

Personal Free account. Sources: GitHub's billing pages for Actions
(https://docs.github.com/en/billing/concepts/product-billing/github-actions) and Git LFS
(https://docs.github.com/en/billing/concepts/product-billing/git-lfs), read on 2026-11-11.

- **Actions compute.** GitHub states the included usage as $12 a month. The page gives per-minute rates in USD: Linux 1-core $0.002, Linux 2-core $0.006, Linux 2-core arm64 $0.005, Windows 2-core $0.010, Windows 2-core arm64 $0.010, macOS 3- or 4-core $0.062. It states no runner multipliers.
- **Git LFS.** 10 GiB of storage and 10 GiB of bandwidth a month. Downloads by Actions count against bandwidth. Past the
  bandwidth limit, with no payment method, LFS is disabled until next month; past the storage limit, new LFS files
  cannot be pushed.
- **Artifacts and Packages**: 500 MB on Free, as the coordinator states. Neither page mentions it: unverified here.
- **Cache**: 10 GB per repository, as the coordinator states. Unverified here.
- **Runners.** `ubuntu-24.04-arm` and `windows-11-arm` are listed among the standard runners for private repositories
  (https://docs.github.com/en/actions/reference/runners/github-hosted-runners). That page states no plan limit for them;
  re-check on a real run before relying on them.

Design consequences:

- `kicad-library` holds about 614 MB of LFS in 394 objects. Hardware jobs must not pull all of it. Check (ERC and DRC)
  needs no LFS. Build and release fetch only the 3D models (`git lfs pull --include`), cached by the library commit.
- Keep artifacts short-lived: build artifacts 7 days, store bundles of the app workflows 7 days. Download them promptly.
- Concurrency cancels superseded push runs, and a tag does not repeat the work of `checks.yml`.
- macOS jobs are gated by `MACOS_CI`, because their minutes are the most expensive.

### Known gaps

- Caches (actions/cache): Cargo registry and target directory, pnpm store, PlatformIO packages, pub and Gradle caches, and the kicad-library and altium-library LFS objects keyed on the library commit. Each `hashFiles` key is worked out in a `Get the ... cache key before anything builds` step and reaches the cache step as `steps.<id>.outputs.key`: actions/cache evaluates its inputs again in its post step, after the build, where a `hashFiles` over the part folder failed on files the build left unreadable and failed a passing job. GitHub evicts caches past 10 GB per repository, so the library cache can churn when the library changes often.
- Real workflow runs are not yet verified on GitHub. The arm64 Windows image's Visual Studio components need a real run.

## 7. Cloudflare API token permissions

One token per project, named `<project>`, an account API token scoped to the one account and only the
zones the project uses, with an expiry. `make cf-login` creates the request for it:

1. It reads the `wrangler.jsonc` of every cloud-worker and web-pages part in `PARTS` (the top level and every env block;
   one token serves them all) and adds the rows of the table below the bindings need: D1, KV, R2 and
   Queues by binding, Pages for a web-pages part, Workers Routes and DNS when there are `routes` or custom
   domains. Account Settings Read and Workers Scripts Edit are always in. Workers Tail is not asked for:
   `wrangler tail` (`make logs`) works with Workers Scripts Edit on an account token (verified 2026-11-12).
   An OTA bucket (`OTA_BUCKET` or a `<part>_OTA_BUCKET` in `make/project.mk`, for the firmware and app OTA uploads,
   `wrangler r2 object put`) adds Workers R2 Storage Edit. A project whose only Cloudflare use is that bucket (no
   cloud-worker or web-pages part) is still a Cloudflare project: `cf-login`, `cf-token-check` and `make help` treat
   it as one, its token needs Account Settings Read and Workers R2 Storage Edit only (no Workers Scripts), and the
   scaffold writes its `CLOUDFLARE_*` rows in `secrets.schema`, which `make doctor` then checks. `cf-provision`
   creates the bucket with that token (Workers R2 Storage Edit also covers the r2.dev URL of `OTA_PUBLIC`).
2. It prints a dashboard URL, the list of permissions, and the zones to pick for the zone permissions (a
   route's `zone_name`, else the last two labels of its hostname), and opens the URL with `open` on macOS
   or `xdg-open` elsewhere (`CF_NO_BROWSER=1` prints it only). The URL is Cloudflare's account-owned token
   template (https://developers.cloudflare.com/fundamentals/api/how-to/account-owned-token-template/):
   `https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=<URL-encoded JSON>&name=<project>`,
   which opens **Manage Account > Account API Tokens > Create Token** filled in. The permissions use the
   short keys from that page's table (`account_settings`, `workers_scripts`, `d1`, `workers_kv_storage`,
   `workers_r2`, `queues`, `page`, `workers_routes`, `dns`); permission group IDs would also work but are
   published only by an API that needs a token. The URL cannot preset zones: account token template URLs
   take no account or zone parameter, and resources are chosen in the form.
3. In the form: pick the account; under the resources of the zone permissions (Workers Routes, DNS) choose
   **Specific zone** and pick the printed zones; set an expiry; create. Paste the token at the hidden prompt.
   The account id, when asked, is the 32 hex characters after `dash.cloudflare.com/` in the address bar;
   Enter looks it up from the token (for an account-owned `cfat_` token, the account under which it verifies).
4. It verifies the token, stores it for staging and production and the account id in `common`, then runs
   the probes of `make cf-token-check` with it and names any permission it cannot reach (exit 1; the token
   stays stored, so add the permission in the dashboard and run `make cf-token-check`). The zone
   permissions are not probed.

With `CLOUDFLARE_API_TOKEN` in the environment (a script, CI) `cf-login` takes that token without the form
or a prompt; without a terminal it reads the token, then the account id, from stdin. It never runs
`wrangler login` and never prints the token. `bash make/bin/cf.sh token-url` prints the URL and the
permission list alone. A user token (**My Profile > API Tokens**) with the same permissions works as well.

Why one token and not one per environment: Cloudflare permissions are granted per account (or per zone)
and per resource type, never per resource name. A staging token with D1 Edit can edit the production
database as well, so a token per environment never kept staging away from production resources; it only
doubled the tokens to create, rotate and expire. What keeps a staging command off production data is the
env block in `wrangler.jsonc`, the `<project>-<env>` names that wipe and destroy check, and `CONFIRM`.
Where staging and production must really be separated, put them in separate Cloudflare accounts. CI holds
the token twice (one copy in each environment's file, each opened by its own CI key), which changes nothing
about what it can reach.

Add the rows for the bindings the project's `wrangler.jsonc` files use. The dashboard shows the
"Edit" names; the API and some docs call the same groups "Write".

| Needed for | Scope | Permission (dashboard) | API name |
|---|---|---|---|
| every token: account lookup for `cf-login`, `cf-whoami` | Account | Account Settings: Read | Account Settings Read |
| Workers: deploy, versions, secrets, Durable Objects | Account | Workers Scripts: Edit | Workers Scripts Write |
| `make logs` on a deployed Worker (`wrangler tail`), user tokens only, optional | Account | Workers Tail: Read | Workers Tail Read |
| D1 | Account | D1: Edit | D1 Write |
| KV | Account | Workers KV Storage: Edit | Workers KV Storage Write |
| R2 (buckets, CORS, objects, backups; the OTA bucket of `OTA_BUCKET`) | Account | Workers R2 Storage: Edit | Workers R2 Storage Write |
| Queues | Account | Queues: Edit | Queues Write |
| Pages | Account | Cloudflare Pages: Edit | Pages Write |
| Routes and custom domains of a Worker | Zone (each zone) | Workers Routes: Edit | Workers Routes Write |
| DNS records | Zone (each zone) | DNS: Edit | DNS Write |
| Access applications and policies, only with `CF_TOKEN_PERMS := access` | Account | Access: Apps and Policies: Edit (add by hand: the form cannot preset it) | Access: Apps and Policies Write |
| Access service tokens, with `CF_TOKEN_PERMS := access` (v37) | Account | Access: Service Tokens: Edit (add by hand) | Access: Service Tokens Write |
| The Zero Trust organization (its team domain), with `CF_TOKEN_PERMS := access` (v38) | Account | Access: Organizations, Identity Providers, and Groups: Read (add by hand) | Access: Organizations, Identity Providers, and Groups Read |
| Realtime (a TURN app the project creates), only with `CF_TOKEN_PERMS := realtime` | Account | Cloudflare Realtime: Edit (add by hand: the form cannot preset it) | Realtime Write |

Notes:

- A permission no binding shows goes in `make/project.mk` as `CF_TOKEN_PERMS := realtime access` (space-separated):
  `realtime` for a TURN app, `access` for an Access application the project makes and edits from make (the application, its policies and its
  service token: Access: Apps and Policies and Access: Service Tokens, both Edit; and Access: Organizations, Identity
  Providers, and Groups, Read, for the team domain).
  `cf-login` lists them with the permissions to pick (neither has a short key the pre-filled form accepts, so they are
  added by hand), and `cf-token-check` probes them. The project keeps one token: never a second token for Access.
  `make <part>-access` (1.7, section 4.5) is what uses the three Access permissions: it refuses to run until
  `CF_TOKEN_PERMS` names `access`, and a token without them stops at the first call with the names to add.
- Binding a resource in a Worker needs only Workers Scripts; the resource's own permission is needed
  to create it (`cf-provision`), migrate or seed it, back it up or read it.
- Cloudflare is moving Workers permissions to roles ("Editor at the Workers product scope" replaces
  Workers Scripts Edit); the legacy groups keep working.
- Containers, Hyperdrive, Vectorize and Workers AI have their own groups; they are not covered here
  yet, check the permissions reference before using them.
- An account-owned token is verified at `/accounts/<id>/tokens/verify`, a user token at
  `/user/tokens/verify`; `cf-login`, `cf-whoami` and `cf-token-check` try both. With no account id,
  `cf-login` lists the accounts the token sees (`GET /accounts`) and verifies an account token under each.
- `wrangler tail` works with Workers Scripts: Edit on an account token, without Workers Tail: Read (verified
  2026-11-12), so `cf-login` does not ask for Workers Tail.

Sources: Cloudflare's API token permissions reference
(https://developers.cloudflare.com/fundamentals/api/reference/permissions/), Workers roles and
permissions (https://developers.cloudflare.com/workers/authorization/workers/), R2 token
permissions (https://developers.cloudflare.com/r2/api/tokens/), the Workers Builds token
(https://developers.cloudflare.com/workers/ci-cd/builds/configuration/) and creating a token
(https://developers.cloudflare.com/fundamentals/api/get-started/create-token/).

## 8. First time on a new Mac

1. Install Homebrew, then set up `~/.claude` (`bootstrap.sh`), which installs the base tools.
2. Write `~/.config/project-standard/config.mk` (section 9). It holds the address of your secrets
   repo and is never committed anywhere.
3. Sign in to GitHub: `gh auth login`, and make sure `git clone` of the secrets repo works over SSH.
4. In any standard project: `make setup` (installs sops, age, age-plugin-se and the project's tools).
5. `make secrets-enroll`: clones the project's secrets repo (5.1; `~/.secrets-<owner>`), creates this Mac's Secure Enclave
   key (Touch ID prompt) and dev key (Keychain), commits their public halves and prints the command
   for the next step.
   On the very first Mac there is nothing else to do here, except step 5a.
5a. First Mac only: `make secrets-recovery` (or `secrets.sh recovery` outside a project). It shows
   the recovery key once, in the terminal, and stores only its public half. Write it on paper and keep
   it in a safe, then clear the terminal's scrollback. The Secure Enclave key cannot be exported, so
   without this key a lost Mac means every secret is lost.
6. On a Mac that is already enrolled: `make secrets-add-machine HOST=<new-mac>`. It re-encrypts every
   file to the new Mac and pushes. No enrolled Mac at hand: do the same with the recovery key
   (`SOPS_AGE_KEY` from the printed copy, in that one shell only).
6b. Projects of other owners: steps 5 and 6 again in one project of each owner (5.3).
7. Back on the new Mac: `make doctor` in each project. Firmware SDKs install on the first `make setup`
   of a project that pins them.

## 9. Per-user configuration

`~/.config/project-standard/config.mk` (private, per machine; copy it between your Macs):

```make
SECRETS_REMOTE        := git@github.com:<owner>/secrets.git   (optional: the default owner's secrets repo)
GITHUB_OWNER          := <owner>                              (the default owner)
# CI_TEMPLATES_REPO   := mayankgautam-me/ci-templates   (the default; set it only for another repository)
DOCKER_REGISTRY       := ghcr.io/<owner>                      (optional: the default owner's registry)
KICAD_LIBRARY_DIR     := <your kicad-library checkout>
KICAD_LIBRARY_PROJECT := <owner>/kicad-library                (optional: the default is <owner>/kicad-library)
ALTIUM_LIBRARY_PROJECT := <owner>/altium-library             (optional: the default is <owner>/altium-library)
FREECADCMD            := <path to freecadcmd>                 (optional: when it is not found by itself)
```

`GITHUB_OWNER` is the default owner: the GitHub account (a personal account or an organization) of a project that has
no GitHub `origin` yet. A project's own owner comes from its `origin` (5.1), and its repository, releases and secrets
repository follow that owner. `SECRETS_REMOTE` here is the default owner's secrets repo (default
`https://github.com/<owner>/secrets.git`); a project of another owner uses `https://github.com/<its owner>/secrets.git`
and never this one. Every owner's checkout is `~/.secrets-<owner>`; `SECRETS_DIR` here applies only to a project with no
owner at all. Write all three with `:=` (common.mk reads this file's own values apart from the project's). `GITLAB_GROUP` is ignored since v9.

`CI_TEMPLATES_REPO` (`owner/name`) is the repository of the reusable workflows (section 6), independent of
`GITHUB_OWNER`; default `mayankgautam-me/ci-templates`, public. A project can set its own in `make/project.mk`, which
wins over this file; scaffold the workflows again after changing it. `CI_TEMPLATES_PROJECT` (before 1.7, default
`<owner>/ci-templates`) is ignored, and the scaffold and the audit warn while it is set.

`DOCKER_REGISTRY` follows the project's owner like the secrets repo (since 1.1). It is, in order: the value in
`make/project.mk` or the environment; this file's, only when the project's owner is this file's `GITHUB_OWNER` (it never
reaches another owner's project); else `ghcr.io/<owner>`, the owner in lowercase (ghcr.io refuses capitals). `make
<part>-doctor` of a docker part says where it came from. The repository of the project's `origin` (`STD_ORIGIN_REPO`,
read with its owner from the same `git remote get-url origin`) names the images' source label (4.11).

`KICAD_LIBRARY_DIR` is optional: without it the hardware kind uses the library KiCad already points at (its
`FABROLABS_LIB_DIR` path variable, or `<KICAD_LIB_PREFIX>_LIB_DIR`), and `make <part>-doctor` says which one it
found. `KICAD_LIBRARY_PROJECT` (`owner/name`) is the GitHub repository of the shared KiCad library. It is, in order:
the value in `make/project.mk`; this file's (or the environment's); else `<owner>/kicad-library` of the project's
owner. `make ci-setup` adds the KiCad deploy key to it and sets the CI variable `KICAD_LIBRARY_REPO` from it, for a
project with a hardware part that uses the shared library (none when every hardware part is `<part>_LIBRARY := local`);
the hardware doctor prints it.

`ALTIUM_LIBRARY_PROJECT` (`owner/name`, since 1.4) is the shared Altium library, read the same way: `make/project.mk`,
else this file's (or the environment's), else `<owner>/altium-library`. An altium part's setup adds it as the submodule
`ALTIUM_LIBRARY`, `make ci-setup` adds the Altium deploy key to it and sets `ALTIUM_LIBRARY_REPO`, and the altium doctor
prints it (4.10).

`OTA_BUCKET` is not a per-user setting (since v6): it is the project's, `OTA_BUCKET := <bucket>` in
`make/project.mk` (the scaffold leaves a commented line for the kinds that release OTA). Each project has its own
Cloudflare token and maybe its own account, and CI reads `make/project.mk` but never this file. A value left in
`config.mk` is ignored, with a warning. `make cf-provision ENV=production CONFIRM=production` (or `ENV=staging`)
creates the bucket, and every `<part>_OTA_BUCKET`, when missing; with no cloud-worker or web-pages part it runs
`npx --yes wrangler@4` from the project root (the wrangler the firmware releases upload with), else the first such
part's installed wrangler in its dir. The bucket is private unless `make/project.mk` sets `OTA_PUBLIC := r2dev`:
then `cf-provision` turns on its public r2.dev URL (`wrangler r2 bucket dev-url enable`) and prints it, the URL the
apps download firmware from (`<part>_OTA_URL`). r2.dev is rate-limited and meant for development; a custom domain
on the bucket is the production choice and is set in the dashboard. `cf-provision` never turns a URL off, and
`cf-wipe`/`cf-destroy` never touch the bucket.

Overrides for one shell: `STD_TOOLCHAINS` (default `~/.toolchains`), `SECRETS_DIR` and `SECRETS_REMOTE` (default:
the project's owner's, 5.1), `STD_CONFIG` (default `~/.config/project-standard`). `SECRETS_DEFAULT_DIR` (default
`~/.secrets-<the config's owner>`) is where a new secrets repo first looks for the Macs' recipients (5.2).

## 10. Versions

Each version is a tag of `CI_TEMPLATES_REPO` (`mayankgautam-me/ci-templates`) and the number in a project's `make/VERSION`, its managed
headers and the `@v<n>` of its workflows' `uses:` lines. A published tag is never moved; a change ships as the next version, and
the skill's update mode brings a project to it.

- **1.13** (2026-11-26): espidf images are signed whenever their signature does not verify with the project's key.
  `make/VERSION`, the managed headers and the workflows' `@v1.13` say 1.13; `mayankgautam-me/ci-templates` gets the tag
  `v1.13` (its workflows change only in the version) and keeps `v1.12` to `v1.0`.
  - What happened: an OTA to a secure-boot ESP32-C6 failed at `esp_ota_end`. The build skipped signing any image that
    `espsecure signature_info_v2` accepted, and from esptool 4.x that command exits 0 for an image with no signature
    block, so every app and bootloader image went out unsigned.
  - `espidf_sign` leaves an image alone only when `espsecure verify_signature --version 2` passes with the signing key;
    anything else is signed, and the build stops unless every image verifies afterwards.
  - Update from 1.12: refresh the managed files and move the `uses:` lines to `@v1.13`. Rebuild every espidf part with
    secure boot on (the next `make <part>-build` signs again); images built and released since the esptool change are
    unsigned and should be replaced, not promoted.

- **1.12** (2026-11-25): one firmware build per folder, images checked before use. `make/VERSION`, the managed headers
  and the workflows' `@v1.12` say 1.12; `mayankgautam-me/ci-templates` gets the tag `v1.12` (its workflows change only
  in the version) and keeps `v1.11` to `v1.0`.
  - What happened: `make <part>-release ENV=staging` and `ENV=production` ran at once on one espidf build folder. The
    staging run wiped it and rebuilt it with its `CLOUD_URL` while the production run built there; production has no
    `_ENV_DEFINES_production`, so its idf.py run passed no `STD_ENV_DEFINES`, kept staging's from the CMake cache,
    stamped the folder `env=production` and uploaded staging's image.
  - The defines reach the build on every build, an empty set too: espidf `-D STD_ENV_DEFINES=` (when the
    `CMakeLists.txt` applies it), zephyr `-D<APP>_EXTRA_CPPFLAGS=`. A build folder that holds files but no `std-env`
    stamp is made again from scratch (a CMake cache in it may hold any defines). arm-gcc (`STD_ENV_CFLAGS`, always
    exported), silabs (`CC` on the make line) and pio (`PLATFORMIO_BUILD_FLAGS`) already passed theirs on every build;
    what their compiled objects or an arm-gcc CMake cache keep is handled by the stamp, as before.
  - Every build, flash and release of zephyr, espidf, pio, arm-gcc and silabs holds a lock on its build folder
    (`std_fw_lock`; a directory in `TMPDIR` with the holder's pid): a second run waits `STD_FW_LOCK_WAIT` seconds
    (10), then stops naming the other run's pid and target. A lock whose pid is gone is taken over.
  - The build records the sha256 of its images in `<build dir>/std-env.sha256` (removed when a build starts, written
    when it ends); flash and release check them, and the release the image it uploads, right before use.
    `std_fw_image_check` gives a project's own OTA or upload target the same check (4.9).
  Update from 1.11: refresh the managed files and move the `uses:` lines to `@v1.12`. A project with its own OTA or
  upload target in `make/local.mk` calls `std_fw_image_check` in its upload line (4.9). The first build of each folder
  after the update is made from scratch when the folder has no stamp; a `NOBUILD=1` release of a build made by 1.11
  is refused until it is built again.

- **1.11** (2026-11-25): secrets fixes. `make/VERSION`, the managed headers and the workflows' `@v1.11` say 1.11;
  `mayankgautam-me/ci-templates` gets the tag `v1.11` (its workflows change only in the version) and keeps `v1.10` to
  `v1.0`.
  - `make secrets-import NAME=<key> FILE=<path> FORCE=1` replaces an existing key (a rotated App Store Connect key):
    the new key is encrypted into a temp file and moved over the old one, so a failed encrypt leaves the old key whole.
    Without `FORCE=1` it is refused, and the error says that `FORCE=1` replaces it. `FORCE` counts only on the command
    line and only as `1`, as for the other targets (before, any `FORCE` from anywhere passed `--force`).
    `secrets-keygen` still never replaces a key: devices and stores trust its public half; its error points at the
    import.
  - `make secrets-list` no longer lists names that are in the schema a second time as `not in schema`. The check ran
    `schema_rows | grep -q` under `pipefail`: grep stops at the first match, `schema_rows` then died of SIGPIPE and the
    pipeline counted as no match. The schema's names are now read once. The same race is gone from the secrets repo's
    pre-commit hook (a large key could be refused as not encrypted), `secrets-rotate`'s schema lookup (could stop
    without a message), cf.sh's declared-resource checks, the LFS pointer check of `make hooks`, ghcr.sh, release.sh,
    toolchain.sh, the audit, the android-sdk and deploy-key checks of common.mk, docker's `--annotation` probe and
    zephyr's probe check. They use `grep -c` (it reads all its input) through the new `has_match TEXT GREP-ARGS` of
    lib.sh, never a here-string (bash 3.2 backs those with a file); `| head -n 1` after a command is `| sed -n 1p` and
    awk no longer exits early. A `printf` of one short value into grep cannot race and is left as it was.
  Update from 1.10: refresh the managed files and move the `uses:` lines to `@v1.11`. Nothing else changes.

- **1.10** (2026-11-25): store uploads from CI, a deploy that builds only what it deploys. `make/VERSION`, the managed
  headers and the workflows' `@v1.10` say 1.10; `mayankgautam-me/ci-templates` gets the tag `v1.10` and keeps `v1.9` to
  `v1.0`.
  - `make deploy` runs `check` and `build` only for the parts whose kind deploys (cloud-worker, web-pages, docker), then
    deploys them and runs `smoke`; firmware, apps and boards are no longer built for a deploy. The root `check` and
    `build` still run (with the internal `STD_ONLY=` list), so prerequisites `make/local.mk` adds to them still run;
    `PART=` and the production guard are as before. `make check` and `make build` alone still cover every part.
  - app-flutter store uploads on the part's tag, opt-in with `<part>_STORE := android ios` (or one): the scaffold writes
    `store:` and `confirm: production` on the tag job. `store-android` (Linux) builds the bundle and uploads it with
    `fastlane supply` to the Play **internal** track; `store-ios` (a GitHub-hosted macOS runner, `STD_RUNNER_MACOS`
    when set; gated by its input, not `MACOS_CI`) archives, signs and uploads to **TestFlight**. Nothing is released
    publicly or sent for review. The manual `publish` job runs only from a dispatch, not on a tag.
  - `make <part>-release` (the same command on a Mac and in CI): `TARGET=appbundle` signs with
    `keys/android-upload-keystore` when the secrets hold it (`ANDROID_KEYSTORE_FILE` and the production values
    `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` in the build's environment, for
    `build.gradle(.kts)`) and skips the metadata, changelog, image and screenshot uploads; `TARGET=ios` runs
    `flutter build ios --config-only` and then `make/bin/store-ios.sh` (new managed file): `xcodebuild archive` and
    `-exportArchive` with `-allowProvisioningUpdates` and the App Store Connect key, so Xcode's automatic signing
    creates the certificate and profile (no manual certificates on the runner; the key needs the Admin role), then
    `altool --upload-app`. `ios/ExportOptions.plist` is used when it exists, else app-store-connect with automatic
    signing. `<part>_STORE_ARGS` adds flutter build arguments to both store builds (dart-defines), read when the
    recipe runs, so `make/local.mk` can set it.
  - `make <part>-android-sdk` (app-flutter, app-android): installs `<part>_ANDROID_PACKAGES` (default
    `platform-tools`) into `ANDROID_HOME` (else `~/Library/Android/sdk` on a Mac) with the `android` CLI of
    cmdline-tools (`android sdk install`, slash names) and falls back to the deprecated `sdkmanager` (`;` names); either
    spelling is accepted. app-flutter then points `flutter config --android-sdk` at it.
  - hardware: on macOS every kicad-cli call runs with `FONTCONFIG_FILE` set to a minimal config of the system and user
    font folders (`$TMPDIR/project-standard-kicad-fonts.conf`), so KiCad's bundled fontconfig no longer reads
    Homebrew's newer `conf.d` and prints about 45 `Fontconfig warning` lines per ERC and DRC. Nothing is filtered; a
    `FONTCONFIG_FILE` in the environment wins.
  - The scaffold writes `android-upload-keystore` and the `ANDROID_KEY*` rows into `secrets.schema` for app-flutter;
    `make audit` warns when `<part>_STORE` is set and the tag job does not pass it with `confirm: production`.
  Update from 1.9: refresh the managed files (with `make/bin/store-ios.sh`) and move the `uses:` lines to `@v1.10`.
  Store uploads stay off until a project sets `<part>_STORE` and the job's `store:` and `confirm: production`.

- **1.9** (2026-11-24): app-flutter builds on the project's Flutter and checks only its own Dart files. `make/VERSION`,
  the managed headers and the workflows' `@v1.9` say 1.9; `mayankgautam-me/ci-templates` gets the tag `v1.9` and keeps
  `v1.8` to `v1.0`.
  - CI: the app-flutter workflow runs on the runner, not in `ghcr.io/cirruslabs/flutter:3.44.0` (no newer image is
    published, so a Flutter 3.50 / Dart 3.14 part failed `pub get`). Each job installs Flutter with
    `subosito/flutter-action` (pinned by commit SHA) at the new input `flutter_version`, which the scaffold writes from
    `<part>_FLUTTER_VERSION` in `make/project.mk`; without it, the part's `.fvmrc`, else the latest stable. Linux arm64
    has no Flutter archive, so there it comes from git at the release tag. build and publish use the runner's Android
    SDK, or `android-actions/setup-android` on a runner without one.
  - `make <part>-check` and `<part>-format` format the part's own Dart files (git: tracked and new, not ignored;
    outside git: all but `build/` and `.dart_tool/`), not `.`: the generated Dart under `build/` (an iOS build's
    `SourcePackages`) failed the check on a clean tree.
  - `make audit` warns when `<part>_FLUTTER_VERSION` is set and a job of the part in `checks.yml` or `release.yml`
    does not pass it as `flutter_version`.
  Update from 1.8: refresh the managed files and move the `uses:` lines to `@v1.9`. A Flutter part sets
  `<part>_FLUTTER_VERSION := <x.y.z>` (its `flutter --version`) and gets `flutter_version: '<x.y.z>'` on its jobs in
  `checks.yml` and `release.yml` (by hand, or `scaffold.sh` on a new workflow file).

- **1.8** (2026-11-24): a firmware build for an environment. `make/VERSION`, the managed headers and the workflows'
  `@v1.8` say 1.8; `mayankgautam-me/ci-templates` gets the tag `v1.8` and keeps `v1.7` to `v1.0`.
  - `<part>_ENV_DEFINES_<env> := NAME=value NAME2="a string"` in `make/project.mk` (env `local`, `staging`,
    `production`, each optional): `make <part>-build ENV=<env>`, and check, flash and release (which build first),
    compile with those C defines, quoting intact; no setting for the env, no defines. espidf (idf.py `-D
    STD_ENV_DEFINES` and a `CMakeLists.txt` block), pio (`PLATFORMIO_BUILD_FLAGS`), zephyr (`<APP>_EXTRA_CPPFLAGS`, or
    `EXTRA_CPPFLAGS` without sysbuild), arm-gcc (`CFLAGS`/`CXXFLAGS` for CMake, `STD_ENV_CFLAGS` for a Makefile),
    silabs (appended to `CC`/`CXX`); circuitpython has no compile step (4.9, Defines per environment).
  - A build records its env and defines in `std-env` in its build folder: a build for other defines is made again
    from scratch, and a flash or release with `NOBUILD=1` of such a build refuses.
  - CI: the firmware workflows' build job builds with `ENV=production` when the run releases (`run_release` or
    `confirm` `production`), else `ENV=local`.
  - `make audit` warns about an espidf part with the setting and no `STD_ENV_DEFINES` block, an arm-gcc Makefile that
    never uses `STD_ENV_CFLAGS`, and a circuitpython part with the setting; a new firmware part's README shows the
    setting (and, for espidf, the block).
  Update from 1.7: refresh the managed files and move the `uses:` lines to `@v1.8`. Nothing changes for a part without
  the setting, except that its next build writes the `std-env` stamp. To use it, add the settings; an espidf part adds
  the block to its `CMakeLists.txt`, an arm-gcc Makefile part `CFLAGS += $(STD_ENV_CFLAGS)`.

- **1.7** (2026-11-18): a part's Cloudflare Access setup is a standard command. `make/VERSION`, the managed headers and the
  workflows' `@v1.7` say 1.7; `mayankgautam-me/ci-templates` gets the tag `v1.7` (its workflows are 1.6's but for the
  version) and keeps `v1.6` to `v1.0`.
  - `make <part>-access ENV=staging|production` (cloud-worker and web-pages; `cf.sh access`): finds or makes the
    self-hosted Access application `<project>-<env>-<part>` on `<part>_ACCESS_HOST` (default: the env's custom domain)
    and `<part>_ACCESS_PATH`, its Allow policy (`<part>_ACCESS_EMAIL_DOMAINS`, `<part>_ACCESS_EMAILS`, synced every run)
    and its Service Auth policy with the service token; a new token's id and secret go into the env's secrets on stdin,
    `ROTATE=1` gives an existing token a new secret, `DRY=1` prints the plan. `ACCESS_AUD` and `ACCESS_TEAM_DOMAIN` are
    written into `env.<ENV>.vars` of `wrangler.jsonc`, keeping comments. Needs `CF_TOKEN_PERMS := access` and the
    `CF_ACCESS_CLIENT_*` rows of `secrets.schema`; production needs `CONFIRM=production` (section 4.5).
  - `make <part>-access-check ENV=`: read only, Access stops the health path without the token and lets it through with
    it. A web-pages part gets a `doctor` target; both kinds' doctor checks a part with Access settings
    (`cf.sh access-doctor`).
  - `scaffold.sh` writes the `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` rows when `make/project.mk` gives a
    part Access settings or names `access` in `CF_TOKEN_PERMS`, and `--force` appends them to a kept `secrets.schema`;
    a cloud part's settings in a new `make/project.mk` offer the Access lines commented out.
  Update from 1.6: refresh the managed files and move the `uses:` lines to `@v1.7`. A project that made its Access by
  hand can keep it: set the part's `_ACCESS_*` settings and run `make <part>-access ENV=<env> DRY=1` to see what it finds
  (an application on the same domain is used under its own name; the policies and the token are found by name or by
  the stored `CF_ACCESS_CLIENT_ID`).
- **1.6** (2026-11-17): a smoke check through Cloudflare Access. `make/VERSION`, the managed headers and the workflows'
  `@v1.6` say 1.6; `mayankgautam-me/ci-templates` gets the tag `v1.6` (its workflows are 1.5's but for the version) and
  keeps `v1.5` to `v1.0`.
  - `smoke_get` (`lib.sh`) sends `CF-Access-Client-Id` and `CF-Access-Client-Secret` when `CF_ACCESS_CLIENT_ID` and
    `CF_ACCESS_CLIENT_SECRET` are in the environment, through a curl config on stdin (`-K -`), never in argv. A value
    with a quote, a backslash or a line break is refused.
  - A cloud-worker or web-pages part's smoke for `ENV=staging|production` runs under `secrets.sh exec --env <ENV>` when
    `secrets.schema` declares `CF_ACCESS_CLIENT_ID` (`std_smoke_access` in `common.mk`), so a deploy behind Access ends
    in a passing smoke instead of a 403 (myndrya-voice's core at voice.myndrya.com/core). Without it, as before.
  Update from 1.5: refresh the managed files and move the `uses:` lines to `@v1.6`. Nothing else changes.
- **1.5** (2026-11-17): an altium part's BOM is the one its OutJob writes. `make/VERSION`, the managed headers and the
  workflows' `@v1.5` say 1.5; `mayankgautam-me/ci-templates` gets the tag `v1.5` and keeps `v1.4`, `v1.3`, `v1.2`, `v1.1`
  and `v1.0`.
  - altium: the BOM is `<dir>/outputs/**/*BOM*.csv` (and its `.xlsx`), written by the OutJob, not a committed
    `bom/<Board>_BOM.csv`. `<part>-build` requires a BOM CSV among the outputs (an xlsx alone fails); the Release
    attaches the outputs' BOM CSV and xlsx; `<part>-bom` points the `bom` skill at the outputs' CSV and says to run
    the OutJob first. `bom/` leaves the layout: check and doctor warn about one (no longer a violation, and layout
    moves nothing for it), and the audit warns with `git rm -r <dir>/bom` (4.10).
  - KiCad (`hardware`) BOMs are unchanged.
  Update from 1.4: refresh the managed files and move the `uses:` lines to `@v1.5`. For an altium part, make sure the
  OutJob has a Bill of Materials output as CSV into `outputs\` (`BOM` in its file name), run it, check with
  `make <part>-build`, then `git rm -r <dir>/bom` and commit (with the user's go-ahead).
- **1.4** (2026-11-16): the shared Altium library. `make/VERSION`, the managed headers and the workflows' `@v1.4` say
  1.4; `mayankgautam-me/ci-templates` gets the tag `v1.4` and keeps `v1.3`, `v1.2`, `v1.1` and `v1.0`.
  - altium: the shared library `ALTIUM_LIBRARY_PROJECT` (default `<owner>/altium-library`) is a git submodule at
    `ALTIUM_LIBRARY` (default `hardware/altium-library`). New: `<part>-setup` (adds or checks out the submodule,
    installs the library's tools in `<dir>/.venv`), `<part>-lib-check` (the library's `tools/check.py project` on the
    `.PrjPcb`, `WARN=1` for `--warn`), and `<part>-lib-ref` for CI. `<part>-check` runs the library check once the
    library is checked out; the layout check skips the library's own files and accepts a `DocumentPath=` into it;
    doctor reports the submodule and its pin (4.10).
  - CI: `make ci-setup` adds the read-only deploy key `ALTIUM_LIBRARY_DEPLOY_KEY` to the Altium library and sets
    `ALTIUM_LIBRARY_REPO` when the project has an altium part. `altium.yml` takes the secret `ALTIUM_LIBRARY_DEPLOY_KEY`,
    checks the library out at the pinned commit, pulls only its symbols and footprints (cached per library commit) and
    the part's schematics from LFS, installs the tools and runs the check with the library check (section 6).
  - The scaffold documents the submodule in an altium part's README and writes `docs/<part>/library.md` (a new kind
    doc of altium), passes `ALTIUM_LIBRARY_DEPLOY_KEY` to the altium job and adds `.venv/` to Altium's `.gitignore`
    lines. The audit warns about an altium part without the submodule and about a missing `docs/<part>/library.md`.
  Update from 1.3: refresh the managed files and move the `uses:` lines to `@v1.4`; for an altium part add
  `ALTIUM_LIBRARY_DEPLOY_KEY: ${{ secrets.ALTIUM_LIBRARY_DEPLOY_KEY }}` to its job's `secrets:` in `checks.yml`, run
  `scaffold.sh <dir> --force` (it adds `docs/<part>/library.md` and the `.venv/` ignore line), `make <part>-setup` to
  add the submodule (commit `.gitmodules` and it), and `make ci-setup` once more for the key and the variable.
- **1.3** (2026-11-16): the silabs `.rps` and toolchain, found building real WiseConnect 4.0.1 firmware, and audit
  fixes. `make/VERSION`, the managed headers and the workflows' `@v1.3` say 1.3; `mayankgautam-me/ci-templates` gets
  the tag `v1.3` and keeps `v1.2`, `v1.1` and `v1.0`.
  - silabs: the `.rps` comes from the `.slcp`'s `post_build:` / `profile: wiseconnect_soc` (a top-level key, not a
    component), and slc leaves the generated makefile's `POST_BUILD_EXE` empty, so a 1.2 build made no `.rps` even with
    Commander installed. The kind now passes `POST_BUILD_EXE=<commander>`; with a post-build, build refuses without
    Commander and check skips the post-build; without one, doctor (with an OTA bucket) and release name the two `.slcp`
    lines (4.9). 1.2 said Commander was required to build: only a `.slcp` with a post-build needs it.
  - silabs: `slc generate` gets no `--toolchain gcc`; on a SiWx917 it added the Simplicity SDK's `toolchain_gcc` next to
    WiseConnect's `wiseconnect_toolchain_gcc_standard` ("Project is invalid even after autoselecting dependencies").
    The generated makefile is the same without it.
  - silabs: setup installs Simplicity Commander through slt: `commander/<part>_COMMANDER` (`1.25.0`, pinned) joins the
    default `<part>_SLT_INSTALL`, the kind finds the slt-installed one (`slt where`, `Commander.app/Contents/MacOS/commander`
    on macOS) after `SILABS_COMMANDER`, `PATH` and `SILABS_COMMANDER_PATHS`, and doctor's and build's fix for a missing
    Commander is `make <part>-setup` instead of a download from Silicon Labs. Like the SDK it lives in slt's own folder,
    outside the toolchain ledger, so teardown and prune leave it (4.9).
  - The audit counts a silabs part's `<dir>/test/Makefile` and `<dir>/tests/Makefile` as the kind's (its
    `make <part>-test`), not as sub-Makefiles, and warns (area `make`) about a `make/project.mk` or `make/local.mk`
    assignment, commented out or not, with a `# comment` after its value (the 1.2 scaffold lint, now for every project).
  - `scaffold.sh --force` into a git repository (adopt, update) ends with `next: git diff to review, then make setup &&
    make doctor`, without the new project's `git init`.
  Update from 1.2: refresh the managed files and move the `uses:` lines to `@v1.3`. A silabs part that publishes the
  `.rps` adds `post_build:` / `  profile: wiseconnect_soc` to its `.slcp`; `make <part>-setup`, re-run on the Macs and
  runners, installs Simplicity Commander through slt; drop a `<part>_SLC_ARGS` or `POST_BUILD_EXE` in `make/local.mk` that worked around either
  problem. Move any trailing comment the audit reports onto its own line above the setting.
- **1.2** (2026-11-16): reference documents are links, each kind's `.gitattributes` lines, and the silabs
  fixes from building real WiseConnect firmware. `make/VERSION`, the
  managed headers and the workflows' `@v1.2` say 1.2; `mayankgautam-me/ci-templates` gets the tag `v1.2` and keeps
  `v1.1` and `v1.0`.
  - `docs/references.md` is a list of links, one line per document, `- [Title (MPN) — Vendor](URL)`, under `##`
    headings (datasheets by category, then per vendor or module). `make refs-fetch`, `make refs-check` and
    `make/bin/refs.sh` are gone, and so is the `references/` line of `.gitignore`: nothing is downloaded. The audit warns
    (area `docs`) about a 1.1 table with `File` or `SHA256` columns and reports a leftover `make/bin/refs.sh` as outdated.
  - `*.wrl` (KiCad's VRML models) is in `.gitattributes` only with a KiCad board (kind `hardware`): the scaffold adds it
    with the kind's other lines, and the audit asks for it only then (`*.step`, `*.stp` and `*.fcstd` everywhere, as
    before).
  - altium: `*.PrjPcbVariants` (an OLE compound file) joins the lockable LFS lines, and `*.PrjPcb -text` and
    `*.OutJob -text` keep Altium's CRLF text files (the `.PrjPcb` with a UTF-8 BOM) byte-exact; `make <part>-check`,
    doctor and the audit check both (4.10).
  - The scaffold's `make/project.mk` has every comment on a line of its own above its setting: a trailing `# note`
    after a commented-out `<part>_BOARD := x` became trailing spaces in the value once uncommented.
  - silabs, from building real WiseConnect firmware: setup installs `wiseconnect/<part>_WISECONNECT` (a bare
    `wiseconnect` installed the latest, 4.1.2 with SDK 2026.6.2, and the pinned SDK was never found); the SDK is found
    by its `.slcs` `sdk_version:` line; slc's Java at slt's `jre/bin/java`; `slc generate --overwrite-all` by default
    (`<part>_SLC_OVERWRITE`; with `-cp` a later source edit was silently not rebuilt); the board stripped of spaces;
    the pinned GNU Arm toolchain's gcc (`<part>_GCC`, `12.2.rel1`), not the first found; `make <part>-test` runs host
    unit tests from `<dir>/test/` or `<dir>/tests/` with the Mac's `cc` (none: exit 0); doctor and the kind say that
    Simplicity Commander is required to build (the `wiseconnect_soc` post-build makes the `.rps` with it), and
    release refuses when there is no `.rps`.
  Update from 1.1: refresh the managed files, delete `make/bin/refs.sh` and move the `uses:` lines to `@v1.2`; convert a
  `docs/references.md` table to links (keep Title, Vendor and URL; drop File and SHA256) and remove `references/` from
  `.gitignore`; `scaffold.sh --force` adds `*.wrl` with a hardware part and Altium's new lines with an altium part.
  A `.PrjPcbVariants` already committed as a plain blob moves to LFS with `git add --renormalize .`, as in adopt.
  A silabs part: drop a `<part>_SLT_INSTALL := slc-cli wiseconnect/<ver>` or `<part>_SLC_ARGS := --overwrite-all` that
  only worked around these (both are the defaults now), and move a `make/local.mk` `<part>-test` target into a Makefile
  in `<dir>/tests/` (the kind's `<part>-test` runs it), deleting the local one.
- **1.1** (2026-11-16): three new kinds, and the owner's registry and library. `make/VERSION`, the managed headers and
  the workflows' `@v1.1` say 1.1; `mayankgautam-me/ci-templates` gets the tag `v1.1` and keeps `v1.0`.
  - Kinds: `silabs` (Silicon Labs slc projects on the Simplicity SDK and WiseConnect, SiWx917 / SiWG917 M4; slt, slc,
    Simplicity Commander; `power`, `power-live`, `power-avg` through Commander's energy monitor; the optional signing
    key `silabs-m4`), in `firmware/`; `altium` (Altium Designer boards: Altium runs on Windows, so the kind checks the
    project, its fixed layout and Git LFS, verifies the OutJob's outputs and packages the fab zip; `make <part>-layout`
    prints the moves into the layout; CI checks only, and the Release is made where the outputs are), in `hardware/`;
    `mechanical` (FreeCAD models in Git LFS: open and recompute, STEP and STL exports), in the new group folder
    `mechanical/`. Their workflows are `silabs.yml`, `altium.yml` and `mechanical.yml`; their docs `power.md` (silabs,
    with `protocol.md` and `flashing.md`), `bringup.md` and `manufacturing.md` (altium), `assembly.md` (mechanical).
    None of them is started before its file exists (`*.slcp`, `*.PrjPcb`, `*.FCStd`).
  - zephyr: upstream Zephyr with `<part>_ZEPHYR := v4.3.0` (and no `<part>_NCS`), `PROBE=commander` (west's Silicon Labs
    Commander runner), and `make <part>-power` with `POWER=ppk2` or `joulescope` (4.9).
  - hardware: `<part>_LIBRARY := local` makes the board's own library tables its library; its CI jobs pass the new
    `hardware.yml` input `library: local` and check out no KiCad library (4.10). `KICAD_LIBRARY_PROJECT` is read from
    `make/project.mk`, else the user config, else `<owner>/kicad-library` (section 9).
  - docker: `DOCKER_REGISTRY` follows the project's owner (`ghcr.io/<owner>`, lowercase; section 9); images carry the
    OCI source, revision, version and created labels, so a ghcr.io package inherits its repository's access; setup logs
    docker in to ghcr.io with gh's token, doctor checks the `write:packages` scope, and `make <part>-prune-images`
    deletes old untagged and sha-only versions with `CONFIRM=prune` (4.11).
  - `make refs-fetch` and `make refs-check`: the reference documents listed in `docs/references.md` (written for every
    project) downloaded into the ignored `references/` and checked by SHA256 (4.1; removed in 1.2).
  - `.gitattributes` has `*.FCStd` next to `*.fcstd` (git matches with case on Linux, so a Linux checkout got the
    pointer file of `Case.FCStd`), and Altium's binaries with an altium part; the audit checks the case of every CAD
    file in LFS, reports an Altium binary committed as a plain blob as an error, reports an origin that is not on
    GitHub (area `repo`, with the move to GitHub as its fix), suggests the `PARTS` entry for a KiCad, Altium or
    FreeCAD folder no part covers, and checks the docs of the new kinds.
  - Teardown never removes an altium part's `outputs/` (only Altium makes them again); it removes its `production/`.
  Update from 1.0: refresh the managed files, move the `uses:` lines to `@v1.1`, add `references/` to `.gitignore`
  and `*.FCStd` to `.gitattributes` (`scaffold.sh --force` adds both, and `docs/references.md` when it is missing), and
  `library: local` on the jobs of a hardware part that sets `<part>_LIBRARY := local`.
- **1.0** (2026-11-15, second restart): the version restarts at 1.0 again. `make/VERSION`, the managed files'
  headers, the workflows' `@v1.0` and the `mayankgautam-me/ci-templates` tag all say 1.0; ci-templates' history is one
  commit, tagged `v1.0`. 1.1 to 1.8 below (and the first 1.0) are the versions before this restart; 1.8 and this 1.0
  have the same files.
- **1.8** (2026-11-15): one secrets repo per GitHub owner. A project's owner is read from its git remote `origin`
  (in CI from `GITHUB_REPOSITORY_OWNER`); its secrets repo is `https://github.com/<owner>/secrets.git`, checked out at
  `~/.secrets-<owner>` for every owner, the user config's own included: move the old `~/.secrets` by hand, the
  commands are in section 5.4 and every secrets command prints them until it is done. The config's `SECRETS_REMOTE`
  applies to its own owner only, so a personal project never lands in a company repo. `secrets-init` on an empty
  remote starts the repo with the Macs' and the recovery key's public recipients copied from another `~/.secrets-*`.
  New-project mode creates the GitHub repo (owner asked) and `origin` before the secrets; `ci-setup` takes
  `SECRETS_REPO` and the deploy key from the project's own secrets repo (section 5).
- **1.7** (2026-11-15): `CI_TEMPLATES_REPO` (`owner/name`) names the repository of the reusable workflows, apart from
  the project's `GITHUB_OWNER`: default `mayankgautam-me/ci-templates`, public, so projects of every owner (the
  fabrolabs-innovations and i2sage-technologies organizations, the personal account) call the same workflows.
  `make/project.mk` or the user config can set another. The audit reports a `uses:` line on another ci-templates repo
  as outdated; `ci-setup` asks for the Actions Access setting only for a private one. `CI_TEMPLATES_PROJECT` is retired.
- **1.6** (2026-11-14): `make cf-provision ENV=staging|production` also creates the project's OTA buckets
  (`OTA_BUCKET`, each `<part>_OTA_BUCKET`), in a project with Workers and in one whose only Cloudflare resource is that
  bucket (a firmware or app project); `cf-status` reports them. `OTA_PUBLIC := r2dev` in `make/project.mk` turns on
  the bucket's public r2.dev URL; without it nothing is made public. `cf-wipe` and `cf-destroy` never touch an OTA
  bucket. my-morning's bucket had to be made by hand before.
- **1.5** (2026-11-14): `cf-backup`, `cf-wipe` and `cf-destroy` pass `--env <env>` to every remote `wrangler d1` call
  by name. Without it wrangler resolved the name through the top level of `wrangler.jsonc`, the local bindings, and an
  adopted Worker's placeholder `database_id: "local"` reached the API ("Invalid uuid"): myndrya's first
  `cf-backup ENV=production` failed so.
- **1.4** (2026-11-14): the linux-arm64 jobs run on `vars.STD_RUNNER_LINUX_ARM` (default `ubuntu-24.04-arm`) and the
  macOS jobs on `vars.STD_RUNNER_MACOS` (default `macos-latest`), so with the four `STD_RUNNER*` variables every job can
  run on self-hosted runners (section 6).
- **1.3** (2026-11-14): every Linux job's `runs-on` is `${{ vars.STD_RUNNER || 'ubuntu-24.04' }}`, in ci-templates and
  in the jobs the scaffold writes into `checks.yml` and `release.yml`: the organization variable `STD_RUNNER` moves all
  CI to a self-hosted runner (section 6) without editing a workflow; `STD_RUNNER_WINDOWS` does the same for app-tauri's
  Windows jobs.
- **1.2** (2026-11-14): `secrets.schema` fits the project. The scaffold writes an app's signing rows only for the app
  kinds in `PARTS` (app-xcode: `appstore-api-key`; Android, Windows and Apple notarisation rows only where a kind reads
  them; section 5), and the Cloudflare rows also for a project whose only Cloudflare use is a firmware OTA bucket
  (`OTA_BUCKET`), whose token then needs R2 only (section 7). A row whose description starts with `optional:` is a
  warning in `make doctor` when it is not set, never a problem. Found adopting my-morning (Zephyr, KiCad, iOS app).
- **1.1** (2026-11-14): Git LFS only for 3D and CAD models (`*.step *.stp *.wrl *.fcstd`). PNG, MP4, ZIP and HEX left the
  LFS lines: images, fonts, short videos and test fixtures are small and stay in plain git (172 PNGs in LFS across the
  projects came to 0.7 MB), and zip or hex build output is a release file, not committed. A file over 5 MB is still
  refused by the pre-commit hook unless `.gitattributes` names it for LFS. The audit warns about a project that still
  routes png, mp4, zip or hex to LFS; the fix is to drop those lines and `git add --renormalize .`.
- **1.0** (2026-11-14): the standard's version restarts at 1.0: `make/VERSION`, the managed files' headers, the
  workflows' `@v1.0` and the ci-templates tag all say 1.0, and the next versions are 1.1, 1.2 and so on. ci-templates'
  history is one commit, tagged `v1.0`. v1 to v40 below are the versions before 1.0; v40 and 1.0 have the same files.
- **v40** (2026-11-14): the smoke check of a cloud-worker or web-pages part (`smoke_get` in `lib.sh`) falls back to
  public DNS when this machine cannot resolve the host (curl exit 6): right after a first deploy attaches a custom
  domain, the Mac's resolver still caches the miss from before. It asks 1.1.1.1, then 8.8.8.8, over DNS-over-HTTPS and
  checks again pinned to that address, saying so; any other failure fails as before (health.myndrya.com, core.myndrya.com).
- **v39** (2026-11-14): `make cf-secrets` skips the key-file rows of `secrets.schema` (env `keys`, whose names may hold
  `-`, such as `appstore-api-key`) instead of refusing the whole schema; a Worker secret is never a key file
  (myndrya-voice's first `cf-secrets`).
- **v38** (2026-11-14): `CF_TOKEN_PERMS := access` also asks for Access: Organizations, Identity Providers, and Groups:
  Read (`cf-token-check` probes `/access/organizations`): the team domain behind the Access certs URL is read from the
  account's Zero Trust organization, which the two Edit permissions do not reach (myndrya-voice's first `access-create`).
- **v37** (2026-11-14): `CF_TOKEN_PERMS := access` also asks for Access: Service Tokens: Edit (`cf-login` names it,
  `cf-token-check` probes `/access/service_tokens`), so a project can make its Access application, policies and
  service token from make with its one token (myndrya-voice's `make access-create`).
- **v36** (2026-11-14): `CF_TOKEN_PERMS := access` adds Access: Apps and Policies: Edit to the project's one Cloudflare
  token: `cf-login` names it to add by hand, `cf-token-check` probes `/access/apps`. A project that edits its own Access
  application from make (myndrya-voice's `access-paths`) uses `CLOUDFLARE_API_TOKEN`, not a second token.
- **v35** (2026-11-13): the circuitpython build opens `<dir>/build/` to everyone before `docker run`. The build image
  runs as a user of its own (`USER` in its Dockerfile), and on a Linux runner that user could not write the folder the
  runner owns, so the release job failed at the copy into `/out` (orphea). Docker Desktop on a Mac hid it.
- **v34** (2026-11-13): a web-pages part is a static-assets Worker on its custom domain by default, as kaivoo is.
  `scaffold.sh --domain <part>=<host>` writes its `wrangler.jsonc` (`workers_dev` and `preview_urls` off, an env
  block per environment with the domain as a `custom_domain` route, staging at `<label>-staging.<zone>`) and
  `<part>_URL_<env>` in `make/project.mk`; it writes the file into an existing part folder too (adopt). Pages only
  with `--pages <part>`, when the user asks for it. New and adopt ask each web part's domain; the audit warns about a
  web-pages part with no wrangler file and about a `CHANGE-ME` route.
- **v33** (2026-11-13): a web-pages part is a static-assets Worker only when its `wrangler.jsonc` has no
  `pages_build_output_dir`. v31 made any wrangler file a Worker, and the scaffold writes a Pages one, so a scaffolded
  site would have deployed with `wrangler deploy` (found updating prism-tagger).
  The audit also leaves CubeMX's generated folders (`Core`, `Drivers`, `Inc`, `Src`, `Middlewares`) next to a `.ioc`
  with their names: CubeMX regenerates into them (pahwatt).
- **v32** (2026-11-13): the audit accepts a go or python part under `firmware/`: code that runs on a device (multisig's
  LattePanda agent, `firmware/lattepanda`) belongs with the firmware, not in `cloud/`. Elsewhere such a part is still a
  service and its fix is `cloud/`.
- **v31** (2026-11-13): a web-pages part with a `wrangler.jsonc` in its folder is served by a static-assets Worker, not
  a Pages project: `deploy` runs `wrangler deploy --env ENV`, `provision` has nothing to create, `status`, `versions` and
  `logs` use the Worker, and `cf-login` asks for Workers Routes and DNS on its zone instead of Pages. With `workers_dev`
  and `preview_urls` off its custom domain is its only address, which Pages cannot do (kaivoo.fabrolabs.com).
- **v30** (2026-11-13): `CF_TOKEN_PERMS` in `make/project.mk` names token permissions no binding shows; `realtime`
  (Cloudflare Realtime: Edit, for a TURN app: multisig) is the first. `cf-login` lists it to add by hand (the form
  cannot preset it) and `cf-token-check` probes `/calls/turn_keys`.
- **v29** (2026-11-13): `make secrets-check` (and `make doctor`) counts a gitleaks finding only in a file git does not
  ignore: gitleaks scans ignored build folders too, and Next.js's dev cache (`web/.next/`) has random ids it reads as API
  keys (kaivoo). The error names the file, never a value. `make cf-token-check` checks the project's one token once,
  against what every cloud-worker and web-pages part needs (the list `cf-login` asks for, Pages included); before, it
  ran per Worker folder, so a project with only a Pages site printed nothing. A token without an expiry shows
  `expires never`.
- **v28** (2026-11-13): `make ci-setup` does the whole CI setup in one run the user starts: the CI age key
  (`secrets-ci`), the read-only deploy keys for the secrets repo and the KiCad library (made in `~/.ssh` when missing,
  added when the repository does not have them yet, titled `<project>-ci-read-only`), their repository secrets, and the
  variables `SECRETS_REPO` and `KICAD_LIBRARY_REPO`. It is safe to run again; `ci-setup-help` still prints the steps as
  commands. New and adopt now ask whether each cloud-worker and web-pages part has staging, instead of assuming it from
  the old setup (kaivoo's site got staging from an old dev deploy).
- **v27** (2026-11-12): every workflow's setup step also installs jq when it is missing. `cf.sh` reads
  `wrangler.jsonc` with jq, and the cloud-worker job's Node container has none, so the first production deploy from a
  release tag failed with `no "production" block under env` (cryptoguard's cloud-v1.0.0).
- **v26** (2026-11-12): a cloud-worker or web-pages part's release tag deploys production (`make <part>-deploy
  ENV=production`, one `deploy-production` job for parts with and without staging), then makes its GitHub Release
  with the CHANGELOG notes only (no files): a Release means "this version is live". A push to main deploys staging
  where the part has it and production never; CI no longer promotes (`make <part>-promote` stays for a run by hand),
  checks.yml has no `confirm` input, and release.yml's `<part>-production` dispatch job is the hotfix route for every
  cloud part. The audit warns about a cloud part's tag job without `confirm: production`. A firmware part in a project
  with no OTA bucket skips its OTA publish: `<part>-release` says so and exits 0, `make help` hides it, and the
  scaffold writes no firmware production job when the project has no cloud part either. `latest-sync` returns early
  for a Release with no files.
- **v25** (2026-11-12): setup on demand (4.1): a part's commands run its setup first when a cheap, offline ready
  check fails (`node_modules` against the lockfile; the NCS workspace and toolchain; ESP-IDF; a pio stamp; the
  circuitpython image; the docker builder), with one line saying so; names are unchanged and a ready part costs
  milliseconds. setup, doctor, clean, version, bump and anything that needs the user (secrets, Touch ID, cf-login)
  are never chained; a CONFIRM-guarded command may set up before it refuses. `make cf-login` with an account-owned
  token and Enter at the account-id prompt looks the account up from the token; the printed steps say to choose
  Specific zone in the form (the link cannot preset zones); Workers Tail is no longer asked for (`wrangler tail`
  works with Workers Scripts: Edit on an account token, verified on cryptoguard). The audit no longer counts the
  Makefile an arm-gcc part builds through as a sub-Makefile. The cloud-worker and web-pages workflows skip
  deploy-staging for a production-only part (a push to main failed on it).
- **v24** (2026-11-12): the zephyr kind works inside the nRF Connect SDK CI image. When `<part>_TOOLCHAIN_ENV`
  (default `/opt/toolchain-env.sh`) exists, setup uses the image's python, west, cmake, ninja and Zephyr SDK as they are
  (no venv, no SDK download; a venv there broke on the image's python paths), and every build sources that script when
  the image's BASH_ENV did not. The NCS workspace is cloned shallow (`--depth 1`, `west init -l`), and the zephyr
  workflow caches it per NCS version (`actions/cache/restore` and `save`, key `zephyr-ncs-<version>-w1`). The image has
  no curl, and its LD_LIBRARY_PATH breaks Debian's: a `/usr/local/bin/curl` wrapper runs it without. `make cf-login`
  opens Cloudflare's token page pre-filled with the project's name and the permissions its `wrangler.jsonc` files need
  (account-owned token template URL, section 7), then takes the pasted token as before and checks each permission;
  `CLOUDFLARE_API_TOKEN` in the environment is used without the form, and `cf.sh token-url` prints the link only.
  The Worker and site starters get a `pnpm-workspace.yaml` that lets pnpm run wrangler's install scripts (esbuild,
  sharp, workerd), under both `onlyBuiltDependencies` (pnpm 10) and `allowBuilds` (pnpm 11 and later): without it
  pnpm refuses them and the first `make setup` stops. An existing part adds the same file by hand. Every GitHub
  repository gets a one-line description (its "About"), the README's first sentence; the audit warns about a
  repository without one: its only online check, run only when `gh` is installed and a remote is on github.com
  (`STD_AUDIT_OFFLINE=1` skips it).
- **v23** (2026-11-12): every workflow's setup step installs only the tools of make, git and curl that are missing,
  with `--no-upgrade`, instead of all three. In the nRF Connect SDK container, installing all three upgraded libcurl
  past the nghttp2 the image ships, and curl then failed with a symbol lookup error (cryptoguard's second run).
- **v22** (2026-11-12): the `check` job of the zephyr and espidf workflows installs make (and STD_APT_PACKAGES) and
  mise like their `build` job. Their containers (nRF Connect SDK toolchain, ESP-IDF) have no make, so a check job
  failed at once with `env: 'make': No such file or directory` (found on cryptoguard's first GitHub run).
- **v21** (2026-11-12): the zephyr `check` turns warnings into errors with `-DEXTRA_CFLAGS=-Werror` instead of
  `CONFIG_COMPILER_WARNINGS_AS_ERRORS`: NCS passed that on to TF-M, which every `/ns` board (nRF91, nRF53) builds, and
  TF-M's own sources warn, so the check failed on code that is not the project's. `-Werror` still reaches Zephyr and
  the app. Layout (section 1): one part of a kind sits in the kind's folder (`firmware/`, `hardware/`, `cloud/`, `web/`,
  `app/`), several get `<kind folder>/<part>/` each, and several firmware parts are named for their chip;
  `scaffold.sh` defaults a part's folder that way and `audit.sh` warns about a part outside it.
- **v20** (2026-11-12): the Release `latest` holds the newest files of every part and carries GitHub's one Latest badge
  (4.12): names without the version, so `.../releases/download/latest/<file>` stays the same; a hardware part keeps one
  group per major version (each board revision); a `<group>-SHA256SUMS` per group. Part Releases are made with
  `--latest=false`. `release.sh latest-sync` and `make <part>-release-latest` copy a published Release into it;
  `release.yml` ends with a `latest` job that runs it, one at a time, and `<part>-github-release FORCE=1` on a Mac runs
  it too. A `release.yml` without the job is kept: the audit warns, and the job is added by hand.
- **v19** (2026-11-12): the pre-commit large-file guard skips KiCad design files (`.kicad_pcb`, `.kicad_sch`,
  `.kicad_pro`): they are text that git stores as deltas and diffs, and a real board is often well over 5 MB (command-deck's
  is 30 MB), so the guard blocked every board change. Every other file over `STD_MAX_FILE_MB` still needs LFS.
- **v18** (2026-11-12): teardown also lists and removes each part's `release/` (and a hardware part's `production/`),
  local copies of what its GitHub Releases keep, and a pio part's distclean removes the project-local PlatformIO core
  `.platformio` (`core_dir`), which `make setup` downloads again. The first real run on command-deck found both: 3.6 GB in
  all, against 2.6 GB before.
- **v17** (2026-11-12): `make teardown` and `make prune`. `make setup` keeps a usage record per project and a ledger of
  what the standard itself installed (mise versions from the project's mise.toml, SDK folders by physical path, rustup
  targets with their toolchain) in `${XDG_STATE_HOME:-~/.local/state}/project-standard`; the record is rebuilt beside
  the old one and swapped in only when setup finishes. Both commands list with sizes and remove only with
  `CONFIRM=teardown` / `CONFIRM=prune`: the project's build and dependency folders, its record, and ledger items that no
  other current record and no global mise tool uses. Homebrew is never touched. A record on an unmounted drive is
  unreachable and keeps protecting its items; prune drops only stale records, runs `pnpm store prune` and
  `cargo cache --autoclean` when available, and skips Docker. Part folders that are absolute or contain `..` are refused,
  and the kinds' `rm -rf` paths are quoted. `make latest` no longer uses a here-string.
- **v16** (2026-11-12): the push and pull-request workflow is `.github/workflows/checks.yml` (shown as `checks`, its
  concurrency group `checks-<ref>`), not `ci.yml`; `release.yml` keeps its name. audit warns about a left-over `ci.yml`, and
  `scaffold.sh --force` keeps it and asks for the rename instead of writing a second checks workflow. `make latest` prints
  each part's newest Release, since GitHub marks only one Release of a repository Latest. The app-tauri macOS build retries
  once when `tauri build` fails (its DMG step fails now and then).
- **v15** (2026-11-12): `make <part>-bump` of an app-tauri part sets the version everywhere the app declares it:
  `src-tauri/tauri.conf.json` (or the JSON file its `"version"` names), the `[package]` `version` of
  `src-tauri/Cargo.toml` (never a dependency's) and the top-level `"version"` of `package.json`, each when it exists,
  and the app's own entry in `src-tauri/Cargo.lock` when the lock is tracked; the release commit holds every one of
  them. `version` still reads tauri.conf.json. The scaffolded `docs/<part>/manufacturing.md` says the stackup matches
  the board's `.kicad_pcb` (KiCad keeps it there, in Board Setup), not the `.kicad_pro`.
- **v14** (2026-11-12): decision records are no longer part of the standard. The scaffold no longer writes
  `docs/decisions/` (its README and the `adopt-the-project-standard` record) and no longer lists it in `docs/README.md`;
  `audit.sh` no longer requires it, and an existing one causes no finding. `CLAUDE.md` no longer asks for a decision record
  (CHANGELOG entries and `docs/<part>/` upkeep stay), and `PLAN.md`'s root component claims `docs/*.md` and `docs/images/**`.
  An existing `docs/decisions/` can stay as the project's own docs or be removed.
- **v13** (2026-11-12): `make release-push` (release.sh push) pushes the branch, then each new release tag in its own
  push (GitHub starts no workflow for the tags of a push with more than three); bump points at it. `scaffold.sh --force`
  appends the missing CI and release lines (.ci/, ci-local, <dir>/release/) to an existing `.gitignore`, and audit warns
  when `.ci/` is not ignored.
- **v12** (2026-11-12): the jobs that download another job's artifact (firmware release and publish, cloud-worker
  deploy-production) ask for actions: read, and every calling job grants it: without it the artifact API answered
  "Resource not accessible by integration" and the firmware Release failed.
- **v11** (2026-11-12): cache keys hash only the part's own lock and config files (a `**` walk over the workspace
  failed on the tool folders a container job had written, which failed the job in its cache step); the Windows jobs clone
  the secrets repo with Git's own ssh and a pinned github.com host key, because the OpenSSH that actions/checkout uses
  on windows-11-arm refuses the deploy key file ("permissions are too open").
- **v10** (2026-11-12): fixes from the first runs on GitHub. A container job (most Linux jobs) marks the workspace
  as a git safe.directory before Git LFS (the checkout belongs to another user there, and git-lfs said "Not in a Git
  repository"); paths under the workspace (SECRETS_DIR, PLATFORMIO_CORE_DIR) are set in a step from $GITHUB_WORKSPACE,
  because ${{ github.workspace }} is the host path inside a container; the GitHub CLI step installs curl when the image
  has none (kicad/kicad). GitHub starts no workflow when more than three tags are pushed at once: push release tags one
  at a time.
- **v9** (2026-11-11): GitHub replaces GitLab. Each project has `.github/workflows/checks.yml` (pushes and pull requests; a
  `changes` job runs only the parts that changed) and `release.yml` (tags `<part>-v*`, and the production jobs behind
  `workflow_dispatch`), written by `scaffold.sh` when missing. They call the reusable workflows of `<owner>/ci-templates`
  at `@v<n>`. Releases are GitHub Releases: `make <part>-github-release` creates or updates `<part> <version>` with the
  files attached. The v8 names `<part>-gitlab-release` and `gitlab-release` are gone in v9: rename them in any script. Release files are no longer in a
  package registry; store bundles and mapping files are workflow artifacts, not Release assets. The CI age key is the
  repository secret `SOPS_AGE_KEY` (`make secrets-ci`); the secrets and KiCad library repositories are read with read-only
  deploy keys (`SECRETS_DEPLOY_KEY`, `KICAD_LIBRARY_DEPLOY_KEY`; `make ci-setup-help`), replacing the job token allowlists.
  Free private repositories have no environment protection, so production, store and OTA jobs need `confirm` =
  `production`. Docker images go to `ghcr.io/<owner>`. `gh`, `actionlint` and `act` replace `glab` and gitlab-ci-local.
  Windows x64 runs on `windows-2025` and arm64 on `windows-11-arm` (NSIS only); the macOS jobs need `MACOS_CI=true`.
  A leftover `.gitlab-ci.yml` is not used: remove it with `git rm`. Limits and billing: section 6. Not yet run on GitHub.
- **v8** (2026-11-11): per-platform releases. An app part releases one file set per platform (`PLATFORM`), each platform
  job adds its files to the same GitLab Release, each writes `SHA256SUMS-<platform>`, and a Release created twice at once is
  updated, not refused. Build lines of iOS and the notes survive other platforms' updates (a bounded re-write, not a lock: two
  updates that overlap more than three times can still lose a line; the next run writes it again). The Linux and Windows
  platforms are CI jobs (`saas-linux-small-amd64`, `-arm64`, `saas-windows-medium-amd64`); macOS, iOS and Android are published
  from the Mac with `FORCE=1 PLATFORM=...`. Store bundles and mapping files are uploaded but not linked. v7 projects keep working:
  the v7 `<part>-gitlab-release` names of app-tauri, app-flutter, app-xcode and app-android are hidden aliases in the templates,
  and `audit.sh` reports an `extends:` of a job the templates no longer define as an error.
- **v7** (2026-11-11): documents and GitLab Releases. The scaffold writes a document set, each doc with its headings and a one-line
  hint per section, never overwriting one that exists (§1, "Documents"): `docs/README.md` (index),
  `docs/architecture.md` (a Mermaid node per part, where each runs), `docs/decisions/` (format and a first record,
  `adopt-the-project-standard`, numbered after any records already there), `docs/operations.md` with a deployable
  part (cloud-worker, web-pages, docker), and per part a fuller `<dir>/README.md` (purpose, build and run,
  configuration, interfaces, docs), a `<dir>/CHANGELOG.md` in Keep a Changelog 1.1.0 format (tags
  `<part>-v<version>`) and the kind's docs in `docs/<part>/` (firmware: protocol, flashing; hardware: bring-up,
  manufacturing; cloud-worker: api, data; apps: distribution; docker, go, python: usage). A part folder that
  exists gets its missing docs too, never its starter code. Binary documents are never committed: `.gitignore`
  ignores PDF, Word, Excel, PowerPoint and OpenDocument files, and `*.pdf` and `*.xlsx` leave the LFS lists
  (project and hardware board template). `CLAUDE.md` asks for a decision record per significant decision, a
  CHANGELOG entry per user-visible change and docs updated with the interfaces. `PLAN.md` gives each part's
  component its `docs/<part>/**`. The audit warns for each missing doc and each committed binary document, and
  for a `.gitignore` or `.gitattributes` that still lets them in. Adopt moves existing docs into the layout.
  Releases (§4.12): each part releases on its own tag `<part>-v<version>`. `make <part>-bump LEVEL=|VERSION=`
  (every kind: firmware and go/docker/cloud-worker/web-pages `VERSION`, hardware `VERSION` or the title block,
  pubspec, tauri.conf.json, build.gradle.kts, agvtool, pyproject.toml) sets the version, moves the CHANGELOG's
  Unreleased notes under it, commits those files and tags; root `make bump` needs `PART=` with several parts and
  no longer runs for all. On the tag, CI runs `<part>-gitlab-release` (new `.<kind>-gitlab-release` job in every
  kind template, not manual): `<part>-release-assets` collects each kind's files into `<dir>/release/<version>/`
  with `SHA256SUMS` (ignored per part in `.gitignore`), `release.sh` (new managed script) uploads them to the
  generic package registry under `<project>-<part>/<version>/` and creates or updates the GitLab Release `<part>
  <version>` with that version's CHANGELOG section and a link per file, through the Releases API with
  `CI_JOB_TOKEN` (on a Mac: glab). The scaffold writes each tag job narrowed to `$CI_COMMIT_TAG =~ /^<part>-v/`.
  Publishing stays manual: the firmware OTA, app store and production deploy jobs keep `CONFIRM` and now run on
  their part's tag only; the app store jobs, automatic on tags in v6, are manual. Hardware: `<part>-release` is the
  GitLab Release (all outputs, not just the fab zip and WRL) and no longer makes the tag (bump does);
  `.hardware-release` is kept as the same job for v6 projects. Docker: the GitLab Release job pushes the image
  (now also tagged `:<version>`) and attaches `image.json` with its digest; the scaffold writes no separate
  docker release job. Go releases linux and darwin, amd64 and arm64. cloud-worker, web-pages and docker get a
  `version` target. The audit warns about tracked files under a part's `release/`.

- **v6** (2026-11-09): what the first project on v5 (command-deck) needed to go green on GitLab. The hardware
  template no longer sets `KICAD_LIBRARY_REPO` and `KICAD_LIB_PREFIX` on its jobs (it reads them with a default),
  so a project sets them once under its top-level `variables:`; in v5 the empty job variable overrode the
  project's value and every hardware job had to repeat it. The scaffold writes `KICAD_LIBRARY_REPO` for a
  hardware part when the user config sets `KICAD_LIBRARY_PROJECT`, and the docs give the job token allowlist
  step (library and secrets repo). Rust is pinned with `components = "clippy,rustfmt"` (mise installs the minimal
  profile otherwise, and CI had no clippy); app-tauri has a `doctor` that checks clippy and rustfmt, and `check`
  says how to fix a missing clippy. `STD_APT_PACKAGES` (top-level) adds Debian packages to every apt-get install
  in the templates; the app-tauri build job installs `xdg-utils` for the AppImage bundle, in CI and in the Linux
  Docker build. The change filter includes `.gitlab-ci.yml`. `make ci-local JOB=` runs one job in Docker with
  gitlab-ci-local (Brewfile, `make doctor` and `.gitignore` lines for it), as linux/amd64 like GitLab's runners
  (kicad/kicad has no arm64 image), and refuses in a git worktree, where git in the container cannot reach the
  repository. The app-tauri Linux Docker build uses
  pnpm when the part has `pnpm-lock.yaml` (`npm ci` failed there). Adopt moves binaries already tracked as plain
  blobs into LFS (`git add --renormalize .`), and the audit reports such files. `make help` lists only the root
  commands the project's parts use (`ALL=1` lists every one). The hardware kind falls back to the library KiCad
  points at (`<prefix>_LIB_DIR` in KiCad's `kicad_common.json`) when `KICAD_LIBRARY_DIR` is not set, and doctor
  says where it came from. `OTA_BUCKET` moves from the user config to `make/project.mk` (one bucket per project,
  in its own Cloudflare account, and visible to CI); a value in `config.mk` is ignored with a warning.
  The scaffold places `tests/smoke/` and `tests/remote/` only when a part is deployable (cloud-worker or
  web-pages, the kinds with `smoke` and `test-remote`). Its `.gitignore` ignores each hardware part's
  `<dir>/production/` (the release fab zips, published to the package registry), and `.svelte-kit/` and
  `vite.config.*.timestamp-*` for app-tauri and web-pages parts, so a part needs no `.gitignore` of its own;
  the audit warns about tracked files under a hardware folder's `outputs/` or `production/`.
- **v5** (2026-11-09): the JS kinds (app-tauri, cloud-worker, web-pages) and `cf.sh` run package binaries
  (tauri, svelte-kit, svelte-check, vitest, tsc, biome, eslint, vite, next, wrangler) through the part's package
  manager: `pnpm exec` when the part has `pnpm-lock.yaml`, else `npx --no-install` (`<part>_EXEC` overrides it
  in the kinds); in v4 a pnpm project went through `npx`, which warns about pnpm-only `.npmrc` keys and can
  resolve differently. app-tauri `check` runs `svelte-kit sync` before `svelte-check` when the front end is
  SvelteKit (`@sveltejs/kit` in `package.json` or `svelte.config.js`), so it works on a fresh checkout without
  `.svelte-kit/tsconfig.json`. `scaffold.sh` for a pio part: the `project.mk` comment and README name
  `<part>_PIO_ENV` (the variable the kind reads, not `<part>_ENV`), and PlatformIO is pinned in `mise.toml`
  (`"pipx:platformio" = "6"`, with `python` and `uv`) instead of a `brew "platformio"` line in the Brewfile.
- **v4** (2026-11-09): pio board targets (flash, erase, monitor, debug, provision) run for exactly one env and
  refuse, before touching the board, when `PIO_ENV=` and `<part>_PIO_ENV` are unset and `platformio.ini`
  (`default_envs`, else its `[env:*]` sections) or `PLATFORMIO_DEFAULT_ENVS` selects several: in v3, `make
  <part>-flash` with `default_envs = rev3, rev4` uploaded both images to the same board. build, check, size and
  clean still run every default env. `.npmrc` counts as a secret file (in `secrets-check` and the audit) only
  when it sets a credential (`_authToken`, `_auth`, `_password`, `username`, `password`, also per registry); a
  value that is only `${VAR}` is not one, and an `.npmrc` with settings only is fine.
- **v3** (2026-11-08): one Cloudflare API token per project: `make cf-login` (no `ENV`) stores it for staging and
  production, `cf-logout` removes both, `cf-whoami` and `cf-token-check` say when the copies differ.
  Production-only cloud-worker and web-pages parts (no `env.staging`): deployed with `make <part>-deploy
  ENV=production CONFIRM=production`, staging commands refused, CI jobs `.<kind>-deploy-production-only` and
  `scaffold.sh --production-only <part>` (also detected from an existing `wrangler.jsonc`). Queue consumers'
  queues and dead-letter queues are provisioned, shown by `cf-status`, name-checked and deleted by `cf-destroy`;
  a queue is found by its exact name (an existing `<q>-dlq` no longer hides a missing `<q>`). The docs say which
  bindings are managed and that Durable Object storage is not backed up. The project CI template's `ref:` is
  the current version (it said `v1` in v2).
- **v2** (2026-11-08): the app release targets (app-android, app-flutter, app-tauri, app-xcode) publish only with
  `CONFIRM=production`, and their CI release jobs pass it. Every CI job that decrypts secrets extends
  `.std-secrets`, so `SECRETS_DIR` is set; in v1 the app, docker, python, web-pages and cloud-worker jobs cloned
  the secrets repo to an empty path. The project pre-commit hook is recognised whatever version installed it.
- **v1**: the first version.
