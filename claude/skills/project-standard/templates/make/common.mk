# project-standard v1.0 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# The stage commands, the same in every project. GNU make 3.81 compatible (macOS /usr/bin/make):
# no .ONESHELL, .SHELLFLAGS, $(file), .RECIPEPREFIX, undefine, != or ::=.
#
# Order in this file: variables, guard and fan-out macros, help registration, kinds and parts,
# root targets, then make/local.mk. Recipe lines below start with a tab.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# --- variables ---------------------------------------------------------------------------------

# A stray ENV from the shell (a POSIX startup-file variable) must not break make: ignore it unless valid.
ifeq ($(origin ENV),environment)
ifeq ($(filter local staging production,$(ENV)),)
ENV := local
endif
endif
ENV ?= local
ifeq ($(filter local staging production,$(ENV)),)
$(error ENV=$(ENV) is not valid: use local, staging or production)
endif

CONFIRM ?=
PART ?=
STD_TOOLCHAINS ?= $(HOME)/.toolchains
STD_CONFIG ?= $(HOME)/.config/project-standard
STD_BIN ?= make/bin
SECRETS_SCHEMA ?= $(CURDIR)/secrets.schema
# OTA_BUCKET belongs to the project (make/project.mk): each project has its own Cloudflare token and
# account, and CI reads project.mk, never the user config. A value in config.mk (v5 and earlier) is ignored.
STD_OTA_BUCKET_PROJECT := $(OTA_BUCKET)
# CI_TEMPLATES_REPO set in make/project.mk wins over the user config (1.7).
STD_CI_TEMPLATES_REPO_PROJECT := $(CI_TEMPLATES_REPO)
# The secrets repo follows the project's GitHub owner (1.8). SECRETS_DIR and SECRETS_REMOTE from make/project.mk or
# the environment, and GITHUB_OWNER from the environment, are captured with their origin and cleared, so what config.mk
# sets is known apart (config.mk assigns with :=); all three are resolved below. The command line wins over everything.
STD_P_GITHUB_OWNER := $(GITHUB_OWNER)
STD_P_GITHUB_OWNER_FROM := $(origin GITHUB_OWNER)
STD_P_SECRETS_DIR := $(SECRETS_DIR)
STD_P_SECRETS_DIR_FROM := $(origin SECRETS_DIR)
STD_P_SECRETS_REMOTE := $(SECRETS_REMOTE)
STD_P_SECRETS_REMOTE_FROM := $(origin SECRETS_REMOTE)
GITHUB_OWNER :=
SECRETS_DIR :=
SECRETS_REMOTE :=
-include $(STD_CONFIG)/config.mk
STD_CONFIG_OWNER := $(GITHUB_OWNER)
STD_CONFIG_SECRETS_DIR := $(SECRETS_DIR)
STD_CONFIG_SECRETS_REMOTE := $(SECRETS_REMOTE)
ifneq ($(OTA_BUCKET),$(STD_OTA_BUCKET_PROJECT))
$(warning OTA_BUCKET in $(STD_CONFIG)/config.mk is ignored since project-standard v6: set OTA_BUCKET in make/project.mk and remove it from config.mk)
OTA_BUCKET := $(STD_OTA_BUCKET_PROJECT)
endif
# GITHUB_OWNER is the GitHub account (a User, or an Org) that owns the project's repos: <owner>/<project> and
# <owner>/secrets are private. It is the project's own owner (1.8): in GitHub Actions GITHUB_REPOSITORY_OWNER (or the
# owner part of GITHUB_REPOSITORY), else the owner of the git remote origin when it is on github.com
# (https://github.com/<owner>/<repo>, git@github.com:<owner>/<repo>, ssh://git@github.com/<owner>/<repo>), else, with
# no GitHub origin yet, the user config's (~/.config/project-standard/config.mk), else the environment's. git runs
# once per make run (a sub-make reads the exported result), and only when the project root holds .git (a folder, or
# a worktree's file); without one there is simply no origin.
# STD_OWNER_FROM says where it came from (ci, origin, config); the user config's owner is the default owner.
ifeq ($(origin STD_ORIGIN_OWNER),undefined)
STD_ORIGIN_OWNER := $(if $(wildcard $(CURDIR)/.git),$(shell git remote get-url origin 2>/dev/null | sed -n -E 's%^(https?://([^@/]*@)?github\.com/|ssh://git@github\.com/|git@github\.com:)([A-Za-z0-9][A-Za-z0-9-]*)/[A-Za-z0-9._-]+/?$$%\3%p' | tr 'A-Z' 'a-z'))
endif
export STD_ORIGIN_OWNER
ifeq ($(strip $(STD_CONFIG_OWNER)),)
ifeq ($(STD_P_GITHUB_OWNER_FROM),environment)
STD_CONFIG_OWNER := $(STD_P_GITHUB_OWNER)
endif
endif
STD_CI_OWNER := $(or $(GITHUB_REPOSITORY_OWNER),$(if $(findstring /,$(GITHUB_REPOSITORY)),$(firstword $(subst /, ,$(GITHUB_REPOSITORY)))))
ifneq ($(strip $(STD_CI_OWNER)),)
GITHUB_OWNER := $(STD_CI_OWNER)
STD_OWNER_FROM := ci
else ifneq ($(strip $(STD_ORIGIN_OWNER)),)
GITHUB_OWNER := $(STD_ORIGIN_OWNER)
STD_OWNER_FROM := origin
else
GITHUB_OWNER := $(STD_CONFIG_OWNER)
STD_OWNER_FROM := $(if $(strip $(STD_CONFIG_OWNER)),config)
endif
ifeq ($(origin GITHUB_OWNER),command line)
STD_OWNER_FROM := command line
# config.mk could not set it: read the default owner from the file itself
STD_CONFIG_OWNER := $(shell sed -n -E 's/^[[:space:]]*GITHUB_OWNER[[:space:]]*[:?]?=[[:space:]]*([^[:space:]]*).*/\1/p' "$(STD_CONFIG)/config.mk" 2>/dev/null | tail -n 1)
endif
# One secrets repo per owner (reference/standard.md 5.1), the same rule for every owner: SECRETS_DIR ~/.secrets-<owner>,
# SECRETS_REMOTE https://github.com/<owner>/secrets.git. The environment or make/project.mk win (a last-resort override;
# write it with ?= so CI's SECRETS_DIR still wins). The user config's SECRETS_REMOTE is its own owner's repo and never
# reaches a project of another owner; its SECRETS_DIR is used only when there is no owner at all (else ~/.secrets, as
# before 1.8). SECRETS_DEFAULT_DIR is the user config's owner's checkout, the first place a new secrets repo copies the
# Macs' recipients from (make secrets-init); secrets.sh then looks at the other ~/.secrets-* on this Mac.
STD_SAME_OWNER := $(if $(filter-out $(STD_CONFIG_OWNER),$(GITHUB_OWNER)),,1)
SECRETS_DEFAULT_DIR ?= $(if $(strip $(STD_CONFIG_OWNER)),$(HOME)/.secrets-$(strip $(STD_CONFIG_OWNER)))
ifneq ($(strip $(if $(filter environment file,$(STD_P_SECRETS_DIR_FROM)),$(STD_P_SECRETS_DIR))),)
SECRETS_DIR := $(STD_P_SECRETS_DIR)
else ifneq ($(strip $(GITHUB_OWNER)),)
SECRETS_DIR := $(HOME)/.secrets-$(strip $(GITHUB_OWNER))
else
SECRETS_DIR := $(or $(STD_CONFIG_SECRETS_DIR),$(HOME)/.secrets)
endif
ifneq ($(strip $(if $(filter environment file,$(STD_P_SECRETS_REMOTE_FROM)),$(STD_P_SECRETS_REMOTE))),)
SECRETS_REMOTE := $(STD_P_SECRETS_REMOTE)
else ifneq ($(and $(STD_SAME_OWNER),$(strip $(STD_CONFIG_SECRETS_REMOTE))),)
SECRETS_REMOTE := $(STD_CONFIG_SECRETS_REMOTE)
else ifneq ($(strip $(GITHUB_OWNER)),)
SECRETS_REMOTE := https://github.com/$(GITHUB_OWNER)/secrets.git
else
SECRETS_REMOTE :=
endif
# CI_TEMPLATES_REPO (owner/name) is the repository of the reusable workflows, independent of GITHUB_OWNER (1.7):
# make/project.mk, else the user config, else the public mayankgautam-me/ci-templates. CI_TEMPLATES_PROJECT is ignored.
ifneq ($(strip $(STD_CI_TEMPLATES_REPO_PROJECT)),)
CI_TEMPLATES_REPO := $(STD_CI_TEMPLATES_REPO_PROJECT)
endif
CI_TEMPLATES_REPO ?= mayankgautam-me/ci-templates
PORT_BASE ?= 8000

