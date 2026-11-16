#!/usr/bin/env bats
# Firmware kinds (zephyr, espidf, pio, arm-gcc, circuitpython) against stub tools: every tool the
# kinds call (west, probe-rs, idf.py, pio, dfu-util, docker, ...) records its argv; nothing touches a
# device, the network, ~/.toolchains or ~/.secrets. secrets.sh is replaced by a stub that implements
# with-file ({} -> a temp file), exec and keygen.

load helpers

FW_KINDS="zephyr espidf pio arm-gcc circuitpython"

setup() {
  std_setup_env
  export STD_TOOLCHAINS="$BATS_TEST_TMPDIR/toolchains"
  # fake pinned SDKs: what the kinds look for before they run anything
  mkdir -p "$STD_TOOLCHAINS/ncs-v3.2.1/zephyr" "$STD_TOOLCHAINS/zephyr-sdk-0.17.4" "$STD_TOOLCHAINS/esp-idf-v5.5"
  : >"$STD_TOOLCHAINS/ncs-v3.2.1/zephyr/zephyr-env.sh"
  : >"$STD_TOOLCHAINS/esp-idf-v5.5/export.sh"
  # ... and set up, so a command does not run its part's setup first (std_ready): the NCS workspace updated with west in
  # its venv, the ESP-IDF tools installed for the targets the tests use, and the pio part fw's packages (a stamp dated
  # ahead of any platformio.ini a test writes). The tests of setup and of std_ready remove these.
  mkdir -p "$STD_TOOLCHAINS/ncs-v3.2.1/.venv/bin" "$BATS_TEST_TMPDIR/proj/fw/.pio"
  : >"$STD_TOOLCHAINS/ncs-v3.2.1/.std-updated"
  printf '#!/bin/sh\nexit 0\n' >"$STD_TOOLCHAINS/ncs-v3.2.1/.venv/bin/west"
  chmod +x "$STD_TOOLCHAINS/ncs-v3.2.1/.venv/bin/west"
  : >"$STD_TOOLCHAINS/esp-idf-v5.5/.std-installed-esp32c6"
  : >"$STD_TOOLCHAINS/esp-idf-v5.5/.std-installed-esp32s3"
  touch -t 209901010000 "$BATS_TEST_TMPDIR/proj/fw/.pio/.std-setup"
  for t in west probe-rs nrfutil openocd JLinkExe idf.py pio dfu-util st-flash docker esptool tio npx \
    arm-none-eabi-gcc arm-none-eabi-size cmake ninja; do
    stub_recorder "$t"
  done
  # objcopy makes the .bin it is asked for
  stub_cmd arm-none-eabi-objcopy 'printf "%s\n" "$@" >>"$STUB_LOG/arm-none-eabi-objcopy.argv"; : >"${@: -1}"'
  # no real serial ports on the test machine: the glob points into the temp dir
  export PORTS_DIR="$BATS_TEST_TMPDIR/dev"
  mkdir -p "$PORTS_DIR"
  # make reports physical paths (/private/var/... on macOS), so compare against those
  P="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/proj"
}

# fwproject 'PARTS' 'more project.mk lines'
fwproject() {
  mkproject "$P" "PROJECT := demo
PARTS := $1
OTA_BUCKET := ota-bucket
STD_PORT_GLOB := $PORTS_DIR/cu.*
$2"
  for k in $FW_KINDS; do cp "$STD_TEMPLATES/kinds/$k.mk" "$P/make/kinds/"; done
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
  keygen) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$P/make/bin/secrets.sh"
  cd "$P"
  # each part started (std_started): the file its kind builds from, so its targets run; arm-gcc and circuitpython
  # tests write their own (CMakeLists.txt or Makefile picks the build system). FW_EMPTY=1 leaves the parts empty.
  local spec name kind dir
  if [ "${FW_EMPTY:-}" != 1 ]; then
    for spec in $1; do
      IFS=: read -r name kind dir <<<"$spec"
      dir="${dir:-$name}"
      case "$kind" in
        zephyr | espidf) mkdir -p "$dir"; [ -e "$dir/CMakeLists.txt" ] || : >"$dir/CMakeLists.txt" ;;
        pio) mkdir -p "$dir"; [ -e "$dir/platformio.ini" ] || : >"$dir/platformio.ini" ;;
      esac
    done
  fi
}

argv() { cat "$STUB_LOG/$1.argv" 2>/dev/null; }

zephyr_proj() {
  fwproject 'firmware:zephyr' 'firmware_BOARD := nrf9151dk/nrf9151/ns
firmware_CHIP := nRF9151_xxAA'
  mkdir -p firmware
  printf 'VERSION_MAJOR = 1\nVERSION_MINOR = 4\nPATCHLEVEL = 2\n' >firmware/VERSION
}

zephyr_built() {
  B="$P/firmware/build/nrf9151dk_nrf9151_ns"
  mkdir -p "$B"
  echo hex >"$B/merged.hex"
  echo zip >"$B/dfu_application.zip"
}

# --- zephyr ----------------------------------------------------------------------------------

@test "all firmware kinds parse together and list their targets in help" {
  fwproject 'firmware:zephyr esp:espidf fw2:pio iface:arm-gcc cpy:circuitpython' 'firmware_BOARD := nrf52840dk/nrf52840'
  run make help
  [ "$status" -eq 0 ]
  for t in firmware-build firmware-flash firmware-keygen firmware-recover esp-fuse-burn esp-fuse-lockdown \
    fw2-test iface-flash cpy-deploy firmware-release; do
    [[ "$output" == *"$t"* ]] || { echo "missing $t"; false; }
  done
}

@test "zephyr build passes BOARD, pristine auto and sysbuild, and signs with the key from the secrets repo" {
  zephyr_proj
  run make firmware-build
  [ "$status" -eq 0 ]
  a="$(argv west)"
  [[ "$a" == *$'build\n--pristine\nauto\n--sysbuild\n-b\nnrf9151dk/nrf9151/ns'* ]]
  [[ "$a" == *"$P/firmware/build/nrf9151dk_nrf9151_ns"* ]]
  [[ "$a" == *"-DSB_CONFIG_BOOTLOADER_MCUBOOT=y"* ]]
  # the {} placeholder became the temporary key file, which is gone afterwards
  key="$(cat "$STUB_LOG/keyfile")"
  [[ "$a" == *"-DSB_CONFIG_BOOT_SIGNATURE_KEY_FILE=\"$key\""* ]]
  [ ! -e "$key" ]
  grep -q '^with-file mcuboot -- west build' "$STUB_LOG/secrets.calls"
}

@test "zephyr BOARD= on the command line wins over the project setting" {
  zephyr_proj
  run make firmware-build BOARD=nrf52840dk/nrf52840
  [ "$status" -eq 0 ]
  [[ "$(argv west)" == *$'-b\nnrf52840dk/nrf52840'* ]]
  [[ "$(argv west)" == *"build/nrf52840dk_nrf52840"* ]]
}

