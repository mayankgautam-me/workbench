#!/usr/bin/env bats
# make teardown and make prune (templates/make/bin/toolchain.sh): the usage record, the installed ledger, and what is
# listed and removed. mise, rustup, rustc, pnpm, du and brew are stubs; HOME, STD_TOOLCHAINS and the state dir are
# folders in the test's temp dir. Nothing here touches the real machine.

load helpers

setup() {
  std_setup_env
  export PROJECT=demo
  export STD_TOOLCHAINS="$HOME/.toolchains"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  STATE="$XDG_STATE_HOME/project-standard"
  mkdir -p "$STD_TOOLCHAINS"
  TCR="$(cd "$STD_TOOLCHAINS" && pwd -P)"
  P="$BATS_TEST_TMPDIR/proj"
  mkproject "$P" 'PROJECT := demo
PARTS := \
  fw:zephyr \
  svc:go'
  # a zephyr-like part: setup puts SDK folders into STD_TOOLCHAINS the way zephyr_setup does; distclean removes build/
  mkkind "$P" zephyr 'define kind_zephyr
$(call std_verb,$(1),setup,firmware,Install the SDK)
$(call std_verb,$(1),distclean,firmware,Remove build)
$(call std_verb,$(1),clean,dev,Remove build)
$(1)-setup:
	@$(STD_TC) sdk-begin "$(STD_TOOLCHAINS)/ncs-v1" "$(STD_TOOLCHAINS)/shared-2"; mkdir -p "$(STD_TOOLCHAINS)/ncs-v1" "$(STD_TOOLCHAINS)/shared-2"; $(STD_TC) sdk-use "$(STD_TOOLCHAINS)/ncs-v1" "$(STD_TOOLCHAINS)/shared-2"
$(1)-distclean:
	@rm -rf "$(2)/build"
$(1)-clean:
	@rm -rf "$(2)/build"
endef'
  # a go-like part: clean only, no distclean
  mkkind "$P" go 'define kind_go
$(call std_verb,$(1),clean,dev,Remove bin)
$(1)-clean:
	@rm -rf "$(2)/bin" "$(2)/dist"
endef'
  printf '[tools]\nnode = "22"\npython = "3.12"\n' >"$P/mise.toml"
  printf 'brew "git"\nbrew "mise", args: ["x"]\ncask "docker"\n' >"$P/Brewfile"
  mkdir -p "$P/fw/build" "$P/svc/bin" "$P/fw/release/1.0.0"
  echo x >"$P/fw/build/out.elf"
  echo x >"$P/fw/release/1.0.0/SHA256SUMS"
  echo x >"$P/svc/bin/app"
  PHYS_P="$(cd "$P" && pwd -P)"
  export STUB_PROJ_TOML="$PHYS_P/mise.toml"
  stub_recorder brew
  stub_stubs
  cd "$P"
}

# The stubs. mise keeps its installed versions in $STUB_LOG/mise.installed (tool@version lines), what its install adds in
# mise.toinstall, what this project's mise.toml asks for in mise.current and what the global config asks for in mise.global
# (ls --current shows both, each with its source file). mise.fail makes install fail. rustup keeps `toolchain target`
# lines in rustup.installed; its active toolchain is stable-aarch64-apple-darwin. du says 2048 KB for whatever exists.
stub_stubs() {
  : >"$STUB_LOG/mise.installed"
  : >"$STUB_LOG/mise.toinstall"
  : >"$STUB_LOG/mise.current"
  : >"$STUB_LOG/mise.global"
  : >"$STUB_LOG/rustup.installed"
  cat >"$STUBS/mise" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG/mise.calls"
json() { jq -Rn '[inputs | select(length > 0) | split("\t") | (.[0] | split("@")) as $a | {t: $a[0], v: $a[1], s: .[1]}] | group_by(.t) | map({key: .[0].t, value: map({version: .v, installed: true, source: {path: .s}})}) | from_entries'; }
src() { sed "s|\$|	$2|" "$1"; }
G="$HOME/.config/mise/config.toml"
case "$1" in
  ls)
    case "$2" in
      --installed) src "$STUB_LOG/mise.installed" - | json ;;
      --global) if [ "$(pwd -P)" = / ]; then src "$STUB_LOG/mise.global" "$G" | json; else echo "{}"; fi ;;  # like mise: no global tools inside a project
      --current) { src "$STUB_LOG/mise.current" "$STUB_PROJ_TOML"; src "$STUB_LOG/mise.global" "$G"; } | json ;;
    esac ;;
  install)
    [ ! -f "$STUB_LOG/mise.fail" ] || exit 1
    cat "$STUB_LOG/mise.toinstall" >>"$STUB_LOG/mise.installed"; sort -u "$STUB_LOG/mise.installed" -o "$STUB_LOG/mise.installed" ;;
  where) if grep -Fxq "$2" "$STUB_LOG/mise.installed"; then mkdir -p "$HOME/mise/$2"; echo "$HOME/mise/$2"; else exit 1; fi ;;
  uninstall) grep -Fxv "$2" "$STUB_LOG/mise.installed" >"$STUB_LOG/mise.tmp" || true; mv "$STUB_LOG/mise.tmp" "$STUB_LOG/mise.installed" ;;