ifeq ($(strip $(PROJECT)),)
$(error PROJECT is not set: put PROJECT := <name> in make/project.mk)
endif

export PROJECT PORT_BASE SECRETS_DIR SECRETS_DEFAULT_DIR STD_CONFIG SECRETS_REMOTE GITHUB_OWNER STD_OWNER_FROM STD_CONFIG_OWNER OTA_BUCKET DOCKER_REGISTRY
export CI_TEMPLATES_REPO STD_TOOLCHAINS SECRETS_SCHEMA

STD_LIB := . $(STD_BIN)/lib.sh
STD_SECRETS := bash $(STD_BIN)/secrets.sh
STD_CF := bash $(STD_BIN)/cf.sh
# toolchain.sh: the usage record, the installed ledger, make teardown and make prune. Absolute, with the project root named,
# because the kinds call it from inside a part's folder (since v17).
STD_TC := STD_PROJECT_DIR="$(CURDIR)" bash $(CURDIR)/$(STD_BIN)/toolchain.sh
STD_RELEASE := bash $(STD_BIN)/release.sh
# the same, absolute: the helpers of the app kinds cd into their part before they call it (since v8)
STD_RELEASE_ABS := bash $(CURDIR)/$(STD_BIN)/release.sh
# The platform a release-assets or github-release run builds (since v8): macos on a Mac, linux-amd64 or linux-arm64
# on Linux, windows under Git Bash. A CI job sets PLATFORM in its variables; a Mac also builds ios and android
# (PLATFORM=ios FORCE=1 make <part>-github-release). See reference/standard.md 4.12.
STD_HOST_PLATFORM := $(shell $(STD_RELEASE) host-platform)
PLATFORM ?= $(STD_HOST_PLATFORM)
# std_has_env ENV: the env file of ENV exists in the secrets repo on this machine (names are not checked here).
std_has_env = $(wildcard $(SECRETS_DIR)/$(PROJECT)/$(1).env.sops)
# std_secret_prefix ENV: the command prefix that runs a build with ENV's secrets in its environment, or nothing when
# ENV has no secrets here (the build then runs unsigned; the helper says so).
std_secret_prefix = $(if $(call std_has_env,$(1)),bash $(CURDIR)/$(STD_BIN)/secrets.sh exec --env $(1) --,)
# std_apple_prefix: the production secrets (std_secret_prefix), and the App Store key of keys/appstore-api-key as the file
# APPLE_API_KEY_PATH (notarisation) when the secrets hold it. The command follows the prefix.
std_apple_prefix = $(call std_secret_prefix,production) $(if $(wildcard $(SECRETS_DIR)/$(PROJECT)/keys/appstore-api-key.sops),bash $(CURDIR)/$(STD_BIN)/secrets.sh with-file appstore-api-key -- sh -c 'export APPLE_API_KEY_PATH="$$1"; shift; exec "$$@"' sh {} ,)

# Every verb a kind may fan out. `bump` and `github-release` act on one part (root `make bump PART=...`).
STD_VERBS := doctor setup update dev stop status logs reset check test test-e2e test-device format \
  build deploy smoke test-remote preview promote versions rollback release version bump github-release clean distclean \
  flash erase monitor debug

# --- helpers -----------------------------------------------------------------------------------

empty :=
space := $(empty) $(empty)
define newline


endef

# --- guard integrity ---------------------------------------------------------------------------
# A guard trusts CONFIRM only when it was typed on the make command line, and it only protects the shell
# line it shares with its action. Refuse the ways around both, before anything else is read:
#  - make -i / --ignore-errors lets a failed guard line carry on with the next recipe line;
#  - MAKEFLAGS='CONFIRM=...' in the environment makes make treat CONFIRM as a command line variable.
# The second is found by looking at the argv of the make process itself (/proc on Linux, ps on macOS):
# MAKEFLAGS cannot be told apart from the command line from inside make (4.x even rewrites it).
ifneq ($(filter -i --ignore-errors,$(MAKEFLAGS)),)
$(error make -i / --ignore-errors is refused: it would skip failed guards)
endif
ifneq ($(findstring i,$(filter-out -% %=%,$(firstword $(MAKEFLAGS)))),)
$(error make -i / --ignore-errors is refused: it would skip failed guards)
endif
ifeq ($(MAKELEVEL),0)
ifeq ($(origin CONFIRM),command line)
STD_ARGV := $(shell if [ -r /proc/$$PPID/cmdline ]; then tr '\0' ' ' </proc/$$PPID/cmdline; else ps -o args= -p $$PPID 2>/dev/null; fi)
ifeq ($(strip $(STD_ARGV)),)
$(error cannot read the make command line to check where CONFIRM came from; run make from a shell where ps works)
endif
ifeq ($(findstring $(space)CONFIRM=,$(space)$(STD_ARGV)),)
$(error CONFIRM did not come from the make command line (MAKEFLAGS in the environment?); type CONFIRM=<value> after make)
endif
endif
endif

std_name = $(word 1,$(subst :, ,$(1)))
std_kind = $(word 2,$(subst :, ,$(1)))
std_dir  = $(or $(word 3,$(subst :, ,$(1))),$(word 1,$(subst :, ,$(1))))

# Help entries are stored as group|target|description with spaces turned into __SP__ (a make list
# cannot hold spaces). Descriptions must not contain commas, pipes or dollar signs.
STD_HELP =
# Targets help leaves out unless ALL=1 (a kind adds the ones that do nothing in this project: a firmware part's
# release without an OTA bucket). A root verb is listed only while one of its parts is not hidden.
STD_HELP_HIDE :=

# std_verb part,verb,group,description : register <part>-<verb> for the root fan-out and for help.
define std_verb
STD_VERB_$(2) += $(1)-$(2)
STD_HELP += $(subst $(space),__SP__,$(3)|$(1)-$(2)|$(4))
endef

# std_extra part,target-suffix,group,description : help only, no fan-out.
define std_extra
STD_HELP += $(subst $(space),__SP__,$(3)|$(1)-$(2)|$(4))
endef

# std_h group,target,description : help entry for a root target.
std_h = $(eval STD_HELP += $(subst $(space),__SP__,$(1)|$(2)|$(3)))

# The parts a root verb applies to, in PARTS order, restricted by PART=.
std_sel = $(if $(PART),$(filter $(PART)-$(1),$(STD_VERB_$(1))),$(STD_VERB_$(1)))

# A shell line that refuses with a message (exit 1).
std_refuse = $(STD_LIB); log_err "refused: $(1)"; exit 1

# Guards. A guard expands to a shell command that EXITS the recipe's shell with status 1 (and a message)
# unless it passes, when it is `true`. It protects only the shell line it is on, so it must share a line
# with the action: `@$(call std_confirm,x) && action`, or `guard; action` when the action holds several
# commands. A guard on a line of its own, or as a prerequisite, is skipped by `make -i` and by `-`/.IGNORE.
# std_confirm passes only when CONFIRM=<env> was typed on the make command line (not the environment).
std_confirm = $(if $(filter command line,$(origin CONFIRM)),$(if $(and $(filter $(1),$(CONFIRM)),$(filter 1,$(words $(CONFIRM)))),true,$(call std_refuse,CONFIRM has the wrong value; this needs CONFIRM=$(1))),$(call std_refuse,this needs CONFIRM=$(1) on the make command line))
std_production_guard = $(if $(filter production,$(ENV)),$(call std_confirm,production),true)
# std_remote_guard part : for the targets that deploy: refuse ENV=local, and production without CONFIRM.
std_remote_guard = { test "$(ENV)" != local || { echo "$(1): ENV=local is not deployed, use ENV=staging or ENV=production"; exit 1; }; } && $(std_production_guard)

