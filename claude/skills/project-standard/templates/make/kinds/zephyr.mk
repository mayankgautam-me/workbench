# project-standard v1.0 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind zephyr: a Zephyr / nRF Connect SDK firmware part (west, sysbuild, MCUboot).
#
# make/project.mk declares it as   <name>:zephyr[:<dir>]   and sets at least <name>_BOARD.
# NCS and the Zephyr SDK are pinned per part and installed once into $(STD_TOOLCHAINS)/ncs-<ver> and
# $(STD_TOOLCHAINS)/zephyr-sdk-<ver>, shared across projects; two versions live side by side.
# In the nRF Connect SDK toolchain image (CI) only the NCS source tree is fetched; see zephyr_image_env.
# The MCUboot signing key never touches the project: it is decrypted from the secrets repo into a
# temporary file for the one west build that signs (secrets.sh with-file), then removed.

# --- shared firmware helpers --------------------------------------------------------------------
# The same block is in every firmware kind (zephyr, espidf, pio, arm-gcc, circuitpython); the first
# kind included defines it. Helpers are recursive variables expanded when a recipe runs, called as
# $(call name,part,dir,...). They are shell text: one line, `$$` for the shell, no `#`.
ifndef STD_FW_HELPERS
STD_FW_HELPERS := 1

# west build --pristine value (auto rebuilds from scratch only when the configuration changed)
PRISTINE ?= auto
# serial ports looked at when PORT= is not given
STD_PORT_GLOB ?= /dev/cu.usbmodem* /dev/cu.usbserial* /dev/cu.SLAB* /dev/ttyACM* /dev/ttyUSB*

# Shell prelude: strict mode, Tokyo Night colour on a TTY, say/ok/warn/bad/die/have/ports.
STD_FW_SH = set -euo pipefail; \
  if [ -t 1 ] && [ -z "$${NO_COLOR:-}" ]; then c_ok=$$'\033[38;2;158;206;106m'; c_warn=$$'\033[38;2;224;175;104m'; c_err=$$'\033[38;2;247;118;142m'; c_info=$$'\033[38;2;122;162;247m'; c_0=$$'\033[0m'; else c_ok=; c_warn=; c_err=; c_info=; c_0=; fi; \
  problems=0; \
  say() { printf '%s>%s %s\n' "$$c_info" "$$c_0" "$$*"; }; \
  ok() { printf '  %sok%s    %s\n' "$$c_ok" "$$c_0" "$$*"; }; \
  warn() { printf '  %swarn%s  %s\n' "$$c_warn" "$$c_0" "$$*"; }; \
  bad() { printf '  %smiss%s  %s\n' "$$c_err" "$$c_0" "$$*"; problems=$$((problems + 1)); }; \
  die() { printf '%serror%s %s\n' "$$c_err" "$$c_0" "$$*" >&2; exit 1; }; \
  have() { command -v "$$1" >/dev/null 2>&1; }; \
  ports() { ls -d $(STD_PORT_GLOB) 2>/dev/null || true; };

# Sets $$port: PORT= when given, else the only serial port connected; several or none is an error.
STD_FW_PORT = port="$(PORT)"; \
  if [ -z "$$port" ]; then \
    list=$$(ports); n=$$(printf '%s' "$$list" | grep -c . || true); \
    [ "$$n" -gt 0 ] || die "no serial port found (looked for $(STD_PORT_GLOB)): plug the board in or pass PORT=/dev/..."; \
    [ "$$n" -eq 1 ] || die "several serial ports, pick one with PORT=...: $$(echo $$list)"; \
    port="$$list"; \
  fi; \
  say "port $$port";

# Defines logged LOGFILE CMD...: runs an interactive CMD on a pseudo-terminal and keeps a copy of
# everything it prints in LOGFILE (script(1): BSD syntax on macOS, util-linux syntax elsewhere).
STD_FW_LOGGED = logged() { log="$$1"; shift; mkdir -p "$$(dirname "$$log")"; say "console log: $$log"; \
  if [ "$$(uname -s)" = Darwin ]; then script -q "$$log" "$$@"; else script -q -e -c "$$(printf '%q ' "$$@")" "$$log"; fi; };

