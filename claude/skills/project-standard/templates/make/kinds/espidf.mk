# project-standard v1.12 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind espidf: an ESP-IDF firmware part (idf.py, one build per chip target).
#
# make/project.mk declares it as   <name>:espidf[:<dir>]   and may set <name>_TARGET (esp32c6).
# ESP-IDF is pinned per part and cloned once into $(STD_TOOLCHAINS)/esp-idf-<ver>, shared across
# projects. Every target has its own build dir and sdkconfig, so the images of two boards can never
# overwrite each other. Flash encryption and secure boot are checked against the chip's eFuses before
# anything is written; eFuse burns are extras that need CONFIRM=fuse.

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
  [ -z "$${image_sha:-}" ] || [ "$$sha" = "$$image_sha" ] || die "$$f is not the image its check passed (sha256 $$sha, the build recorded $$image_sha): nothing was uploaded"; \
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

# Per-environment defines (1.8). <part>_ENV_DEFINES_<env> := NAME=value NAME2="a string" in make/project.mk, for env
# local, staging or production: C preprocessor defines that every compile of the part gets for ENV (make <part>-build
# ENV=staging; flash and release build first). Words split at spaces outside double quotes; a double-quoted value keeps
# its quotes, so it is a C string literal. No setting for ENV: no defines, the code's own defaults apply. A build
# records them in <build dir>/std-env (env=<ENV>, then one define per line): a build whose stamp differs from ENV's
# defines is made again from scratch, and a flash or release of such a build (NOBUILD=1) refuses.
# 1.12: a build folder that has no stamp is made again from scratch too, and the defines reach the build tool on every
# build, an empty set included (it clears a set a cache such as CMakeCache.txt kept). The build also records the sha256
# of the images it made (<build dir>/std-env.sha256), and std_fw_env_check compares them right before a flash or upload,
# so an image another build replaced is never shipped. Every build, flash and release holds the build folder's lock.
std_fw_env_defs = $(strip $($(1)_ENV_DEFINES_$(ENV)))
# $(call std_fw_env_sh,part): sets $$envdefs (one define per line, empty without a setting), $$envflags (each define as
# a single-quoted shell word '-DNAME=value', for a compiler run through a shell, a CMake UNIX_COMMAND list and
# PlatformIO's build flags) and $$envlist (the defines as a CMake list, ;-separated). A malformed setting stops.
std_fw_env_sh = envraw='$(subst ','\'',$(call std_fw_env_defs,$(1)))'; \
  envdefs=$$(printf '%s\n' "$$envraw" | awk '{ n = length($$0); w = ""; has = 0; q = 0; \
    for (i = 1; i <= n; i++) { c = substr($$0, i, 1); \
      if (c == "\\" && q && i < n) { w = w c substr($$0, i + 1, 1); i++; continue } \
      if (c == "\"") q = !q; \
      if (!q && (c == " " || c == "\t")) { if (has) print w; w = ""; has = 0; continue } \
      w = w c; has = 1 } \
    if (q) exit 3; if (has) print w }') || die "$(1)_ENV_DEFINES_$(ENV): a double quote is not closed"; \
  bad=$$(printf '%s\n' "$$envdefs" | grep -vE '^([A-Za-z_][A-Za-z0-9_]*(=.*)?)?$$' || true); \
  [ -z "$$bad" ] || die "$(1)_ENV_DEFINES_$(ENV): not NAME or NAME=value: $$(printf '%s\n' "$$bad" | paste -sd ' ' -)"; \
  envflags=$$(printf '%s\n' "$$envdefs" | awk 'NF { m = split($$0, p, "\047"); s = p[1]; for (j = 2; j <= m; j++) s = s "\047\\\047\047" p[j]; printf "%s\047-D%s\047", (k++ ? " " : ""), s }'); \
  envlist=$$(printf '%s\n' "$$envdefs" | paste -sd ';' -);
# after std_fw_env_sh: names the defines of ENV, when there are any
std_fw_env_say = [ -z "$$envdefs" ] || say "$(1): defines for ENV=$(ENV): $$(printf '%s\n' "$$envdefs" | paste -sd ' ' -)";
# $(call std_fw_env_old,build-dir): $$old (the defines its stamp records, empty without one) and $$oldenv (its ENV).
std_fw_env_old = old=; oldenv=; if [ -f "$(1)/std-env" ]; then old=$$(tail -n +2 "$(1)/std-env"); oldenv=$$(sed -n '1s/^env=//p' "$(1)/std-env"); fi;
# $(call std_fw_env_fresh,part,build-dir,wipe), after std_fw_env_sh and std_fw_lock, before a build: when the build in
# build-dir was made with other defines, or the folder holds files but no stamp (a cache in it may hold any defines),
# runs the shell command wipe, so it is made again. Then forgets the images it recorded: until the new build stamps
# them, a check refuses the folder (a build that fails or is stopped leaves none it would pass).
std_fw_env_fresh = $(call std_fw_env_old,$(2)) std_files=$$(ls -A "$(2)" 2>/dev/null || true); \
  if [ "$$old" != "$$envdefs" ] || { [ -n "$$std_files" ] && [ ! -f "$(2)/std-env" ]; }; then \
    if [ -f "$(2)/std-env" ]; then say "$(1): the build in $(2) was made for ENV=$${oldenv:-unknown}, ENV=$(ENV) has other defines: building it again from scratch"; \
    elif [ -n "$$std_files" ]; then say "$(1): the build in $(2) has no ENV stamp (std-env): building it again from scratch"; fi; $(3); fi; \
  rm -f "$(2)/std-env.sha256";
