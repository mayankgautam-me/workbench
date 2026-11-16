# project-standard v1.2 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind circuitpython: a CircuitPython part (interpreter image built in Docker, code in src/).
#
# make/project.mk declares it as   <name>:circuitpython[:<dir>]   and sets <name>_BOARD.

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

# --- circuitpython helpers ----------------------------------------------------------------------

cpy_need_docker = have docker || die "docker not found: brew install --cask docker (or orbstack)"; \
  docker info >/dev/null 2>&1 || die "the Docker daemon is not running: start Docker";
# Ready for std_ready: the build image exists (a local docker call, no network; no docker or no daemon is not ready,
# and setup then says what is missing).
cpy_ready = docker image inspect "$($(1)_IMAGE)"
cpy_need_board =[ -n "$($(1)_BOARD)" ] || die "no board: set $(1)_BOARD in make/project.mk (a CircuitPython board name)";

cpy_setup = $(STD_FW_SH) $(cpy_need_docker) \
  if docker image inspect "$($(1)_IMAGE)" >/dev/null 2>&1 && [ "$(REBUILD)" != 1 ]; then ok "image $($(1)_IMAGE) (REBUILD=1 to rebuild it)"; exit 0; fi; \
  [ -f "$(CURDIR)/$($(1)_DOCKERFILE)" ] || die "no $($(1)_DOCKERFILE): the image that builds CircuitPython $($(1)_CP_VERSION) comes from it"; \
  say "docker build $($(1)_IMAGE) from $($(1)_DOCKERFILE)"; \
  docker build --tag "$($(1)_IMAGE)" --build-arg CP_VERSION=$($(1)_CP_VERSION) -f "$(CURDIR)/$($(1)_DOCKERFILE)" "$(CURDIR)/$(2)"; \
  ok "image $($(1)_IMAGE)"

# Builds ports/<port> for BOARD inside the image; a board dir in <dir>/boards/<board> is mounted
# over the image's copy. The images end up in <dir>/build/. The image may build as a user of its own (USER in the
# Dockerfile): on Linux (CI) that user cannot write a folder the runner owns, so build/ is opened to it first (v35;
# Docker Desktop on a Mac hides this).
cpy_build = $(STD_FW_SH) $(cpy_need_docker) $(call cpy_need_board,$(1)) \
  docker image inspect "$($(1)_IMAGE)" >/dev/null 2>&1 || die "image $($(1)_IMAGE) missing: run make $(1)-setup"; \
  out="$(CURDIR)/$(2)/build"; mkdir -p "$$out"; chmod a+rwx "$$out"; brd="$(CURDIR)/$(2)/boards/$($(1)_BOARD)"; \
  set -- -v "$$out:/out"; if [ -d "$$brd" ]; then set -- "$$@" -v "$$brd:$($(1)_CP_SRC)/ports/$($(1)_CP_PORT)/boards/$($(1)_BOARD)"; fi; \
  say "CircuitPython $($(1)_CP_VERSION) for $($(1)_BOARD) ($($(1)_CP_PORT)) into $(2)/build"; \
  docker run --rm "$$@" -e BOARD=$($(1)_BOARD) "$($(1)_IMAGE)" bash -c 'set -e; cd $($(1)_CP_SRC); \
    if [ -f ports/$($(1)_CP_PORT)/esp-idf/export.sh ]; then . ports/$($(1)_CP_PORT)/esp-idf/export.sh >/dev/null 2>&1; fi; \
    make -C ports/$($(1)_CP_PORT) BOARD=$($(1)_BOARD) -j"$$(nproc)"; cp ports/$($(1)_CP_PORT)/build-$($(1)_BOARD)/firmware.* /out/'; \
  ls "$$out"/firmware.* >/dev/null 2>&1 || die "the build left no firmware.* in $(2)/build"; \
  ok "built $$(ls "$$out"/firmware.* | tr '\n' ' ')"

