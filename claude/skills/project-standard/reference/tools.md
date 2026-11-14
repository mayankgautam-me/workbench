# What each part kind does

Every target a kind adds, and the tool it runs. `<part>` is the part's name from `make/project.mk`
(for example `firmware`, `hardware`, `cloud-api`), so `build` below is `make <part>-build`. The root
command (`make build`) runs the same verb in every part that has it. Targets marked *extra* are not
fanned out from the root; run them by their full name.

Rules that hold for every kind:

- `ENV=local|staging|production`, default `local`.
- Anything that touches production, and every destroy, wipe or reset, needs `CONFIRM=<env>` typed on
  the make command line; every app `release` (TestFlight, Play, the OTA bucket) needs
  `CONFIRM=production`. Erase and recover need `CONFIRM=erase`, fuse burns `CONFIRM=fuse`.
- Secrets reach a command only through its environment (`secrets.sh exec`), and signing keys through
  a temporary file that is removed when the command ends (`secrets.sh with-file`).
- Toolchains live in `~/.toolchains/<tool>-<version>`, shared by every project; versions are pinned
  per part in `make/project.mk`.
  `make teardown` and `make prune` (`standard.md` 4.1) remove the ones the standard installed and no project records.
- `doctor` only reads; it never changes anything.
- A part's commands run its `setup` first when the part is not ready (a millisecond check of files; `standard.md` 4.1,
  Setup on demand): `> <part>: not set up yet, running make <part>-setup first`. setup, doctor, clean, distclean,
  version and bump never do, and nothing that needs you is chained.
- Each part also has `<dir>/README.md`, `<dir>/CHANGELOG.md` and its kind's docs in `docs/<part>/`
  (`standard.md` §1, "Documents"): the scaffold writes them once, then they are the project's.
- Releases that upload OTA images (firmware kinds, app-android, app-tauri `CHANNEL=ota`) use `OTA_BUCKET` from
  `make/project.mk` (or `<part>_OTA_BUCKET`), the project's own R2 bucket. A project with an OTA bucket uses the
  Cloudflare token even with no Worker or Pages part: `cf-login` asks for Workers R2 Storage Edit, `cf-token-check`
  probes R2, and the scaffold writes the `CLOUDFLARE_*` rows of `secrets.schema`. `make cf-provision
  ENV=production CONFIRM=production` creates the bucket (each `<part>_OTA_BUCKET` too) when missing, and with
  `OTA_PUBLIC := r2dev` in `make/project.mk` turns on its public r2.dev URL and prints it; `cf-status` shows it.
  `cf-wipe` and `cf-destroy` never touch it (one bucket serves every env).

## Releases (every kind)

Every part of every kind has these three, besides the kind's own targets below (`standard.md` §4.12 has the
version source and the release files of each kind):

| Target | What it does |
|---|---|
| bump `LEVEL=patch\\|minor\\|major` or `VERSION=x.y.z` | Sets the version in the kind's own source, moves the CHANGELOG's Unreleased notes under it, commits those files and tags `<part>-v<version>` (annotated); prints the push command, never pushes. An empty Unreleased refuses (`FORCE=1` goes on). Root `make bump PART=<part>` |
| release-assets *extra* | Builds (unless `NOBUILD=1`), then copies the kind's release files into `<dir>/release/<version>/` with `SHA256SUMS` (`release.sh`); app kinds build the files of `PLATFORM` (default: this machine) and write `SHA256SUMS-<platform>` (since v8, `standard.md` 4.12) |
| github-release | In the release job of the tag `<part>-v<version>` (`release.yml`): release-assets, then create or update the GitHub Release `<part> <version>` with the CHANGELOG section and every file attached (`gh`). Nothing on another part's tag; refuses outside a tag run unless `FORCE=1` on a Mac. No `CONFIRM` |


## Firmware

### zephyr: Zephyr / nRF Connect SDK (west)