# Defines std_sha FILE: its sha256 (sha256sum, else shasum).
std_fw_sha_fn = std_sha() { { sha256sum "$$1" 2>/dev/null || shasum -a 256 "$$1"; } | cut -d' ' -f1; };
# $(call std_fw_env_stamp,build-dir,images), after a build and its signing: std-env (the ENV and its defines) and
# std-env.sha256, a line "<sha256>  <path>" for each of images (shell words, relative to build-dir or absolute) that is
# there. std-env.sha256 is written last, so a folder with one holds a finished build.
std_fw_env_stamp = mkdir -p "$(1)"; $(std_fw_sha_fn) std_dir="$(1)"; : > "$$std_dir/std-env.sha256.tmp"; \
  for std_img in $(2); do case "$$std_img" in /*) std_f="$$std_img";; *) std_f="$$std_dir/$$std_img";; esac; \
    if [ -f "$$std_f" ]; then printf '%s  %s\n' "$$(std_sha "$$std_f")" "$${std_img\#"$$std_dir/"}" >> "$$std_dir/std-env.sha256.tmp"; fi; done; \
  printf 'env=%s\n%s\n' "$(ENV)" "$$envdefs" > "$$std_dir/std-env"; mv "$$std_dir/std-env.sha256.tmp" "$$std_dir/std-env.sha256";
# $(call std_fw_env_check,part,build-dir[,image]): right before a flash or an upload, after std_fw_lock on build-dir (in
# the same shell as the flash or upload, so no build can change the folder in between). Refuses a build made with other
# defines than ENV's, and one whose recorded images are not the files there now (another build replaced them). With
# image (a file of the build, relative to build-dir or absolute), the build must have recorded it: a build from before
# 1.12, or one that failed or still runs, has no record and is refused. Sets $$image_sha to the image's sha256, which
# std_fw_release compares with what it uploads. A project's own OTA or upload target calls it the same way (SKILL.md).
std_fw_env_check = $(call std_fw_env_sh,$(1)) $(call std_fw_env_old,$(2)) \
  [ "$$old" = "$$envdefs" ] || die "the build in $(2) was made for ENV=$${oldenv:-unknown}, and $(1)_ENV_DEFINES_$(ENV) differs: build it again with ENV=$(ENV) (without NOBUILD=1)"; \
  $(std_fw_sha_fn) std_dir="$(2)"; std_rec="$$std_dir/std-env.sha256"; image_sha=; \
  $(if $(3),[ -f "$$std_rec" ] || die "the build in $(2) has no record of its images (std-env.sha256; a build from before 1.12 or one that failed or is still running): build it again with ENV=$(ENV) (without NOBUILD=1)";) \
  if [ -f "$$std_rec" ]; then while read -r std_h std_p; do [ -n "$$std_p" ] || continue; \
    case "$$std_p" in /*) std_f="$$std_p";; *) std_f="$$std_dir/$$std_p";; esac; \
    [ -f "$$std_f" ] || die "$$std_f is gone since the build that recorded it: build it again with ENV=$(ENV)"; \
    [ "$$(std_sha "$$std_f")" = "$$std_h" ] || die "$$std_f is not the image the build for ENV=$${oldenv:-unknown} made (another build changed it): build it again with ENV=$(ENV), one build per folder at a time"; \
  done < "$$std_rec"; fi; \
  $(if $(3),std_img="$(3)"; std_img="$${std_img\#"$$std_dir/"}"; image_sha=$$(awk -v p="$$std_img" '{ h = $$1; sub(/^[^ ]+  /, "") } $$0 == p { print h; exit }' "$$std_rec"); \
    [ -n "$$image_sha" ] || die "$(3) is not an image the build in $(2) recorded: build it again with ENV=$(ENV)";)

# Build-folder locks (1.12). A build, flash or release holds a lock on its build folder from before its ENV check to
# its stamp, flash or upload, so two runs never use one folder at once (two ENVs into one folder once shipped one ENV's
# image as the other's). A second run waits up to STD_FW_LOCK_WAIT seconds, then stops and names the run that holds it.
# The lock is a directory in TMPDIR named after the folder's path, with the pid of the shell holding it; it goes when
# that shell exits, and one whose pid is gone (a run that was killed) is taken over. A make run started inside the
# holding shell shares it (STD_FW_LOCKED, exported).
STD_FW_LOCK_WAIT ?= 10
# Defines std_fw_lock_take DIR WHAT, std_fw_unlock (all the locks the shell holds) and std_fw_alive PID.
STD_FW_LOCK_FN = std_fw_unlock() { for std_l in $${std_fw_lockdirs[@]+"$${std_fw_lockdirs[@]}"}; do rm -rf "$$std_l"; done; std_fw_lockdirs=(); }; \
  std_fw_alive() { std_e=$$(kill -0 "$$1" 2>&1) && return 0; case "$$std_e" in *ermitted*) return 0;; esac; return 1; }; \
  std_fw_lock_take() { std_d="$$1"; case "$$std_d" in /*) ;; *) std_d="$$PWD/$$std_d";; esac; std_d="$${std_d%/}"; \
    case ":$${STD_FW_LOCKED:-}:" in *":$$std_d:"*) return 0;; esac; \
    std_l="$${TMPDIR:-/tmp}"; std_l="$${std_l%/}/std-fw-lock-$$(printf '%s' "$$std_d" | cksum | tr ' ' -)"; std_w=0; \
    while ! mkdir "$$std_l" 2>/dev/null; do \
      std_p=$$(cat "$$std_l/pid" 2>/dev/null || true); \
      if [ -n "$$std_p" ] && ! std_fw_alive "$$std_p"; then \
        if mv "$$std_l" "$$std_l.stale.$$$$" 2>/dev/null; then \
          if [ "$$(cat "$$std_l.stale.$$$$/pid" 2>/dev/null || true)" = "$$std_p" ]; then warn "$$std_d: taking over the lock of pid $$std_p, which is gone (a run that was stopped)"; rm -rf "$$std_l.stale.$$$$"; \
          else mv "$$std_l.stale.$$$$" "$$std_l" 2>/dev/null || rm -rf "$$std_l.stale.$$$$"; fi; fi; continue; fi; \
      if [ -z "$$std_p" ] && [ "$$std_w" -ge 2 ]; then warn "$$std_d: taking over a lock that holds no pid ($$std_l)"; rm -rf "$$std_l"; continue; fi; \
      [ "$$std_w" -lt "$(STD_FW_LOCK_WAIT)" ] || die "$$std_d is in use by another run: pid $${std_p:-unknown} ($$(cat "$$std_l/what" 2>/dev/null || echo unknown)). Two builds or uploads in one build folder at once mix their images: wait for it to finish, then run this again. If no process $${std_p:-} is running, remove $$std_l"; \
      [ "$$std_w" -gt 0 ] || say "$$std_d is in use by pid $${std_p:-unknown} ($$(cat "$$std_l/what" 2>/dev/null || echo unknown)): waiting up to $(STD_FW_LOCK_WAIT)s"; \
      sleep 1; std_w=$$((std_w + 1)); \
    done; \
    printf '%s\n' "$$$$" > "$$std_l/pid"; printf '%s\n' "$$2" > "$$std_l/what"; \
    std_fw_lockdirs+=("$$std_l"); export STD_FW_LOCKED="$${STD_FW_LOCKED:+$$STD_FW_LOCKED:}$$std_d"; \
    trap 'std_fw_unlock' EXIT; trap 'std_fw_unlock; exit 130' INT; trap 'std_fw_unlock; exit 143' TERM HUP; };
# $(call std_fw_lock,build-dir,what): takes build-dir's lock for the rest of the shell; what (make <target> ENV=...) is
# shown to a run that has to wait. A trap on EXIT set after it replaces its own: such a trap calls std_fw_unlock.
std_fw_lock = $(STD_FW_LOCK_FN) std_fw_lock_take "$(1)" "$(2) ENV=$(ENV)";
# $(call std_fw_image_check,part,build-dir,image): for a project's own OTA or upload target (make/local.mk). In the
# recipe line that uploads, after $(STD_FW_SH) and before the upload: takes build-dir's lock for the rest of that shell
# (std_fw_lock: no build can replace the image until the upload is done), then std_fw_env_check with image: the build
# was made for ENV's defines and image is the file it recorded. Sets $$image_sha (its sha256).
std_fw_image_check = $(call std_fw_lock,$(2),make $(or $(MAKECMDGOALS),$(1) upload)) $(call std_fw_env_check,$(1),$(2),$(3))

endif

# --- espidf helpers -----------------------------------------------------------------------------

espidf_repo = https://github.com/espressif/esp-idf

# $(call espidf_env,part): the pinned ESP-IDF environment (export.sh) in the current shell. In CI
# an image that brings its own ESP-IDF (IDF_PATH) is used when the pinned one is not installed.
espidf_env = if [ -f "$($(1)_IDF_DIR)/export.sh" ]; then idf_dir="$($(1)_IDF_DIR)"; export IDF_TOOLS_PATH="$($(1)_IDF_TOOLS)"; \
  elif [ -n "$${CI:-}" ] && [ -f "$${IDF_PATH:-/nonexistent}/export.sh" ]; then idf_dir="$$IDF_PATH"; \
  else die "ESP-IDF $($(1)_IDF) is not in $($(1)_IDF_DIR): run make $(1)-setup"; fi; \
  set +eu; . "$$idf_dir/export.sh" >/dev/null 2>&1; rc=$$?; set -eu; \
  [ "$$rc" -eq 0 ] || die "sourcing $$idf_dir/export.sh failed: run make $(1)-setup"; \
  have idf.py || die "idf.py not found after export.sh: run make $(1)-setup";

# idf.py for the part's target: build/<target>, sdkconfig.<target>
espidf_idf = idf.py -C "$(CURDIR)/$(2)" -B "$($(1)_BUILD)" -D SDKCONFIG="$(CURDIR)/$(2)/sdkconfig.$($(1)_T)" -D IDF_TARGET=$($(1)_T) $($(1)_IDF_ARGS)
espidf_need_build = b="$($(1)_BUILD)"; [ -d "$$b" ] || die "no build in $$b: run make $(1)-build";
espidf_app_bin = app=$$(sed -nE 's/.*"app_bin":[[:space:]]*"([^"]*)".*/\1/p' "$$b/project_description.json" 2>/dev/null || true); \
  [ -n "$$app" ] || die "no app_bin in $$b/project_description.json: run make $(1)-build";