# $(call std_fw_version_sh,dir): sets $$ver from dir/VERSION (Zephyr VERSION_MAJOR/... format or a
# plain first line) or dir/version.txt; empty when neither exists.
std_fw_version_sh = ver=; vf="$(CURDIR)/$(1)/VERSION"; [ -f "$$vf" ] || vf="$(CURDIR)/$(1)/version.txt"; \
  if [ -f "$$vf" ]; then \
    if grep -q '^VERSION_MAJOR' "$$vf"; then \
      ver=$$(sed -nE 's/^(VERSION_MAJOR|VERSION_MINOR|PATCHLEVEL)[[:space:]]*=[[:space:]]*([0-9]+).*/\2/p' "$$vf" | paste -sd. -); \
      x=$$(sed -nE 's/^EXTRAVERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$$vf"); [ -z "$$x" ] || ver="$$ver-$$x"; \
    else ver=$$(head -n 1 "$$vf" | tr -d '[:space:]'); fi; \
  fi;

# $(call std_fw_print_version,part,dir)
std_fw_print_version = $(STD_FW_SH) $(call std_fw_version_sh,$(2)) printf '%s %s\n' "$(1)" "$${ver:-unknown (no $(2)/VERSION)}"

# $(call std_fw_pin,VAR,VALUE): set VAR := VALUE in make/project.mk (rewrites the line or appends it).
std_fw_pin = pf=make/project.mk; [ -f "$$pf" ] || die "make/project.mk not found (run from the project root)"; \
  if grep -qE '^$(1)[[:space:]]*[:?]?=' "$$pf"; then \
    awk -v n='$(2)' '/^$(1)[[:space:]]*[:?]?=/ { sub(/=.*/, "= " n) } { print }' "$$pf" > "$$pf.tmp" && mv "$$pf.tmp" "$$pf"; \
  else printf '%s := %s\n' '$(1)' '$(2)' >> "$$pf"; fi; \
  ok "$(1) = $(2) in $$pf";

# Signing keys come from the secrets repo through `secrets.sh with-file NAME -- cmd ... {}` (a
# mode-600 temp file that is removed afterwards). SIGNING_KEY=path uses a local key file instead.
std_fw_secrets = PROJECT="$(PROJECT)" "$(abspath $(STD_BIN))/secrets.sh"
std_fw_with_key = $(if $(SIGNING_KEY),,$(std_fw_secrets) with-file $(1) --)
std_fw_keyarg = $(if $(SIGNING_KEY),$(abspath $(SIGNING_KEY)),{})
std_fw_key_file = $(SECRETS_DIR)/$(PROJECT)/keys/$(1).sops

# $(call std_fw_keygen,part,keyname,type): create the key in the secrets repo, never overwrite one.
std_fw_keygen = $(STD_FW_SH) f="$(call std_fw_key_file,$(2))"; \
  [ ! -e "$$f" ] || die "signing key $(2) already exists ($$f): not overwriting it. Rotating it on purpose is a secrets.sh rotate job, and devices signed with the old key need a probe to move."; \
  say "creating signing key $(2) ($(3)) in the secrets repo"; \
  $(std_fw_secrets) keygen $(2) --type $(3); \
  ok "key $(2) stored encrypted in $$f"; \
  say "it is backed up with the secrets repo. Devices that boot images signed with it accept only images signed with it.";

# $(call std_fw_key_check,part,keyname): doctor line for a signing key.
std_fw_key_check = if [ -n "$(SIGNING_KEY)" ]; then if [ -f "$(SIGNING_KEY)" ]; then ok "signing key $(SIGNING_KEY) (SIGNING_KEY)"; else bad "SIGNING_KEY=$(SIGNING_KEY) does not exist"; fi; \
  elif [ -f "$(call std_fw_key_file,$(2))" ]; then ok "signing key $(2) in the secrets repo"; \
  else bad "signing key $(2) missing from $(SECRETS_DIR)/$(PROJECT)/keys: make $(1)-keygen (or restore it)"; fi;

# $(call std_fw_ports_check): doctor line for serial ports.
std_fw_ports_check = n=$$(ports | grep -c . || true); \
  if [ -n "$(PORT)" ]; then if [ -e "$(PORT)" ]; then ok "port $(PORT)"; else bad "PORT=$(PORT) does not exist"; fi; \
  elif [ "$$n" -eq 1 ]; then ok "serial port $$(ports)"; \
  elif [ "$$n" -gt 1 ]; then warn "several serial ports, pass PORT=: $$(echo $$(ports))"; \
  else warn "no serial port connected (fine unless you flash or monitor over serial)"; fi;

# $(call std_fw_doctor_end,part)
std_fw_doctor_end = if [ "$$problems" -eq 0 ]; then ok "$(1) ready"; else die "$(1): $$problems problem(s), fixes above"; fi

# In a tag pipeline (CI_COMMIT_TAG set) only a <part>-v* tag releases the part; locally always true.
std_fw_tag_ok = case "$${GITHUB_REF_NAME:-$${CI_COMMIT_TAG:-}}" in ""|$(1)-v*) true;; *) false;; esac

# Refuses releases outside staging and production (the OTA store is remote).
std_fw_remote_env = $(STD_FW_SH) case "$(ENV)" in staging|production) ;; *) die "release uploads to the OTA store: run it with ENV=staging or ENV=production";; esac

# $(call std_fw_release,part,dir,object-name), after $(STD_FW_SH) and f=FILE: uploads FILE to the
# OTA bucket as <prefix>/<ver>/<name> and <prefix>/latest/<name> (and stable/ with PROMOTE=1),
# through wrangler under `secrets.sh exec --env ENV`, then runs <part>_RELEASE_HOOK when set.
std_fw_release = $(call std_fw_version_sh,$(2)) \
  [ -n "$$ver" ] || die "no version: write it to $(2)/VERSION"; \
  [ -f "$$f" ] || die "$$f not found: the build did not produce it"; \
  bucket="$($(1)_OTA_BUCKET)"; [ -n "$$bucket" ] || die "no OTA bucket: set OTA_BUCKET (or $(1)_OTA_BUCKET) in make/project.mk"; \
  pfx="$($(1)_OTA_PREFIX)"; key="$$pfx/$$ver/$(3)"; \
  set -- "$$bucket/$$key" "$$bucket/$$pfx/latest/$(3)"; \
  if [ "$(PROMOTE)" = 1 ]; then set -- "$$@" "$$bucket/$$pfx/stable/$(3)"; fi; \
  sha=$$({ sha256sum "$$f" 2>/dev/null || shasum -a 256 "$$f"; } | cut -d' ' -f1); \
  say "release $(1) $$ver to $$bucket/$$pfx ($(ENV)), sha256 $$sha"; \
  $(std_fw_secrets) exec --env $(ENV) -- bash -c 'set -euo pipefail; f="$$1"; shift; for k in "$$@"; do $($(1)_WRANGLER) r2 object put "$$k" --file "$$f" --remote; done' _ "$$f" "$$@"; \
  for k in "$$@"; do ok "uploaded $$k"; done; \
  export VERSION="$$ver" SHA256="$$sha" OTA_BUCKET="$$bucket" OTA_KEY="$$key" OTA_FILE="$$f"; \
  $(call $(if $($(1)_RELEASE_HOOK),std_fw_release_hook,std_fw_noop),$(1))