@test "zephyr check builds with warnings as errors and needs no secrets" {
  zephyr_proj
  run make firmware-check
  [ "$status" -eq 0 ]
  [[ "$(argv west)" == *"-DEXTRA_CFLAGS=-Werror"* ]]
  [[ "$(argv west)" != *"CONFIG_COMPILER_WARNINGS_AS_ERRORS"* ]]
  [[ "$(argv west)" == *"build/check-nrf9151dk_nrf9151_ns"* ]]
  [[ "$(argv west)" != *"SIGNATURE_KEY_FILE"* ]]
  [ ! -f "$STUB_LOG/secrets.calls" ]
}

@test "zephyr build refuses without a board" {
  fwproject 'firmware:zephyr'
  run make firmware-build
  [ "$status" -ne 0 ]
  [[ "$output" == *"no board"* ]]
  [ ! -f "$STUB_LOG/west.argv" ]
}

@test "zephyr build refuses when the pinned NCS is not installed" {
  zephyr_proj
  run make firmware-build firmware_NCS=v9.9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"make firmware-setup"* ]]
}

# git that records its argv and, for a clone, makes the clone folder with a west.yml
zephyr_stub_git() {
  stub_cmd git 'printf "%s\n" "$@" >>"$STUB_LOG/git.argv"; printf -- "--\n" >>"$STUB_LOG/git.argv"
if [ "${1:-}" = -c ]; then shift 2; fi
if [ "${1:-}" = clone ]; then d="${@: -1}"; mkdir -p "$d"; : >"$d/west.yml"; fi
exit 0'
}

# A stand-in for the nRF Connect SDK toolchain image: its environment script sets ZEPHYR_SDK_INSTALL_DIR to an SDK
# of version 0.17.0 and leaves a mark each time it is sourced.
zephyr_image() {
  IMG="$BATS_TEST_TMPDIR/image"
  mkdir -p "$IMG/zephyr-sdk"
  echo 0.17.0 >"$IMG/zephyr-sdk/sdk_version"
  printf 'export ZEPHYR_SDK_INSTALL_DIR="%s/zephyr-sdk"\necho sourced >>"%s/sourced"\n' "$IMG" "$IMG" >"$IMG/toolchain-env.sh"
  echo "firmware_TOOLCHAIN_ENV := $IMG/toolchain-env.sh" >>make/project.mk
}

@test "zephyr setup in the nRF Connect SDK toolchain image uses its toolchain and fetches only a shallow NCS" {
  zephyr_proj
  rm -rf "$STD_TOOLCHAINS/ncs-v3.2.1/.std-updated" "$STD_TOOLCHAINS/ncs-v3.2.1/.venv"
  zephyr_image
  zephyr_stub_git
  for t in dtc gperf python3 pip curl; do stub_recorder "$t"; done
  rmdir "$STD_TOOLCHAINS/zephyr-sdk-0.17.4"
  echo 0.17.0 >"$STD_TOOLCHAINS/ncs-v3.2.1/zephyr/SDK_VERSION"
  run env -u ZEPHYR_SDK_INSTALL_DIR CI=true make firmware-setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"toolchain of the nRF Connect SDK image ($IMG/toolchain-env.sh)"* ]]
  [[ "$output" == *"Zephyr SDK 0.17.0 of the image"* ]]
  [[ "$output" != *"asks for Zephyr SDK"* ]]
  [ -f "$IMG/sourced" ]
  ncs="$STD_TOOLCHAINS/ncs-v3.2.1"
  [[ "$(argv git)" == *$'clone\n-q\n--depth\n1\n--branch\nv3.2.1\nhttps://github.com/nrfconnect/sdk-nrf\n'"$ncs/nrf"* ]]
  [[ "$(argv west)" == *$'init\n-l\n'"$ncs/nrf"* ]]
  [[ "$(argv west)" == *$'update\n--narrow\n-o=--depth=1'* ]]
  [ -f "$ncs/.std-updated" ]
  # no venv, no pip, no SDK download
  [ ! -e "$ncs/.venv" ]
  [ ! -f "$STUB_LOG/python3.argv" ]
  [ ! -f "$STUB_LOG/pip.argv" ]
  [ ! -f "$STUB_LOG/curl.argv" ]
  [ ! -e "$STD_TOOLCHAINS/zephyr-sdk-0.17.4" ]
}

@test "zephyr setup in the image warns when NCS asks for another Zephyr SDK than the image has" {
  zephyr_proj
  zephyr_image
  zephyr_stub_git
  for t in dtc gperf; do stub_recorder "$t"; done
  echo 0.17.4 >"$STD_TOOLCHAINS/ncs-v3.2.1/zephyr/SDK_VERSION"
  run env -u ZEPHYR_SDK_INSTALL_DIR make firmware-setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"NCS v3.2.1 asks for Zephyr SDK 0.17.4, the image has 0.17.0"* ]]
}

@test "zephyr setup with a restored NCS workspace (CI cache) fetches nothing" {
  zephyr_proj
  zephyr_image
  zephyr_stub_git
  for t in dtc gperf; do stub_recorder "$t"; done
  mkdir -p "$STD_TOOLCHAINS/ncs-v3.2.1/.west"
  : >"$STD_TOOLCHAINS/ncs-v3.2.1/.std-updated"
  run env -u ZEPHYR_SDK_INSTALL_DIR make firmware-setup
  [ "$status" -eq 0 ]
  [ ! -f "$STUB_LOG/git.argv" ]
  [ ! -f "$STUB_LOG/west.argv" ]
}

@test "zephyr setup outside the image makes a venv with west and the NCS python requirements" {
  zephyr_proj
  rm -rf "$STD_TOOLCHAINS/ncs-v3.2.1/.std-updated" "$STD_TOOLCHAINS/ncs-v3.2.1/.venv"
  echo "firmware_TOOLCHAIN_ENV := $BATS_TEST_TMPDIR/no-image/toolchain-env.sh" >>make/project.mk
  zephyr_stub_git
  for t in dtc gperf; do stub_recorder "$t"; done
  stub_recorder pip
  stub_cmd python3 'printf "%s\n" "$@" >>"$STUB_LOG/python3.argv"; mkdir -p "$3/bin"; cp "$STUBS/west" "$STUBS/pip" "$3/bin/"'
  run env -u ZEPHYR_SDK_INSTALL_DIR make firmware-setup
  [ "$status" -eq 0 ]
  [[ "$output" != *"toolchain of the nRF Connect SDK image"* ]]
  ncs="$STD_TOOLCHAINS/ncs-v3.2.1"
  [[ "$(argv python3)" == *$'-m\nvenv\n'"$ncs/.venv"* ]]
  [[ "$(argv pip)" == *$'install\n-q\n--upgrade\npip\nwest'* ]]
  [[ "$(argv pip)" == *"$ncs/nrf/scripts/requirements.txt"* ]]
  [[ "$(argv west)" == *$'init\n-l\n'"$ncs/nrf"* ]]
  [[ "$output" == *"Zephyr SDK $STD_TOOLCHAINS/zephyr-sdk-0.17.4"* ]]
}

