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

# What slt installs, as a fake tree: slc (a stub that generates a makefile project), a Java runtime (at slt's
# jre/bin/java), two GNU Arm toolchains (the pinned 12.2.rel1 and a newer one, each with its manifest), two Simplicity
# SDKs (the pinned one says sdk_version:, as real .slcs files do) and two WiseConnects (the pinned one and another).
fake_installs() {
  mkdir -p "$INST/archive/slc-cli-6.0.1/slc_cli" "$INST/archive/java-21/jre/bin" "$INST/conan/p/gcc12/bin" \
    "$INST/conan/p/gcc14/bin" "$INST/conan/p/sdk-old" "$INST/conan/p/sdk-new" "$INST/conan/p/wc-old" "$INST/conan/p/wc-new"
  : >"$INST/archive/java-21/jre/bin/java"
  chmod +x "$INST/archive/java-21/jre/bin/java"
  for g in gcc12 gcc14; do
    for t in arm-none-eabi-gcc arm-none-eabi-size arm-none-eabi-gdb; do
      printf '#!/bin/bash\nprintf "%%s\\n" "$@" >>"%s/%s.argv"\n' "$STUB_LOG" "$t" >"$INST/conan/p/$g/bin/$t"
      chmod +x "$INST/conan/p/$g/bin/$t"
    done
  done
  : >"$INST/conan/p/gcc12/12.2.rel1-darwin-arm64-arm-none-eabi-manifest.txt"
  : >"$INST/conan/p/gcc14/14.2.rel1-darwin-arm64-arm-none-eabi-manifest.txt"
  printf 'id: simplicity_sdk\nversion: "2024.6.0"\n' >"$INST/conan/p/sdk-old/simplicity_sdk.slcs"
  printf 'id: simplicity_sdk\nlabel: Simplicity SDK\nsdk_version: 2025.12.2\n' >"$INST/conan/p/sdk-new/simplicity_sdk.slcs"
  printf 'id: wiseconnect3_sdk\nversion: 3.5.0\n' >"$INST/conan/p/wc-old/wiseconnect.slce"
  printf 'id: wiseconnect3_sdk\nversion: 4.0.1\n' >"$INST/conan/p/wc-new/wiseconnect.slce"
  # slc generate SLCP ... -d DIR ...: a makefile project in DIR whose make writes the image files and the CC it got.
  # With a post_build in the .slcp the makefile also has slc's post-build rule: it refuses an empty POST_BUILD_EXE,
  # runs "$(POST_BUILD_EXE)" postbuild ./app.slpb --parameter build_dir:build/debug, and (standing in for what
  # Commander's create_rps does) writes the .rps unless POST_BUILD_EXE is true (a skipped post-build).
  sl="$INST/archive/slc-cli-6.0.1/slc_cli"
  printf 'all:\n\tmkdir -p build/debug\n\tfor x in hex out map; do echo $$x > build/debug/app.$$x; done\n\techo "CC=$(CC)" > cc.txt\n' >"$sl/plain.Makefile"
  cp "$sl/plain.Makefile" "$sl/pb.Makefile"
  printf '\t@[ -n "$(POST_BUILD_EXE)" ] || { echo "POST_BUILD_EXE is not defined. Post-Build cannot run."; exit 1; }\n\t"$(POST_BUILD_EXE)" postbuild "./app.slpb" --parameter build_dir:"build/debug"\n\t[ "$(POST_BUILD_EXE)" = true ] || echo rps > build/debug/app.rps\n' >>"$sl/pb.Makefile"
  cat >"$sl/slc" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >>"$STUB_LOG/slc.argv"; printf -- '--\n' >>"$STUB_LOG/slc.argv"
[ "\$1" = generate ] || exit 0
d=''; prev=''; for a in "\$@"; do [ "\$prev" = -d ] && d="\$a"; prev="\$a"; done
mkdir -p "\$d"
if grep -q '^post_build:' "\$2"; then cp "$sl/pb.Makefile" "\$d/app.Makefile"; else cp "$sl/plain.Makefile" "\$d/app.Makefile"; fi
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
    [ "${SL_NO_POSTBUILD:-}" = 1 ] || printf 'post_build:\n  profile: wiseconnect_soc\n' >>firmware/app.slcp
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
  [[ "$a" == $'generate\n'"$P/firmware/app.slcp"$'\n-np\n-cp\n--overwrite-all\n-d\n'"$P/firmware/build/brd4338a"$'\n-o\nmakefile\n--with\nbrd4338a\n--sdk-package-path\n'* ]]
  [[ "$a" == *$'--sdk-package-path\n'"$INST/conan/p/sdk-new,$INST/conan/p/wc-new"$'\n--force'* ]]
  [ -f "$(OUT)/app.hex" ] && [ -f "$(OUT)/app.rps" ]
  # no -Werror and no signing on a plain build (SIGN=0); Commander only as the post-build
  [ "$(cat firmware/build/brd4338a/cc.txt)" = "CC=cc" ]
  [ ! -f "$STUB_LOG/secrets.calls" ]
  [ "$(argv commander)" = $'postbuild\n./app.slpb\n--parameter\nbuild_dir:build/debug\n--' ]
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
  [[ "$output" == *"Simplicity SDK 2099.1.0 not found"*"installed: 2024.6.0 2025.12.2 3.5.0 4.0.1"* ]] || false
  [ ! -f "$STUB_LOG/slc.argv" ]
}

