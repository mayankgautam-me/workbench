# project-standard v1.14 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind silabs: a Silicon Labs firmware part built from an slc project (*.slcp) on the Simplicity SDK and
# WiseConnect 3, for SiWx917 / SiWG917 (Cortex-M4 SoC mode).
#
# make/project.mk declares it as   <name>:silabs[:<dir>]   (dir usually firmware). slt, Silicon Labs' Simplicity
# Tools CLI, is pinned per part and installed once into $(STD_TOOLCHAINS)/slt-<ver>; it installs slc-cli, a Java
# runtime, the GNU Arm toolchain, the Simplicity SDK, WiseConnect and Simplicity Commander into its own folder
# (~/.silabs/slt; none of it is in the toolchain ledger, so make teardown and prune leave it, as they leave the SDK). A build is
# slc generate (a makefile project) into <dir>/build/<board>, then the generated makefile. Flash, erase and the
# energy monitor go through Simplicity Commander (commander), the console through the kit's J-Link VCOM port, debug
# through the J-Link GDB server. The image signing key never touches the project: it is decrypted from the secrets
# repo into a temporary file for the one commander call that signs (secrets.sh with-file), then removed.
#
# The .rps image (what the SiWx917 boots from its bootloader and what OTA delivers) comes from the slcp's post-build
# profile, not from slc or the compiler: the .slcp needs the top-level lines
#     post_build:
#       profile: wiseconnect_soc
# (WiseConnect's utilities/postbuild_profile/wiseconnect_soc.slpb: create_rps from <name>.out and <name>.map, then
# convert the .rps to <name>.hex, .s37 and _isp.bin). It is a key of the .slcp, not a component. With it, slc writes
# <name>.slpb into the build folder and a post-build rule `"$(POST_BUILD_EXE)" postbuild "./<name>.slpb" --parameter
# build_dir:"$(OUTPUT_DIR)"` (slc-cli's arm_gcc exporter template), and leaves POST_BUILD_EXE empty unless told where
# Simplicity Commander is; the kind passes POST_BUILD_EXE=<commander> to the generated makefile. So a part whose .slcp
# has a post_build needs Commander to build: make <part>-build refuses without it (make <part>-check, a compile check,
# skips the post-build then, with a warning). Without a post_build the build makes no .rps (the .hex is the linker's),
# and make <part>-release refuses, saying the .slcp lines it needs.
#
# No --toolchain on slc generate: on a SiWx917 the device brings WiseConnect's wiseconnect_toolchain_gcc_standard, which
# provides toolchain_gcc, and `--toolchain gcc` adds the Simplicity SDK's toolchain_gcc too ("Project is invalid even
# after autoselecting dependencies": the two are exclusive). The makefile exporter is GCC either way; the .slcp needs no
# toolchain line. <part>_SLC_ARGS can still pass one.
#
# Host unit tests (make <part>-test): the Makefile in <dir>/test/, else in <dir>/tests/, run with the Mac's cc
# (CC=<part>_TEST_CC, default cc) and BUILD_DIR=<dir>/build/test passed to it. No such Makefile: "no host tests", exit 0.
# make <part>-clean removes <dir>/build only, so a test build is cleaned only when it is under <dir>/build/ (put it in
# BUILD_DIR); a test Makefile that builds elsewhere keeps its output.

# --- shared firmware helpers --------------------------------------------------------------------
# The same block is in every firmware kind (zephyr, espidf, pio, arm-gcc, circuitpython, silabs); the first
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

# --- energy profiling ----------------------------------------------------------------------------
# The same block is in zephyr and silabs; the first kind included defines it.
ifndef STD_FW_POWER
STD_FW_POWER := 1
# $(call std_fw_power_summary,part,dir), after $$csv (time_s,current_mA,voltage_V) is written: the sample count, the
# duration, the average, minimum and maximum current (and the average power when the voltage is known), printed and
# kept in <dir>/build/power.txt.
std_fw_power_summary = [ -s "$$csv" ] || die "no samples in $$csv"; \
  awk -F, 'NR > 1 && $$2 != "" { n++; c = $$2 + 0; s += c; if (n == 1 || c < mn) mn = c; if (n == 1 || c > mx) mx = c; \
      if ($$3 != "") { v += $$3; nv++ }; t = $$1 } \
    END { if (!n) { print "no samples"; exit 1 }; printf "samples   %d over %.1f s\navg       %.4f mA\nmin       %.4f mA\nmax       %.4f mA\n", n, t, s / n, mn, mx; \
      if (nv) printf "voltage   %.3f V (avg)\npower     %.3f mW (avg)\n", v / nv, (s / n) * (v / nv) }' "$$csv" | tee "$${csv%.csv}.txt"; \
  ok "$(1): samples in $(2)/build/power.csv, summary in $(2)/build/power.txt"
endif

# --- silabs helpers -----------------------------------------------------------------------------

# Where Silicon Labs publishes the slt (Simplicity Tools) CLI zips: <url>/slt-cli-<ver>-<mac-arm64|mac-x64|linux-x64>.zip
SILABS_SLT_URL ?= https://www.silabs.com/documents/public/software
# Simplicity Commander: on PATH, else these (the first that exists), else the one slt installed (slt where
# commander/<part>_COMMANDER; on macOS the package is Commander.app and the CLI its Contents/MacOS/commander).
# SILABS_COMMANDER= wins.
SILABS_COMMANDER ?=
SILABS_COMMANDER_PATHS ?= $(HOME)/.silabs/commander/Commander.app/Contents/MacOS/commander /Applications/Commander.app/Contents/MacOS/commander /opt/commander/commander