# std_need VAR : refuse unless VAR was given.
std_need = $(if $($(1)),true,$(call std_refuse,$(1)= is required))

# Fan out one verb over its parts (one sub-make per part, in PARTS order). Second argument: keep
# (carry on after a failure and exit 1 at the end). Third argument: extra make arguments.
define std_fan_loop
( $(STD_LIB); n=$(words $(call std_sel,$(1))); rc=0; \
  for t in $(call std_sel,$(1)); do \
    if [ "$$n" -gt 1 ]; then hdr "$$t"; fi; \
    $(MAKE) --no-print-directory $(3) "$$t" || { rc=$$?; [ "$(2)" = keep ] || exit "$$rc"; }; \
  done; exit "$$rc" )
endef
std_fan = $(if $(call std_sel,$(1)),$(call std_fan_loop,$(1),$(2),$(3)),$(STD_LIB); log_info "no part has '$(1)'")

# The firmware verbs act on exactly one part.
std_single = $(if $(call std_sel,$(1)),$(if $(word 2,$(call std_sel,$(1))),$(STD_LIB); log_err "several parts have '$(1)'; pick one with PART=<part> or run one of: $(call std_sel,$(1))"; exit 2,$(MAKE) --no-print-directory $(call std_sel,$(1))),$(STD_LIB); log_err "no part has '$(1)'"; exit 2)

# cloud-worker parts (restricted by PART=) and their directories.
std_cf_dirs = $(foreach p,$(PARTS),$(if $(and $(filter cloud-worker,$(call std_kind,$(p))),$(if $(PART),$(filter $(PART),$(call std_name,$(p))),x)),$(call std_dir,$(p))))
std_cf_each = $(if $(strip $(std_cf_dirs)),for d in $(std_cf_dirs); do $(STD_CF) $(1) --project "$(PROJECT)" --env "$(ENV)" --dir "$$d" $(2) || exit $$?; done,$(STD_LIB); log_info "no cloud-worker part$(if $(PART), named $(PART))")
# The OTA bucket(s) of make/project.mk (cf.sh provision-ota, status-ota): project-wide, so they run after the parts,
# unless PART= picks a cloud-worker part. A project with no cloud-worker part and an OTA bucket skips the parts' line.
std_cf_ota = $(if $(and $(PART),$(strip $(std_cf_dirs))),true,$(STD_CF) $(1) --project "$(PROJECT)" --env "$(ENV)")
std_cf_parts = $(if $(or $(PART),$(strip $(std_cf_dirs)),$(if $(std_ota_any),,x)),$(call std_cf_each,$(1),$(2)),true)

# R2_UNBACKED=1 on the command line (not the environment) lets wipe/destroy go on although R2 objects are not in the backup.
STD_R2_FLAG = $(if $(filter command line,$(origin R2_UNBACKED)),$(if $(filter 1,$(R2_UNBACKED)),--r2-unbacked))

# --- releases (release.sh) ---------------------------------------------------------------------
# Every kind with a version calls $(call std_release,part,kind,dir,assets-helper,pre-steps) in its template. It
# registers <part>-bump and <part>-github-release (verbs) and <part>-release-assets (extra):
#   <part>-bump            LEVEL=patch|minor|major or VERSION=x.y.z: the kind's version file, the CHANGELOG, a commit
#                          and the tag <part>-v<version> (release.sh bump); nothing is pushed
#   <part>-release-assets  runs <part>-<step> for each pre-step (unless NOBUILD=1), then the kind's assets helper, which
#                          fills <dir>/release/<version>/ and writes SHA256SUMS (std_rel_begin ... std_rel_end). A kind
#                          with no assets helper (cloud-worker, web-pages: what they release is the deploy) has no
#                          files: its Release carries the CHANGELOG notes only (release.sh create --notes-only)
#   <part>-github-release  in the release workflow of tag <part>-v<version> (FORCE=1 outside CI): release-assets, then
#                          create or update the GitHub Release (its files; the unlinked store bundles stay in the build
#                          folder for the workflow to upload as artifacts). No CONFIRM: it publishes to the project's
#                          own repo, not to production. From a Mac it also updates the latest Release.
#   <part>-release-latest  (since v20) copy the part's published Release (VERSION= or the current version) into the
#                          Release "latest", which holds the newest files of every part and carries GitHub's Latest
#                          badge; the release workflow's latest job runs it after the part's jobs
# FORCE counts only from the command line.
std_force = $(if $(and $(filter command line,$(origin FORCE)),$(filter 1,$(FORCE))),--force)
STD_BUMP_ARGS = $(if $(LEVEL),--level "$(LEVEL)") $(if $(filter command line,$(origin VERSION)),--version "$(VERSION)") $(std_force)

# Shell text for an assets helper (expanded when the recipe runs; `$$` for the shell, no `#`):
# std_rel_begin part,kind,dir sets ver and out (an empty <dir>/release/<ver>) and defines
#   put FILE [NAME]    copy FILE into out as NAME (default: its name); non-zero when FILE is missing
#   need FILE [NAME]   put or fail;   opt FILE [NAME]   put or say it is skipped
#   zipdir DIR NAME    zip the content of DIR into out/NAME (release.sh zip)
# std_rel_end writes SHA256SUMS.
# (since v8) plat is PLATFORM, and need_glob / opt_glob take the first file a glob matches (the name is the second argument).
std_rel_begin = plat="$(PLATFORM)"; ver=$$($(STD_RELEASE_ABS) version --part $(1) --kind $(2) --part-dir $(3) --platform "$$plat"); \
  out="$(CURDIR)/$(3)/release/$$ver"; rm -rf "$$out"; mkdir -p "$$out"; \
  printf '> %s %s (%s): release assets into %s\n' "$(1)" "$$ver" "$$plat" "$(3)/release/$$ver"; \
  put() { if [ -f "$$1" ]; then an="$${2:-$$(basename "$$1")}"; cp "$$1" "$$out/$$an"; printf '  asset %s\n' "$$an"; else return 1; fi; }; \
  need() { put "$$@" || { printf 'error %s: %s not found (did the build make it?)\n' "$(1)" "$$1" >&2; exit 1; }; }; \
  opt() { put "$$@" || printf '  skip  %s (not built)\n' "$$(basename "$$1")"; }; \
  need_glob() { for f in $$1; do if [ -f "$$f" ]; then put "$$f" "$$2"; return 0; fi; done; printf 'error %s: no file matches %s (did the build make it?)\n' "$(1)" "$$1" >&2; exit 1; }; \
  opt_glob() { for f in $$1; do if [ -f "$$f" ]; then put "$$f" "$$2"; return 0; fi; done; printf '  skip  %s (not built)\n' "$$1"; }; \
  zipdir() { [ -d "$$1" ] || { printf 'error %s: %s not found\n' "$(1)" "$$1" >&2; exit 1; }; $(STD_RELEASE_ABS) zip --from "$$1" --to "$$out/$$2"; printf '  asset %s\n' "$$2"; };
std_rel_end = $(STD_RELEASE_ABS) sums --dir "$$out"
# For the kinds that build per platform (app-*): the sums file is SHA256SUMS-<platform>, so the next platform's job
# does not overwrite it. Every job adds its own files to the same GitHub Release.
std_rel_end_plat = $(STD_RELEASE_ABS) sums --dir "$$out" --platform "$$plat"

