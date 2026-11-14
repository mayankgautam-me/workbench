#!/usr/bin/env bats
# Releases (v9): make <part>-bump for every kind with a version, release.sh gate and create (upload is its alias), and
# <part>-release-assets per kind against stubbed build outputs. GitHub is a stub: gh (helpers.bash, stub_gh) records its
# argv and the notes it is given, and keeps the Release's state in $STUB_LOG. Nothing is pushed or sent.

load helpers

ALL_KINDS="zephyr espidf pio arm-gcc circuitpython hardware go python docker cloud-worker web-pages app-flutter app-tauri app-xcode app-android"

setup() {
  std_setup_env
  R="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  P="$R/proj"
  export STD_TOOLCHAINS="$R/toolchains"
  mkdir -p "$STD_TOOLCHAINS/ncs-v3.2.1/zephyr" "$STD_TOOLCHAINS/zephyr-sdk-0.17.4" "$STD_TOOLCHAINS/esp-idf-v5.5"
  : >"$STD_TOOLCHAINS/ncs-v3.2.1/zephyr/zephyr-env.sh"
  : >"$STD_TOOLCHAINS/esp-idf-v5.5/export.sh"
  stub_gh
}

argv() { cat "$STUB_LOG/$1.argv" 2>/dev/null; }

# A project with one part of every kind.
allproject() {
  mkproject "$P" "PROJECT := demo
PARTS := fw:zephyr esp:espidf pio:pio arm:arm-gcc cpy:circuitpython hw:hardware go:go:svc/go py:python:svc/py \\
  dock:docker:svc/dock api:cloud-worker:cloud/api web:web-pages:cloud/web flut:app-flutter:apps/flut \\
  tau:app-tauri:apps/tau xc:app-xcode:apps/xc andr:app-android:apps/andr
fw_BOARD := nrf/x
cpy_BOARD := feather
DOCKER_REGISTRY := registry.invalid
KICAD_IBOM :=
KICAD_PREFS := $R/prefs"
  for k in $ALL_KINDS; do cp "$STD_TEMPLATES/kinds/$k.mk" "$P/make/kinds/"; done
  cd "$P"
  git init -q -b main .
  git init -q --bare -b main "$R/remote.git"
  git remote add origin "$R/remote.git"
}

# changelog DIR: a CHANGELOG with something under Unreleased.
changelog() {
  mkdir -p "$1"
  printf '%s\n' '# Changelog' '' 'Intro.' '' '## [Unreleased]' '' '### Added' '' '- a feature' '' '### Changed' '' \
    '### Fixed' '' '- a "quoted" bug \ with a backslash' '' '## [0.0.1] - 2026-01-01' '' '### Added' '' '- first' >"$1/CHANGELOG.md"
}

# version sources of every part, before any bump
mkversions() {
  mkdir -p fw esp pio arm cpy hw svc/go svc/py svc/dock cloud/api cloud/web apps/flut apps/tau/src-tauri apps/xc apps/andr/app
  printf 'VERSION_MAJOR = 1\nVERSION_MINOR = 4\nPATCHLEVEL = 2\nVERSION_TWEAK = 0\nEXTRAVERSION =\n' >fw/VERSION
  printf '2.0.0\n' >pio/version.txt
  printf '(kicad_pcb\n\t(title_block\n\t\t(rev "Version 2")\n\t)\n)\n' >hw/Board.kicad_pcb
  : >hw/Board.kicad_pro
  printf '1.2\n' >svc/go/VERSION
  printf 'name: flut\nversion: 1.2.3+7\n' >apps/flut/pubspec.yaml
  printf '{\n  "productName": "Tau",\n  "version": "0.3.0",\n  "identifier": "x"\n}\n' >apps/tau/src-tauri/tauri.conf.json
  printf 'android {\n    defaultConfig {\n        versionCode = 21\n        versionName = "2.1.0"\n    }\n}\n' >apps/andr/app/build.gradle.kts
  printf '[project]\nname = "py"\nversion = "0.9.0"\n\n[tool.other]\nversion = "9"\n' >svc/py/pyproject.toml
  for d in fw esp pio arm cpy hw svc/go svc/py svc/dock cloud/api cloud/web apps/flut apps/tau apps/xc apps/andr; do changelog "$d"; done
  git add -A && git commit -qm start
}

# fake xcrun: agvtool keeps the marketing version in apps/xc/.marketing
stub_xcrun() {
  stub_cmd xcrun 'case "$1 $2" in
  "agvtool what-marketing-version") cat .marketing 2>/dev/null ;;
  "agvtool new-marketing-version") printf "%s\n" "$3" >.marketing ;;
  "agvtool next-version") echo "build+1" >>.build ;;
  *) exit 1 ;;
esac'
}

# --- bump --------------------------------------------------------------------------------------

@test "bump sets the version in every kind's own source, moves Unreleased, commits only those files and tags" {
  allproject
  mkversions
  stub_xcrun
  printf '3.1.0\n' >apps/xc/.marketing
  echo 1 >apps/xc/.build
  git add -A && git commit -qm xc
  echo dirty >>README.md
  run make fw-bump LEVEL=minor
  [ "$status" -eq 0 ]
  [[ "$output" == *"git push --atomic origin main fw-v1.5.0"* ]]
  grep -qx 'VERSION_MINOR = 5' fw/VERSION
  grep -qx 'PATCHLEVEL = 0' fw/VERSION
  grep -qx 'VERSION_TWEAK = 0' fw/VERSION
  run make esp-bump LEVEL=patch
  [ "$status" -eq 0 ]
  [ "$(cat esp/VERSION)" = 0.0.1 ]
  run make pio-bump LEVEL=major
  [ "$(cat pio/version.txt)" = 3.0.0 ]
  [ ! -f pio/VERSION ]
  run make hw-bump LEVEL=patch
  [ "$status" -eq 0 ]
  [[ "$output" == *"title block"* ]]
  [ "$(cat hw/VERSION)" = 3 ]
  run make go-bump LEVEL=minor
  [ "$(cat svc/go/VERSION)" = 1.3 ]
  run make py-bump VERSION=1.0.0-rc1
  [ "$status" -eq 0 ]
  grep -qx 'version = "1.0.0-rc1"' svc/py/pyproject.toml
  grep -qx 'version = "9"' svc/py/pyproject.toml
  run make dock-bump LEVEL=minor
  [ "$(cat svc/dock/VERSION)" = 0.1.0 ]
  run make api-bump LEVEL=major
  [ "$(cat cloud/api/VERSION)" = 1.0.0 ]
  run make web-bump LEVEL=patch
  [ "$(cat cloud/web/VERSION)" = 0.0.1 ]
  run make flut-bump LEVEL=patch
  grep -qx 'version: 1.2.4+8' apps/flut/pubspec.yaml
  run make tau-bump LEVEL=minor
  grep -q '"version": "0.4.0",' apps/tau/src-tauri/tauri.conf.json
  run make andr-bump LEVEL=patch
  grep -q 'versionName = "2.1.1"' apps/andr/app/build.gradle.kts
  grep -q 'versionCode = 22' apps/andr/app/build.gradle.kts
  run make xc-bump LEVEL=minor
  [ "$status" -eq 0 ]
  [ "$(cat apps/xc/.marketing)" = 3.2.0 ]
  [ -f apps/xc/.build ]
  # one commit and one annotated tag per part, nothing else committed, nothing pushed
  for t in fw-v1.5.0 esp-v0.0.1 pio-v3.0.0 hw-v3 go-v1.3 py-v1.0.0-rc1 dock-v0.1.0 api-v1.0.0 web-v0.0.1 flut-v1.2.4 tau-v0.4.0 andr-v2.1.1 xc-v3.2.0; do
    [ "$(git cat-file -t "$t")" = tag ]
  done
  [ "$(git log -1 --format=%s fw-v1.5.0)" = "fw: release 1.5.0" ]
  [ "$(git diff-tree --no-commit-id --name-only -r 'fw-v1.5.0^{commit}' | sort | tr '\n' ' ')" = "fw/CHANGELOG.md fw/VERSION " ]
  [ "$(git diff-tree --no-commit-id --name-only -r 'hw-v3^{commit}' | sort | tr '\n' ' ')" = "hw/CHANGELOG.md hw/VERSION " ]
  [ "$(git status --porcelain)" = "?? README.md" ]
  [ -z "$(git --git-dir="$R/remote.git" tag)" ]
  # versions read back
  run make fw-version
  [ "$output" = "fw 1.5.0" ]
  run make api-version
  [ "$output" = "api 1.0.0" ]
  # patch releases a pre-release
  run make py-bump LEVEL=patch FORCE=1
  [ "$status" -eq 0 ]
  grep -qx 'version = "1.0.0"' svc/py/pyproject.toml
}