# $(call silabs_find,part,dir): sets d, slcp (the part's one *.slcp, or <part>_SLCP) and name (its project_name).
silabs_find = d="$(CURDIR)/$(2)"; slcp="$($(1)_SLCP)"; \
  if [ -z "$$slcp" ]; then set -- "$$d"/*.slcp; [ -f "$$1" ] || die "no .slcp in $(2): the part is a Simplicity Studio / slc project"; \
    [ -z "$${2:-}" ] || die "several .slcp in $(2): pick one with $(1)_SLCP in make/project.mk"; slcp="$$1"; \
  else case "$$slcp" in /*) ;; *) slcp="$$d/$$slcp";; esac; [ -f "$$slcp" ] || die "$(1)_SLCP=$($(1)_SLCP) not found in $(2)"; fi; \
  name=$$(sed -nE 's/^project_name:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$$slcp" | sed -n 1p); [ -n "$$name" ] || name=$$(basename "$$slcp" .slcp);

# $(call silabs_postbuild): after silabs_find, sets pb to the .slcp's post_build profile (the line under post_build:,
# `profile: <name>`, else `yes` for a post_build without one), empty when the .slcp has no post_build.
silabs_postbuild = pb=$$(awk '/^post_build:/ { f = 1; p = "yes"; next } /^[^[:space:]]/ { f = 0 } f && /profile:/ { sub(/.*profile:[[:space:]]*"?/, ""); sub(/"?[[:space:]]*$$/, ""); p = $$0 } END { print p }' "$$slcp");
silabs_pb_lines = add post_build: with profile: wiseconnect_soc under it (two lines at the top level) to $$(basename "$$slcp")

# $(call silabs_cmdr,part): sets cmdr to Simplicity Commander (empty when not found).
silabs_cmdr = cmdr="$(SILABS_COMMANDER)"; \
  if [ -z "$$cmdr" ]; then cmdr=$$(command -v commander 2>/dev/null || true); fi; \
  if [ -z "$$cmdr" ]; then for c in $(SILABS_COMMANDER_PATHS); do if [ -x "$$c" ]; then cmdr="$$c"; break; fi; done; fi; \
  if [ -z "$$cmdr" ] && [ -x "$($(1)_SLT_DIR)/slt" ]; then \
    cpath=$$("$($(1)_SLT_DIR)/slt" where commander$(if $(strip $($(1)_COMMANDER)),/$(strip $($(1)_COMMANDER))) --non-interactive --ignore-slconf 2>/dev/null | sed -n 1p || true); \
    if [ -n "$$cpath" ]; then for c in "$$cpath/Contents/MacOS/commander" "$$cpath/commander" "$$cpath"; do if [ -f "$$c" ] && [ -x "$$c" ]; then cmdr="$$c"; break; fi; done; fi; \
  fi; \
  if [ -z "$$cmdr" ]; then cmdr=$$(find "$($(1)_SLT_HOME)/installs/archive" -maxdepth 4 -name commander -type f -perm -u+x 2>/dev/null | sed -n 1p || true); fi;
# The fix a missing Commander message gives.
silabs_cmdr_fix = make $(1)-setup (it installs Simplicity Commander$(if $(strip $($(1)_COMMANDER)), $(strip $($(1)_COMMANDER))) through slt), or set SILABS_COMMANDER
silabs_need_cmdr = $(call silabs_cmdr,$(1)) [ -n "$$cmdr" ] || die "Simplicity Commander not found: $(call silabs_cmdr_fix,$(1))";

# $(call silabs_tools,part): what slt installed into <part>_SLT_HOME/installs. Sets slt, slc, java (a bin folder),
# gccdir (the bin folder of the pinned GNU Arm toolchain, <part>_GCC: the package whose <ver>-*manifest.txt names it,
# never just the first arm-none-eabi-gcc found; with <part>_GCC empty, the first found, else the one on PATH), sdk (the
# folder of the *.slcs of version <part>_SDK) and wc (the folder of the *.slce of version <part>_WISECONNECT); each
# empty when missing. pkg EXT VER prints the folder of the first *.EXT whose version line is VER (sdk_version: in a
# .slcs, version: in a .slce).
silabs_tools = slt="$($(1)_SLT_DIR)/slt"; inst="$($(1)_SLT_HOME)/installs"; \
  pkg() { find "$$inst/conan" -name "*.$$1" -type f 2>/dev/null | while IFS= read -r f; do \
    if grep -qE "^(sdk_)?version:[[:space:]]*\"?$$2\"?[[:space:]]*$$" "$$f"; then dirname "$$f"; break; fi; done; }; \
  slc=$$(ls "$$inst"/archive/slc-cli-*/slc_cli/slc 2>/dev/null | sed -n 1p || true); [ -n "$$slc" ] || slc=$$(command -v slc 2>/dev/null || true); \
  java=$$(find "$$inst/archive" \( -path '*/jre/bin/java' -o -path '*/jre/*/bin/java' \) -type f 2>/dev/null | sed -n 1p || true); [ -z "$$java" ] || java=$$(dirname "$$java"); \
  gccver="$(strip $($(1)_GCC))"; gccdir=; \
  if [ -n "$$gccver" ]; then gccdir=$$(find "$$inst/conan" -name "$$gccver-*manifest.txt" -type f 2>/dev/null | while IFS= read -r m; do \
      if [ -x "$$(dirname "$$m")/bin/arm-none-eabi-gcc" ]; then printf '%s\n' "$$(dirname "$$m")/bin"; break; fi; done || true); \
  else gccdir=$$(find "$$inst/conan" -name arm-none-eabi-gcc -type f 2>/dev/null | sed -n 1p || true); \
    if [ -n "$$gccdir" ]; then gccdir=$$(dirname "$$gccdir"); elif command -v arm-none-eabi-gcc >/dev/null 2>&1; then gccdir=$$(dirname "$$(command -v arm-none-eabi-gcc)"); fi; fi; \
  sdk=$$(pkg slcs "$($(1)_SDK)" || true); wc=$$(pkg slce "$($(1)_WISECONNECT)" || true);

# The versions of what slt installed, for the messages: every *.slcs / *.slce version found, and the GNU Arm toolchains
# (gccfound, from their <ver>-*manifest.txt).
silabs_have_versions = found=$$(find "$$inst/conan" \( -name '*.slcs' -o -name '*.slce' \) -type f 2>/dev/null | while IFS= read -r f; do \
    sed -nE 's/^(sdk_)?version:[[:space:]]*"?([^"[:space:]]+)"?.*/\2/p' "$$f" | sed -n 1p; done | sort -u | paste -sd' ' - || true); \
  gccfound=$$(find "$$inst/conan" -name '*-arm-none-eabi-manifest.txt' -type f 2>/dev/null | sed -E 's,.*/,,; s,-(darwin|linux|mingw|win).*,,' | sort -u | paste -sd' ' - || true);

silabs_need_tools = [ -x "$$slt" ] || die "slt $($(1)_SLT) is not in $($(1)_SLT_DIR): run make $(1)-setup"; \
  [ -n "$$slc" ] || die "slc not found among the packages slt installed in $$inst: run make $(1)-setup"; \
  [ -n "$$java" ] || command -v java >/dev/null 2>&1 || die "no Java runtime for slc (slt installs one with slc-cli): run make $(1)-setup"; \
  $(silabs_have_versions) \
  [ -n "$$gccdir" ] || die "GNU Arm toolchain $(if $(strip $($(1)_GCC)),$(strip $($(1)_GCC)) )not found (slt installs it with the SDK; installed: $${gccfound:-none}): run make $(1)-setup or pin $(1)_GCC"; \
  [ -n "$$sdk" ] || die "Simplicity SDK $($(1)_SDK) not found in $$inst (installed: $${found:-none}): run make $(1)-setup or pin $(1)_SDK"; \
  [ -n "$$wc" ] || die "WiseConnect $($(1)_WISECONNECT) not found in $$inst (installed: $${found:-none}): run make $(1)-setup or pin $(1)_WISECONNECT";