@test "silabs: a part not set up runs setup first: slt install, slc signature trust, then the stamp" {
  slproject
  rm -f "$SLT/.std-setup-2025.12.2-4.0.1"
  run make firmware-build
  [ "$status" -eq 0 ]
  [[ "$output" == *"> firmware: not set up yet, running make firmware-setup first"* ]]
  [[ "$(argv slt)" == $'install\nslc-cli\n--non-interactive\n--\ninstall\nwiseconnect/4.0.1\n--non-interactive\n--'* ]]
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
  [[ "$(argv commander)" == *$'flash\n'"$(OUT)/app.hex"$'\n--device\nSiWG917M111MGTBA\n--serialno\n440123456'* ]]
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
  [[ "$(argv commander)" == *$'rps\nconvert\n'"$(OUT)/app-signed.rps"$'\n--app\n'"$(OUT)/app.rps"$'\n--sign\n'"$key"* ]]
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

@test "silabs 1.2: slt installs the pinned WiseConnect (wiseconnect/<ver>), and the setting follows WISECONNECT" {
  slproject 'firmware_WISECONNECT := 3.5.0'
  rm -f "$SLT/.std-setup-2025.12.2-4.0.1"
  run make firmware-setup
  [[ "$(argv slt)" == *$'install\nwiseconnect/3.5.0\n--non-interactive'* ]] || false
  [[ "$(argv slt)" != *$'install\nwiseconnect\n'* ]] || false
}

@test "silabs 1.2: the SDK is found by sdk_version: (doctor and build), Java at slt's jre/bin/java" {
  slproject
  run make firmware-doctor
  echo "$output"
  [[ "$output" == *"ok    Simplicity SDK 2025.12.2"* ]] || false
  [[ "$output" == *"ok    java for slc"* ]] || false
  # no java on PATH: only slt's jre/bin/java can satisfy slc
  run make firmware-build
  [ "$status" -eq 0 ]
  [[ "$(argv slc)" == *$'--sdk-package-path\n'"$INST/conan/p/sdk-new,$INST/conan/p/wc-new"* ]] || false
  rm -rf "$INST/archive/java-21"
  mkdir -p "$INST/archive/java-17/jre/lib/bin" && : >"$INST/archive/java-17/jre/lib/bin/java" && chmod +x "$INST/archive/java-17/jre/lib/bin/java"
  run make firmware-doctor
  [[ "$output" == *"ok    java for slc"* ]] || false
}

@test "silabs 1.2: slc generate gets --overwrite-all by default, once; SLC_OVERWRITE=0 leaves it out" {
  slproject 'firmware_SLC_ARGS := --overwrite-all --foo'
  run make firmware-build
  [ "$status" -eq 0 ]
  [ "$(argv slc | grep -c -- '^--overwrite-all$')" -eq 1 ]
  [[ "$(argv slc)" == *$'--force\n--foo'* ]] || false
  rm -f "$STUB_LOG/slc.argv"
  run make firmware-build firmware_SLC_OVERWRITE=0 firmware_SLC_ARGS=
  [ "$status" -eq 0 ]
  [ "$(argv slc | grep -c -- '^--overwrite-all$')" -eq 0 ]
}

@test "silabs 1.2: a board with trailing spaces in make/project.mk is stripped in slc, the build folder and doctor" {
  slproject 'firmware_BOARD := brd4338a   '
  run make firmware-check
  [ "$status" -eq 0 ]
  [[ "$(argv slc)" == *$'--with\nbrd4338a\n--sdk-package-path'* ]] || false
  [ -d "$P/firmware/build/check-brd4338a" ]
  [ -z "$(find "$P/firmware/build" -maxdepth 1 -name '* *')" ]
  run make firmware-build BOARD=' brd4325b '
  [ "$status" -eq 0 ]
  [ -f firmware/build/brd4325b/build/debug/app.hex ]
  run make firmware-doctor
  [[ "$output" == *"probe commander"*"board brd4338a"* ]] || false
  [[ "$output" != *"board brd4338a "* ]] || false
}

@test "silabs 1.2: the pinned toolchain's gcc, never the first found; a missing pin names what is installed" {
  slproject
  run make firmware-check
  [ "$status" -eq 0 ]
  [ "$(cat firmware/build/check-brd4338a/cc.txt)" = "CC=$INST/conan/p/gcc12/bin/arm-none-eabi-gcc -Werror" ]
  run make firmware-check firmware_GCC=14.2.rel1
  [ "$status" -eq 0 ]
  [ "$(cat firmware/build/check-brd4338a/cc.txt)" = "CC=$INST/conan/p/gcc14/bin/arm-none-eabi-gcc -Werror" ]
  rm -f "$STUB_LOG/slc.argv"
  run make firmware-check firmware_GCC=13.3.rel1
  [ "$status" -ne 0 ]
  [[ "$output" == *"GNU Arm toolchain 13.3.rel1 not found"*"installed: 12.2.rel1 14.2.rel1"*"firmware_GCC"* ]] || false
  [ ! -f "$STUB_LOG/slc.argv" ]
  run make firmware-doctor firmware_GCC=13.3.rel1
  [[ "$output" == *"GNU Arm toolchain 13.3.rel1 missing (installed: 12.2.rel1 14.2.rel1)"* ]] || false
}

@test "silabs 1.2: test runs the Makefile in test/ (else tests/) with cc and BUILD_DIR under build/; none is fine; clean removes build/ only" {
  slproject
  run make firmware-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"no host tests (no Makefile in firmware/test or firmware/tests)"* ]] || false
  mkdir -p firmware/tests
  printf 'all:\n\tmkdir -p $(BUILD_DIR)\n\techo "CC=$(CC)" > $(BUILD_DIR)/cc.txt\n\techo tests > here.txt\n' >firmware/tests/Makefile
  run make firmware-test
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat firmware/build/test/cc.txt)" = "CC=cc" ]
  [[ "$output" == *"host tests in firmware/tests with cc"*"host tests passed"* ]] || false
  # test/ wins over tests/; a failing test fails the target
  mkdir -p firmware/test
  printf 'all:\n\t@echo FAILED; exit 1\n' >firmware/test/Makefile
  run make firmware-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"host tests in firmware/test with cc"* ]] || false
  rm -rf firmware/test
  # the root make test runs it
  run make test
  [ "$status" -eq 0 ]
  [[ "$output" == *"host tests passed"* ]] || false
  # clean removes firmware/build (the test build under it), never what a test Makefile wrote elsewhere
  run make firmware-clean
  [ ! -e firmware/build ]
  [ -f firmware/tests/here.txt ]
  run make help
  [[ "$output" == *"firmware-test"* ]] || false
}