# Secure boot v2: the build leaves the bootloader and app unsigned
# (CONFIG_SECURE_BOOT_BUILD_SIGNED_BINARIES=n) and they are signed here with the key from the
# secrets repo. An image that already carries a signature is left alone.
espidf_sign = $(call espidf_app_bin,$(1)) set -- "$$b/bootloader/bootloader.bin" "$$b/$$app"; \
  say "signing $$* with $(if $(SIGNING_KEY),$(SIGNING_KEY),$($(1)_KEY)) (secure boot v2)"; \
  $(call std_fw_with_key,$($(1)_KEY)) bash -c 'set -euo pipefail; key="$$0"; for f in "$$@"; do \
    if python -m espsecure signature_info_v2 "$$f" >/dev/null 2>&1; then echo "  already signed: $$f"; continue; fi; \
    python -m espsecure sign_data --version 2 --keyfile "$$key" --output "$$f.signed" "$$f"; mv "$$f.signed" "$$f"; done' "$(std_fw_keyarg)" "$$@";

# The defines of ENV (std_fw_env_sh) reach idf.py as the CMake list STD_ENV_DEFINES, which the project's top
# CMakeLists.txt applies before project() (reference/standard.md 4.9): idf.py has no option for a C define. Sets
# $$envargs. A CMakeLists.txt that applies it gets it on every build, empty for an ENV without defines: STD_ENV_DEFINES is
# a CMake cache variable, kept until it is set again, so leaving it out built with the last ENV's defines (1.12).
espidf_env_cmake = envargs=(); \
  if [ -n "$$envdefs" ]; then \
    case "$$envdefs" in *';'*) die "$(1)_ENV_DEFINES_$(ENV): ESP-IDF gets the defines as a CMake list, so a value cannot hold a ;";; esac; \
    grep -q 'STD_ENV_DEFINES' "$(CURDIR)/$(2)/CMakeLists.txt" 2>/dev/null || die "$(1)_ENV_DEFINES_$(ENV) is set but $(2)/CMakeLists.txt does not apply STD_ENV_DEFINES, so the build would leave the defines out: add the project-standard block after include(.../project.cmake) and before project() (reference/standard.md 4.9; make audit prints it)"; \
  fi; \
  if grep -q 'STD_ENV_DEFINES' "$(CURDIR)/$(2)/CMakeLists.txt" 2>/dev/null; then envargs=(-D "STD_ENV_DEFINES=$$envlist"); fi;