# tauri_files: the three files a Tauri app declares its version in, plus a Cargo.lock with the app's entry and a
# dependency of the same version. Cargo.toml has a dependency at the same version and a [package.metadata] version.
tauri_files() {
  printf '%s\n' '[package]' 'name = "tau"' 'version = "0.1.0"' 'edition = "2021"' '' '[package.metadata.x]' 'version = "0.1.0"' '' \
    '[dependencies]' 'serde = { version = "0.1.0", features = ["derive"] }' '' '[dependencies.tauri]' 'version = "0.1.0"' \
    >apps/tau/src-tauri/Cargo.toml
  printf '%s\n' '# This file is automatically @generated by Cargo.' 'version = 4' '' '[[package]]' 'name = "serde"' 'version = "0.1.0"' \
    'source = "registry+https://github.com/rust-lang/crates.io-index"' '' '[[package]]' 'name = "tau"' 'version = "0.1.0"' \
    'dependencies = [' ' "serde",' ']' >apps/tau/src-tauri/Cargo.lock
  printf '%s\n' '{' '  "name": "tau",' '  "private": true,' '  "version": "0.1.0",' '  "devDependencies": {' \
    '    "x": { "version": "0.1.0" }' '  }' '}' >apps/tau/package.json
}

@test "bump of a Tauri app sets tauri.conf.json, Cargo.toml [package], package.json and the app's Cargo.lock entry" {
  allproject
  mkversions
  tauri_files
  git add -A && git commit -qm tauri
  run make tau-bump VERSION=1.2.0
  [ "$status" -eq 0 ]
  grep -q '"version": "1.2.0",' apps/tau/src-tauri/tauri.conf.json
  [ "$(sed -n 3p apps/tau/src-tauri/Cargo.toml)" = 'version = "1.2.0"' ]
  [ "$(grep -c '"1.2.0"' apps/tau/src-tauri/Cargo.toml)" = 1 ]
  # dependencies and other tables keep their versions
  [ "$(sed -n 7p apps/tau/src-tauri/Cargo.toml)" = 'version = "0.1.0"' ]
  grep -qx 'serde = { version = "0.1.0", features = \["derive"\] }' apps/tau/src-tauri/Cargo.toml
  [ "$(sed -n 13p apps/tau/src-tauri/Cargo.toml)" = 'version = "0.1.0"' ]
  [ "$(sed -n 6p apps/tau/src-tauri/Cargo.lock)" = 'version = "0.1.0"' ]
  [ "$(sed -n 11p apps/tau/src-tauri/Cargo.lock)" = 'version = "1.2.0"' ]
  grep -q '^  "version": "1.2.0",$' apps/tau/package.json
  grep -q '"x": { "version": "0.1.0" }' apps/tau/package.json
  [ "$(git diff-tree --no-commit-id --name-only -r 'tau-v1.2.0^{commit}' | sort | tr '\n' ' ')" = \
    "apps/tau/CHANGELOG.md apps/tau/package.json apps/tau/src-tauri/Cargo.lock apps/tau/src-tauri/Cargo.toml apps/tau/src-tauri/tauri.conf.json " ]
  [ -z "$(git status --porcelain)" ]
  # version still reads tauri.conf.json; a two-part version works the same
  run make tau-version
  [ "$output" = 1.2.0 ]
  changelog apps/tau
  git add -A && git commit -qm notes
  run make tau-bump VERSION=1.3
  [ "$status" -eq 0 ]
  [ "$(sed -n 3p apps/tau/src-tauri/Cargo.toml)" = 'version = "1.3"' ]
  [ "$(sed -n 11p apps/tau/src-tauri/Cargo.lock)" = 'version = "1.3"' ]
  grep -q '^  "version": "1.3",$' apps/tau/package.json
  run make tau-version
  [ "$output" = 1.3 ]
}

@test "bump of a Tauri app leaves an untracked Cargo.lock alone and skips files that are missing" {
  allproject
  mkversions
  tauri_files
  rm apps/tau/package.json
  git add apps/tau/src-tauri/Cargo.toml && git commit -qm cargo
  run make tau-bump LEVEL=patch
  [ "$status" -eq 0 ]
  [ "$(sed -n 3p apps/tau/src-tauri/Cargo.toml)" = 'version = "0.3.1"' ]
  [ "$(sed -n 11p apps/tau/src-tauri/Cargo.lock)" = 'version = "0.1.0"' ]
  [ ! -f apps/tau/package.json ]
  [ "$(git diff-tree --no-commit-id --name-only -r 'tau-v0.3.1^{commit}' | sort | tr '\n' ' ')" = \
    "apps/tau/CHANGELOG.md apps/tau/src-tauri/Cargo.toml apps/tau/src-tauri/tauri.conf.json " ]
}

@test "bump moves the Unreleased notes under the version and leaves a fresh empty Unreleased" {
  allproject
  mkversions
  run make fw-bump LEVEL=patch
  [ "$status" -eq 0 ]
  d=$(date +%Y-%m-%d)
  expected="# Changelog

Intro.

## [Unreleased]

### Added

### Changed

### Fixed

## [1.4.3] - $d

### Added

- a feature

### Fixed

- a \"quoted\" bug \\ with a backslash

## [0.0.1] - 2026-01-01

### Added

- first"
  [ "$(cat fw/CHANGELOG.md)" = "$expected" ]
  run bash make/bin/release.sh notes --part fw --version 1.4.3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "### Added" ]
  [[ "$output" == *'- a "quoted" bug \ with a backslash' ]]
  run bash make/bin/release.sh notes --part fw --version 9.9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ## [9.9.9] section"* ]]
}

@test "bump refuses an empty Unreleased (FORCE=1 goes on), no LEVEL, a bad level, an existing tag, a dynamic python version" {
  allproject
  mkversions
  run make fw-bump
  [ "$status" -ne 0 ]
  [[ "$output" == *"LEVEL=patch, minor or major"* ]]
  run make fw-bump LEVEL=huge
  [ "$status" -ne 0 ]
  run make fw-bump VERSION=1.x
  [ "$status" -ne 0 ]
  run make fw-bump LEVEL=patch
  [ "$status" -eq 0 ]
  run make fw-bump LEVEL=patch
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unreleased section of fw/CHANGELOG.md is empty"* ]]
  [ "$(cat fw/VERSION | grep PATCHLEVEL)" = "PATCHLEVEL = 3" ]
  [ -z "$(git status --porcelain)" ]
  run make fw-bump LEVEL=patch FORCE=1
  [ "$status" -eq 0 ]
  git rev-parse -q --verify refs/tags/fw-v1.4.4
  run make go-bump LEVEL=patch
  [ "$status" -eq 0 ]
  git tag go-v9.0.0
  run make go-bump VERSION=9.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag go-v9.0.0 exists already"* ]]
  printf '[project]\nname = "py"\ndynamic = ["version"]\n' >svc/py/pyproject.toml
  run make py-bump LEVEL=patch
  [ "$status" -ne 0 ]
  [[ "$output" == *"dynamic"* ]]
}

@test "xcode bump refuses without agvtool" {
  allproject
  mkversions
  mkdir -p "$R/minbin"
  for t in bash git sed awk grep head tail tr cat mktemp rm date dirname basename paste mv mkdir env cp; do
    ln -s "$(command -v "$t")" "$R/minbin/$t"
  done
  PATH="$R/minbin" run bash make/bin/release.sh bump --part xc --kind app-xcode --part-dir apps/xc --version 1.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"agvtool"* ]]
  [ -z "$(git status --porcelain)" ]
}

@test "release.sh next versions keep the number of components" {
  allproject
  mkversions
  printf '7\n' >svc/go/VERSION
  git commit -qam seven
  run make go-bump LEVEL=minor
  [ "$(cat svc/go/VERSION)" = 8 ]
}

# --- push ---------------------------------------------------------------------------------------

