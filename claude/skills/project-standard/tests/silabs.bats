#!/usr/bin/env bats
# Kind silabs (slt, slc, Simplicity Commander) against stub tools: slc generates a tiny makefile that writes the
# image files, commander and the J-Link tools record their argv, the slt installs are a fake tree in the test HOME.
# Nothing touches a device, the network, ~/.toolchains, ~/.silabs or ~/.secrets. secrets.sh is replaced by a stub
# that implements with-file ({} -> a temp file), exec and keygen.

load helpers

setup() {
  std_setup_env
  export STD_TOOLCHAINS="$BATS_TEST_TMPDIR/toolchains"
  P="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/proj"
  INST="$HOME/.silabs/slt/installs"
  export PORTS_DIR="$BATS_TEST_TMPDIR/dev"
  mkdir -p "$PORTS_DIR"
  for t in commander JLinkExe JLinkGDBServerCLExe arm-none-eabi-gdb tio npx curl; do stub_recorder "$t"; done
  # slt itself, pinned and set up: what a command checks before it runs anything (std_ready)
  SLT="$STD_TOOLCHAINS/slt-1.1.1"
  mkdir -p "$SLT"
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" >>"%s/slt.argv"; printf -- "--\\n" >>"%s/slt.argv"\n' "$STUB_LOG" "$STUB_LOG" >"$SLT/slt"
  chmod +x "$SLT/slt"
  : >"$SLT/.std-setup-2025.12.2-4.0.1"
  fake_installs
}

# What slt installs, as a fake tree: slc (a stub that generates a makefile project), a Java runtime, the GNU Arm
# toolchain, two Simplicity SDKs and two WiseConnects (the pinned one and another).
fake_installs() {
  mkdir -p "$INST/archive/slc-cli-6.0.1/slc_cli" "$INST/archive/java-21/jre/lib/bin" "$INST/conan/p/gcc12/bin" \
    "$INST/conan/p/sdk-old" "$INST/conan/p/sdk-new" "$INST/conan/p/wc-old" "$INST/conan/p/wc-new"
  : >"$INST/archive/java-21/jre/lib/bin/java"
  chmod +x "$INST/archive/java-21/jre/lib/bin/java"
  for t in arm-none-eabi-gcc arm-none-eabi-size arm-none-eabi-gdb; do
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" >>"%s/%s.argv"\n' "$STUB_LOG" "$t" >"$INST/conan/p/gcc12/bin/$t"
    chmod +x "$INST/conan/p/gcc12/bin/$t"
  done
  printf 'id: simplicity_sdk\nversion: "2024.6.0"\n' >"$INST/conan/p/sdk-old/simplicity_sdk.slcs"
  printf 'id: simplicity_sdk\nversion: "2025.12.2"\n' >"$INST/conan/p/sdk-new/simplicity_sdk.slcs"
  printf 'id: wiseconnect3_sdk\nversion: 3.5.0\n' >"$INST/conan/p/wc-old/wiseconnect.slce"
  printf 'id: wiseconnect3_sdk\nversion: 4.0.1\n' >"$INST/conan/p/wc-new/wiseconnect.slce"
  # slc generate SLCP ... -d DIR ...: a makefile project in DIR whose make writes the image files and the CC it got
  cat >"$INST/archive/slc-cli-6.0.1/slc_cli/slc" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >>"$STUB_LOG/slc.argv"; printf -- '--\n' >>"$STUB_LOG/slc.argv"
[ "\$1" = generate ] || exit 0
d=''; prev=''; for a in "\$@"; do [ "\$prev" = -d ] && d="\$a"; prev="\$a"; done
mkdir -p "\$d"
printf 'all:\n\tmkdir -p build/debug\n\tfor x in hex out rps map; do echo \$\$x > build/debug/app.\$\$x; done\n\techo "CC=\$(CC)" > cc.txt\n' >"\$d/app.Makefile"
EOF
  chmod +x "$INST/archive/slc-cli-6.0.1/slc_cli/slc"
}