esac
EOF
  cat >"$STUBS/rustup" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG/rustup.calls"
tc=''; args=()
while [ $# -gt 0 ]; do
  if [ "$1" = --toolchain ]; then tc="$2"; shift 2; else args+=("$1"); shift; fi
done
case "${args[0]} ${args[1]}" in
  "show active-toolchain") echo "stable-aarch64-apple-darwin (default)" ;;
  "target list") awk -v t="$tc" '$1 == t { print $2 }' "$STUB_LOG/rustup.installed" ;;
  "target add") for x in "${args[@]:2}"; do echo "$tc $x" >>"$STUB_LOG/rustup.installed"; done ;;
  "target remove") grep -Fxv "$tc ${args[2]}" "$STUB_LOG/rustup.installed" >"$STUB_LOG/rustup.tmp" || true; mv "$STUB_LOG/rustup.tmp" "$STUB_LOG/rustup.installed" ;;
esac
EOF
  stub_cmd rustc 'echo "host: aarch64-apple-darwin"'
  cat >"$STUBS/du" <<'EOF'
#!/bin/bash
for last in "$@"; do :; done
printf '2048\t%s\n' "$last"
EOF
  cat >"$STUBS/pnpm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG/pnpm.calls"
case "$1 $2" in
  "store path") mkdir -p "$HOME/pnpm-store"; echo "$HOME/pnpm-store" ;;
esac
EOF
  chmod +x "$STUBS"/mise "$STUBS"/rustup "$STUBS"/du "$STUBS"/pnpm
}

TC_SH() { bash "$P/make/bin/toolchain.sh" "$@"; }

# another standard project (a finished setup) whose record uses the given sdk folders (names under STD_TOOLCHAINS)
other_project() {
  local dir="$BATS_TEST_TMPDIR/other" n
  mkdir -p "$dir"
  (cd "$dir" && PROJECT=other STD_PROJECT_DIR="$dir" TC_SH record-begin)
  for n in "$@"; do (cd "$dir" && PROJECT=other STD_PROJECT_DIR="$dir" TC_SH sdk-use "$STD_TOOLCHAINS/$n"); done
  (cd "$dir" && PROJECT=other STD_PROJECT_DIR="$dir" TC_SH record-commit)
}

# a record written by hand: NAME PATH, then the lines on stdin
hand_record() {
  mkdir -p "$STATE/uses"
  { printf 'path %s\nproject %s\n' "$2" "$1"; cat; } >"$STATE/uses/$1-000000000000"
}

record_of_demo() { /bin/ls "$STATE"/uses/demo-???????????? ; }