@test "release-push: pushes the branch, then each new release tag on its own; skips a tag origin has; refuses a moved one" {
  allproject
  for i in 1 2 3; do echo "$i" >"f$i"; git add "f$i"; git commit -qm "c$i"; done
  git tag -a a-v1.0.0 -m a HEAD~2
  git tag -a b-v1.0.0 -m b HEAD~1
  git tag -a c-v1.0.0 -m c HEAD
  git tag -a d-v1.0.0 -m d HEAD
  git tag -a note -m "not a release tag" HEAD
  git push -q origin main refs/tags/a-v1.0.0
  # a stub git that logs every push, so each tag's push can be counted
  mkdir -p "$R/gitbin"
  printf '#!/bin/sh\n[ "$1" = push ] && echo "$*" >>"%s/pushes"\nexec %s "$@"\n' "$R" "$(command -v git)" >"$R/gitbin/git"
  chmod +x "$R/gitbin/git"
  PATH="$R/gitbin:$PATH" run make release-push
  [ "$status" -eq 0 ]
  [ "$(grep -c 'refs/tags/' "$R/pushes")" -eq 3 ]
  grep -qx 'push origin main' "$R/pushes"
  ! grep -q 'a-v1.0.0\|note' "$R/pushes"
  [ "$(git ls-remote --tags origin 'refs/tags/*-v*' | grep -vc '\^{}')" -eq 4 ]
  # nothing new: says so
  run make release-push
  [ "$status" -eq 0 ]
  [[ $output == *"no new release tag to push"* ]]
  # a tag that origin has with another commit is refused, not overwritten
  git tag -d b-v1.0.0 >/dev/null
  git tag -a b-v1.0.0 -m b HEAD
  run make release-push
  [ "$status" -ne 0 ]
  [[ $output == *"tag b-v1.0.0 is on origin with another commit"* ]]
}

@test "bump points at make release-push, never at a multi-tag push" {
  allproject
  mkversions
  run make go-bump LEVEL=patch
  [ "$status" -eq 0 ]
  [[ $output == *"make release-push"* ]]
  [[ $output != *"git push --atomic"* ]]
}

# --- gate ---------------------------------------------------------------------------------------

@test "gate: its own tag goes on; another part's tag is nothing to do; a wrong version, another ref, or no ref refuses" {
  allproject
  rel() { bash make/bin/release.sh "$@"; }
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.2.0 run rel gate --part fw --version 1.2.0
  [ "$status" -eq 0 ]
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-x-v1.2.0 run rel gate --part fw --version 1.2.0
  [ "$status" -eq 3 ]
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.3.0 run rel gate --part fw --version 1.2.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match"* ]]
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main run rel gate --part fw --version 1.2.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"only by the release workflow of a fw-v* tag"* ]]
  GITHUB_ACTIONS=true run rel gate --part fw --version 1.2.0
  [ "$status" -eq 1 ]
  GITHUB_ACTIONS=true run rel gate --part fw --version 1.2.0 --force
  [ "$status" -eq 1 ]
  run rel gate --part fw --version 1.2.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"FORCE=1"* ]]
  run rel gate --part fw --version 1.2.0 --force
  [ "$status" -eq 0 ]
}

@test "github-release needs FORCE=1 from the command line on a Mac; the gitlab-release alias is gone (v9)" {
  allproject
  mkversions
  mkdir -p svc/go/dist
  FORCE=1 run make go-github-release NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"FORCE=1 makes it from here"* ]]
  [ ! -f "$STUB_LOG/gh.argv" ]
  run make go-gitlab-release NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"No rule to make target"* ]]
  [ ! -f "$STUB_LOG/gh.argv" ]
}

# --- create -------------------------------------------------------------------------------------

mkassets() {
  mkdir -p "$1"
  echo a >"$1/fw.bin"
  echo b >"$1/fw.elf"
  bash make/bin/release.sh sums --dir "$1" >/dev/null 2>&1
}

# a CHANGELOG with notes for fw, and fw bumped to 1.2.0 (the tag fw-v1.2.0 exists; nothing is pushed)
fw_release() {
  changelog fw
  git add -A && git commit -qm cl
  bash make/bin/release.sh bump --part fw --kind zephyr --version 1.2.0 >/dev/null
}

@test "create: the Release with its notes and the linked files; the unlinked files are named for the workflow, not sent" {
  allproject
  fw_release
  mkassets "$R/assets"
  echo '{}' >"$R/assets/image.json"
  echo x >"$R/assets/fw.aab"
  echo x >"$R/assets/fw-mapping.txt"
  GITHUB_ACTIONS=true GITHUB_REPOSITORY=owner/demo GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.2.0 GH_TOKEN=secret-token \
    run bash make/bin/release.sh create --part fw --version 1.2.0 --dir "$R/assets"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unlinked: fw.aab"* ]]
  [[ "$output" == *"unlinked: fw-mapping.txt"* ]]
  [[ "$output" == *'release fw-v1.2.0 created: "fw 1.2.0" with 4 assets'* ]]
  a="$(argv gh)"
  [[ "$a" == *$'release\ncreate\nfw-v1.2.0\n--title\nfw 1.2.0\n--notes-file\n'* ]]
  [[ "$a" == *"--verify-tag"* ]]
  [[ "$a" == *"$R/assets/fw.bin"* && "$a" == *"$R/assets/SHA256SUMS"* && "$a" == *"$R/assets/image.json"* ]]
  [[ "$a" != *"fw.aab"* && "$a" != *"fw-mapping.txt"* ]]
  [[ "$a" == *$'--repo\nowner/demo'* ]]
  [[ "$a" != *secret-token* ]]
  [ "$(cat "$STUB_LOG/notes.txt")" = "$(printf '### Added\n\n- a feature\n\n### Fixed\n\n- a "quoted" bug \\ with a backslash')" ]
}

@test "create on a Mac: gh infers the repo, so no --repo is passed; a version without notes refuses" {
  allproject
  fw_release
  mkassets "$R/assets"
  run bash make/bin/release.sh create --part fw --version 1.2.0 --dir "$R/assets"
  [ "$status" -eq 0 ]
  [[ "$(argv gh)" != *"--repo"* ]]
  run bash make/bin/release.sh create --part fw --version 1.3.0 --dir "$R/assets"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ## [1.3.0] section"* ]]
}

@test "upload is the v8 name of create: the same Release" {
  allproject
  fw_release
  mkassets "$R/assets"
  run bash make/bin/release.sh upload --part fw --version 1.2.0 --dir "$R/assets"
  [ "$status" -eq 0 ]
  [[ "$(argv gh)" == *$'release\ncreate\nfw-v1.2.0\n'* ]]
}

@test "create when the Release exists: name and notes edited, the assets uploaded over the old ones" {
  allproject
  fw_release
  mkassets "$R/assets"
  printf '%s\n' '### Added' '' '- old' >"$STUB_LOG/release.body"
  touch "$STUB_LOG/release.exists"
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.2.0 \
    run bash make/bin/release.sh create --part fw --version 1.2.0 --dir "$R/assets"
  [ "$status" -eq 0 ]
  [[ "$output" == *"release fw-v1.2.0 updated: 3 assets"* ]]
  a="$(argv gh)"
  [[ "$a" == *$'release\nedit\nfw-v1.2.0\n--title\nfw 1.2.0\n--notes-file\n'* ]]
  [[ "$a" == *$'release\nupload\nfw-v1.2.0\n--clobber\n'* ]]
  [[ "$a" != *$'release\ncreate\n'* ]]
  [[ "$(cat "$STUB_LOG/notes.txt")" == *"- a feature"* ]]
}

@test "build lines: another platform's line survives this update, and this run's line replaces the old one of its platform" {
  allproject
  fw_release
  mkassets "$R/assets"
  printf '%s\n' '### Added' '' '- x' '' '### Builds' '- ios: TestFlight build 41 (version 1.2.0)' '- macos: notarised' \
    >"$STUB_LOG/release.body"
  touch "$STUB_LOG/release.exists"
  printf 'ios: TestFlight build 42 (version 1.2.0)\n' >"$R/bn.txt"
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.2.0 \
    run bash make/bin/release.sh create --part fw --version 1.2.0 --dir "$R/assets" --build-note-file "$R/bn.txt"
  [ "$status" -eq 0 ]
  n="$(cat "$STUB_LOG/notes.txt")"
  [[ "$n" == *"TestFlight build 42"* ]]
  [[ "$n" != *"TestFlight build 41"* ]]
  [[ "$n" == *"- macos: notarised"* ]]
  [[ "$n" == *"### Builds"* ]]
}

@test "create sends the checksum files of every platform with the assets" {
  allproject
  fw_release
  mkassets "$R/assets"
  printf 'x\n' >"$R/assets/SHA256SUMS-macos"
  run bash make/bin/release.sh create --part fw --version 1.2.0 --dir "$R/assets"
  [ "$status" -eq 0 ]
  [[ "$(argv gh)" == *"$R/assets/SHA256SUMS-macos"* ]]
}