# slproject 'more project.mk lines'
slproject() {
  mkproject "$P" "PROJECT := demo
PARTS := firmware:silabs
OTA_BUCKET := ota-bucket
STD_PORT_GLOB := $PORTS_DIR/cu.*
$1"
  cp "$STD_TEMPLATES/kinds/silabs.mk" "$P/make/kinds/"
  cat >"$P/make/bin/secrets.sh" <<'EOF'
#!/usr/bin/env bash
# test stub of secrets.sh: records the call, then does what the real one does for the command
printf '%s\n' "$*" >>"$STUB_LOG/secrets.calls"
cmd="$1"; shift
case "$cmd" in
  with-file)
    shift; shift
    tmp="$(mktemp)"; echo "KEY" >"$tmp"; printf '%s\n' "$tmp" >"$STUB_LOG/keyfile"
    args=(); for a in "$@"; do args+=("${a//\{\}/$tmp}"); done
    "${args[@]}"; rc=$?; rm -f "$tmp"; exit "$rc" ;;
  exec) shift 2; shift; exec "$@" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$P/make/bin/secrets.sh"
  cd "$P"
  mkdir -p firmware
  if [ "${SL_EMPTY:-}" != 1 ]; then
    printf 'project_name: app\nsdk:\n  id: simplicity_sdk\n  version: "2025.12.2"\nsdk_extension:\n- id: wiseconnect3_sdk\n  version: 4.0.1\n' >firmware/app.slcp
    echo 1.2.0 >firmware/VERSION
  fi
}

argv() { cat "$STUB_LOG/$1.argv" 2>/dev/null; }
OUT() { printf '%s\n' "$P/firmware/build/brd4338a/build/debug"; }

@test "silabs parses and lists its targets in help, power and keygen among them" {
  slproject
  run make help
  [ "$status" -eq 0 ]
  for t in firmware-build firmware-check firmware-flash firmware-erase firmware-monitor firmware-debug firmware-size \
    firmware-power firmware-power-live firmware-power-avg firmware-keygen firmware-release firmware-github-release; do
    [[ "$output" == *"$t"* ]] || { echo "missing $t"; false; }
  done
}

@test "silabs build: slc generate from the .slcp for the board with the pinned SDK and WiseConnect, then the generated makefile" {
  slproject
  run make firmware-build
  [ "$status" -eq 0 ]
  a="$(argv slc)"
  [[ "$a" == $'generate\n'"$P/firmware/app.slcp"$'\n-np\n-cp\n-d\n'"$P/firmware/build/brd4338a"$'\n-o\nmakefile\n--with\nbrd4338a\n--toolchain\ngcc\n'* ]]
  [[ "$a" == *$'--sdk-package-path\n'"$INST/conan/p/sdk-new,$INST/conan/p/wc-new"$'\n--force'* ]]
  [ -f "$(OUT)/app.hex" ] && [ -f "$(OUT)/app.rps" ]
  # no -Werror and no signing on a plain build (SIGN=0)
  [ "$(cat firmware/build/brd4338a/cc.txt)" = "CC=cc" ]
  [ ! -f "$STUB_LOG/secrets.calls" ]
  [ ! -f "$STUB_LOG/commander.argv" ]
}

@test "silabs BOARD= on the command line wins and builds into its own folder" {
  slproject
  run make firmware-build BOARD=brd4325b
  [ "$status" -eq 0 ]
  [[ "$(argv slc)" == *$'--with\nbrd4325b'* ]]
  [ -f firmware/build/brd4325b/build/debug/app.hex ]
}

@test "silabs check builds into build/check-<board> with -Werror and needs no secrets" {
  slproject
  run make firmware-check
  [ "$status" -eq 0 ]
  [[ "$(argv slc)" == *"$P/firmware/build/check-brd4338a"* ]]
  [ "$(cat firmware/build/check-brd4338a/cc.txt)" = "CC=$INST/conan/p/gcc12/bin/arm-none-eabi-gcc -Werror" ]
  [ ! -f "$STUB_LOG/secrets.calls" ]
}

@test "silabs build refuses when the pinned SDK is not installed, naming what is" {
  slproject 'firmware_SDK := 2099.1.0'
  : >"$SLT/.std-setup-2099.1.0-4.0.1"
  run make firmware-build
  [ "$status" -ne 0 ]
  [[ "$output" == *"Simplicity SDK 2099.1.0 not found"*"installed: 2024.6.0 2025.12.2 3.5.0 4.0.1"* ]]
  [ ! -f "$STUB_LOG/slc.argv" ]
}

