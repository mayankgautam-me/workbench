#!/usr/bin/env bash
# scaffold.sh: lay out a new project-standard project from the skill's templates.
#
#   scaffold.sh <dir> --project NAME --part name:kind[:dir] [--part ...] [--production-only NAME ...]
#               [--domain NAME=HOST ...] [--pages NAME ...] [--port-base N] [--force]
#
# Copies the managed make files (common.mk, bin/, the kinds the parts use) and the project templates,
# fills project.mk, Brewfile, mise.toml, .gitignore, .github/workflows/checks.yml and release.yml, secrets.schema,
# README.md and PLAN.md, and creates a minimal starter for each part whose folder does not exist yet. It writes the
# documents: docs/README.md, docs/architecture.md, docs/operations.md (with a deployable part), docs/references.md
# (links to the reference documents), and per part
# <dir>/README.md, <dir>/CHANGELOG.md and the kind's docs in docs/<part>/; each only when it does not exist. It
# never runs a network command and never touches git: `git init`, `make setup` and `make secrets-init` are separate
# steps.
#
# --production-only NAME marks a cloud-worker or web-pages part that has no staging: a push to main deploys nothing
# for it (no deploy-staging). Every cloud-worker and web-pages part goes to production on its tag <part>-v<version>:
# release.yml's <part>-release job deploys production, then makes the notes-only GitHub Release. A cloud-worker part
# whose existing wrangler.jsonc has env.production but no env.staging is marked production-only without the option.
#
# A web-pages part is a static-assets Worker on its own custom domain: --domain NAME=HOST gives the production host
# (staging, when the part has it, is <label>-staging.<zone>), and its wrangler.jsonc turns workers.dev and preview
# URLs off, so the domain is the site's only address. --pages NAME makes it a Cloudflare Pages project instead (only
# when the user asks for Pages: Pages always keeps *.pages.dev). Without --domain the host is a CHANGE-ME placeholder
# the audit reports. The wrangler.jsonc is written when missing, also in a part folder that exists (adopt).
#
# A part given without a dir goes in the folder of its kind (firmware/, hardware/, mechanical/, cloud/, web/, app/) when
# it is the only part of that group, else in <folder>/<name>; explicit dirs are used as given. altium shares hardware/
# with hardware, silabs firmware/ with the other firmware kinds.
#
# Refuses a non-empty <dir> unless --force. With --force, managed files are (re)written and files
# the project owns (project.mk, local.mk, README.md, PLAN.md, ...) are kept when they exist.
set -euo pipefail

readonly STD_VERSION=1.5
SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly SKILL_DIR
readonly TPL_MAKE="$SKILL_DIR/templates/make"
readonly TPL_PROJECT="$SKILL_DIR/templates/project"
readonly KINDS="zephyr espidf pio arm-gcc circuitpython silabs hardware altium mechanical cloud-worker web-pages app-flutter app-tauri app-xcode app-android docker go python"
readonly WRANGLER_VERSION="4.42.0"
readonly TYPESCRIPT_VERSION="5.9.3"
readonly VITEST_VERSION="3.2.4"
readonly RUST_MISE='rust = { version = "1.90", components = "clippy,rustfmt" }'

# ---------------------------------------------------------------------------------------------
# output

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[38;2;247;118;142m'
  C_GREEN=$'\033[38;2;158;206;106m'
  C_BLUE=$'\033[38;2;122;162;247m'
  C_YELLOW=$'\033[38;2;224;175;104m'
  C_DIM=$'\033[38;2;86;95;137m'
  C_OFF=$'\033[0m'
else
  C_RED='' C_GREEN='' C_BLUE='' C_YELLOW='' C_DIM='' C_OFF=''
fi

die() {
  printf '%sscaffold:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: scaffold.sh <dir> --project NAME --part name:kind[:dir] [--part ...] [--production-only NAME ...]
       [--domain NAME=HOST ...] [--pages NAME ...]
                   [--port-base N] [--force]

--production-only NAME   a cloud-worker or web-pages part with no staging (repeat for several)
--domain NAME=HOST       the production custom domain of a web-pages part (its only address)
--pages NAME             a web-pages part on Cloudflare Pages instead of a Worker (only when asked for)

A part given without a dir goes in the folder of its kind (firmware/ hardware/ mechanical/ cloud/ web/ app/) when it is
the only part of that group, else in <folder>/<name>. An explicit dir is used as given.

kinds: firmware zephyr espidf pio arm-gcc circuitpython silabs; hardware hardware altium; mechanical mechanical;
       cloud cloud-worker web-pages; apps app-flutter app-tauri app-xcode app-android; services docker go python
EOF
}

note() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }

# ---------------------------------------------------------------------------------------------
# kind tables (bash 3.2: no associative arrays, so one case per table)

# kind_group KIND: the folder a part of this kind lives in (reference/standard.md section 1).
kind_group() {
  case $1 in
    zephyr | espidf | pio | arm-gcc | circuitpython | silabs) printf 'firmware' ;;
    hardware | altium) printf 'hardware' ;;
    mechanical) printf 'mechanical' ;;
    cloud-worker | docker | go | python) printf 'cloud' ;;
    web-pages) printf 'web' ;;
    app-flutter | app-tauri | app-xcode | app-android) printf 'app' ;;
  esac
}

kind_known() {
  local k
  for k in $KINDS; do
    [[ $k == "$1" ]] && return 0
  done
  return 1
}

kind_tech() {
  case $1 in
    zephyr) echo "Zephyr / nRF Connect SDK firmware: west, sysbuild, MCUboot" ;;
    espidf) echo "ESP-IDF firmware: idf.py, esptool" ;;
    pio) echo "PlatformIO firmware" ;;
    arm-gcc) echo "bare-metal Cortex-M firmware: arm-none-eabi-gcc, libopencm3 or CubeMX" ;;
    circuitpython) echo "CircuitPython firmware: circup" ;;
    silabs) echo "Silicon Labs firmware: Simplicity SDK, WiseConnect, slc, Simplicity Commander" ;;
    hardware) echo "KiCad 10 board: kicad-cli, JLCPCB rules" ;;
    altium) echo "Altium Designer board: OutJob outputs, Git LFS" ;;
    mechanical) echo "FreeCAD models: freecadcmd, STEP and STL" ;;
    cloud-worker) echo "Cloudflare Worker: TypeScript, wrangler, D1 / KV / R2" ;;
    web-pages) echo "static site on Cloudflare Pages: wrangler" ;;
    app-flutter) echo "Flutter app" ;;
    app-tauri) echo "Tauri desktop app: Rust, TypeScript" ;;
    app-xcode) echo "Swift / SwiftUI app: Xcode" ;;
    app-android) echo "Android app: Kotlin, Compose, Gradle" ;;
    docker) echo "container image and compose service: Docker buildx" ;;
    go) echo "Go service" ;;
    python) echo "Python package or service: uv, ruff, pytest" ;;
  esac
}

# Brewfile lines per kind (the base list is in templates/project/Brewfile).
kind_brew() {
  case $1 in
    zephyr) printf '%s\n' 'brew "cmake"' 'brew "ninja"' 'brew "dtc"' 'brew "gperf"' 'brew "ccache"' 'cask "segger-jlink"' ;;
    espidf) printf '%s\n' 'brew "cmake"' 'brew "ninja"' 'brew "dfu-util"' 'brew "ccache"' 'brew "libusb"' ;;
    arm-gcc) printf '%s\n' 'cask "gcc-arm-embedded"' 'brew "openocd"' 'brew "stlink"' 'brew "dfu-util"' ;;
    silabs) printf '%s\n' 'cask "segger-jlink"' 'brew "tio"' ;;
    hardware) printf '%s\n' 'cask "kicad"' ;;
    mechanical) printf '%s\n' 'cask "freecad"' ;;
    app-flutter) printf '%s\n' 'cask "flutter"' 'brew "cocoapods"' ;;
    app-xcode) printf '%s\n' 'brew "xcbeautify"' 'brew "swiftlint"' ;;
    app-android) printf '%s\n' 'cask "temurin@21"' 'cask "android-commandlinetools"' ;;
    docker) printf '%s\n' 'brew "docker"' 'brew "docker-buildx"' 'brew "docker-compose"' 'brew "hadolint"' ;;
    go) printf '%s\n' 'brew "golangci-lint"' ;;
    *) : ;;
  esac
}

# mise.toml [tools] lines per kind. Rust always comes with clippy and rustfmt: mise installs the minimal
# profile otherwise, and check runs clippy (CI too, where .std-mise installs from this file).
kind_mise() {
  case $1 in
    zephyr | espidf) printf '%s\n' 'python = "3.12"' ;;
    circuitpython | python) printf '%s\n' 'python = "3.12"' 'uv = "0.9"' ;;
    cloud-worker | web-pages) printf '%s\n' 'node = "22"' 'pnpm = "10"' ;;
    app-tauri) printf '%s\n' 'node = "22"' 'pnpm = "10"' "$RUST_MISE" ;;
    pio) printf '%s\n' 'python = "3.12"' 'uv = "0.9"' '"pipx:platformio" = "6"' ;;
    go) printf '%s\n' 'go = "1.25"' ;;
    *) : ;;
  esac
}

kind_ignore() {
  case $1 in
    zephyr | arm-gcc) printf '%s\n' 'build/' 'build-*/' ;;
    espidf) printf '%s\n' 'build/' 'managed_components/' 'sdkconfig.old' ;;
    pio) printf '%s\n' '.pio/' '.pioenvs/' '.piolibdeps/' ;;
    circuitpython) printf '%s\n' '__pycache__/' ;;
    silabs) printf '%s\n' 'build/' ;;
    hardware) printf '%s\n' 'outputs/' '*-backups/' '_autosave-*' '*.lck' 'fp-info-cache' '*.kicad_prl' ;;
    altium) grep -v '^#' "$SKILL_DIR/templates/altium/gitignore" | grep -v '^[[:space:]]*$' ;;
    mechanical) printf '%s\n' 'outputs/' '*.FCBak' '*.FCStd1' ;;
    cloud-worker) printf '%s\n' 'node_modules/' '.wrangler/' 'dist/' ;;
    web-pages) printf '%s\n' 'node_modules/' '.wrangler/' 'dist/' '.svelte-kit/' '.astro/' 'vite.config.*.timestamp-*' ;;
    app-flutter) printf '%s\n' '.dart_tool/' '.flutter-plugins' '.flutter-plugins-dependencies' 'build/' 'Pods/' ;;
    app-tauri) printf '%s\n' 'node_modules/' 'dist/' 'src-tauri/target/' 'src-tauri/gen/' '.svelte-kit/' 'vite.config.*.timestamp-*' ;;
    app-xcode) printf '%s\n' 'DerivedData/' 'xcuserdata/' '*.xcuserstate' 'build/' ;;
    app-android) printf '%s\n' '.gradle/' 'build/' 'local.properties' '.kotlin/' 'captures/' ;;
    docker) printf '%s\n' '.docker-cache/' ;;
    go) printf '%s\n' '*.test' 'coverage.out' '__debug_bin*' ;;
    python) printf '%s\n' '__pycache__/' '.venv/' '.pytest_cache/' '.ruff_cache/' '.mypy_cache/' '*.egg-info/' ;;
  esac
}

# Commented per-part settings for make/project.mk. Every comment is a line of its own above its assignment, never after
# a value: make keeps the spaces before a trailing `#` in the value, so `X := a   # note`, once uncommented, sets X to
# "a   " (tests/lint.bats checks every := line the scaffold writes).
kind_settings() {
  local p=$1 k=$2 d=$3
  case $k in
    zephyr)
      echo "# the board: fill in before the first build, see $d/README.md"
      echo "# ${p}_BOARD := <board>"
      echo "# nRF Connect SDK version, installed into ~/.toolchains"
      echo "# ${p}_NCS := v3.2.1"
      ;;
    espidf)
      echo "# the chip: fill in before the first build, see $d/README.md"
      echo "# ${p}_TARGET := esp32s3"
      echo "# ESP-IDF version, installed into ~/.toolchains"
      echo "# ${p}_IDF := v5.5"
      ;;
    pio)
      echo "# an [env:...] of $d/platformio.ini, see $d/README.md"
      echo "# ${p}_PIO_ENV := <env>"
      ;;
    arm-gcc)
      echo "# the board: fill in before the first build, see $d/README.md"
      echo "# ${p}_BOARD := <board>"
      echo "# the probe: probe-rs jlink openocd stlink dfu"
      echo "# ${p}_PROBE := openocd"
      ;;
    circuitpython)
      echo "# where the board is mounted"
      echo "# ${p}_DRIVE := /Volumes/CIRCUITPY"
      ;;
    silabs)
      echo "# the slc board (radio board), see $d/README.md"
      echo "# ${p}_BOARD := brd4338a"
      echo "# Simplicity SDK version"
      echo "# ${p}_SDK := 2025.12.2"
      echo "# WiseConnect version"
      echo "# ${p}_WISECONNECT := 4.0.1"
      echo "# the probe: commander or jlink"
      echo "# ${p}_PROBE := commander"
      echo "# the GNU Arm toolchain slt installs with the SDK (the <ver>-*manifest.txt of its package)"
      echo "# ${p}_GCC := 12.2.rel1"
      ;;
    hardware)
      echo "# the board's own sym-lib-table and fp-lib-table instead of the shared KiCad library"
      echo "# ${p}_LIBRARY := local"
      ;;
    web-pages)
      echo "# what gets deployed: the build output folder"
      echo "${p}_OUT := $d/public"
      if ! is_pages "$p"; then
        echo "# a static-assets Worker ($d/wrangler.jsonc) on its custom domain, its only address"
        is_prod_only "$p" || echo "${p}_URL_staging := https://$(web_staging_host "$(web_host "$p")")"
        echo "${p}_URL_production := https://$(web_host "$p")"
      fi
      ;;
    *) : ;;
  esac
  if is_prod_only "$p"; then
    echo "# $p is production-only (no staging): make $p-deploy ENV=production CONFIRM=production deploys it"
  fi
  case $k in
    cloud-worker | web-pages | go | python)
      echo "# dev port of $p: PORT_BASE + $PORT_OFFSET"
      echo "${p}_PORT_OFFSET := $PORT_OFFSET"
      PORT_OFFSET=$((PORT_OFFSET + 1))
      ;;
  esac
}

