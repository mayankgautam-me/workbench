# project-standard v1.13 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
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

# --- pio helpers --------------------------------------------------------------------------------

# Every pio command runs with the defines of ENV (std_fw_env_sh) added to PLATFORMIO_BUILD_FLAGS, which PlatformIO
# splits like a shell (shlex), so the single-quoted words of $$envflags reach the compiler as they are. All of them, so
# an upload, which builds too, builds what build built; PlatformIO rebuilds what changed flags touch.
pio_need = have pio || die "pio not found: PlatformIO comes from mise (mise.toml pins platformio; run make setup)"; \
  $(call std_fw_env_sh,$(1)) [ -z "$$envflags" ] || export PLATFORMIO_BUILD_FLAGS="$${PLATFORMIO_BUILD_FLAGS:+$$PLATFORMIO_BUILD_FLAGS }$$envflags";
pio_e = $(if $($(1)_E),-e $($(1)_E))
# $(call pio_stamp,part,dir,env...): after a build, the ENV stamp (std-env, std-env.sha256 of its images) in
# .pio/build/<env> of each env built.
pio_stamp = for e in $(3); do bd="$(CURDIR)/$(2)/.pio/build/$$e"; if [ -d "$$bd" ]; then $(call std_fw_env_stamp,$$bd,firmware.bin firmware.hex firmware.uf2 firmware.elf $($(1)_IMAGE)) fi; done;
# $(call pio_lock,part,dir,env...,target): before a build or upload, the lock (std_fw_lock) of .pio/build/<env> of each
# env it builds, then forgets the images recorded there until the new build stamps them.
pio_lock = for e in $(3); do bd="$(CURDIR)/$(2)/.pio/build/$$e"; $(call std_fw_lock,$$bd,make $(1)-$(4)) rm -f "$$bd/std-env.sha256"; done;

# $(call pio_build_envs,part,dir): sets $$envs to the envs a build makes, one per line: PIO_ENV (or <part>_PIO_ENV),
# else PLATFORMIO_DEFAULT_ENVS, else the default_envs of platformio.ini, else its [env:*] sections.
pio_build_envs = ini="$(CURDIR)/$(2)/platformio.ini"; \
  if [ -n "$($(1)_E)" ]; then envs=$$(printf '%s\n' "$($(1)_E)" | tr ', ' '\n\n' | grep . || true); \
  elif [ -n "$${PLATFORMIO_DEFAULT_ENVS:-}" ]; then envs=$$(printf '%s\n' "$$PLATFORMIO_DEFAULT_ENVS" | tr ', ' '\n\n' | grep . || true); \
  else [ -f "$$ini" ] || die "no $(2)/platformio.ini"; envs=$$($(pio_envs_awk) "$$ini"); fi;

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

pio_build = $(STD_FW_SH) $(pio_need) $(call pio_sdkconfig,$(1),$(2)) $(call pio_build_envs,$(1),$(2)) $(call pio_lock,$(1),$(2),$$envs,build) \
  say "pio run $(1)$(if $($(1)_E), -e $($(1)_E))"; $(std_fw_env_say) \
  pio run -d "$(CURDIR)/$(2)" $(call pio_e,$(1)); \
  $(call pio_stamp,$(1),$(2),$$envs) ok "built $(1)"

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
  if have pio; then ok "$$(pio --version 2>/dev/null | sed -n 1p)"; else bad "pio missing: mise install (mise.toml pins platformio)"; fi; \
  $(call std_doctor_started,$(1),$(2)) \
  $(if $($(1)_E),if [ -f "$(CURDIR)/$(2)/platformio.ini" ] && ! grep -q '^\[env:$($(1)_E)\]' "$(CURDIR)/$(2)/platformio.ini"; then bad "no [env:$($(1)_E)] in platformio.ini"; fi;) \
  if [ -d "$(CURDIR)/$(2)/.pio" ]; then ok "packages and build in $(2)/.pio"; else warn "nothing built yet: make $(1)-setup then make $(1)-build"; fi; \
  $(std_fw_ports_check) \
  $(call std_fw_doctor_end,$(1))

pio_flash = $(STD_FW_SH) $(pio_need) $(call pio_one_env,$(1),$(2),$(1)-flash) $(pio_port) $(call pio_lock,$(1),$(2),"$$pio_env",flash) \
  case "$($(1)_P)" in pio|esptool) ;; *) die "PROBE=$($(1)_P): pio uploads with the upload_protocol of platformio.ini (PROBE=pio)";; esac; \
  $(std_fw_env_say) pio run -d "$(CURDIR)/$(2)" -e "$$pio_env" -t upload $$( [ -z "$$up" ] || printf -- '--upload-port %s' "$$up" ); \
  $(call pio_stamp,$(1),$(2),"$$pio_env") ok "uploaded $(1)"

pio_monitor = $(STD_FW_SH) $(pio_need) $(call pio_one_env,$(1),$(2),$(1)-monitor) $(STD_FW_PORT) $(STD_FW_LOGGED) \
  logged "$(CURDIR)/$(2)/build/monitor.log" pio device monitor -d "$(CURDIR)/$(2)" -e "$$pio_env" -p "$$port"

# Provision runs for one env too: it is exported as PIO_ENV to <part>_PROVISION and to the flash it falls back to.
pio_provision = $(STD_FW_SH) $(call pio_one_env,$(1),$(2),$(1)-provision) export PIO_ENV="$$pio_env"; $(call std_fw_provision,$(1))

pio_release = $(STD_FW_SH) $(call std_fw_lock,$(CURDIR)/$(2)/.pio/build/$($(1)_E),make $(1)-release) $(call std_fw_env_check,$(1),$(CURDIR)/$(2)/.pio/build/$($(1)_E),$(CURDIR)/$(2)/.pio/build/$($(1)_E)/$($(1)_IMAGE)) f="$(CURDIR)/$(2)/.pio/build/$($(1)_E)/$($(1)_IMAGE)"; $(call std_fw_release,$(1),$(2),$(or $($(1)_E),firmware)-$($(1)_IMAGE))

# GitHub Release assets: one set per env the build makes (PIO_ENV, else default_envs, else every [env:*]), each
# file prefixed with its env: <env>-firmware.bin / .hex / .uf2 (at least one) and <env>-firmware.elf.
pio_release_assets = $(STD_FW_SH) $(call pio_build_envs,$(1),$(2)) \
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
#   ENV_DEFINES_<env>             C defines for ENV=<env> (local, staging, production), NAME=value words: every pio
#                                 command gets them in PLATFORMIO_BUILD_FLAGS (-D...), on top of build_flags
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