@test "silabs 1.3: no --toolchain on slc generate (WiseConnect's own toolchain_gcc would clash with the SDK's)" {
  slproject
  run make firmware-check
  [ "$status" -eq 0 ]
  run make firmware-build
  [ "$status" -eq 0 ]
  [ "$(argv slc | grep -c -- '^--toolchain$')" -eq 0 ]
  # a project that needs one passes it through SLC_ARGS
  rm -f "$STUB_LOG/slc.argv"
  run make firmware-build 'firmware_SLC_ARGS=--toolchain gcc'
  [ "$status" -eq 0 ]
  [[ "$(argv slc)" == *$'--force\n--toolchain\ngcc'* ]] || false
}

@test "silabs 1.3: with a post_build the generated makefile gets POST_BUILD_EXE=<commander> and the build checks the .rps" {
  slproject
  run make firmware-build
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"post_build wiseconnect_soc with $STUBS/commander"* ]] || false
  [[ "$output" == *"ok    $(OUT)/app.rps"* ]] || false
  # SILABS_COMMANDER wins over the one on PATH
  stub_recorder mycmdr
  rm -f "$STUB_LOG/commander.argv"
  run make firmware-build SILABS_COMMANDER="$STUBS/mycmdr"
  [ "$status" -eq 0 ]
  [ "$(argv mycmdr)" = $'postbuild\n./app.slpb\n--parameter\nbuild_dir:build/debug\n--' ]
  [ ! -f "$STUB_LOG/commander.argv" ]
  # a post-build that makes no .rps fails the build
  stub_cmd commander 'exit 0'
  sed -i.bak 's|echo rps > build/debug/app.rps|true|' "$INST/archive/slc-cli-6.0.1/slc_cli/pb.Makefile"
  rm -rf firmware/build
  run make firmware-build
  [ "$status" -ne 0 ]
  [[ "$output" == *"the post_build wiseconnect_soc ran but made no app.rps"* ]] || false
}