@test "zephyr build in the image sources its environment when BASH_ENV did not" {
  zephyr_proj
  zephyr_image
  run env -u ZEPHYR_SDK_INSTALL_DIR make firmware-check
  [ "$status" -eq 0 ]
  [ -f "$IMG/sourced" ]
  rm -f "$IMG/sourced"
  run env ZEPHYR_SDK_INSTALL_DIR="$IMG/zephyr-sdk" make firmware-check
  [ "$status" -eq 0 ]
  [ ! -f "$IMG/sourced" ]
}

@test "firmware-flash PROBE=jlink uses the jlink runner on the existing build" {
  zephyr_proj
  zephyr_built
  run make firmware-flash PROBE=jlink NOBUILD=1
  [ "$status" -eq 0 ]
  [[ "$(argv west)" == *$'flash\n--skip-rebuild\n-d\n'"$B"$'\n-r\njlink'* ]]
  [ ! -f "$STUB_LOG/probe-rs.argv" ]
}

@test "firmware-flash builds first, then flashes merged.hex with probe-rs by default" {
  zephyr_proj
  zephyr_built
  run make firmware-flash
  [ "$status" -eq 0 ]
  [[ "$(argv west)" == *"--pristine"* ]]
  [[ "$(argv probe-rs)" == *$'download\n--chip\nnRF9151_xxAA\n--verify\n--binary-format\nhex\n'"$B/merged.hex"* ]]
  [[ "$(argv probe-rs)" == *$'reset\n--chip\nnRF9151_xxAA'* ]]
}

@test "probe-rs flash refuses without a chip name" {
  fwproject 'firmware:zephyr' 'firmware_BOARD := nrf52840dk/nrf52840'
  mkdir -p firmware/build/nrf52840dk_nrf52840
  run make firmware-flash NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"firmware_CHIP"* ]]
  [ ! -f "$STUB_LOG/probe-rs.argv" ]
}

@test "erase without CONFIRM refuses and touches no probe" {
  zephyr_proj
  run make firmware-erase
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=erase"* ]]
  run make firmware-erase CONFIRM=production
  [ "$status" -ne 0 ]
  run make firmware-recover
  [ "$status" -ne 0 ]
  [ ! -f "$STUB_LOG/probe-rs.argv" ]
  [ ! -f "$STUB_LOG/nrfutil.argv" ]
}

@test "CONFIRM=erase in the environment is not enough" {
  zephyr_proj
  CONFIRM=erase run make firmware-erase
  [ "$status" -ne 0 ]
  [ ! -f "$STUB_LOG/probe-rs.argv" ]
}

@test "erase and recover with CONFIRM=erase use the probe" {
  zephyr_proj
  run make firmware-erase CONFIRM=erase
  [ "$status" -eq 0 ]
  [[ "$(argv probe-rs)" == *$'erase\n--chip\nnRF9151_xxAA'* ]]
  run make firmware-recover CONFIRM=erase PROBE=nrfutil
  [ "$status" -eq 0 ]
  [[ "$(argv nrfutil)" == *$'device\nrecover'* ]]
}

@test "recover runs the project's <part>_RECOVER hook when set" {
  zephyr_proj
  echo 'firmware_RECOVER = echo HOOK-RECOVER > $(CURDIR)/recover.out' >>make/project.mk
  run make firmware-recover CONFIRM=erase
  [ "$status" -eq 0 ]
  [ "$(cat recover.out)" = HOOK-RECOVER ]
  [ ! -f "$STUB_LOG/probe-rs.argv" ]
}

@test "keygen never overwrites an existing key" {
  zephyr_proj
  mkdir -p "$SECRETS_DIR/demo/keys"
  echo old >"$SECRETS_DIR/demo/keys/mcuboot.sops"
  run make firmware-keygen
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
  [ ! -f "$STUB_LOG/secrets.calls" ]
  [ "$(cat "$SECRETS_DIR/demo/keys/mcuboot.sops")" = old ]
}

@test "keygen creates a missing key through secrets.sh keygen with the right type" {
  zephyr_proj
  run make firmware-keygen
  [ "$status" -eq 0 ]
  grep -qx 'keygen mcuboot --type mcuboot-ecdsa-p256' "$STUB_LOG/secrets.calls"
}

@test "release with ENV=production without CONFIRM refuses and uploads nothing" {
  zephyr_proj
  zephyr_built
  run make firmware-release ENV=production NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=production"* ]]
  [ ! -f "$STUB_LOG/npx.argv" ]
  [ ! -f "$STUB_LOG/secrets.calls" ]
}

@test "release refuses ENV=local" {
  zephyr_proj
  zephyr_built
  run make firmware-release NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENV=staging or ENV=production"* ]]
  [ ! -f "$STUB_LOG/npx.argv" ]
}

@test "release uploads <ver>/ and latest/ under secrets.sh exec, stable/ with PROMOTE=1" {
  zephyr_proj
  zephyr_built
  run make firmware-release ENV=staging NOBUILD=1 PROMOTE=1
  [ "$status" -eq 0 ]
  grep -q '^exec --env staging -- bash -c' "$STUB_LOG/secrets.calls"
  a="$(argv npx)"
  [[ "$a" == *"ota-bucket/demo/firmware/staging/1.4.2/dfu_application.zip"* ]]
  [[ "$a" == *"ota-bucket/demo/firmware/staging/latest/dfu_application.zip"* ]]
  [[ "$a" == *"ota-bucket/demo/firmware/staging/stable/dfu_application.zip"* ]]
  [[ "$a" == *"$B/dfu_application.zip"* ]]
}

@test "in a tag pipeline release acts only on its own <part>-v* tag" {
  zephyr_proj
  zephyr_built
  CI_COMMIT_TAG=hardware-v3 run make firmware-release ENV=staging NOBUILD=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a firmware release"* ]]
  [ ! -f "$STUB_LOG/npx.argv" ]
  CI_COMMIT_TAG=firmware-v1.4.2 run make firmware-release ENV=staging NOBUILD=1
  [ "$status" -eq 0 ]
  [[ "$(argv npx)" == *"1.4.2/dfu_application.zip"* ]]
}

@test "release with ENV=production CONFIRM=production goes through" {
  zephyr_proj
  zephyr_built
  run make firmware-release ENV=production CONFIRM=production NOBUILD=1
  [ "$status" -eq 0 ]
  [[ "$(argv npx)" == *"demo/firmware/production/1.4.2/dfu_application.zip"* ]]
  [[ "$(argv npx)" != *"stable/"* ]]
}

