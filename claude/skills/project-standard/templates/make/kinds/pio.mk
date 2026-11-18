# project-standard v1.7 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind pio: a PlatformIO firmware part (platformio.ini in the part dir).
#
# make/project.mk declares it as   <name>:pio[:<dir>]   and may set <name>_PIO_ENV.
# PlatformIO is the one mise pins (mise.toml), not a per-project venv.
#
# One env per board: the targets that talk to a connected board (flash, erase, monitor, debug,
# provision) run for exactly one env. With no PIO_ENV= and no <name>_PIO_ENV they read the
# default_envs of platformio.ini (or PLATFORMIO_DEFAULT_ENVS), else its [env:*] sections, and refuse
# when that is more than one: `default_envs = rev3, rev4` must never upload both images to one board.
# build, check, test, size and clean still run every default env.

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

# --- pio helpers --------------------------------------------------------------------------------

pio_need = have pio || die "pio not found: PlatformIO comes from mise (mise.toml pins platformio; run make setup)";
pio_e = $(if $($(1)_E),-e $($(1)_E))

# awk program, one env name per line: default_envs of the [platformio] section (commas, spaces,
# indented continuation lines, ; and \# comments), or every [env:NAME] when there is none or it is empty.
pio_envs_awk = awk 'function names(v) { sub(/^[ \t]*/, "", v); sub(/[ \t]+[;\#].*$$/, "", v); return v } \
  { sub(/\r$$/, "") } \
  /^[ \t]*[;\#]/ { next } \
  /^\[/ { sec = $$0; sub(/\].*$$/, "]", sec); cont = 0; \
    if (sec ~ /^\[env:[^]]+\]$$/) { n = sec; sub(/^\[env:/, "", n); sub(/\]$$/, "", n); all = all " " n } next } \
  cont && /^[ \t]+[^ \t]/ { dflt = dflt " " names($$0); next } \
  { cont = 0 } \
  sec == "[platformio]" && /^default_envs[ \t]*[=:]/ { v = $$0; sub(/^[^=:]*[=:]/, "", v); dflt = names(v); cont = 1; next } \
  END { out = dflt; gsub(/[ \t,]+/, " ", out); if (out ~ /^ *$$/) out = all; \
    k = split(out, a, /[ \t,]+/); for (i = 1; i <= k; i++) if (a[i] != "") print a[i] }'

# $(call pio_one_env,part,dir,target): sets $$pio_env to the one env a board target runs for, else stops
# the shell (keep it on the line of the action). PIO_ENV= or <part>_PIO_ENV when set; else
# PLATFORMIO_DEFAULT_ENVS or the default_envs of platformio.ini, else its [env:*] sections.
pio_one_env = pio_env="$($(1)_E)"; ini="$(CURDIR)/$(2)/platformio.ini"; \
  if [ -n "$$pio_env" ]; then \
    case "$$pio_env" in *[,[:space:]]*) die "$(3): PIO_ENV=$$pio_env names several envs: this target talks to one board, give one env";; esac; \
  else \
    if [ -n "$${PLATFORMIO_DEFAULT_ENVS:-}" ]; then src=PLATFORMIO_DEFAULT_ENVS; envs=$$(printf '%s\n' "$$PLATFORMIO_DEFAULT_ENVS" | tr ', ' '\n\n' | grep . || true); \
    else [ -f "$$ini" ] || die "$(3): no $(2)/platformio.ini"; src="$(2)/platformio.ini"; envs=$$($(pio_envs_awk) "$$ini"); fi; \
    n=$$(printf '%s' "$$envs" | grep -c . || true); \
    [ "$$n" -gt 0 ] || die "$(3): no env in $$src: add an [env:NAME] section or pass PIO_ENV=<env>"; \
    [ "$$n" -eq 1 ] || die "$(3) talks to one board but $$src selects $$n envs ($$(echo $$envs)): pick the board's env with PIO_ENV=<env> (make $(3) PIO_ENV=$$(echo $$envs | cut -d' ' -f1)) or set $(1)_PIO_ENV in make/project.mk"; \
    pio_env="$$envs"; say "$(3): env $$pio_env (the only one in $$src)"; \
  fi;

# $(call pio_board_run,part,dir,target,pio run args): pio run for the one env of a board target.
pio_board_run = $(STD_FW_SH) $(pio_need) $(call pio_one_env,$(1),$(2),$(3)) pio run -d "$(CURDIR)/$(2)" -e "$$pio_env" $(4)
pio_run = $(STD_FW_SH) $(pio_need) pio run -d "$(CURDIR)/$(2)" $(call pio_e,$(1)) $(3)