# The slcp's own SDK pins (sdk: version and the wiseconnect3_sdk sdk_extension version), set as slcp_sdk and slcp_wc.
silabs_slcp_versions = slcp_sdk=$$(awk '/^sdk:/ { f = 1; next } /^[^[:space:]-]/ { f = 0 } f && /version:/ { sub(/.*version:[[:space:]]*"?/, ""); sub(/"?[[:space:]]*$$/, ""); print; exit }' "$$slcp"); \
  slcp_wc=$$(awk '/^sdk_extension:/ { f = 1; next } /^[^[:space:]-]/ { f = 0 } f && /id:[[:space:]]*wiseconnect/ { w = 1 } f && w && /version:/ { sub(/.*version:[[:space:]]*"?/, ""); sub(/"?[[:space:]]*$$/, ""); print; exit }' "$$slcp");

# Ready for std_ready: the stamp setup leaves once slt, slc and the pinned SDK and WiseConnect are installed and trusted.
silabs_stamp = $($(1)_SLT_DIR)/.std-setup-$($(1)_SDK)-$($(1)_WISECONNECT)
silabs_ready = [ -f "$(call silabs_stamp,$(1))" ]

# Setup: the slt CLI of the pinned version from Silicon Labs into $(STD_TOOLCHAINS)/slt-<ver> (ledgered, shared), then
# slt install of <part>_SLT_INSTALL (slt keeps its packages in <part>_SLT_HOME, its own folder: not in the ledger, so
# make teardown and prune never remove them; Simplicity Commander, commander/<part>_COMMANDER, is one of them), then slc
# signature trust on the SDK and WiseConnect. A part whose stamp is already there (set up before Commander was in
# SLT_INSTALL) skips those installs; setup still installs commander/<part>_COMMANDER through slt when none is found.
silabs_setup = $(STD_FW_SH) dir="$($(1)_SLT_DIR)"; mkdir -p "$(STD_TOOLCHAINS)"; \
  if [ -x "$$dir/slt" ]; then ok "slt $($(1)_SLT) in $$dir"; \
  else \
    $(STD_TC) sdk-begin "$$dir" || true; \
    case "$$(uname -s)-$$(uname -m)" in Darwin-arm64) arch=mac-arm64;; Darwin-*) arch=mac-x64;; Linux-x86_64) arch=linux-x64;; *) die "slt has no build for $$(uname -s)-$$(uname -m)";; esac; \
    for t in curl unzip; do have $$t || die "$$t not found: brew install $$t"; done; \
    url="$(SILABS_SLT_URL)/slt-cli-$($(1)_SLT)-$$arch.zip"; say "slt $($(1)_SLT) from $$url"; \
    tmp="$$dir.partial"; rm -rf "$$tmp"; mkdir -p "$$tmp"; \
    curl -fsSL --retry 3 -o "$$tmp/slt.zip" "$$url"; unzip -q -o "$$tmp/slt.zip" -d "$$tmp"; rm -f "$$tmp/slt.zip"; \
    [ -f "$$tmp/slt" ] || die "the slt zip has no slt at its top"; chmod +x "$$tmp/slt"; mv "$$tmp" "$$dir"; \
  fi; \
  $(STD_TC) sdk-use "$$dir" || true; \
  if [ ! -f "$(call silabs_stamp,$(1))" ]; then \
    for p in $($(1)_SLT_INSTALL); do say "slt install $$p (first run downloads about 2 GB)"; "$$dir/slt" install "$$p" --non-interactive; done; \
  fi; \
  $(call silabs_tools,$(1)) $(call silabs_need_tools,$(1)) \
  if PATH="$$java:$$PATH" "$$slc" signature trust --sdk-package-path "$$sdk,$$wc" >/dev/null 2>&1; then ok "slc trusts the SDK and WiseConnect"; else warn "slc signature trust failed (slc generate asks for it)"; fi; \
  $(call silabs_cmdr,$(1)) \
  if [ -z "$$cmdr" ] && [ -n "$(strip $($(1)_COMMANDER))" ]; then say "slt install commander/$(strip $($(1)_COMMANDER)) (Simplicity Commander)"; "$$dir/slt" install "commander/$(strip $($(1)_COMMANDER))" --non-interactive; $(call silabs_cmdr,$(1)) fi; \
  if [ -n "$$cmdr" ]; then ok "Simplicity Commander $$cmdr"; else warn "Simplicity Commander not found (flash, erase, power and a .slcp post_build need it): $(if $(strip $($(1)_COMMANDER)),slt did not install commander/$(strip $($(1)_COMMANDER)) (slt list commander --versions shows what it has); pin another $(1)_COMMANDER,set $(1)_COMMANDER to have slt install it) or set SILABS_COMMANDER"; fi; \
  touch "$(call silabs_stamp,$(1))"; \
  ok "$(1): slt $($(1)_SLT), Simplicity SDK $($(1)_SDK), WiseConnect $($(1)_WISECONNECT)"