@test "no OTA bucket (no Cloudflare): every firmware kind's release skips the publish with exit 0 and help leaves it out" {
  fwproject 'firmware:zephyr esp:espidf fw2:pio iface:arm-gcc cpy:circuitpython' 'firmware_BOARD := nrf52840dk/nrf52840
OTA_BUCKET :='
  for p in firmware esp fw2 iface cpy; do
    run make "$p-release" ENV=production CONFIRM=production
    [ "$status" -eq 0 ] || { echo "$p: $output"; false; }
    [ "$output" = "> $p: no OTA bucket (no Cloudflare in this project): firmware publish skipped" ]
  done
  # nothing built, nothing unlocked, nothing uploaded; the root release fans out to the same skip
  [ ! -f "$STUB_LOG/west.argv" ] && [ ! -f "$STUB_LOG/npx.argv" ] && [ ! -f "$STUB_LOG/secrets.calls" ]
  run make release ENV=production CONFIRM=production
  [ "$status" -eq 0 ]
  [ ! -f "$STUB_LOG/npx.argv" ]
  run make help
  [ "$status" -eq 0 ]
  for p in firmware esp fw2 iface cpy; do
    [[ "$output" != *"$p-release "* ]] || { echo "$p-release is listed"; false; }
    [[ "$output" == *"$p-release-assets"* ]]
  done
  run make help ALL=1
  [[ "$output" == *"firmware-release "* ]]
}

@test "a part's own <part>_OTA_BUCKET publishes it without the project's OTA_BUCKET, and help lists it" {
  zephyr_proj
  zephyr_built
  printf 'OTA_BUCKET :=\nfirmware_OTA_BUCKET := own-bucket\n' >>make/project.mk
  run make firmware-release ENV=staging NOBUILD=1
  [ "$status" -eq 0 ]
  [[ "$(argv npx)" == *"own-bucket/demo/firmware/staging/1.4.2/dfu_application.zip"* ]]
  run make help
  [[ "$output" == *"firmware-release "* ]]
}

@test "provision needs SERIAL and runs the <part>_PROVISION hook with SERIAL exported" {
  zephyr_proj
  echo 'firmware_PROVISION = echo "provisioned $$SERIAL" > $(CURDIR)/prov.out' >>make/project.mk
  run make firmware-provision
  [ "$status" -ne 0 ]
  [[ "$output" == *"SERIAL= is required"* ]]
  run make firmware-provision 'SERIAL=a;rm'
  [ "$status" -ne 0 ]
  run make firmware-provision SERIAL=CG-0042
  [ "$status" -eq 0 ]
  [ "$(cat prov.out)" = "provisioned CG-0042" ]
}

@test "version reads the Zephyr VERSION file" {
  zephyr_proj
  run make firmware-version
  [ "$status" -eq 0 ]
  [ "$output" = "firmware 1.4.2" ]
}

@test "doctor names what is missing and fails" {
  fwproject 'firmware:zephyr' 'firmware_NCS := v9.9.9'
  run make firmware-doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"NCS v9.9.9 missing: make firmware-setup"* ]]
  [[ "$output" == *"no board"* ]]
  [[ "$output" == *"signing key mcuboot missing"* ]]
}

# --- ports --------------------------------------------------------------------------------------

@test "monitor port detection: none and several are errors that name PORT=" {
  zephyr_proj
  run make firmware-monitor
  [ "$status" -ne 0 ]
  [[ "$output" == *"no serial port found"* ]]
  : >"$PORTS_DIR/cu.usbmodem1"
  : >"$PORTS_DIR/cu.usbmodem2"
  run make firmware-monitor
  [ "$status" -ne 0 ]
  [[ "$output" == *"several serial ports"* ]]
  [[ "$output" == *"cu.usbmodem1"* ]]
  [ ! -f "$STUB_LOG/tio.argv" ]
}

@test "monitor uses the only port and logs to build/monitor.log" {
  zephyr_proj
  : >"$PORTS_DIR/cu.usbmodem1"
  stub_cmd script 'printf "%s\n" "$@" >"$STUB_LOG/script.argv"'
  run make firmware-monitor
  [ "$status" -eq 0 ]
  a="$(cat "$STUB_LOG/script.argv")"
  [[ "$a" == *"$P/firmware/build/monitor.log"* ]]
  [[ "$a" == *$'tio\n-b\n115200\n'"$PORTS_DIR/cu.usbmodem1"* ]]
}

# --- espidf -------------------------------------------------------------------------------------

esp_proj() {
  fwproject 'esp:espidf' "$1"
  mkdir -p esp
  echo 2.1.0 >esp/version.txt
}

@test "espidf build passes the target, its build dir and its sdkconfig" {
  esp_proj
  run make esp-build TARGET=esp32s3
  [ "$status" -eq 0 ]
  a="$(argv idf.py)"
  [[ "$a" == *$'-B\n'"$P/esp/build/esp32s3"* ]]
  [[ "$a" == *"SDKCONFIG=$P/esp/sdkconfig.esp32s3"* ]]
  [[ "$a" == *"IDF_TARGET=esp32s3"* ]]
  [[ "$a" == *$'\nbuild\n'* ]]
}

@test "espidf flash refuses an encrypted part on a fresh chip without FIRST=1" {
  esp_proj 'esp_FLASH_ENCRYPTION := 1'
  mkdir -p esp/build/esp32c6
  stub_cmd python 'echo "SPI_BOOT_CRYPT_CNT (BLOCK0)   Enables flash encryption = Disable (0b000) R/W"; echo "KEY_PURPOSE_0 (BLOCK0)  = USER (0) R/W"'
  : >"$PORTS_DIR/cu.usbmodem1"
  run make esp-flash NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"FIRST=1"* ]]
  [[ "$(argv idf.py)" != *"flash"* ]]
  run make esp-flash NOBUILD=1 FIRST=1
  [ "$status" -eq 0 ]
  [[ "$(argv idf.py)" == *$'bootloader-flash\nflash'* ]]
}

@test "espidf flash refuses FIRST=1 on a half burned chip and uses encrypted-flash once encryption is on" {
  esp_proj 'esp_FLASH_ENCRYPTION := 1'
  mkdir -p esp/build/esp32c6
  : >"$PORTS_DIR/cu.usbmodem1"
  stub_cmd python 'echo "SPI_BOOT_CRYPT_CNT (BLOCK0) = Disable (0b000) R/W"; echo "KEY_PURPOSE_1 (BLOCK0) = XTS_AES_128_KEY (4) R/-"'
  run make esp-flash NOBUILD=1 FIRST=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"interrupted first boot"* ]]
  stub_cmd python 'echo "SPI_BOOT_CRYPT_CNT (BLOCK0) = Enable (0b001) R/W"; echo "KEY_PURPOSE_1 (BLOCK0) = XTS_AES_128_KEY (4) R/-"'
  run make esp-flash NOBUILD=1
  [ "$status" -eq 0 ]
  [[ "$(argv idf.py)" == *"encrypted-flash"* ]]
}

@test "espidf eFuse burns need CONFIRM=fuse and erase needs CONFIRM=erase" {
  esp_proj
  stub_recorder python
  : >"$PORTS_DIR/cu.usbmodem1"
  run make esp-fuse-burn EFUSE='DIS_USB_JTAG 1'
  [ "$status" -ne 0 ]
  run make esp-fuse-burn EFUSE='DIS_USB_JTAG 1' CONFIRM=erase
  [ "$status" -ne 0 ]
  run make esp-fuse-lockdown
  [ "$status" -ne 0 ]
  run make esp-erase
  [ "$status" -ne 0 ]
  [ ! -f "$STUB_LOG/python.argv" ]
  run make esp-fuse-burn EFUSE='DIS_USB_JTAG 1' CONFIRM=fuse
  [ "$status" -eq 0 ]
  [[ "$(argv python)" == *$'--do-not-confirm\nburn_efuse\nDIS_USB_JTAG\n1'* ]]
  run make esp-fuse-lockdown CONFIRM=fuse
  [ "$status" -ne 0 ]
  [[ "$output" == *"esp_LOCKDOWN_EFUSES"* ]]
}

