# project-standard v1.4: internal contract

How the pieces of the skill fit together. `standard.md` is the user-facing spec; this file is for
whoever writes or changes `common.mk`, a kind, a script, the CI templates, `scaffold.sh` or `audit.sh`.

## Constraints

- **GNU make 3.81** (the macOS default) must work, and so must make 4.x in CI images. So: no `.ONESHELL`,
  `.SHELLFLAGS`, `$(file ...)`, `.RECIPEPREFIX`, `undefine`, `!=`, or `::=`. `define` + `$(eval $(call ...))`
  is fine. `SHELL := /bin/bash`; recipes that need strict mode start with `set -euo pipefail;`.
- Every shell script is bash 3.2 compatible (macOS `/bin/bash`), `set -euo pipefail`, shellcheck clean
  (`shellcheck -x`), follows `shell-scripting:bash-defensive-patterns`. No GNU-only flags (`sed -i ''`
  vs `sed -i`: avoid in-place sed; use a temp file and `mv`).
- Nothing personal in any file: no home paths (use `$(HOME)` / `$HOME`), no remote addresses, no keys.
  Personal values come from `~/.config/project-standard/config.mk` (see below).
- Plain coloured output, Tokyo Night truecolour, no boxes. Colour only when stdout is a TTY and
  `NO_COLOR` is unset.

## Files in a project

```
Makefile                 managed: 3 lines, see below
make/project.mk          the project's own: PROJECT, PARTS, PORT_BASE, per-part overrides
make/common.mk           managed
make/kinds/<kind>.mk     managed: one per kind used by PARTS
make/bin/secrets.sh      managed: secrets engine (also used by CI)
make/bin/cf.sh           managed: Cloudflare engine
make/bin/lib.sh          managed: shared shell helpers (colours, die, confirm, log)
make/bin/release.sh      managed: versions, release notes and GitHub Releases
make/bin/toolchain.sh    managed: usage record, installed ledger, make teardown and make prune (since v17)
make/bin/ghcr.sh         managed: the docker kind's ghcr.io login, write:packages check and prune-images (1.1)
make/bin/secret-patterns.sh, sign-windows.sh   managed: the secret file patterns; the Tauri Windows signing helper
make/local.mk            the project's own targets, documented with `## ` comments
make/VERSION             the standard version the managed files came from: `1.3`
```

Besides these, `scaffold.sh` writes the project-owned files once (kept with `--force`): `README.md`, `CLAUDE.md`,
`PLAN.md`, `.gitattributes`, `Brewfile`, `mise.toml`, `secrets.schema`, `.github/workflows/checks.yml` and `release.yml`, and `.gitignore`
(`templates/project/.gitignore` + `kind_ignore` per kind + `<dir>/production/` per hardware or altium
part + `<dir>/outputs/` per altium part + `<dir>/release/` per part). An existing `.gitignore` gets the missing required
lines appended (`gitignore_required`: `.ci/`, the ci-local ones, the per-part lines, and Altium's own
lines with an altium part); a new or existing `.gitattributes` gets the missing lines of the kinds appended
(`gitattributes_required`: `*.wrl` with a hardware part, `*.FCStd` with a mechanical part, `templates/altium/gitattributes`
with an altium part: its binaries in LFS, lockable, and `*.PrjPcb -text`, `*.OutJob -text`), matched by pattern, never
removed or reordered. The template has no `*.wrl` line (1.2): only KiCad boards have VRML models. Each part README has a Release section (bump, push the tag, what the tag pipeline publishes). It places
`tests/smoke/README.md` and `tests/remote/README.md` only when a part's kind has `smoke` / `test-remote`
(cloud-worker, web-pages). Nothing in common.mk, the kinds or `audit.sh` needs a root `tests/`.

Documents are project-owned too, and each is written only when it does not exist (also in a part folder that
exists, where no starter code is written): `docs/README.md`, `docs/architecture.md`, `docs/operations.md` (only
when a part is cloud-worker, web-pages or docker), `docs/references.md` (always: `##` headings and a hint, the links
`- [Title (MPN) — Vendor](URL)` added by hand; since 1.2 nothing reads or downloads them), and per part `<dir>/README.md`, `<dir>/CHANGELOG.md` and
`docs/<part>/<doc>.md` for the kind's docs (`kind_docs` in `scaffold.sh`; `audit.sh` has the same table and checks
it). The CHANGELOG format is fixed, because the release targets read it: Keep a Changelog 1.1.0, `## [Unreleased]`
then `### Added`, `### Changed`, `### Fixed`, version sections `## [<version>] - YYYY-MM-DD`, tags `<part>-v<version>`.
Binary documents (`*.pdf *.doc *.docx *.xls *.xlsx *.ppt *.pptx *.odt *.ods *.odp`) are in the `.gitignore` template
and in no `.gitattributes` LFS line.