# Upload port: PORT=, else the only serial port when there is exactly one, else PlatformIO decides
# (non-serial upload protocols such as stlink need none).
pio_port = up="$(PORT)"; if [ -z "$$up" ]; then list=$$(ports); n=$$(printf '%s' "$$list" | grep -c . || true); \
  if [ "$$n" -eq 1 ]; then up="$$list"; elif [ "$$n" -gt 1 ]; then die "several serial ports, pick one with PORT=...: $$(echo $$list)"; fi; fi;

# PlatformIO does not regenerate an existing sdkconfig.<env> when sdkconfig.defaults changes.
pio_sdkconfig = $(if $($(1)_E),sd="$(CURDIR)/$(2)/sdkconfig.$($(1)_E)"; dflt="$(CURDIR)/$(2)/sdkconfig.defaults"; \
  if [ -f "$$sd" ] && [ -f "$$dflt" ] && [ "$$dflt" -nt "$$sd" ]; then warn "sdkconfig.defaults changed: removing sdkconfig.$($(1)_E) so it is regenerated"; rm -f "$$sd"; fi;)

pio_build = $(STD_FW_SH) $(pio_need) $(call pio_sdkconfig,$(1),$(2)) say "pio run $(1)$(if $($(1)_E), -e $($(1)_E))"; \
  pio run -d "$(CURDIR)/$(2)" $(call pio_e,$(1)); ok "built $(1)"

pio_has_test_env = grep -q '^\[env:$($(1)_TEST_ENV)\]' "$(CURDIR)/$(2)/platformio.ini" 2>/dev/null

pio_test = $(STD_FW_SH) $(pio_need) \
  if $(call pio_has_test_env,$(1),$(2)); then pio test -d "$(CURDIR)/$(2)" -e $($(1)_TEST_ENV) $(if $(TEST),-f '$(TEST)'); \
  else say "$(1): no [env:$($(1)_TEST_ENV)] in platformio.ini, no host tests"; fi

pio_check = $(STD_FW_SH) $(pio_need) say "pio check $(1)"; \
  pio check -d "$(CURDIR)/$(2)" $(call pio_e,$(1)) --fail-on-defect=$($(1)_CHECK_SEVERITY) --skip-packages; \
  $(call pio_test,$(1),$(2))

pio_update = $(STD_FW_SH) $(pio_need) say "pio pkg update for $(1) within the ranges of platformio.ini"; pio pkg update -d "$(CURDIR)/$(2)" $(call pio_e,$(1))
pio_debug = $(STD_FW_SH) $(pio_need) $(call pio_one_env,$(1),$(2),$(1)-debug) pio debug -d "$(CURDIR)/$(2)" -e "$$pio_env" --interface=gdb -- -x .pioinit
pio_setup =$(STD_FW_SH) $(pio_need) say "pio pkg install for $(1)"; pio pkg install -d "$(CURDIR)/$(2)" $(call pio_e,$(1)); \
  mkdir -p "$(CURDIR)/$(2)/.pio" && touch "$(CURDIR)/$(2)/.pio/.std-setup"; ok "$(1): PlatformIO packages installed"
# Ready for std_ready: setup's stamp (.pio/.std-setup) is there and platformio.ini has not changed since. pio itself comes
# from mise (the root setup), not from the part's setup, so it is not looked at here.
pio_ready = $(call std_fresh,$(CURDIR)/$(2),.pio/.std-setup,platformio.ini)

pio_doctor = $(STD_FW_SH) say "$(1): pio$(if $($(1)_E), env $($(1)_E))"; \
  if have pio; then ok "$$(pio --version 2>/dev/null | head -n 1)"; else bad "pio missing: mise install (mise.toml pins platformio)"; fi; \
  $(call std_doctor_started,$(1),$(2)) \
  $(if $($(1)_E),if [ -f "$(CURDIR)/$(2)/platformio.ini" ] && ! grep -q '^\[env:$($(1)_E)\]' "$(CURDIR)/$(2)/platformio.ini"; then bad "no [env:$($(1)_E)] in platformio.ini"; fi;) \
  if [ -d "$(CURDIR)/$(2)/.pio" ]; then ok "packages and build in $(2)/.pio"; else warn "nothing built yet: make $(1)-setup then make $(1)-build"; fi; \
  $(std_fw_ports_check) \
  $(call std_fw_doctor_end,$(1))

pio_flash = $(STD_FW_SH) $(pio_need) $(call pio_one_env,$(1),$(2),$(1)-flash) $(pio_port) \
  case "$($(1)_P)" in pio|esptool) ;; *) die "PROBE=$($(1)_P): pio uploads with the upload_protocol of platformio.ini (PROBE=pio)";; esac; \
  pio run -d "$(CURDIR)/$(2)" -e "$$pio_env" -t upload $$( [ -z "$$up" ] || printf -- '--upload-port %s' "$$up" ); ok "uploaded $(1)"