@test "silabs 1.3: with a post_build and no Simplicity Commander, build refuses before slc, check skips the post-build" {
  slproject
  rm -f "$STUBS/commander"
  run make firmware-build SILABS_COMMANDER_PATHS=
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Simplicity Commander not found: the .slcp's post_build wiseconnect_soc runs it (commander postbuild) to make the .rps"* ]] || false
  [ ! -f "$STUB_LOG/slc.argv" ]
  run make firmware-check SILABS_COMMANDER_PATHS=
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the post_build wiseconnect_soc (the .rps) is skipped in this check build"* ]] || false
  [ ! -f "$P/firmware/build/check-brd4338a/build/debug/app.rps" ]
  [ -f "$P/firmware/build/check-brd4338a/build/debug/app.hex" ]
  run make firmware-doctor SILABS_COMMANDER_PATHS=
  [ "$status" -ne 0 ]
  [[ "$output" == *"ok    post_build wiseconnect_soc in app.slcp"* ]] || false
  [[ "$output" == *"miss  Simplicity Commander missing: the build needs it (the .slcp's post_build wiseconnect_soc runs commander postbuild to make the .rps)"* ]] || false
}

@test "silabs 1.3: without a post_build the build makes no .rps and needs no Commander; release says the .slcp lines" {
  SL_NO_POSTBUILD=1 slproject
  rm -f "$STUBS/commander"
  run make firmware-build SILABS_COMMANDER_PATHS=
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no post_build in app.slcp: no .rps"* ]] || false
  [ -f "$(OUT)/app.hex" ] && [ ! -f "$(OUT)/app.rps" ]
  # the generated makefile gets no POST_BUILD_EXE (it has no post-build rule to give it to)
  run make firmware-release ENV=staging NOBUILD=1 SILABS_COMMANDER_PATHS=
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no app.rps in $(OUT): app.slcp has no post_build, so the build makes none. add post_build: with profile: wiseconnect_soc under it (two lines at the top level) to app.slcp"*"Nothing was uploaded"* ]] || false
  [ ! -f "$STUB_LOG/npx.argv" ]
  # doctor: with an OTA bucket a warning, Commander only a warning (no post-build needs it)
  run make firmware-doctor SILABS_COMMANDER_PATHS=
  echo "$output"
  [[ "$output" == *"warn  no post_build in app.slcp: the build makes no .rps and make firmware-release refuses"* ]] || false
  [[ "$output" == *"warn  Simplicity Commander missing, needed by flash, erase and power"* ]] || false
  # without one, no warning about the .rps
  run make firmware-doctor SILABS_COMMANDER_PATHS= OTA_BUCKET=
  [[ "$output" == *"ok    no post_build in app.slcp"* ]] || false
}

@test "silabs 1.3: the post_build profile is read from the .slcp's top level only" {
  SL_NO_POSTBUILD=1 slproject
  # a nested key or a comment is not the top-level post_build
  printf '# post_build:
other:
  post_build: x
' >>firmware/app.slcp
  run make firmware-build SILABS_COMMANDER_PATHS=
  [ "$status" -eq 0 ]
  [[ "$output" == *"no post_build in app.slcp"* ]] || false
  printf 'post_build:
  # the WiseConnect SoC profile
  profile: "wiseconnect_soc"
later: 1
' >>firmware/app.slcp
  run make firmware-build
  [ "$status" -eq 0 ]
  [[ "$output" == *"post_build wiseconnect_soc with"* ]] || false
}

# A stub slt that also answers `slt where commander/<ver>`: the Commander.app folder in the fake slt tree when that
# version is "installed" (CMDR_VER), nothing otherwise (as the real slt prints nothing for a package it does not have).
slt_with_where() {
  cat >"$SLT/slt" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >>"$STUB_LOG/slt.argv"; printf -- '--\n' >>"$STUB_LOG/slt.argv"
if [ "\$1" = where ] && [ "\$2" = "commander/\${CMDR_VER:-none}" ]; then printf '%s\n' "$INST/archive/Commander.app"; fi
exit 0
STUB
  chmod +x "$SLT/slt"
  mkdir -p "$INST/archive/Commander.app/Contents/MacOS"
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" >>"%s/slt-commander.argv"; printf -- "--\\n" >>"%s/slt-commander.argv"\n' "$STUB_LOG" "$STUB_LOG" \
    >"$INST/archive/Commander.app/Contents/MacOS/commander"
  chmod +x "$INST/archive/Commander.app/Contents/MacOS/commander"
}