silabs_doctor = $(STD_FW_SH) say "$(1): silabs, slt $($(1)_SLT), Simplicity SDK $($(1)_SDK), WiseConnect $($(1)_WISECONNECT), probe $($(1)_P)"; \
  $(call silabs_tools,$(1)) $(silabs_have_versions) \
  if [ -x "$$slt" ]; then ok "slt $$slt"; else bad "slt $($(1)_SLT) missing: make $(1)-setup"; fi; \
  if [ -n "$$slc" ]; then ok "slc $$slc"; else bad "slc missing: make $(1)-setup"; fi; \
  if [ -n "$$java" ] || have java; then ok "java for slc"; else bad "no Java runtime for slc: make $(1)-setup"; fi; \
  if [ -n "$$gccdir" ]; then ok "arm-none-eabi-gcc in $$gccdir"; else bad "GNU Arm toolchain $(strip $($(1)_GCC)) missing (installed: $${gccfound:-none}): make $(1)-setup or pin $(1)_GCC"; fi; \
  if [ -n "$$sdk" ]; then ok "Simplicity SDK $($(1)_SDK)"; else bad "Simplicity SDK $($(1)_SDK) missing (installed: $${found:-none}): make $(1)-setup"; fi; \
  if [ -n "$$wc" ]; then ok "WiseConnect $($(1)_WISECONNECT)"; else bad "WiseConnect $($(1)_WISECONNECT) missing (installed: $${found:-none}): make $(1)-setup"; fi; \
  $(call std_doctor_started,$(1),$(2)) \
  if $(call std_started,$(1),$(2)); then $(call silabs_find,$(1),$(2)) $(silabs_slcp_versions) \
    if [ -n "$$slcp_sdk" ] && [ "$$slcp_sdk" != "$($(1)_SDK)" ]; then warn "$$(basename "$$slcp") asks for Simplicity SDK $$slcp_sdk, $(1)_SDK is $($(1)_SDK)"; fi; \
    if [ -n "$$slcp_wc" ] && [ "$$slcp_wc" != "$($(1)_WISECONNECT)" ]; then warn "$$(basename "$$slcp") asks for WiseConnect $$slcp_wc, $(1)_WISECONNECT is $($(1)_WISECONNECT)"; fi; \
  fi; \
  if [ -n "$($(1)_B)" ]; then ok "board $($(1)_B)"; else bad "no board: set $(1)_BOARD in make/project.mk (for example brd4338a)"; fi; \
  pb=; if $(call std_started,$(1),$(2)); then $(call silabs_find,$(1),$(2)) $(silabs_postbuild) \
    if [ -n "$$pb" ]; then ok "post_build $$pb in $$(basename "$$slcp"): the build makes the .rps with Simplicity Commander"; \
    elif [ -n "$(strip $($(1)_OTA_BUCKET))" ]; then warn "no post_build in $$(basename "$$slcp"): the build makes no .rps and make $(1)-release refuses; $(silabs_pb_lines)"; \
    else ok "no post_build in $$(basename "$$slcp") (no .rps; release needs one: $(silabs_pb_lines))"; fi; fi; \
  $(call silabs_cmdr,$(1)) if [ -n "$$cmdr" ]; then ok "Simplicity Commander $$cmdr"; \
  elif [ -n "$$pb" ]; then bad "Simplicity Commander missing: the build needs it (the .slcp's post_build $$pb runs commander postbuild to make the .rps), and flash, erase and power: $(call silabs_cmdr_fix,$(1))"; \
  else warn "Simplicity Commander missing, needed by flash, erase and power (and to build once the .slcp has a post_build): $(call silabs_cmdr_fix,$(1))"; fi; \
  case "$($(1)_P)" in \
    commander) ;; \
    jlink) if have JLinkExe; then ok "J-Link"; else bad "J-Link: brew install --cask segger-jlink"; fi; \
      if [ -z "$($(1)_JLINK_DEVICE)" ]; then bad "PROBE=jlink needs $(1)_JLINK_DEVICE (the J-Link device name of the chip)"; fi;; \
    *) bad "PROBE=$($(1)_P): use commander or jlink";; \
  esac; \
  if have JLinkGDBServerCLExe || have JLinkGDBServer; then ok "J-Link GDB server (debug)"; else warn "J-Link GDB server missing, needed by make $(1)-debug: brew install --cask segger-jlink"; fi; \
  if [ "$($(1)_SIGN)" = 1 ]; then $(call std_fw_key_check,$(1),$($(1)_KEY)) fi; \
  if have tio; then ok "tio (monitor)"; else warn "tio missing, needed by make $(1)-monitor: brew install tio"; fi; \
  $(std_fw_ports_check) \
  $(call std_fw_doctor_end,$(1))

silabs_update = $(STD_FW_SH) \
  if [ -n "$(TO)" ]; then $(call std_fw_pin,$(1)_SLT,$(TO)) $(if $(SDK),$(call std_fw_pin,$(1)_SDK,$(SDK))) $(if $(WISECONNECT),$(call std_fw_pin,$(1)_WISECONNECT,$(WISECONNECT))) $(MAKE) --no-print-directory $(1)-setup; \
  else say "$(1): slt $($(1)_SLT), Simplicity SDK $($(1)_SDK), WiseConnect $($(1)_WISECONNECT)"; \
    $(call silabs_tools,$(1)) if [ -x "$$slt" ]; then say "what slt has (slt list)"; "$$slt" list || true; fi; \
    say "pin with make $(1)-update TO=<slt version> [SDK=<simplicity_sdk version>] [WISECONNECT=<version>] (keep the .slcp sdk: versions the same), then commit make/project.mk"; fi