# Starter tasks for PLAN.md.
kind_tasks() {
  local p=$1 k=$2 d=$3
  case $k in
    zephyr | espidf | pio | arm-gcc | circuitpython | silabs)
      echo "- [ ] Board set in make/project.mk (see $d/README.md) {#$p-board}"
      echo "- [ ] First build with make $p-build and flash with make $p-flash {#$p-first-build}"
      ;;
    hardware)
      echo "- [ ] Board started with make $p-new NAME=<board> {#$p-new}"
      echo "- [ ] ERC and DRC clean with make $p-check {#$p-check}"
      ;;
    altium)
      echo "- [ ] Board files in the standard layout (make $p-layout prints the moves) {#$p-layout}"
      echo "- [ ] make $p-check passes and make $p-build packages the OutJob's outputs {#$p-check}"
      ;;
    mechanical)
      echo "- [ ] First FreeCAD model in $d (*.FCStd, in Git LFS) {#$p-create}"
      echo "- [ ] make $p-check recomputes every model and make $p-build exports STEP and STL {#$p-check}"
      ;;
    cloud-worker)
      echo "- [ ] Project Cloudflare API token stored with make cf-login {#$p-token}"
      if is_prod_only "$p"; then
        echo "- [ ] First production deploy with make $p-deploy ENV=production CONFIRM=production {#$p-first-deploy}"
      else
        echo "- [ ] First staging deploy with make deploy ENV=staging PART=$p {#$p-first-deploy}"
      fi
      ;;
    web-pages)
      if is_prod_only "$p"; then
        echo "- [ ] Pages project created with make $p-provision ENV=production CONFIRM=production {#$p-provision}"
        echo "- [ ] First production deploy with make $p-deploy ENV=production CONFIRM=production {#$p-first-deploy}"
      else
        echo "- [ ] Pages project created with make $p-provision ENV=staging {#$p-provision}"
        echo "- [ ] First staging deploy with make deploy ENV=staging PART=$p {#$p-first-deploy}"
      fi
      ;;
    app-*)
      echo "- [ ] Native project created in $d (see $d/README.md) {#$p-create}"
      echo "- [ ] make $p-build passes {#$p-first-build}"
      ;;
    docker)
      echo "- [ ] Dockerfile and compose.yaml in $d {#$p-create}"
      echo "- [ ] make $p-build builds the image {#$p-first-build}"
      ;;
    go)
      echo "- [ ] Go module created in $d {#$p-create}"
      echo "- [ ] make $p-check passes {#$p-first-check}"
      ;;
    python)
      echo "- [ ] Python project created in $d with uv {#$p-create}"
      echo "- [ ] make $p-check passes {#$p-first-check}"
      ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# documents: project-owned, written once; a doc that exists is never overwritten

# The docs a part of kind K gets under docs/<part>/, by name (without .md).
kind_docs() {
  case $1 in
    zephyr | espidf | pio | arm-gcc | circuitpython) echo "protocol flashing" ;;
    silabs) echo "protocol flashing power" ;;
    hardware) echo "bringup manufacturing" ;;
    altium) echo "bringup manufacturing library" ;;
    mechanical) echo "assembly" ;;
    cloud-worker) echo "api data" ;;
    app-*) echo "distribution" ;;
    docker | go | python) echo "usage" ;;
    *) : ;;
  esac
}

doc_title() {
  case $1 in
    protocol) echo "Protocol" ;;
    flashing) echo "Flashing" ;;
    bringup) echo "Bring-up" ;;
    manufacturing) echo "Manufacturing" ;;
    power) echo "Power" ;;
    assembly) echo "Assembly" ;;
    api) echo "API" ;;
    data) echo "Data" ;;
    distribution) echo "Distribution" ;;
    usage) echo "Usage" ;;
    library) echo "Library" ;;
  esac
}

doc_what() {
  case $1 in
    protocol) echo "commands, messages and the BLE / HID / USB / serial interfaces" ;;
    flashing) echo "bootloader, recovery, factory programming, board revisions" ;;
    bringup) echo "first power-on and test checklist" ;;
    manufacturing) echo "fab and assembly options, stackup, design rules, supplier notes" ;;
    power) echo "power modes, measured currents, battery life" ;;
    assembly) echo "parts, fasteners, assembly order, printing and machining notes" ;;
    api) echo "endpoints, authentication, errors" ;;
    data) echo "D1 tables, KV keys, R2 layout, migrations" ;;
    distribution) echo "bundle ids, signing, stores, OTA channel, permissions" ;;
    usage) echo "CLI or service usage, configuration, environment" ;;
    library) echo "the shared Altium library: its submodule, adding a part, the library check" ;;
  esac
}

# Where a part of kind K runs, for docs/architecture.md.
kind_runs_on() {
  case $1 in
    zephyr | espidf | pio | arm-gcc | circuitpython | silabs) echo "the device's microcontroller" ;;
    hardware) echo "the board itself (made from this part's KiCad files)" ;;
    altium) echo "the board itself (made from this part's Altium files)" ;;
    mechanical) echo "the enclosure and mechanical parts (made from this part's FreeCAD models)" ;;
    cloud-worker) echo "Cloudflare Workers" ;;
    web-pages) echo "Cloudflare Pages" ;;
    app-flutter) echo "phones, tablets and desktops (Flutter)" ;;
    app-tauri) echo "desktops, and phones where built for them (Tauri)" ;;
    app-xcode) echo "iPhone, iPad or Mac" ;;
    app-android) echo "Android phones and tablets" ;;
    docker) echo "a container host (the image is in GitHub Container Registry, ghcr.io)" ;;
    go) echo "a server or the user's machine (Go binary)" ;;
    python) echo "a server or the user's machine (Python)" ;;
  esac
}

is_deployable_kind() {
  case $1 in cloud-worker | web-pages | docker) return 0 ;; esac
  return 1
}

# own_doc REL < content: write a project-owned doc unless it exists.
own_doc() {
  if [[ -e "$DEST/$1" ]]; then
    cat >/dev/null
    note "kept existing $1"
    return 0
  fi
  write_file "$DEST/$1"
}

# up_of DIR: the relative path from DIR back to the project root ("../", "../../", ...).
up_of() {
  local d=$1 up='../'
  while [[ $d == */* ]]; do
    d=${d#*/}
    up="../$up"
  done
  printf '%s\n' "$up"
}

# The "Build and run" and "Configuration" sections of a part's README, per kind.
readme_build() {
  local p=$1 k=$2
  case $k in
    zephyr)
      echo "\`make setup\` installs the nRF Connect SDK into ~/.toolchains. Then \`make $p-build\`, \`make $p-flash\`,"
      echo "\`make $p-monitor\` and \`make $p-debug\` work from the project root; \`make help\` lists the rest."
      ;;
    espidf)
      echo "\`make setup\` installs ESP-IDF into ~/.toolchains. Then \`make $p-build\`, \`make $p-flash\`, \`make $p-monitor\`"
      echo "from the project root."
      ;;
    pio)
      echo "Put \`platformio.ini\` here. Then \`make $p-build\`, \`make $p-flash\`, \`make $p-monitor\` from the project root."
      ;;
    arm-gcc)
      echo "\`make $p-build\`, \`make $p-flash\`, \`make $p-debug\` from the project root (arm-none-eabi-gcc; libopencm3 or a"
      echo "CubeMX export)."
      ;;
    circuitpython)
      echo "\`code.py\` and \`lib/\` live here. \`make $p-flash\` copies them to the board, \`make $p-monitor\` opens the"
      echo "serial console."
      ;;
    silabs)
      echo "\`make setup\` installs slt, and through it slc, the Simplicity SDK and WiseConnect. Put the slc project"
      echo "(\`*.slcp\`) here; then \`make $p-build\`, \`make $p-flash\`, \`make $p-monitor\` and \`make $p-power\` work"
      echo "from the project root."
      ;;
    altium)
      echo "Altium Designer (Windows) makes the outputs: run the board's OutJob, which writes into \`outputs/\`, the BOM"
      echo "(\`*BOM*.csv\`) among them. \`make $p-check\` checks the layout, the documents and Git LFS, \`make $p-build\` checks the outputs and"
      echo "packages the fab zip into \`production/\`; \`make $p-layout\` prints the moves into the standard layout."
      ;;
    mechanical)
      echo "FreeCAD models (\`*.FCStd\`, in Git LFS) live here. \`make $p-check\` opens and recomputes every model,"
      echo "\`make $p-build\` exports each visible body or part to STEP and STL in \`outputs/\`."
      ;;
    hardware)
      echo "Start a board from the template (title block, JLCPCB design rules and stackup, the shared library):"
      echo
      echo "    make $p-new NAME=<board>"
      echo
      echo "\`make $p-check\` runs ERC and DRC, \`make $p-build\` writes the fabrication outputs into \`outputs/\`;"
      echo "a revision's fab files are published by its GitHub Release (Release, below)."
      ;;
    cloud-worker)
      local deploy_env='ENV=staging'
      is_prod_only "$p" && deploy_env='ENV=production CONFIRM=production'
      echo "\`make dev\` runs it locally with local D1 / KV / R2; \`make $p-deploy $deploy_env\` checks, builds,"
      echo "migrates, deploys and smoke-tests it. \`GET /health\` is what \`make smoke\` calls."
      ;;
    web-pages)
      echo "Served from \`public/\` (or the build output set in \`wrangler.jsonc\`). \`make dev\` serves it locally,"
      if is_prod_only "$p"; then
        echo "\`make $p-deploy ENV=production CONFIRM=production\` publishes it (production-only: no staging)."
      else
        echo "\`make deploy ENV=staging\` publishes a preview deployment, \`make deploy ENV=production CONFIRM=production\`"
        echo "the production one."
      fi
      ;;
    app-flutter)
      echo "Create it here with \`flutter create --org <org> .\` (from this folder), then use \`make $p-dev\`,"
      echo "\`make $p-build\`, \`make $p-release TARGET=ios|android CONFIRM=production\` from the project root."
      ;;
    app-tauri)
      echo "Create it here with \`pnpm create tauri-app\`, then use \`make $p-dev\`, \`make $p-build\`,"
      echo "\`make $p-release TARGET=macos|linux CONFIRM=production\` from the project root."
      ;;
    app-xcode)
      echo "Create the Xcode project in this folder, then use \`make $p-build\`, \`make $p-dev\` (simulator) and"
      echo "\`make $p-release TARGET=ios|macos CONFIRM=production\` from the project root."
      ;;
    app-android)
      echo "Create the Gradle project in this folder (Android Studio, New Project), then use \`make $p-build\` and"
      echo "\`make $p-release TARGET=android CONFIRM=production\` from the project root."
      ;;
    docker)
      echo "Put the \`Dockerfile\` (and \`compose.yaml\` for \`make dev\`) here. \`make $p-build\` builds it for amd64"
      echo "and arm64, \`make $p-release\` pushes it."
      ;;
    go)
      echo "Create the module here with \`go mod init <module>\`, then \`make $p-check\` runs gofmt, go vet and"
      echo "\`go test -race\`; \`make $p-dev\` runs it."
      ;;
    python)
      echo "Create it here with \`uv init\`, then \`make $p-check\` runs ruff and pytest; \`make $p-dev\` runs it."
      ;;
  esac
}