# The images a build records (std_fw_env_stamp): the app (app_bin of project_description.json), bootloader, partition table.
espidf_images = app=$$(sed -nE 's/.*"app_bin":[[:space:]]*"([^"]*)".*/\1/p' "$($(1)_BUILD)/project_description.json" 2>/dev/null || true);
espidf_image_list = $${app:+"$$app"} bootloader/bootloader.bin partition_table/partition-table.bin

espidf_build = $(STD_FW_SH) $(call espidf_env,$(1)) $(call std_fw_env_sh,$(1)) $(call espidf_env_cmake,$(1),$(2)) \
  $(call std_fw_lock,$($(1)_BUILD),make $(1)-$(if $(3),build,check)) \
  $(call std_fw_env_fresh,$(1),$($(1)_BUILD),rm -rf "$($(1)_BUILD)") \
  say "idf.py build $(1) for $($(1)_T) into $($(1)_BUILD)"; $(std_fw_env_say) \
  sd="$(CURDIR)/$(2)/sdkconfig.$($(1)_T)"; dflt="$(CURDIR)/$(2)/sdkconfig.defaults"; \
  if [ -f "$$sd" ] && [ -f "$$dflt" ] && [ "$$dflt" -nt "$$sd" ]; then warn "sdkconfig.defaults is newer than sdkconfig.$($(1)_T): run make $(1)-config or delete sdkconfig.$($(1)_T) to take the new defaults"; fi; \
  $(call espidf_idf,$(1),$(2)) $${envargs[@]+"$${envargs[@]}"} build; \
  $(if $(and $(3),$(filter 1,$($(1)_SECURE_BOOT))),b="$($(1)_BUILD)"; $(call espidf_sign,$(1))) \
  $(call espidf_images,$(1)) $(call std_fw_env_stamp,$($(1)_BUILD),$(espidf_image_list)) \
  ok "built $($(1)_BUILD)"