cpy_check = $(STD_FW_SH) src="$(CURDIR)/$(2)/src"; [ -d "$$src" ] || die "no $(2)/src"; \
  if have ruff; then say "ruff check $(2)/src"; ruff check "$$src"; \
  else say "python syntax check of $(2)/src"; find "$$src" -name '*.py' -print0 | xargs -0 -n 1 python3 -m py_compile; fi; \
  find "$$src" -name '__pycache__' -type d -prune -exec rm -rf {} +; ok "$(1): src checked"

cpy_flash = $(STD_FW_SH) img="$(CURDIR)/$(2)/build/$($(1)_IMAGE_FILE)"; [ -f "$$img" ] || die "no $$img: run make $(1)-build"; \
  case "$($(1)_P)" in \
    esptool) have esptool.py || have esptool || die "esptool not found: brew install esptool"; $(STD_FW_PORT) \
      et=esptool; have esptool || et=esptool.py; "$$et" --chip $($(1)_CHIP) -p "$$port" write_flash -z 0x0 "$$img";; \
    uf2) vol="$($(1)_UF2_VOLUME)"; [ -d "$$vol" ] || die "$$vol is not mounted: double tap reset to get the UF2 bootloader drive"; cp "$$img" "$$vol/"; sync;; \
    *) die "PROBE=$($(1)_P): circuitpython flashes with esptool or uf2";; \
  esac; \
  ok "flashed $$img"

cpy_erase = $(STD_FW_SH) $(STD_FW_PORT) et=esptool; have esptool || et=esptool.py; have "$$et" || die "esptool not found: brew install esptool"; \
  "$$et" --chip $($(1)_CHIP) -p "$$port" erase_flash; ok "$(1): flash erased (CIRCUITPY is formatted again on the next boot)"

cpy_deploy = $(STD_FW_SH) src="$(CURDIR)/$(2)/src"; vol="$($(1)_VOLUME)"; \
  [ -d "$$src" ] || die "no $(2)/src"; [ -d "$$vol" ] || die "$$vol is not mounted: plug the board in (it shows up as CIRCUITPY)"; \
  say "copying $(2)/src to $$vol"; cp -R "$$src/." "$$vol/"; sync; ok "$(1): code on $$vol (the board reloads it)"

cpy_doctor = $(STD_FW_SH) say "$(1): circuitpython $($(1)_CP_VERSION), board $($(1)_BOARD)"; \
  if have docker; then if docker info >/dev/null 2>&1; then ok "docker"; else bad "the Docker daemon is not running"; fi; else bad "docker: brew install --cask docker"; fi; \
  if [ -f "$(CURDIR)/$($(1)_DOCKERFILE)" ]; then ok "$($(1)_DOCKERFILE)"; else bad "no $($(1)_DOCKERFILE)"; fi; \
  if have docker && docker image inspect "$($(1)_IMAGE)" >/dev/null 2>&1; then ok "image $($(1)_IMAGE)"; else warn "image $($(1)_IMAGE) not built: make $(1)-setup"; fi; \
  if [ -n "$($(1)_BOARD)" ]; then ok "board $($(1)_BOARD)"; else bad "no board: set $(1)_BOARD"; fi; \
  $(call std_doctor_started,$(1),$(2)) \
  if [ "$($(1)_P)" = esptool ]; then if have esptool || have esptool.py; then ok "esptool"; else bad "esptool: brew install esptool"; fi; fi; \
  if [ -d "$($(1)_VOLUME)" ]; then ok "$($(1)_VOLUME) mounted"; else warn "$($(1)_VOLUME) not mounted (needed by make $(1)-deploy)"; fi; \
  $(std_fw_ports_check) \
  $(call std_fw_doctor_end,$(1))

cpy_monitor = $(STD_FW_SH) $(STD_FW_PORT) $(STD_FW_LOGGED) \
  have $(firstword $($(1)_MONITOR)) || die "$(firstword $($(1)_MONITOR)) not found: brew install $(firstword $($(1)_MONITOR))"; \
  logged "$(CURDIR)/$(2)/build/monitor.log" $($(1)_MONITOR) "$$port"

cpy_release = $(STD_FW_SH) f="$(CURDIR)/$(2)/build/$($(1)_IMAGE_FILE)"; $(call std_fw_release,$(1),$(2),$($(1)_BOARD)-$($(1)_IMAGE_FILE))