# The release workflow's release: gate (exit 3: another part's tag, nothing to do), assets, then the GitHub Release.
# The unlinked files (*.aab, *-mapping.txt) stay in the build folder; release.sh create names each one on its
# "unlinked:" line, and release.yml uploads them with actions/upload-artifact (retention 7 days).
# A kind with no assets helper (the 4th argument empty) makes a Release with the notes only.
std_github_release = set -euo pipefail; \
  ver=$$($(STD_RELEASE) version --part $(1) --kind $(2) --part-dir $(3)); \
  rc=0; $(STD_RELEASE) gate --part $(1) --version "$$ver" $(std_force) || rc=$$?; \
  if [ "$$rc" -eq 3 ]; then exit 0; elif [ "$$rc" -ne 0 ]; then exit "$$rc"; fi; \
  $(if $(4),$(MAKE) --no-print-directory $(1)-release-assets;) \
  $(STD_RELEASE) create --part $(1) --kind $(2) --project "$(PROJECT)" --version "$$ver" \
    $(if $(4),--dir "$(3)/release/$$ver",--notes-only) --part-dir $(3) --build-note-file "$(3)/release/$$ver.build-note"

# std_release part,kind,dir,assets-helper,pre-steps
define std_release
$(call std_verb,$(1),bump,release,Set the version with LEVEL=patch or minor or major or VERSION=x.y.z then move the CHANGELOG Unreleased notes under it and commit and tag $(1)-v<version> without pushing)
$(call std_extra,$(1),release-assets,release,Collect the release files into $(3)/release/<version> with SHA256SUMS and build first unless NOBUILD=1)
$(call std_verb,$(1),github-release,release,In the release workflow of a $(1)-v tag: release-assets then the GitHub Release (FORCE=1 from a Mac))
$(call std_extra,$(1),release-latest,release,Copy the files of the $(1) Release (VERSION=x.y.z or the current version) into the Release latest that holds every part)
.PHONY: $(1)-bump $(1)-release-assets $(1)-github-release $(1)-release-latest
$(1)-bump:
	@$$(STD_RELEASE) bump --part $(1) --kind $(2) --part-dir $(3) $$(STD_BUMP_ARGS)
$(1)-release-assets:
	@$(if $(4),set -euo pipefail; $$(if $$(NOBUILD),,$(if $(5),$$(MAKE) --no-print-directory $(addprefix $(1)-,$(5));)) $$(call $(4),$(1),$(3)),echo "$(1): no release files: its GitHub Release carries the CHANGELOG notes only")
$(1)-github-release:
	@$$(call std_github_release,$(1),$(2),$(3),$(4))
$(1)-release-latest:
	@set -euo pipefail; ver="$$(if $$(filter command line,$$(origin VERSION)),$$(VERSION))"; \
	  [ -n "$$$$ver" ] || ver=$$$$($$(STD_RELEASE) version --part $(1) --kind $(2) --part-dir $(3)); \
	  $$(STD_RELEASE) latest-sync --part $(1) --kind $(2) --project "$$(PROJECT)" --version "$$$$ver"
endef

# --- setup on demand ---------------------------------------------------------------------------
# A part's commands that need what its setup installs run that setup first when the part is not ready, so in a fresh
# clone `make cloud-logs ENV=production` installs the Worker's packages and then tails. A kind calls
#   $(call std_ready,part,dir,ready-helper,verbs)
# ready-helper is a helper called as $(call ready-helper,part,dir) when the recipe runs: shell text (`$$` for the shell)
# run in a subshell that exits 0 when the part is ready. It must be cheap and offline: files and their times, no network,
# no package manager. std_ready defines the internal target <part>-ready (not in help), which runs make <part>-setup
# when the test fails, and makes it a prerequisite of <part>-<verb> for each of verbs. The root verbs fan out to the
# part targets, so they chain too. Never chained: setup itself, doctor, clean, distclean, version, bump, and any setup
# that needs the user (secrets, CONFIRM, a probe, APPLY=1): such a kind calls no std_ready. CI runs <part>-setup
# first, after which the test passes and nothing more runs.
define std_ready
STD_READY += $(1)-ready
.PHONY: $(1)-ready
$(1)-ready:
	@if ( $$(call $(3),$(1),$(2)) ) >/dev/null 2>&1; then :; else printf '> %s: not set up yet, running make %s-setup first\n' "$(1)" "$(1)"; $$(MAKE) --no-print-directory $(1)-setup; fi
$(addprefix $(1)-,$(4)): $(1)-ready
endef

# $(call std_fresh,dir,stamps,inputs): exits 0 when one of the stamp files (paths in dir) exists and none of the input
# files is newer than it, else exits 1. A missing input does not count.
std_fresh = d="$(1)"; for s in $(2); do [ -f "$$d/$$s" ] || continue; fresh=1; \
  for i in $(3); do if [ "$$d/$$i" -nt "$$d/$$s" ]; then fresh=; fi; done; [ -z "$$fresh" ] || exit 0; done; exit 1
# A part with a package.json (cloud-worker, web-pages, app-tauri) is ready when node_modules was installed after the last
# change to package.json and its lockfile: the stamp its setup leaves (node_modules/.std-setup), or the one npm or pnpm
# writes itself (an install by hand counts too). No package.json: nothing to install, ready.
std_node_ready = [ -f "$(2)/package.json" ] || exit 0; \
  $(call std_fresh,$(2),node_modules/.std-setup node_modules/.package-lock.json node_modules/.modules.yaml,package.json package-lock.json pnpm-lock.yaml)
# The setup line of those parts, run in the part's folder: install, then leave the stamp.
STD_NODE_SETUP := { if [ -f package-lock.json ]; then npm ci; else pnpm install; fi; } && mkdir -p node_modules && touch node_modules/.std-setup

# --- help registration (root commands come first inside each group) -----------------------------