readme_config() {
  local p=$1 k=$2 d=$3
  case $k in
    zephyr)
      echo "Set the board in \`make/project.mk\` before the first build:"
      echo
      echo "    ${p}_BOARD := <board>          # for example nrf9151dk/nrf9151/ns"
      echo "    ${p}_NCS   := v3.2.1           # optional: the nRF Connect SDK version"
      ;;
    espidf)
      echo "Set the chip in \`make/project.mk\` before the first build:"
      echo
      echo "    ${p}_TARGET := <target>        # for example esp32s3"
      echo "    ${p}_IDF    := v5.5            # optional: the ESP-IDF version"
      ;;
    pio)
      echo "Pick the \`platformio.ini\` environment in \`make/project.mk\`:"
      echo
      echo "    ${p}_PIO_ENV := <env>          # one of the [env:...] sections"
      ;;
    arm-gcc)
      echo "Set the board and the probe in \`make/project.mk\` before the first build:"
      echo
      echo "    ${p}_BOARD := <board>"
      echo "    ${p}_PROBE := openocd          # probe-rs jlink openocd stlink dfu"
      ;;
    circuitpython)
      echo "\`${p}_DRIVE\` in \`make/project.mk\` when the board is not mounted at /Volumes/CIRCUITPY."
      ;;
    silabs)
      echo "Set the board in \`make/project.mk\` before the first build:"
      echo
      echo "    ${p}_BOARD       := <board>    # for example brd4338a (SiWx917 radio board)"
      echo "    ${p}_SDK         := 2025.12.2  # optional: the Simplicity SDK version"
      echo "    ${p}_WISECONNECT := 4.0.1      # optional: the WiseConnect version"
      echo "    ${p}_SIGN        := 1          # optional: sign the image with the key silabs-m4"
      ;;
    hardware)
      echo "The shared KiCad library comes from \`KICAD_LIBRARY_DIR\` (user config) or KiCad's own setting;"
      echo "\`make $p-doctor\` says which. \`${p}_LIBRARY := local\` in \`make/project.mk\` uses the board's own"
      echo "library tables instead (no shared library, none checked out in CI)."
      ;;
    altium)
      echo "The layout is fixed (\`<Board>.PrjPcb\`, \`.SchDoc\`, \`.PcbDoc\` and \`.OutJob\` here, \`sheets/\`,"
      echo "\`library/\`); \`make $p-check\` enforces it. The revision is \`VERSION\`. The BOM is the one the OutJob writes"
      echo "to \`outputs/\` (\`*BOM*.csv\`, and its \`.xlsx\`), not a committed file: \`make $p-bom\` hands it to the \`bom\` skill."
      echo
      echo "Parts come from the shared Altium library, a git submodule at \`$(altium_library)\` (\`ALTIUM_LIBRARY\`;"
      echo "the repository is \`ALTIUM_LIBRARY_PROJECT\`, by default \`<owner>/altium-library\`). \`make $p-setup\` adds it,"
      echo "or in a fresh clone checks it out:"
      echo
      echo "    git submodule update --init -- $(altium_library)"
      echo
      echo "The board's project uses its \`Library.DbLib\` by a relative path; \`make $p-lib-check\` (and \`make $p-check\`)"
      echo "checks every part against it (Library, under Docs)."
      ;;
    mechanical)
      echo "\`FREECADCMD\` (user config or environment) when freecadcmd is neither on PATH nor in FreeCAD.app."
      ;;
    cloud-worker)
      # shellcheck disable=SC2016 # the backticks are Markdown
      local env_list='`env.staging` and `env.production`'
      # shellcheck disable=SC2016 # the backticks are Markdown
      is_prod_only "$p" && env_list='`env.production` (production-only: add `env.staging` to get a staging environment)'
      echo "Bindings are declared in \`wrangler.jsonc\`, under \`env.local\`, $env_list; then"
      echo "\`make cf-provision ENV=<env>\` creates them. Secrets are lines in \`secrets.schema\`, pushed with"
      echo "\`make cf-secrets ENV=<env>\`. \`${p}_PORT_OFFSET\` in \`make/project.mk\` sets the dev port."
      ;;
    web-pages)
      echo "\`${p}_OUT\` in \`make/project.mk\` is the folder that gets deployed (default \`$d/public\`)."
      ;;
    app-*)
      echo "Signing keys and store credentials are in the secrets repo (names in \`secrets.schema\`), never here."
      ;;
    docker | go | python)
      echo "Settings come from the environment: secrets through \`secrets.schema\` (\`make dev\` loads them),"
      echo "the rest as \`${p}_*\` variables in \`make/project.mk\`."
      ;;
  esac
}

# readme_release P K D: the Release section of the part's README: bump, push the tag, what the tag workflow publishes.
readme_release() {
  local p=$1 k=$2 d=$3 manual
  echo "Write what changed under \`## [Unreleased]\` in [CHANGELOG.md](CHANGELOG.md) as you go. To release:"
  echo
  echo "    make $p-bump LEVEL=patch       # or minor, major, or VERSION=x.y.z"
  echo "    make release-push              # the branch, then each new release tag in its own push"
  echo
  echo "\`$p-bump\` sets the version in $(version_source "$k" "$d"), moves the Unreleased notes under it, commits them and"
  case $k in
    cloud-worker | web-pages)
      echo "tags \`$p-v<version>\`; it pushes nothing. Pushing the tag deploys production: the tag's workflow"
      echo "(.github/workflows/release.yml) checks, builds and runs \`make $p-deploy ENV=production CONFIRM=production\`,"
      echo "then creates the GitHub Release \"$p <version>\" with those notes and no files, so a Release is what is live."
      ;;
    altium)
      echo "tags \`$p-v<version>\`; it pushes nothing. No workflow makes this part's GitHub Release \"$p <version>\"."
      ;;
    *)
      echo "tags \`$p-v<version>\`; it pushes nothing. The tag's workflow (.github/workflows/release.yml) builds the release"
      echo "files and creates the GitHub Release \"$p <version>\" with those notes; the files are attached to it."
      ;;
  esac
  # the production steps run by hand from the Actions tab: workflow_dispatch of release.yml with part and confirm
  manual="from the Actions tab: release.yml with part \`$p\` and confirm \`production\`"
  case $k in
    zephyr | espidf | pio | arm-gcc | circuitpython | silabs)
      if fw_publishes; then
        echo "The OTA upload stays manual, $manual (locally: \`make $p-release ENV=production CONFIRM=production\`)."
      else
        echo "No OTA upload: the project has no OTA bucket (no Cloudflare), so \`make $p-release\` skips the publish."
        echo "Set \`OTA_BUCKET\` in \`make/project.mk\` and scaffold the workflows again to publish."
      fi
      ;;
    app-*)
      echo "Store publishing stays manual, $manual."
      ;;
    cloud-worker | web-pages)
      if is_prod_only "$p"; then
        echo "A push to main deploys nothing (production-only: no staging)."
      else
        echo "A push to main deploys staging; production only ever comes from the tag."
      fi
      echo "A hotfix without a new version runs $manual,"
      echo "on the ref to deploy (locally: \`make $p-deploy ENV=production CONFIRM=production\`)."
      ;;
    hardware)
      echo "The fab zip, BOMs, CPL, netlist, schematic PDF, iBOM and 3D files are attached to the Release."
      ;;
    altium)
      echo "Altium runs on Windows only, so CI only checks the board. After the bump and \`make release-push\`, run"
      echo "\`make $p-github-release FORCE=1\` where the OutJob's outputs are (Git Bash on that Windows machine, or a Mac"
      echo "they were copied to). It attaches the fab zip and the outputs to the Release."
      ;;
    mechanical)
      echo "The STEP and STL exports and the \`.FCStd\` models are attached to the Release."
      ;;
    docker)
      echo "The workflow pushes the image to ghcr.io tagged \`:<version>\` and records its digest in the Release."
      ;;
    python)
      echo "PyPI only by hand, $manual (locally: \`make $p-release PUBLISH=1 CONFIRM=production\`)."
      ;;
  esac
}

# version_source K D: where the kind keeps its version, for the README.
version_source() {
  case $1 in
    app-flutter) echo "\`$2/pubspec.yaml\`" ;;
    app-tauri) echo "\`$2/src-tauri/tauri.conf.json\`, \`$2/src-tauri/Cargo.toml\` and \`$2/package.json\`" ;;
    app-android) echo "\`$2/app/build.gradle.kts\` (versionName)" ;;
    app-xcode) echo "the Xcode project (agvtool)" ;;
    python) echo "\`$2/pyproject.toml\`" ;;
    *) echo "\`$2/VERSION\`" ;;
  esac
}

# part_readme P K D: the part's README.md, unless it exists.
part_readme() {
  local p=$1 k=$2 d=$3 up name
  up=$(up_of "$d")
  {
    printf '# %s\n\n' "$p"
    printf '%s.\n\n' "$(kind_tech "$k")"
    printf '## Purpose\n\n_What this part does, for whom, and how it fits with the other parts._\n\n'
    printf '## Build and run\n\n'
    readme_build "$p" "$k"
    printf '\n## Configuration\n\n'
    readme_config "$p" "$k" "$d"
    printf '\n## Release\n\n'
    readme_release "$p" "$k" "$d"
    printf '\n## Interfaces\n\n'
    printf '_What other parts and people use from this part (commands, endpoints, files, ports), in a line each; the details\n'
    printf 'go in the docs below._\n\n'
    printf '## Docs\n\n'
    printf -- '- [Changelog](CHANGELOG.md)\n'
    for name in $(kind_docs "$k"); do
      printf -- '- [%s](%sdocs/%s/%s.md): %s\n' "$(doc_title "$name")" "$up" "$p" "$name" "$(doc_what "$name")"
    done
    printf -- '- [Architecture](%sdocs/architecture.md): how the parts connect\n' "$up"
  } | own_doc "$d/README.md"
}