@test "setup writes the usage record and the ledger; a global tool is not the project's and not the standard's" {
  printf 'python@3.12.4\n' >"$STUB_LOG/mise.installed"
  printf 'node@22.1.0\npython@3.12.4\ngtool@9.0.0\n' >"$STUB_LOG/mise.toinstall"
  printf 'node@22.1.0\npython@3.12.4\n' >"$STUB_LOG/mise.current"
  printf 'gtool@9.0.0\n' >"$STUB_LOG/mise.global"
  run make setup
  [ "$status" -eq 0 ]
  rec="$(record_of_demo)"
  grep -Fxq "path $(pwd -P)" "$rec"
  grep -Fxq 'project demo' "$rec"
  grep -Fxq 'mise node@22.1.0' "$rec"
  grep -Fxq 'mise python@3.12.4' "$rec"
  grep -Fxq "sdk $TCR/ncs-v1" "$rec"
  grep -Fxq "sdk $TCR/shared-2" "$rec"
  ! grep -q gtool "$rec"
  [ ! -e "$rec.next" ]
  # the ledger: what the standard installed for this project, not python (there before) and not the global tool
  grep -Fxq 'mise node@22.1.0' "$STATE/installed"
  grep -Fxq "sdk $TCR/ncs-v1" "$STATE/installed"
  ! grep -q python "$STATE/installed"
  ! grep -q gtool "$STATE/installed"
}

@test "setup again keeps the ledger and does not claim an SDK that was already there" {
  run make setup
  [ "$status" -eq 0 ]
  rm -f "$STATE/installed"
  run make setup
  [ "$status" -eq 0 ]
  [ ! -e "$STATE/installed" ] || ! grep -q 'ncs-v1' "$STATE/installed"
}

@test "setup of one part keeps the record of the others; a finished full setup drops what the project no longer uses" {
  run make setup
  [ "$status" -eq 0 ]
  rec="$(record_of_demo)"
  printf 'mise gone@1.0.0\n' >>"$rec"
  run make fw-setup
  [ "$status" -eq 0 ]
  grep -Fxq 'mise gone@1.0.0' "$rec"
  run make setup PART=fw
  [ "$status" -eq 0 ]
  grep -Fxq 'mise gone@1.0.0' "$rec"
  run make setup
  [ "$status" -eq 0 ]
  ! grep -Fxq 'mise gone@1.0.0' "$rec"
  grep -Fxq "sdk $TCR/ncs-v1" "$rec"
}

@test "a failed setup keeps protecting what the project had: its record is never emptied" {
  printf 'node@22.1.0\n' >"$STUB_LOG/mise.toinstall"
  printf 'node@22.1.0\n' >"$STUB_LOG/mise.current"
  make setup
  mkdir -p "$STD_TOOLCHAINS/old-9"
  printf 'sdk %s/old-9\n' "$TCR" >>"$STATE/installed"
  rec="$(record_of_demo)"
  printf 'sdk %s/old-9\n' "$TCR" >>"$rec"
  touch "$STUB_LOG/mise.fail"
  run make setup
  [ "$status" -ne 0 ]
  # the record still names everything, the new one waits beside it
  grep -Fxq 'mise node@22.1.0' "$rec"
  grep -Fxq "sdk $TCR/ncs-v1" "$rec"
  grep -Fxq "sdk $TCR/old-9" "$rec"
  [ -f "$rec.next" ]
  run make prune CONFIRM=prune
  [ "$status" -eq 0 ]
  [ -d "$STD_TOOLCHAINS/ncs-v1" ]
  [ -d "$STD_TOOLCHAINS/old-9" ]
  ! grep -Fxq 'uninstall node@22.1.0' "$STUB_LOG/mise.calls"
  # the next setup that finishes replaces the record
  rm -f "$STUB_LOG/mise.fail"
  run make setup
  [ "$status" -eq 0 ]
  [ ! -e "$rec.next" ]
  ! grep -Fxq "sdk $TCR/old-9" "$rec"
}