std_fw_release_hook = say "running $(1)_RELEASE_HOOK"; $($(1)_RELEASE_HOOK)
std_fw_noop = :

# $(call std_fw_provision,part): SERIAL= is required; runs <part>_PROVISION (a shell command line
# from make/project.mk, with SERIAL, PART, PORT and PROBE exported), else flashes only.
std_fw_provision = $(STD_FW_SH) serial="$(SERIAL)"; \
  [ -n "$$serial" ] || die "SERIAL= is required: the serial number of the device being provisioned"; \
  case "$$serial" in *[!A-Za-z0-9._-]*) die "SERIAL=$$serial: letters, digits, dot, dash and underscore only";; esac; \
  export SERIAL="$$serial" PART="$(1)" PORT="$(PORT)" PROBE="$(PROBE)"; \
  say "provisioning $(1) serial $$serial"; \
  $(call $(if $($(1)_PROVISION),std_fw_provision_hook,std_fw_provision_default),$(1))
std_fw_provision_hook = $($(1)_PROVISION)
std_fw_provision_default = warn "$(1)_PROVISION is not set in make/project.mk: flashing only"; $(MAKE) --no-print-directory $(1)-flash

# $(call std_fw_hook,part,VAR,what): run the shell command line in VAR or explain that it is unset.
std_fw_hook = $(STD_FW_SH) $(call $(if $($(2)),std_fw_hook_run,std_fw_hook_missing),$(1),$(2),$(3))
std_fw_hook_run = say "running $(2)"; $($(2))
std_fw_hook_missing = die "$(3): set $(2) in make/project.mk to the command that does it for this board"

endif

# --- zephyr helpers -----------------------------------------------------------------------------

zephyr_ncs_repo = https://github.com/nrfconnect/sdk-nrf

# $(call zephyr_env,part): the pinned NCS + Zephyr SDK environment in the current shell.
zephyr_env = [ -f "$($(1)_NCS_DIR)/zephyr/zephyr-env.sh" ] || die "nRF Connect SDK $($(1)_NCS) is not in $($(1)_NCS_DIR): run make $(1)-setup"; \
  $(call zephyr_image_env,$(1)) \
  export ZEPHYR_TOOLCHAIN_VARIANT=zephyr; \
  if [ -d "$($(1)_SDK_DIR)" ]; then export ZEPHYR_SDK_INSTALL_DIR="$($(1)_SDK_DIR)"; \
  elif [ ! -d "$${ZEPHYR_SDK_INSTALL_DIR:-/nonexistent}" ]; then die "Zephyr SDK $($(1)_ZEPHYR_SDK) is not in $($(1)_SDK_DIR): run make $(1)-setup"; fi; \
  set +eu; . "$($(1)_NCS_DIR)/zephyr/zephyr-env.sh"; \
  if [ -f "$($(1)_NCS_DIR)/.venv/bin/activate" ]; then . "$($(1)_NCS_DIR)/.venv/bin/activate"; fi; set -eu; \
  have west || die "west not found: run make $(1)-setup";

# Only signed when asked for and MCUboot is on.
zephyr_sign = $(and $(1),$(filter 1,$($(2)_MCUBOOT)))
zephyr_sysbuild = $(if $(filter 1,$($(1)_SYSBUILD)),--sysbuild,--no-sysbuild)
zephyr_mcuboot_args = $(if $(filter 1,$($(1)_MCUBOOT)),-DSB_CONFIG_BOOTLOADER_MCUBOOT=y)
zephyr_key_args = $(if $(call zephyr_sign,$(2),$(1)),'-DSB_CONFIG_BOOT_SIGNATURE_KEY_FILE="$(std_fw_keyarg)"')
zephyr_signer = $(if $(call zephyr_sign,$(2),$(1)),$(call std_fw_with_key,$($(1)_KEY)))
zephyr_probe_sel = $(if $($(1)_PROBE_ID),--probe "$($(1)_PROBE_ID)")
zephyr_need_chip = [ -n "$($(1)_CHIP)" ] || die "probe-rs needs the chip name: set $(1)_CHIP in make/project.mk (for example nRF9151_xxAA)";
zephyr_need_build = b="$($(1)_BUILD)"; [ -d "$$b" ] || die "no build in $$b: run make $(1)-build";
zephyr_domain = $(if $(filter 1,$($(1)_SYSBUILD)),--domain $($(1)_APP))

# $(call zephyr_west_build,part,dir,build-dir,sign,extra-cmake-args)
zephyr_west_build = $(STD_FW_SH) $(call zephyr_env,$(1)) \
  board="$($(1)_B)"; [ -n "$$board" ] || die "no board: set $(1)_BOARD in make/project.mk or pass BOARD=..."; \
  say "west build $(1) for $$board into $(3)$(if $(call zephyr_sign,$(4),$(1)), signed with $(if $(SIGNING_KEY),$(SIGNING_KEY),$($(1)_KEY)))"; \
  cd "$(CURDIR)/$(2)"; \
  $(call zephyr_signer,$(1),$(4)) west build --pristine $(PRISTINE) $(call zephyr_sysbuild,$(1)) -b "$$board" -d "$(3)" -s . $($(1)_WEST_ARGS) -- \
    $(call zephyr_mcuboot_args,$(1)) $(call zephyr_key_args,$(1),$(4)) $($(1)_CMAKE_ARGS) $(5); \
  ok "built $(3)"