@test "github-release in the release workflow: assets, then the Release; another part's tag does nothing; no gitlab-release target" {
  allproject
  mkversions
  run make go-bump LEVEL=minor
  mkdir -p svc/go/dist
  for a in linux-amd64 darwin-arm64; do echo bin >"svc/go/dist/go-1.3-$a"; done
  echo old >svc/go/dist/go-1.2-linux-amd64
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=go-v1.3 GH_TOKEN=t \
    run make go-github-release NOBUILD=1
  [ "$status" -eq 0 ]
  [ "$(LC_ALL=C ls svc/go/release/1.3 | tr '\n' ' ')" = "SHA256SUMS go-1.3-darwin-arm64 go-1.3-linux-amd64 " ]
  a="$(argv gh)"
  [[ "$a" == *$'release\ncreate\ngo-v1.3\n'* ]]
  [[ "$a" == *"go-1.3-darwin-arm64"* ]]
  rm -f "$STUB_LOG/gh.argv"
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.5.0 run make go-github-release NOBUILD=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a go release"* ]]
  [ ! -f "$STUB_LOG/gh.argv" ]
  # the root target needs PART with several parts; the v8 name is gone (the v8 to v9 step renames it)
  run make github-release
  [ "$status" -eq 2 ]
  [[ "$output" == *"PART=<part>"* ]]
  run make gitlab-release
  [ "$status" -ne 0 ]
  [[ "$output" == *"No rule to make target"* ]]
}


# --- release assets per kind ----------------------------------------------------------------------

@test "release-assets per kind collects the expected files from the build outputs" {
  allproject
  mkversions
  stub_xcrun
  printf '3.1.0\n' >apps/xc/.marketing
  for d in esp arm cpy svc/dock cloud/api cloud/web; do printf '1.0.0\n' >"$d/VERSION"; done
  # stubs for the tools the helpers call
  stub_cmd esptool.py 'while [ $# -gt 0 ]; do [ "$1" = -o ] && echo merged >"$2"; shift; done'
  stub_cmd arm-none-eabi-objcopy 'echo hex >"${@: -1}"'
  stub_cmd docker 'echo "$*" >>"$STUB_LOG/docker.argv"; case "$*" in *imagetools*) echo sha256:abc ;; esac'
  # zephyr (sysbuild, MCUboot)
  b=fw/build/nrf_x
  mkdir -p "$b/fw/zephyr"
  for f in dfu_application.zip merged.hex; do echo x >"$b/$f"; done
  for f in zephyr.signed.bin zephyr.signed.hex zephyr.elf zephyr.map; do echo x >"$b/fw/zephyr/$f"; done
  # espidf
  b=esp/build/esp32c6
  mkdir -p "$b/bootloader" "$b/partition_table"
  printf '{"app_bin": "esp.bin", "x": 1}\n' >"$b/project_description.json"
  for f in esp.bin esp.elf esp.map bootloader/bootloader.bin partition_table/partition-table.bin; do echo x >"$b/$f"; done
  printf '%s\n' '--flash_mode dio --flash_size 4MB' '0x0 bootloader/bootloader.bin' '0x8000 partition_table/partition-table.bin' '0x10000 esp.bin' >"$b/flash_args"
  # pio: two envs
  printf '[platformio]\ndefault_envs = rev3, rev4\n\n[env:rev3]\n[env:rev4]\n' >pio/platformio.ini
  mkdir -p pio/.pio/build/rev3 pio/.pio/build/rev4
  echo x >pio/.pio/build/rev3/firmware.bin
  echo x >pio/.pio/build/rev3/firmware.elf
  echo x >pio/.pio/build/rev4/firmware.hex
  echo x >pio/.pio/build/rev4/firmware.elf
  # arm-gcc
  mkdir -p arm/build
  for f in app.elf app.bin app.map; do echo x >"arm/build/$f"; done
  # circuitpython
  mkdir -p cpy/build cpy/src/lib
  echo x >cpy/build/firmware.uf2
  echo 'print(1)' >cpy/src/code.py
  echo x >cpy/src/lib/mod.py
  # python: the current version only
  mkdir -p svc/py/dist
  for f in py-0.9.0-py3-none-any.whl py-0.9.0.tar.gz py-0.8.0.tar.gz; do echo x >"svc/py/dist/$f"; done
  # flutter: apk, appbundle, web
  b=apps/flut/build
  mkdir -p "$b/app/outputs/flutter-apk" "$b/app/outputs/bundle/release" "$b/app/outputs/mapping/release" "$b/web"
  echo x >"$b/app/outputs/flutter-apk/app-release.apk"
  echo x >"$b/app/outputs/bundle/release/app-release.aab"
  echo x >"$b/app/outputs/mapping/release/mapping.txt"
  echo x >"$b/web/index.html"
  # tauri
  b=apps/tau/src-tauri/target/release/bundle
  mkdir -p "$b/appimage" "$b/deb" "$b/rpm"
  echo x >"$b/appimage/Tau App_0.3.0_amd64.AppImage"
  echo x >"$b/appimage/Tau App_0.3.0_amd64.AppImage.sig"
  echo x >"$b/deb/tau_0.3.0_amd64.deb"
  echo x >"$b/rpm/tau-0.3.0-1.x86_64.rpm"
  # xcode: the dSYMs of the archive
  mkdir -p apps/xc/build/xc.xcarchive/dSYMs/xc.app.dSYM
  echo x >apps/xc/build/xc.xcarchive/dSYMs/xc.app.dSYM/Info.plist
  # android
  o=apps/andr/app/build/outputs
  mkdir -p "$o/apk/release" "$o/bundle/release" "$o/mapping/release"
  echo x >"$o/apk/release/app-release.apk"
  echo x >"$o/bundle/release/app-release.aab"
  echo x >"$o/mapping/release/mapping.txt"
  # hardware
  mkdir -p hw/outputs/gerbers
  echo g >hw/outputs/gerbers/Board-F_Cu.gtl
  for f in Board-bom.csv Board-bom-jlcpcb.csv Board-pos.csv Board-cpl-jlcpcb.csv Board-schematic.pdf Board.step Board.wrl; do echo x >"hw/outputs/$f"; done
  stub_recorder kicad-cli
  printf 'outputs/\nproduction/\nrelease/\n' >hw/.gitignore
  git add -A && git commit -qm outputs

  # part dir version expected-files
  check() {
    run make "$1-release-assets" NOBUILD=1
    if [ "$status" -ne 0 ]; then echo "$1: $output" >&2; return 1; fi
    local got
    got="$(cd "$2/release/$3" && LC_ALL=C ls | tr '\n' ' ')"
    if [ "$got" != "$4" ]; then echo "$1: got [$got] want [$4]" >&2; return 1; fi
    (cd "$2/release/$3" && { sha256sum -c SHA256SUMS 2>/dev/null || shasum -a 256 -c SHA256SUMS; }) >/dev/null
  }
  check fw fw 1.4.2 "SHA256SUMS dfu_application.zip merged.hex zephyr.elf zephyr.map zephyr.signed.bin zephyr.signed.hex "
  check esp esp 1.0.0 "SHA256SUMS bootloader.bin esp.bin esp.elf esp.map factory-esp32c6.bin flash_args partition-table.bin "
  [ "$(cat esp/release/1.0.0/flash_args)" = "--flash_mode dio --flash_size 4MB
0x0 bootloader.bin
0x8000 partition-table.bin
0x10000 esp.bin" ]
  check pio pio 2.0.0 "SHA256SUMS rev3-firmware.bin rev3-firmware.elf rev4-firmware.elf rev4-firmware.hex "
  check arm arm 1.0.0 "SHA256SUMS app.bin app.elf app.hex app.map "
  check cpy cpy 1.0.0 "SHA256SUMS cpy-1.0.0-code.zip feather-firmware.uf2 "
  unzip -l cpy/release/1.0.0/cpy-1.0.0-code.zip | grep -q 'lib/mod.py'
  check py svc/py 0.9.0 "SHA256SUMS py-0.9.0-py3-none-any.whl py-0.9.0.tar.gz "
  # cloud-worker and web-pages release what they deploy: no files (and no build, NOBUILD or not)
  for p in api web; do
    run make "$p-release-assets"
    [ "$status" -eq 0 ]
    [[ $output == *"$p: no release files: its GitHub Release carries the CHANGELOG notes only"* ]]
  done
  [ ! -e cloud/api/release ] && [ ! -e cloud/web/release ]
  check dock svc/dock 1.0.0 "SHA256SUMS image.json "
  [ "$(cat svc/dock/release/1.0.0/image.json)" = '{"registry":"registry.invalid","image":"registry.invalid/demo/dock","tag":"1.0.0","digest":"sha256:abc","platforms":"linux/amd64,linux/arm64"}' ]
  [[ "$(cat "$STUB_LOG/docker.argv")" == *"imagetools inspect registry.invalid/demo/dock:1.0.0"* ]]
  check hw hw 2 "Board-bom-jlcpcb.csv Board-bom.csv Board-cpl-jlcpcb.csv Board-pos.csv Board-schematic.pdf Board.step Board.wrl Board_v2.zip SHA256SUMS "
  # go: the binaries of the current version only
  mkdir -p svc/go/dist
  for f in go-1.2-linux-amd64 go-1.2-darwin-arm64 go-1.1-linux-amd64 go-1.2.sha256; do echo x >"svc/go/dist/$f"; done
  check go svc/go 1.2 "SHA256SUMS go-1.2-darwin-arm64 go-1.2-linux-amd64 "
  # a missing required output fails and names it
  rm fw/build/nrf_x/fw/zephyr/zephyr.elf
  run make fw-release-assets NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"zephyr.elf not found"* ]]
}

