# project-standard v1.8 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind arm-gcc: a bare-metal arm-none-eabi firmware part (CubeMX export, libopencm3, own Makefile).
#
# make/project.mk declares it as   <name>:arm-gcc[:<dir>]   and sets <name>_PROBE and, for
# probe-rs, <name>_CHIP. The part's own CMakeLists.txt or Makefile does the compiling; this kind
# gives it the standard commands and the flashing, debugging and release around it.

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

# --- arm-gcc helpers ----------------------------------------------------------------------------

armgcc_need_gcc = have $($(1)_PREFIX)gcc || die "$($(1)_PREFIX)gcc not found: brew install --cask gcc-arm-embedded (or set $(1)_PREFIX)";
armgcc_need_chip = [ -n "$($(1)_CHIP)" ] || die "probe-rs needs the chip name: set $(1)_CHIP in make/project.mk (for example STM32F042G6Ux)";
armgcc_need_ocd = [ -n "$($(1)_OPENOCD_ARGS)" ] || die "set $(1)_OPENOCD_ARGS to the interface and target -f files";
armgcc_probe_sel = $(if $($(1)_PROBE_ID),--probe "$($(1)_PROBE_ID)")
# a sub-make of the part's own Makefile, without this make's command line variables
armgcc_submake = MAKEFLAGS= MAKELEVEL= $(MAKE) --no-print-directory -C "$(CURDIR)/$(2)" $($(1)_MAKE_ARGS)
armgcc_has_target = grep -qE '^$(3):' "$(CURDIR)/$(2)/Makefile" 2>/dev/null

# $(call armgcc_build,part,dir,check): CMake (Ninja) when the dir has CMakeLists.txt, else its Makefile.
armgcc_build = $(STD_FW_SH) $(call armgcc_need_gcc,$(1)) d="$(CURDIR)/$(2)"; \
  if [ -f "$$d/CMakeLists.txt" ]; then \
    tc="$($(1)_TOOLCHAIN_FILE)"; if [ -z "$$tc" ] && [ -f "$$d/cmake/gcc-arm-none-eabi.cmake" ]; then tc="$$d/cmake/gcc-arm-none-eabi.cmake"; fi; \
    out="$($(1)_OUT)$(if $(3),-check)"; say "cmake $(1) into $$out"; \
    cmake -S "$$d" -B "$$out" -G Ninja $$( [ -z "$$tc" ] || printf -- '-DCMAKE_TOOLCHAIN_FILE=%s' "$$tc" ) $($(1)_CMAKE_ARGS) $(if $(3),-DCMAKE_COMPILE_WARNING_AS_ERROR=ON); \
    cmake --build "$$out"; \
  elif [ -f "$$d/Makefile" ]; then \
    if [ -n "$(3)" ] && $(call armgcc_has_target,$(1),$(2),check); then say "make -C $(2) check"; $(call armgcc_submake,$(1),$(2)) check; \
    else tgt="$($(1)_MAKE_TARGET)"; if [ -z "$$tgt" ] && $(call armgcc_has_target,$(1),$(2),build); then tgt=build; fi; \
      say "make -C $(2) $$tgt"; $(call armgcc_submake,$(1),$(2)) $$tgt; fi; \
  else die "no CMakeLists.txt or Makefile in $(2)"; fi; \
  $(if $(3),,$(call armgcc_artifacts,$(1),$(2)) ok "built $$elf and $$(basename "$$bin")";) \
  ok "built $(1)"

# Sets $$elf and $$bin (made with objcopy when missing or older than the elf).
armgcc_artifacts = out="$($(1)_OUT)"; elf="$($(1)_ELF)"; \
  if [ -z "$$elf" ]; then elf=$$(find "$$out" -maxdepth 2 -name '*.elf' 2>/dev/null | head -n 2); \
    [ -n "$$elf" ] || die "no .elf in $$out: run make $(1)-build (or set $(1)_ELF)"; \
    [ "$$(printf '%s\n' "$$elf" | wc -l | tr -d ' ')" = 1 ] || die "several .elf files in $$out: set $(1)_ELF"; \
  else elf="$(CURDIR)/$(2)/$$elf"; fi; \
  bin="$($(1)_BIN)"; if [ -z "$$bin" ]; then bin="$${elf%.elf}.bin"; else bin="$(CURDIR)/$(2)/$$bin"; fi; \
  if [ ! -f "$$bin" ] || [ "$$elf" -nt "$$bin" ]; then $($(1)_PREFIX)objcopy -O binary "$$elf" "$$bin"; fi;

armgcc_fail_hint = { $(if $($(1)_FLASH_HINT),warn "$($(1)_FLASH_HINT)";) exit 1; }