| Target | What it does |
|---|---|
| doctor | Checks NCS, the Zephyr SDK, the probe, the signing key and the serial ports |
| setup | Installs the pinned NCS and Zephyr SDK into `~/.toolchains` (shallow `west init`, `west update`, SDK installer). In the nRF Connect SDK toolchain image (CI; recognised by `/opt/toolchain-env.sh`, `<part>_TOOLCHAIN_ENV`) it uses the image's python, west and Zephyr SDK and fetches only the NCS source tree, which the workflow caches per NCS version |
| update | Lists NCS releases, or pins `TO=vX.Y.Z [SDK=]` in `make/project.mk` and sets it up |
| check | Build with warnings as errors, plus `native_sim` tests on Linux |
| build | `west build --sysbuild --pristine auto -b $BOARD`, signed with the MCUboot key (Touch ID) |
| flash | Builds, then flashes with `PROBE=probe-rs\|jlink\|openocd\|nrfutil` (`NOBUILD=1` skips the build) |
| erase | Erases the whole chip (`CONFIRM=erase`) |
| recover *extra* | Unlocks a protected chip by erasing it all (`CONFIRM=erase`) |
| monitor | Serial console on `PORT` (or the only port), also logged to `build/monitor.log` |
| debug | GDB on the built image through the probe |
| size *extra* | ROM and RAM report |
| config *extra* | menuconfig |
| keygen *extra* | Creates the MCUboot signing key in the secrets repo; never overwrites one |
| provision *extra* | Per-device setup, `SERIAL=`, through the project's `<part>_PROVISION` hook (else flash only) |
| release | Signed `dfu_application.zip` to the OTA store (R2) as `<ver>/` and `latest/`; `PROMOTE=1` marks it stable. No OTA bucket (no Cloudflare): skipped with one line, exit 0, and left out of help |
| version | Version from `<dir>/VERSION` |
| clean / distclean | Remove the build output (toolchains are kept) |

### espidf: ESP-IDF (idf.py)

| Target | What it does |
|---|---|
| doctor | Checks ESP-IDF and its tools, the sdkconfig, the keys and the ports |
| setup | Installs the pinned ESP-IDF into `~/.toolchains/esp-idf-<ver>` (`install.sh <target>`) |
| update | Lists ESP-IDF releases, or pins `TO=vX.Y` and sets it up |
| check | Build with warnings as errors |
| build | `idf.py -B build/$TARGET -D SDKCONFIG=sdkconfig.$TARGET build` (signed when secure boot is on) |
| flash | Builds, then flashes with esptool; with flash encryption it reads the eFuses first and refuses a half-burned chip |
| erase | `esptool erase_flash` (`CONFIRM=erase`) |
| recover *extra* | The project's recovery hook for a partly burned chip |
| fuse-summary *extra* | Prints the eFuse summary (read only) |
| fuse-burn *extra* | Burns `EFUSE='NAME VALUE'`, irreversible (`CONFIRM=fuse`) |
| fuse-lockdown *extra* | Burns the project's lockdown fuse list, irreversible (`CONFIRM=fuse`) |
| monitor | `idf.py monitor` on `PORT`, logged |
| debug | OpenOCD and GDB through idf.py |
| size *extra* | Size report per component |
| config *extra* | menuconfig for `sdkconfig.$TARGET` |
| keygen *extra* | Creates the Secure Boot v2 key in the secrets repo |
| provision *extra* | Per-device setup, `SERIAL=` |
| release | App image to the OTA store as `<ver>/` and `latest/`; `PROMOTE=1` for stable. No OTA bucket (no Cloudflare): skipped with one line, exit 0, and left out of help |
| version / clean / distclean | Version from `VERSION`; remove build output |

### pio: PlatformIO

| Target | What it does |
|---|---|
| doctor | Checks pio, `platformio.ini` and the ports |
| setup | Installs the platforms and libraries of `platformio.ini` |
| update | Updates the platforms and libraries within `platformio.ini` |
| check | `pio check` static analysis, then the native host tests |
| test | `pio test -e native` (`TEST=pattern`) |
| build | `pio run -e $PIO_ENV`; without one, every env of `default_envs` |
| flash | `pio run -e <env> -t upload` on `PORT`, for one env (below) |
| erase | `pio run -e <env> -t erase` (`CONFIRM=erase`), for one env |
| monitor | `pio device monitor -e <env>`, logged |
| debug | `pio debug -e <env>` with GDB through the `debug_tool` of `platformio.ini` |
| size / config *extra* | RAM and flash use / menuconfig for ESP-IDF based envs |
| provision *extra* | Per-device setup, `SERIAL=`, for one env (exported as `PIO_ENV` to `<part>_PROVISION`) |
| release | Image to the OTA store as `<ver>/` and `latest/`. No OTA bucket (no Cloudflare): skipped with one line, exit 0, and left out of help |
| version / clean / distclean | Version; `pio run -t clean`; remove build output |