@test "release-assets builds first unless NOBUILD=1" {
  allproject
  mkversions
  printf '1.0.0\n' >arm/VERSION
  printf 'build:\n\tmkdir -p build && echo x >build/app.elf && echo x >build/app.bin\n' >arm/Makefile
  stub_cmd arm-none-eabi-gcc 'exit 0'
  stub_cmd arm-none-eabi-objcopy 'echo hex >"${@: -1}"'
  run make arm-release-assets
  [ "$status" -eq 0 ]
  [ -f arm/release/1.0.0/app.bin ]
}

# --- v8: app kinds per PLATFORM, shared Releases -------------------------------------------------------------------

# stub_uname OS ARCH: `uname -s` and `uname -m` answer OS and ARCH for the host checks of the helpers
stub_uname() {
  cat >"$STUBS/uname" <<EOF
#!/bin/bash
case \$1 in -m) echo '$2' ;; *) echo '$1' ;; esac
EOF
  chmod +x "$STUBS/uname"
}

@test "host-platform names this machine: macos, linux-amd64, linux-arm64, windows under Git Bash" {
  stub_uname Linux aarch64
  run bash "$STD_TEMPLATES/bin/release.sh" host-platform
  [ "$output" = linux-arm64 ]
  stub_uname Linux x86_64
  run bash "$STD_TEMPLATES/bin/release.sh" host-platform
  [ "$output" = linux-amd64 ]
  stub_uname MINGW64_NT-10.0 x86_64
  run bash "$STD_TEMPLATES/bin/release.sh" host-platform
  [ "$output" = windows ]
  stub_uname Darwin arm64
  run bash "$STD_TEMPLATES/bin/release.sh" host-platform
  [ "$output" = macos ]
}

@test "sums --platform writes SHA256SUMS-<platform> and leaves the other sums out; a bad platform refuses" {
  allproject
  mkdir -p "$R/d"
  echo a >"$R/d/x.bin"
  echo b >"$R/d/y.deb"
  echo s >"$R/d/SHA256SUMS-macos"
  run bash make/bin/release.sh sums --dir "$R/d" --platform linux-amd64
  [ "$status" -eq 0 ]
  [ "$(LC_ALL=C ls "$R/d" | tr '\n' ' ')" = "SHA256SUMS-linux-amd64 SHA256SUMS-macos x.bin y.deb " ]
  grep -q 'x.bin' "$R/d/SHA256SUMS-linux-amd64"
  ! grep -q 'SHA256SUMS' "$R/d/SHA256SUMS-linux-amd64"
  run bash make/bin/release.sh sums --dir "$R/d" --platform plan9
  [ "$status" -ne 0 ]
  [[ "$output" == *"--platform plan9"* ]]
}

@test "app kinds: release-assets per PLATFORM name each file by platform and write SHA256SUMS-<platform>" {
  allproject
  mkversions
  rustup_stub() { stub_cmd rustup 'exit 0'; }
  rustup_stub
  # flutter, android: the apk linked; the aab and the mapping only in the registry (not linked: release.sh create)
  b=apps/flut/build
  mkdir -p "$b/app/outputs/flutter-apk" "$b/app/outputs/bundle/release" "$b/app/outputs/mapping/release"
  echo x >"$b/app/outputs/flutter-apk/app-release.apk"
  echo x >"$b/app/outputs/bundle/release/app-release.aab"
  echo x >"$b/app/outputs/mapping/release/mapping.txt"
  # android (app-android: one platform whatever PLATFORM says)
  o=apps/andr/app/build/outputs
  mkdir -p "$o/apk/release" "$o/bundle/release" "$o/mapping/release"
  echo x >"$o/apk/release/app-release.apk"
  echo x >"$o/bundle/release/app-release.aab"
  echo x >"$o/mapping/release/mapping.txt"
  # tauri, linux: deb, rpm, AppImage
  b=apps/tau/src-tauri/target/release/bundle
  mkdir -p "$b/appimage" "$b/deb" "$b/rpm"
  echo x >"$b/appimage/Tau App_0.3.0_amd64.AppImage"
  echo x >"$b/deb/tau_0.3.0_amd64.deb"
  echo x >"$b/rpm/tau-0.3.0-1.x86_64.rpm"
  # tauri, windows: msi and nsis for both MSVC targets
  for t in x86_64-pc-windows-msvc aarch64-pc-windows-msvc; do
    mkdir -p "apps/tau/src-tauri/target/$t/release/bundle/msi" "apps/tau/src-tauri/target/$t/release/bundle/nsis"
    echo x >"apps/tau/src-tauri/target/$t/release/bundle/msi/Tau_0.3.0_en-US.msi"
    echo x >"apps/tau/src-tauri/target/$t/release/bundle/nsis/Tau_0.3.0-setup.exe"
  done
  # tauri, macos: the universal dmg and the app (ditto is the Mac's zip tool)
  b=apps/tau/src-tauri/target/universal-apple-darwin/release/bundle
  mkdir -p "$b/dmg" "$b/macos/Tau.app/Contents"
  echo x >"$b/dmg/Tau_0.3.0_universal.dmg"
  echo x >"$b/macos/Tau.app/Contents/Info.plist"
  git add -A && git commit -qm builds

  # part dir version platform expected-files
  checkp() {
    run env PLATFORM="$4" make "$1-release-assets" NOBUILD=1
    if [ "$status" -ne 0 ]; then echo "$1 $4: $output" >&2; return 1; fi
    local got
    got="$(cd "$2/release/$3" && LC_ALL=C ls | tr '\n' ' ')"
    if [ "$got" != "$5" ]; then echo "$1 $4: got [$got] want [$5]" >&2; return 1; fi
    (cd "$2/release/$3" && { sha256sum -c "SHA256SUMS-$4" 2>/dev/null || shasum -a 256 -c "SHA256SUMS-$4"; }) >/dev/null
  }
  checkp flut apps/flut 1.2.3 android "SHA256SUMS-android flut-1.2.3-android-mapping.txt flut-1.2.3-android.apk flut-1.2.3.aab "
  checkp andr apps/andr 2.1.0 android "SHA256SUMS-android andr-2.1.0-android-mapping.txt andr-2.1.0-android.apk andr-2.1.0.aab "
  stub_uname Linux x86_64
  checkp tau apps/tau 0.3.0 linux-amd64 "SHA256SUMS-linux-amd64 tau-0.3.0-linux-amd64.AppImage tau-0.3.0-linux-amd64.deb tau-0.3.0-linux-amd64.rpm "
  stub_uname MINGW64_NT-10.0 x86_64
  checkp tau apps/tau 0.3.0 windows "SHA256SUMS-windows tau-0.3.0-windows-arm64.exe tau-0.3.0-windows-x64.exe tau-0.3.0-windows-x64.msi "
  # a platform on the wrong host is refused before anything is collected
  stub_uname Linux x86_64
  run env PLATFORM=macos make tau-release-assets NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"PLATFORM=macos is built on a Mac"* ]]
  # a platform the kind does not build
  run env PLATFORM=plan9 make tau-release-assets NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not one of"* ]]
  # the macOS universal build needs a Mac and ditto
  if command -v ditto >/dev/null && [ "$(/usr/bin/uname -s)" = Darwin ]; then
    stub_uname Darwin arm64
    checkp tau apps/tau 0.3.0 macos "SHA256SUMS-macos tau-0.3.0-macos-universal.app.zip tau-0.3.0-macos-universal.dmg "
  fi
}

@test "app kinds: the Xcode archive's dSYMs per platform, and the iOS build number as a note" {
  [ -x /usr/libexec/PlistBuddy ] || skip "PlistBuddy: a Mac only"
  allproject
  mkversions
  stub_xcrun
  printf '3.1.0\n' >apps/xc/.marketing
  mkdir -p apps/xc/build/xc.xcarchive/dSYMs/xc.app.dSYM
  echo x >apps/xc/build/xc.xcarchive/dSYMs/xc.app.dSYM/Info.plist
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict>' \
    '<key>ApplicationProperties</key><dict><key>CFBundleVersion</key><string>42</string></dict>' '</dict></plist>' \
    >apps/xc/build/xc.xcarchive/Info.plist
  git add -A && git commit -qm archive
  run env PLATFORM=ios make xc-release-assets NOBUILD=1
  [ "$status" -eq 0 ]
  [ "$(LC_ALL=C ls apps/xc/release/3.1.0 | tr '\n' ' ')" = "SHA256SUMS-ios xc-3.1.0-ios-dSYMs.zip " ]
  [ "$(cat apps/xc/release/3.1.0.build-note)" = "ios: TestFlight build 42 (version 3.1.0)" ]
}