zephyr_twister = $(STD_FW_SH) \
  if [ ! -d "$(CURDIR)/$(2)/tests" ]; then say "$(1): no $(2)/tests, no twister run"; \
  elif [ "$$(uname -s)" != Linux ]; then warn "$(1): native_sim tests run on Linux only (CI runs them)"; \
  else $(call zephyr_env,$(1)) cd "$(CURDIR)/$(2)"; west twister -T tests -p native_sim --inline-logs -O "$(CURDIR)/$(2)/build/twister"; fi

# The nRF Connect SDK toolchain image (ghcr.io/nrfconnect/sdk-nrf-toolchain, the CI container) is recognised by its
# environment script, <part>_TOOLCHAIN_ENV (default /opt/toolchain-env.sh): where that file exists, the image's
# toolchain (its python with the NCS requirements, west, cmake, ninja, the Zephyr SDK) is used as it is, with no
# venv, no pip and no SDK download; only the NCS source tree is fetched. The image's BASH_ENV sources the script in
# every bash unless ZEPHYR_SDK_INSTALL_DIR is set; zephyr_image_env does the same where it did not run.
zephyr_image_env = if [ -f "$($(1)_TOOLCHAIN_ENV)" ] && [ -z "$${ZEPHYR_SDK_INSTALL_DIR:-}" ]; then set +eu; . "$($(1)_TOOLCHAIN_ENV)"; set -eu; fi;

# Elsewhere: a venv with west (and below the NCS python requirements) in the NCS folder, and the pinned Zephyr SDK.
zephyr_setup_venv = \
  if [ ! -x "$$ncs/.venv/bin/west" ] && ! { [ -n "$${CI:-}" ] && have west; }; then \
    say "python venv with west in $$ncs/.venv"; mkdir -p "$$ncs"; $($(1)_PYTHON) -m venv "$$ncs/.venv"; "$$ncs/.venv/bin/pip" install -q --upgrade pip west; fi; \
  west="$$ncs/.venv/bin/west"; [ -x "$$west" ] || west=west;

zephyr_setup_sdk = \
  if [ -d "$$sdk" ]; then ok "Zephyr SDK $$sdk"; \
  elif [ -d "$${ZEPHYR_SDK_INSTALL_DIR:-/nonexistent}" ]; then ok "Zephyr SDK from the environment ($$ZEPHYR_SDK_INSTALL_DIR)"; \
  else \
    $(STD_TC) sdk-begin "$$sdk" || true; \
    os=$$(uname -s | tr '[:upper:]' '[:lower:]'); if [ "$$os" = darwin ]; then os=macos; fi; \
    arch=$$(uname -m); if [ "$$arch" = arm64 ]; then arch=aarch64; fi; \
    url="https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v$($(1)_ZEPHYR_SDK)/zephyr-sdk-$($(1)_ZEPHYR_SDK)_$${os}-$${arch}_minimal.tar.xz"; \
    say "Zephyr SDK $($(1)_ZEPHYR_SDK) from $$url"; tmp="$$sdk.partial"; rm -rf "$$tmp"; mkdir -p "$$tmp"; \
    curl -fsSL --retry 3 "$$url" | tar xJ -C "$$tmp"; mv "$$tmp/zephyr-sdk-$($(1)_ZEPHYR_SDK)" "$$sdk"; rmdir "$$tmp"; \
    for t in $($(1)_SDK_TOOLCHAINS); do "$$sdk/setup.sh" -t "$$t"; done; \
  fi; \

# The NCS workspace: sdk-nrf at the pinned tag cloned with depth 1 as the manifest repo, then a narrow, depth-1
# west update. .std-updated marks a finished update, so a workspace restored from a CI cache is used as it is.
zephyr_setup = $(STD_FW_SH) ncs="$($(1)_NCS_DIR)"; sdk="$($(1)_SDK_DIR)"; image=; mkdir -p "$(STD_TOOLCHAINS)"; \
  if [ -f "$($(1)_TOOLCHAIN_ENV)" ]; then image=1; $(call zephyr_image_env,$(1)) \
    say "toolchain of the nRF Connect SDK image ($($(1)_TOOLCHAIN_ENV)): no venv, no Zephyr SDK download"; \
    for t in west cmake ninja dtc gperf git; do have $$t || die "$$t not found in the toolchain of $($(1)_TOOLCHAIN_ENV)"; done; \
    [ -d "$${ZEPHYR_SDK_INSTALL_DIR:-/nonexistent}" ] || die "$($(1)_TOOLCHAIN_ENV) sets no ZEPHYR_SDK_INSTALL_DIR"; \
  fi; \
  $(STD_TC) sdk-begin "$$ncs" || true; \
  for t in cmake ninja dtc gperf git; do have $$t || die "$$t not found: brew install $$t (the Brewfile has it)"; done; \
  if [ -n "$$image" ]; then west=west; else { $(call zephyr_setup_venv,$(1)) }; fi; \
  if [ ! -d "$$ncs/.west" ]; then say "west init nRF Connect SDK $($(1)_NCS) in $$ncs (shallow)"; mkdir -p "$$ncs"; \
    [ -f "$$ncs/nrf/west.yml" ] || git -c advice.detachedHead=false clone -q --depth 1 --branch "$($(1)_NCS)" $(zephyr_ncs_repo) "$$ncs/nrf"; \
    "$$west" init -l "$$ncs/nrf"; fi; \
  if [ ! -f "$$ncs/.std-updated" ]; then say "west update (shallow) in $$ncs"; (cd "$$ncs" && "$$west" update --narrow -o=--depth=1) && touch "$$ncs/.std-updated"; fi; \
  if [ -x "$$ncs/.venv/bin/pip" ] && [ ! -f "$$ncs/.venv/.std-requirements" ]; then say "python requirements of zephyr, nrf and mcuboot"; \
    "$$ncs/.venv/bin/pip" install -q -r "$$ncs/zephyr/scripts/requirements.txt" -r "$$ncs/nrf/scripts/requirements.txt" -r "$$ncs/bootloader/mcuboot/scripts/requirements.txt" && touch "$$ncs/.venv/.std-requirements"; fi; \
  want=$$(cat "$$ncs/zephyr/SDK_VERSION" 2>/dev/null || true); \
  if [ -n "$$image" ]; then \
    got=$$(cat "$$ZEPHYR_SDK_INSTALL_DIR/sdk_version" 2>/dev/null || true); ok "Zephyr SDK $${got:-?} of the image ($$ZEPHYR_SDK_INSTALL_DIR)"; \
    if [ -n "$$want" ] && [ -n "$$got" ] && [ "$$want" != "$$got" ]; then warn "NCS $($(1)_NCS) asks for Zephyr SDK $$want, the image has $$got"; fi; \
  else { $(call zephyr_setup_sdk,$(1)) }; \
    if [ -n "$$want" ] && [ "$$want" != "$($(1)_ZEPHYR_SDK)" ]; then warn "NCS $($(1)_NCS) asks for Zephyr SDK $$want, $(1)_ZEPHYR_SDK is $($(1)_ZEPHYR_SDK)"; fi; \
    $(STD_TC) sdk-use "$$ncs" "$$sdk" || true; \
  fi; \
  ok "$(1): nRF Connect SDK $($(1)_NCS) in $$ncs"