The env is `PIO_ENV=` from the command line, else `<part>_PIO_ENV` from `make/project.mk`. When neither is
set, build, check, size and clean run every env pio would (`default_envs`). The targets that talk to a board
(flash, erase, monitor, debug, provision) need exactly one: they take `PLATFORMIO_DEFAULT_ENVS` or the
`default_envs` of `platformio.ini` (commas, spaces, continuation lines and comments understood), else its
`[env:NAME]` sections, and refuse before running anything when that is more than one, naming the envs and
how to pick. `default_envs = rev3, rev4` is one image per board revision: uploading both to one board is
never what is meant.

### arm-gcc: bare arm-none-eabi (Makefile or CMake, libopencm3, CubeMX export)

| Target | What it does |
|---|---|
| doctor | Checks the cross compiler, the build system, the probe and the ports |
| setup | Checks the cross compiler (installed from the Brewfile) |
| check | Build with warnings as errors, or the part Makefile's `check` target |
| build | CMake, or the part's own Makefile |
| flash | Builds, then flashes with `PROBE=dfu\|stlink\|probe-rs\|openocd` |
| erase / recover *extra* | Whole-chip erase / unlock (`CONFIRM=erase`) |
| monitor / debug | Serial console, logged / GDB on the elf through the probe's GDB server |
| size *extra* | Section sizes of the elf |
| provision *extra* | Per-device setup, `SERIAL=` |
| release | Binary to the OTA store as `<ver>/` and `latest/`. No OTA bucket (no Cloudflare): skipped with one line, exit 0, and left out of help |
| version / clean / distclean | Version; remove build output and fetched libraries |

### circuitpython: CircuitPython image built in Docker

| Target | What it does |
|---|---|
| doctor | Checks Docker, the build image, the board and the `CIRCUITPY` volume |
| setup | Builds the Docker image that builds the pinned CircuitPython |
| check | Lints the Python code |
| build | Builds the CircuitPython firmware image for the board |
| flash | Flashes the image with esptool or UF2 |
| erase | Erases the whole flash, `CIRCUITPY` with it (`CONFIRM=erase`) |
| deploy *extra* | Copies the code to the `CIRCUITPY` volume |
| monitor | Serial REPL, logged |
| provision *extra* | Per-device setup, `SERIAL=` |
| release | Image to the OTA store as `<ver>/` and `latest/`. No OTA bucket (no Cloudflare): skipped with one line, exit 0, and left out of help |
| version / clean / distclean | Version; remove build output |

## Hardware

### hardware: KiCad 10 (kicad-cli)

| Target | What it does |
|---|---|
| doctor | Checks kicad-cli, the library path variables and iBOM; warns when KiCad has the board open |
| setup | Checks KiCad's library tables and path variables against `KICAD_LIBRARY_DIR` (unset: the library KiCad's `<prefix>_LIB_DIR` points at, from the `kicad_common.json` of the installed major); `APPLY=1` adds what is missing (after a backup) |
| new *extra* | Starts a board from the template, `NAME=`, `LAYERS=2\|4`, with JLCPCB design rules and stackup |
| check | ERC, and DRC with schematic parity; fails on violations |
| build | Gerbers, drill, positions, BOM, schematic PDF, STEP, WRL and the iBOM into `outputs/` |
| ibom *extra* | Interactive HTML BOM into `outputs/` |
| render *extra* | 3D renders of top and bottom into `outputs/` |
| bom *extra* | Hands sourcing and pricing to the `bom` skill |
| release | The board's GitHub Release, same as github-release: check, build, the JLCPCB fab zip (also `production/<Board>_v<rev>.zip`) and every output attached to the Release. The tag `<part>-v<rev>` comes from bump (since v7) |
| version | Board revision from `VERSION` or the title block |
| clean | Removes `outputs/` |