# $(call silabs_build,part,dir,build-dir,sign,check): slc generate from the .slcp into build-dir (a makefile project;
# --overwrite-all with <part>_SLC_OVERWRITE := 1, the default: -cp copies the sources into it, and without it slc keeps
# the old copies, so a later source edit was silently not rebuilt; no --toolchain, see the header), then the generated
# <name>.Makefile with POST_BUILD_EXE=<Simplicity Commander>, which the .slcp's post_build profile runs to make the .rps
# (no post_build: no .rps). check: the compiler runs with -Werror (CC overridden on the make line, which assumes the
# generated makefile compiles through $(CC), as slc's gcc makefiles do), and without Commander the post-build is skipped
# (POST_BUILD_EXE=true). sign: the .rps image is signed with the key KEY from the secrets repo into <name>-signed.rps
# (see silabs_sign). The defines of ENV (std_fw_env_sh) go the same way: appended to CC and CXX on the make line as
# single-quoted shell words, since the generated makefile has no variable of its own for extra defines (its C_DEFS
# would be replaced, not added to); a change of them makes build-dir again from scratch (the env stamp).
silabs_build = $(STD_FW_SH) $(call silabs_find,$(1),$(2)) $(silabs_postbuild) $(call silabs_tools,$(1)) $(call silabs_need_tools,$(1)) \
  board="$($(1)_B)"; [ -n "$$board" ] || die "no board: set $(1)_BOARD in make/project.mk or pass BOARD=... (for example brd4338a)"; \
  $(call std_fw_env_sh,$(1)) $(call std_fw_lock,$(3),make $(1)-$(if $(5),check,build)) $(call std_fw_env_fresh,$(1),$(3),rm -rf "$(3)") $(std_fw_env_say) \
  b="$(3)"; mkdir -p "$$b"; ARM_GCC_DIR=$$(dirname "$$gccdir"); export PATH="$${java:+$$java:}$$gccdir:$$PATH" ARM_GCC_DIR; \
  $(call silabs_cmdr,$(1)) pbexe=; \
  if [ -z "$$pb" ]; then say "no post_build in $$(basename "$$slcp"): no .rps (release needs one: $(silabs_pb_lines))"; \
  elif [ -n "$$cmdr" ]; then pbexe="$$cmdr"; say "post_build $$pb with $$cmdr"; \
  else \
    $(if $(5),pbexe=true; warn "Simplicity Commander not found: the post_build $$pb (the .rps) is skipped in this check build";,die "Simplicity Commander not found: the .slcp's post_build $$pb runs it (commander postbuild) to make the .rps. Fix: $(call silabs_cmdr_fix,$(1))";) \
  fi; \
  say "slc generate $$(basename "$$slcp") for $$board into $$b"; \
  "$$slc" generate "$$slcp" -np -cp $(if $(filter 1,$(strip $($(1)_SLC_OVERWRITE))),--overwrite-all )-d "$$b" -o makefile --with "$$board" --sdk-package-path "$$sdk,$$wc" --force $(filter-out --overwrite-all,$($(1)_SLC_ARGS)); \
  [ -f "$$b/$$name.Makefile" ] || die "slc made no $$name.Makefile in $$b"; \
  jobs=$$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4); \
  set --; [ -z "$$pbexe" ] || set -- POST_BUILD_EXE="$$pbexe"; \
  ccx="$(if $(5), -Werror)$${envflags:+ $$envflags}"; [ -z "$$ccx" ] || set -- "$$@" CC="$$gccdir/arm-none-eabi-gcc$$ccx"; \
  [ -z "$$envflags" ] || set -- "$$@" CXX="$$gccdir/arm-none-eabi-g++ $$envflags"; \
  say "make -f $$name.Makefile$(if $(5), with -Werror)"; \
  env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL make -C "$$b" -f "$$name.Makefile" -j "$$jobs" "$$@" $($(1)_MAKE_ARGS); \
  o="$$b/$($(1)_OUT)"; [ -f "$$o/$$name.hex" ] || [ -f "$$o/$$name.out" ] || die "the build made no $$name.hex or $$name.out in $$o"; \
  if [ -n "$$pb" ] && [ "$$pbexe" != true ]; then [ -f "$$o/$$name.rps" ] || die "the post_build $$pb ran but made no $$name.rps in $$o"; ok "$$o/$$name.rps"; fi; \
  $(if $(4),$(if $(filter 1,$($(1)_SIGN)),$(call silabs_sign,$(1)))) \
  $(call std_fw_env_stamp,$$b,"$($(1)_OUT)/$$name.hex" "$($(1)_OUT)/$$name.out" "$($(1)_OUT)/$$name.rps" "$($(1)_OUT)/$$name-signed.rps") \
  ok "built $$o"

# Image signing for SiWx917 M4 secure boot, run when SIGN=1 (default 0: a board whose secure boot is not provisioned
# runs unsigned images, and provisioning is a one-way manufacturing step). The key is an ECDSA P-256 private key in
# PEM from the secrets repo (make <part>-keygen), reaching commander only as secrets.sh with-file's temporary file.
# TODO(verify): the commander syntax below (rps convert OUT --app IN --sign KEY) is from Silicon Labs' SiWx917
# secure boot application note as remembered, not checked against `commander rps convert --help` of the installed
# Simplicity Commander. Check it, and the image format the OTA path expects, before setting <part>_SIGN := 1.
silabs_sign = rps="$$o/$$name.rps"; [ -f "$$rps" ] || die "no $$name.rps to sign in $$o: the .slcp's post_build makes it ($(silabs_pb_lines))"; \
  $(call silabs_need_cmdr,$(1)) say "signing $$name.rps with $(if $(SIGNING_KEY),$(SIGNING_KEY),$($(1)_KEY))"; \
  $(call std_fw_with_key,$($(1)_KEY)) "$$cmdr" rps convert "$$o/$$name-signed.rps" --app "$$rps" --sign "$(std_fw_keyarg)"; \
  ok "signed $$o/$$name-signed.rps";

# Sets b, o, name and img (the image to flash and to publish: <name>-signed.rps with SIGN=1, else <name>.hex for flash).
silabs_need_build = $(call silabs_find,$(1),$(2)) b="$($(1)_BUILD)"; o="$$b/$($(1)_OUT)"; [ -d "$$o" ] || die "no build in $$o: run make $(1)-build";
# $(call silabs_need_env,part,dir,target): the lock of the build folder (std_fw_lock), then a flash or OTA release of a
# build made with other defines than ENV's, or whose images changed since, refuses (std_fw_env_check)
silabs_need_env = $(call silabs_need_build,$(1),$(2)) $(call std_fw_lock,$$b,make $(1)-$(3)) $(call std_fw_env_check,$(1),$$b)

silabs_sel = $(if $($(1)_DEVICE),--device "$($(1)_DEVICE)") $(if $($(1)_PROBE_ID),--serialno "$($(1)_PROBE_ID)")

silabs_flash = $(STD_FW_SH) $(call silabs_need_env,$(1),$(2),flash) \
  if [ "$($(1)_SIGN)" = 1 ]; then img="$$o/$$name-signed.rps"; else img="$$o/$$name.hex"; fi; [ -f "$$img" ] || die "$$img not found: run make $(1)-build"; \
  case "$($(1)_P)" in \
    commander) $(call silabs_need_cmdr,$(1)) say "commander flash $$(basename "$$img")"; "$$cmdr" flash "$$img" $(call silabs_sel,$(1));; \
    jlink) have JLinkExe || die "JLinkExe not found: brew install --cask segger-jlink"; \
      [ -n "$($(1)_JLINK_DEVICE)" ] || die "PROBE=jlink needs $(1)_JLINK_DEVICE in make/project.mk (SiWx917 flash goes through its ROM bootloader: use PROBE=commander there)"; \
      cmd=$$(mktemp); trap 'rm -f "$$cmd"; std_fw_unlock' EXIT; printf 'r\nh\nloadfile %s\nr\ng\nexit\n' "$$o/$$name.hex" > "$$cmd"; \
      JLinkExe -device "$($(1)_JLINK_DEVICE)" -if SWD -speed 4000 -autoconnect 1 $(if $($(1)_PROBE_ID),-SelectEmuBySN "$($(1)_PROBE_ID)") -CommandFile "$$cmd";; \
    *) die "PROBE=$($(1)_P): silabs flashes with commander or jlink";; \
  esac; \
  ok "flashed $$img"

silabs_erase = $(STD_FW_SH) $(call silabs_need_cmdr,$(1)) "$$cmdr" device masserase $(call silabs_sel,$(1)); ok "$(1): flash mass erased"