@test "espidf keygen asks for a secure boot v2 key" {
  esp_proj
  run make esp-keygen
  [ "$status" -eq 0 ]
  grep -qx 'keygen secure-boot --type espsecure-v2' "$STUB_LOG/secrets.calls"
}

# --- pio ----------------------------------------------------------------------------------------

@test "pio build and check use the env; check runs pio check and the native tests" {
  fwproject 'fw:pio' 'fw_PIO_ENV := esp32dev'
  mkdir -p fw
  printf '[env:esp32dev]\nboard = esp32dev\n[env:native]\nplatform = native\n' >fw/platformio.ini
  run make fw-build
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == *$'run\n-d\n'"$P/fw"$'\n-e\nesp32dev'* ]]
  run make fw-check
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == *$'check\n-d\n'"$P/fw"* ]]
  [[ "$(argv pio)" == *$'test\n-d\n'"$P/fw"$'\n-e\nnative'* ]]
}

@test "pio flash uploads to the only port, PIO_ENV= on the command line wins" {
  fwproject 'fw:pio' 'fw_PIO_ENV := esp32dev'
  mkdir -p fw
  : >"$PORTS_DIR/cu.usbserial-1"
  run make fw-flash PIO_ENV=esp32s3
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == *$'-e\nesp32s3\n-t\nupload\n--upload-port\n'"$PORTS_DIR/cu.usbserial-1"* ]]
}

# One env per board: default_envs = rev3, rev4 is one image per board revision, and the rev-4 image
# on a rev-3 board overloads its LDO. Board targets refuse unless exactly one env is selected.
pio_two_revs() {
  fwproject 'fw:pio' "${1:-}"
  mkdir -p fw
  printf '[platformio]\ndefault_envs = rev3, rev4\n\n[env]\nframework = arduino\n[env:rev3]\nboard = b3\n[env:rev4]\nboard = b4\n[env:native]\nplatform = native\n' >fw/platformio.ini
  : >"$PORTS_DIR/cu.usbserial-1"
  stub_cmd script 'printf "%s\n" "$@" >"$STUB_LOG/script.argv"'
}

@test "pio board targets refuse when default_envs names several envs and say how to pick one" {
  pio_two_revs
  local t
  rm -f "$STUB_LOG/script.argv"
  for t in fw-flash 'fw-erase CONFIRM=erase' fw-monitor fw-debug 'fw-provision SERIAL=CD-1'; do
    rm -f "$STUB_LOG/pio.argv"
    # shellcheck disable=SC2086
    run make $t
    [ "$status" -ne 0 ] || { echo "$t did not refuse"; return 1; }
    [[ "$output" == *"${t%% *} talks to one board but fw/platformio.ini selects 2 envs (rev3 rev4)"* ]] || { echo "$t: $output"; return 1; }
    [[ "$output" == *"PIO_ENV=<env>"* && "$output" == *"fw_PIO_ENV in make/project.mk"* ]]
    [ ! -f "$STUB_LOG/pio.argv" ] || { echo "$t ran pio: $(argv pio)"; return 1; }
    [ ! -f "$STUB_LOG/script.argv" ] || { echo "$t ran the monitor"; return 1; }
  done
  # the root verb fans out to the same refusal
  run make flash
  [ "$status" -ne 0 ]
  [ ! -f "$STUB_LOG/pio.argv" ]
}

@test "pio build, check and clean still run every default env" {
  pio_two_revs
  run make fw-build
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == $'run\n-d\n'"$P/fw"$'\n--' ]]
  rm -f "$STUB_LOG/pio.argv"
  run make fw-clean
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" != *$'\n-e\n'* ]]
}

@test "pio board targets run for the env PIO_ENV= or <part>_PIO_ENV picks" {
  pio_two_revs
  run make fw-flash PIO_ENV=rev3
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == *$'-e\nrev3\n-t\nupload\n--upload-port\n'"$PORTS_DIR/cu.usbserial-1"* ]]
  [[ "$(argv pio)" != *rev4* ]]
  rm -f "$STUB_LOG/pio.argv"
  run make fw-erase CONFIRM=erase PIO_ENV=rev4
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == $'run\n-d\n'"$P/fw"$'\n-e\nrev4\n-t\nerase\n--' ]]
  rm -f "$STUB_LOG/pio.argv"
  run make fw-monitor PIO_ENV=rev3
  [ "$status" -eq 0 ]
  [[ "$(cat "$STUB_LOG/script.argv")" == *$'pio\ndevice\nmonitor\n-d\n'"$P/fw"$'\n-e\nrev3\n-p\n'"$PORTS_DIR/cu.usbserial-1"* ]]
  rm -f "$STUB_LOG/pio.argv"
  run make fw-debug PIO_ENV=rev3
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == *$'debug\n-d\n'"$P/fw"$'\n-e\nrev3\n'* ]]
  # erase still needs CONFIRM before anything else
  rm -f "$STUB_LOG/pio.argv"
  run make fw-erase PIO_ENV=rev3
  [ "$status" -ne 0 ]
  [ ! -f "$STUB_LOG/pio.argv" ]
  # project.mk setting
  echo 'fw_PIO_ENV := rev4' >>make/project.mk
  rm -f "$STUB_LOG/pio.argv"
  run make fw-flash
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == *$'-e\nrev4\n-t\nupload'* ]]
  # several envs in PIO_ENV are refused too
  rm -f "$STUB_LOG/pio.argv"
  run make fw-flash 'PIO_ENV=rev3,rev4'
  [ "$status" -ne 0 ]
  [[ "$output" == *"names several envs"* ]]
  [ ! -f "$STUB_LOG/pio.argv" ]
}

@test "pio provision runs for one env and hands it to the hook and to the flash fallback" {
  pio_two_revs
  run make fw-provision SERIAL=CD-1 PIO_ENV=rev3
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == *$'-e\nrev3\n-t\nupload'* ]]
  [[ "$(argv pio)" != *rev4* ]]
  echo 'fw_PROVISION = echo "$$SERIAL $$PIO_ENV" > $(CURDIR)/prov.out' >>make/project.mk
  run make fw-provision SERIAL=CD-2 PIO_ENV=rev4
  [ "$status" -eq 0 ]
  [ "$(cat prov.out)" = "CD-2 rev4" ]
}

