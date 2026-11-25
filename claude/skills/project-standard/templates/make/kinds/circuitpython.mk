# project-standard v1.12 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
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
# No ENV_DEFINES_<env> (1.8): the part's code is Python, copied as it is, with no compile step to take C defines;
# per-environment settings belong in the code's own files (settings.toml).

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