# --- race ---------------------------------------------------------------------------------------

@test "create survives a race: the create is refused, the Release now exists and is updated; unlinked files are not sent" {
  allproject
  fw_release
  mkassets "$R/assets"
  echo x >"$R/assets/fw.aab"
  echo x >"$R/assets/fw-mapping.txt"
  touch "$STUB_LOG/create.fail"
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.2.0 GH_TOKEN=t \
    run bash make/bin/release.sh create --part fw --version 1.2.0 --dir "$R/assets"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated: 3 assets"* ]]
  [ "$(grep -c '^create$' "$STUB_LOG/gh.argv")" -eq 1 ]
  a="$(argv gh)"
  [[ "$a" == *$'release\nedit\n'* ]]
  [[ "$a" == *$'release\nupload\nfw-v1.2.0\n--clobber\n'* ]]
  [[ "$a" != *"fw.aab"* ]]
  [[ "$a" != *"fw-mapping.txt"* ]]
}


@test "apple prefix: with production secrets and the App Store key, the signing wrapper and the key export are both there, spaced" {
  allproject
  mkdir -p "$SECRETS_DIR/demo/keys"
  : >"$SECRETS_DIR/demo/production.env.sops"
  : >"$SECRETS_DIR/demo/keys/appstore-api-key.sops"
  run env PLATFORM=macos make -n tau-release-assets
  [ "$status" -eq 0 ]
  [[ "$output" == *"secrets.sh exec --env production -- bash"* ]]
  [[ "$output" == *"with-file appstore-api-key -- sh -c 'export APPLE_API_KEY_PATH="$1"; shift; exec "$@"' sh {}"* ]]
  [[ "$output" != *"--bash"* ]]
  [[ "$output" != *"-- sh -c 'APPLE_API_KEY_PATH"* ]]
}

@test "apple prefix: without secrets the build runs bare and says it is unsigned" {
  allproject
  run env PLATFORM=macos make -n tau-release-assets
  [ "$status" -eq 0 ]
  [[ "$output" != *"with-file appstore-api-key"* ]]
  [[ "$output" != *"exec --env production"* ]]
}

@test "make latest: each part's newest published Release, not the repository's one Latest; PART= for one" {
  allproject
  mkdir -p "$R/fakegh"
  # a gh that answers release list (already in the --jq row format) and release view (the url)
  cat >"$R/fakegh/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
  "release list") printf 'app-v1.0.0\tapp 1.0.0\t2026-11-12T08:42:38Z\nhw-v4.0\thardware 4.0\t2026-11-12T08:22:15Z\nhw-v3.0\thardware 3.0\t2026-11-12T08:17:39Z\nnotes\tnot a part\t2026-11-12T09:00:00Z\n' ;;
  "release view") echo "https://example.invalid/releases/tag/$3" ;;
esac
GH
  chmod +x "$R/fakegh/gh"
  PATH="$R/fakegh:$PATH" run make latest
  [ "$status" -eq 0 ]
  [[ $output == *"hardware 4.0"*"hw-v4.0"* ]]
  [[ $output != *"hardware 3.0"* ]]
  [[ $output == *"app 1.0.0"* ]]
  [[ $output != *"not a part"* ]]
  PATH="$R/fakegh:$PATH" run make latest PART=hw
  [ "$status" -eq 0 ]
  [[ $output == *"hw-v4.0"* ]]
  [[ $output != *"app"* ]]
  PATH="$R/fakegh:$PATH" run make latest PART=fw
  [[ $output == *"no published Release of fw yet"* ]]
}

# --- the latest Release (v20) -------------------------------------------------------------------
# A gh that keeps Releases in files under $GHS: $GHS/<tag>/{url,date,draft,pre,body,files/*} (a Release exists when its
# folder does). It answers release view/create/edit/download/upload/delete-asset and logs every call, one line each, to
# $GHS/calls.log. Files made by mkrel hold their own name as content.