@test "pio board targets take the only env: one default_envs, or one [env:*] without default_envs" {
  fwproject 'fw:pio'
  mkdir -p fw
  : >"$PORTS_DIR/cu.usbserial-1"
  # default_envs with continuation lines, comments and one name
  printf '[platformio]\nsrc_dir = src ; comment\ndefault_envs =\n    rev4 ; the new board\n# rev3\nlib_dir = lib\n[env:rev3]\n[env:rev4]\n' >fw/platformio.ini
  run make fw-flash
  [ "$status" -eq 0 ]
  [[ "$output" == *"fw-flash: env rev4 (the only one in fw/platformio.ini)"* ]]
  [[ "$(argv pio)" == *$'-e\nrev4\n-t\nupload'* ]]
  # continuation lines that add a second env: refused
  printf '[platformio]\ndefault_envs =\n    rev3,\n    rev4\n[env:rev3]\n[env:rev4]\n' >fw/platformio.ini
  rm -f "$STUB_LOG/pio.argv"
  run make fw-flash
  [ "$status" -ne 0 ]
  [[ "$output" == *"selects 2 envs (rev3 rev4)"* ]]
  [ ! -f "$STUB_LOG/pio.argv" ]
  # no default_envs: the [env:*] sections count ([env] is not one)
  printf '[env]\nframework = arduino\n[env:only]\nboard = x\n' >fw/platformio.ini
  run make fw-flash
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == *$'-e\nonly\n-t\nupload'* ]]
  printf '[env:a]\n[env:native]\n' >fw/platformio.ini
  rm -f "$STUB_LOG/pio.argv"
  run make fw-flash
  [ "$status" -ne 0 ]
  [[ "$output" == *"selects 2 envs (a native)"* ]]
  [ ! -f "$STUB_LOG/pio.argv" ]
  # PLATFORMIO_DEFAULT_ENVS overrides default_envs, as it does for pio
  printf '[platformio]\ndefault_envs = a\n[env:a]\n[env:b]\n' >fw/platformio.ini
  run env PLATFORMIO_DEFAULT_ENVS=a,b make fw-flash
  [ "$status" -ne 0 ]
  [[ "$output" == *"PLATFORMIO_DEFAULT_ENVS selects 2 envs (a b)"* ]]
  # no platformio.ini and no env: refused
  rm -f fw/platformio.ini "$STUB_LOG/pio.argv"
  run make fw-flash
  [ "$status" -ne 0 ]
  [ ! -f "$STUB_LOG/pio.argv" ]
}

@test "pio: every board target resolves its one env on the line of its action" {
  local mk="$STD_TEMPLATES/kinds/pio.mk" h
  for h in pio_flash pio_monitor pio_debug pio_provision pio_board_run; do
    grep -qE "^$h = .*pio_one_env" "$mk" || { echo "$h does not start with pio_one_env"; return 1; }
  done
  grep -qF '@$$(call std_confirm,erase) && { $$(call pio_board_run,$(1),$(2),$(1)-erase,-t erase); }' "$mk"
  grep -qF '@$$(call pio_provision,$(1),$(2))' "$mk"
  # no board target is left on the all-envs pio_e
  ! grep -E '^pio_(flash|monitor|debug|provision|board_run) ' "$mk" | grep -qF 'call pio_e,'
}

# --- arm-gcc ------------------------------------------------------------------------------------

@test "arm-gcc builds through the part Makefile and flashes the bin with dfu-util" {
  fwproject 'iface:arm-gcc' 'iface_DFU_ID := 1209:da42,0483:df11'
  mkdir -p iface/build
  printf '.PHONY: build\nbuild:\n\t@echo "BUILT with $(PREFIX)" > build.out\n\t@touch build/iface.elf\n' >iface/Makefile
  run make iface-flash PROBE=dfu
  [ "$status" -eq 0 ]
  [ "$(cat iface/build.out)" = "BUILT with arm-none-eabi-" ]
  [[ "$(argv dfu-util)" == *$'-d\n1209:da42,0483:df11\n-a\n0\n-s\n0x08000000:leave\n-D\n'"$P/iface/build/iface.bin"* ]]
}

@test "arm-gcc erase refuses without CONFIRM and dfu has no erase" {
  fwproject 'iface:arm-gcc' 'iface_PROBE := dfu'
  run make iface-erase
  [ "$status" -ne 0 ]
  run make iface-erase CONFIRM=erase
  [ "$status" -ne 0 ]
  [[ "$output" == *"no erase"* ]]
  run make iface-erase CONFIRM=erase PROBE=stlink
  [ "$status" -eq 0 ]
  [[ "$(argv st-flash)" == *"erase"* ]]
}

# --- circuitpython ------------------------------------------------------------------------------

@test "circuitpython builds in Docker for the board and deploy copies src to the volume" {
  fwproject 'cpy:circuitpython' "cpy_BOARD := pianni_orphea
cpy_VOLUME := $BATS_TEST_TMPDIR/CIRCUITPY"
  mkdir -p cpy/src cpy/boards/pianni_orphea cpy/build
  echo 'print(1)' >cpy/src/code.py
  : >cpy/build/firmware.bin
  run make cpy-build
  [ "$status" -eq 0 ]
  a="$(argv docker)"
  [[ "$a" == *$'run\n--rm\n-v\n'"$P/cpy/build:/out"* ]]
  [[ "$a" == *"$P/cpy/boards/pianni_orphea:/circuitpython/ports/espressif/boards/pianni_orphea"* ]]
  [[ "$a" == *"BOARD=pianni_orphea"* ]]
  # the image's own user can write build/ on Linux (v35): the folder is open to everyone
  [[ "$(stat -f %Lp cpy/build 2>/dev/null || stat -c %a cpy/build)" == 777 ]]
  run make cpy-deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"not mounted"* ]]
  mkdir -p "$BATS_TEST_TMPDIR/CIRCUITPY"
  run make cpy-deploy
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/CIRCUITPY/code.py")" = 'print(1)' ]
}

@test "the root deploy verb never runs the circuitpython copy" {
  fwproject 'cpy:circuitpython' "cpy_BOARD := x
cpy_VOLUME := $BATS_TEST_TMPDIR/CIRCUITPY"
  run make -pn 2>/dev/null
  [[ "$output" != *"STD_VERB_deploy := cpy-deploy"* ]]
  [[ "$output" != *"STD_VERB_deploy = cpy-deploy"* ]]
}

# --- setup on demand (std_ready) ---------------------------------------------------------------

@test "zephyr: a part whose NCS workspace is not set up runs setup before check, once; the image toolchain counts as ready" {
  zephyr_proj
  zephyr_image
  zephyr_stub_git
  for t in dtc gperf; do stub_recorder "$t"; done
  ncs="$STD_TOOLCHAINS/ncs-v3.2.1"
  rm -rf "$ncs/.std-updated" "$ncs/.venv"
  run env -u ZEPHYR_SDK_INSTALL_DIR make firmware-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"> firmware: not set up yet, running make firmware-setup first"* ]]
  [[ "$(argv west)" == *$'update\n--narrow\n-o=--depth=1'*$'build\n'* ]]
  [ -f "$ncs/.std-updated" ]
  rm -f "$STUB_LOG/west.argv" "$STUB_LOG/git.argv"
  run env -u ZEPHYR_SDK_INSTALL_DIR make firmware-build
  [ "$status" -eq 0 ]
  [[ "$output" != *"not set up yet"* ]]
  [[ "$(argv west)" == *$'build\n'* ]]
  [[ "$(argv west)" != *$'update\n'* ]]
  [ ! -f "$STUB_LOG/git.argv" ]
  # setup, doctor, clean and version are never chained, and erase (a probe, CONFIRM) is not either
  rm -f "$ncs/.std-updated"
  for t in doctor clean version erase; do
    run env -u ZEPHYR_SDK_INSTALL_DIR make "firmware-$t"
    [[ "$output" != *"not set up yet"* ]]
  done
  [ ! -f "$STUB_LOG/git.argv" ]
}