espidf_setup = $(STD_FW_SH) idf="$($(1)_IDF_DIR)"; \
  if [ -n "$${CI:-}" ] && [ ! -f "$$idf/export.sh" ] && [ -f "$${IDF_PATH:-/nonexistent}/export.sh" ]; then ok "CI: ESP-IDF from the image ($$IDF_PATH)"; exit 0; fi; \
  have git || die "git not found"; mkdir -p "$(STD_TOOLCHAINS)"; \
  $(STD_TC) sdk-begin "$$idf" "$($(1)_IDF_TOOLS)" || true; \
  if [ ! -f "$$idf/export.sh" ]; then say "cloning ESP-IDF $($(1)_IDF) into $$idf"; rm -rf "$$idf.partial"; \
    git clone -q --depth 1 -b "$($(1)_IDF)" --recursive --shallow-submodules $(espidf_repo) "$$idf.partial"; mv "$$idf.partial" "$$idf"; fi; \
  targets=$$(echo $($(1)_TARGETS) | tr ' ' ','); stamp="$$idf/.std-installed-$$targets"; \
  if [ ! -f "$$stamp" ]; then say "ESP-IDF tools for $$targets into $($(1)_IDF_TOOLS)"; \
    IDF_TOOLS_PATH="$($(1)_IDF_TOOLS)" IDF_GITHUB_ASSETS=dl.espressif.com/github_assets "$$idf/install.sh" "$$targets"; touch "$$stamp"; fi; \
  $(STD_TC) sdk-use "$$idf" "$($(1)_IDF_TOOLS)" || true; \
  ok "$(1): ESP-IDF $($(1)_IDF) in $$idf"

# Ready for std_ready, the same conditions espidf_setup leaves: the pinned ESP-IDF is cloned and its tools are installed
# for TARGETS (the .std-installed-<targets> stamp), or in CI an image brings its own ESP-IDF (IDF_PATH).
espidf_ready = idf="$($(1)_IDF_DIR)"; \
  if [ -n "$${CI:-}" ] && [ ! -f "$$idf/export.sh" ] && [ -f "$${IDF_PATH:-/nonexistent}/export.sh" ]; then exit 0; fi; \
  [ -f "$$idf/export.sh" ] && [ -f "$$idf/.std-installed-$$(echo $($(1)_TARGETS) | tr ' ' ',')" ]

espidf_doctor = $(STD_FW_SH) say "$(1): espidf, ESP-IDF $($(1)_IDF), target $($(1)_T)$(if $(filter 1,$($(1)_FLASH_ENCRYPTION)), flash encryption)$(if $(filter 1,$($(1)_SECURE_BOOT)), secure boot)"; \
  if [ -f "$($(1)_IDF_DIR)/export.sh" ]; then ok "ESP-IDF $($(1)_IDF_DIR)"; else bad "ESP-IDF $($(1)_IDF) missing: make $(1)-setup"; fi; \
  if [ -d "$($(1)_IDF_TOOLS)" ]; then ok "ESP-IDF tools $($(1)_IDF_TOOLS)"; else bad "ESP-IDF tools missing: make $(1)-setup"; fi; \
  $(call std_doctor_started,$(1),$(2)) \
  sd="$(CURDIR)/$(2)/sdkconfig.$($(1)_T)"; \
  if [ -f "$$sd" ]; then ok "sdkconfig.$($(1)_T)"; else warn "no sdkconfig.$($(1)_T) yet: the first build makes it from sdkconfig.defaults"; fi; \
  if [ "$($(1)_SECURE_BOOT)" = 1 ]; then $(call std_fw_key_check,$(1),$($(1)_KEY)) \
    if [ -f "$$sd" ] && grep -q '^CONFIG_SECURE_BOOT_BUILD_SIGNED_BINARIES=y' "$$sd"; then bad "sdkconfig.$($(1)_T) signs at build time with a key file in the project: set CONFIG_SECURE_BOOT_BUILD_SIGNED_BINARIES=n, the build signs with the key from the secrets repo"; fi; fi; \
  if [ "$($(1)_FLASH_ENCRYPTION)" = 1 ] && [ -f "$$sd" ] && ! grep -q '^CONFIG_SECURE_FLASH_ENC_ENABLED=y' "$$sd"; then warn "$(1)_FLASH_ENCRYPTION=1 but sdkconfig.$($(1)_T) does not enable flash encryption"; fi; \
  $(std_fw_ports_check) \
  $(call std_fw_doctor_end,$(1))

espidf_update = $(STD_FW_SH) \
  if [ -n "$(TO)" ]; then $(call std_fw_pin,$(1)_IDF,$(TO)) $(MAKE) --no-print-directory $(1)-setup; \
  else say "$(1): ESP-IDF $($(1)_IDF). Latest releases:"; \
    git ls-remote --tags --refs $(espidf_repo) 'v*' | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$$' | sort -V | tail -n 5; \
    say "pin one with make $(1)-update TO=vX.Y[.Z], then commit make/project.mk"; fi

# Reads the eFuse summary of the chip on $$port into $$sum and SPI_BOOT_CRYPT_CNT into $$cnt/$$bits.
espidf_efuse_state = sum=$$(python -m espefuse --chip $($(1)_T) -p "$$port" summary 2>/dev/null || true); \
  cnt=$$(printf '%s\n' "$$sum" | grep 'SPI_BOOT_CRYPT_CNT' | grep -oE '0b[01]+' | sed -n 1p || true); \
  [ -n "$$cnt" ] || die "could not read SPI_BOOT_CRYPT_CNT on $$port (wrong chip, not $($(1)_T)? port busy?): refusing to guess"; \
  bits=$$(printf '%s' "$$cnt" | sed 's/^0b//' | tr -cd 1 | wc -c | tr -d ' '); \
  xts=$$(printf '%s\n' "$$sum" | grep -E '^KEY_PURPOSE_[0-9]' | grep -c 'XTS_AES' || true); \
  say "eFuses: SPI_BOOT_CRYPT_CNT=$$cnt, XTS-AES key blocks $$xts";