## Cloud and web

### cloud-worker: Cloudflare Worker (wrangler, D1, KV, R2, Queues, Durable Objects)

| Target | What it does |
|---|---|
| setup / doctor | `npm ci` or `pnpm install`; checks the packages and the pinned wrangler |
| dev | Applies local D1 migrations, then `wrangler dev` on the part's port with the local secrets in its environment |
| stop | Stops that `wrangler dev` |
| logs | `wrangler tail` of the deployed Worker in `ENV` |
| status | Declared bindings (dead-letter queues included) against what exists in `ENV` |
| check / test / format | Typecheck, lint, vitest (`TEST=pattern`); biome formatting when configured |
| build | Bundles with `wrangler deploy --dry-run` into `dist/` |
| deploy | check, build, migrate, `wrangler deploy --env $ENV`, then smoke. A production-only part (no `env.staging`) deploys this way with `ENV=production CONFIRM=production`; its `ENV=staging` is refused. In CI: staging on a push to main (with staging), production on the part's tag |
| smoke | Health check, then `tests/smoke`, against the URL of `ENV` |
| test-remote | `tests/remote` against the deployed `ENV` |
| preview | `wrangler versions upload`, then smoke on the preview URL |
| promote | Deploys to production the code that passed on staging (`CONFIRM=production`); only for parts with staging, by hand (CI deploys production on the tag instead) |
| versions / rollback | Lists deployed versions / rolls `ENV` back to the previous one |
| migrate *extra* | D1 migrations, local or remote by `ENV` |
| seed *extra* | Loads seed SQL into local or staging; production refused |
| provision *extra* | Creates the missing D1, KV, R2 and Queues of `ENV` (consumer queues and dead-letter queues too) and writes their ids back into `wrangler.jsonc` |
| secrets *extra* | Pushes the secrets the schema marks `cf` with `wrangler secret bulk` (`ROTATE=NAME` replaces one) |
| backup *extra* | D1 export and every KV value into an encrypted archive in `~/Backups/<project>/`; R2 bucket info only. **Durable Object storage is not backed up** |
| wipe *extra* | Backs up, then deletes the data and keeps the resources (`CONFIRM=<env>`) |
| destroy *extra* | Backs up, then deletes the Worker and resources of `ENV` (`CONFIRM=<env>`; production also asks you to type the project name). Deleting the Worker deletes its Durable Object storage too |
| reset | Wipes the local D1 and KV state, then migrates and seeds again (`CONFIRM=local`) |
| version | From `VERSION` (bump creates it). The tag `<part>-v<version>` deploys production in CI, then makes the GitHub Release with the CHANGELOG notes only (no files) |
| clean / distclean | Build output / plus installed packages |

Account-level commands, at the root only: `cf-login`, `cf-logout`, `cf-whoami`, `cf-token-check`
(one API token per project, stored in the secrets repo for staging and production; `cf-login` and
`cf-logout` need no `ENV`). `cf-login` opens the dashboard's token form pre-filled with the project name and
the permissions its `wrangler.jsonc` files and its OTA bucket (`OTA_BUCKET`: R2) need, prints the URL, the list and the zones to pick in the form
("Specific zone": the link cannot preset zones), then takes the pasted token (`CF_NO_BROWSER=1` prints only;
`CLOUDFLARE_API_TOKEN` in the environment skips the form). Enter at the account id prompt looks the account up
from the token, account-owned (`cfat_`) tokens included.

Managed bindings: D1, KV, R2 and Queues (producers, the queues consumers read, and their dead-letter
queues) are provisioned, shown by `status`, backed up (D1 and KV data; R2 bucket info) and name-checked by
wipe and destroy. Every other binding (Durable Objects, `send_email`, Workers AI, `unsafe` rate limits,
Workflows, Containers, service bindings, Access) is passed to wrangler on deploy and is not provisioned,
checked or backed up.