@test "silabs 1.3: setup installs Simplicity Commander through slt (commander/<COMMANDER>, pinned, after WiseConnect)" {
  slproject
  rm -f "$SLT/.std-setup-2025.12.2-4.0.1"
  run make firmware-setup
  [ "$status" -eq 0 ]
  [[ "$(argv slt)" == $'install\nslc-cli\n--non-interactive\n--\ninstall\nwiseconnect/4.0.1\n--non-interactive\n--\ninstall\ncommander/1.25.0\n--non-interactive\n--'* ]] || false
  # the pin follows COMMANDER; an empty COMMANDER installs none
  rm -f "$SLT/.std-setup-2025.12.2-4.0.1" "$STUB_LOG/slt.argv"
  run make firmware-setup firmware_COMMANDER=1.24.3
  [ "$status" -eq 0 ]
  [[ "$(argv slt)" == *$'install\ncommander/1.24.3\n--non-interactive'* ]] || false
  rm -f "$SLT/.std-setup-2025.12.2-4.0.1" "$STUB_LOG/slt.argv"
  run make firmware-setup firmware_COMMANDER=
  [ "$status" -eq 0 ]
  [[ "$(argv slt)" != *commander* ]] || false
}

@test "silabs 1.3: the Commander slt installed is found (slt where commander/<ver>, Commander.app/Contents/MacOS/commander)" {
  slproject
  slt_with_where
  rm -f "$STUBS/commander"
  CMDR_VER=1.25.0 run make firmware-build SILABS_COMMANDER_PATHS=
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"post_build wiseconnect_soc with $INST/archive/Commander.app/Contents/MacOS/commander"* ]] || false
  [ "$(argv slt-commander)" = $'postbuild\n./app.slpb\n--parameter\nbuild_dir:build/debug\n--' ]
  [[ "$(argv slt)" == *$'where\ncommander/1.25.0\n--non-interactive\n--ignore-slconf'* ]] || false
  CMDR_VER=1.25.0 run make firmware-doctor SILABS_COMMANDER_PATHS=
  [[ "$output" == *"ok    Simplicity Commander $INST/archive/Commander.app/Contents/MacOS/commander"* ]] || false
  # commander on PATH still wins over the slt one
  stub_recorder commander
  CMDR_VER=1.25.0 run make firmware-doctor SILABS_COMMANDER_PATHS=
  [[ "$output" == *"ok    Simplicity Commander $STUBS/commander"* ]] || false
}

@test "silabs 1.3: a part set up before Commander was in SLT_INSTALL gets it from setup; doctor's fix is make <part>-setup" {
  slproject
  slt_with_where
  rm -f "$STUBS/commander"
  # not installed yet: slt where finds nothing, and the archive has no Commander for the fallback either
  rm -rf "$INST/archive/Commander.app"
  run make firmware-doctor SILABS_COMMANDER_PATHS=
  [ "$status" -ne 0 ]
  [[ "$output" == *"miss  Simplicity Commander missing: the build needs it"*": make firmware-setup (it installs Simplicity Commander 1.25.0 through slt), or set SILABS_COMMANDER"* ]] || false
  [[ "$output" != *"from Silicon Labs"* ]] || false
  SL_NO_POSTBUILD=1 slproject
  run make firmware-doctor SILABS_COMMANDER_PATHS=
  [[ "$output" == *"warn  Simplicity Commander missing, needed by flash, erase and power"*": make firmware-setup (it installs Simplicity Commander 1.25.0 through slt), or set SILABS_COMMANDER"* ]] || false
  # the stamp is there, so setup skips the slt installs but still installs Commander
  rm -f "$STUB_LOG/slt.argv"
  run make firmware-setup SILABS_COMMANDER_PATHS=
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$(argv slt)" != *$'install\nslc-cli'* ]] || false
  [[ "$(argv slt)" == *$'install\ncommander/1.25.0\n--non-interactive'* ]] || false
  [[ "$output" == *"warn  Simplicity Commander not found"*"slt did not install commander/1.25.0"* ]] || false
}