silabs_monitor = $(STD_FW_SH) $(STD_FW_PORT) $(STD_FW_LOGGED) \
  have $(firstword $($(1)_MONITOR)) || die "$(firstword $($(1)_MONITOR)) not found: brew install $(firstword $($(1)_MONITOR))"; \
  logged "$(CURDIR)/$(2)/build/monitor.log" $($(1)_MONITOR) "$$port"

# GDB through the J-Link of the board (its J-Link OB) on the built .out (ELF).
silabs_debug = $(STD_FW_SH) $(call silabs_need_build,$(1),$(2)) $(call silabs_tools,$(1)) \
  elf="$$o/$$name.out"; [ -f "$$elf" ] || die "$$elf not found: run make $(1)-build"; \
  [ -n "$($(1)_JLINK_DEVICE)" ] || die "debug needs $(1)_JLINK_DEVICE in make/project.mk: the J-Link device name of the chip"; \
  srv=JLinkGDBServerCLExe; have "$$srv" || srv=JLinkGDBServer; have "$$srv" || die "J-Link GDB server not found: brew install --cask segger-jlink"; \
  gdb="$$gccdir/arm-none-eabi-gdb"; [ -x "$$gdb" ] || gdb=arm-none-eabi-gdb; \
  "$$srv" -device "$($(1)_JLINK_DEVICE)" -if SWD -speed 4000 -port 2331 $(if $($(1)_PROBE_ID),-select USB="$($(1)_PROBE_ID)") & pid=$$!; trap 'kill $$pid 2>/dev/null || true' EXIT; sleep 1; \
  "$$gdb" "$$elf" -ex 'target remote :2331'

# Host unit tests: make in <dir>/test (else <dir>/tests) when it has a Makefile, with the Mac's cc and BUILD_DIR under
# <dir>/build/test (so make <part>-clean removes the test build); without one, nothing to run.
silabs_test = $(STD_FW_SH) d="$(CURDIR)/$(2)"; t=; \
  for x in test tests; do if [ -f "$$d/$$x/Makefile" ]; then t="$$x"; break; fi; done; \
  if [ -z "$$t" ]; then say "$(1): no host tests (no Makefile in $(2)/test or $(2)/tests)"; exit 0; fi; \
  have "$(firstword $($(1)_TEST_CC))" || die "$(firstword $($(1)_TEST_CC)) not found: the host tests build with the Mac's compiler (xcode-select --install)"; \
  say "$(1): host tests in $(2)/$$t with $($(1)_TEST_CC)"; \
  env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL make -C "$$d/$$t" CC="$($(1)_TEST_CC)" BUILD_DIR="$$d/build/test" $(TEST_ARGS); \
  ok "$(1): host tests passed"

silabs_size = $(STD_FW_SH) $(call silabs_need_build,$(1),$(2)) $(call silabs_tools,$(1)) \
  size="$$gccdir/arm-none-eabi-size"; [ -x "$$size" ] || size=arm-none-eabi-size; "$$size" -A -d "$$o/$$name.out"; "$$size" "$$o/$$name.out"

# Energy profiling through the Advanced Energy Monitor of a Silicon Labs kit, read with Simplicity Commander.
# power: aem dump for <part>_POWER_S seconds (DURATION= wins) at AEM_RATE_HZ into <dir>/build/power.csv (commander
# prints the time in microseconds, the current in mA and the voltage in V), then the summary. power-live: the stream
# as it comes. power-avg: commander's own average over AEM_WINDOW_MS.
silabs_power = $(STD_FW_SH) $(call silabs_need_cmdr,$(1)) out="$(CURDIR)/$(2)/build"; mkdir -p "$$out"; csv="$$out/power.csv"; raw="$$out/power.raw"; \
  say "AEM at $($(1)_AEM_RATE) Hz for $($(1)_PW_S) s"; \
  "$$cmdr" aem dump --datarate "$($(1)_AEM_RATE)" --noheader $(if $($(1)_PROBE_ID),--serialno "$($(1)_PROBE_ID)") > "$$raw" & pid=$$!; \
  sleep "$($(1)_PW_S)"; kill "$$pid" 2>/dev/null || true; wait "$$pid" 2>/dev/null || true; \
  awk -F, 'BEGIN { print "time_s,current_mA,voltage_V" } /^[0-9]/ { printf "%.6f,%.6f,%.4f\n", $$1 / 1e6, $$2 + 0, $$3 + 0 }' "$$raw" > "$$csv"; \
  $(call std_fw_power_summary,$(1),$(2))
silabs_power_live = $(STD_FW_SH) $(call silabs_need_cmdr,$(1)) \
  "$$cmdr" aem dump --datarate "$($(1)_AEM_RATE)" --noheader $(if $($(1)_PROBE_ID),--serialno "$($(1)_PROBE_ID)") | \
  awk -F, '/^[0-9]/ { printf "%10.3f s  %8.3f mA  %6.3f V\n", $$1 / 1e6, $$2 + 0, $$3 + 0; fflush() }'
silabs_power_avg = $(STD_FW_SH) $(call silabs_need_cmdr,$(1)) \
  say "AEM average over $($(1)_AEM_WINDOW) ms"; "$$cmdr" aem measure --windowlength "$($(1)_AEM_WINDOW)" $(if $($(1)_PROBE_ID),--serialno "$($(1)_PROBE_ID)")

# OTA: the .rps image (signed with SIGN=1) to the OTA bucket as <part>.rps.
silabs_release = $(STD_FW_SH) $(call silabs_need_env,$(1),$(2),release) $(silabs_postbuild) \
  if [ ! -f "$$o/$$name.rps" ]; then \
    if [ -z "$$pb" ]; then die "no $$name.rps in $$o: $$(basename "$$slcp") has no post_build, so the build makes none. $(silabs_pb_lines) (WiseConnect's .rps step, run by Simplicity Commander), then make $(1)-build. Nothing was uploaded"; \
    else die "no $$name.rps in $$o: the post_build $$pb of $$(basename "$$slcp") makes it with Simplicity Commander (make $(1)-doctor checks it); make $(1)-build. Nothing was uploaded"; fi; \
  fi; \
  if [ "$($(1)_SIGN)" = 1 ]; then f="$$o/$$name-signed.rps"; else f="$$o/$$name.rps"; warn "$(1)_SIGN is not 1: publishing an unsigned image"; fi; \
  $(call std_fw_env_check,$(1),$$b,$$f) $(call std_fw_release,$(1),$(2),$(1).rps)