@test "silabs: a part not set up runs setup first: slt install, slc signature trust, then the stamp" {
  slproject
  rm -f "$SLT/.std-setup-2025.12.2-4.0.1"
  run make firmware-build
  [ "$status" -eq 0 ]
  [[ "$output" == *"> firmware: not set up yet, running make firmware-setup first"* ]]
  [[ "$(argv slt)" == $'install\nslc-cli\n--non-interactive\n--\ninstall\nwiseconnect\n--non-interactive\n--'* ]]
  [[ "$(argv slc)" == $'signature\ntrust\n--sdk-package-path\n'"$INST/conan/p/sdk-new,$INST/conan/p/wc-new"* ]]
  [ -f "$SLT/.std-setup-2025.12.2-4.0.1" ]
  rm -f "$STUB_LOG/slt.argv"
  run make firmware-build
  [ "$status" -eq 0 ]
  [[ "$output" != *"not set up yet"* ]]
  [ ! -f "$STUB_LOG/slt.argv" ]
}

@test "silabs setup downloads the pinned slt zip when it is missing" {
  command -v zip >/dev/null || skip "zip is not installed"
  slproject
  rm -rf "$SLT"
  mkdir -p "$BATS_TEST_TMPDIR/zip"
  cp "$STUBS/tio" "$BATS_TEST_TMPDIR/zip/slt"
  (cd "$BATS_TEST_TMPDIR/zip" && zip -q slt.zip slt)
  stub_cmd curl 'printf "%s\n" "$@" >>"$STUB_LOG/curl.argv"; out=""; prev=""; for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done; cp "'"$BATS_TEST_TMPDIR"'/zip/slt.zip" "$out"'
  run make firmware-setup
  [ "$status" -eq 0 ]
  [[ "$(argv curl)" == *"https://www.silabs.com/documents/public/software/slt-cli-1.1.1-"*".zip"* ]]
  [ -x "$SLT/slt" ]
  [ ! -e "$SLT.partial" ]
  [ -f "$SLT/.std-setup-2025.12.2-4.0.1" ]
}

@test "silabs part not started yet (no .slcp): setup, check and build skip; flash and release refuse" {
  SL_EMPTY=1 slproject
  rm -f "$SLT/.std-setup-2025.12.2-4.0.1"
  for v in setup check build; do
    run make "firmware-$v"
    [ "$status" -eq 0 ]
    [[ "$output" == *"> firmware: not started yet (no *.slcp in firmware): $v skipped"* ]]
  done
  run make firmware-flash NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to flash"* ]]
  run make firmware-release-assets
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to release"* ]]
  [ ! -f "$STUB_LOG/slc.argv" ] && [ ! -f "$STUB_LOG/slt.argv" ]
  run make firmware-doctor
  [[ "$output" == *"warn"*"firmware: not started yet (no *.slcp in firmware)"* ]]
}

@test "silabs flash builds, then flashes the hex with Simplicity Commander; DEVICE and PROBE_ID are passed" {
  slproject 'firmware_DEVICE := SiWG917M111MGTBA
firmware_PROBE_ID := 440123456'
  run make firmware-flash
  [ "$status" -eq 0 ]
  [[ "$(argv commander)" == $'flash\n'"$(OUT)/app.hex"$'\n--device\nSiWG917M111MGTBA\n--serialno\n440123456'* ]]
}

@test "silabs flash PROBE=jlink needs the J-Link device name, then loads the hex" {
  slproject
  make firmware-build >/dev/null
  run make firmware-flash PROBE=jlink NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"firmware_JLINK_DEVICE"* ]]
  [ ! -f "$STUB_LOG/JLinkExe.argv" ]
  run make firmware-flash PROBE=jlink NOBUILD=1 firmware_JLINK_DEVICE=EFR32MG24BXXXF1536
  [ "$status" -eq 0 ]
  [[ "$(argv JLinkExe)" == $'-device\nEFR32MG24BXXXF1536\n-if\nSWD'* ]]
}

@test "silabs erase needs CONFIRM=erase on the command line, then mass erases with commander" {
  slproject
  run make firmware-erase
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=erase"* ]]
  CONFIRM=erase run make firmware-erase
  [ "$status" -ne 0 ]
  [ ! -f "$STUB_LOG/commander.argv" ]
  run make firmware-erase CONFIRM=erase
  [ "$status" -eq 0 ]
  [[ "$(argv commander)" == $'device\nmasserase'* ]]
}

@test "silabs SIGN=1 signs the .rps with the key from the secrets repo, which is gone afterwards" {
  slproject 'firmware_SIGN := 1'
  run make firmware-build
  [ "$status" -eq 0 ]
  key="$(cat "$STUB_LOG/keyfile")"
  [[ "$(argv commander)" == $'rps\nconvert\n'"$(OUT)/app-signed.rps"$'\n--app\n'"$(OUT)/app.rps"$'\n--sign\n'"$key"* ]]
  [ ! -e "$key" ]
  grep -q '^with-file silabs-m4 -- ' "$STUB_LOG/secrets.calls"
}