$(call std_h,setup,help,This list)
$(call std_h,setup,doctor,Check tools; pins; secrets and every part; print the fix for what is wrong)
$(call std_h,setup,setup,Install brew and mise tools; each part's dependencies; git hooks and git-lfs)
$(call std_h,setup,update,Bump the pinned SDKs and tools on purpose; then run setup)
$(call std_h,setup,hooks,Install the pre-commit hook: gitleaks; LFS check; large files over 5 MB)
$(call std_h,setup,teardown,Undo setup for this project: lists with sizes; CONFIRM=teardown removes its folders and record and the shared tools no other project records; Homebrew stays)
$(call std_h,setup,prune,Machine wide: lists with sizes; CONFIRM=prune removes shared tools and SDKs no project records; stale records; the pnpm store)
$(call std_h,dev,dev,Start the whole local stack (dev-<part> style: PART=<part>))
$(call std_h,dev,stop,Stop what dev started)
$(call std_h,dev,status,Show what is running and the state of local data)
$(call std_h,dev,logs,Follow the logs of the running parts)
$(call std_h,dev,reset,Wipe local state and re-migrate (needs CONFIRM=local))
$(call std_h,dev,build,Build every part)
$(call std_h,dev,clean,Remove build output)
$(call std_h,dev,distclean,Remove build output and project-local dependencies)
$(call std_h,test,check,The gate before every commit and in CI: format check; lint; types; unit tests)
$(call std_h,test,test,Unit tests (TEST=<pattern> for one))
$(call std_h,test,test-e2e,End-to-end tests against make dev)
$(call std_h,test,test-device,Flash the connected board and assert on its serial output)
$(call std_h,test,format,Rewrite formatting)
$(call std_h,cloudflare,cf-login,Verify the project API token and store it for staging and production (no ENV needed))
$(call std_h,cloudflare,cf-logout,Remove the token from staging and production and print where to revoke it)
$(call std_h,cloudflare,cf-whoami,Account; the token status and expiry; says when the staging and production copies differ)
$(call std_h,cloudflare,cf-token-check,Check the project token reaches every API its Workers and Pages sites and OTA bucket use (default: the production copy))
$(call std_h,cloudflare,cf-provision,Create the missing D1; KV; R2 and Queues (dead-letter queues too) and write ids back; and the OTA bucket)
$(call std_h,cloudflare,cf-status,Declared against existing resources; the OTA bucket and its r2.dev URL)
$(call std_h,cloudflare,cf-migrate,Apply D1 migrations)
$(call std_h,cloudflare,cf-migrate-list,List D1 migrations)
$(call std_h,cloudflare,cf-seed,Load seed data into local or staging (never production))
$(call std_h,cloudflare,cf-secrets,Push the cf secrets with wrangler secret bulk (ROTATE=NAME for one new value))
$(call std_h,cloudflare,cf-backup,Encrypted backup of D1 and of every KV key with its value into the Backups folder (R2: info only; Durable Objects: not backed up))
$(call std_h,cloudflare,cf-wipe,Back up; then delete the data and keep the resources (needs CONFIRM=<env>; R2 needs R2_UNBACKED=1))
$(call std_h,cloudflare,cf-destroy,Back up; then delete the resources of ENV (needs CONFIRM=<env>; R2 needs R2_UNBACKED=1))
$(call std_h,secrets,secrets-init,Create this project's secrets from secrets.schema (GEN=1 generates values))
$(call std_h,secrets,secrets-set,Set one value: NAME=<name> ENV=<env>; hidden prompt)
$(call std_h,secrets,secrets-import,Import a key file (NAME= FILE=) or a dotenv file (FILE= ENV=))
$(call std_h,secrets,secrets-edit,Edit the values of ENV=local or common in sops (staging and production: secrets-set))
$(call std_h,secrets,secrets-list,Names; environments and users; no values)
$(call std_h,secrets,secrets-check,Missing names; wrong recipients; tracked secret files; gitleaks)
$(call std_h,secrets,secrets-keygen,Generate a signing key into the secrets: NAME=<name> TYPE=<type>)
$(call std_h,secrets,secrets-rotate,New value for NAME= in ENV=; then push it with cf-secrets)
$(call std_h,secrets,secrets-ci,Create the CI key and store it as the GitHub Actions secret SOPS_AGE_KEY of the project repo)
$(call std_h,secrets,secrets-enroll,New Mac: clone the secrets repo and create this Mac's identities)
$(call std_h,secrets,secrets-recovery,Create the offline recovery key (shown once; FORCE=1 replaces it))
$(call std_h,secrets,secrets-add-machine,Let a new Mac decrypt: HOST=<host>)
$(call std_h,secrets,secrets-remove-machine,Revoke a Mac: HOST=<host>; lists the values to rotate)
$(call std_h,secrets,secrets-sync,Pull the secrets repo now)
$(call std_h,secrets,secrets-doctor,Check the secrets tools and identities)
$(call std_h,deploy,deploy,check; build; deploy the parts; smoke (production needs CONFIRM=production))
$(call std_h,deploy,smoke,Health and smoke tests against the deployed URLs)
$(call std_h,deploy,test-remote,Full deployed test suite (production needs CONFIRM=production))
$(call std_h,deploy,preview,Upload a version and smoke test its preview URL)
$(call std_h,deploy,promote,Deploy to production what passed on staging (needs CONFIRM=production))
$(call std_h,deploy,versions,List the deployed versions)
$(call std_h,deploy,rollback,Roll back to the previous version (production needs CONFIRM=production))
$(call std_h,ci,ci-lint,Lint the workflows in .github/workflows with actionlint)
$(call std_h,ci,ci-status,Pipeline status of the current branch)
$(call std_h,ci,ci-logs,Log of the failed job of the current branch)
$(call std_h,ci,ci-run,Start checks.yml on the current branch (it needs workflow_dispatch))
$(call std_h,ci,ci-local,Run one job of the CI workflow here in Docker with act: JOB=<job> (no JOB lists them))
$(call std_h,ci,ci-setup,Set up CI once: the CI age key and read-only deploy keys and the repo secrets and variables (prints no values))
$(call std_h,ci,ci-setup-help,Print the commands that set the CI secrets and deploy keys for you to run (no values))
$(call std_h,firmware,flash,Flash the one part that can (PART=<part> when there are several))
$(call std_h,firmware,erase,Erase the chip (needs CONFIRM=erase) )
$(call std_h,firmware,monitor,Serial console)
$(call std_h,firmware,debug,Open GDB through the probe)
$(call std_h,release,release,Publish the parts where they go (OTA store; app stores; image registry))
$(call std_h,release,version,Show each part's version)
$(call std_h,release,bump,Release one part: LEVEL=patch or minor or major (or VERSION=x.y.z) PART=<part>; commits and tags <part>-v<version>)
$(call std_h,release,latest,The newest published Release of each part (PART=<part> for one); GitHub marks only one Release Latest)
$(call std_h,release,release-push,Push the branch then each new release tag on its own (GitHub ignores the tags of a push with more than three))
$(call std_h,release,github-release,The GitHub Release of one part (its tag pipeline runs it; FORCE=1 PART=<part> from a Mac))

# --- kinds and parts ---------------------------------------------------------------------------

STD_KINDS := $(sort $(foreach p,$(PARTS),$(call std_kind,$(p))))
STD_PART_NAMES := $(foreach p,$(PARTS),$(call std_name,$(p)))
STD_PARTS_TXT := $(foreach p,$(PARTS),$(call std_name,$(p))($(call std_kind,$(p))))

$(foreach p,$(PARTS),$(if $(call std_kind,$(p)),,$(error PARTS entry '$(p)' must be name:kind[:dir])))
# A part's folder is a path inside the project: relative, no .. and no leading - or / (since v17). Recipes and make teardown
# remove things under it. (It need not exist yet: a new part's folder is made by its first command.)
std_dir_bad = $(or $(filter /% -%,$(1)),$(findstring /../,/$(1)/))
$(foreach p,$(PARTS),$(if $(call std_dir_bad,$(call std_dir,$(p))),$(error part $(call std_name,$(p)): its folder '$(call std_dir,$(p))' must be inside the project: relative, no .., no leading / or -)))
$(foreach k,$(STD_KINDS),$(if $(wildcard make/kinds/$(k).mk),,$(error part kind '$(k)' has no make/kinds/$(k).mk)))
ifneq ($(words $(STD_PART_NAMES)),$(words $(sort $(STD_PART_NAMES))))
$(error two parts in PARTS have the same name)
endif
ifneq ($(PART),)
ifeq ($(filter $(PART),$(STD_PART_NAMES)),)
$(error PART=$(PART) is not a part; the parts are: $(STD_PART_NAMES))
endif
endif

# The folders of a part that its distclean (or clean, for a kind without distclean) removes, per kind: what make teardown lists
# with their sizes (since v17). It mirrors the recipes in make/kinds/<kind>.mk, which do the removing.
STD_DIRS_app-android := .gradle app/build
STD_DIRS_app-flutter := .dart_tool build
STD_DIRS_app-tauri := node_modules dist dist-release dist-linux src-tauri/target
STD_DIRS_app-xcode := build
STD_DIRS_arm-gcc := build
STD_DIRS_circuitpython := build
STD_DIRS_cloud-worker := node_modules dist
STD_DIRS_espidf := build managed_components
STD_DIRS_go := bin dist
STD_DIRS_hardware := outputs
STD_DIRS_pio := .pio build .platformio
STD_DIRS_python := .venv dist build .pytest_cache .ruff_cache
STD_DIRS_web-pages := node_modules dist out .next
STD_DIRS_zephyr := build
# docker removes images, no folders
std_part_dirs = $(foreach d,$(STD_DIRS_$(call std_kind,$(1))) release $(if $(filter hardware,$(call std_kind,$(1))),production),$(call std_dir,$(1))/$(d))
# release/ (every part: make <part>-release-assets) and production/ (hardware: fab zips) are local copies of what each
# GitHub Release keeps; no distclean removes them, so teardown does, after the distcleans.
STD_TEARDOWN_RELEASE_DIRS = $(foreach p,$(PARTS),$(call std_dir,$(p))/release $(if $(filter hardware,$(call std_kind,$(p))),$(call std_dir,$(p))/production))
STD_TEARDOWN_DIRS = $(foreach p,$(PARTS),$(call std_part_dirs,$(p)))
std_teardown_clean_only = $(foreach p,$(STD_PART_NAMES),$(if $(filter $(p)-distclean,$(STD_VERB_distclean)),,$(filter $(p)-clean,$(STD_VERB_clean))))

include $(foreach k,$(STD_KINDS),make/kinds/$(k).mk)

$(foreach p,$(PARTS),$(if $(filter undefined,$(origin kind_$(call std_kind,$(p)))),$(error kind '$(call std_kind,$(p))' defines no template kind_$(call std_kind,$(p)))))
$(foreach p,$(PARTS),$(eval $(call kind_$(call std_kind,$(p)),$(call std_name,$(p)),$(call std_dir,$(p)))))

.PHONY: $(foreach v,$(STD_VERBS),$(STD_VERB_$(v)))

# --- root targets ------------------------------------------------------------------------------

# Which root entries `make help` lists: only those that do something in this project (`make help ALL=1` lists
# every one; the targets themselves always exist). The rule, table-driven:
#   STD_HELP_ALWAYS          always listed;
#   STD_HELP_NEED_<n>        listed when PARTS has one of the kinds in STD_HELP_KINDS_<n> (the cloud and res entries
#                            also when OTA_BUCKET or a <part>_OTA_BUCKET is set: the OTA uploads use the project token,
#                            cf-provision creates the bucket and cf-status checks it);
#   any other root verb      listed when a part has that verb (STD_VERB_<verb>: deploy, promote, flash, release...);
#   everything else          listed (secrets, ci, and every part's own entries).
STD_HELP_ALWAYS := help doctor setup update hooks build clean distclean check format
STD_HELP_NEEDS := cloud res worker
STD_HELP_NEED_cloud := cf-login cf-logout cf-whoami cf-token-check
STD_HELP_KINDS_cloud := cloud-worker web-pages
STD_HELP_NEED_res := cf-provision cf-status
STD_HELP_KINDS_res := cloud-worker
STD_HELP_NEED_worker := cf-migrate cf-migrate-list cf-seed cf-secrets cf-backup cf-wipe cf-destroy
STD_HELP_KINDS_worker := cloud-worker
std_help_need = $(firstword $(foreach n,$(STD_HELP_NEEDS),$(if $(filter $(1),$(STD_HELP_NEED_$(n))),$(n))))
# an OTA bucket set for the project or a part (the firmware and app kinds default <part>_OTA_BUCKET to OTA_BUCKET)
std_ota_any = $(strip $(OTA_BUCKET) $(foreach p,$(STD_PART_NAMES),$($(p)_OTA_BUCKET)))
std_help_kinds = $(filter $(STD_HELP_KINDS_$(1)),$(STD_KINDS))$(if $(filter cloud res,$(1)),$(std_ota_any))
std_help_show = $(or $(filter 1,$(ALL)),$(if $(filter $(1),$(STD_HELP_HIDE)),,$(or $(filter $(1),$(STD_HELP_ALWAYS)),$(if $(call std_help_need,$(1)),$(call std_help_kinds,$(call std_help_need,$(1))),$(if $(filter $(1),$(STD_VERBS)),$(filter-out $(STD_HELP_HIDE),$(STD_VERB_$(1))),x)))))

export STD_HELP_TXT
define STD_HELP_TXT
$(foreach h,$(STD_HELP),$(if $(call std_help_show,$(word 2,$(subst |, ,$(h)))),$(subst __SP__, ,$(h))$(newline)))
endef

.PHONY: help
help:
	@{ printf '%s\n' "$$STD_HELP_TXT"; $(STD_LIB); std_local_help make/local.mk; } | { $(STD_LIB); std_help_render "$(PROJECT)" "$(ENV)" "$(STD_PARTS_TXT)"; }

.PHONY: doctor
doctor:
	@rc=0; $(STD_LIB); doctor_project || rc=1; $(call std_fan,doctor,keep) || rc=1; $(STD_SECRETS) doctor --project "$(PROJECT)" || rc=1; exit $$rc

# setup writes this project's usage record (what it uses from the shared machine) and, for what it installs there, the
# ledger: see toolchain.sh and make teardown. The record only grows while a setup runs and is replaced by the new one in the
# last line, which a failed setup never reaches; a setup of one part (PART=) only adds.
.PHONY: setup
setup:
	@$(STD_LIB); \
	$(if $(PART),,$(STD_TC) record-begin; ) \
	if [ -f Brewfile ]; then if command -v brew >/dev/null 2>&1; then brew bundle --file=Brewfile; else log_warn "brew not found; skipped the Brewfile"; fi; fi; \
	if [ -f mise.toml ]; then if command -v mise >/dev/null 2>&1; then $(STD_TC) mise-install; else log_warn "mise not found; skipped mise.toml"; fi; fi
	@$(call std_fan,setup)
	@$(STD_LIB); \
	if git rev-parse --git-dir >/dev/null 2>&1; then \
	  $(MAKE) --no-print-directory hooks; \
	  if command -v git-lfs >/dev/null 2>&1; then git lfs install --local >/dev/null; else log_warn "git-lfs not found (brew install git-lfs)"; fi; \
	fi
	@$(if $(PART),true,$(STD_TC) record-commit)

.PHONY: update
update:
	@$(call std_fan,update)
	@$(MAKE) --no-print-directory setup

.PHONY: hooks
hooks:
	@bash $(STD_BIN)/lib.sh install-hook

# teardown and prune only list what they would remove, with sizes. Removing needs CONFIRM=teardown or CONFIRM=prune on the
# command line. They remove what the standard installed (the ledger) and no project records any more, never a Homebrew
# package. std-teardown-clean is the project's part of teardown: every part's distclean, and clean where a kind has no
# distclean. It is not a command: teardown runs it.
.PHONY: teardown prune std-teardown-clean
teardown:
	@$(if $(CONFIRM),$(call std_confirm,teardown) && )$(STD_TC) teardown $(if $(CONFIRM),--remove )--dirs "$(STD_TEARDOWN_DIRS)" --brewfile Brewfile --clean-cmd '$(MAKE) --no-print-directory std-teardown-clean'
prune:
	@$(if $(CONFIRM),$(call std_confirm,prune) && )$(STD_TC) prune $(if $(CONFIRM),--remove)
std-teardown-clean:
	@rc=0; $(if $(STD_VERB_distclean),$(call std_fan,distclean,keep) || rc=1;) for t in $(std_teardown_clean_only); do $(MAKE) --no-print-directory $$t || rc=1; done; for d in $(STD_TEARDOWN_RELEASE_DIRS); do rm -rf "$(CURDIR)/$$d" || rc=1; done; exit $$rc

.PHONY: dev stop status logs
dev:
	@$(call std_fan,dev)
stop:
	@$(call std_fan,stop,keep)
status:
	@$(call std_fan,status,keep)
logs:
	@$(call std_fan,logs)

.PHONY: reset
reset:
	@$(call std_confirm,local) && { $(if $(filter-out local,$(ENV)),$(call std_refuse,reset only works on ENV=local),true); } && { $(call std_fan,reset); }

.PHONY: build clean distclean
build:
	@$(call std_fan,build)
clean:
	@$(call std_fan,clean)
distclean:
	@$(call std_fan,distclean)

.PHONY: check test test-e2e test-device format
check:
	@$(call std_fan,check)
test:
	@$(call std_fan,test)
test-e2e:
	@$(call std_fan,test-e2e)
test-device:
	@$(call std_fan,test-device)
format:
	@$(call std_fan,format)

.PHONY: deploy smoke test-remote preview promote versions rollback
deploy:
	@$(call std_production_guard) && $(MAKE) --no-print-directory check && $(MAKE) --no-print-directory build && { $(call std_fan,deploy); } && $(MAKE) --no-print-directory smoke
smoke:
	@$(call std_fan,smoke)
test-remote:
	@$(call std_production_guard) && { $(call std_fan,test-remote); }
preview:
	@$(call std_production_guard) && { $(call std_fan,preview); }
promote:
	@$(call std_confirm,production) && { $(call std_fan,promote,,ENV=production); }
versions:
	@$(call std_fan,versions)
rollback:
	@$(call std_production_guard) && { $(call std_fan,rollback); }

.PHONY: release version bump github-release release-push latest
release:
	@$(call std_fan,release)
version:
	@$(call std_fan,version)
# A release belongs to one part: bump and github-release run for PART= (or the only part that has them).
bump:
	@$(call std_single,bump)
github-release:
	@$(call std_single,github-release)
release-push:
	@$(STD_RELEASE) push
latest:
	@$(STD_RELEASE) latest $(if $(PART),--part $(PART))

.PHONY: flash erase monitor debug
flash:
	@$(call std_single,flash)
erase:
	@$(call std_confirm,erase) && { $(call std_single,erase); }
monitor:
	@$(call std_single,monitor)
debug:
	@$(call std_single,debug)

# Cloudflare (cf.sh runs under the secrets for ENV; one call per cloud-worker part)
.PHONY: cf-login cf-logout cf-whoami cf-token-check cf-provision cf-status cf-migrate cf-migrate-list
.PHONY: cf-seed cf-secrets cf-backup cf-wipe cf-destroy
# One token per project: login and logout act on the staging and the production copy whatever ENV is.
cf-login:
	@$(call std_production_guard) && $(STD_CF) login --project "$(PROJECT)"
cf-logout:
	@$(call std_production_guard) && $(STD_CF) logout --project "$(PROJECT)"
cf-whoami:
	@$(STD_CF) whoami --project "$(PROJECT)"
cf-token-check:
	@$(STD_CF) token-check --project "$(PROJECT)" --env "$(ENV)"
# The cf commands that run each Worker's own wrangler set up the parts that are not ready first (std_ready).
$(addprefix cf-,provision status migrate migrate-list seed secrets backup wipe destroy): $(filter $(STD_READY),$(foreach p,$(PARTS),$(if $(and $(filter cloud-worker,$(call std_kind,$(p))),$(if $(PART),$(filter $(PART),$(call std_name,$(p))),x)),$(call std_name,$(p))-ready)))
cf-provision:
	@$(call std_production_guard) && { $(call std_cf_parts,provision); } && $(call std_cf_ota,provision-ota)
cf-status:
	@rc=0; ( $(call std_cf_parts,status) ) || rc=1; $(call std_cf_ota,status-ota) || rc=1; exit $$rc
cf-migrate:
	@$(call std_production_guard) && $(call std_cf_each,migrate)
cf-migrate-list:
	@$(call std_cf_each,migrate,--list)
cf-seed:
	@$(call std_production_guard) && $(call std_cf_each,seed)
cf-secrets:
	@$(call std_production_guard) && $(call std_cf_each,secrets,$(if $(ROTATE),--rotate "$$ROTATE"))
cf-backup:
	@$(call std_cf_each,backup)
cf-wipe:
	@$(call std_confirm,$(ENV)) && $(call std_cf_each,wipe,$(STD_R2_FLAG))
cf-destroy:
	@$(call std_confirm,$(ENV)) && $(call std_cf_each,destroy,$(STD_R2_FLAG))

# Secrets (secrets.sh; values never go through make)
.PHONY: secrets-init secrets-set secrets-import secrets-edit secrets-list secrets-check secrets-keygen secrets-rotate
.PHONY: secrets-ci secrets-enroll secrets-recovery secrets-add-machine secrets-remove-machine secrets-sync secrets-doctor
secrets-init:
	@$(STD_SECRETS) init --project "$(PROJECT)" $(if $(GEN),--gen)
secrets-set:
	@$(call std_production_guard) && $(call std_need,NAME) && $(STD_SECRETS) set "$$NAME" --project "$(PROJECT)" --env "$(ENV)"
secrets-import:
	@$(call std_production_guard) && $(call std_need,FILE) && $(if $(filter command line,$(origin ENV)),$(STD_SECRETS) import --file "$$FILE" --project "$(PROJECT)" --env "$(ENV)" $(if $(FORCE),--force),$(call std_need,NAME) && $(STD_SECRETS) import "$$NAME" --file "$$FILE" --project "$(PROJECT)" $(if $(FORCE),--force))
secrets-edit:
	@$(call std_production_guard) && $(STD_SECRETS) edit --project "$(PROJECT)" --env "$(ENV)"
secrets-list:
	@$(STD_SECRETS) list --project "$(PROJECT)"
secrets-check:
	@$(STD_SECRETS) check --project "$(PROJECT)"
secrets-keygen:
	@$(call std_need,NAME)
	@$(STD_SECRETS) keygen "$$NAME" --project "$(PROJECT)" $(if $(TYPE),--type "$$TYPE")
secrets-rotate:
	@$(call std_production_guard) && $(call std_need,NAME) && $(STD_SECRETS) rotate "$$NAME" --project "$(PROJECT)" --env "$(ENV)"
secrets-ci:
	@$(STD_SECRETS) ci --project "$(PROJECT)"
secrets-enroll:
	@$(STD_SECRETS) enroll
secrets-recovery:
	@$(STD_SECRETS) recovery $(if $(filter 1,$(FORCE)),--force)
secrets-add-machine:
	@$(call std_need,HOST)
	@$(STD_SECRETS) add-machine "$$HOST" --project "$(PROJECT)"
secrets-remove-machine:
	@$(call std_need,HOST)
	@$(STD_SECRETS) remove-machine "$$HOST" --project "$(PROJECT)"
secrets-sync:
	@$(STD_SECRETS) sync
secrets-doctor:
	@$(STD_SECRETS) doctor --project "$(PROJECT)"

# GitHub Actions (gh; actionlint lints the workflows; act runs one job here)
.PHONY: ci-lint ci-status ci-logs ci-run ci-local ci-setup ci-setup-help
STD_NEED_GH := command -v gh >/dev/null 2>&1 || { $(STD_LIB); log_err "gh not found (brew install gh, then gh auth login)"; exit 1; }
STD_NEED_ACTIONLINT := command -v actionlint >/dev/null 2>&1 || { $(STD_LIB); log_err "actionlint not found (brew install actionlint)"; exit 1; }
ci-lint:
	@$(STD_NEED_ACTIONLINT); actionlint
ci-status:
	@$(STD_NEED_GH); gh run list --branch "$$(git branch --show-current)" --limit 5
ci-logs:
	@$(STD_NEED_GH); b="$$(git branch --show-current)"; \
	id=$$(gh run list --branch "$$b" --status failure --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true); \
	if [ -n "$$id" ]; then gh run view "$$id" --log-failed; else \
	  id=$$(gh run list --branch "$$b" --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true); \
	  [ -n "$$id" ] || { echo "no workflow run on GitHub for $$b" >&2; exit 1; }; \
	  gh run view "$$id" --log; fi
ci-run:
	@$(STD_NEED_GH); gh workflow run checks.yml --ref "$$(git branch --show-current)"

# Everything CI needs, in one run you start: the CI age key (secrets-ci), a read-only deploy key for the secrets repo
# (the project's, SECRETS_REMOTE, whose owner/name is also the variable SECRETS_REPO)
# and, with a hardware part, for the KiCad library (made in ~/.ssh when missing, added to the repo when not there yet,
# its private half stored as the repo secret), and the repository variables. Safe to run again: what exists is kept,
# the secrets and variables are set again. It prints no values. The GitHub repository must exist first. The reusable
# workflows' repository (CI_TEMPLATES_REPO) is public and needs no setting; it warns only when that repo is private.
ci-setup:
	@$(STD_NEED_GH); $(STD_LIB); owner="$(GITHUB_OWNER)"; \
	[ -n "$$owner" ] || die "GITHUB_OWNER is not set: add the GitHub remote origin (git remote add origin https://github.com/<owner>/$(PROJECT).git), or put GITHUB_OWNER := <your GitHub account> in $(STD_CONFIG)/config.mk"; \
	repo="$$owner/$(PROJECT)"; \
	gh repo view "$$repo" >/dev/null 2>&1 || die "no GitHub repository $$repo: create it first (gh repo create $$repo --private --description \"...\")"; \
	command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"; \
	$(MAKE) --no-print-directory secrets-ci || exit 1; \
	mkdir -p "$$HOME/.ssh" && chmod 700 "$$HOME/.ssh"; \
	deploy_key() { \
	  f="$$HOME/.ssh/$(PROJECT)-ci-$$1"; \
	  if [ -f "$$f" ]; then log_info "deploy key $$f exists"; \
	  else ssh-keygen -q -t ed25519 -N '' -C "$(PROJECT)-ci-$$1" -f "$$f" || die "ssh-keygen failed"; log_ok "created $$f"; fi; \
	  pub="$$(cut -d' ' -f1,2 "$$f.pub")"; \
	  if gh repo deploy-key list --repo "$$2" --json key -q '.[].key' 2>/dev/null | grep -qxF "$$pub"; then log_info "its public key is already a deploy key of $$2"; \
	  else gh repo deploy-key add "$$f.pub" --repo "$$2" --title "$(PROJECT)-ci-read-only" >/dev/null || die "could not add the deploy key to $$2"; \
	    log_ok "read-only deploy key added to $$2"; fi; \
	  gh secret set "$$3" --repo "$$repo" <"$$f" || die "could not set the secret $$3 of $$repo"; \
	  log_ok "secret $$3 of $$repo set"; \
	}; \
	srepo="$$(github_repo_slug "$(SECRETS_REMOTE)")"; \
	[ -n "$$srepo" ] || die "SECRETS_REMOTE '$(SECRETS_REMOTE)' is not a GitHub repository: the CI jobs clone the secrets repo from GitHub"; \
	deploy_key secrets "$$srepo" SECRETS_DEPLOY_KEY; \
	gh variable set SECRETS_REPO --repo "$$repo" --body "$$srepo" && log_ok "variable SECRETS_REPO of $$repo set ($$srepo)"; \
	if echo " $(STD_KINDS) " | grep -q ' hardware '; then \
	  deploy_key kicad "$$owner/kicad-library" KICAD_LIBRARY_DEPLOY_KEY; \
	  gh variable set KICAD_LIBRARY_REPO --repo "$$repo" --body "$$owner/kicad-library" && log_ok "variable KICAD_LIBRARY_REPO of $$repo set"; \
	fi; \
	vis=$$(gh repo view "$(CI_TEMPLATES_REPO)" --json visibility -q .visibility 2>/dev/null || true); \
	case "$$vis" in PRIVATE | INTERNAL) log_warn "CI_TEMPLATES_REPO $(CI_TEMPLATES_REPO) is not public: on it, Settings > Actions > General > Access must allow the repositories of $$owner";; esac; \
	log_ok "CI for $$repo is set up: make ci-run starts the checks"

# The commands make ci-setup runs, printed for you to run by hand instead. They print no values; the keys stay
# in ~/.ssh and in the GitHub secrets. GITHUB_OWNER is the project's (its origin); the secrets repo is SECRETS_REMOTE.
ci-setup-help:
	@$(STD_LIB); owner="$(GITHUB_OWNER)"; \
	if [ -z "$$owner" ]; then log_warn "GITHUB_OWNER is not set: add the GitHub remote origin, or put GITHUB_OWNER := <your GitHub account> in $(STD_CONFIG)/config.mk, then run this again"; owner='<owner>'; fi; \
	srepo="$$(github_repo_slug "$(SECRETS_REMOTE)")"; [ -n "$$srepo" ] || srepo="$$owner/secrets"; \
	printf '%s\n' "# CI setup for $(PROJECT). Run these yourself, in this order." ""; \
	printf '%s\n' "# 1. the age key the CI jobs decrypt with: stored as the secret SOPS_AGE_KEY of $$owner/$(PROJECT)" \
	  "make secrets-ci" ""; \
	printf '%s\n' "# 2. a read-only deploy key for the secrets repo (the CI jobs clone it with it)" \
	  "ssh-keygen -t ed25519 -N '' -C $(PROJECT)-ci-secrets -f ~/.ssh/$(PROJECT)-ci-secrets" \
	  "gh repo deploy-key add ~/.ssh/$(PROJECT)-ci-secrets.pub --repo $$srepo --title $(PROJECT)-ci-read-only" \
	  "gh secret set SECRETS_DEPLOY_KEY --repo $$owner/$(PROJECT) < ~/.ssh/$(PROJECT)-ci-secrets" ""; \
	if echo " $(STD_KINDS) " | grep -q ' hardware '; then \
	  printf '%s\n' "# 3. the same for the shared KiCad library (the hardware jobs clone it; it is a private repo)" \
	    "ssh-keygen -t ed25519 -N '' -C $(PROJECT)-ci-kicad -f ~/.ssh/$(PROJECT)-ci-kicad" \
	    "gh repo deploy-key add ~/.ssh/$(PROJECT)-ci-kicad.pub --repo $$owner/kicad-library --title $(PROJECT)-ci-read-only" \
	    "gh secret set KICAD_LIBRARY_DEPLOY_KEY --repo $$owner/$(PROJECT) < ~/.ssh/$(PROJECT)-ci-kicad" ""; \
	fi; \
	printf '%s\n' "# 4. repository variables (names, not secrets) the workflows read" \
	  "gh variable set SECRETS_REPO --repo $$owner/$(PROJECT) --body $$srepo"; \
	if echo " $(STD_KINDS) " | grep -q ' hardware '; then \
	  printf '%s\n' "gh variable set KICAD_LIBRARY_REPO --repo $$owner/$(PROJECT) --body $$owner/kicad-library"; \
	fi; \
	if [ "$(CI_TEMPLATES_REPO)" != mayankgautam-me/ci-templates ]; then \
	  printf '%s\n' "" "# Only if CI_TEMPLATES_REPO ($(CI_TEMPLATES_REPO)) is private: on it, Settings > Actions > General > Access" \
	    "# must allow the repositories of $$owner (the public default needs nothing)"; \
	fi; \
	printf '%s\n' "" "# Then check the workflows: make ci-lint, and one job here: make ci-local JOB=<job>"

# One job of .github/workflows/$(CI_LOCAL_WORKFLOW) on this machine, in Docker, with act. Jobs run as linux/amd64
# (CI_LOCAL_PLATFORM), like GitHub's hosted Linux runners: some images (kicad/kicad) have no arm64 build, and on Apple
# Silicon Docker emulates amd64. CI_LOCAL_PLATFORM= (empty) uses the machine's own. act fetches the reusable workflows
# from CI_TEMPLATES_REPO (public: no token needed; GITHUB_TOKEN in the environment only when it is private, and for
# jobs that call the GitHub API), and the job's secrets from .secrets in the project
# root (in .gitignore: it can hold secrets). JOB unset lists the jobs.
CI_LOCAL_PLATFORM ?= linux/amd64
CI_LOCAL_WORKFLOW ?= checks.yml
ci-local:
	@$(STD_LIB); \
	command -v act >/dev/null 2>&1 || die "act not found (brew install act, or make setup)"; \
	command -v docker >/dev/null 2>&1 || die "docker not found: make ci-local runs the job in a container (Docker Desktop or colima)"; \
	docker info >/dev/null 2>&1 || die "the Docker daemon is not running: start Docker Desktop (or colima start)"; \
	[ "$$(git rev-parse --git-dir 2>/dev/null)" = "$$(git rev-parse --git-common-dir 2>/dev/null)" ] || die "this is a git worktree: its .git points outside the folder, so git inside the job's container fails; run make ci-local from a normal clone"; \
	wf=".github/workflows/$(CI_LOCAL_WORKFLOW)"; \
	[ -f "$$wf" ] || die "no $$wf (CI_LOCAL_WORKFLOW names the workflow file)"; \
	arch=''; if [ -n "$(CI_LOCAL_PLATFORM)" ]; then arch="--container-architecture $(CI_LOCAL_PLATFORM)"; fi; \
	if [ -z "$$JOB" ]; then act -W "$$wf" $$arch -l; log_info "run one with make ci-local JOB=<job>"; exit 0; fi; \
	act -W "$$wf" $$arch -j "$$JOB"

# The project's own targets come last, so they can add to or replace the above.
-include make/local.mk