espidf_flash = $(STD_FW_SH) $(call espidf_env,$(1)) $(call espidf_need_build,$(1)) $(call std_fw_lock,$$b,make $(1)-flash) $(call std_fw_env_check,$(1),$$b) $(STD_FW_PORT) \
  case "$($(1)_P)" in esptool) ;; *) die "PROBE=$($(1)_P): espidf flashes with esptool (idf.py)";; esac; \
  $(call $(if $(filter 1,$($(1)_FLASH_ENCRYPTION)),espidf_flash_encrypted,espidf_flash_plain),$(1),$(2)) \
  ok "flashed $(1) on $$port"
espidf_flash_plain = $(call espidf_idf,$(1),$(2)) -p "$$port" flash;
espidf_flash_encrypted = $(call espidf_efuse_state,$(1)) \
  case "$$bits" in \
    1|3) say "flash encryption is on: encrypted-flash"; $(call espidf_idf,$(1),$(2)) -p "$$port" encrypted-flash;; \
    0) [ "$(FIRST)" = 1 ] || die "flash encryption is not on yet ($$cnt): a fresh chip takes its first, plaintext flash with FIRST=1 and encrypts itself on first boot"; \
       [ "$$xts" = 0 ] || die "keys are burned but encryption is off ($$cnt): an interrupted first boot. A plaintext flash would brick it; recover by hand (make $(1)-recover runs $(1)_RECOVER)"; \
       say "fresh chip, FIRST=1: plaintext bootloader and app; the first boot burns the keys and encrypts in place, do not unplug it"; \
       $(call espidf_idf,$(1),$(2)) -p "$$port" bootloader-flash flash;; \
    *) die "flash encryption was turned off for good on this chip ($$cnt): refusing";; \
  esac;

espidf_erase = $(STD_FW_SH) $(call espidf_env,$(1)) $(STD_FW_PORT) \
  $(if $(filter 1,$($(1)_FLASH_ENCRYPTION)),warn "flash encryption: after the erase only an encrypted reflash boots (make $(1)-flash)";) \
  python -m esptool --chip $($(1)_T) -p "$$port" erase_flash $(if $(filter 1,$($(1)_FLASH_ENCRYPTION) $($(1)_SECURE_BOOT)),--force); \
  ok "$(1): flash erased"

espidf_fuse = $(STD_FW_SH) $(call espidf_env,$(1)) $(STD_FW_PORT)
espidf_fuse_summary = $(call espidf_fuse,$(1)) python -m espefuse --chip $($(1)_T) -p "$$port" summary
espidf_fuse_burn = $(call espidf_fuse,$(1)) [ -n "$(EFUSE)" ] || die "EFUSE= is required, for example EFUSE='DIS_USB_JTAG 1'"; \
  warn "burning eFuses $(EFUSE) on $$port: irreversible"; \
  python -m espefuse --chip $($(1)_T) -p "$$port" --do-not-confirm burn_efuse $(EFUSE)
espidf_fuse_lockdown = $(call espidf_fuse,$(1)) [ -n "$($(1)_LOCKDOWN_EFUSES)" ] || die "set $(1)_LOCKDOWN_EFUSES in make/project.mk to the eFuses that lock this chip down (names differ per chip)"; \
  warn "lockdown on $$port, irreversible: $($(1)_LOCKDOWN_EFUSES). Afterwards the device updates over OTA only."; \
  python -m espefuse --chip $($(1)_T) -p "$$port" --do-not-confirm burn_efuse $($(1)_LOCKDOWN_EFUSES)

espidf_monitor = $(STD_FW_SH) $(call espidf_env,$(1)) $(STD_FW_PORT) $(STD_FW_LOGGED) \
  logged "$(CURDIR)/$(2)/build/monitor.log" $(call espidf_idf,$(1),$(2)) -p "$$port" monitor

espidf_debug = $(STD_FW_SH) $(call espidf_env,$(1)) $(call espidf_need_build,$(1)) $(call espidf_idf,$(1),$(2)) openocd gdb
espidf_action = $(STD_FW_SH) $(call espidf_env,$(1)) $(call espidf_idf,$(1),$(2)) $(3)

espidf_release = $(STD_FW_SH) $(call espidf_need_build,$(1)) $(call std_fw_lock,$$b,make $(1)-release) $(call espidf_app_bin,$(1)) $(call std_fw_env_check,$(1),$$b,$$b/$$app) f="$$b/$$app"; $(call std_fw_release,$(1),$(2),$($(1)_T).bin)