@test "silabs keygen makes an ECDSA P-256 key and never overwrites one" {
  slproject
  run make firmware-keygen
  [ "$status" -eq 0 ]
  grep -q '^keygen silabs-m4 --type ecdsa-p256' "$STUB_LOG/secrets.calls"
  mkdir -p "$SECRETS_DIR/demo/keys"
  echo old >"$SECRETS_DIR/demo/keys/silabs-m4.sops"
  run make firmware-keygen
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "silabs power: the AEM samples go to build/power.csv with the average, minimum and maximum current" {
  slproject
  printf '1000000,10.0,3.30\n2000000,20.0,3.30\n3000000,30.0,3.30\n' >"$STUB_LOG/commander.out"
  # commander runs in the background for DURATION seconds, then is stopped; the stub is done well within one
  run make firmware-power DURATION=1
  [ "$status" -eq 0 ]
  [[ "$(argv commander)" == $'aem\ndump\n--datarate\n10\n--noheader'* ]]
  [ "$(head -n 1 firmware/build/power.csv)" = "time_s,current_mA,voltage_V" ]
  [ "$(sed -n 2p firmware/build/power.csv)" = "1.000000,10.000000,3.3000" ]
  [[ "$output" == *"avg       20.0000 mA"* ]]
  [[ "$output" == *"min       10.0000 mA"* ]]
  [[ "$output" == *"max       30.0000 mA"* ]]
  [[ "$output" == *"power     66.000 mW (avg)"* ]]
  [ -f firmware/build/power.txt ]
  run make firmware-power-avg AEM_WINDOW_MS=5000
  [ "$status" -eq 0 ]
  [[ "$(argv commander)" == *$'aem\nmeasure\n--windowlength\n5000'* ]]
}

@test "silabs power with no samples fails" {
  slproject
  run make firmware-power DURATION=0
  [ "$status" -ne 0 ]
  [[ "$output" == *"no samples"* ]]
}

@test "silabs release: refuses ENV=local, uploads the .rps as <ver>/ and latest/ with ENV=staging, skips without a bucket" {
  slproject
  run make firmware-release ENV=local
  [ "$status" -ne 0 ]
  run make firmware-release ENV=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=production"* ]]
  run make firmware-release ENV=staging
  [ "$status" -eq 0 ]
  a="$(argv npx)"
  [[ "$a" == *"ota-bucket/demo/firmware/staging/1.2.0/firmware.rps"* ]]
  [[ "$a" == *"ota-bucket/demo/firmware/staging/latest/firmware.rps"* ]]
  [[ "$a" == *$'--file\n'"$(OUT)/app.rps"* ]]
  [[ "$output" == *"unsigned image"* ]]
  run make firmware-release ENV=staging OTA_BUCKET=
  [ "$status" -eq 0 ]
  [[ "$output" == *"no OTA bucket"* ]]
}

@test "silabs release-assets: hex, out, rps and map in release/<ver> with SHA256SUMS" {
  slproject
  run make firmware-release-assets
  [ "$status" -eq 0 ]
  for f in app.hex app.out app.rps app.map SHA256SUMS; do [ -f "firmware/release/1.2.0/$f" ] || { echo "missing $f"; false; }; done
  grep -q 'app.hex' firmware/release/1.2.0/SHA256SUMS
  run make firmware-version
  [ "$output" = "firmware 1.2.0" ]
}

@test "silabs doctor names what is missing and warns when the .slcp pins other SDK versions" {
  slproject 'firmware_WISECONNECT := 3.5.0'
  rm -rf "$INST/conan/p/sdk-new"
  run make firmware-doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"Simplicity SDK 2025.12.2 missing"* ]]
  [[ "$output" == *"app.slcp asks for WiseConnect 4.0.1, firmware_WISECONNECT is 3.5.0"* ]]
  [[ "$output" == *"Simplicity Commander"* ]]
}

@test "silabs monitor uses the only port and logs to build/monitor.log" {
  slproject
  : >"$PORTS_DIR/cu.usbmodem0004401234561"
  stub_cmd script 'printf "%s\n" "$@" >"$STUB_LOG/script.argv"'
  run make firmware-monitor
  [ "$status" -eq 0 ]
  a="$(cat "$STUB_LOG/script.argv")"
  [[ "$a" == *"$P/firmware/build/monitor.log"* ]]
  [[ "$a" == *$'tio\n-b\n115200\n'"$PORTS_DIR/cu.usbmodem0004401234561"* ]]
}