Every managed file's first line is exactly:

```
# project-standard v1.4 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
```

(`#!/usr/bin/env bash` first, then that line, for scripts.) `audit.sh` and the hook look for
`project-standard v<version>` on line 1 or 2 of `make/common.mk`.

Root `Makefile`:

```make
# project-standard v1.4 (managed: ...)
include make/project.mk
include make/common.mk
```

`common.mk` includes the kinds, evaluates the parts, then defines the root targets, then
`-include make/local.mk` last.

## project.mk

```make
# = folder in the secrets repo, CI variables, image names
PROJECT   := cryptogaurd
# dev ports are PORT_BASE + offset per part
PORT_BASE := 8100
# PARTS: name:kind[:dir]   dir defaults to name
PARTS := \
  firmware:zephyr \
  firmware-interface:arm-gcc \
  hardware:hardware \
  cloud-api:cloud-worker:cloud/api \
  cloud-web:web-pages:cloud/web
# per-part settings: <part>_<VAR>
firmware_BOARD := nrf9151dk/nrf9151/ns
firmware_NCS   := v3.2.1
```

Every comment is a line of its own, above the assignment it describes: make keeps the spaces before a trailing `#` in
the value (`X := a   # note` sets X to `a   `), and a commented-out `# X := a   # note` gets the same bug once it is
uncommented. `kind_settings` in `scaffold.sh` writes no `:=` line with a trailing comment, commented or not (1.2;
`tests/lint.bats` checks every line the scaffold writes into `make/project.mk` and `make/local.mk`). `audit.sh` runs the
same check on a project's own `make/project.mk` and `make/local.mk` (1.3, area `make`, fix "put the comment on its own
line above"): keep the two awk programs alike.

## Part evaluation (common.mk)

```make
STD_KINDS := $(sort $(foreach p,$(PARTS),$(word 2,$(subst :, ,$(p)))))
include $(foreach k,$(STD_KINDS),make/kinds/$(k).mk)
std_name = $(word 1,$(subst :, ,$(1)))
std_kind = $(word 2,$(subst :, ,$(1)))
std_dir  = $(or $(word 3,$(subst :, ,$(1))),$(word 1,$(subst :, ,$(1))))
$(foreach p,$(PARTS),$(eval $(call kind_$(call std_kind,$(p)),$(call std_name,$(p)),$(call std_dir,$(p)))))
```

(`$(or)` exists in 3.81.) Kind names use `-` (`cloud-worker`); the template macro is
`kind_cloud-worker`: make allows `-` in variable names.

## A kind file

Each `make/kinds/<kind>.mk` defines one template `kind_<kind>` with `$(1)` = part name, `$(2)` = dir.
Inside a `define`, `$$` escapes what must expand at recipe time. Pattern:

```make
define kind_zephyr
$(1)_BOARD ?= $$(BOARD)
$(1)_NCS   ?= v3.2.1
$(call std_verb,$(1),build,firmware,Build for $$($(1)_BOARD) into $(2)/build)
$(1)-build:
	@cd $(2) && $(STD_TOOLCHAINS)/ncs-$$($(1)_NCS)/... west build ...
endef
```

`std_verb` (defined in common.mk) takes `part,verb,group,description` and does two things:

1. appends `<part>-<verb>` to `STD_VERB_<verb>` (the root `make <verb>` runs all of them, in PARTS order);
2. appends `group|<part>-<verb>|description` to `STD_HELP`.

Extras (not one of the fixed verbs) use `std_extra` (`part,target-suffix,group,description`): help
only, no fan-out. Kinds must only use these fixed verbs for fan-out:

```
doctor setup update dev stop status logs reset check test test-e2e test-device format build
deploy smoke test-remote preview promote versions rollback release version clean distclean
flash erase monitor debug
```

`teardown` and `prune` are root targets only, not verbs: no kind defines them. `teardown` runs the hidden
`std-teardown-clean` (every part's `distclean`, then `clean` for the parts whose kind has no `distclean`) and lists the
folders in `STD_DIRS_<kind>` (a table in common.mk of what each kind's `distclean` or `clean` removes: a new kind or a changed
recipe needs its row changed too). Both ask `toolchain.sh` (below) and remove only with `CONFIRM=teardown` / `CONFIRM=prune`.

The kinds, by group (folder): firmware `zephyr espidf pio arm-gcc circuitpython silabs`; hardware `hardware altium`;
mechanical `mechanical`; cloud `cloud-worker docker go python`; web `web-pages`; app `app-flutter app-tauri app-xcode
app-android`. A new kind touches: `templates/make/kinds/<kind>.mk`, `ci-templates/.github/workflows/<kind>.yml`, `KINDS`
and the kind tables of `scaffold.sh` (`kind_group`, `kind_tech`, `kind_brew`, `kind_ignore`, `kind_settings`,
`kind_tasks`, `kind_docs`, `kind_runs_on`, the README sections, the CI cases) and of `audit.sh` (`KINDS`, `kind_docs`,
`part_group_at`), `STD_DIRS_<kind>` in common.mk, the version-source cases of `release.sh`, and `KINDS` in
`tests/ci.bats`. altium's `STD_DIRS` is only `.venv` (the Altium library's tools, 1.4) and teardown skips its `clean`:
its `outputs/` come only from Altium on Windows.