# Ready for std_ready, the same conditions zephyr_setup leaves: the NCS workspace of the pinned version is updated
# (.std-updated), and the toolchain is reachable: the nRF Connect SDK image's (TOOLCHAIN_ENV, CI), or the venv's west
# with the python requirements installed (in CI, a west on PATH) and the pinned Zephyr SDK (or ZEPHYR_SDK_INSTALL_DIR).
zephyr_ready = ncs="$($(1)_NCS_DIR)"; [ -f "$$ncs/.std-updated" ] || exit 1; \
  if [ -f "$($(1)_TOOLCHAIN_ENV)" ]; then exit 0; fi; \
  [ -x "$$ncs/.venv/bin/west" ] || { [ -n "$${CI:-}" ] && command -v west; } || exit 1; \
  [ ! -x "$$ncs/.venv/bin/pip" ] || [ -f "$$ncs/.venv/.std-requirements" ] || exit 1; \
  [ -d "$($(1)_SDK_DIR)" ] || [ -d "$${ZEPHYR_SDK_INSTALL_DIR:-/nonexistent}" ]

zephyr_doctor = $(STD_FW_SH) say "$(1): zephyr, NCS $($(1)_NCS), Zephyr SDK $($(1)_ZEPHYR_SDK), probe $($(1)_P)"; \
  if [ -f "$($(1)_TOOLCHAIN_ENV)" ]; then $(call zephyr_image_env,$(1)) ok "toolchain of the nRF Connect SDK image ($($(1)_TOOLCHAIN_ENV))"; fi; \
  for t in cmake ninja dtc gperf; do if have $$t; then ok "$$t"; else bad "$$t: brew install $$t"; fi; done; \
  if [ -f "$($(1)_NCS_DIR)/zephyr/zephyr-env.sh" ]; then ok "NCS $($(1)_NCS_DIR)"; else bad "NCS $($(1)_NCS) missing: make $(1)-setup"; fi; \
  if [ -x "$($(1)_NCS_DIR)/.venv/bin/west" ] || have west; then ok "west"; else bad "west missing: make $(1)-setup"; fi; \
  if [ -d "$($(1)_SDK_DIR)" ] || [ -d "$${ZEPHYR_SDK_INSTALL_DIR:-/nonexistent}" ]; then ok "Zephyr SDK $($(1)_ZEPHYR_SDK)"; else bad "Zephyr SDK $($(1)_ZEPHYR_SDK) missing: make $(1)-setup"; fi; \
  if [ -n "$($(1)_B)" ]; then ok "board $($(1)_B)"; else bad "no board: set $(1)_BOARD in make/project.mk"; fi; \
  case "$($(1)_P)" in \
    probe-rs) if have probe-rs; then ok "probe-rs"; else bad "probe-rs: brew install probe-rs-tools"; fi; \
      if [ -z "$($(1)_CHIP)" ]; then bad "probe-rs needs $(1)_CHIP (for example nRF9151_xxAA)"; fi; \
      if have probe-rs; then if probe-rs list 2>/dev/null | grep -q '\['; then ok "probe connected"; else warn "no debug probe connected"; fi; fi;; \
    jlink) if have JLinkExe; then ok "J-Link"; else bad "J-Link: brew install --cask segger-jlink"; fi;; \
    openocd) if have openocd; then ok "openocd"; else bad "openocd: brew install openocd"; fi; \
      if [ -z "$($(1)_OPENOCD_ARGS)" ]; then warn "$(1)_OPENOCD_ARGS is empty (west runner defaults apply)"; fi;; \
    nrfutil) if have nrfutil; then ok "nrfutil"; else bad "nrfutil: install it from Nordic (nrfutil) and add the device command"; fi;; \
    *) bad "PROBE=$($(1)_P): use probe-rs, jlink, openocd or nrfutil";; \
  esac; \
  if [ "$($(1)_MCUBOOT)" = 1 ]; then $(call std_fw_key_check,$(1),$($(1)_KEY)) fi; \
  if have tio; then ok "tio (monitor)"; else warn "tio missing, needed by make $(1)-monitor: brew install tio"; fi; \
  $(std_fw_ports_check) \
  $(call std_fw_doctor_end,$(1))