# GitHub Release assets: the interpreter images of the build (<board>-firmware.uf2 / .bin, at least one) and
# <part>-<version>-code.zip, the code bundle (the content of <dir>/src: code.py, lib/ ...).
cpy_release_assets = $(STD_FW_SH) $(call cpy_need_board,$(1)) $(call std_rel_begin,$(1),circuitpython,$(2)) \
  imgs=0; for x in uf2 bin; do if put "$(CURDIR)/$(2)/build/firmware.$$x" "$($(1)_BOARD)-firmware.$$x"; then imgs=$$((imgs + 1)); fi; done; \
  [ "$$imgs" -gt 0 ] || die "no firmware.uf2 or firmware.bin in $(2)/build: run make $(1)-build"; \
  zipdir "$(CURDIR)/$(2)/src" "$(1)-$$ver-code.zip"; \
  $(std_rel_end)

# --- the kind -----------------------------------------------------------------------------------
#
# A CircuitPython part: the interpreter image is built in Docker (nothing to install on the Mac
# but Docker), the Python code in <dir>/src is copied to the CIRCUITPY drive.
# Per-part settings (make/project.mk, <part>_<VAR>), with their defaults:
#   BOARD        CircuitPython board name (required); a custom board lives in <dir>/boards/<board>
#   CP_VERSION   10.3.1     passed to the Dockerfile as the CP_VERSION build argument
#   CP_PORT      espressif  the ports/<port> to build;  CP_SRC  /circuitpython  source dir in the image
#   DOCKERFILE   <dir>/Dockerfile;  IMAGE  <project>-<part>-circuitpython:<CP_VERSION> (local only)
#   IMAGE_FILE   firmware.bin (firmware.uf2 for UF2 ports)
#   PROBE        esptool    esptool (with CHIP, default esp32s3) or uf2 (copies to UF2_VOLUME)
#   VOLUME       /Volumes/CIRCUITPY;  UF2_VOLUME  /Volumes/BOOT
#   MONITOR      tio -b BAUD (BAUD 115200), the REPL;  PROVISION, OTA_*, WRANGLER, RELEASE_HOOK
# `make <part>-deploy` copies the code; it is an extra, so `make deploy` (cloud) never touches a board.

define kind_circuitpython
# the part is started once its folder has src (its code) (std_started in common.mk): until then setup, check and build
# skip it and flash and release refuse
$(1)_START ?= src
$(1)_BOARD ?=
$(1)_CP_VERSION ?= 10.3.1
$(1)_CP_PORT ?= espressif
$(1)_CP_SRC ?= /circuitpython
$(1)_DOCKERFILE ?= $(2)/Dockerfile
$(1)_IMAGE ?= $$(PROJECT)-$(1)-circuitpython:$$($(1)_CP_VERSION)
$(1)_IMAGE_FILE ?= firmware.bin
$(1)_PROBE ?= esptool
$(1)_CHIP ?= esp32s3
$(1)_VOLUME ?= /Volumes/CIRCUITPY
$(1)_UF2_VOLUME ?= /Volumes/BOOT
$(1)_BAUD ?= 115200
$(1)_MONITOR ?= tio -b $$($(1)_BAUD)
$(1)_PROVISION ?=
$(1)_OTA_BUCKET ?= $$(OTA_BUCKET)
# no OTA bucket (no Cloudflare in the project): <part>-release publishes nothing, and help leaves it out
STD_HELP_HIDE += $$(if $$(strip $$($(1)_OTA_BUCKET)),,$(1)-release)
$(1)_OTA_PREFIX ?= $$(PROJECT)/$(1)/$$(ENV)
$(1)_WRANGLER ?= npx --yes wrangler@4
$(1)_RELEASE_HOOK ?=
$(1)_P = $$(or $$(PROBE),$$($(1)_PROBE))

.PHONY: $(1)-release-run $(1)-doctor $(1)-setup $(1)-check $(1)-build $(1)-clean $(1)-distclean $(1)-flash $(1)-erase $(1)-monitor $(1)-deploy $(1)-release $(1)-version $(1)-provision