### web-pages: static, Vite or Next export sites (a static-assets Worker on its custom domain; Pages when asked for)

| Target | What it does |
|---|---|
| setup | Installs the site packages |
| dev | Framework dev server, or `wrangler pages dev`, on the part's port |
| check / test / format | Lint, typecheck, vitest; biome formatting |
| build | Framework build, or copies the static files into the output folder |
| deploy | check, build, `wrangler pages deploy` to the staging preview branch or to production, then smoke. With a `wrangler.jsonc` without `pages_build_output_dir` in the part dir the site is a static-assets Worker instead: `wrangler deploy --env $ENV` from the part dir (its custom domain the only address with `workers_dev` and `preview_urls` off), and provision has nothing to create. In CI: staging on a push to main, production on the part's tag. A production-only site (`scaffold.sh --production-only`) has no staging CI job |
| smoke / test-remote | Health path and `tests/smoke` / `tests/remote` against `ENV` |
| provision *extra* | Creates the Pages project for `ENV` when missing |
| status / versions / logs | The Pages project / recent deployments / Pages Functions logs |
| version | From `VERSION` (bump creates it). The tag deploys production in CI, then makes the GitHub Release with the CHANGELOG notes only (no files) |
| clean / distclean | Build output / plus packages |

## Apps

### app-flutter

| Target | What it does |
|---|---|
| setup / doctor | `flutter pub get`, `pod install` / `flutter doctor` |
| dev | `flutter run` with hot reload on `DEVICE` |
| check / test / format | `dart format` check, `flutter analyze`, `flutter test` / `dart format` |
| build | `TARGET=apk\|appbundle\|ios\|macos\|linux\|web`, release mode |
| release | `TARGET=ios` to TestFlight, or the app bundle to the Play track `TRACK`; signing keys from the secrets repo (`CONFIRM=production`) |
| logs | App log from the Android device or the iOS simulator |
| version / clean / distclean | From `pubspec.yaml`; `flutter clean` |

### app-tauri

| Target | What it does |
|---|---|
| doctor | cargo with clippy and rustfmt (mise pins `rust = { version = "...", components = "clippy,rustfmt" }`), and the part's package manager |
| setup | Front-end packages and Rust crates |
| dev | `tauri dev` for `TARGET=host\|ios\|android` |
| check / test / format | `svelte-kit sync` (SvelteKit) then svelte-check, and `cargo clippy -D warnings` / cargo and vitest tests / `cargo fmt` |
| build | `TARGET=host\|ios\|android\|linux` (Linux in Docker, with pnpm when the part has `pnpm-lock.yaml`), `BUNDLE=apk\|aab` for Android |
| release | iOS to TestFlight, Android to the R2 OTA channel or Play (`CONFIRM=production`, checked before the build) |
| logs / version / clean / distclean | Device log; version from `tauri.conf.json`; build output |

### app-xcode: Swift / SwiftUI

| Target | What it does |
|---|---|
| setup | Resolves the Swift packages |
| dev | Builds for the simulator, installs and launches |
| check / test | SwiftLint (strict, when configured) and a compile check / unit and UI tests on the simulator |
| build | Release build for `TARGET=ios\|macos`, unsigned |
| archive *extra* | Release archive into `build/` |
| release | Archive, export and upload to TestFlight with the App Store key (`CONFIRM=production`, checked before the archive) |
| logs / version / clean | Simulator log stream; marketing version; clean |

### app-android: Kotlin / Gradle (phone or Wear OS)

| Target | What it does |
|---|---|
| setup | Checks the Gradle wrapper and fetches dependencies |
| dev | Installs the debug build on `DEVICE` or the emulator and launches it |
| check / test | Gradle lint / local unit tests |
| build | Assembles the APK for `BUILD_TYPE` |
| release | Signed release to the R2 OTA channel (APK and `latest.json`) or to Play, by `CHANNEL` (`CONFIRM=production`) |
| devices / pair *extra* | Lists devices / pairs a phone over wireless debugging |
| logs / version / clean / distclean | adb logcat for the app; `versionName`; Gradle clean and caches |