# part_changelog P D: Keep a Changelog 1.1.0; the release notes of tag <part>-v<version> come from here.
part_changelog() {
  local p=$1 d=$2
  own_doc "$d/CHANGELOG.md" <<EOF
# Changelog: $p

Every notable change to $p, newest first, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
format. Each release is tagged \`$p-v<version>\` and gets a \`## [<version>] - YYYY-MM-DD\` section.

## [Unreleased]

### Added

### Changed

### Fixed
EOF
}

# part_doc P K NAME: the content of docs/<part>/<name>.md.
part_doc() {
  local p=$1 k=$2 name=$3 d=${4:-}
  printf '# %s: %s\n\n' "$p" "$(doc_title "$name")"
  case $name in
    protocol)
      cat <<EOF
_How the host, the apps and the cloud talk to this firmware. A change here is a CHANGELOG entry._

## Transports

_Each link (USB HID, USB CDC serial, BLE, UART, LTE / MQTT ...): its role, ids (VID / PID, service and
characteristic UUIDs), framing and speed._

## Commands

_Each command the firmware accepts: id, payload layout, response, errors. A table per transport._

## Messages and events

_What the firmware sends on its own (reports, notifications, telemetry): layout and when._

## Versioning

_How the other side learns the firmware and protocol version, and what stays compatible across versions._

## Errors

_Error codes, what each means and what the other side should do._
EOF
      ;;
    flashing)
      cat <<EOF
_How images get onto the board, in the factory and in the field._

## Images

_Which build output is which (application, bootloader, merged factory image) and where \`make $p-build\` puts it._

## Bootloader

_Which bootloader, how to enter it (button, command, pin), how images are signed._

## Updating

_\`make $p-flash\` over the probe or USB, and the over-the-air path (\`make $p-release\`)._

## Recovery

_A board that does not boot: \`make $p-erase CONFIRM=erase\`, the probe wiring, the DFU or ROM boot mode._

## Factory programming

_The full image, option bytes or fuses, serial numbers and provisioning, in order._

## Board revisions

_Which build (board, env, config) goes with which hardware revision._
EOF
      ;;
    bringup)
      cat <<EOF
_The checklist for the first power-on of a new board or revision. Copy the results table per batch._

## Before power

_Visual inspection, orientation of polarised parts, resistance of each rail to ground (expected values)._

## First power

_Supply voltage and current limit, the expected idle current, each rail's measured voltage._

## Programming

_Probe connection, the first image (\`make <firmware part>-flash\`), what the board does when it is alive._

## Functional tests

_One line per block (power, radio, sensors, USB, buttons, LEDs): how to test it and what passes._

## Results

| Board / serial | Revision | Date | Result | Notes |
|---|---|---|---|---|

## Known issues

_Errata per revision, with the rework that fixes each._
EOF
      ;;
    manufacturing)
      local stackup_src="the board's \`.kicad_pcb\` (Board Setup, Physical Stackup)"
      [[ $k != altium ]] || stackup_src="the board's \`.PcbDoc\` (Layer Stack Manager)"
      cat <<EOF
_How this board is fabricated and assembled. \`make $p-release\` publishes the fab files._

## Fabrication

_Fab house, layer count, thickness, copper weight, finish, colour, panelisation._

## Stackup

_The layer stack and controlled impedances; it matches the stackup in $stackup_src._

## Design rules

_The rule set used (for example JLCPCB 4-layer) and every exception, with why._

## Assembly

_Who assembles, which side, parts by LCSC basic / extended, hand-placed or consigned parts, orientation notes._

## Suppliers and parts

_Long lead-time parts, alternates, what to check before ordering._

## Revisions

_What changed in each revision; the details are in the CHANGELOG._
EOF
      ;;
    power)
      cat <<EOF
_How much current $p draws and how long a battery lasts. \`make $p-power\` records the samples (Simplicity Commander's
energy monitor on the kit), \`make $p-power-avg\` the long average._

## Power modes

_Each mode the firmware uses (active, radio on, sleep, deep sleep), what enters and leaves it, the wake sources._

## Measurements

| Firmware version | Board / revision | Mode | Average current | Peak | Date |
|---|---|---|---|---|---|

## Budget

_The duty cycle of a typical day and the average current it gives._

## Battery life

_The battery, its usable capacity, and the life the budget gives; what shortens it._

## How to measure

_The kit or probe, the wiring, \`make $p-power DURATION=<s>\` and what to keep fixed between runs._
EOF
      ;;
    assembly)
      cat <<EOF
_How the parts of $p are made and put together. The models are in \`$d/\`; \`make $p-build\` exports STEP and STL._

## Parts

| Part | Model (.FCStd) | Made by | Material | Quantity |
|---|---|---|---|---|

## Fasteners and bought parts

_Screws, inserts, magnets, gaskets: size, quantity, supplier._

## Assembly order

_The steps, in order, with what to check at each (fit of the board, connectors, buttons, cables)._

## Printing and machining

_Per part: process, orientation, layer height or tolerance, finish, supports._

## Revisions

_What changed in each revision; the details are in the CHANGELOG._
EOF
      ;;
    api)
      cat <<EOF
_The HTTP interface of this Worker. A change here is a CHANGELOG entry._

## Base URLs

| Environment | URL |
|---|---|
| local | |
| staging | |
| production | |

## Authentication

_How a client authenticates (tokens, sessions, device keys) and which endpoints need it._

## Endpoints

| Method | Path | Auth | Request | Response |
|---|---|---|---|---|
| GET | /health | none | | \`{ ok, environment }\` |

## Errors

_The error body, status codes and what a client should do on each._

## Limits

_Rate limits, payload sizes, timeouts._
EOF
      ;;
    data)
      cat <<EOF
_What this Worker stores and where. The bindings are declared in \`wrangler.jsonc\`._

## D1 tables

_Per table: columns, keys and indexes, who writes it._

## KV keys

_Per namespace: key patterns, value format, TTL._

## R2 layout

_Per bucket: object key layout, content types, lifetime._

## Queues

_Per queue: message format, producer, consumer, dead-letter queue._

## Migrations

_How a schema change ships (\`migrations/\`, \`make cf-migrate ENV=<env>\`) and how it stays compatible with the
running version._

## Backup and retention

_What \`make cf-backup\` covers, how long data is kept, how to restore._
EOF
      ;;
    distribution)
      cat <<EOF
_How this app reaches users. Keys and passwords live in the secrets repo, never here._

## Identifiers

_Bundle id / application id per platform and environment, app name, team or developer account._

## Signing

_Certificates, provisioning profiles, keystores: their names in \`secrets.schema\` and when they expire._

## Channels

_TestFlight / App Store, Play tracks, the OTA channel, direct downloads: what \`make $p-release TARGET=\` publishes
where._

## Permissions

_Each OS permission the app asks for, why, and the text shown to the user._

## Release files (GitHub Release)

_Which file each platform gets, where it is built, and what the Release links. The matrix is fixed by the standard
(reference/standard.md 4.12); \`make $p-github-release\` on the tag \`$p-v<version>\` does the rest, run by
.github/workflows/release.yml._

| Platform | Built where | Files in the Release |
|---|---|---|
| macos (universal) | the Mac: \`make $p-github-release FORCE=1\` | \`.dmg\`, \`.app.zip\` (Tauri); \`.zip\` (Flutter) |
| ios | the Mac: \`PLATFORM=ios FORCE=1\` | dSYMs zip; the TestFlight build number in the notes. No ipa |
| android | the Mac: \`PLATFORM=android FORCE=1\` (app-android always) | release \`.apk\`. The \`.aab\` and the R8 mapping are workflow artifacts (kept 7 days), not release files |
| linux-amd64, linux-arm64 | the tag workflow, GitHub-hosted Linux runners | Tauri: \`.deb\`, \`.rpm\`, \`.AppImage\`; Flutter: \`.tar.gz\` |
| windows-x64, windows-arm64 | the tag workflow, GitHub-hosted Windows runner (Tauri) | x64 \`.msi\` and \`.exe\`; arm64 \`.exe\` (no arm64 \`.msi\`) |

Each platform writes \`SHA256SUMS-<platform>\` (the app kinds); the jobs add their files to the same Release. Flutter
has no Windows job in CI yet (Linux only); Tauri builds Windows x64 and arm64 in its tag workflow.

## Signing and notarisation

_What the release helpers do. Tauri macOS and iOS: built inside the production secrets, signed and notarised when
\`APPLE_SIGNING_IDENTITY\`, \`APPLE_API_KEY\`, \`APPLE_API_ISSUER\` and the key file \`appstore-api-key\` (as \`APPLE_API_KEY_PATH\`) exist.
Tauri Windows: signed with the key file \`windows-codesign\` and \`WINDOWS_CERT_PASSWORD\` (staging) when the CI job has
the secrets; otherwise unsigned. app-android: signed with the key file \`android-keystore\` when it exists. Flutter (Android,
iOS archive and macOS) and Tauri Android run inside the production secrets but are NOT signed by the helper: their Gradle
or Xcode settings must read the environment (not wired by default). Each unsigned build prints a warning._

## iOS and Android policy

_iOS: no ipa in the Release; the dSYMs zip is, and the TestFlight build number is written into the Release notes.
Android: the release apk is linked; the aab and the mapping file are workflow artifacts (kept 7 days), not release files. Stores are
never published from a tag: \`make $p-release\` with \`CONFIRM=production\` is the manual step._

## Updates

_How users get a new version, the minimum supported version, and update prompts._
EOF
      ;;
    usage)
      cat <<EOF
_How to run and use $p._

## Running

_How to start it locally (\`make $p-dev\`) and in production (image, binary, service unit)._

## Commands or endpoints

_The CLI commands and flags, or the service's endpoints, with an example each._

## Configuration

_Every setting: environment variable, default, meaning. Secrets by name only (\`secrets.schema\`)._

## Environment

_Where it runs, ports, volumes, the other services it needs._

## Logs and health

_Where the logs go and how to tell it is healthy._
EOF
      ;;
    library)
      local lib
      lib=$(altium_library)
      cat <<EOF
_The parts of this board come from the shared Altium library, never from a library of its own._

## The submodule

The library is the repository \`ALTIUM_LIBRARY_PROJECT\` (by default \`<owner>/altium-library\`), a git submodule of
this project at \`$lib\` (\`ALTIUM_LIBRARY\` in \`make/project.mk\`). A submodule, because the board's project names
the library's \`Library.DbLib\` by a relative path. \`make $p-setup\` adds it (\`git submodule add\`) when the project
has none yet, and checks it out in a fresh clone; by hand:

    git submodule update --init -- $lib

The project pins one commit of the library. To move to a newer one: \`git -C $lib pull\`, then
\`git add $lib\` and commit. \`make $p-doctor\` says when the checkout is not the pinned commit.

## What is in it

\`parts.csv\` (one row per MPN), \`Library.DbLib\` (Altium's view of \`parts.csv\`), \`sym/<name>.SchLib\`,
\`fp/<name>.PcbLib\`, \`models/<MPN>.step\` (Git LFS, lockable) and \`tools/check.py\`.

## Adding a part

_Add it in the library repository (its row in \`parts.csv\`, its symbol, footprint and model), check it there with
\`python3 tools/check.py library\`, push, then move this project's pin as above._

## The check

\`make $p-lib-check\` runs \`tools/check.py project\` on the board's \`.PrjPcb\` (in \`$d/.venv\`, which
\`make $p-setup\` makes); \`make $p-check\` runs it too once the library is checked out. In CI the altium job checks
the library out at the pinned commit with a read-only deploy key (\`make ci-setup\`).

## Notes

_Parts this board uses that are not in the library yet, and why._
EOF
      ;;
  esac
}

part_docs() {
  local p=$1 k=$2 d=$3 name
  for name in $(kind_docs "$k"); do
    part_doc "$p" "$k" "$name" "$d" | own_doc "docs/$p/$name.md"
  done
}

# references_doc: docs/references.md, the links to the reference documents (1.2: links only, nothing downloaded). Written
# for every project: firmware has its chip's reference manual and SDK notes, hardware its datasheets, mechanical its
# vendors' drawings. One line per document, `- [Title (MPN) — Vendor](URL)`, under ## headings; no rows at first.
# shellcheck disable=SC2016 # the backticks are Markdown
references_doc() {
  {
    printf '# %s: references\n\n' "$PROJECT"
    printf '_Links to the datasheets, reference manuals, application notes and drawings this project works from, one line\n'
    printf 'per document: `- [Title (MPN) — Vendor](URL)`. The documents themselves are never committed._\n\n'
    printf '## Datasheets\n\n'
    printf '_Grouped by category under ### headings (MCU, power, radio, sensors, connectors ...)._\n\n'
    printf '## Vendors and modules\n\n'
    printf '_Per vendor or module, under ### headings: reference manuals, application notes, SDK guides, drawings._\n'
  } | own_doc docs/references.md
}

# mermaid_id NAME: a part name as a Mermaid node id.
mermaid_id() { printf '%s\n' "${1//-/_}"; }

# shellcheck disable=SC2016 # the backticks in this function are Markdown
project_docs() {
  local i p k d name deployable=0
  i=0
  while ((i < n)); do
    is_deployable_kind "${P_KINDS[$i]}" && deployable=1
    i=$((i + 1))
  done

  {
    printf '# %s: documents\n\n' "$PROJECT"
    printf '_Every document in this project. Add a line here when you add a doc._\n\n'
    printf 'Docs are Markdown; diagrams are Mermaid blocks inside them; images are SVG, or PNG (Git LFS), in\n'
    printf '`docs/images/` or `docs/<part>/images/`. Binary documents (PDF, Word, Excel, PowerPoint) are never\n'
    printf 'committed: a generated PDF is attached to a release.\n\n'
    printf '## Project\n\n'
    printf -- '- [README](../README.md): what the project is and how to start\n'
    printf -- '- [Architecture](architecture.md): the parts, how they connect, where each runs\n'
    ((deployable == 0)) || printf -- '- [Operations](operations.md): deploy, rollback, backup, checks\n'
    printf -- '- [References](references.md): links to the datasheets, manuals and drawings\n'
    printf '\n## Parts\n'
    i=0
    while ((i < n)); do
      p=${P_NAMES[$i]} k=${P_KINDS[$i]} d=${P_DIRS[$i]}
      printf '\n### %s\n\n' "$p"
      printf -- '- [README](../%s/README.md), [Changelog](../%s/CHANGELOG.md)\n' "$d" "$d"
      for name in $(kind_docs "$k"); do
        printf -- '- [%s](%s/%s.md): %s\n' "$(doc_title "$name")" "$p" "$name" "$(doc_what "$name")"
      done
      i=$((i + 1))
    done
  } | own_doc docs/README.md

  {
    printf '# %s: architecture\n\n' "$PROJECT"
    printf '_The parts, how they talk to each other, and where each one runs._\n\n'
    printf '## Parts\n\n'
    printf '```mermaid\nflowchart LR\n'
    i=0
    while ((i < n)); do
      printf '  %s["%s<br/>%s"]\n' "$(mermaid_id "${P_NAMES[$i]}")" "${P_NAMES[$i]}" "${P_KINDS[$i]}"
      i=$((i + 1))
    done
    printf '  %%%% one arrow per link, labelled with the transport, for example:\n'
    if ((n >= 2)); then
      printf '  %%%% %s -->|USB HID| %s\n' "$(mermaid_id "${P_NAMES[1]}")" "$(mermaid_id "${P_NAMES[0]}")"
    else
      printf '  %%%% user -->|HTTPS| %s\n' "$(mermaid_id "${P_NAMES[0]}")"
    fi
    printf '```\n\n'
    printf '## Data flow\n\n'
    printf '_What data moves between the parts, in which direction and format, for the main use cases._\n\n'
    printf '## Where each part runs\n\n'
    printf '| Part | Kind | Runs on | Folder |\n|---|---|---|---|\n'
    i=0
    while ((i < n)); do
      # shellcheck disable=SC2016 # the backticks are Markdown
      printf '| %s | %s | %s | `%s/` |\n' "${P_NAMES[$i]}" "${P_KINDS[$i]}" "$(kind_runs_on "${P_KINDS[$i]}")" "${P_DIRS[$i]}"
      i=$((i + 1))
    done
    printf '\n## External services\n\n'
    printf '_Accounts and services the project depends on (Cloudflare, GitHub, app stores, suppliers) and what for._\n'
  } | own_doc docs/architecture.md

  ((deployable == 1)) || return 0
  {
    printf '# %s: operations\n\n' "$PROJECT"
    printf '_The runbook for the deployed parts:'
    i=0
    while ((i < n)); do
      is_deployable_kind "${P_KINDS[$i]}" && printf ' %s' "${P_NAMES[$i]}"
      i=$((i + 1))
    done
    printf '._\n\n'
    printf '## Environments\n\n'
    printf '| Part | Staging | Production |\n|---|---|---|\n'
    i=0
    while ((i < n)); do
      if is_deployable_kind "${P_KINDS[$i]}"; then
        if is_prod_only "${P_NAMES[$i]}"; then
          printf '| %s | (none: production-only) | |\n' "${P_NAMES[$i]}"
        else
          printf '| %s | | |\n' "${P_NAMES[$i]}"
        fi
      fi
      i=$((i + 1))
    done
    printf '\n## Deploy\n\n'
    printf '_The order and the checks of a release. A push to main deploys staging (not a production-only part);\n'
    printf 'the part'"'"'s tag (`make <part>-bump`, `make release-push`) deploys production, then makes its GitHub\n'
    printf 'Release. By hand: `make <part>-deploy ENV=production CONFIRM=production`, or release.yml from the\n'
    printf 'Actions tab with part and confirm `production`; an image: `make <part>-release`._\n\n'
    printf '## Rollback\n\n'
    printf '_How to go back: `make versions ENV=production`, `make rollback ENV=production CONFIRM=production`,\n'
    printf 'and what a rollback does not undo (migrations, data)._\n\n'
    printf '## Backup and restore\n\n'
    printf '_What is backed up (`make cf-backup ENV=production` for Cloudflare data), where, how often, and the\n'
    printf 'restore steps._\n\n'
    printf '## Checks\n\n'
    printf '_How to tell production is healthy: `make smoke ENV=production`, dashboards, alerts, logs (`make logs`); CI runs: `make ci-status`, `make ci-logs` (gh)._\n\n'
    printf '## Incidents\n\n'
    printf '_What to look at first, who to tell, and how to rotate a leaked secret (`make secrets-rotate`)._\n'
  } | own_doc docs/operations.md
}