# GitHub Release assets of the build: the (signed) app image, bootloader.bin, partition-table.bin, flash_args with
# its paths made flat (so it works in the release folder), the elf and map, and factory-<target>.bin: one image
# merged from flash_args with esptool merge_bin, where esptool is on PATH (the ESP-IDF image in CI).
espidf_release_assets = $(STD_FW_SH) $(call espidf_need_build,$(1)) $(call espidf_app_bin,$(1)) $(call std_rel_begin,$(1),espidf,$(2)) \
  need "$$b/$$app"; need "$$b/bootloader/bootloader.bin"; need "$$b/partition_table/partition-table.bin"; \
  [ -f "$$b/flash_args" ] || die "no $$b/flash_args: run make $(1)-build"; \
  sed -E 's|[^ ]*/([^/ ]+)|\1|g' "$$b/flash_args" > "$$out/flash_args"; printf '  asset flash_args\n'; \
  opt "$$b/$${app%.bin}.elf"; opt "$$b/$${app%.bin}.map"; \
  et=; if have esptool.py; then et=esptool.py; elif have esptool; then et=esptool; fi; \
  if [ -n "$$et" ]; then (cd "$$b" && "$$et" --chip $($(1)_T) merge_bin -o "$$out/factory-$($(1)_T).bin" @flash_args) || die "esptool merge_bin failed"; \
    printf '  asset %s\n' "factory-$($(1)_T).bin"; \
  else warn "esptool not found: no merged factory image"; fi; \
  $(std_rel_end)

# --- the kind -----------------------------------------------------------------------------------
#
# Per-part settings (make/project.mk, <part>_<VAR>), with their defaults:
#   IDF              v5.5      ESP-IDF tag, cloned into $(STD_TOOLCHAINS)/esp-idf-<ver>, shared
#   IDF_TOOLS        $(STD_TOOLCHAINS)/esp-idf-tools   IDF_TOOLS_PATH (versioned inside, shared)
#   TARGET           esp32c6   chip; TARGET= on the command line wins. Each target builds in
#                              <dir>/build/<target> with <dir>/sdkconfig.<target>
#   TARGETS          $(TARGET) the targets setup installs tools for (space separated)
#   FLASH_ENCRYPTION 0         1: flash checks the eFuses first, then encrypted-flash (FIRST=1 for
#                              the first, plaintext flash of a fresh chip)
#   SECURE_BOOT      0         1: the bootloader and app are signed after the build with KEY
#                              (secure-boot, type espsecure-v2) from the secrets repo
#   LOCKDOWN_EFUSES            eFuses make <part>-fuse-lockdown burns (chip specific)
#   RECOVER, PROVISION, OTA_BUCKET, OTA_PREFIX, WRANGLER, RELEASE_HOOK   as in the zephyr kind
#   IDF_ARGS                   extra idf.py arguments
#   ENV_DEFINES_<env>          C defines for ENV=<env> (local, staging, production), NAME=value words: idf.py gets
#                              them as -D STD_ENV_DEFINES=<list>, which the top CMakeLists.txt applies before
#                              project() (the block in reference/standard.md 4.9); without the block the build stops
# eFuse burns need CONFIRM=fuse; erase and recover need CONFIRM=erase.

define kind_espidf
# the part is started once its folder has its CMakeLists.txt (std_started in common.mk): until then setup, check and build
# skip it and flash and release refuse
$(1)_START ?= CMakeLists.txt
$(1)_IDF ?= v5.5
$(1)_TARGET ?= esp32c6
$(1)_TARGETS ?= $$($(1)_T)
$(1)_FLASH_ENCRYPTION ?= 0
$(1)_SECURE_BOOT ?= 0
$(1)_KEY ?= secure-boot
$(1)_PROBE ?= esptool
$(1)_IDF_ARGS ?=
$(1)_LOCKDOWN_EFUSES ?=
$(1)_RECOVER ?=
$(1)_PROVISION ?=
$(1)_OTA_BUCKET ?= $$(OTA_BUCKET)
# no OTA bucket (no Cloudflare in the project): <part>-release publishes nothing, and help leaves it out
STD_HELP_HIDE += $$(if $$(strip $$($(1)_OTA_BUCKET)),,$(1)-release)
$(1)_OTA_PREFIX ?= $$(PROJECT)/$(1)/$$(ENV)
$(1)_WRANGLER ?= npx --yes wrangler@4
$(1)_RELEASE_HOOK ?=
$(1)_IDF_DIR ?= $$(STD_TOOLCHAINS)/esp-idf-$$($(1)_IDF)
$(1)_IDF_TOOLS ?= $$(STD_TOOLCHAINS)/esp-idf-tools
$(1)_T = $$(or $$(TARGET),$$($(1)_TARGET))
$(1)_P = $$(or $$(PROBE),$$($(1)_PROBE))
$(1)_BUILD = $$(CURDIR)/$(2)/build/$$($(1)_T)

.PHONY: $(1)-release-run $(1)-doctor $(1)-setup $(1)-update $(1)-check $(1)-build $(1)-clean $(1)-distclean $(1)-flash $(1)-erase $(1)-monitor $(1)-debug $(1)-release $(1)-version $(1)-size $(1)-config $(1)-keygen $(1)-provision $(1)-recover $(1)-fuse-summary $(1)-fuse-burn $(1)-fuse-lockdown

$(call std_verb,$(1),doctor,firmware,Check ESP-IDF and its tools and sdkconfig and keys and ports read only)
$(1)-doctor:
	@$$(call espidf_doctor,$(1),$(2))

$(call std_verb,$(1),setup,firmware,Install ESP-IDF $$($(1)_IDF) and its tools into $$(STD_TOOLCHAINS) shared)
$(1)-setup:
	@$$(call std_skip_unstarted,$(1),$(2),setup) $$(call espidf_setup,$(1),$(2))