# GitHub Release assets: the hex (factory programming), the .rps images (OTA; signed with SIGN=1), the .out (ELF,
# debug symbols), the map, and the .s37 and .bin when the build made them.
silabs_release_assets = $(STD_FW_SH) $(call silabs_need_build,$(1),$(2)) $(call std_rel_begin,$(1),silabs,$(2)) \
  need "$$o/$$name.hex"; need "$$o/$$name.out"; \
  if [ "$($(1)_SIGN)" = 1 ]; then need "$$o/$$name-signed.rps"; fi; opt "$$o/$$name.rps"; \
  opt "$$o/$$name.map"; opt "$$o/$$name.s37"; opt "$$o/$$name.bin"; \
  $(std_rel_end)

# --- the kind -----------------------------------------------------------------------------------
#
# Per-part settings (make/project.mk, <part>_<VAR>), with their defaults:
#   BOARD          brd4338a  the slc board (--with), for example brd4338a (SiWx917 radio board); BOARD= wins; stripped
#                  of spaces wherever it is used (a trailing space in make/project.mk is not part of the board)
#   SLT            1.1.1     the slt CLI, in $(STD_TOOLCHAINS)/slt-<ver>, shared across projects
#   SDK            2025.12.2 Simplicity SDK (simplicity_sdk) version the build uses
#   WISECONNECT    4.0.1     WiseConnect 3 (wiseconnect3_sdk) version the build uses
#   SLT_INSTALL    slc-cli wiseconnect/$(<part>_WISECONNECT) commander/$(<part>_COMMANDER)   what setup asks slt to
#                  install (slt keeps it in SLT_HOME, ~/.silabs/slt); setup then checks that SDK and WISECONNECT are
#                  among what is installed. The WiseConnect version is pinned: a bare wiseconnect installs the latest
#                  (and its newer SDK)
#   COMMANDER      1.25.0    Simplicity Commander, slt's commander package (Commander.app on macOS): setup installs it,
#                  and the kind uses it when no commander is on PATH or in SILABS_COMMANDER_PATHS; empty: slt
#                  installs none (bring your own)
#   GCC            12.2.rel1  the GNU Arm toolchain slt installs with the SDK (its <ver>-*manifest.txt); empty: the
#                  first one found
#   SLCP           (the one *.slcp in the part dir)   the slc project
#   OUT            build/debug   where the generated makefile puts <name>.hex/.out/.rps, under the build dir
#   SLC_ARGS, MAKE_ARGS   extra slc generate / make arguments
#   ENV_DEFINES_<env>  C defines for ENV=<env> (local, staging, production), NAME=value words, appended to CC and
#                  CXX on the generated makefile's make line
#   SLC_OVERWRITE  1  slc generate --overwrite-all (0: slc keeps the copied sources it generated before)
#   TEST_CC        cc  the host compiler of make <part>-test (TEST_ARGS= extra make arguments)
#   PROBE          commander  commander (Simplicity Commander) or jlink (PROBE= wins); DEVICE commander --device;
#                  PROBE_ID the kit's J-Link serial (commander --serialno, J-Link -SelectEmuBySN)
#   JLINK_DEVICE   the J-Link device name, for debug (JLinkGDBServer) and PROBE=jlink flash
#   SIGN 0, KEY silabs-m4   SIGN=1 signs the .rps with the ECDSA P-256 key KEY from the secrets repo
#                  (make <part>-keygen); SIGNING_KEY=path uses a local key file instead
#   MONITOR        tio -b BAUD (BAUD 115200), on the kit's J-Link VCOM port
#   POWER_S 10     seconds of make <part>-power (DURATION= wins); AEM_RATE_HZ 10 (AEM_RATE_HZ= wins);
#   AEM_WINDOW_MS  310000  make <part>-power-avg window (AEM_WINDOW_MS= wins)
#   PROVISION      shell command for make <part>-provision SERIAL=... (default: flash only)
#   OTA_BUCKET     $(OTA_BUCKET) from make/project.mk;  OTA_PREFIX  <project>/<part>/<env>;  WRANGLER  npx --yes wrangler@4
#   RELEASE_HOOK   shell command run after a release upload (VERSION SHA256 OTA_KEY OTA_FILE set)
# Builds go to <dir>/build/<board>; `make <part>-check` builds with -Werror into <dir>/build/check-<board>.

define kind_silabs
# the part is started once its folder has its .slcp (std_started in common.mk)
$(1)_START ?= *.slcp
$(1)_BOARD ?= brd4338a
$(1)_SLT ?= 1.1.1
$(1)_SDK ?= 2025.12.2
$(1)_WISECONNECT ?= 4.0.1
$(1)_COMMANDER ?= 1.25.0
$(1)_SLT_INSTALL ?= slc-cli wiseconnect/$$(strip $$($(1)_WISECONNECT))$$(if $$(strip $$($(1)_COMMANDER)), commander/$$(strip $$($(1)_COMMANDER)))
$(1)_GCC ?= 12.2.rel1
$(1)_SLT_HOME ?= $$(HOME)/.silabs/slt
$(1)_SLT_DIR ?= $$(STD_TOOLCHAINS)/slt-$$($(1)_SLT)
$(1)_SLCP ?=
$(1)_OUT ?= build/debug
$(1)_SLC_ARGS ?=
$(1)_SLC_OVERWRITE ?= 1
$(1)_TEST_CC ?= cc
$(1)_MAKE_ARGS ?=
$(1)_PROBE ?= commander
$(1)_DEVICE ?=
$(1)_PROBE_ID ?=
$(1)_JLINK_DEVICE ?=
$(1)_SIGN ?= 0
$(1)_KEY ?= silabs-m4
$(1)_BAUD ?= 115200
$(1)_MONITOR ?= tio -b $$($(1)_BAUD)
$(1)_POWER_S ?= 10
$(1)_AEM_RATE_HZ ?= 10
$(1)_AEM_WINDOW_MS ?= 310000
$(1)_PROVISION ?=
$(1)_OTA_BUCKET ?= $$(OTA_BUCKET)
# no OTA bucket (no Cloudflare in the project): <part>-release publishes nothing, and help leaves it out
STD_HELP_HIDE += $$(if $$(strip $$($(1)_OTA_BUCKET)),,$(1)-release)
$(1)_OTA_PREFIX ?= $$(PROJECT)/$(1)/$$(ENV)
$(1)_WRANGLER ?= npx --yes wrangler@4
$(1)_RELEASE_HOOK ?=
$(1)_B = $$(strip $$(or $$(strip $$(BOARD)),$$($(1)_BOARD)))
$(1)_P = $$(or $$(PROBE),$$($(1)_PROBE))
$(1)_PW_S = $$(or $$(DURATION),$$($(1)_POWER_S))
$(1)_AEM_RATE = $$(or $$(AEM_RATE_HZ),$$($(1)_AEM_RATE_HZ))
$(1)_AEM_WINDOW = $$(or $$(AEM_WINDOW_MS),$$($(1)_AEM_WINDOW_MS))
$(1)_BUILD = $$(CURDIR)/$(2)/build/$$($(1)_B)
$(1)_CHECK_BUILD = $$(CURDIR)/$(2)/build/check-$$($(1)_B)