@test "a project in the middle of a setup is protected: what it intends to use is recorded before it exists" {
  mkdir -p "$BATS_TEST_TMPDIR/other"
  (cd "$BATS_TEST_TMPDIR/other" && PROJECT=other STD_PROJECT_DIR="$BATS_TEST_TMPDIR/other" TC_SH record-begin)
  (cd "$BATS_TEST_TMPDIR/other" && PROJECT=other STD_PROJECT_DIR="$BATS_TEST_TMPDIR/other" TC_SH sdk-begin "$STD_TOOLCHAINS/mid-7")
  mkdir -p "$STD_TOOLCHAINS/mid-7"
  grep -Fxq "sdk $TCR/mid-7" "$STATE/installed"
  run make prune CONFIRM=prune
  [ "$status" -eq 0 ]
  [ -d "$STD_TOOLCHAINS/mid-7" ]
  grep -Fxq "sdk $TCR/mid-7" "$STATE/installed"
}

@test "teardown without CONFIRM lists what would go with sizes and removes nothing" {
  printf 'node@22.1.0\n' >"$STUB_LOG/mise.toinstall"
  printf 'node@22.1.0\n' >"$STUB_LOG/mise.current"
  make setup
  other_project shared-2
  : >"$STUB_LOG/brew.argv"
  run make teardown
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing is removed without CONFIRM=teardown"* ]]
  [[ "$output" == *"2.0 M  fw/build"* ]]
  [[ "$output" == *"2.0 M  fw/release"* ]]
  [[ "$output" == *"2.0 M  svc/bin"* ]]
  [[ "$output" == *"usage record"* ]]
  [[ "$output" == *"sdk    $TCR/ncs-v1"* ]]
  [[ "$output" == *"mise   node@22.1.0"* ]]
  [[ "$output" == *"shared-2"*"used by "*"/other"* ]]
  [[ "$output" != *"sdk    $TCR/shared-2"*"2.0 M"* ]]
  [[ "$output" == *"not on the standard and uses one of these would lose it"* ]]
  [[ "$output" == *"total 12.0 M"* ]]
  [[ "$output" == *"make teardown CONFIRM=teardown"* ]]
  [ -f "$P/fw/build/out.elf" ]
  [ -f "$P/fw/release/1.0.0/SHA256SUMS" ]
  [ -f "$P/svc/bin/app" ]
  [ -d "$STD_TOOLCHAINS/ncs-v1" ]
  [ -n "$(record_of_demo)" ]
  ! grep -q uninstall "$STUB_LOG/mise.calls"
  [ ! -s "$STUB_LOG/brew.argv" ]
}

@test "teardown with CONFIRM=teardown removes the folders, the record and the unshared items; keeps the rest; never calls brew" {
  printf 'node@22.1.0\n' >"$STUB_LOG/mise.toinstall"
  printf 'node@22.1.0\npython@3.12.4\n' >"$STUB_LOG/mise.current"
  printf 'python@3.12.4\n' >"$STUB_LOG/mise.installed"
  make setup
  # another project uses shared-2; mine-3 is the user's own folder (not in the ledger) that this project records
  other_project shared-2
  mkdir -p "$STD_TOOLCHAINS/mine-3"
  TC_SH sdk-use "$STD_TOOLCHAINS/mine-3"
  : >"$STUB_LOG/brew.argv"
  run make teardown CONFIRM=teardown
  [ "$status" -eq 0 ]
  [ ! -e "$P/fw/build" ]
  [ ! -e "$P/fw/release" ]
  [ ! -e "$P/svc/bin" ]
  [ -z "$(/bin/ls "$STATE"/uses/demo-* 2>/dev/null)" ]
  [ ! -e "$STD_TOOLCHAINS/ncs-v1" ]
  grep -Fxq 'uninstall node@22.1.0' "$STUB_LOG/mise.calls"
  ! grep -q 'ncs-v1' "$STATE/installed"
  ! grep -q 'node@22.1.0' "$STATE/installed"
  [ -d "$STD_TOOLCHAINS/shared-2" ]
  grep -Fxq "sdk $TCR/shared-2" "$STATE/installed"
  [ -d "$STD_TOOLCHAINS/mine-3" ]
  ! grep -Fxq 'uninstall python@3.12.4' "$STUB_LOG/mise.calls"
  [[ "$output" == *"removed  sdk    $TCR/ncs-v1"* ]]
  [[ "$output" == *"freed about"* ]]
  [[ "$output" == *"Homebrew packages stay: git mise docker"* ]]
  [ ! -s "$STUB_LOG/brew.argv" ]
}