pio_monitor = $(STD_FW_SH) $(pio_need) $(call pio_one_env,$(1),$(2),$(1)-monitor) $(STD_FW_PORT) $(STD_FW_LOGGED) \
  logged "$(CURDIR)/$(2)/build/monitor.log" pio device monitor -d "$(CURDIR)/$(2)" -e "$$pio_env" -p "$$port"

# Provision runs for one env too: it is exported as PIO_ENV to <part>_PROVISION and to the flash it falls back to.
pio_provision = $(STD_FW_SH) $(call pio_one_env,$(1),$(2),$(1)-provision) export PIO_ENV="$$pio_env"; $(call std_fw_provision,$(1))

pio_release = $(STD_FW_SH) f="$(CURDIR)/$(2)/.pio/build/$($(1)_E)/$($(1)_IMAGE)"; $(call std_fw_release,$(1),$(2),$(or $($(1)_E),firmware)-$($(1)_IMAGE))

# GitHub Release assets: one set per env the build makes (PIO_ENV, else default_envs, else every [env:*]), each
# file prefixed with its env: <env>-firmware.bin / .hex / .uf2 (at least one) and <env>-firmware.elf.
pio_release_assets = $(STD_FW_SH) ini="$(CURDIR)/$(2)/platformio.ini"; \
  if [ -n "$($(1)_E)" ]; then envs=$$(printf '%s\n' "$($(1)_E)" | tr ', ' '\n\n' | grep . || true); \
  elif [ -n "$${PLATFORMIO_DEFAULT_ENVS:-}" ]; then envs=$$(printf '%s\n' "$$PLATFORMIO_DEFAULT_ENVS" | tr ', ' '\n\n' | grep . || true); \
  else [ -f "$$ini" ] || die "no $(2)/platformio.ini"; envs=$$($(pio_envs_awk) "$$ini"); fi; \
  [ -n "$$envs" ] || die "$(1): no env to release"; \
  $(call std_rel_begin,$(1),pio,$(2)) \
  for e in $$envs; do bd="$(CURDIR)/$(2)/.pio/build/$$e"; [ -d "$$bd" ] || die "no build for env $$e in $$bd: run make $(1)-build"; \
    imgs=0; for x in bin hex uf2; do if put "$$bd/firmware.$$x" "$$e-firmware.$$x"; then imgs=$$((imgs + 1)); fi; done; \
    [ "$$imgs" -gt 0 ] || die "env $$e: no firmware.bin, .hex or .uf2 in $$bd"; \
    need "$$bd/firmware.elf" "$$e-firmware.elf"; done; \
  $(std_rel_end)

# --- the kind -----------------------------------------------------------------------------------
#
# Per-part settings (make/project.mk, <part>_<VAR>), with their defaults:
#   PIO_ENV        empty: the default_envs of platformio.ini; PIO_ENV= on the command line wins.
#                  Release needs one env (its image is .pio/build/<env>/IMAGE); so do flash, erase,
#                  monitor, debug and provision, which take the only default env when there is one.
#   IMAGE          firmware.bin   the file release uploads
#   TEST_ENV       native         the host env `make <part>-test` runs (pio test -e native)
#   CHECK_SEVERITY high           pio check --fail-on-defect
#   PROBE          pio            uploads use upload_protocol from platformio.ini
#   PROVISION, OTA_BUCKET, OTA_PREFIX, WRANGLER, RELEASE_HOOK   as in the zephyr kind
# PlatformIO itself is pinned in mise.toml ("pipx:platformio" = "6"); its packages live in ~/.platformio.

define kind_pio
# the part is started once its folder has its platformio.ini (std_started in common.mk): until then setup, check and build
# skip it and flash and release refuse
$(1)_START ?= platformio.ini
$(1)_PIO_ENV ?=
$(1)_IMAGE ?= firmware.bin
$(1)_TEST_ENV ?= native
$(1)_CHECK_SEVERITY ?= high
$(1)_PROBE ?= pio
$(1)_PROVISION ?=
$(1)_OTA_BUCKET ?= $$(OTA_BUCKET)
# no OTA bucket (no Cloudflare in the project): <part>-release publishes nothing, and help leaves it out
STD_HELP_HIDE += $$(if $$(strip $$($(1)_OTA_BUCKET)),,$(1)-release)
$(1)_OTA_PREFIX ?= $$(PROJECT)/$(1)/$$(ENV)
$(1)_WRANGLER ?= npx --yes wrangler@4
$(1)_RELEASE_HOOK ?=
$(1)_E = $$(or $$(PIO_ENV),$$($(1)_PIO_ENV))
$(1)_P = $$(or $$(PROBE),$$($(1)_PROBE))

.PHONY: $(1)-release-run $(1)-doctor $(1)-setup $(1)-update $(1)-check $(1)-test $(1)-build $(1)-clean $(1)-distclean $(1)-flash $(1)-erase $(1)-monitor $(1)-debug $(1)-release $(1)-version $(1)-size $(1)-config $(1)-provision