.PHONY: $(1)-release-run $(1)-doctor $(1)-setup $(1)-update $(1)-check $(1)-test $(1)-build $(1)-clean $(1)-distclean $(1)-flash $(1)-erase $(1)-monitor $(1)-debug $(1)-release $(1)-version $(1)-size $(1)-keygen $(1)-provision $(1)-power $(1)-power-live $(1)-power-avg

$(call std_verb,$(1),doctor,firmware,Check slt and slc and the SDK and WiseConnect and Commander and probe and ports read only)
$(1)-doctor:
	@$$(call silabs_doctor,$(1),$(2))

$(call std_verb,$(1),setup,firmware,Install slt $$($(1)_SLT) into $$(STD_TOOLCHAINS) and through it slc and Simplicity SDK $$($(1)_SDK) and WiseConnect $$($(1)_WISECONNECT) and Commander)
$(1)-setup:
	@$$(call std_skip_unstarted,$(1),$(2),setup) $$(call silabs_setup,$(1),$(2))

# The commands that run slc or the toolchain set up the pinned slt, SDK and WiseConnect first when they are not ready.
$(call std_ready,$(1),$(2),silabs_ready,check build flash debug size)

$(call std_verb,$(1),update,firmware,Show the pinned slt and SDK versions or pin TO= [SDK=] [WISECONNECT=] in make/project.mk and set up)
$(1)-update:
	@$$(call silabs_update,$(1),$(2))

$(call std_verb,$(1),check,firmware,slc generate and build with -Werror into $(2)/build/check-<board>)
$(1)-check:
	@$$(call std_skip_unstarted,$(1),$(2),check) $$(call silabs_build,$(1),$(2),$$($(1)_CHECK_BUILD),,1)

$(call std_verb,$(1),test,test,Host unit tests from the Makefile in $(2)/test or $(2)/tests with the Mac cc and none is fine)
$(1)-test:
	@$$(call silabs_test,$(1),$(2))

$(call std_verb,$(1),build,firmware,slc generate and build for $$($(1)_B) into $(2)/build and sign with SIGN=1)
$(1)-build:
	@$$(call std_skip_unstarted,$(1),$(2),build) $$(call silabs_build,$(1),$(2),$$($(1)_BUILD),1,)

$(call std_verb,$(1),flash,firmware,Build then flash with PROBE= commander or jlink and NOBUILD=1 to skip the build)
$(1)-flash: $$(if $$(NOBUILD),,$(1)-build)
	@$$(call std_refuse_unstarted,$(1),$(2),flash) $$(call silabs_flash,$(1),$(2))

$(call std_verb,$(1),erase,firmware,Mass erase the flash with Simplicity Commander and needs CONFIRM=erase)
$(1)-erase:
	@$$(call std_confirm,erase) && { $$(call silabs_erase,$(1),$(2)); }

$(call std_verb,$(1),monitor,firmware,Serial console on the kit VCOM PORT or the only port and logged to $(2)/build/monitor.log)
$(1)-monitor:
	@$$(call silabs_monitor,$(1),$(2))

$(call std_verb,$(1),debug,firmware,GDB on the built image through the J-Link GDB server)
$(1)-debug:
	@$$(call silabs_debug,$(1),$(2))

$(call std_extra,$(1),size,firmware,Section sizes of the built image)
$(1)-size:
	@$$(call silabs_size,$(1),$(2))

$(call std_extra,$(1),power,firmware,AEM current profile for DURATION= seconds into $(2)/build/power.csv with avg min max)
$(1)-power:
	@$$(call silabs_power,$(1),$(2))

$(call std_extra,$(1),power-live,firmware,Stream the AEM current and voltage at AEM_RATE_HZ)
$(1)-power-live:
	@$$(call silabs_power_live,$(1),$(2))

$(call std_extra,$(1),power-avg,firmware,Average current over AEM_WINDOW_MS from Simplicity Commander)
$(1)-power-avg:
	@$$(call silabs_power_avg,$(1),$(2))

$(call std_extra,$(1),keygen,firmware,Create the SiWx917 M4 image signing key $$($(1)_KEY) (ECDSA P-256) in the secrets repo and never overwrite)
$(1)-keygen:
	@$$(call std_fw_keygen,$(1),$$($(1)_KEY),ecdsa-p256)

$(call std_extra,$(1),provision,firmware,Per device setup SERIAL= through $(1)_PROVISION else flash only)
$(1)-provision:
	@$$(call std_fw_provision,$(1))

$(call std_verb,$(1),release,release,The .rps image to the OTA store as ver and latest with ENV= and PROMOTE=1 for stable)
$(1)-release:
	@if [ -z "$$(strip $$($(1)_OTA_BUCKET))" ]; then echo "> $(1): no OTA bucket (no Cloudflare in this project): firmware publish skipped"; exit 0; fi; if $$(call std_fw_tag_ok,$(1)); then $$(MAKE) --no-print-directory $(1)-release-run; else echo "$(1): tag $$$$CI_COMMIT_TAG is not a $(1) release, nothing to do"; fi

$(1)-release-run:
	@$$(call std_refuse_unstarted,$(1),$(2),release) $$(std_production_guard) && { $$(std_fw_remote_env); } && $$(if $$(NOBUILD),true,$$(MAKE) --no-print-directory $(1)-build) && { $$(call silabs_release,$(1),$(2)); }

$(call std_verb,$(1),version,release,Firmware version from $(2)/VERSION)

# release.sh knows the version source of the firmware kinds by name; silabs keeps its version as they do (<dir>/VERSION,
# else version.txt), so it is passed as espidf until release.sh lists silabs itself.
$(call std_release,$(1),silabs,$(2),silabs_release_assets,build)
$(1)-version:
	@$$(call std_fw_print_version,$(1),$(2))

$(call std_verb,$(1),clean,firmware,Remove $(2)/build and the host test build under it)
$(1)-clean:
	@rm -rf "$$(CURDIR)/$(2)/build"

$(call std_verb,$(1),distclean,firmware,Remove $(2)/build and keep the shared slt and SDK)
$(1)-distclean: $(1)-clean
endef