@test "a mise version the global config uses is never uninstalled, ledger or not" {
  printf 'node@22.1.0\n' >"$STUB_LOG/mise.toinstall"
  printf 'node@22.1.0\n' >"$STUB_LOG/mise.current"
  make setup
  # the user later put node 22.1.0 into the global config too
  printf 'node@22.1.0\n' >"$STUB_LOG/mise.global"
  run make teardown
  [[ "$output" == *"node@22.1.0"*"in use by the global mise config"* ]]
  run make teardown CONFIRM=teardown
  [ "$status" -eq 0 ]
  ! grep -Fxq 'uninstall node@22.1.0' "$STUB_LOG/mise.calls"
  # when the global config cannot be read, nothing from mise goes
  printf 'node@22.1.0\n' >"$STUB_LOG/mise.global"
  stub_cmd jq 'exit 1'
  run make prune CONFIRM=prune
  ! grep -Fxq 'uninstall node@22.1.0' "$STUB_LOG/mise.calls"
}

@test "an installer's concurrent version is not claimed: only versions this project's mise.toml asks for are ledgered" {
  printf 'node@22.1.0\nother@5.0.0\n' >"$STUB_LOG/mise.toinstall"
  printf 'node@22.1.0\n' >"$STUB_LOG/mise.current"
  run bash make/bin/toolchain.sh mise-install
  [ "$status" -eq 0 ]
  grep -Fxq 'mise node@22.1.0' "$STATE/installed"
  ! grep -q other "$STATE/installed"
}

@test "a stale record is removed by prune and protects nothing; an unreachable one is kept and still protects" {
  make setup
  mkdir -p "$STD_TOOLCHAINS/old-9" "$STD_TOOLCHAINS/far-8"
  printf 'sdk %s/old-9\nsdk %s/far-8\n' "$TCR" "$TCR" >>"$STATE/installed"
  # stale: the folder is gone, its parent (the temp dir) is there
  printf 'sdk %s/old-9\n' "$TCR" | hand_record gone "$BATS_TEST_TMPDIR/gone"
  # unreachable: not even the parent is there (an unmounted drive)
  mkdir -p "$STATE/uses"
  printf 'path /nonexistent-vol/proj\nproject far\nsdk %s/far-8\n' "$TCR" >"$STATE/uses/far-111111111111"
  run make prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale usage records"*"$BATS_TEST_TMPDIR/gone"* ]]
  [[ "$output" == *"unreachable usage records"*"/nonexistent-vol/proj"* ]]
  [[ "$output" == *"sdk    $TCR/old-9"* ]]
  [[ "$output" != *"sdk    $TCR/far-8"* ]]
  [ -f "$STATE/uses/gone-000000000000" ]
  run make prune CONFIRM=prune
  [ "$status" -eq 0 ]
  [ ! -e "$STATE/uses/gone-000000000000" ]
  [ -f "$STATE/uses/far-111111111111" ]
  [ ! -e "$STD_TOOLCHAINS/old-9" ]
  [ -d "$STD_TOOLCHAINS/far-8" ]
  # an unreachable record also keeps its items in a teardown
  run make teardown
  [[ "$output" == *"not reachable"* ]]
}

@test "teardown with no record still lists and cleans the folders" {
  run make teardown
  [ "$status" -eq 0 ]
  [[ "$output" == *"none (make setup writes it)"* ]]
  run make teardown CONFIRM=teardown
  [ "$status" -eq 0 ]
  [ ! -e "$P/fw/build" ]
  [ ! -e "$P/svc/bin" ]
}

@test "teardown and prune refuse a wrong CONFIRM, the environment, and several words; nothing is removed" {
  make setup
  run make teardown CONFIRM=prune
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=teardown"* ]]
  run make prune CONFIRM=teardown
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=prune"* ]]
  CONFIRM=teardown run make teardown
  [ "$status" -ne 0 ]
  run make teardown CONFIRM="teardown prune"
  [ "$status" -ne 0 ]
  [ -d "$P/fw/build" ]
  [ -d "$STD_TOOLCHAINS/ncs-v1" ]
  [ -n "$(record_of_demo)" ]
  run bash make/bin/toolchain.sh teardown --remove
  [ "$status" -ne 0 ]
  CONFIRM=teardown run bash make/bin/toolchain.sh prune --remove
  [ "$status" -ne 0 ]
}