# The commands that source the ESP-IDF environment install the pinned ESP-IDF and its tools first when they are not
# there (std_ready in common.mk). release, release-assets and provision build or flash through these targets.
$(call std_ready,$(1),$(2),espidf_ready,check build flash erase monitor debug size config fuse-summary fuse-burn fuse-lockdown)

$(call std_verb,$(1),update,firmware,List ESP-IDF releases or pin TO=vX.Y in make/project.mk and set up)
$(1)-update:
	@$$(call espidf_update,$(1),$(2))

$(call std_verb,$(1),check,firmware,Build for $$($(1)_T) unsigned as the gate)
$(1)-check:
	@$$(call std_skip_unstarted,$(1),$(2),check) $$(call espidf_build,$(1),$(2),)

$(call std_verb,$(1),build,firmware,Build for TARGET=$$($(1)_T) into $(2)/build/$$($(1)_T) and sign when secure boot is on)
$(1)-build:
	@$$(call std_skip_unstarted,$(1),$(2),build) $$(call espidf_build,$(1),$(2),1)

$(call std_verb,$(1),flash,firmware,Build then flash with esptool and checks the eFuses first when flash encryption is on)
$(1)-flash: $$(if $$(NOBUILD),,$(1)-build)
	@$$(call std_refuse_unstarted,$(1),$(2),flash) $$(call espidf_flash,$(1),$(2))

$(call std_verb,$(1),erase,firmware,Erase the whole flash and needs CONFIRM=erase)
$(1)-erase:
	@$$(call std_confirm,erase) && { $$(call espidf_erase,$(1),$(2)); }

$(call std_extra,$(1),recover,firmware,Run $(1)_RECOVER for a chip stuck half way and needs CONFIRM=erase)
$(1)-recover:
	@$$(call std_confirm,erase) && { $$(call std_fw_hook,$(1),$(1)_RECOVER,recover); }

$(call std_extra,$(1),fuse-summary,firmware,Print the eFuse summary of the chip read only)
$(1)-fuse-summary:
	@$$(call espidf_fuse_summary,$(1))

$(call std_extra,$(1),fuse-burn,firmware,Burn EFUSE='NAME VALUE' irreversibly and needs CONFIRM=fuse)
$(1)-fuse-burn:
	@$$(call std_confirm,fuse) && { $$(call espidf_fuse_burn,$(1)); }

$(call std_extra,$(1),fuse-lockdown,firmware,Burn $(1)_LOCKDOWN_EFUSES so the device updates over OTA only and needs CONFIRM=fuse)
$(1)-fuse-lockdown:
	@$$(call std_confirm,fuse) && { $$(call espidf_fuse_lockdown,$(1)); }

$(call std_verb,$(1),monitor,firmware,idf.py monitor on PORT or the only port and logged to $(2)/build/monitor.log)
$(1)-monitor:
	@$$(call espidf_monitor,$(1),$(2))

$(call std_verb,$(1),debug,firmware,OpenOCD and GDB on the build through idf.py)
$(1)-debug:
	@$$(call espidf_debug,$(1),$(2))

$(call std_extra,$(1),size,firmware,Size report of the build per component)
$(1)-size:
	@$$(call espidf_action,$(1),$(2),size size-components)

$(call std_extra,$(1),config,firmware,menuconfig for sdkconfig.$$($(1)_T))
$(1)-config:
	@$$(call espidf_action,$(1),$(2),menuconfig)

$(call std_extra,$(1),keygen,firmware,Create the secure boot v2 key $$($(1)_KEY) in the secrets repo and never overwrite)
$(1)-keygen:
	@$$(call std_fw_keygen,$(1),$$($(1)_KEY),espsecure-v2)

$(call std_extra,$(1),provision,firmware,Per device setup SERIAL= through $(1)_PROVISION else flash only)
$(1)-provision:
	@$$(call std_fw_provision,$(1))

$(call std_verb,$(1),release,release,App image to the OTA store as ver and latest with ENV= and PROMOTE=1 for stable)
$(1)-release:
	@if [ -z "$$(strip $$($(1)_OTA_BUCKET))" ]; then echo "> $(1): no OTA bucket (no Cloudflare in this project): firmware publish skipped"; exit 0; fi; if $$(call std_fw_tag_ok,$(1)); then $$(MAKE) --no-print-directory $(1)-release-run; else echo "$(1): tag $$$$CI_COMMIT_TAG is not a $(1) release, nothing to do"; fi

$(1)-release-run:
	@$$(call std_refuse_unstarted,$(1),$(2),release) $$(std_production_guard) && { $$(std_fw_remote_env); } && $$(if $$(NOBUILD),true,$$(MAKE) --no-print-directory $(1)-build) && { $$(call espidf_release,$(1),$(2)); }

$(call std_verb,$(1),version,release,Firmware version from $(2)/VERSION or version.txt)

$(call std_release,$(1),espidf,$(2),espidf_release_assets,build)
$(1)-version:
	@$$(call std_fw_print_version,$(1),$(2))

$(call std_verb,$(1),clean,firmware,Remove $(2)/build)
$(1)-clean:
	@rm -rf "$$(CURDIR)/$(2)/build"

$(call std_verb,$(1),distclean,firmware,Remove $(2)/build and managed_components and keep the shared toolchains)
$(1)-distclean: $(1)-clean
	@rm -rf "$$(CURDIR)/$(2)/managed_components"
endef