$(call std_verb,$(1),doctor,firmware,Check pio and platformio.ini and ports read only)
$(1)-doctor:
	@$$(call pio_doctor,$(1),$(2))

$(call std_verb,$(1),setup,firmware,Install the platforms and libraries of platformio.ini)
$(1)-setup:
	@$$(call std_skip_unstarted,$(1),$(2),setup) $$(call pio_setup,$(1),$(2))

# The commands that run pio on the project install its platforms and libraries first when setup has not run since
# platformio.ini last changed (std_ready in common.mk).
$(call std_ready,$(1),$(2),pio_ready,check test build flash erase monitor debug size config)

$(call std_verb,$(1),update,firmware,Update the PlatformIO platforms and libraries within platformio.ini)
$(1)-update:
	@$$(call pio_update,$(1),$(2))

$(call std_verb,$(1),check,firmware,pio check static analysis then the native host tests)
$(1)-check:
	@$$(call std_skip_unstarted,$(1),$(2),check) $$(call pio_check,$(1),$(2))

$(call std_verb,$(1),test,firmware,Host tests with pio test -e native and TEST=pattern for one)
$(1)-test:
	@$$(call std_skip_unstarted,$(1),$(2),test) $$(call pio_test,$(1),$(2))

$(call std_verb,$(1),build,firmware,pio run for PIO_ENV $$($(1)_E))
$(1)-build:
	@$$(call std_skip_unstarted,$(1),$(2),build) $$(call pio_build,$(1),$(2))

$(call std_verb,$(1),flash,firmware,Upload one env with pio on PORT or the only port and NOBUILD is ignored as pio builds first)
$(1)-flash:
	@$$(call std_refuse_unstarted,$(1),$(2),flash) $$(call pio_flash,$(1),$(2))

$(call std_verb,$(1),erase,firmware,pio run -t erase for one env and needs CONFIRM=erase)
$(1)-erase:
	@$$(call std_confirm,erase) && { $$(call pio_board_run,$(1),$(2),$(1)-erase,-t erase); }

$(call std_verb,$(1),monitor,firmware,pio device monitor for one env on PORT or the only port and logged to $(2)/build/monitor.log)
$(1)-monitor:
	@$$(call pio_monitor,$(1),$(2))

$(call std_verb,$(1),debug,firmware,pio debug for one env with GDB through the debug_tool of platformio.ini)
$(1)-debug:
	@$$(call pio_debug,$(1),$(2))

$(call std_extra,$(1),size,firmware,RAM and flash use of the build)
$(1)-size:
	@$$(call pio_run,$(1),$(2),-t size)

$(call std_extra,$(1),config,firmware,menuconfig for ESP-IDF based envs)
$(1)-config:
	@$$(call pio_run,$(1),$(2),-t menuconfig)

$(call std_extra,$(1),provision,firmware,Per device setup SERIAL= for one env through $(1)_PROVISION else flash only)
$(1)-provision:
	@$$(call pio_provision,$(1),$(2))

$(call std_verb,$(1),release,release,Image of PIO_ENV to the OTA store as ver and latest with ENV= and PROMOTE=1 for stable)
$(1)-release:
	@if [ -z "$$(strip $$($(1)_OTA_BUCKET))" ]; then echo "> $(1): no OTA bucket (no Cloudflare in this project): firmware publish skipped"; exit 0; fi; if $$(call std_fw_tag_ok,$(1)); then $$(MAKE) --no-print-directory $(1)-release-run; else echo "$(1): tag $$$$CI_COMMIT_TAG is not a $(1) release, nothing to do"; fi

$(1)-release-run:
	@$$(call std_refuse_unstarted,$(1),$(2),release) $$(std_production_guard) && { $$(std_fw_remote_env); } && { $$(if $$($(1)_E),true,echo "release needs one env: set $(1)_PIO_ENV or pass PIO_ENV=" >&2; exit 1); } && $$(if $$(NOBUILD),true,$$(MAKE) --no-print-directory $(1)-build) && { $$(call pio_release,$(1),$(2)); }

$(call std_verb,$(1),version,release,Firmware version from $(2)/VERSION)

$(call std_release,$(1),pio,$(2),pio_release_assets,build)
$(1)-version:
	@$$(call std_fw_print_version,$(1),$(2))

$(call std_verb,$(1),clean,firmware,pio run -t clean)
$(1)-clean:
	@$$(call pio_run,$(1),$(2),-t clean)

$(call std_verb,$(1),distclean,firmware,Remove $(2)/.pio and $(2)/build and the project-local PlatformIO core $(2)/.platformio)
$(1)-distclean:
	@rm -rf "$$(CURDIR)/$(2)/.pio" "$$(CURDIR)/$(2)/build" "$$(CURDIR)/$(2)/.platformio"
endef