zephyr_update = $(STD_FW_SH) \
  if [ -n "$(TO)" ]; then $(call std_fw_pin,$(1)_NCS,$(TO)) $(if $(SDK),$(call std_fw_pin,$(1)_ZEPHYR_SDK,$(SDK))) $(MAKE) --no-print-directory $(1)-setup; \
  else say "$(1): NCS $($(1)_NCS), Zephyr SDK $($(1)_ZEPHYR_SDK). Latest nRF Connect SDK releases:"; \
    git ls-remote --tags --refs $(zephyr_ncs_repo) 'v*' | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$$' | sort -V | tail -n 5; \
    say "pin one with make $(1)-update TO=vX.Y.Z [SDK=0.17.x] (the SDK the release asks for is in zephyr/SDK_VERSION), then commit make/project.mk"; fi

zephyr_flash = $(STD_FW_SH) $(call zephyr_need_build,$(1)) \
  hex="$$b/merged.hex"; [ -f "$$hex" ] || hex="$$b/zephyr/zephyr.hex"; \
  case "$($(1)_P)" in \
    probe-rs) $(call zephyr_need_chip,$(1)) \
      probe-rs download --chip "$($(1)_CHIP)" $(call zephyr_probe_sel,$(1)) --verify --binary-format hex "$$hex"; \
      probe-rs reset --chip "$($(1)_CHIP)" $(call zephyr_probe_sel,$(1));; \
    jlink|openocd|nrfutil) $(call zephyr_env,$(1)) west flash --skip-rebuild -d "$$b" -r "$($(1)_P)" $($(1)_FLASH_ARGS);; \
    *) die "PROBE=$($(1)_P): zephyr flashes with probe-rs, jlink, openocd or nrfutil";; \
  esac; \
  ok "flashed $$hex"

zephyr_erase = $(STD_FW_SH) \
  case "$($(1)_P)" in \
    probe-rs) $(call zephyr_need_chip,$(1)) probe-rs erase --chip "$($(1)_CHIP)" $(call zephyr_probe_sel,$(1));; \
    jlink|nrfutil) have nrfutil || die "nrfutil not found: install it from Nordic"; nrfutil device erase --all;; \
    openocd) [ -n "$($(1)_OPENOCD_ARGS)" ] || die "set $(1)_OPENOCD_ARGS to the interface and target -f files"; \
      openocd $($(1)_OPENOCD_ARGS) -c 'init; reset halt; flash erase_sector 0 0 last; shutdown';; \
    *) die "PROBE=$($(1)_P): zephyr erases with probe-rs, jlink, openocd or nrfutil";; \
  esac; \
  ok "$(1): chip erased"

# recover: <part>_RECOVER when set (for example an openocd script), else the probe's own unlock.
zephyr_recover = $(call $(if $($(1)_RECOVER),zephyr_recover_hook,zephyr_recover_builtin),$(1))
zephyr_recover_hook = $(call std_fw_hook,$(1),$(1)_RECOVER,recover)
zephyr_recover_builtin = $(STD_FW_SH) \
  case "$($(1)_P)" in \
    probe-rs) $(call zephyr_need_chip,$(1)) probe-rs erase --chip "$($(1)_CHIP)" $(call zephyr_probe_sel,$(1)) --allow-erase-all;; \
    jlink|nrfutil) have nrfutil || die "nrfutil not found: install it from Nordic"; nrfutil device recover;; \
    *) die "PROBE=$($(1)_P) has no built-in recover: set $(1)_RECOVER in make/project.mk";; \
  esac; \
  ok "$(1): chip unlocked and erased"

zephyr_debug = $(STD_FW_SH) $(call zephyr_need_build,$(1)) \
  elf="$$b/$($(1)_APP)/zephyr/zephyr.elf"; [ -f "$$elf" ] || elf="$$b/zephyr/zephyr.elf"; \
  case "$($(1)_P)" in \
    probe-rs) $(call zephyr_need_chip,$(1)) $(call zephyr_env,$(1)) \
      gdb="$${ZEPHYR_SDK_INSTALL_DIR:-}/arm-zephyr-eabi/bin/arm-zephyr-eabi-gdb"; [ -x "$$gdb" ] || gdb=arm-none-eabi-gdb; \
      probe-rs gdb --chip "$($(1)_CHIP)" $(call zephyr_probe_sel,$(1)) & srv=$$!; trap 'kill $$srv 2>/dev/null || true' EXIT; sleep 1; \
      "$$gdb" "$$elf" -ex 'target remote :1337';; \
    jlink|openocd) $(call zephyr_env,$(1)) west debug --skip-rebuild -d "$$b" -r "$($(1)_P)";; \
    *) die "PROBE=$($(1)_P): zephyr debugs with probe-rs, jlink or openocd";; \
  esac

zephyr_monitor = $(STD_FW_SH) $(STD_FW_PORT) $(STD_FW_LOGGED) \
  have $(firstword $($(1)_MONITOR)) || die "$(firstword $($(1)_MONITOR)) not found: brew install $(firstword $($(1)_MONITOR))"; \
  logged "$(CURDIR)/$(2)/build/monitor.log" $($(1)_MONITOR) "$$port"

# $(call zephyr_target,part,west-target...): a west build target on the existing build.
zephyr_target = $(STD_FW_SH) $(call zephyr_need_build,$(1)) $(call zephyr_env,$(1)) \
  for t in $(2); do west build -d "$$b" $(call zephyr_domain,$(1)) -t "$$t"; done