# ---------------------------------------------------------------------------------------------
# starters: only written when the part's folder does not exist yet (the part's docs are written either way)

write_file() {
  # write_file PATH < content
  mkdir -p "$(dirname "$1")"
  cat >"$1"
}

# pnpm_workspace DIR: pnpm runs no package's install scripts unless the workspace allows it, and wrangler needs three
# (esbuild, sharp, workerd). pnpm 10 reads onlyBuiltDependencies, pnpm 11 and later allowBuilds; both accept the
# other key, so the file names them both (v24).
pnpm_workspace() {
  write_file "$1/pnpm-workspace.yaml" <<'EOF'
# Packages whose install scripts pnpm may run (wrangler needs these). pnpm 10 reads onlyBuiltDependencies,
# pnpm 11 and later allowBuilds.
onlyBuiltDependencies:
  - esbuild
  - sharp
  - workerd
allowBuilds:
  esbuild: true
  sharp: true
  workerd: true
EOF
}

starter_cloud_worker() {
  local p=$1 d=$2 today staging_block=''
  today=$(date +%Y-%m-%d)
  if ! is_prod_only "$p"; then
    staging_block="    \"staging\": {
      \"name\": \"$PROJECT-staging-$p\",
      \"vars\": { \"ENVIRONMENT\": \"staging\" }
    },
"
  fi
  write_file "$DEST/$d/package.json" <<EOF
{
  "name": "$PROJECT-$p",
  "private": true,
  "type": "module",
  "devDependencies": {
    "typescript": "$TYPESCRIPT_VERSION",
    "vitest": "$VITEST_VERSION",
    "wrangler": "$WRANGLER_VERSION"
  }
}
EOF
  pnpm_workspace "$DEST/$d"
  write_file "$DEST/$d/wrangler.jsonc" <<EOF
{
  "\$schema": "node_modules/wrangler/config-schema.json",
  "name": "$PROJECT-$p",
  "main": "src/index.ts",
  "compatibility_date": "$today",
  "observability": { "enabled": true },
  // Bindings are declared per environment and are the source of truth: \`make dev\` uses
  // env.local (local D1 / KV / R2), \`make cf-provision ENV=<env>\` creates what is missing for
  // staging or production and writes the ids back.
  // Naming rule: every D1 database_name, R2 bucket_name and Queue name in env.<env> starts with
  // $PROJECT-<env> (for example "$PROJECT-staging-db"), and a Worker name set in env.<env> ends with -<env>.
  // \`make cf-wipe\` and \`make cf-destroy\` refuse anything else, so a wrong ENV cannot reach another env's data.
  "env": {
    "local": {
      "vars": { "ENVIRONMENT": "local" }
    },
$staging_block    "production": {
      "name": "$PROJECT-production-$p",
      "vars": { "ENVIRONMENT": "production" }
    }
  }
}
EOF
  write_file "$DEST/$d/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "lib": ["ES2022", "WebWorker"],
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
EOF
  write_file "$DEST/$d/src/index.ts" <<'EOF'
interface Env {
  ENVIRONMENT: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json({ ok: true, environment: env.ENVIRONMENT });
    }
    return new Response("Not found", { status: 404 });
  },
};
EOF
}

# is_pages PART: the web part is a Cloudflare Pages project (--pages), not a Worker.
is_pages() {
  local s
  for s in ${PAGES_SPECS[@]+"${PAGES_SPECS[@]}"}; do [[ $s == "$1" ]] && return 0; done
  return 1
}

# web_host PART: its production custom domain (--domain), else the placeholder the audit reports.
web_host() {
  local s
  for s in ${DOMAIN_SPECS[@]+"${DOMAIN_SPECS[@]}"}; do
    if [[ ${s%%=*} == "$1" ]]; then printf '%s' "${s#*=}"; return; fi
  done
  printf 'CHANGE-ME.example.com'
}

# web_staging_host HOST: <label>-staging.<zone> (one level, so the zone's certificate covers it); an apex domain
# gets staging.<domain>.
web_staging_host() {
  local h=$1 rest=${1#*.}
  if [[ $rest == *.* ]]; then printf '%s-staging.%s' "${h%%.*}" "$rest"; else printf 'staging.%s' "$h"; fi
}

# web_wrangler PART DIR: the part's wrangler.jsonc, when it has none. A Worker serving the build output on its custom
# domain only (workers_dev and preview_urls off), or with --pages the Pages project's config.
web_wrangler() {
  local p=$1 d=$2 today out host shost
  [[ -e "$DEST/$d/wrangler.jsonc" || -e "$DEST/$d/wrangler.json" ]] && return 0
  today=$(date +%Y-%m-%d)
  out=./public
  if compgen -G "$DEST/$d/next.config.*" >/dev/null; then out=./out; elif compgen -G "$DEST/$d/astro.config.*" >/dev/null || compgen -G "$DEST/$d/vite.config.*" >/dev/null; then out=./dist; fi
  if is_pages "$p"; then
    write_file "$DEST/$d/wrangler.jsonc" <<EOF
{
  "\$schema": "node_modules/wrangler/config-schema.json",
  "name": "$PROJECT-$p",
  "pages_build_output_dir": "$out",
  "compatibility_date": "$today"
}
EOF
    return 0
  fi
  host=$(web_host "$p")
  shost=$(web_staging_host "$host")
  {
    printf '// wrangler.jsonc: the %s site as a static-assets Worker. Each env block is one Worker on its custom domain,\n' "$p"
    printf '// its only address: workers_dev and preview_urls are off, so there is no *.workers.dev or preview URL.\n'
    printf '{\n'
    printf '  "$schema": "node_modules/wrangler/config-schema.json",\n'
    printf '  "name": "%s-%s",\n' "$PROJECT" "$p"
    printf '  "compatibility_date": "%s",\n' "$today"
    printf '  "workers_dev": false,\n'
    printf '  "preview_urls": false,\n'
    printf '  "assets": { "directory": "%s" },\n\n' "$out"
    printf '  "env": {\n'
    if ! is_prod_only "$p"; then
      printf '    "staging": {\n'
      printf '      "name": "%s-staging-%s",\n' "$PROJECT" "$p"
      printf '      "workers_dev": false,\n'
      printf '      "preview_urls": false,\n'
      printf '      "routes": [{ "pattern": "%s", "custom_domain": true }],\n' "$shost"
      printf '      "assets": { "directory": "%s" }\n' "$out"
      printf '    },\n'
    fi
    printf '    "production": {\n'
    printf '      "name": "%s-production-%s",\n' "$PROJECT" "$p"
    printf '      "workers_dev": false,\n'
    printf '      "preview_urls": false,\n'
    printf '      "routes": [{ "pattern": "%s", "custom_domain": true }],\n' "$host"
    printf '      "assets": { "directory": "%s" }\n' "$out"
    printf '    }\n'
    printf '  }\n'
    printf '}\n'
  } | write_file "$DEST/$d/wrangler.jsonc"
}

starter_web_pages() {
  local p=$1 d=$2
  write_file "$DEST/$d/package.json" <<EOF
{
  "name": "$PROJECT-$p",
  "private": true,
  "devDependencies": {
    "wrangler": "$WRANGLER_VERSION"
  }
}
EOF
  pnpm_workspace "$DEST/$d"
  write_file "$DEST/$d/public/index.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>$PROJECT</title></head>
<body><p>$PROJECT</p></body>
</html>
EOF
}

# ---------------------------------------------------------------------------------------------
# helpers

# render SRC DEST: copy a template, replacing @@TOKEN@@ placeholders. A line that is only
# @@TOKEN@@ is replaced by the file $WORK/TOKEN (or dropped when there is none).
render() {
  local src=$1 dest=$2 line tok tmp
  tmp="$dest.scaffold.$$"
  mkdir -p "$(dirname "$dest")"
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^@@([A-Z_]+)@@$ ]]; then
      tok=${BASH_REMATCH[1]}
      if [[ -f "$WORK/$tok" ]]; then
        cat "$WORK/$tok"
      fi
      continue
    fi
    line=${line//@@PROJECT@@/$PROJECT}
    line=${line//@@PORT_BASE@@/$PORT_BASE}
    line=${line//@@FIRST_PART@@/$FIRST_PART}
    printf '%s\n' "$line"
  done <"$src" >"$tmp"
  mv "$tmp" "$dest"
}

# place REL KIND: write a project file from the template unless it is project-owned and exists.
# KIND is managed (always written) or own (kept if present).
place() {
  local rel=$1 kind=$2
  if [[ $kind == own && -e "$DEST/$rel" ]]; then
    note "kept existing $rel"
    return 0
  fi
  render "$TPL_PROJECT/$rel" "$DEST/$rel"
}

copy_managed() {
  local src=$1 rel=$2
  [[ -f $src ]] || die "skill templates incomplete: ${src#"$SKILL_DIR"/} is missing"
  mkdir -p "$(dirname "$DEST/$rel")"
  cp "$src" "$DEST/$rel"
}

# user_config NAME: the value of NAME from the environment, else from the user config
# (~/.config/project-standard/config.mk, its last assignment); empty when neither sets it.
user_config() {
  local name=$1 cfg val
  val=$(printenv "$name" || true)
  if [[ -n $val ]]; then
    printf '%s\n' "$val"
    return 0
  fi
  cfg="${STD_CONFIG:-$HOME/.config/project-standard}/config.mk"
  if [[ -f $cfg ]]; then
    sed -n "s/^[[:space:]]*${name}[[:space:]]*[:?]*=[[:space:]]*\\([^[:space:]#]*\\).*/\\1/p" "$cfg" | tail -n 1
  fi
}

# is_prod_only PART: the part has no staging (--production-only, or found so in its wrangler.jsonc).
is_prod_only() {
  case " $PROD_ONLY " in *" $1 "*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------------------------
# CI for GitHub: .github/workflows/checks.yml (pushes and pull requests, by part) and release.yml (tags, and the
# production steps by hand). Each part calls its kind's reusable workflow in the CI templates repository.

readonly ACTIONS_CHECKOUT='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'

# The repository of the reusable workflows when nothing sets CI_TEMPLATES_REPO: public, shared by every owner (1.7).
readonly CI_TEMPLATES_DEFAULT=mayankgautam-me/ci-templates

# project_mk_value NAME: the last assignment of NAME in the project's make/project.mk; empty when none.
# altium_library: where an altium part's shared library is a submodule: ALTIUM_LIBRARY in make/project.mk, else the
# default hardware/altium-library (1.4). The scaffold writes no submodule (no network): make <part>-setup adds it.
altium_library() {
  local v
  v=$(project_mk_value ALTIUM_LIBRARY)
  printf '%s\n' "${v:-hardware/altium-library}"
}

project_mk_value() {
  local pm="$DEST/make/project.mk"
  [[ -f $pm ]] || return 0
  sed -n "s/^[[:space:]]*${1}[[:space:]]*[:?]*=[[:space:]]*\\([^[:space:]#]*\\).*/\\1/p" "$pm" | tail -n 1
}

# ci_project: the repository of the reusable workflows (owner/name), independent of GITHUB_OWNER: CI_TEMPLATES_REPO
# from make/project.mk, else from the environment or the user config, else CI_TEMPLATES_DEFAULT.
ci_project() {
  local val
  val=$(project_mk_value CI_TEMPLATES_REPO)
  [[ -n $val ]] || val=$(user_config CI_TEMPLATES_REPO)
  printf '%s\n' "${val:-$CI_TEMPLATES_DEFAULT}"
}

# ci_owner_check: GITHUB_OWNER is a GitHub user or organisation name, and CI_TEMPLATES_REPO is owner/name. Warns
# when the GitLab-era GITLAB_GROUP or the pre-1.7 CI_TEMPLATES_PROJECT is still set (both are ignored).
ci_owner_check() {
  local owner repo
  owner=$(user_config GITHUB_OWNER)
  if [[ -n $owner && ! $owner =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    die "GITHUB_OWNER '$owner' must be a GitHub user or organisation name"
  fi
  repo=$(ci_project)
  if [[ ! $repo =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]]; then
    die "CI_TEMPLATES_REPO '$repo' must be owner/name, e.g. $CI_TEMPLATES_DEFAULT"
  fi
  if [[ -n $(user_config GITLAB_GROUP) ]]; then
    warn "GITLAB_GROUP in the user config is ignored since project-standard v19; set GITHUB_OWNER := <owner> instead"
  fi
  if [[ -n $(user_config CI_TEMPLATES_PROJECT) ]]; then
    warn "CI_TEMPLATES_PROJECT in the user config is ignored since project-standard 1.7: the workflows call $repo; set CI_TEMPLATES_REPO := <owner>/<name> to change it, and remove CI_TEMPLATES_PROJECT"
  fi
}

# ci_has_production KIND: the kind has a step that goes to production by hand (OTA, store, deploy, PyPI).
# fw_publishes: the firmware parts publish OTA, so they get a production job: the project has a Cloudflare part
# (cloud-worker, web-pages) or an existing make/project.mk sets OTA_BUCKET (or <part>_OTA_BUCKET). Without either,
# make <part>-release skips the publish, so release.yml gets no production job for them.
fw_publishes() {
  local k
  for k in "${P_KINDS[@]}"; do
    case $k in cloud-worker | web-pages) return 0 ;; esac
  done
  [[ -f "$DEST/make/project.mk" ]] &&
    grep -Eq '^[[:space:]]*([A-Za-z0-9_-]+_)?OTA_BUCKET[[:space:]]*[:?]?=[[:space:]]*[^[:space:]]' "$DEST/make/project.mk"
}

ci_has_production() {
  case $1 in
    zephyr | espidf | pio | arm-gcc | circuitpython | silabs | cloud-worker | web-pages | app-*) return 0 ;;
  esac
  return 1
}

# ci_has_release KIND: the kind gets a <part>-release job in release.yml. Not altium: its outputs come from Altium on
# Windows, so its GitHub Release is made there (make <part>-github-release FORCE=1), and CI only checks it.
ci_has_release() { [[ $1 != altium ]]; }

# ci_key PART: the output name of a part in the changes job (an output name cannot hold '-').
ci_key() { printf '%s\n' "${1//-/_}"; }

# ci_secrets KIND: the secrets block of a job that calls a kind's reusable workflow.
# shellcheck disable=SC2016 # the ${{ }} expressions are for GitHub to expand
ci_secrets() {
  echo "    secrets:"
  echo '      SECRETS_DEPLOY_KEY: ${{ secrets.SECRETS_DEPLOY_KEY }}'
  echo '      SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}'
  if [[ $1 == hardware ]]; then
    echo '      KICAD_LIBRARY_DEPLOY_KEY: ${{ secrets.KICAD_LIBRARY_DEPLOY_KEY }}'
  fi
  # the shared Altium library, a submodule the altium job checks out with its own deploy key (1.4)
  if [[ $1 == altium ]]; then
    echo '      ALTIUM_LIBRARY_DEPLOY_KEY: ${{ secrets.ALTIUM_LIBRARY_DEPLOY_KEY }}'
  fi
}

# ci_job MODE PART KIND DIR: one job of a part. MODE is ci (every push and pull request: check and build, the job
# runs only when the part changed), release (its tag: check, build and the release; a cloud-worker or web-pages part
# also deploys production there, before its Release) or production (workflow_dispatch with part and confirm).
ci_job() {
  local mode=$1 p=$2 k=$3 d=$4 key
  key=$(ci_key "$p")
  case $mode in
    ci)
      printf '  %s:\n' "$p"
      printf '    needs: changes\n'
      printf "    if: needs.changes.outputs.%s == 'true'\n" "$key"
      ;;
    release)
      printf '  %s-release:\n' "$p"
      printf '    needs: tag\n'
      printf "    if: needs.tag.outputs.part == '%s'\n" "$p"
      ;;
    production)
      printf '  %s-production:\n' "$p"
      printf "    if: github.event_name == 'workflow_dispatch' && inputs.part == '%s' && inputs.confirm == 'production'\n" "$p"
      ;;
  esac
  # the caller must grant every permission the called jobs ask for (a called job can only lower it): contents for the
  # release job, packages for the docker image, actions: read for the jobs that download another job's artifact (the
  # artifact API), in every mode. The top level of each workflow stays read-only.
  printf '    permissions:\n      actions: read\n      contents: write\n'
  if [[ $k == docker ]]; then printf '      packages: write\n'; fi
  printf '    uses: %s/.github/workflows/%s.yml@v%s\n' "$CI_PROJECT" "$k" "$STD_VERSION"
  printf '    with:\n'
  printf '      part: %s\n' "$p"
  printf '      part_dir: %s\n' "$d"
  printf '      run_check: true\n'
  printf '      run_build: true\n'
  if [[ $mode == release ]]; then
    printf '      run_release: true\n'
  else
    printf '      run_release: false\n'
  fi
  if [[ $mode == production ]]; then
    printf "      confirm: \${{ inputs.confirm }}\\n"
  fi
  # the Cloudflare kinds: the part's tag deploys production (this job runs only on that tag), then makes the Release
  if [[ $mode == release ]]; then
    case $k in
      cloud-worker | web-pages) printf '      confirm: production\n' ;;
    esac
  fi
  case $k in
    cloud-worker | web-pages)
      if is_prod_only "$p"; then printf '      production_only: true\n'; else printf '      production_only: false\n'; fi
      ;;
  esac
  # a board with its own library tables (<part>_LIBRARY := local in make/project.mk): CI checks out no KiCad library
  if [[ $k == hardware && $(project_mk_value "${p}_LIBRARY") == local ]]; then
    printf '      library: local\n'
  fi
  # a push to main deploys staging (a production-only part: nothing)
  if [[ $mode == ci ]]; then
    case $k in
      cloud-worker | web-pages | docker)
        printf "      deploy_staging: \${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}\n"
        ;;
    esac
  fi
  # the production step takes the build or staging run from the dispatch's source_run_id
  if [[ $mode == production ]]; then
    case $k in
      arm-gcc | circuitpython | espidf | pio | silabs | zephyr)
        printf "      source_run_id: \${{ inputs.source_run_id }}\\n"
        ;;
    esac
  fi
  ci_secrets "$k"
  printf '\n'
}