@test "an SDK is removed by the exact path it was recorded with, whatever STD_TOOLCHAINS is now" {
  make setup
  other="$BATS_TEST_TMPDIR/tcB"
  mkdir -p "$other/ncs-v1"
  STD_TOOLCHAINS="$other" run make teardown CONFIRM=teardown
  [ "$status" -eq 0 ]
  [ ! -e "$STD_TOOLCHAINS/ncs-v1" ]
  [ -d "$other/ncs-v1" ]
}

@test "STD_TOOLCHAINS at HOME, at /, or above HOME is refused: nothing is recorded, ledgered or removed" {
  mkdir -p "$HOME/evil"
  for root in "$HOME" / "$(dirname "$HOME")"; do
    STD_TOOLCHAINS="$root" run bash make/bin/toolchain.sh sdk-begin "$root/evil"
    [ "$status" -eq 0 ]
  done
  [ ! -e "$STATE/installed" ] || ! grep -q evil "$STATE/installed"
  # hand-written lines for such folders, and the old name-only form, are never removed
  mkdir -p "$STD_TOOLCHAINS/oldname-1" "$STATE"
  printf 'sdk %s/evil\nsdk oldname-1\nsdk %s/\nsdk /\n' "$(cd "$HOME" && pwd -P)" "$(cd "$HOME" && pwd -P)" >"$STATE/installed"
  run make prune CONFIRM=prune
  [ "$status" -eq 0 ]
  [ -d "$HOME/evil" ]
  [ -d "$STD_TOOLCHAINS/oldname-1" ]
  [[ "$output" == *"ignored lines"* ]]
  [[ "$output" == *"sdk oldname-1"* ]]
}

@test "rustup: ledgered and removed per toolchain, never the host target, never a line without a toolchain" {
  printf 'stable-aarch64-apple-darwin aarch64-apple-darwin\nstable-aarch64-apple-darwin thumbv7em-none-eabihf\n' >"$STUB_LOG/rustup.installed"
  run bash make/bin/toolchain.sh rustup-add aarch64-apple-darwin x86_64-apple-darwin thumbv7em-none-eabihf
  [ "$status" -eq 0 ]
  grep -Fxq 'target add --toolchain stable-aarch64-apple-darwin x86_64-apple-darwin' "$STUB_LOG/rustup.calls"
  grep -Fxq 'rustup stable-aarch64-apple-darwin x86_64-apple-darwin' "$STATE/installed"
  ! grep -q 'thumbv7em' "$STATE/installed"
  rec="$(record_of_demo)"
  grep -Fxq 'rustup stable-aarch64-apple-darwin x86_64-apple-darwin' "$rec"
  grep -Fxq 'rustup stable-aarch64-apple-darwin thumbv7em-none-eabihf' "$rec"
  # a host-target entry, an old entry without a toolchain, and one for another toolchain
  printf 'rustup stable-aarch64-apple-darwin aarch64-apple-darwin\nrustup wasm32-unknown-unknown\nrustup nightly x86_64-apple-darwin\n' >>"$STATE/installed"
  printf 'nightly x86_64-apple-darwin\n' >>"$STUB_LOG/rustup.installed"
  printf 'rustup stable-aarch64-apple-darwin aarch64-apple-darwin\nrustup wasm32-unknown-unknown\n' >>"$rec"
  run make teardown CONFIRM=teardown
  [ "$status" -eq 0 ]
  grep -Fxq 'target remove --toolchain stable-aarch64-apple-darwin x86_64-apple-darwin' "$STUB_LOG/rustup.calls"
  ! grep -q 'target remove.*thumbv7em' "$STUB_LOG/rustup.calls"
  ! grep -q 'target remove.*aarch64-apple-darwin aarch64' "$STUB_LOG/rustup.calls"
  ! grep -q 'wasm32' <(grep 'target remove' "$STUB_LOG/rustup.calls")
  # nightly's target is in the ledger but no record names it: prune removes it from nightly only
  run make prune CONFIRM=prune
  grep -Fxq 'target remove --toolchain nightly x86_64-apple-darwin' "$STUB_LOG/rustup.calls"
  ! grep -q '^nightly x86_64' "$STUB_LOG/rustup.installed"
}