Root targets for the firmware verbs (`flash`, `monitor`, ...) only run when exactly one part has the
verb; with several they list the part targets and exit 2. Likewise a part's targets that talk to a board run
for one build configuration: in pio, flash, erase, monitor, debug and provision start with `pio_one_env`
(on the line of the action, like a guard), which refuses when `default_envs` selects several envs.

Help groups, in this order: `setup`, `dev`, `test`, `cloudflare`, `secrets`, `deploy`, `ci`,
`firmware`, `hardware`, `app`, `release`, `project` (local.mk). A part's targets go in its group by
kind (zephyr → firmware, cloud-worker → deploy and cloudflare, app-* → app, docker/go/python → dev...).

## toolchain.sh (since v17)

`STD_TC` in common.mk is `STD_PROJECT_DIR=<root> bash <root>/make/bin/toolchain.sh`, absolute so a recipe can call it from
inside a part's folder. Subcommands: `record-begin` and `record-commit` (a full `make setup` starts with the first and ends with the last: the
record only grows in between, the new one is built in `<record>.next` and swapped in at the end), `mise-install` (what root
`setup` runs instead of `mise install`: record the project's installed tools before and after, ledger the new versions that
this project's `mise.toml` asks for; needs `jq`), `sdk-begin DIR...` (before an install into a folder directly under
`STD_TOOLCHAINS`: record the physical path, ledger it when it does not exist yet), `sdk-use DIR...` (record the ones that
exist), `rustup-add TARGET...` (add on the active toolchain, ledger the missing ones, record all with the toolchain), and
`teardown` / `prune` (list; with `--remove` remove, which needs `CONFIRM=teardown` / `CONFIRM=prune` in its environment; the
script is internal and that is its only guard). A kind that installs into `STD_TOOLCHAINS` calls `sdk-begin` before and
`sdk-use` after (zephyr, espidf), one that adds a rustup target calls `rustup-add` (app-tauri); each call ends `|| true`, a
recording failure never fails a setup. State and formats: `reference/standard.md` 4.1. Bash 3.2; sizes come from `du -sk`.

A part's folder (`name:kind:dir`) must be relative, without `..`, and not start with `/` or `-`: common.mk stops with an
error otherwise, for every verb, because recipes and `teardown` remove things under it. Recipes quote their removals.

## Variables (common.mk)