zephyr_release = $(STD_FW_SH) f="$($(1)_BUILD)/dfu_application.zip"; $(call std_fw_release,$(1),$(2),dfu_application.zip)

# GitHub Release assets of the build: the signed dfu_application.zip (OTA), merged.hex (MCUboot and the app, for
# factory programming), the signed app image, and the elf and map (debug symbols). Without sysbuild: zephyr.bin/hex.
zephyr_release_assets = $(STD_FW_SH) $(call zephyr_need_build,$(1)) $(call std_rel_begin,$(1),zephyr,$(2)) \
  app="$$b/$($(1)_APP)/zephyr"; [ -d "$$app" ] || app="$$b/zephyr"; \
  if [ "$($(1)_MCUBOOT)" = 1 ]; then need "$$b/dfu_application.zip"; need "$$app/zephyr.signed.bin"; opt "$$app/zephyr.signed.hex"; \
  else opt "$$b/dfu_application.zip"; need "$$app/zephyr.bin"; fi; \
  put "$$b/merged.hex" || need "$$app/zephyr.hex"; \
  need "$$app/zephyr.elf"; opt "$$app/zephyr.map"; \
  $(std_rel_end)

# --- the kind -----------------------------------------------------------------------------------
#
# Per-part settings (make/project.mk, <part>_<VAR>), with their defaults:
#   BOARD          board target, for example nrf9151dk/nrf9151/ns (BOARD= on the command line wins)
#   NCS            v3.2.1   nRF Connect SDK, in $(STD_TOOLCHAINS)/ncs-<ver>, shared across projects
#   ZEPHYR_SDK     0.17.4   Zephyr SDK, in $(STD_TOOLCHAINS)/zephyr-sdk-<ver>
#   SDK_TOOLCHAINS arm-zephyr-eabi   toolchains the SDK setup installs
#   TOOLCHAIN_ENV  /opt/toolchain-env.sh   environment script of the nRF Connect SDK toolchain image; where it
#                  exists (the CI container) setup and builds use the image's python, west and Zephyr SDK
#   SYSBUILD 1, MCUBOOT 1   sysbuild with MCUboot; the image is signed with the key KEY (mcuboot)
#                           from the secrets repo; SIGNING_KEY=path uses a local key file instead
#   APP            the app image name in a sysbuild build (default: the part dir's name)
#   PROBE          probe-rs  probe-rs, jlink, openocd or nrfutil (PROBE= on the command line wins)
#   CHIP           probe-rs chip name, for example nRF9151_xxAA;  PROBE_ID  probe-rs --probe value
#   OPENOCD_ARGS   -f files for openocd erase;  FLASH_ARGS  extra west flash arguments
#   WEST_ARGS, CMAKE_ARGS   extra west build arguments, before and after `--`
#   MONITOR        tio -b BAUD (BAUD 115200)
#   RECOVER        shell command for make <part>-recover (default: the probe's own unlock)
#   PROVISION      shell command for make <part>-provision SERIAL=... (default: flash only)
#   OTA_BUCKET     $(OTA_BUCKET) from make/project.mk;  OTA_PREFIX  <project>/<part>/<env>;  WRANGLER  npx --yes wrangler@4
#   RELEASE_HOOK   shell command run after a release upload (VERSION SHA256 OTA_KEY OTA_FILE set)
# Builds go to <dir>/build/<board with / as _>; `make <part>-check` builds with warnings as errors
# into <dir>/build/check-<board> (MCUboot's own development key, no secrets) and runs twister on
# <dir>/tests with native_sim on Linux.

define kind_zephyr
$(1)_NCS ?= v3.2.1
$(1)_ZEPHYR_SDK ?= 0.17.4
$(1)_SDK_TOOLCHAINS ?= arm-zephyr-eabi
$(1)_BOARD ?=
$(1)_SYSBUILD ?= 1
$(1)_MCUBOOT ?= 1
$(1)_KEY ?= mcuboot
$(1)_APP ?= $(notdir $(2))
$(1)_PROBE ?= probe-rs
$(1)_CHIP ?=
$(1)_PROBE_ID ?=
$(1)_OPENOCD_ARGS ?=
$(1)_FLASH_ARGS ?=
$(1)_WEST_ARGS ?=
$(1)_CMAKE_ARGS ?=
$(1)_PYTHON ?= python3
$(1)_TOOLCHAIN_ENV ?= /opt/toolchain-env.sh
$(1)_BAUD ?= 115200
$(1)_MONITOR ?= tio -b $$($(1)_BAUD)
$(1)_RECOVER ?=
$(1)_PROVISION ?=
$(1)_OTA_BUCKET ?= $$(OTA_BUCKET)
# no OTA bucket (no Cloudflare in the project): <part>-release publishes nothing, and help leaves it out
STD_HELP_HIDE += $$(if $$(strip $$($(1)_OTA_BUCKET)),,$(1)-release)
$(1)_OTA_PREFIX ?= $$(PROJECT)/$(1)/$$(ENV)
$(1)_WRANGLER ?= npx --yes wrangler@4
$(1)_RELEASE_HOOK ?=
$(1)_NCS_DIR ?= $$(STD_TOOLCHAINS)/ncs-$$($(1)_NCS)
$(1)_SDK_DIR ?= $$(STD_TOOLCHAINS)/zephyr-sdk-$$($(1)_ZEPHYR_SDK)
$(1)_B = $$(or $$(BOARD),$$($(1)_BOARD))
$(1)_P = $$(or $$(PROBE),$$($(1)_PROBE))
$(1)_BUILD = $$(CURDIR)/$(2)/build/$$(subst /,_,$$($(1)_B))
$(1)_CHECK_BUILD = $$(CURDIR)/$(2)/build/check-$$(subst /,_,$$($(1)_B))