## Services

### docker: images and compose

| Target | What it does |
|---|---|
| setup / doctor | Creates the buildx builder / checks the Docker daemon and buildx |
| dev / stop / logs / status | `docker compose up` with local secrets in its environment / down (volumes kept) / logs / services |
| reset | Removes the compose volumes (`CONFIRM=local`) |
| check | hadolint (when installed) and `docker compose config` |
| build | Multi-arch buildx build for `PLATFORMS`, no push |
| release | Builds and pushes to `DOCKER_REGISTRY`, tagged with the git sha, `ENV`, and `<version>` on the tag `<part>-v<version>` |
| version | From `VERSION` (bump creates it) |
| clean / distclean | Stops the stack and removes the local image / and its tags |

### go

| Target | What it does |
|---|---|
| setup / dev | `go mod download` / runs the service with local secrets |
| check / test / format | gofmt, `go vet`, `go test -race` / race tests / gofmt |
| build / release | Binary into `bin/` / binaries for `PLATFORMS` (linux and darwin, amd64 and arm64) with checksums into `dist/` |
| version / clean | From `VERSION` / remove binaries |

### python

| Target | What it does |
|---|---|
| setup / dev | `uv` virtual environment from `uv.lock` / runs the module with local secrets |
| check / test / format | ruff format and lint, then pytest / pytest / ruff format and fixes |
| build / release | sdist and wheel into `dist/` / checksums; publishes only with `PUBLISH=1 CONFIRM=production` |
| version / clean / distclean | From `pyproject.toml` / caches / and the virtual environment |

## Project-wide commands (every project)

| Command | What it does |
|---|---|
| help | Every command, grouped by stage, then by part |
| doctor, setup, update | Base tools (Brewfile, mise, git-lfs, hooks), then every part |
| hooks | Pre-commit hook: gitleaks, LFS check, files over 5 MB |
| dev, stop, status, logs, reset | The local stack, across parts |
| check, test, test-e2e, test-device, format | Across parts |
| build, deploy, smoke, test-remote, preview, promote, versions, rollback, release | Across parts, by `ENV` |
| flash, erase, monitor, debug | On the only firmware part, or `PART=` |
| version / bump `PART= LEVEL=` / github-release `PART=` | Versions of every part / release one part: version, CHANGELOG, commit, tag / its GitHub Release (the tag run does it) |
| cf-login, cf-logout, cf-whoami, cf-token-check | The project's one Cloudflare token (stored for staging and production); cf-login opens the pre-filled token form |
| cf-provision, cf-status, cf-migrate, cf-seed, cf-secrets, cf-backup, cf-wipe, cf-destroy | Cloudflare resources, per environment (cf-provision and cf-status also the project's OTA bucket) |
| secrets-init, -set, -import, -edit, -list, -check, -keygen, -rotate, -ci, -enroll, -recovery, -add-machine, -remove-machine, -sync, -doctor | The project's encrypted secrets repo: one per GitHub owner, the owner of the project's `origin` (`~/.secrets-<owner>`); secrets-init clones it, or starts it from an empty remote with the Macs' and the recovery recipients |
| ci-lint, ci-status, ci-logs, ci-run | `actionlint`; `gh run list` and `gh run view` on the current branch; `gh workflow run checks.yml` |
| ci-local `JOB=` | One job of `checks.yml` in Docker with `act`; no `JOB` lists them. Partial: the reusable workflows come from the public `CI_TEMPLATES_REPO` with no token (`GITHUB_TOKEN` only for a private one); some steps may not run here |
| ci-setup | Sets up CI once: the CI age key (secrets-ci), the read-only deploy keys (made in ~/.ssh when missing, added to the project's secrets repo and the KiCad library), their repo secrets, and the variables SECRETS_REPO (owner/name of SECRETS_REMOTE) and KICAD_LIBRARY_REPO; warns only when `CI_TEMPLATES_REPO` is not public (it then needs Settings > Actions > General > Access); safe to run again; no values |
| ci-setup-help | Prints the commands ci-setup runs, for you to run by hand; no values |
| clean, distclean | Build output / plus project-local dependencies |