# ci_tag_job: the first job of release.yml. The part of a <part>-v<version> tag is everything before the last "-v", so
# app-v1.0 is app and app-viewer-v1.0 is app-viewer: each release job compares that exactly.
# shellcheck disable=SC2016 # the ${{ }} expressions and $GITHUB_OUTPUT are for GitHub and the shell at run time
ci_tag_job() {
  cat <<'EOF'
  tag:
    runs-on: ${{ vars.STD_RUNNER || 'ubuntu-24.04' }}
    outputs:
      part: ${{ steps.part.outputs.part }}
    steps:
      - id: part
        shell: bash
        env:
          REF_TYPE: ${{ github.ref_type }}
          REF_NAME: ${{ github.ref_name }}
        run: |
          set -euo pipefail
          if [ "$REF_TYPE" = tag ]; then
            echo "part=${REF_NAME%-v*}" >>"$GITHUB_OUTPUT"
          else
            echo "part=" >>"$GITHUB_OUTPUT"
          fi
EOF
}

# ci_changes: the changes job of checks.yml. Each part's output is true when the run changed its folder, make/, the
# Makefile, mise.toml or the workflows. Everything runs when there is no base to compare (a new branch's first push,
# a manual run).
# shellcheck disable=SC2016 # the ${{ }} expressions and $GITHUB_OUTPUT are for GitHub and the shell at run time
ci_changes() {
  local i=0 k
  echo "  changes:"
  echo "    runs-on: \${{ vars.STD_RUNNER || 'ubuntu-24.04' }}"
  echo "    outputs:"
  while ((i < n)); do
    k=$(ci_key "${P_NAMES[$i]}")
    printf '      %s: ${{ steps.changes.outputs.%s }}\n' "$k" "$k"
    i=$((i + 1))
  done
  echo "    steps:"
  printf '      - uses: %s\n' "$ACTIONS_CHECKOUT"
  cat <<'EOF'
        with:
          fetch-depth: 0
      - id: changes
        shell: bash
        env:
          BASE: ${{ github.event_name == 'pull_request' && github.event.pull_request.base.sha || github.event.before }}
        run: |
          set -euo pipefail
          all=0
          files=''
          if [[ -z $BASE || $BASE =~ ^0+$ ]] || ! git cat-file -e "$BASE^{commit}" 2>/dev/null; then
            all=1
          else
            files=$(git diff --name-only "$BASE" HEAD)
          fi
          changed() {
            local dir=$1 f
            if ((all == 1)); then return 0; fi
            while IFS= read -r f; do
              case $f in
                "$dir"/* | make/* | Makefile | mise.toml | .github/workflows/*) return 0 ;;
              esac
            done <<<"$files"
            return 1
          }
EOF
  # one group for the outputs: one redirect for all of them
  echo "          {"
  i=0
  while ((i < n)); do
    k=$(ci_key "${P_NAMES[$i]}")
    printf "            if changed '%s'; then echo '%s=true'; else echo '%s=false'; fi\n" "${P_DIRS[$i]}" "$k" "$k"
    i=$((i + 1))
  done
  echo '          } >>"$GITHUB_OUTPUT"'
}

# ci_header NAME: the comment block and the workflow name, trigger-independent part.
ci_header() {
  printf '# %s\n' "$1"
  printf '# Generated by the project-standard skill (project-standard v%s). Each job calls a reusable workflow in\n' "$STD_VERSION"
  printf '# %s, which runs make <part>-<verb>, so CI does what you run locally.\n' "$CI_PROJECT"
  printf '# Add jobs at the end; make ci-lint checks this file.\n'
}

# ci_workflow: .github/workflows/checks.yml
ci_workflow() {
  local i=0 p
  ci_header "checks.yml: CI for $PROJECT. A push or pull request runs the parts whose folder changed."
  cat <<'EOF'
name: checks

on:
  push:
    branches: ['**']
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: checks-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name != 'workflow_dispatch' }}

EOF
  echo "jobs:"
  ci_changes
  while ((i < n)); do
    p=${P_NAMES[$i]}
    ci_job ci "$p" "${P_KINDS[$i]}" "${P_DIRS[$i]}"
    i=$((i + 1))
  done
}

# ci_latest_job: the last job of release.yml (since v20). Once the tag's part job has passed, it copies that part's
# Release into the Release "latest" (make <part>-release-latest), which holds the newest files of every part and
# carries GitHub's Latest badge. One at a time across the repository (the concurrency group), because two tags can
# finish together and both update the same Release.
# shellcheck disable=SC2016 # the ${{ }} expressions are for GitHub, the $VARS for the shell at run time
ci_latest_job() {
  local i=0 needs='tag' cond=''
  while ((i < n)); do
    if ! ci_has_release "${P_KINDS[$i]}"; then
      i=$((i + 1))
      continue
    fi
    needs="$needs, ${P_NAMES[$i]}-release"
    [[ -z $cond ]] || cond="$cond || "
    cond="${cond}needs.${P_NAMES[$i]}-release.result == 'success'"
    i=$((i + 1))
  done
  printf '  latest:
'
  printf '    needs: [%s]
' "$needs"
  printf '    if: always() && (%s)
' "$cond"
  printf '    runs-on: %s\n' "\${{ vars.STD_RUNNER || 'ubuntu-24.04' }}"
  printf '    permissions:
      contents: write
'
  printf '    concurrency:
      group: release-latest
      cancel-in-progress: false
'
  printf '    steps:
'
  printf '      - uses: %s
' "$ACTIONS_CHECKOUT"
  printf '        with:
          persist-credentials: false
'
  cat <<'EOF'
      - name: Copy the part's Release into the latest Release
        shell: bash
        env:
          GH_TOKEN: ${{ github.token }}
          PART: ${{ needs.tag.outputs.part }}
          REF_NAME: ${{ github.ref_name }}
        run: make "$PART-release-latest" VERSION="${REF_NAME##*-v}"
EOF
}

# ci_release_workflow: .github/workflows/release.yml
ci_release_workflow() {
  local i=0 p k has_release=0
  ci_header "release.yml: release for $PROJECT. A tag <part>-v<version> (make <part>-bump) runs that part's job."
  cat <<'EOF'
name: release

on:
  push:
    tags: ['*-v*']
  workflow_dispatch:
    inputs:
      part:
        description: 'the part to send to production (its name in make/project.mk)'
        required: false
        type: string
      confirm:
        description: 'type production to run the production step'
        required: false
        type: string
      source_run_id:
        description: 'firmware: the run that built the part (its build artifacts); empty builds again'
        required: false
        type: string

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

permissions:
  contents: read

EOF
  echo "jobs:"
  ci_tag_job
  while ((i < n)); do
    if ci_has_release "${P_KINDS[$i]}"; then
      ci_job release "${P_NAMES[$i]}" "${P_KINDS[$i]}" "${P_DIRS[$i]}"
      has_release=1
    fi
    i=$((i + 1))
  done
  ((has_release == 0)) || ci_latest_job
  printf '\n'
  i=0
  while ((i < n)); do
    p=${P_NAMES[$i]} k=${P_KINDS[$i]}
    if ci_has_production "$k"; then
      case $k in
        zephyr | espidf | pio | arm-gcc | circuitpython | silabs) fw_publishes || { i=$((i + 1)); continue; } ;;
      esac
      ci_job production "$p" "$k" "${P_DIRS[$i]}"
    fi
    i=$((i + 1))
  done
}

title_of() {
  local s=${1//-/ }
  printf '%s%s\n' "$(printf '%s' "${s:0:1}" | tr '[:lower:]' '[:upper:]')" "${s:1}"
}

# ---------------------------------------------------------------------------------------------
# arguments

DEST=''
PROJECT=''
PORT_BASE=''
FORCE=0
PART_SPECS=()
PROD_SPECS=()
DOMAIN_SPECS=()
PAGES_SPECS=()
PROD_ONLY=''

while (($# > 0)); do
  case $1 in
    --project)
      (($# >= 2)) || die "--project needs a value"
      PROJECT=$2
      shift 2
      ;;
    --part)
      (($# >= 2)) || die "--part needs a value"
      PART_SPECS+=("$2")
      shift 2
      ;;
    --production-only)
      (($# >= 2)) || die "--production-only needs a part name"
      PROD_SPECS+=("$2")
      shift 2
      ;;
    --domain)
      (($# >= 2)) || die "--domain needs NAME=HOST"
      [[ $2 == ?*=?*.?* ]] || die "--domain $2: give NAME=HOST, for example web=example.com"
      DOMAIN_SPECS+=("$2")
      shift 2
      ;;
    --pages)
      (($# >= 2)) || die "--pages needs a part name"
      PAGES_SPECS+=("$2")
      shift 2
      ;;
    --port-base)
      (($# >= 2)) || die "--port-base needs a value"
      PORT_BASE=$2
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "unknown option $1"
      ;;
    *)
      [[ -z $DEST ]] || die "only one <dir> is allowed (got $DEST and $1)"
      DEST=$1
      shift
      ;;
  esac
done

if [[ -z $DEST ]]; then
  usage >&2
  die "missing <dir>"
fi
[[ -n $PROJECT ]] || die "missing --project NAME"
[[ $PROJECT =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "project name '$PROJECT': use lowercase letters, digits and '-'"
((${#PART_SPECS[@]} > 0)) || die "give at least one --part name:kind[:dir]"

if [[ -z $PORT_BASE ]]; then
  # Stable per project name, so two projects rarely share ports: 8000..8890 in steps of 10.
  sum=$(printf '%s' "$PROJECT" | cksum | awk '{print $1}')
  PORT_BASE=$((8000 + (sum % 90) * 10))
fi
if ! [[ $PORT_BASE =~ ^[0-9]+$ ]] || ((PORT_BASE < 1024 || PORT_BASE > 65000)); then
  die "--port-base must be a number between 1024 and 65000"
fi

# parse parts into parallel arrays
P_NAMES=()
P_KINDS=()
P_DIRS=()
for spec in "${PART_SPECS[@]}"; do
  IFS=':' read -r name kind dir extra <<<"$spec"
  [[ -z ${extra:-} ]] || die "part '$spec': expected name:kind[:dir]"
  [[ -n ${name:-} && -n ${kind:-} ]] || die "part '$spec': expected name:kind[:dir]"
  [[ $name =~ ^[a-z][a-z0-9-]*$ ]] || die "part name '$name': use lowercase letters, digits and '-', starting with a letter"
  case $name in
    project) die "part name 'project' is reserved (the root component in PLAN.md)" ;;
    changes) die "part name 'changes' is reserved (the CI job that finds the changed parts)" ;;
  esac
  kind_known "$kind" || die "part '$name': unknown kind '$kind' (kinds: $KINDS)"
  i=0
  while ((i < ${#P_NAMES[@]})); do
    [[ ${P_NAMES[$i]} != "$name" ]] || die "part '$name' is given twice"
    i=$((i + 1))
  done
  P_NAMES+=("$name")
  P_KINDS+=("$kind")
  P_DIRS+=("${dir:-}")
done

# A part given without a dir goes in the folder of its kind when it is the only part of its group,
# else in <folder>/<name>. Explicit dirs stay as given.
i=0
while ((i < ${#P_NAMES[@]})); do
  if [[ -z ${P_DIRS[$i]} ]]; then
    g=$(kind_group "${P_KINDS[$i]}")
    same=0
    j=0
    while ((j < ${#P_NAMES[@]})); do
      [[ $(kind_group "${P_KINDS[$j]}") != "$g" ]] || same=$((same + 1))
      j=$((j + 1))
    done
    if ((same > 1)); then P_DIRS[i]="$g/${P_NAMES[$i]}"; else P_DIRS[i]=$g; fi
  fi
  i=$((i + 1))
done

# validate the final dirs
i=0
while ((i < ${#P_NAMES[@]})); do
  name=${P_NAMES[$i]} dir=${P_DIRS[$i]}
  [[ $dir =~ ^[a-z0-9][a-z0-9._/-]*$ && $dir != *..* && $dir != */ ]] ||
    die "part '$name': dir '$dir' must be a relative, lowercase path"
  case $dir in
    make | make/* | tests | tests/* | .git | .git/*) die "part '$name': dir '$dir' is reserved" ;;
  esac
  j=0
  while ((j < i)); do
    [[ ${P_DIRS[$j]} != "$dir" ]] || die "parts '${P_NAMES[$j]}' and '$name' share the dir '$dir'"
    j=$((j + 1))
  done
  i=$((i + 1))
done
FIRST_PART=${P_NAMES[0]}

# production-only parts: named with --production-only (a cloud-worker or web-pages part), or a cloud-worker part
# whose existing wrangler.jsonc declares env.production and no env.staging (read after DEST is known, below)
for spec in ${PROD_SPECS[@]+"${PROD_SPECS[@]}"}; do
  found=''
  i=0
  while ((i < ${#P_NAMES[@]})); do
    if [[ ${P_NAMES[$i]} == "$spec" ]]; then found=${P_KINDS[$i]}; fi
    i=$((i + 1))
  done
  [[ -n $found ]] || die "--production-only $spec: no part named '$spec'"
  case $found in
    cloud-worker | web-pages) ;;
    *) die "--production-only $spec: only cloud-worker and web-pages parts have staging and production" ;;
  esac
  is_prod_only "$spec" || PROD_ONLY="$PROD_ONLY $spec"
done

# --domain and --pages name web-pages parts
for spec in ${DOMAIN_SPECS[@]+"${DOMAIN_SPECS[@]}"} ${PAGES_SPECS[@]+"${PAGES_SPECS[@]}"}; do
  name=${spec%%=*}
  found=''
  i=0
  while ((i < ${#P_NAMES[@]})); do
    if [[ ${P_NAMES[$i]} == "$name" ]]; then found=${P_KINDS[$i]}; fi
    i=$((i + 1))
  done
  [[ $found == web-pages ]] || die "--domain/--pages $spec: no web-pages part named '$name'"
done

if [[ -e $DEST && ! -d $DEST ]]; then
  die "$DEST exists and is not a folder"
fi
if [[ -d $DEST ]] && [[ -n $(ls -A "$DEST") ]] && ((FORCE == 0)); then
  die "$DEST is not empty (use --force to scaffold into it; existing project files are kept)"
fi

# Check the managed templates before writing anything.
[[ -f "$TPL_MAKE/common.mk" ]] || die "skill templates incomplete: templates/make/common.mk is missing"
USED_KINDS=$(printf '%s\n' "${P_KINDS[@]}" | awk '!seen[$0]++')
for k in $USED_KINDS; do
  [[ -f "$TPL_MAKE/kinds/$k.mk" ]] || die "skill templates incomplete: templates/make/kinds/$k.mk is missing"
done

ci_owner_check
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)
CI_PROJECT=$(ci_project)

i=0
while ((i < ${#P_NAMES[@]})); do
  p=${P_NAMES[$i]} d=${P_DIRS[$i]}
  if [[ ${P_KINDS[$i]} == cloud-worker ]] && ! is_prod_only "$p"; then
    if [[ -f "$DEST/$d/wrangler.jsonc" || -f "$DEST/$d/wrangler.json" ]]; then
      envs=$(bash "$TPL_MAKE/bin/cf.sh" envs --dir "$DEST/$d" 2>/dev/null) || envs=''
      if printf '%s\n' "$envs" | grep -qx production && ! printf '%s\n' "$envs" | grep -qx staging; then
        PROD_ONLY="$PROD_ONLY $p"
        note "$p: $d/wrangler.jsonc has env.production and no env.staging, so it is production-only"
      fi
    elif [[ -f "$DEST/$d/wrangler.toml" ]]; then
      note "$p: $d has wrangler.toml; convert it to wrangler.jsonc (make and cf.sh read only jsonc), then scaffold again"
    fi
  fi
  i=$((i + 1))
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/scaffold.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------------
# blocks for the templates

has_cloud=0
PORT_OFFSET=0
n=${#P_NAMES[@]}
i=0
while ((i < n)); do
  p=${P_NAMES[$i]} k=${P_KINDS[$i]} d=${P_DIRS[$i]}
  spec="$p:$k"
  [[ $d == "$p" ]] || spec="$spec:$d"
  if ((i + 1 < n)); then
    printf '  %s \\\n' "$spec" >>"$WORK/PARTS"
  else
    printf '  %s\n' "$spec" >>"$WORK/PARTS"
  fi
  kind_settings "$p" "$k" "$d" >"$WORK/settings.part"
  cat "$WORK/settings.part" >>"$WORK/SETTINGS"
  case $k in cloud-worker | web-pages) has_cloud=1 ;; esac

  {
    printf '## %s {#%s}\n' "$(title_of "$p")" "$p"
    printf 'tech: %s\n' "$(kind_tech "$k")"
    if [[ -n $(kind_docs "$k") ]]; then
      printf 'files: [%s/**, docs/%s/**]\n' "$d" "$p"
    else
      printf 'files: [%s/**]\n' "$d"
    fi
    printf 'kind: %s\n' "$k"
    kind_tasks "$p" "$k" "$d"
    printf '\n'
  } >>"$WORK/COMPONENTS"

  # shellcheck disable=SC2016 # the backticks are Markdown
  printf '| `%s` | %s | `%s/` |\n' "$p" "$(kind_tech "$k")" "$d" >>"$WORK/PARTS_ROWS"

  i=$((i + 1))
done
# The OTA bucket is the project's (its Cloudflare account; CI reads it from here), for the kinds that release OTA.
if grep -Eqx 'zephyr|espidf|pio|arm-gcc|circuitpython|silabs|app-android|app-tauri' <<<"$USED_KINDS"; then
  {
    echo "# R2 bucket that <part>-release uploads OTA images to, in this project's Cloudflare account"
    echo "# (a part can override it with <part>_OTA_BUCKET); make cf-provision ENV=production CONFIRM=production creates it:"
    echo "# OTA_BUCKET := <bucket>"
    echo "# Public r2.dev URL for the apps to download from (cf-provision turns it on; unset, the bucket stays private):"
    echo "# OTA_PUBLIC := r2dev"
  } >>"$WORK/SETTINGS"
fi
[[ -s "$WORK/SETTINGS" ]] || echo "# (none yet)" >"$WORK/SETTINGS"
{
  printf '| Part | What | Folder |\n|---|---|---|\n'
  cat "$WORK/PARTS_ROWS"
} >"$WORK/PARTS_TABLE"

# ---------------------------------------------------------------------------------------------
# write the project

# managed files: always written
place Makefile managed
place make/VERSION managed
copy_managed "$TPL_MAKE/common.mk" make/common.mk
found_bin=0
for f in "$TPL_MAKE"/bin/*.sh; do
  [[ -f $f ]] || continue
  copy_managed "$f" "make/bin/$(basename "$f")"
  chmod 755 "$DEST/make/bin/$(basename "$f")"
  found_bin=1
done
((found_bin == 1)) || die "skill templates incomplete: templates/make/bin/*.sh is missing"
for k in $USED_KINDS; do
  copy_managed "$TPL_MAKE/kinds/$k.mk" "make/kinds/$k.mk"
done

# project-owned files: written once, kept with --force
place make/project.mk own
place make/local.mk own
place README.md own
place CLAUDE.md own
place PLAN.md own
# tests against a deployed service: only for the kinds with smoke and test-remote targets
if grep -Eqx 'cloud-worker|web-pages' <<<"$USED_KINDS"; then
  place tests/smoke/README.md own
  place tests/remote/README.md own
fi
ga_existed=0
[[ ! -e "$DEST/.gitattributes" ]] || ga_existed=1
place .gitattributes own

if [[ ! -e "$DEST/Brewfile" ]]; then
  render "$TPL_PROJECT/Brewfile" "$DEST/Brewfile"
  for k in $USED_KINDS; do
    lines=$(kind_brew "$k")
    [[ -n $lines ]] || continue
    added=''
    while IFS= read -r l; do
      grep -Fxq -- "$l" "$DEST/Brewfile" || added="$added$l"$'\n'
    done <<<"$lines"
    if [[ -n $added ]]; then printf '\n# %s\n%s' "$k" "$added" >>"$DEST/Brewfile"; fi
  done
else
  note "kept existing Brewfile"
fi

if [[ ! -e "$DEST/mise.toml" ]]; then
  render "$TPL_PROJECT/mise.toml" "$DEST/mise.toml"
  for k in $USED_KINDS; do kind_mise "$k"; done | awk '!seen[$0]++' >>"$DEST/mise.toml"
else
  note "kept existing mise.toml"
fi

# gitignore_required: the lines the standard needs in every project's .gitignore, appended when missing (never removed
# or reordered), for a new .gitignore and for an existing one alike: the CI checkouts (.ci/), the local CI runner's
# work folder and secrets file, and per part the release files (and a hardware part's production/). Prints what it added.
gitignore_required() {
  local added l i before altium=0
  before=$(wc -l <"$DEST/.gitignore")
  added=''
  grep -Fxq -- ".ci/" "$DEST/.gitignore" || added=".ci/"$'\n'
  if [[ -n $added ]]; then printf '\n# the CI jobs check the secrets repo and the KiCad library out here (never commit them)\n%s' "$added" >>"$DEST/.gitignore"; fi
  # the local CI runner's work folder and its secrets file (make ci-local): never committed
  added=''
  for l in .act/ .secrets; do
    grep -Fxq -- "$l" "$DEST/.gitignore" || added="$added$l"$'\n'
  done
  if [[ -n $added ]]; then printf '\n# local CI runs (make ci-local): the work folder and the secrets file\n%s' "$added" >>"$DEST/.gitignore"; fi
  # Per part: a hardware or altium part's fab zips (production/), an altium part's OutJob outputs (outputs/), and every
  # part's release files (make <part>-release-assets, attached to the GitHub Release), only in that part's folder so an
  # unrelated folder elsewhere is not hidden.
  added=''
  i=0
  while ((i < n)); do
    if [[ ${P_KINDS[$i]} == altium ]]; then
      l="${P_DIRS[$i]}/outputs/"
      grep -Fxq -- "$l" "$DEST/.gitignore" || added="$added$l"$'\n'
      altium=1
    fi
    if [[ ${P_KINDS[$i]} == hardware || ${P_KINDS[$i]} == altium ]]; then
      l="${P_DIRS[$i]}/production/"
      grep -Fxq -- "$l" "$DEST/.gitignore" || added="$added$l"$'\n'
    fi
    l="${P_DIRS[$i]}/release/"
    grep -Fxq -- "$l" "$DEST/.gitignore" || added="$added$l"$'\n'
    i=$((i + 1))
  done
  if [[ -n $added ]]; then printf '\n# release files (make <part>-release-assets; the GitHub Release keeps them) and generated board outputs\n%s' "$added" >>"$DEST/.gitignore"; fi
  # Altium's history, logs, previews and locks: make <part>-doctor warns about each one that is not ignored
  if ((altium == 1)); then
    added=''
    while IFS= read -r l; do
      grep -Fxq -- "$l" "$DEST/.gitignore" || added="$added$l"$'\n'
    done < <(kind_ignore altium)
    if [[ -n $added ]]; then printf '\n# altium\n%s' "$added" >>"$DEST/.gitignore"; fi
  fi
  if (($(wc -l <"$DEST/.gitignore") > before)); then echo "added"; fi
}

# gitattributes_required: the Git LFS lines a part's kind needs, appended to .gitattributes when no line has their
# pattern yet (never removed or reordered), for a new .gitattributes and an existing one alike: *.wrl (KiCad's VRML
# models) for a hardware part, *.FCStd for a mechanical part (git matches with case on Linux, so *.fcstd alone leaves a
# Linux checkout with the pointer files), and for an altium part its binary documents in LFS and its text files kept
# byte-exact (templates/altium/gitattributes). Prints what it added.
gitattributes_required() {
  local f="$DEST/.gitattributes" added='' l pat
  [[ -f $f ]] || return 0
  {
    if has_kind hardware; then printf '%s\n' '*.wrl filter=lfs diff=lfs merge=lfs -text'; fi
    if has_kind mechanical; then printf '%s\n' '*.FCStd filter=lfs diff=lfs merge=lfs -text'; fi
    if has_kind altium; then grep -v '^#' "$SKILL_DIR/templates/altium/gitattributes" | grep -v '^[[:space:]]*$'; fi
  } >"$WORK/gitattributes.want"
  while IFS= read -r l; do
    pat=${l%%[[:space:]]*}
    awk -v p="$pat" '$1 == p { found = 1 } END { exit !found }' "$f" || added="$added$l"$'\n'
  done <"$WORK/gitattributes.want"
  [[ -n $added ]] || return 0
  printf '\n# the CAD files of this project'"'"'s kinds: binaries in Git LFS (never merged), Altium'"'"'s text files byte-exact\n%s' "$added" >>"$f"
  echo "added"
}

if [[ ! -e "$DEST/.gitignore" ]]; then
  render "$TPL_PROJECT/.gitignore" "$DEST/.gitignore"
  for k in $USED_KINDS; do
    lines=$(kind_ignore "$k")
    [[ -n $lines ]] || continue
    added=''
    while IFS= read -r l; do
      grep -Fxq -- "$l" "$DEST/.gitignore" || added="$added$l"$'\n'
    done <<<"$lines"
    if [[ -n $added ]]; then printf '\n# %s\n%s' "$k" "$added" >>"$DEST/.gitignore"; fi
  done
  gitignore_required >/dev/null
elif [[ -n $(gitignore_required) ]]; then
  note "kept existing .gitignore, and added the standard's missing CI and release lines (.ci/, ci-local, <dir>/release/) at its end"
else
  note "kept existing .gitignore"
fi

# has_kind KIND...   true when a part in PARTS has one of the kinds.
has_kind() {
  local k
  for k in "$@"; do
    grep -Fxq -- "$k" <<<"$USED_KINDS" && return 0
  done
  return 1
}

if [[ -n $(gitattributes_required) ]] && ((ga_existed == 1)); then
  note "added the .gitattributes lines of the project's kinds (*.wrl, *.FCStd, Altium's documents) at its end"
fi

# schema_row NAME ENVS USED-BY GEN DESCRIPTION   one secrets.schema row, in the template's columns.
schema_row() { printf '%-22s %-26s %-14s %-5s %s\n' "$@"; }

# app_secret_rows   the secrets.schema rows of the app kinds in PARTS, each written only for the kinds that read it:
#   APPLE_SIGNING_IDENTITY, APPLE_API_KEY, APPLE_API_ISSUER   app-tauri (macOS signing and notarisation, std_apple_prefix)
#   appstore-api-key        app-tauri (notarisation, TestFlight), app-flutter and app-xcode (TestFlight / App Store)
#   play-service-account    app-tauri, app-flutter, app-android (CHANNEL=play / TARGET=appbundle uploads)
#   android-keystore, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD   app-android (its release build;
#                           Flutter and Tauri Android are not signed by the helper)
#   windows-codesign, WINDOWS_CERT_PASSWORD   app-tauri (sign-windows.sh in the CI Windows job)
app_secret_rows() {
  local asc
  if has_kind app-tauri; then
    schema_row APPLE_SIGNING_IDENTITY production app no "optional: the Developer ID identity of the Tauri macOS build (signed when set, unsigned without it)"
    schema_row APPLE_API_KEY production app no "optional: App Store Connect key id (Tauri macOS notarisation; the key file is appstore-api-key)"
    schema_row APPLE_API_ISSUER production app no "optional: App Store Connect issuer id (Tauri macOS notarisation)"
  fi
  if has_kind app-tauri app-flutter app-xcode; then
    asc="the App Store Connect upload (TestFlight) of make <part>-release"
    if has_kind app-tauri; then asc="$asc and the Tauri macOS notarisation"; fi
    schema_row appstore-api-key keys app no "optional: the App Store Connect API key (.p8) for $asc, handed over as a temp file"
  fi
  if has_kind app-tauri app-flutter app-android; then
    schema_row play-service-account keys app no "optional: the Google Play service account (JSON) for the Play upload of make <part>-release, handed over as a temp file"
  fi
  if has_kind app-android; then
    schema_row android-keystore keys app no "optional: the Android release keystore, handed over as a temp file (ANDROID_KEYSTORE_FILE); unsigned without it"
    schema_row ANDROID_KEYSTORE_PASSWORD production app no "optional: password of android-keystore (read by build.gradle.kts)"
    schema_row ANDROID_KEY_ALIAS production app no "optional: the key alias in android-keystore (read by build.gradle.kts)"
    schema_row ANDROID_KEY_PASSWORD production app no "optional: password of the key in android-keystore (read by build.gradle.kts)"
  fi
  if has_kind app-tauri; then
    schema_row windows-codesign keys ci no "optional: the Windows code-signing certificate (PFX); the Windows build is unsigned without it"
    schema_row WINDOWS_CERT_PASSWORD staging ci no "optional: password of windows-codesign (read by sign-windows.sh in CI)"
  fi
  return 0
}

if [[ ! -e "$DEST/secrets.schema" ]]; then
  render "$TPL_PROJECT/secrets.schema" "$DEST/secrets.schema"
  if ((has_cloud == 1)) || fw_publishes; then
    {
      printf '%-22s %-26s %-14s %-5s %s\n' CLOUDFLARE_API_TOKEN staging,production auth,ci no \
        "the project's one API token, stored for staging and production by make cf-login (permissions: see the project-standard docs)"
      printf '%-22s %-26s %-14s %-5s %s\n' CLOUDFLARE_ACCOUNT_ID common auth,ci no "Cloudflare account id"
    } >>"$DEST/secrets.schema"
  fi
  # the app kinds: each signing, notarisation and store name is written only when a kind in PARTS reads it
  # (app_secret_rows). All are optional: without them the build is unsigned or the upload is not possible, and
  # the release helper says so.
  app_secret_rows >>"$DEST/secrets.schema"
  # silabs: the image signing key, read only when a part sets <part>_SIGN := 1 (make <part>-keygen creates it)
  if has_kind silabs; then
    schema_row silabs-m4 keys firmware ecdsa-p256 "optional: SiWx917 M4 image signing key, used when <part>_SIGN := 1 (make <part>-keygen)" >>"$DEST/secrets.schema"
  fi
else
  note "kept existing secrets.schema"
  # an existing schema is never rewritten: say what the standard would add
  if { ((has_cloud == 1)) || fw_publishes; } && ! grep -Eq '^[[:space:]]*CLOUDFLARE_API_TOKEN[[:space:]]' "$DEST/secrets.schema"; then
    note "secrets.schema has no CLOUDFLARE_API_TOKEN row, and this project uses Cloudflare (a Worker or Pages part, or OTA_BUCKET): add the CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID rows (project-standard reference/standard.md, section 5, secrets.schema)"
  fi
  if has_kind silabs && ! grep -Eq '^[[:space:]]*silabs-m4[[:space:]]' "$DEST/secrets.schema"; then
    note "secrets.schema has no silabs-m4 row (the silabs image signing key, used with <part>_SIGN := 1): add it as in reference/standard.md, section 5"
  fi
fi

# the workflows are written when missing (an existing one is kept, as the other project files are)
for wf in checks release; do
  if [[ -e "$DEST/.github/workflows/$wf.yml" ]]; then
    note "kept existing .github/workflows/$wf.yml"
  elif [[ $wf == checks && -e "$DEST/.github/workflows/ci.yml" ]]; then
    # v15 and earlier: the same workflow under its old name; renamed by hand, never written twice
    note "kept .github/workflows/ci.yml, the v15 name: rename it with git mv .github/workflows/ci.yml .github/workflows/checks.yml"
  else
    mkdir -p "$DEST/.github/workflows"
    if [[ $wf == checks ]]; then ci_workflow >"$DEST/.github/workflows/checks.yml"; else ci_release_workflow >"$DEST/.github/workflows/release.yml"; fi
  fi
done

# part folders and starters
i=0
while ((i < n)); do
  p=${P_NAMES[$i]} k=${P_KINDS[$i]} d=${P_DIRS[$i]}
  if [[ -e "$DEST/$d" ]]; then
    note "kept existing $d/"
  else
    case $k in
      cloud-worker) starter_cloud_worker "$p" "$d" ;;
      web-pages) starter_web_pages "$p" "$d" ;;
    esac
  fi
  # a web part's wrangler.jsonc: written when missing, also in a part folder that exists (adopt)
  [[ $k != web-pages ]] || web_wrangler "$p" "$d"
  # the part's documents: written when missing, also in a part folder that exists (adopt)
  part_readme "$p" "$k" "$d"
  part_changelog "$p" "$d"
  part_docs "$p" "$k" "$d"
  i=$((i + 1))
done
project_docs
references_doc

printf '%sscaffolded%s %s%s%s  (project-standard v%s, %d parts, port base %s)\n' \
  "$C_GREEN" "$C_OFF" "$C_BLUE" "$DEST" "$C_OFF" "$STD_VERSION" "$n" "$PORT_BASE"
if [[ -e "$DEST/.gitlab-ci.yml" ]]; then
  warn ".gitlab-ci.yml is left over from GitLab CI and is not used any more; once .github/workflows/ is committed, you run: git rm .gitlab-ci.yml"
fi
# An existing git repository (adopt, update: --force into a checkout or a worktree, whose .git is a file) is not
# initialised again; a new folder is.
if [[ -e "$DEST/.git" ]]; then
  note "next: git diff to review, then make setup && make doctor"
else
  note "next: git init -b main && make setup && make secrets-init && make doctor"
fi