| Var | Default | Meaning |
|---|---|---|
| `ENV` | `local` | `local`, `staging`, `production`; anything else is a parse-time `$(error)` |
| `CONFIRM` | empty | must equal the env being touched, and come from the command line (`$(origin CONFIRM)` = `command line`) |
| `PART` | empty | restrict a root verb to one part |
| `STD_TOOLCHAINS` | `$(HOME)/.toolchains` | shared SDKs: `<tool>-<version>` |
| `GITHUB_OWNER` | the project's owner | `GITHUB_REPOSITORY_OWNER` (or `GITHUB_REPOSITORY`'s owner) in CI, else the owner of the github.com `origin` (one `git remote get-url origin` per make run, only when the project root holds `.git`; exported as `STD_ORIGIN_OWNER` to sub-makes), else config.mk's; `STD_OWNER_FROM` = `ci`, `origin`, `config` or `command line` |
| `SECRETS_REMOTE` | `https://github.com/<GITHUB_OWNER>/secrets.git` | the project's secrets repo; config.mk's value only for config.mk's own owner |
| `SECRETS_DIR` | `$(HOME)/.secrets-<GITHUB_OWNER>` for every owner; with no owner at all config.mk's `SECRETS_DIR`, else `$(HOME)/.secrets` | the secrets repo checkout; a pre-1.8 `~/.secrets` of config.mk's owner is reported with the `mv` and `core.hooksPath` commands (standard.md 5.4), never moved |
| `SECRETS_DEFAULT_DIR` | `$(HOME)/.secrets-<config.mk's GITHUB_OWNER>` | where a new secrets repo first copies the Macs' and the recovery recipients from; then any other `~/.secrets-*` |
| `STD_CONFIG` | `$(HOME)/.config/project-standard` | per-user config dir |
| `STD_BIN` | `make/bin` | managed scripts |
| `STD_ORIGIN_REPO` | the repository name of the github.com `origin` (without `.git`) | read by the same `git remote get-url origin` as `STD_ORIGIN_OWNER`, exported with it; the docker kind's OCI source label outside CI |
| `DOCKER_REGISTRY` | `ghcr.io/<GITHUB_OWNER, lowercase>` | `make/project.mk` or the environment, else config.mk's only when the project's owner is config.mk's `GITHUB_OWNER`, else the owner's ghcr.io; `STD_DOCKER_REGISTRY_FROM` = `make/project.mk`, `environment`, `command line`, `config` or `owner` (exported, so a sub-make keeps the parent's word) |
| `KICAD_LIBRARY_PROJECT` | `<GITHUB_OWNER>/kicad-library` | owner/name of the shared KiCad library: `make/project.mk`, else config.mk or the environment, else the default; `STD_KICAD_LIBRARY_PROJECT_FROM` says which. `ci-setup` adds the KiCad deploy key there and sets `KICAD_LIBRARY_REPO` from it, only when a hardware part uses the shared library (`std_hw_shared_lib`: not `<part>_LIBRARY := local`) |
| `ALTIUM_LIBRARY_PROJECT` | `<GITHUB_OWNER>/altium-library` | owner/name of the shared Altium library (1.4), resolved like `KICAD_LIBRARY_PROJECT`; `STD_ALTIUM_LIBRARY_PROJECT_FROM` says which. An altium part's setup adds it as the submodule `ALTIUM_LIBRARY`; `ci-setup` adds the Altium deploy key there and sets `ALTIUM_LIBRARY_REPO` from it when the project has an altium part (`std_altium_parts`) |
| `NO_COLOR` | unset | plain output |

`SECRETS_DIR` and `SECRETS_REMOTE` from the environment or `make/project.mk` (written `?=` there, so CI's environment
wins) and from the command line win over the derived values; common.mk captures them with their `$(origin)` and clears
them before config.mk, so config.mk's own `SECRETS_DIR`, `SECRETS_REMOTE` and `GITHUB_OWNER` (assigned with `:=`) are
known apart. `-include $(STD_CONFIG)/config.mk` may set `SECRETS_REMOTE`, `GITHUB_OWNER` (the default owner),
`DOCKER_REGISTRY` (its own owner's only, above), `CI_TEMPLATES_REPO` (owner/name, default `mayankgautam-me/ci-templates`, independent of
`GITHUB_OWNER`; a value in `make/project.mk` wins over config.mk, and `CI_TEMPLATES_PROJECT` is ignored since 1.7), `KICAD_LIBRARY_DIR`,
`KICAD_LIBRARY_PROJECT`, `ALTIUM_LIBRARY_PROJECT` (above) and `FREECADCMD` (the mechanical kind). `OTA_BUCKET` is a
project setting in `make/project.mk`: common.mk keeps the project's value when config.mk sets one, and warns.

`make help` filters the root entries at render time (`std_help_show`): `STD_HELP_ALWAYS`, then the
`STD_HELP_NEED_<n>` lists (shown when PARTS has a kind in `STD_HELP_KINDS_<n>`), then any root verb is shown when a
part registered it (`STD_VERB_<verb>`); everything else is shown. `ALL=1` shows all. A new root target goes in
one of those lists, never behind its own `ifeq`.

## Guard

`$(call std_confirm,<env>)` expands to a shell command that exits the shell with status 1 and a clear
message unless `CONFIRM` came from the command line and equals `<env>`; when it passes it is `true`.
**A guard protects only the shell line it is on.** Put it at the start of the recipe line that does the
work, `@$(call std_confirm,x) && action` (wrap a multi-command action in `{ ...; }`), never on a line of
its own and never as a prerequisite (`$(1)-deploy: $(1)-guard`): `make -i` would carry on past a failed
guard line. `tests/common.bats` scans common.mk and every kind for a guard that is alone on its line.
Use it for: anything with `ENV=production`, every `destroy`, `wipe`, `reset`, `erase`/`recover`, fuse burns.
`std_production_guard` = `$(if $(filter production,$(ENV)),$(call std_confirm,production),true)` and
`std_remote_guard,<part>` also refuses `ENV=local` (deploy-like targets).
common.mk also refuses, at parse time, `make -i` / `--ignore-errors`, and a `CONFIRM` that reached make
through `MAKEFLAGS` in the environment (it compares with the argv of the make process, read from
`/proc` or `ps`; `$(origin MAKEFLAGS)` cannot tell the two apart). Not covered: an environment that also
forges `MAKELEVEL` to hide the check; the secrets blocklist keeps both out of a secrets file.
`cf-destroy ENV=production` additionally needs the project name typed on `/dev/tty`
(`lib.sh confirm_typed`, which reads `/dev/tty` and nothing else); CI cannot destroy production at all.

## Secrets

Layout of the secrets repo (`SECRETS_DIR`; one per GitHub owner, standard.md 5.1):

```
.sops.yaml                  generated from recipients/ by secrets.sh, never hand-edited
recipients/se/<host>.txt    age1se1... public key of a Mac's Secure Enclave identity
recipients/dev/<host>.txt   age1... public key of a Mac's dev identity (Keychain)
recipients/recovery.txt     age1... public key of the offline recovery identity
recipients/ci/<project>.txt             CI key for common, local, staging, keys
recipients/ci/<project>-production.txt  CI key for production and common
<project>/{common,local,staging,production}.env.sops   sops dotenv
<project>/keys/<name>.sops                             sops binary
.git/hooks/pre-commit       refuses any non-.sops file outside recipients/ and the repo's own files; written by
                            secrets.sh before every commit, core.hooksPath pinned to it (not a tracked folder)
```

Who decrypts what (the `.sops.yaml` rules `secrets.sh` writes):

| Files | Recipients |
|---|---|
| `<p>/common.env.sops` | all `se`, all `dev`, recovery, `ci/<p>`, `ci/<p>-production` |
| `<p>/local.env.sops` | all `se`, all `dev`, recovery, `ci/<p>` |
| `<p>/staging.env.sops`, `<p>/keys/*` | all `se`, recovery, `ci/<p>` |
| `<p>/production.env.sops` | all `se`, recovery, `ci/<p>-production` |

Identities on a Mac:
- SE identity file: `$STD_CONFIG/age/se.txt` (an `AGE-PLUGIN-SE-1...` reference: the private key
  never leaves the Secure Enclave; created with `age-plugin-se keygen --access-control=any-biometry`).
- Dev identity: macOS Keychain generic password, service `project-standard-age-dev`, account `$USER`;
  read with `security find-generic-password -s project-standard-age-dev -w` and passed to sops as
  `SOPS_AGE_KEY` in the sops process only.
- In CI: the repository secret `SOPS_AGE_KEY`, set by `secrets.sh ci` (one key: Free private repositories have no
  environment-scoped secrets). Passed only to the jobs that decrypt or sign. `make <part>-setup` runs with it unset.make <part>-setup` runs with it unset.

`secrets.sh` interface (all subcommands take `--project P`, default from env `PROJECT`):

```
secrets.sh exec --env E -- cmd args...      decrypt common + E into the environment of cmd (exec); staging and
                                            production export only names secrets.schema declares for E or common;
                                            never a name on the blocklist (is_blocked_var) for any env;
                                            local uses the dev identity only (no Touch ID),
                                            staging/production use the SE identity (Touch ID)
secrets.sh with-file NAME -- cmd args {}    decrypt keys/NAME.sops to a mode-600 temp file in a
                                            mode-700 dir, replace {} in args, run, always remove
secrets.sh get NAME --env E                 print one value (for scripts; never echo in make); decoded exactly
                                            as exec does (literal backslash-n becomes a newline)
secrets.sh init [--gen]                     from secrets.schema: create files, prompt missing values. With no
                                            SECRETS_DIR yet: clone SECRETS_REMOTE; an empty remote (or none) starts
                                            a new repo: main, origin, hook, the public recipients se/*.txt, dev/*.txt
                                            and recovery.txt of SECRETS_DEFAULT_DIR, else of the first other
                                            ~/.secrets-* with Mac recipients (no ci/, no file holding a private
                                            key), .sops.yaml, first commit, push. Stops while a pre-1.8 ~/.secrets
                                            waits to be moved
secrets.sh set NAME --env E                 hidden prompt (or stdin when not a TTY), sops set, commit+push
secrets.sh edit --env E                     sops edit, commit+push; ENV local or common only (staging/production
                                            refuse and point to set/import); vim/neovim run with swap, undo,
                                            backup and viminfo off, in a private TMPDIR that is removed
secrets.sh list                             names/envs/users from schema + which are present (no values)
secrets.sh check                            missing names (an `optional:` row only warns), wrong recipients,
                                            tracked secrets in the
                                            project repo (git ls-files against secret-patterns.sh, an .npmrc
                                            only when it sets a credential; + gitleaks if present)
secrets.sh keygen NAME --type TYPE          ed25519|ecdsa-p256|rsa-3072|mcuboot-ecdsa-p256|espsecure-v2
                                            written straight into keys/NAME.sops; refuse if exists
secrets.sh rotate NAME --env E              generate (schema says gen) or prompt, set, then hint cf-secrets
secrets.sh ci [--force]                     create ci/<p> and ci/<p>-production age keys (the same public key today),
                                            store the private key as the GitHub Actions secret SOPS_AGE_KEY with
                                            gh secret set (stdin, never argv), regenerate .sops.yaml, updatekeys,
                                            commit+push
secrets.sh enroll                           new Mac (or this Mac in another owner's repo): clone SECRETS_REMOTE to
                                            SECRETS_DIR if missing (starting a new repo as init does), reuse or
                                            create SE + dev identities, write recipients/{se,dev}/<host>.txt,
                                            commit+push, print what to run on an enrolled Mac
secrets.sh add-machine HOST                 regenerate .sops.yaml, `sops updatekeys -y` every file, commit+push
secrets.sh remove-machine HOST              delete its recipients, updatekeys, list values to rotate
secrets.sh sync                             git pull --ff-only, at most once an hour
                                            (stamp: $SECRETS_DIR/.git/project-standard-pulled), silent
                                            when offline
secrets.sh doctor                           tools, identities, repo, recipients, schema completeness (check)
```

`secrets.schema` (committed in each project, one secret per line, `#` comments):

```
# NAME                 envs                       used-by        gen   description
CLOUDFLARE_API_TOKEN   staging,production         auth,ci        no    the project's one token, see docs
CLOUDFLARE_ACCOUNT_ID  common                     auth,ci        no    account id
JWT_SECRET             local,staging,production   cf             32    HMAC key for sessions
mcuboot                keys                       firmware       mcuboot-ecdsa-p256  MCUboot signing key
```

`envs` is a comma list of `common local staging production`, or `keys` for a key file. `used-by` is a
comma list of `cf auth ci local firmware app`. `gen` is `no`, a byte count (random base64url), or a keygen
type for keys. A description that starts with `optional:` marks a value the project can do without:
`check` (and so `doctor`) warns when it is missing and does not count it, `list` shows `not set (optional)`,
`init` does not count it as missing.

Plain text never reaches disk, apart from `with-file`'s mode-600 temp key. That includes the files bash 3.2
makes for here-documents and here-strings (in `/var/tmp`, whatever `TMPDIR` says): no script feeds a value to
a loop that way (`tests/secrets.bats` lists every here-document and fails on a new one).

Values reach Cloudflare only through `cf.sh secrets` (`wrangler secret bulk` reading JSON from stdin),
never through a file.

## cf.sh

```
cf.sh login [--env E]        one token per project: prompt token, verify (GET /user/tokens/verify, then /accounts),
                             store the same CLOUDFLARE_API_TOKEN in staging AND production (never common: dev
                             keys open it) + CLOUDFLARE_ACCOUNT_ID (common) via secrets.sh set; --env is ignored
cf.sh logout [--env E]       remove the token from staging and production, print the dashboard URL to revoke it
cf.sh whoami                 account + the token's status and expiry; reads both copies (one unlock each), exit 1
                             and says so when they differ or only one is stored
cf.sh token-check --env E    verify the token, probe each API the bindings of E need (local means production),
                             and R2 when make/project.mk sets OTA_BUCKET or a <part>_OTA_BUCKET (an OTA-only
                             project, with no cloud-worker or web-pages part, needs no Workers Scripts); outside
                             CI also fail when the other env's copy differs or is missing; a project with no
                             Cloudflare part and no OTA bucket says so and exits 0
cf.sh envs --dir D           the env names in D/wrangler.jsonc (scaffold finds production-only parts with it)
cf.sh provision --env E --dir D     read D/wrangler.jsonc (env.E bindings), create missing D1/KV/R2/
                             Queues (producers, consumer queues, dead_letter_queue; each name once) (wrangler)
                             and write ids back (jq on the JSON with comments removed
                             is NOT allowed: edit ids with a targeted textual replace that keeps comments)
cf.sh status --env E --dir D        declared vs existing
cf.sh migrate --env E --dir D       wrangler d1 migrations apply (--local for local, --remote else)
cf.sh seed --env E --dir D          D/seed/*.sql into local or staging; production refused
cf.sh secrets --env E --dir D [--rotate NAME]   push cf secrets for E
cf.sh backup --env E --dir D        d1 export, every KV key with its value, r2 bucket info; tar | age -R >
                                    ~/Backups/<project>/<env>-<date>.tar.age; recipients: se + recovery
                                    (dev keys only for local data)
cf.sh wipe --env E --dir D [--r2-unbacked]      backup first, then delete data, keep resources
cf.sh destroy --env E --dir D [--r2-unbacked]   backup first, delete worker + resources of E; production
                                    asks for the project name on /dev/tty only, after the unlock, and
                                    never runs when CI, GITLAB_CI or GITHUB_ACTIONS is set
                                    both refuse when a declared resource cannot be backed up (R2 objects:
                                    needs --r2-unbacked, which make passes for R2_UNBACKED=1 typed on the
                                    command line) and when a D1/R2/Queue name does not start with
                                    <project>-<env> or the env's Worker name does not end with -<env>
```

A remote env without its `env.E` block is refused by every subcommand that would use it (migrate, seed, secrets,
provision, status, backup) before any unlock: wrangler would deploy the top-level config as `<name>-E`. A part
with no `env.staging` is production-only: CI deploys no staging for it (`production_only: true`), and its tag deploys
production like any cloud part (the reusable workflow's `deploy-production` job, `make <part>-deploy ENV=production`).
Bindings other than D1, KV, R2 and Queues reach wrangler on deploy only (not provisioned, checked or backed up;
Durable Object storage is not in a backup).

Everything that talks to Cloudflare runs under `secrets.sh exec --env E`, so wrangler sees
`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` from the environment and nothing else.
`wrangler` is run from the part's dir (pinned in its package.json) through the part's package manager: `pnpm exec wrangler`
when the part has `pnpm-lock.yaml`, else `npx --no-install wrangler`. The JS kinds (cloud-worker, web-pages, app-tauri)
run every package binary the same way through `<part>_EXEC`.

## Releases (release.sh)

Every kind calls `$(call std_release,part,kind,dir,assets-helper,pre-steps)` (common.mk) in its template, which
registers `<part>-bump` and `<part>-github-release` (fan-out verbs; the root `bump` and `github-release` use
`std_single`, so they need `PART=` with several parts) and `<part>-release-assets` (extra). `pre-steps` are the
part's own targets run first unless `NOBUILD=1` (`build`; hardware `check build`; go and docker `release`; empty
when the helper builds itself). The assets helper is shell text expanded when the recipe runs, called with
`part,dir`; it starts with `$(call std_rel_begin,part,kind,dir)` (sets `ver` and `out` = `<dir>/release/<ver>`,
emptied; defines `put FILE [NAME]`, `need`, `opt`, `zipdir DIR NAME`) and ends with `$(std_rel_end)` (writes
`SHA256SUMS`). `<dir>/release/` is in the project's `.gitignore` per part (scaffold) and the audit warns about
tracked files in it. `FORCE` and `VERSION` count only from the command line (`$(origin ...)`).

```
release.sh version --part P --kind K [--part-dir D]     the version from the kind's source (error when none)
release.sh bump    --part P --kind K [--part-dir D] (--level patch|minor|major | --version V) [--force]
                                                        writes the version source, moves the CHANGELOG's
                                                        Unreleased section under `## [V] - YYYY-MM-DD` and
                                                        writes a fresh empty one, `git add` + `git commit -- <files>`
                                                        (those files by name only), `git tag -a P-vV`; never pushes;
                                                        refuses an empty Unreleased without --force, an existing
                                                        tag, an unchanged version, a dynamic python version, an
                                                        Xcode project without agvtool
release.sh notes   --part P --version V [--part-dir D]  the CHANGELOG section of V (error when missing)
release.sh sums    --dir D                              D/SHA256SUMS of every other file in D
release.sh zip     --from DIR --to FILE                 zip of DIR's content (zip, else python3 -m zipfile;
                                                        release/, node_modules/ and .git left out)
release.sh gate    --part P --version V [--force]       0 in the pipeline of tag P-vV (or --force outside CI),
                                                        3 on another part's tag (nothing to do), 1 otherwise
release.sh upload  --part P --version V --dir D      the v8 name of create, same arguments: kept for existing callers
release.sh create  --part P --version V --dir D [--part-dir D2] [--build-note-file F]
                                                        the GitHub Release of tag P-vV (the workflow pushed the tag), titled
                                                        "P V", notes from the CHANGELOG. Created with gh release create; when it
                                                        exists, its name and notes are edited and the assets uploaded with
                                                        --clobber. Files that are not Release assets (*.aab, *-mapping.txt) stay
                                                        in D and are printed as "unlinked: NAME" for the workflow to upload as
                                                        an artifact. "### Builds" lines survive updates; F, when present, holds
                                                        this platform's line.
```

Version sources (the `version` / `bump` table): firmware kinds `<dir>/VERSION` (Zephyr `VERSION_MAJOR` ...
`EXTRAVERSION`, or a plain first line) else `<dir>/version.txt` (silabs included); hardware `<dir>/VERSION` else the
title block `rev` (bump writes `VERSION`); altium, mechanical, go, docker, cloud-worker, web-pages `<dir>/VERSION`. The
board kinds (hardware, altium, mechanical; `is_board_kind`) start a first bump at a plain number and group the
Release `latest` by major revision. Each kind file passes its own name as `--kind` (`std_release`, `std_rel_begin`);
a kind release.sh does not list has no version source; app-flutter `pubspec.yaml`
(`+build` counted up); app-tauri `src-tauri/tauri.conf.json` (or the JSON file its `version` names; bump also sets
the `[package]` `version` of `src-tauri/Cargo.toml`, the top-level `version` of `package.json` and the app's entry in
a tracked `src-tauri/Cargo.lock`); app-android
`app/build.gradle.kts` `versionName` (`versionCode` counted up); app-xcode agvtool (`MARKETING_VERSION` of the
pbxproj when reading without it); python `pyproject.toml` `[project]` (or `[tool.poetry]`). A version is 1 to 3
numbers and an optional `-prerelease`; `+` is not allowed (it is not a valid tag or package version character).

GitHub (since v9): `gh` does the work. In a GitHub Actions run (`GITHUB_ACTIONS` set) the repository is `GITHUB_REPOSITORY`
and the token is `GH_TOKEN`, which the workflow sets from `GITHUB_TOKEN` (`permissions: contents: write`). gh reads the token
from the environment, never from a command line. On a Mac gh uses its own login and infers the repository from the checkout;
`gh_cli` adds `--repo` in CI. No here-document or here-string anywhere in the script.

## CI workflows (`ci-templates/`)

- `ci-templates/.github/workflows/<kind>.yml`: one reusable workflow per kind (`on: workflow_call`), in `CI_TEMPLATES_REPO`
  (default `mayankgautam-me/ci-templates`, public, shared by every project owner), tagged `v1.4` (`v1.3`, `v1.2`, `v1.1` and `v1.0` are kept: a
  published tag never moves). `scaffold.sh` and
  `audit.sh` resolve it the same way (`ci_project`: `make/project.mk`, else the environment or the user config, else
  the default); the audit warns on a `uses:` line on any other repository. Inputs: `part`, `part_dir`, `run_check`, `run_build`, `run_release`, `confirm`, `source_run_id`,
  `deploy_staging`, `production_only`, `target`, and `library` (hardware: `shared`, the default, or `local`, which checks
  out no KiCad library; `ci_job` writes `library: local` when `make/project.mk` sets `<part>_LIBRARY := local`). Secrets are declared in each file and passed explicitly by the caller (no
  `secrets: inherit`): `SECRETS_DEPLOY_KEY`, `SOPS_AGE_KEY`, `KICAD_LIBRARY_DEPLOY_KEY` for hardware and
  `ALTIUM_LIBRARY_DEPLOY_KEY` for altium (`ci_secrets`; `altium.yml` checks the library out at the commit
  `make <part>-lib-ref` prints, 1.4).
- Every job calls `make` only: `make "$PART-check"`, `-build`, `-github-release`, and the production verbs with
  `CONFIRM=production` set on the make line by the workflow (the guard accepts it because CI sets it).
- `scaffold.sh` (`ci_workflow`, `ci_release_workflow`, `ci_job`, `ci_changes`) writes the project's `checks.yml` and `release.yml`
  when they are missing; an existing file is kept. `checks.yml`: a `changes` job whose outputs are true when a part's folder,
  `make/`, `Makefile`, `mise.toml` or `.github/workflows/` changed, then one job per part calling the kind's workflow, and
  a `workflow_dispatch` trigger. `release.yml`: one `<part>-release` job per part, with
  `needs: tag` and `if: needs.tag.outputs.part == '<part>'` (the `tag` job takes the part from the tag, exactly; none for
  an altium part, `ci_has_release`, whose Release is made where Altium's outputs are, and no `latest` job when no part
  has one; `audit.sh` has the same rule, `kind_has_release`), and
  `run_release: true` (a cloud-worker or web-pages part's job also passes `confirm: production`: its tag deploys
  production, then makes the notes-only Release), then the production
  jobs, with `if: github.event_name == 'workflow_dispatch' && inputs.part == '<part>' && inputs.confirm == 'production'`.
- Settings that apply to every job (`STD_APT_PACKAGES`, `KICAD_LIBRARY_REPO`, `ALTIUM_LIBRARY_REPO`, `SECRETS_REPO`, `MACOS_CI`) are repository
  variables, read with defaults (`${NAME:-default}`). No workflow sets them on a job, where they would override the repository
  value. Every apt-get install line appends `${STD_APT_PACKAGES:-}`. `tests/ci.bats` checks it.
- Production and store jobs run only with `confirm: production` (free private repositories have no environments). Store
  bundles and mapping files are workflow artifacts (7 days in the app workflows); build artifacts are kept 7 days.
- `ci-templates/README.md` holds the inputs, secrets, variables, runners and the deploy-key commands.

## Tests

`skills/project-standard/tests/*.bats`, run with `bats ~/.claude/skills/project-standard/tests`.
Tests build projects in `$BATS_TEST_TMPDIR`, put stub tools (wrangler, west, sops when needed, gh, actionlint, act,
security, age-plugin-se...) first on `PATH`, and assert on output and exit codes. Real sops + age are
used for the secrets tests with throwaway age keys (`age-keygen`), never the Secure Enclave and never
the real `~/.secrets-*` (`SECRETS_DIR` and `STD_CONFIG` point into the temp dir). No test touches the
network or Cloudflare.