@test "record-begin keeps rustup lines" {
  run bash make/bin/toolchain.sh rustup-add x86_64-apple-darwin
  make setup
  grep -Fxq 'rustup stable-aarch64-apple-darwin x86_64-apple-darwin' "$(record_of_demo)"
}

@test "lines with CR, blanks or junk: normalised when valid, ignored and reported when not, and a bad record line protects" {
  mkdir -p "$STD_TOOLCHAINS/crlf-1" "$STD_TOOLCHAINS/shared-2" "$STD_TOOLCHAINS/safe-3"
  mkdir -p "$STATE"
  # the ledger: CRLF and trailing blanks on valid lines, junk lines, and an item that only a broken record names
  printf 'sdk %s/crlf-1\r\n  sdk %s/shared-2   \nmise noversion\nmise ev il@1\nsdk %s/safe-3\n' "$TCR" "$TCR" "$TCR" >"$STATE/installed"
  # another live project: a CRLF line that is valid once cleaned protects crlf-1; a broken line mentions safe-3
  mkdir -p "$BATS_TEST_TMPDIR/other"
  printf 'sdk %s/crlf-1\r\nsdk   %s/safe-3 and more words\n' "$TCR" "$TCR" | hand_record other "$(cd "$BATS_TEST_TMPDIR/other" && pwd -P)"
  run make prune CONFIRM=prune
  [ "$status" -eq 0 ]
  [ -d "$STD_TOOLCHAINS/crlf-1" ]
  [ -d "$STD_TOOLCHAINS/safe-3" ]
  # shared-2: valid after cleaning and named by nobody
  [ ! -e "$STD_TOOLCHAINS/shared-2" ]
  [[ "$output" == *"ignored lines"* ]]
  [[ "$output" == *"mise noversion"* ]]
  [[ "$output" == *"mise ev il@1"* ]]
  ! grep -q uninstall "$STUB_LOG/mise.calls"
  grep -q 'mise noversion' "$STATE/installed"
}

@test "a part folder that is absolute, climbs out or starts with a dash stops make for every verb" {
  for d in /tmp ../x -x a/../../x ..; do
    mkproject "$BATS_TEST_TMPDIR/bad" "PROJECT := bad
PARTS := p:go:$d"
    mkkind "$BATS_TEST_TMPDIR/bad" go 'define kind_go
$(1)-clean:
	@true
endef'
    cd "$BATS_TEST_TMPDIR/bad"
    run make help
    cd "$P"
    [ "$status" -ne 0 ] || { echo "accepted $d"; false; }
    [[ "$output" == *"must be inside the project"* ]]
  done
  mkproject "$BATS_TEST_TMPDIR/ok" 'PROJECT := ok
PARTS := p:go:sub/dir'
  mkkind "$BATS_TEST_TMPDIR/ok" go 'define kind_go
$(1)-clean:
	@true
endef'
  mkdir -p "$BATS_TEST_TMPDIR/ok/sub/dir"
  cd "$BATS_TEST_TMPDIR/ok"
  run make help
  cd "$P"
  [ "$status" -eq 0 ]
}