.PHONY: $(1)-release-run $(1)-doctor $(1)-setup $(1)-update $(1)-check $(1)-build $(1)-clean $(1)-distclean $(1)-flash $(1)-erase $(1)-monitor $(1)-debug $(1)-release $(1)-version $(1)-size $(1)-config $(1)-keygen $(1)-provision $(1)-recover

$(call std_verb,$(1),doctor,firmware,Check NCS and Zephyr SDK and probe and signing key and ports read only)
$(1)-doctor:
	@$$(call zephyr_doctor,$(1),$(2))

$(call std_verb,$(1),setup,firmware,Install NCS $$($(1)_NCS) and Zephyr SDK $$($(1)_ZEPHYR_SDK) into $$(STD_TOOLCHAINS) shared)
$(1)-setup:
	@$$(call zephyr_setup,$(1),$(2))

# The commands that run west or the Zephyr SDK set up the pinned NCS and SDK first when they are not ready (std_ready
# in common.mk). release, release-assets and provision build or flash through the targets below.
$(call std_ready,$(1),$(2),zephyr_ready,check build flash debug size config)

$(call std_verb,$(1),update,firmware,List NCS releases or pin TO=vX.Y.Z [SDK=] in make/project.mk and set up)
$(1)-update:
	@$$(call zephyr_update,$(1),$(2))

$(call std_verb,$(1),check,firmware,Build with warnings as errors and run native_sim tests on Linux)
# -Werror through EXTRA_CFLAGS reaches Zephyr and the app, not the images built on their own: with
# CONFIG_COMPILER_WARNINGS_AS_ERRORS, NCS also passes -Werror to TF-M (every /ns board), whose own sources warn (v21).
$(1)-check:
	@$$(call zephyr_west_build,$(1),$(2),$$($(1)_CHECK_BUILD),,-DEXTRA_CFLAGS=-Werror)
	@$$(call zephyr_twister,$(1),$(2))

$(call std_verb,$(1),build,firmware,Signed sysbuild build for $$($(1)_B) into $(2)/build)
$(1)-build:
	@$$(call zephyr_west_build,$(1),$(2),$$($(1)_BUILD),1,)

$(call std_verb,$(1),flash,firmware,Build then flash with PROBE= probe-rs jlink openocd or nrfutil and NOBUILD=1 to skip the build)
$(1)-flash: $$(if $$(NOBUILD),,$(1)-build)
	@$$(call zephyr_flash,$(1),$(2))

$(call std_verb,$(1),erase,firmware,Erase the whole chip and needs CONFIRM=erase)
$(1)-erase:
	@$$(call std_confirm,erase) && { $$(call zephyr_erase,$(1),$(2)); }

$(call std_extra,$(1),recover,firmware,Unlock a protected chip by erasing it all and needs CONFIRM=erase)
$(1)-recover:
	@$$(call std_confirm,erase) && { $$(call zephyr_recover,$(1)); }

$(call std_verb,$(1),monitor,firmware,Serial console on PORT or the only port and logged to $(2)/build/monitor.log)
$(1)-monitor:
	@$$(call zephyr_monitor,$(1),$(2))

$(call std_verb,$(1),debug,firmware,GDB on the built image through the probe)
$(1)-debug:
	@$$(call zephyr_debug,$(1),$(2))

$(call std_extra,$(1),size,firmware,ROM and RAM report of the build)
$(1)-size:
	@$$(call zephyr_target,$(1),rom_report ram_report)

$(call std_extra,$(1),config,firmware,menuconfig on the build)
$(1)-config:
	@$$(call zephyr_target,$(1),menuconfig)

$(call std_extra,$(1),keygen,firmware,Create the MCUboot signing key $$($(1)_KEY) in the secrets repo and never overwrite)
$(1)-keygen:
	@$$(call std_fw_keygen,$(1),$$($(1)_KEY),mcuboot-ecdsa-p256)

$(call std_extra,$(1),provision,firmware,Per device setup SERIAL= through $(1)_PROVISION else flash only)
$(1)-provision:
	@$$(call std_fw_provision,$(1))

$(call std_verb,$(1),release,release,Signed dfu_application.zip to the OTA store as ver and latest with ENV= and PROMOTE=1 for stable)
$(1)-release:
	@if [ -z "$$(strip $$($(1)_OTA_BUCKET))" ]; then echo "> $(1): no OTA bucket (no Cloudflare in this project): firmware publish skipped"; exit 0; fi; if $$(call std_fw_tag_ok,$(1)); then $$(MAKE) --no-print-directory $(1)-release-run; else echo "$(1): tag $$$$CI_COMMIT_TAG is not a $(1) release, nothing to do"; fi

$(1)-release-run:
	@$$(std_production_guard) && { $$(std_fw_remote_env); } && $$(if $$(NOBUILD),true,$$(MAKE) --no-print-directory $(1)-build) && { $$(call zephyr_release,$(1),$(2)); }

$(call std_verb,$(1),version,release,Firmware version from $(2)/VERSION)

$(call std_release,$(1),zephyr,$(2),zephyr_release_assets,build)
$(1)-version:
	@$$(call std_fw_print_version,$(1),$(2))

$(call std_verb,$(1),clean,firmware,Remove $(2)/build)
$(1)-clean:
	@rm -rf "$$(CURDIR)/$(2)/build"

$(call std_verb,$(1),distclean,firmware,Remove $(2)/build and keep the shared toolchains)
$(1)-distclean: $(1)-clean
endef