armgcc_flash = $(STD_FW_SH) $(call armgcc_artifacts,$(1),$(2)) \
  case "$($(1)_P)" in \
    dfu) have dfu-util || die "dfu-util not found: brew install dfu-util"; \
      dfu-util $(if $($(1)_DFU_ID),-d $($(1)_DFU_ID)) -a $($(1)_DFU_ALT) -s $($(1)_FLASH_ADDR):leave -D "$$bin" || $(call armgcc_fail_hint,$(1));; \
    stlink) have st-flash || die "st-flash not found: brew install stlink"; st-flash --reset write "$$bin" $($(1)_FLASH_ADDR) || $(call armgcc_fail_hint,$(1));; \
    probe-rs) $(call armgcc_need_chip,$(1)) probe-rs download --chip "$($(1)_CHIP)" $(call armgcc_probe_sel,$(1)) --verify "$$elf" || $(call armgcc_fail_hint,$(1)); \
      probe-rs reset --chip "$($(1)_CHIP)" $(call armgcc_probe_sel,$(1));; \
    openocd) $(call armgcc_need_ocd,$(1)) openocd $($(1)_OPENOCD_ARGS) -c "program \"$$elf\" verify reset exit" || $(call armgcc_fail_hint,$(1));; \
    *) die "PROBE=$($(1)_P): arm-gcc flashes with dfu, stlink, probe-rs or openocd";; \
  esac; \
  ok "flashed $$elf"

armgcc_erase = $(STD_FW_SH) \
  case "$($(1)_P)" in \
    stlink) st-flash erase;; \
    probe-rs) $(call armgcc_need_chip,$(1)) probe-rs erase --chip "$($(1)_CHIP)" $(call armgcc_probe_sel,$(1));; \
    openocd) $(call armgcc_need_ocd,$(1)) openocd $($(1)_OPENOCD_ARGS) -c 'init; reset halt; flash erase_sector 0 0 last; shutdown';; \
    *) die "PROBE=$($(1)_P) has no erase here: use PROBE=stlink, probe-rs or openocd";; \
  esac; \
  ok "$(1): chip erased"

armgcc_recover = $(call $(if $($(1)_RECOVER),armgcc_recover_hook,armgcc_recover_builtin),$(1))
armgcc_recover_hook = $(call std_fw_hook,$(1),$(1)_RECOVER,recover)
armgcc_recover_builtin = $(STD_FW_SH) \
  case "$($(1)_P)" in \
    stlink) st-flash --connect-under-reset erase;; \
    probe-rs) $(call armgcc_need_chip,$(1)) probe-rs erase --chip "$($(1)_CHIP)" $(call armgcc_probe_sel,$(1)) --allow-erase-all;; \
    *) die "PROBE=$($(1)_P) has no built-in recover: set $(1)_RECOVER in make/project.mk";; \
  esac; \
  ok "$(1): chip unlocked and erased"

armgcc_debug = $(STD_FW_SH) $(call armgcc_artifacts,$(1),$(2)) gdb="$($(1)_PREFIX)gdb"; have "$$gdb" || gdb=gdb-multiarch; \
  case "$($(1)_P)" in \
    probe-rs) $(call armgcc_need_chip,$(1)) probe-rs gdb --chip "$($(1)_CHIP)" $(call armgcc_probe_sel,$(1)) & srv=$$!; gport=1337;; \
    openocd) $(call armgcc_need_ocd,$(1)) openocd $($(1)_OPENOCD_ARGS) & srv=$$!; gport=3333;; \
    stlink) st-util & srv=$$!; gport=4242;; \
    *) die "PROBE=$($(1)_P): arm-gcc debugs with probe-rs, openocd or stlink";; \
  esac; \
  trap 'kill $$srv 2>/dev/null || true' EXIT; sleep 1; "$$gdb" "$$elf" -ex "target extended-remote :$$gport"

armgcc_monitor = $(STD_FW_SH) $(STD_FW_PORT) $(STD_FW_LOGGED) \
  have $(firstword $($(1)_MONITOR)) || die "$(firstword $($(1)_MONITOR)) not found: brew install $(firstword $($(1)_MONITOR))"; \
  logged "$(CURDIR)/$(2)/build/monitor.log" $($(1)_MONITOR) "$$port"

armgcc_size = $(STD_FW_SH) $(call armgcc_artifacts,$(1),$(2)) $($(1)_PREFIX)size "$$elf"