@test "zephyr outside the image is ready only with the venv's west, its requirements and the pinned SDK" {
  zephyr_proj
  ncs="$STD_TOOLCHAINS/ncs-v3.2.1"
  rm -rf "$ncs/.venv"
  echo "firmware_TOOLCHAIN_ENV := $BATS_TEST_TMPDIR/no-image/toolchain-env.sh" >>make/project.mk
  # make -n prints the ready recipe too: count only the message it prints when it sets up
  ready() { make -n firmware-size 2>&1 | grep -c '^> firmware: not set up yet' || true; }
  mkdir -p "$ncs/.venv/bin"
  : >"$ncs/.std-updated"
  [ "$(ready)" -eq 1 ]
  cp "$STUBS/west" "$ncs/.venv/bin/west"
  [ "$(ready)" -eq 0 ]
  cp "$STUBS/west" "$ncs/.venv/bin/pip"
  [ "$(ready)" -eq 1 ]
  : >"$ncs/.venv/.std-requirements"
  [ "$(ready)" -eq 0 ]
  rmdir "$STD_TOOLCHAINS/zephyr-sdk-0.17.4"
  [ "$(ready)" -eq 1 ]
  ZEPHYR_SDK_INSTALL_DIR="$STD_TOOLCHAINS" run make -n firmware-size
  [[ "$output" != *"> firmware: not set up yet"* ]]
}

@test "pio: a fresh part installs its packages before build, once, and again after platformio.ini changes" {
  fwproject 'fw:pio' 'fw_PIO_ENV := esp32dev'
  rm -rf fw/.pio
  mkdir -p fw
  printf '[env:esp32dev]\nboard = esp32dev\n' >fw/platformio.ini
  run make fw-build
  [ "$status" -eq 0 ]
  [[ "$output" == *"> fw: not set up yet, running make fw-setup first"* ]]
  [[ "$(argv pio)" == $'pkg\ninstall\n-d\n'"$P/fw"$'\n-e\nesp32dev\n--\nrun\n'* ]]
  [ -f fw/.pio/.std-setup ]
  rm -f "$STUB_LOG/pio.argv"
  run make fw-check
  [ "$status" -eq 0 ]
  [[ "$output" != *"not set up yet"* ]]
  [[ "$(argv pio)" != *$'pkg\n'* ]]
  touch -t 200001010000 fw/.pio/.std-setup
  rm -f "$STUB_LOG/pio.argv"
  run make fw-size
  [ "$status" -eq 0 ]
  [[ "$(argv pio)" == $'pkg\ninstall\n'* ]]
  # never chained: setup, doctor, clean, distclean, version
  touch -t 200001010000 fw/.pio/.std-setup
  for t in doctor clean distclean version; do
    rm -f "$STUB_LOG/pio.argv"
    run make "fw-$t"
    [[ "$output" != *"not set up yet"* ]]
    [[ "$(argv pio)" != *$'pkg\n'* ]]
  done
  rm -f "$STUB_LOG/pio.argv"
  run make fw-setup
  [ "$status" -eq 0 ]
  [[ "$output" != *"not set up yet"* ]]
  [ "$(grep -c '^pkg$' "$STUB_LOG/pio.argv")" -eq 1 ]
}

@test "arm-gcc, whose setup only checks the cross compiler, chains no setup" {
  fwproject 'mcu:arm-gcc'
  mkdir -p mcu
  run make -n mcu-build
  [[ "$output" != *"not set up yet"* ]]
  [[ "$output" != *"mcu-setup"* ]]
}

@test "a zephyr part not started yet (no CMakeLists.txt): setup, check and build skip with exit 0 and run no west; flash and release refuse" {
  FW_EMPTY=1 zephyr_proj
  [ ! -e firmware/CMakeLists.txt ]
  # not set up either: a started part would run setup first (std_ready), this one does not
  rm -f "$STD_TOOLCHAINS/ncs-v3.2.1/.std-updated"
  for v in setup check build; do
    run make "firmware-$v"
    [ "$status" -eq 0 ]
    [[ "$output" == *"> firmware: not started yet (no CMakeLists.txt in firmware): $v skipped"* ]]
    [[ "$output" != *"not set up yet"* ]]
  done
  [ ! -f "$STUB_LOG/west.argv" ]
  run make firmware-doctor
  [[ "$output" == *"warn"*"firmware: not started yet (no CMakeLists.txt in firmware)"* ]]
  run make firmware-flash
  [ "$status" -ne 0 ]
  [[ "$output" == *"firmware: not started yet (no CMakeLists.txt in firmware): nothing to flash"* ]]
  run make firmware-release ENV=staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to release"* ]]
  run make firmware-release-assets
  [ "$status" -ne 0 ]
  [[ "$output" == *"firmware: not started yet (no CMakeLists.txt in firmware): nothing to release"* ]]
  [ ! -f "$STUB_LOG/west.argv" ] && [ ! -f "$STUB_LOG/npx.argv" ] && [ ! -d firmware/release ]
}

@test "the other firmware kinds skip check, test and build of a part not started yet and refuse its flash" {
  FW_EMPTY=1 fwproject 'esp:espidf fw:pio iface:arm-gcc cpy:circuitpython' 'cpy_BOARD := adafruit_feather_esp32s3'
  rm -f "$P/fw/platformio.ini"
  for p in esp:CMakeLists.txt fw:platformio.ini "iface:CMakeLists.txt or Makefile" cpy:src; do
    part="${p%%:*}" what="${p#*:}"
    for v in check build; do
      run make "$part-$v"
      [ "$status" -eq 0 ]
      [[ "$output" == *"> $part: not started yet (no $what in $part): $v skipped"* ]]
    done
    run make "$part-flash" NOBUILD=1
    [ "$status" -ne 0 ]
    [[ "$output" == *"$part: not started yet (no $what in $part): nothing to flash"* ]]
  done
  run make fw-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"> fw: not started yet (no platformio.ini in fw): test skipped"* ]]
  for t in idf.py pio cmake arm-none-eabi-gcc docker; do [ ! -f "$STUB_LOG/$t.argv" ] || { echo "$t ran"; false; }; done
}

# --- zephyr: upstream Zephyr, Simplicity Commander, energy profiling --------------------------