stateful_gh() {
  export GHS="$R/ghstate"
  mkdir -p "$GHS"
  cat >"$STUBS/gh" <<'GH'
#!/bin/bash
g="$GHS"
printf '%s\n' "$*" >>"$g/calls.log"
[ "$1" = release ] || exit 0
sub=$2 tag=$3
shift 3
case $sub in
  view)
    [ -d "$g/$tag" ] || exit 1
    case " $* " in
      *isDraft*) [ -z "${GHS_FAIL_VIEW:-}" ] || exit 1
        printf '%s %s %s %s %s\n' "$(cat "$g/$tag/draft")" "$(cat "$g/$tag/pre")" "$(cat "$g/$tag/url")" "$(cat "$g/$tag/date")" \
          "$(find "$g/$tag/files" -type f | wc -l | tr -d ' ')" ;;
      *) cat "$g/$tag/body" 2>/dev/null ;;
    esac ;;
  download)
    [ -d "$g/$tag" ] || exit 1
    while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir=$2; shift; done
    # like gh: a Release with no files is an error ("no assets to download")
    cp "$g/$tag/files"/* "$dir/" 2>/dev/null || { echo 'no assets to download' >&2; exit 1; }
    exit 0 ;;
  create)
    [ ! -d "$g/$tag" ] || exit 1
    mkdir -p "$g/$tag/files"
    echo false >"$g/$tag/draft"; echo false >"$g/$tag/pre"
    echo "https://example.invalid/releases/tag/$tag" >"$g/$tag/url"; echo 2026-11-12T08:00:00Z >"$g/$tag/date"
    : >"$g/$tag/body"
    while [ $# -gt 0 ]; do
      case $1 in --notes-file) cp "$2" "$g/$tag/body" ;; --notes) printf '%s\n' "$2" >"$g/$tag/body" ;; esac
      shift
    done ;;
  edit)
    [ -d "$g/$tag" ] || exit 1
    while [ $# -gt 0 ]; do [ "$1" = --notes-file ] && cp "$2" "$g/$tag/body"; shift; done ;;
  upload)
    [ -d "$g/$tag" ] || exit 1
    for f in "$@"; do [ -f "$f" ] && cp "$f" "$g/$tag/files/"; done ;;
  delete-asset)
    name=$1
    rm -f "${g:?}/${tag:?}/files/${name:?}" ;;
esac
exit 0
GH
  chmod +x "$STUBS/gh"
}

# mkrel TAG FILE...: a published Release with those files; DATE, DRAFT=true and PRE=true set the rest
mkrel() {
  local tag=$1 f
  shift
  mkdir -p "$GHS/$tag/files"
  echo "${DRAFT:-false}" >"$GHS/$tag/draft"
  echo "${PRE:-false}" >"$GHS/$tag/pre"
  echo "https://example.invalid/o/r/releases/tag/$tag" >"$GHS/$tag/url"
  echo "${DATE:-2026-11-12}T08:00:00Z" >"$GHS/$tag/date"
  : >"$GHS/$tag/body"
  for f in "$@"; do echo "$f" >"$GHS/$tag/files/$f"; done
}

# lsync PART KIND VERSION: release.sh latest-sync
lsync() {
  bash make/bin/release.sh latest-sync --part "$1" --kind "$2" --version "$3" --project demo
}

# lfiles: the files of the Release latest, sorted, on one line
lfiles() { (cd "$GHS/latest/files" && LC_ALL=C /bin/ls | tr '\n' ' '); }

@test "latest-sync: the first sync makes latest, renames files without the version, writes <part>-SHA256SUMS, and takes the Latest badge" {
  allproject
  stateful_gh
  mkrel app-v1.0.0 app-1.0.0-linux-amd64.deb app_v1.0.0_win.zip app.1.0.0.dmg app-v1.0.0-notes.txt SHA256SUMS SHA256SUMS-ios
  run lsync app go 1.0.0
  echo "$output"
  [ "$status" -eq 0 ]
  [ -d "$GHS/latest" ]
  # app.1.0.0.dmg -> app.dmg -> app-app.dmg (not starting with "app-": prefixed); app_v1.0.0_win.zip -> app_win.zip -> app-app_win.zip
  [ "$(lfiles)" = "app-SHA256SUMS app-app.dmg app-app_win.zip app-linux-amd64.deb app-notes.txt " ]
  # the part's own sums are left out, and the new sums verify the files under their new names
  [ ! -e "$GHS/latest/files/SHA256SUMS" ]
  [ ! -e "$GHS/latest/files/SHA256SUMS-ios" ]
  (cd "$GHS/latest/files" && shasum -a 256 -c app-SHA256SUMS)
  [ "$(wc -l <"$GHS/latest/files/app-SHA256SUMS" | tr -d ' ')" -eq 4 ]
  # created with the Latest badge, and the body is a marker plus a table
  grep -E '^release create latest .*--latest' "$GHS/calls.log"
  grep -E '^release edit latest .*--latest' "$GHS/calls.log"
  grep -Fq '<!-- latest app 1.0.0 2026-11-12 app-v1.0.0 https://example.invalid/o/r/releases/tag/app-v1.0.0 ' "$GHS/latest/body"
  grep -Fq 'app-linux-amd64.deb' "$GHS/latest/body"
  grep -Fq '| app | 1.0.0 | 2026-11-12 |' "$GHS/latest/body"
  grep -Fq 'releases/download/latest/' "$GHS/latest/body"
}

@test "latest-sync: a file that already starts with the part is not prefixed again; other names are" {
  allproject
  stateful_gh
  mkrel fw-v2.1.0 fw-2.1.0-nrf.bin rev4-firmware.bin
  run lsync fw zephyr 2.1.0
  [ "$status" -eq 0 ]
  [ "$(lfiles)" = "fw-SHA256SUMS fw-nrf.bin fw-rev4-firmware.bin " ]
}

@test "latest-sync: rev4-firmware.bin of the part firmware becomes firmware-rev4-firmware.bin" {
  allproject
  stateful_gh
  mkrel firmware-v1.0.0 rev4-firmware.bin
  run lsync firmware zephyr 1.0.0
  [ "$status" -eq 0 ]
  [ "$(lfiles)" = "firmware-SHA256SUMS firmware-rev4-firmware.bin " ]
}

@test "latest-sync: a hardware part is grouped by major version: CommandDeck_v4.0.0.zip becomes hardware-v4-CommandDeck.zip" {
  allproject
  stateful_gh
  mkrel hardware-v4.0.0 CommandDeck_v4.0.0.zip SHA256SUMS
  run lsync hardware hardware 4.0.0
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(lfiles)" = "hardware-v4-CommandDeck.zip hardware-v4-SHA256SUMS " ]
  (cd "$GHS/latest/files" && shasum -a 256 -c hardware-v4-SHA256SUMS)
  grep -Fq '<!-- latest hardware-v4 4.0.0 ' "$GHS/latest/body"
}

@test "latest-sync: a second part keeps the first part's files and marker; the table has a row for each" {
  allproject
  stateful_gh
  mkrel app-v1.0.0 app-1.0.0-linux-amd64.deb
  mkrel fw-v2.0.0 fw-2.0.0-nrf.bin
  run lsync app go 1.0.0
  [ "$status" -eq 0 ]
  run lsync fw zephyr 2.0.0
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^release create latest' "$GHS/calls.log")" -eq 1 ]
  [ -e "$GHS/latest/files/app-linux-amd64.deb" ]
  [ -e "$GHS/latest/files/app-SHA256SUMS" ]
  [ -e "$GHS/latest/files/fw-SHA256SUMS" ]
  grep -Fq '<!-- latest app 1.0.0 ' "$GHS/latest/body"
  grep -Fq '<!-- latest fw 2.0.0 ' "$GHS/latest/body"
  grep -Fq '| app | 1.0.0 |' "$GHS/latest/body"
  grep -Fq '| fw | 2.0.0 |' "$GHS/latest/body"
  (cd "$GHS/latest/files" && shasum -a 256 -c app-SHA256SUMS)
}

@test "latest-sync: hardware 3.0.0 and 4.0.0 both stay, each with its own sums" {
  allproject
  stateful_gh
  mkrel hardware-v3.0.0 CommandDeck_v3.0.0.zip
  mkrel hardware-v4.0.0 CommandDeck_v4.0.0.zip
  run lsync hardware hardware 3.0.0
  [ "$status" -eq 0 ]
  run lsync hardware hardware 4.0.0
  [ "$status" -eq 0 ]
  [ "$(lfiles)" = "hardware-v3-CommandDeck.zip hardware-v3-SHA256SUMS hardware-v4-CommandDeck.zip hardware-v4-SHA256SUMS " ]
  grep -Fq '<!-- latest hardware-v3 3.0.0 ' "$GHS/latest/body"
  grep -Fq '<!-- latest hardware-v4 4.0.0 ' "$GHS/latest/body"
  (cd "$GHS/latest/files" && shasum -a 256 -c hardware-v3-SHA256SUMS && shasum -a 256 -c hardware-v4-SHA256SUMS)
}

@test "latest-sync: a newer version replaces the group's files and deletes the names it no longer has" {
  allproject
  stateful_gh
  mkrel app-v1.0.0 app-1.0.0-linux-amd64.deb app-1.0.0-old.txt
  mkrel app-v1.1.0 app-1.1.0-linux-amd64.deb app-1.1.0-extra.zip
  mkrel fw-v2.0.0 fw-2.0.0-nrf.bin
  run lsync app go 1.0.0
  [ "$status" -eq 0 ]
  run lsync fw zephyr 2.0.0
  [ "$status" -eq 0 ]
  echo changed >"$GHS/app-v1.1.0/files/app-1.1.0-linux-amd64.deb"
  run lsync app go 1.1.0
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$GHS/latest/files/app-old.txt" ]
  grep -Fq 'release delete-asset latest app-old.txt --yes' "$GHS/calls.log"
  [ -e "$GHS/latest/files/app-extra.zip" ]
  [ "$(cat "$GHS/latest/files/app-linux-amd64.deb")" = changed ]
  # the other part is untouched, and a name both versions have is not deleted
  [ -e "$GHS/latest/files/fw-SHA256SUMS" ]
  ! grep -Fq 'delete-asset latest app-linux-amd64.deb' "$GHS/calls.log"
  ! grep -Fq 'delete-asset latest app-SHA256SUMS' "$GHS/calls.log"
  grep -Fq '<!-- latest app 1.1.0 ' "$GHS/latest/body"
  ! grep -Fq '<!-- latest app 1.0.0 ' "$GHS/latest/body"
  grep -Fq '<!-- latest fw 2.0.0 ' "$GHS/latest/body"
  (cd "$GHS/latest/files" && shasum -a 256 -c app-SHA256SUMS)
}

@test "latest-sync: an older version is a no-op, and 1.9.0 is older than 1.10.0 (numeric)" {
  allproject
  stateful_gh
  mkrel app-v1.9.0 app-1.9.0-a.bin
  mkrel app-v1.10.0 app-1.10.0-a.bin
  mkrel app-v1.2.0 app-1.2.0-a.bin
  run lsync app go 1.10.0
  [ "$status" -eq 0 ]
  : >"$GHS/calls.log"
  run lsync app go 1.9.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"newer than 1.9.0: unchanged"* ]]
  run lsync app go 1.2.0
  [ "$status" -eq 0 ]
  ! grep -Eq 'release (upload|edit|delete-asset|download)' "$GHS/calls.log"
  grep -Fq '<!-- latest app 1.10.0 ' "$GHS/latest/body"
}

@test "latest-sync: the same version again (a re-run) is accepted and leaves one marker" {
  allproject
  stateful_gh
  mkrel app-v1.0.0 app-1.0.0-a.bin
  run lsync app go 1.0.0
  [ "$status" -eq 0 ]
  run lsync app go 1.0.0
  [ "$status" -eq 0 ]
  [ "$(lfiles)" = "app-SHA256SUMS app-a.bin " ]
  [ "$(grep -c '^<!-- latest app' "$GHS/latest/body")" -eq 1 ]
}

@test "latest-sync: a pre-release version, a pre-release Release and a draft Release leave latest alone (exit 0)" {
  allproject
  stateful_gh
  mkrel app-v1.0.0 app-1.0.0-a.bin
  run lsync app go 1.0.0
  [ "$status" -eq 0 ]
  cp -R "$GHS/latest" "$R/before"
  mkrel app-v2.0.0-rc.1 app-2.0.0-rc.1-a.bin
  run lsync app go 2.0.0-rc.1
  [ "$status" -eq 0 ]
  PRE=true mkrel app-v2.0.0 app-2.0.0-a.bin
  run lsync app go 2.0.0
  [ "$status" -eq 0 ]
  DRAFT=true mkrel app-v2.1.0 app-2.1.0-a.bin
  run lsync app go 2.1.0
  [ "$status" -eq 0 ]
  diff -r "$R/before" "$GHS/latest"
}

@test "latest-sync: a pre-release or a draft does not even create latest" {
  allproject
  stateful_gh
  PRE=true mkrel app-v1.0.0 app-1.0.0-a.bin
  run lsync app go 1.0.0
  [ "$status" -eq 0 ]
  DRAFT=true mkrel fw-v1.0.0 fw-1.0.0-a.bin
  run lsync fw zephyr 1.0.0
  [ "$status" -eq 0 ]
  [ ! -d "$GHS/latest" ]
}

@test "latest-sync: a Release with no files (or only SHA256SUMS) changes nothing, exit 0" {
  allproject
  stateful_gh
  mkrel app-v1.0.0
  run lsync app go 1.0.0
  [ "$status" -eq 0 ]
  [ ! -d "$GHS/latest" ]
  # a notes-only Release (cloud-worker, web-pages) is not even downloaded: gh refuses a Release with no files
  sa_calls=$(cat "$GHS/calls.log")
  [[ $sa_calls != *"release download app-v1.0.0"* ]]
  mkrel app-v1.1.0 SHA256SUMS
  run lsync app go 1.1.0
  [ "$status" -eq 0 ]
  [ ! -d "$GHS/latest" ]
  # with latest existing: unchanged
  mkrel fw-v1.0.0 fw-1.0.0-a.bin
  run lsync fw zephyr 1.0.0
  [ "$status" -eq 0 ]
  mkrel app-v1.2.0
  cp -R "$GHS/latest" "$R/before"
  run lsync app go 1.2.0
  [ "$status" -eq 0 ]
  diff -r "$R/before" "$GHS/latest"
}

@test "latest-sync: no Release of the version is an error that names the make command" {
  allproject
  stateful_gh
  run lsync app go 1.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Release app-v1.0.0"* ]]
}

@test "latest-sync: the title uses the project name and the body gives the download link base" {
  allproject
  stateful_gh
  mkrel app-v1.0.0 app-1.0.0-a.bin
  run lsync app go 1.0.0
  [ "$status" -eq 0 ]
  grep -Fq 'release create latest --title demo latest' "$GHS/calls.log"
  grep -Fq 'https://example.invalid/o/r/releases/download/latest/<file>' "$GHS/latest/body"
}

@test "create: passes --latest=false to gh release create" {
  allproject
  fw_release
  mkassets "$R/assets"
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.2.0 GH_TOKEN=t \
    run bash make/bin/release.sh create --part fw --version 1.2.0 --dir "$R/assets"
  [ "$status" -eq 0 ]
  [[ "$(argv gh)" == *$'--verify-tag\n--latest=false\n'* ]]
}

@test "create outside CI with --kind runs latest-sync; a failure there only warns and create still succeeds" {
  allproject
  fw_release
  stateful_gh
  mkassets "$R/assets"
  GHS_FAIL_VIEW=1 run bash make/bin/release.sh create --part fw --kind zephyr --project demo --version 1.2.0 --dir "$R/assets"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -d "$GHS/fw-v1.2.0" ]
  grep -Fq 'isDraft' "$GHS/calls.log"
  [[ "$output" == *"fw: the latest Release was not updated: make fw-release-latest"* ]]
  [ ! -d "$GHS/latest" ]
}

@test "create outside CI with --kind syncs the part into latest end to end" {
  allproject
  fw_release
  stateful_gh
  mkassets "$R/assets"
  run bash make/bin/release.sh create --part fw --kind zephyr --project demo --version 1.2.0 --dir "$R/assets"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -d "$GHS/fw-v1.2.0" ]
  grep -E '^release create fw-v1.2.0 .*--latest=false' "$GHS/calls.log"
  [ -d "$GHS/latest" ]
  [ -e "$GHS/latest/files/fw-SHA256SUMS" ]
  [ -e "$GHS/latest/files/fw-fw.bin" ]
  grep -Fq '<!-- latest fw 1.2.0 ' "$GHS/latest/body"
}

@test "create in CI (GITHUB_ACTIONS=true) does not run latest-sync, even with --kind" {
  allproject
  fw_release
  stateful_gh
  mkassets "$R/assets"
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.2.0 GH_TOKEN=t \
    run bash make/bin/release.sh create --part fw --kind zephyr --project demo --version 1.2.0 --dir "$R/assets"
  [ "$status" -eq 0 ]
  [ -d "$GHS/fw-v1.2.0" ]
  [ ! -d "$GHS/latest" ]
  ! grep -Fq 'release create latest' "$GHS/calls.log"
}

@test "create outside CI without --kind does not run latest-sync" {
  allproject
  fw_release
  stateful_gh
  mkassets "$R/assets"
  run bash make/bin/release.sh create --part fw --version 1.2.0 --dir "$R/assets"
  [ "$status" -eq 0 ]
  [ ! -d "$GHS/latest" ]
}

@test "make <part>-release-latest: VERSION= picks the Release, without it the part's current version" {
  allproject
  mkversions
  stateful_gh
  printf '1.2.0\n' >svc/go/VERSION
  mkrel go-v1.2.0 go-1.2.0-a.bin
  mkrel go-v1.5.0 go-1.5.0-a.bin
  # no VERSION: the version file of go says 1.2
  run make go-release-latest
  echo "$output"
  [ "$status" -eq 0 ]
  grep -Fq 'release view go-v1.2.0' "$GHS/calls.log"
  grep -Fq '<!-- latest go 1.2.0 ' "$GHS/latest/body"
  # VERSION= on the command line
  run make go-release-latest VERSION=1.5.0
  echo "$output"
  [ "$status" -eq 0 ]
  grep -Fq 'release view go-v1.5.0' "$GHS/calls.log"
  grep -Fq '<!-- latest go 1.5.0 ' "$GHS/latest/body"
  [ -e "$GHS/latest/files/go-SHA256SUMS" ]
  grep -Fq 'release create latest --title demo latest' "$GHS/calls.log"
}

@test "make <part>-release-latest: is in make help, and a hardware part uses its major version group" {
  allproject
  mkversions
  stateful_gh
  run make help
  [[ "$output" == *"go-release-latest"* ]]
  mkrel hw-v3.0.0 Board_v3.0.0.zip
  run make hw-release-latest VERSION=3.0.0
  echo "$output"
  [ "$status" -eq 0 ]
  [ -e "$GHS/latest/files/hw-v3-Board.zip" ]
}

@test "github-release of a cloud-worker and a web-pages part: a Release with the notes only, nothing built or uploaded" {
  allproject
  mkversions
  for p in api web; do
    run make "$p-bump" VERSION=1.1.0
    [ "$status" -eq 0 ]
    rm -f "$STUB_LOG/gh.argv" "$STUB_LOG/release.exists" "$STUB_LOG/notes.txt"
    GITHUB_ACTIONS=true GITHUB_REPOSITORY=owner/demo GITHUB_REF_TYPE=tag GITHUB_REF_NAME="$p-v1.1.0" GH_TOKEN=t \
      run make "$p-github-release"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ $output == *"release $p-v1.1.0 updated: the notes only, no files"* ]]
    a="$(argv gh)"
    [[ "$a" == *$'release\ncreate\n'"$p-v1.1.0"$'\n--title\n'"$p 1.1.0"* ]]
    [[ "$a" != *$'release\nupload'* ]]
    grep -q 'a feature' "$STUB_LOG/notes.txt"
    [ ! -e "cloud/$p/release" ]
  done
  run env FORCE=1 make -n api-github-release
  [[ "$output" == *"--notes-only"* && "$output" != *"--dir"* && "$output" != *"api-release-assets"* ]]
  # a kind with files keeps --dir
  run env FORCE=1 make -n go-github-release NOBUILD=1
  [[ "$output" == *"--dir \"svc/go/release/"* && "$output" != *"--notes-only"* ]]
}

@test "create --notes-only: no --dir needed, nothing uploaded" {
  allproject
  fw_release
  GITHUB_ACTIONS=true GITHUB_REPOSITORY=owner/demo GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.2.0 GH_TOKEN=t \
    run bash make/bin/release.sh create --part fw --version 1.2.0 --notes-only
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"the notes only, no files"* ]]
  [[ "$(argv gh)" != *$'release\nupload'* ]]
  # without --notes-only, an empty or missing --dir is still an error
  mkdir -p "$R/empty"
  GITHUB_ACTIONS=true GITHUB_REPOSITORY=owner/demo GITHUB_REF_TYPE=tag GITHUB_REF_NAME=fw-v1.2.0 GH_TOKEN=t \
    run bash make/bin/release.sh create --part fw --version 1.2.0 --dir "$R/empty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no release assets"* ]]
}

@test "make <part>-github-release passes --kind and --project to create" {
  allproject
  mkversions
  run env FORCE=1 make -n go-github-release NOBUILD=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"create --part go --kind go --project \"demo\" --version"* ]]
}