armgcc_doctor = $(STD_FW_SH) say "$(1): arm-gcc, probe $($(1)_P)"; \
  if have $($(1)_PREFIX)gcc; then ok "$$($($(1)_PREFIX)gcc --version | head -n 1)"; else bad "$($(1)_PREFIX)gcc: brew install --cask gcc-arm-embedded (or set $(1)_PREFIX)"; fi; \
  if [ -f "$(CURDIR)/$(2)/CMakeLists.txt" ]; then ok "CMake project"; for t in cmake ninja; do if have $$t; then ok "$$t"; else bad "$$t: brew install $$t"; fi; done; \
  elif [ -f "$(CURDIR)/$(2)/Makefile" ]; then ok "Makefile project"; else bad "no CMakeLists.txt or Makefile in $(2)"; fi; \
  case "$($(1)_P)" in \
    dfu) if have dfu-util; then ok "dfu-util"; else bad "dfu-util: brew install dfu-util"; fi;; \
    stlink) if have st-flash; then ok "st-flash"; else bad "st-flash: brew install stlink"; fi;; \
    probe-rs) if have probe-rs; then ok "probe-rs"; else bad "probe-rs: brew install probe-rs-tools"; fi; if [ -z "$($(1)_CHIP)" ]; then bad "probe-rs needs $(1)_CHIP"; fi;; \
    openocd) if have openocd; then ok "openocd"; else bad "openocd: brew install openocd"; fi; if [ -z "$($(1)_OPENOCD_ARGS)" ]; then bad "set $(1)_OPENOCD_ARGS"; fi;; \
    *) bad "PROBE=$($(1)_P): use dfu, stlink, probe-rs or openocd";; \
  esac; \
  $(std_fw_ports_check) \
  $(call std_fw_doctor_end,$(1))

armgcc_clean = $(STD_FW_SH) \
  if [ -f "$(CURDIR)/$(2)/Makefile" ] && [ ! -f "$(CURDIR)/$(2)/CMakeLists.txt" ] && $(call armgcc_has_target,$(1),$(2),$(3)); then $(call armgcc_submake,$(1),$(2)) $(3); \
  else rm -rf "$($(1)_OUT)" "$($(1)_OUT)-check"; fi

armgcc_release = $(STD_FW_SH) $(call armgcc_artifacts,$(1),$(2)) f="$$bin"; $(call std_fw_release,$(1),$(2),$(1).bin)

# GitHub Release assets: the .bin, .hex (made with objcopy when the build has none), .elf and .map of the build.
armgcc_release_assets = $(STD_FW_SH) $(call armgcc_artifacts,$(1),$(2)) $(call std_rel_begin,$(1),arm-gcc,$(2)) \
  hex="$${elf%.elf}.hex"; if [ ! -f "$$hex" ] && have $($(1)_PREFIX)objcopy; then $($(1)_PREFIX)objcopy -O ihex "$$elf" "$$hex"; fi; \
  need "$$bin"; opt "$$hex"; need "$$elf"; opt "$${elf%.elf}.map"; \
  $(std_rel_end)

# --- the kind -----------------------------------------------------------------------------------
#
# A bare arm-none-eabi project in the part dir: a CMakeLists.txt (CubeMX CMake export, built with
# Ninja into <dir>/build) or its own Makefile (libopencm3, CubeMX Makefile export).
# Per-part settings (make/project.mk, <part>_<VAR>), with their defaults:
#   PREFIX          arm-none-eabi-   cross compiler prefix (brew install --cask gcc-arm-embedded)
#   TOOLCHAIN_FILE  CMake toolchain file (default <dir>/cmake/gcc-arm-none-eabi.cmake when present)
#   CMAKE_ARGS      extra CMake arguments;  MAKE_ARGS  PREFIX=<PREFIX>;  MAKE_TARGET  build when the Makefile has one, else its default goal
#   BUILD_DIR       build      output dir in the part dir;  ELF, BIN  image paths in the part dir
#                              (default: the only .elf in the output dir, and that name with .bin)
#   PROBE           probe-rs   dfu, stlink, probe-rs or openocd (PROBE= on the command line wins)
#   CHIP, PROBE_ID  probe-rs chip and probe;  OPENOCD_ARGS  openocd -f files
#   DFU_ID          vid:pid[,vid:pid] for dfu-util -d;  DFU_ALT 0;  FLASH_ADDR 0x08000000
#   FLASH_HINT      printed when a flash fails (for example how to get the board into DFU)
#   MONITOR         tio -b BAUD (BAUD 115200);  RECOVER, PROVISION, OTA_*, WRANGLER, RELEASE_HOOK
# `make <part>-check` builds with warnings as errors (CMake), or runs the Makefile's check target.