@test "zephyr upstream: <part>_ZEPHYR sets up west init -m zephyr --mr <ver> in toolchains/zephyr-<ver> with only zephyr's requirements" {
  zephyr_proj
  echo 'firmware_ZEPHYR := v4.3.0' >>make/project.mk
  echo "firmware_TOOLCHAIN_ENV := $BATS_TEST_TMPDIR/no-image/toolchain-env.sh" >>make/project.mk
  zephyr_stub_git
  for t in dtc gperf; do stub_recorder "$t"; done
  stub_recorder pip
  stub_cmd python3 'printf "%s\n" "$@" >>"$STUB_LOG/python3.argv"; mkdir -p "$3/bin"; cp "$STUBS/west" "$STUBS/pip" "$3/bin/"'
  ws="$STD_TOOLCHAINS/zephyr-v4.3.0"
  run env -u ZEPHYR_SDK_INSTALL_DIR make firmware-setup
  [ "$status" -eq 0 ]
  [[ "$(argv west)" == *$'init\n-m\nhttps://github.com/zephyrproject-rtos/zephyr\n--mr\nv4.3.0\n'"$ws"$'\n'* ]]
  [[ "$(argv west)" == *$'update\n--narrow\n-o=--depth=1'* ]]
  [[ "$(argv west)" != *$'init\n-l'* ]]
  [ ! -f "$STUB_LOG/git.argv" ]
  [[ "$(argv pip)" == *"$ws/zephyr/scripts/requirements.txt"* ]]
  [[ "$(argv pip)" != *"nrf/scripts"* ]]
  [ -f "$ws/.std-updated" ]
  [ ! -e "$STD_TOOLCHAINS/ncs-v3.2.1/.west" ]
  [[ "$output" == *"firmware: Zephyr v4.3.0 in $ws"* ]]
}

@test "zephyr upstream: build, doctor and help use the Zephyr workspace; NCS and ZEPHYR together are refused" {
  zephyr_proj
  echo 'firmware_ZEPHYR := v4.3.0' >>make/project.mk
  ws="$STD_TOOLCHAINS/zephyr-v4.3.0"
  # the workspace set up (std_ready), so nothing here runs a real setup
  mkdir -p "$ws/zephyr" "$ws/.venv/bin"
  : >"$ws/zephyr/zephyr-env.sh"
  : >"$ws/.std-updated"
  cp "$STUBS/west" "$ws/.venv/bin/west"
  rm -f "$STUB_LOG/west.argv"
  run make firmware-build
  [ "$status" -eq 0 ]
  [[ "$output" != *"not set up yet"* ]]
  [[ "$(argv west)" == *$'build\n--pristine\nauto'* ]]
  run make firmware-doctor
  [[ "$output" == *"firmware: zephyr, Zephyr v4.3.0, Zephyr SDK 0.17.4"* ]]
  [[ "$output" == *"Zephyr $ws"* ]]
  run make help
  [[ "$output" == *"Install Zephyr v4.3.0 and Zephyr SDK"* ]]
  echo 'firmware_NCS := v3.2.1' >>make/project.mk
  run make firmware-build
  [ "$status" -ne 0 ]
  [[ "$output" == *"set firmware_ZEPHYR (upstream Zephyr) or firmware_NCS (nRF Connect SDK) in make/project.mk, not both"* ]]
}

@test "zephyr upstream: update lists Zephyr tags and pins TO= into <part>_ZEPHYR" {
  zephyr_proj
  echo 'firmware_ZEPHYR := v4.2.0' >>make/project.mk
  stub_cmd git 'printf "%s\n" "$@" >>"$STUB_LOG/git.argv"; [ "$1" = ls-remote ] && printf "x\trefs/tags/v4.3.0\nx\trefs/tags/v4.2.0\nx\trefs/tags/v4.3.0-rc1\n"; exit 0'
  run make firmware-update
  [ "$status" -eq 0 ]
  [[ "$(argv git)" == *"https://github.com/zephyrproject-rtos/zephyr"* ]]
  [[ "$output" == *"v4.3.0"* ]]
  [[ "$output" != *"rc1"* ]]
  # the v4.3.0 workspace already there, so the setup that follows the pin fetches nothing
  ws="$STD_TOOLCHAINS/zephyr-v4.3.0"
  mkdir -p "$ws/.west" "$ws/.venv/bin"
  : >"$ws/.std-updated"
  cp "$STUBS/west" "$ws/.venv/bin/west"
  for t in dtc gperf; do stub_recorder "$t"; done
  run env -u ZEPHYR_SDK_INSTALL_DIR make firmware-update TO=v4.3.0 firmware_TOOLCHAIN_ENV=/nonexistent/toolchain-env.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"firmware: Zephyr v4.3.0 in $ws"* ]]
  grep -q '^firmware_ZEPHYR = v4.3.0' make/project.mk || grep -q '^firmware_ZEPHYR := v4.3.0' make/project.mk
  ! grep -q '^firmware_NCS' make/project.mk
}

@test "zephyr PROBE=commander flashes through west's silabs_commander runner and erases with commander" {
  zephyr_proj
  zephyr_built
  stub_recorder commander
  run make firmware-flash PROBE=commander NOBUILD=1
  [ "$status" -eq 0 ]
  [[ "$(argv west)" == *$'flash\n--skip-rebuild\n-d\n'"$B"$'\n-r\nsilabs_commander'* ]]
  run make firmware-erase PROBE=commander CONFIRM=erase firmware_DEVICE=SiWG917M111MGTBA
  [ "$status" -eq 0 ]
  [[ "$(argv commander)" == $'device\nmasserase\n--device\nSiWG917M111MGTBA'* ]]
}

@test "zephyr power: a clear install hint when the profiler's python package is missing" {
  zephyr_proj
  stub_cmd python3 'exit 1'
  run make firmware-power
  [ "$status" -ne 0 ]
  [[ "$output" == *"ppk2-api is not installed for python3: python3 -m pip install ppk2-api"* ]]
  run make firmware-power POWER=joulescope
  [ "$status" -ne 0 ]
  [[ "$output" == *"joulescope is not installed for python3: python3 -m pip install joulescope"* ]]
  run make firmware-power POWER=otii
  [ "$status" -ne 0 ]
  [[ "$output" == *"POWER=otii: zephyr measures with ppk2 or joulescope"* ]]
}

@test "zephyr power with a PPK2: the capture script gets its settings, then the summary of build/power.csv" {
  zephyr_proj
  # a python that "has" ppk2-api: the capture writes the CSV it is told to, with the settings it got
  stub_cmd python3 'if [ "$2" = "import ppk2_api" ]; then exit 0; fi
printf "%s\n" "$STD_PW_SECONDS $STD_PW_MV $STD_PW_MODE $STD_PW_PORT" >"$STUB_LOG/pw.env"
case "$2" in *PPK2_API*) ;; *) exit 3;; esac
printf "time_s,current_mA,voltage_V\n0.01,1.5,3.3\n0.02,0.5,3.3\n" >"$STD_PW_CSV"'
  run make firmware-power DURATION=3 PORT=/dev/cu.usbmodemPPK
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG/pw.env")" = "3 3300 source /dev/cu.usbmodemPPK" ]
  [[ "$output" == *"avg       1.0000 mA"* ]]
  [[ "$output" == *"max       1.5000 mA"* ]]
  [ -f firmware/build/power.txt ]
}