$(call std_verb,$(1),doctor,firmware,Check Docker and the build image and board and CIRCUITPY read only)
$(1)-doctor:
	@$$(call cpy_doctor,$(1),$(2))

$(call std_verb,$(1),setup,firmware,Build the Docker image that builds CircuitPython $$($(1)_CP_VERSION) and REBUILD=1 to redo it)
$(1)-setup:
	@$$(call std_skip_unstarted,$(1),$(2),setup) $$(call cpy_setup,$(1),$(2))

# The build runs in the image setup builds: it builds the image first when it is missing (std_ready in common.mk).
# flash, release and release-assets build through it.
$(call std_ready,$(1),$(2),cpy_ready,build)

$(call std_verb,$(1),check,firmware,Lint the code in $(2)/src with ruff or a python syntax check)
$(1)-check:
	@$$(call std_skip_unstarted,$(1),$(2),check) $$(call cpy_check,$(1),$(2))

$(call std_verb,$(1),build,firmware,Build the CircuitPython image for $$($(1)_BOARD) in Docker into $(2)/build)
$(1)-build:
	@$$(call std_skip_unstarted,$(1),$(2),build) $$(call cpy_build,$(1),$(2))

$(call std_verb,$(1),flash,firmware,Flash the CircuitPython image with esptool or uf2 and NOBUILD=1 to skip the build)
$(1)-flash: $$(if $$(NOBUILD),,$(1)-build)
	@$$(call std_refuse_unstarted,$(1),$(2),flash) $$(call cpy_flash,$(1),$(2))

$(call std_verb,$(1),erase,firmware,Erase the whole flash and CIRCUITPY with it and needs CONFIRM=erase)
$(1)-erase:
	@$$(call std_confirm,erase) && { $$(call cpy_erase,$(1),$(2)); }

$(call std_extra,$(1),deploy,firmware,Copy $(2)/src to the CIRCUITPY drive)
$(1)-deploy:
	@$$(call cpy_deploy,$(1),$(2))

$(call std_verb,$(1),monitor,firmware,Serial REPL on PORT or the only port and logged to $(2)/build/monitor.log)
$(1)-monitor:
	@$$(call cpy_monitor,$(1),$(2))

$(call std_extra,$(1),provision,firmware,Per device setup SERIAL= through $(1)_PROVISION else flash only)
$(1)-provision:
	@$$(call std_fw_provision,$(1))

$(call std_verb,$(1),release,release,CircuitPython image to the OTA store as ver and latest with ENV= and PROMOTE=1 for stable)
$(1)-release:
	@if [ -z "$$(strip $$($(1)_OTA_BUCKET))" ]; then echo "> $(1): no OTA bucket (no Cloudflare in this project): firmware publish skipped"; exit 0; fi; if $$(call std_fw_tag_ok,$(1)); then $$(MAKE) --no-print-directory $(1)-release-run; else echo "$(1): tag $$$$CI_COMMIT_TAG is not a $(1) release, nothing to do"; fi

$(1)-release-run:
	@$$(call std_refuse_unstarted,$(1),$(2),release) $$(std_production_guard) && { $$(std_fw_remote_env); } && $$(if $$(NOBUILD),true,$$(MAKE) --no-print-directory $(1)-build) && { $$(call cpy_release,$(1),$(2)); }

$(call std_verb,$(1),version,release,Code version from $(2)/VERSION)

$(call std_release,$(1),circuitpython,$(2),cpy_release_assets,build)
$(1)-version:
	@$$(call std_fw_print_version,$(1),$(2))

$(call std_verb,$(1),clean,firmware,Remove $(2)/build)
$(1)-clean:
	@rm -rf "$$(CURDIR)/$(2)/build"

$(call std_verb,$(1),distclean,firmware,Remove $(2)/build and the local build image)
$(1)-distclean: $(1)-clean
	@if command -v docker >/dev/null 2>&1; then docker image rm "$$($(1)_IMAGE)" >/dev/null 2>&1 || true; fi
endef