define kind_arm-gcc
$(1)_PREFIX ?= arm-none-eabi-
$(1)_TOOLCHAIN_FILE ?=
$(1)_CMAKE_ARGS ?=
$(1)_MAKE_ARGS ?= PREFIX=$$($(1)_PREFIX)
$(1)_MAKE_TARGET ?=
$(1)_BUILD_DIR ?= build
$(1)_ELF ?=
$(1)_BIN ?=
$(1)_PROBE ?= probe-rs
$(1)_CHIP ?=
$(1)_PROBE_ID ?=
$(1)_OPENOCD_ARGS ?=
$(1)_DFU_ID ?=
$(1)_DFU_ALT ?= 0
$(1)_FLASH_ADDR ?= 0x08000000
$(1)_FLASH_HINT ?=
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
$(1)_P = $$(or $$(PROBE),$$($(1)_PROBE))
$(1)_OUT = $$(CURDIR)/$(2)/$$($(1)_BUILD_DIR)

.PHONY: $(1)-release-run $(1)-doctor $(1)-setup $(1)-check $(1)-build $(1)-clean $(1)-distclean $(1)-flash $(1)-erase $(1)-monitor $(1)-debug $(1)-release $(1)-version $(1)-size $(1)-provision $(1)-recover

$(call std_verb,$(1),doctor,firmware,Check the cross compiler and build system and probe and ports read only)
$(1)-doctor:
	@$$(call armgcc_doctor,$(1),$(2))

$(call std_verb,$(1),setup,firmware,Check the cross compiler which comes from the Brewfile)
$(1)-setup:
	@$$(STD_FW_SH) $$(call armgcc_need_gcc,$(1)) ok "$(1): $$($(1)_PREFIX)gcc found"

$(call std_verb,$(1),check,firmware,Build with warnings as errors or the Makefile check target)
$(1)-check:
	@$$(call armgcc_build,$(1),$(2),1)

$(call std_verb,$(1),build,firmware,Build with CMake or the part Makefile)
$(1)-build:
	@$$(call armgcc_build,$(1),$(2),)

$(call std_verb,$(1),flash,firmware,Build then flash with PROBE= dfu stlink probe-rs or openocd and NOBUILD=1 to skip the build)
$(1)-flash: $$(if $$(NOBUILD),,$(1)-build)
	@$$(call armgcc_flash,$(1),$(2))

$(call std_verb,$(1),erase,firmware,Erase the whole chip and needs CONFIRM=erase)
$(1)-erase:
	@$$(call std_confirm,erase) && { $$(call armgcc_erase,$(1),$(2)); }

$(call std_extra,$(1),recover,firmware,Unlock a protected chip by erasing it all and needs CONFIRM=erase)
$(1)-recover:
	@$$(call std_confirm,erase) && { $$(call armgcc_recover,$(1)); }

$(call std_verb,$(1),monitor,firmware,Serial console on PORT or the only port and logged to $(2)/build/monitor.log)
$(1)-monitor:
	@$$(call armgcc_monitor,$(1),$(2))

$(call std_verb,$(1),debug,firmware,GDB on the elf through the probe gdb server)
$(1)-debug:
	@$$(call armgcc_debug,$(1),$(2))

$(call std_extra,$(1),size,firmware,Section sizes of the elf)
$(1)-size:
	@$$(call armgcc_size,$(1),$(2))

$(call std_extra,$(1),provision,firmware,Per device setup SERIAL= through $(1)_PROVISION else flash only)
$(1)-provision:
	@$$(call std_fw_provision,$(1))

$(call std_verb,$(1),release,release,Binary to the OTA store as ver and latest with ENV= and PROMOTE=1 for stable)
$(1)-release:
	@if [ -z "$$(strip $$($(1)_OTA_BUCKET))" ]; then echo "> $(1): no OTA bucket (no Cloudflare in this project): firmware publish skipped"; exit 0; fi; if $$(call std_fw_tag_ok,$(1)); then $$(MAKE) --no-print-directory $(1)-release-run; else echo "$(1): tag $$$$CI_COMMIT_TAG is not a $(1) release, nothing to do"; fi

$(1)-release-run:
	@$$(std_production_guard) && { $$(std_fw_remote_env); } && $$(if $$(NOBUILD),true,$$(MAKE) --no-print-directory $(1)-build) && { $$(call armgcc_release,$(1),$(2)); }

$(call std_verb,$(1),version,release,Firmware version from $(2)/VERSION)

$(call std_release,$(1),arm-gcc,$(2),armgcc_release_assets,build)
$(1)-version:
	@$$(call std_fw_print_version,$(1),$(2))

$(call std_verb,$(1),clean,firmware,Remove the build output)
$(1)-clean:
	@$$(call armgcc_clean,$(1),$(2),clean)

$(call std_verb,$(1),distclean,firmware,Remove the build output and fetched libraries through the Makefile distclean)
$(1)-distclean:
	@$$(call armgcc_clean,$(1),$(2),distclean)
endef