@test "prune without CONFIRM lists stale records, unrecorded items and the caches, and removes nothing" {
  make setup
  mkdir -p "$STD_TOOLCHAINS/old-9"
  printf 'sdk %s/old-9\nmise old@1.0.0\n' "$TCR" >>"$STATE/installed"
  printf 'old@1.0.0\n' >>"$STUB_LOG/mise.installed"
  printf '' | hand_record gone "$BATS_TEST_TMPDIR/gone"
  run make prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing is removed without CONFIRM=prune"* ]]
  [[ "$output" == *"$BATS_TEST_TMPDIR/gone"* ]]
  [[ "$output" == *"sdk    $TCR/old-9"* ]]
  [[ "$output" == *"mise   old@1.0.0"* ]]
  [[ "$output" != *"sdk    $TCR/ncs-v1"* ]]
  [[ "$output" == *"pnpm store"* ]]
  [[ "$output" == *"cargo-cache is not installed"* ]]
  [[ "$output" == *"docker images"*"skipped"* ]]
  [[ "$output" == *"make prune CONFIRM=prune"* ]]
  [ -d "$STD_TOOLCHAINS/old-9" ]
  [ -f "$STATE/uses/gone-000000000000" ]
  ! grep -q uninstall "$STUB_LOG/mise.calls"
  ! grep -q 'store prune' "$STUB_LOG/pnpm.calls"
}

@test "prune with CONFIRM=prune removes stale records and unreferenced ledger items, keeps the referenced and the unledgered" {
  make setup
  mkdir -p "$STD_TOOLCHAINS/old-9" "$STD_TOOLCHAINS/yours-5"
  printf 'sdk %s/old-9\nmise old@1.0.0\n' "$TCR" >>"$STATE/installed"
  printf 'old@1.0.0\nyours@2.0.0\n' >>"$STUB_LOG/mise.installed"
  printf 'sdk %s/old-9\n' "$TCR" | hand_record gone "$BATS_TEST_TMPDIR/gone"
  : >"$STUB_LOG/brew.argv"
  run make prune CONFIRM=prune
  [ "$status" -eq 0 ]
  [ ! -e "$STATE/uses/gone-000000000000" ]
  [ ! -e "$STD_TOOLCHAINS/old-9" ]
  grep -Fxq 'uninstall old@1.0.0' "$STUB_LOG/mise.calls"
  ! grep -q 'old-9' "$STATE/installed"
  ! grep -q 'old@1.0.0' "$STATE/installed"
  [ -d "$STD_TOOLCHAINS/ncs-v1" ]
  [ -d "$STD_TOOLCHAINS/yours-5" ]
  ! grep -Fxq 'uninstall yours@2.0.0' "$STUB_LOG/mise.calls"
  grep -Fxq 'store prune' "$STUB_LOG/pnpm.calls"
  [ -n "$(record_of_demo)" ]
  [ ! -s "$STUB_LOG/brew.argv" ]
  [[ "$output" == *"freed about"* ]]
}

@test "prune runs cargo cache --autoclean only when cargo-cache is installed" {
  stub_cmd cargo 'echo "$*" >>"$STUB_LOG/cargo.calls"; exit 0'
  make setup
  run make prune
  [[ "$output" == *"cargo cache --autoclean drops extracted sources"* ]]
  [ ! -e "$STUB_LOG/cargo.calls" ] || ! grep -q autoclean "$STUB_LOG/cargo.calls"
  run make prune CONFIRM=prune
  [ "$status" -eq 0 ]
  grep -Fxq 'cache --autoclean' "$STUB_LOG/cargo.calls"
}

@test "help lists teardown and prune in the setup group" {
  run make help
  [ "$status" -eq 0 ]
  [[ "$output" == *"teardown"*"Undo setup for this project"* ]]
  [[ "$output" == *"prune"*"Machine wide"* ]]
}

@test "mise-install claims nothing when the installed versions cannot be listed" {
  stub_cmd mise 'case "$1 $2" in "ls --installed") exit 1 ;; "ls --current") printf "{\"node\":[{\"version\":\"22.1.0\",\"installed\":true,\"source\":{\"path\":\"%s\"}}]}" "$STUB_PROJ_TOML" ;; esac'
  run bash make/bin/toolchain.sh mise-install
  [ "$status" -eq 0 ]
  [[ "$output" == *"none is recorded as installed by the standard"* ]]
  [ ! -e "$STATE/installed" ]
  grep -Fxq 'mise node@22.1.0' "$(record_of_demo)"
}
