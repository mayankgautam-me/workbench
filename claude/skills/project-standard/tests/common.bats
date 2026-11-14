#!/usr/bin/env bats
# common.mk: parts, fan-out, guard, ENV, help, hooks, delegation to cf.sh / secrets.sh / gh.

load helpers

setup() {
  std_setup_env
  P="$BATS_TEST_TMPDIR/proj"
  mkproject "$P" 'PROJECT := demo
PARTS := \
  fw-a:fake \
  fw-b:fake \
  cloud-api:cloud-worker:cloud/api \
  cloud-web:cloud-worker:cloud/web'
  mkfakekinds "$P"
  cd "$P"
}

@test "default goal is help and runs on GNU make 3.81" {
  run /usr/bin/make
  [ "$status" -eq 0 ]
  [[ "$output" == *"make demo"* ]]
  run /usr/bin/make -v
  [[ "${lines[0]}" == *"3.81"* ]] || skip "/usr/bin/make is not 3.81 here"
}

@test "also works with make 4.x when gmake is installed" {
  command -v gmake >/dev/null || skip "no gmake"
  run gmake help
  [ "$status" -eq 0 ]
  [[ "$output" == *"fw-a-build"* ]]
}

@test "help: groups in the contract order, parts after root commands" {
  # ALL=1: the release group has no part here, so plain make help leaves it out
  run make help ALL=1
  [ "$status" -eq 0 ]
  # group order: setup dev test cloudflare secrets deploy ci firmware release
  local order="" g
  for g in setup dev test cloudflare secrets deploy ci firmware release; do
    local n
    n="$(printf '%s\n' "$output" | grep -n "^$g\$" | head -n1 | cut -d: -f1)"
    [ -n "$n" ] || { echo "group $g missing"; false; }
    order="$order $n"
  done
  local sorted
  sorted="$(printf '%s\n' $order | sort -n | tr '\n' ' ')"
  [ "$(printf '%s ' $order)" = "$sorted" ]
  # part targets sit in their group, with the description expanded
  [[ "$output" == *"fw-a-build"*"Build for nrf into fw-a/build"* ]]
  [[ "$output" == *"cloud-api-deploy"*"Deploy cloud-api from cloud/api"* ]]
  [[ "$output" == *"parts: fw-a(fake) fw-b(fake) cloud-api(cloud-worker) cloud-web(cloud-worker)"* ]]
}

@test "help: ## lines of make/local.mk show under project" {
  cat >make/local.mk <<'EOF'
## Open the docs
docs:
	@echo docs
seed-all: ## Seed everything
	@echo seed
undocumented:
	@echo no
EOF
  run make help
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nproject\n'* ]]
  [[ "$output" == *"docs"*"Open the docs"* ]]
  [[ "$output" == *"seed-all"*"Seed everything"* ]]
  [[ "$output" != *"undocumented"* ]]
  # project is the last group (release is not listed: no part here releases)
  local p r
  p="$(printf '%s\n' "$output" | grep -n '^project$' | cut -d: -f1)"
  r="$(printf '%s\n' "$output" | grep -n '^firmware$' | cut -d: -f1)"
  [ "$p" -gt "$r" ]
  run make docs
  [ "$output" = docs ]
}

@test "help: plain when not a TTY or NO_COLOR, truecolour on a TTY" {
  run make help
  [[ "$output" != *$'\033'* ]]
  command -v script >/dev/null || skip "no script(1) to fake a TTY"
  unset NO_COLOR
  run script -q /dev/null make help
  [[ "$output" == *$'\033[38;2;'* ]]
  run env NO_COLOR=1 script -q /dev/null make help
  [[ "$output" != *$'\033['* ]]
}

@test "ENV: invalid value is a parse error, valid ones pass" {
  run make help ENV=prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENV=prod is not valid"* ]]
  run make help ENV=staging
  [ "$status" -eq 0 ]
  run make build ENV=staging PART=fw-a
  [[ "$output" == *"BUILD fw-a ENV=staging"* ]]
}

@test "ENV: a stray ENV in the shell environment is ignored" {
  ENV=/home/x/.shrc run make build PART=fw-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENV=local"* ]]
}

@test "PROJECT must be set" {
  printf 'PARTS :=\n' >make/project.mk
  run make help
  [ "$status" -ne 0 ]
  [[ "$output" == *"PROJECT is not set"* ]]
}

@test "a part kind without a kinds file is an error" {
  printf 'PROJECT := demo\nPARTS := x:nokind\n' >make/project.mk
  run make help
  [ "$status" -ne 0 ]
  [[ "$output" == *"no make/kinds/nokind.mk"* ]]
}

@test "root verb fans out to the parts in PARTS order" {
  run make build
  [ "$status" -eq 0 ]
  local joined
  joined="$(printf '%s\n' "$output" | grep -E '^BUILD ' | tr '\n' ' ')"
  [ "$joined" = "BUILD fw-a ENV=local BUILD fw-b ENV=local BUILD cloud-api BUILD cloud-web " ]
}

@test "PART= restricts a root verb to one part, an unknown PART is an error" {
  run make build PART=fw-b
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^BUILD')" -eq 1 ]
  [[ "$output" == *"BUILD fw-b"* ]]
  run make build PART=nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"PART=nope is not a part"* ]]
}

@test "a verb that no part has is a quiet no-op" {
  run make format
  [ "$status" -eq 0 ]
  [[ "$output" == *"no part has 'format'"* ]]
}

@test "flash with two firmware parts exits 2 and lists them" {
  run make flash
  [ "$status" -eq 2 ]
  [[ "$output" == *"several parts have 'flash'"* ]]
  [[ "$output" == *"fw-a-flash"* && "$output" == *"fw-b-flash"* ]]
}

@test "flash with PART= or a single part runs it" {
  run make flash PART=fw-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"FLASH fw-b"* ]]
  printf 'PROJECT := demo\nPARTS := only:fake\n' >make/project.mk
  run make flash
  [ "$status" -eq 0 ]
  [[ "$output" == *"FLASH only"* ]]
}

@test "erase needs the guard, then acts on one part" {
  run make erase PART=fw-a
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=erase"* ]]
  run make erase PART=fw-a CONFIRM=erase
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERASE fw-a"* ]]
}

@test "deploy to production: refused without CONFIRM, with a wrong value, from the environment" {
  run make deploy ENV=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=production"* ]]
  [[ "$output" != *"DEPLOY"* ]]
  run make deploy ENV=production CONFIRM=staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong value"* ]]
  [[ "$output" != *"DEPLOY"* ]]
  CONFIRM=production run make deploy ENV=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"command line"* ]]
  [[ "$output" != *"DEPLOY"* ]]
  run make deploy ENV=production CONFIRM="production staging"
  [ "$status" -ne 0 ]
}

@test "deploy to production with the right CONFIRM runs check, build, deploy, smoke" {
  run make deploy ENV=production CONFIRM=production
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUILD fw-a ENV=production"* ]]
  [[ "$output" == *"DEPLOY cloud-api ENV=production DIR=cloud/api"* ]]
  [[ "$output" == *"DEPLOY cloud-web ENV=production DIR=cloud/web"* ]]
}

@test "deploy to staging needs no CONFIRM" {
  run make deploy ENV=staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEPLOY cloud-api ENV=staging"* ]]
}

@test "rollback and test-remote also guard production" {
  run make rollback ENV=production
  [ "$status" -ne 0 ]
  run make test-remote ENV=production
  [ "$status" -ne 0 ]
  run make rollback ENV=staging
  [ "$status" -eq 0 ]
}

@test "promote always needs CONFIRM=production and runs the parts with ENV=production" {
  mkkind "$P" cloud-worker 'define kind_cloud-worker
$(call std_verb,$(1),promote,deploy,Promote $(1))
$(1)-promote:
	@echo PROMOTE $(1) ENV=$$(ENV)
endef'
  run make promote
  [ "$status" -ne 0 ]
  [[ "$output" != *"PROMOTE"* ]]
  run make promote CONFIRM=production
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMOTE cloud-api ENV=production"* ]]
}

@test "reset needs CONFIRM=local on the command line and ENV=local" {
  mkkind "$P" fake 'define kind_fake
$(call std_verb,$(1),reset,dev,Reset $(1))
$(1)-reset:
	@echo RESET $(1)
endef'
  run make reset
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=local"* ]]
  [[ "$output" != *"RESET"* ]]
  run make reset CONFIRM=production
  [ "$status" -ne 0 ]
  CONFIRM=local run make reset
  [ "$status" -ne 0 ]
  [[ "$output" != *"RESET"* ]]
  run make reset ENV=staging CONFIRM=local
  [ "$status" -ne 0 ]
  [[ "$output" == *"only works on ENV=local"* ]]
  run make reset CONFIRM=local
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESET fw-a"* ]]
}

@test "root bump acts on one part: PART= when several parts have it, and passes LEVEL on" {
  run make bump LEVEL=patch
  [ "$status" -eq 2 ]
  [[ "$output" == *"no part has 'bump'"* ]]
  # a kind with bump on both fw parts
  printf '%s\n' 'define kind_fake' '$(call std_verb,$(1),bump,release,Bump $(1))' '$(1)-bump:' \
    '	@echo BUMP $(1) LEVEL=$(LEVEL)' 'endef' >make/kinds/fake.mk
  run make bump LEVEL=patch
  [ "$status" -eq 2 ]
  [[ "$output" == *"PART=<part>"*"fw-a-bump fw-b-bump"* ]]
  run make bump LEVEL=minor PART=fw-b
  [ "$status" -eq 0 ]
  [ "$output" = "BUMP fw-b LEVEL=minor" ]
}

@test "std_confirm and std_production_guard are usable from local.mk" {
  cat >make/local.mk <<'EOF'
wipe-all:
	@$(call std_confirm,$(ENV))
	@echo WIPED
EOF
  run make wipe-all
  [ "$status" -ne 0 ]
  [[ "$output" != *WIPED* ]]
  run make wipe-all CONFIRM=local
  [[ "$output" == *WIPED* ]]
  run make wipe-all CONFIRM=staging
  [ "$status" -ne 0 ]
}

@test "part targets are phony even when a file of that name exists" {
  touch fw-a-build
  run make fw-a-build
  [[ "$output" == *"BUILD fw-a"* ]]
}

# --- delegation ---------------------------------------------------------------------------------

record_script() { # FILE  replace a managed script with an argv recorder
  printf '#!/bin/bash\nprintf "%%s " "$@" >>"%s/calls"; echo >>"%s/calls"\n' "$STUB_LOG" "$STUB_LOG" >"$1"
}

@test "cf-* run cf.sh once per cloud-worker part, PART= restricts" {
  record_script make/bin/cf.sh
  run make cf-provision ENV=staging
  [ "$status" -eq 0 ]
  run cat "$STUB_LOG/calls"
  [ "${lines[0]}" = "provision --project demo --env staging --dir cloud/api  " ] ||
    [ "${lines[0]}" = "provision --project demo --env staging --dir cloud/api " ]
  [[ "${lines[1]}" == "provision --project demo --env staging --dir cloud/web"* ]]
  : >"$STUB_LOG/calls"
  run make cf-status ENV=staging PART=cloud-web
  run cat "$STUB_LOG/calls"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "status --project demo --env staging --dir cloud/web"* ]]
}

@test "cf-secrets passes ROTATE, cf-migrate-list passes --list, cf-login has no dir and needs no ENV" {
  record_script make/bin/cf.sh
  make cf-secrets ENV=staging PART=cloud-api ROTATE=JWT_SECRET
  make cf-migrate-list ENV=staging PART=cloud-api
  make cf-login ENV=staging
  make cf-login
  make cf-logout
  run cat "$STUB_LOG/calls"
  [[ "${lines[0]}" == *"secrets --project demo --env staging --dir cloud/api --rotate JWT_SECRET"* ]]
  [[ "${lines[1]}" == *"migrate --project demo --env staging --dir cloud/api --list"* ]]
  # one token per project: login and logout act on staging and production whatever ENV is
  [[ "${lines[2]}" == "login --project demo"* ]]
  [[ "${lines[2]}" != *"--dir"* && "${lines[2]}" != *"--env"* ]]
  [[ "${lines[3]}" == "login --project demo"* ]]
  [[ "${lines[4]}" == "logout --project demo"* ]]
  run make help
  [[ "$output" == *"cf-login"*"staging and production"* ]]
}

@test "cf-wipe and cf-destroy need CONFIRM=<env> before cf.sh is called" {
  record_script make/bin/cf.sh
  run make cf-destroy ENV=staging
  [ "$status" -ne 0 ]
  run make cf-destroy ENV=production CONFIRM=staging
  [ "$status" -ne 0 ]
  run make cf-wipe ENV=staging
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG/calls" ]
  run make cf-destroy ENV=staging CONFIRM=staging PART=cloud-api
  [ "$status" -eq 0 ]
  grep -q "destroy --project demo --env staging --dir cloud/api" "$STUB_LOG/calls"
}

@test "cf-provision and cf-status also run the OTA bucket once, after the parts; PART= of a Worker skips it" {
  record_script make/bin/cf.sh
  run make cf-provision ENV=staging
  [ "$status" -eq 0 ]
  run cat "$STUB_LOG/calls"
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[2]}" == "provision-ota --project demo --env staging"* ]]
  [[ "${lines[2]}" != *"--dir"* ]]
  : >"$STUB_LOG/calls"
  run make cf-status ENV=staging
  run cat "$STUB_LOG/calls"
  [[ "${lines[2]}" == "status-ota --project demo --env staging"* ]]
  : >"$STUB_LOG/calls"
  make cf-provision ENV=staging PART=cloud-api
  run cat "$STUB_LOG/calls"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "provision --project demo"* ]]
}

@test "cf-provision of an OTA-only project runs cf.sh provision-ota only, and production still needs CONFIRM" {
  printf 'PROJECT := demo\nPARTS := fw-a:fake\nOTA_BUCKET := demo-ota\n' >make/project.mk
  record_script make/bin/cf.sh
  run make cf-provision ENV=staging
  [ "$status" -eq 0 ]
  [[ "$output" != *"no cloud-worker part"* ]]
  run cat "$STUB_LOG/calls"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "provision-ota --project demo --env staging"* ]]
  : >"$STUB_LOG/calls"
  run make cf-provision ENV=production
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG/calls" ]
  run make cf-provision ENV=production CONFIRM=production
  [ "$status" -eq 0 ]
  grep -q "provision-ota --project demo --env production" "$STUB_LOG/calls"
}

@test "cf-* with no cloud-worker part says so" {
  printf 'PROJECT := demo\nPARTS := fw-a:fake\n' >make/project.mk
  record_script make/bin/cf.sh
  run make cf-status ENV=staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cloud-worker part"* ]]
}

@test "secrets-* delegate to secrets.sh with the project and env" {
  record_script make/bin/secrets.sh
  make secrets-set NAME=JWT_SECRET ENV=staging
  make secrets-init GEN=1
  make secrets-keygen NAME=mcuboot TYPE=ed25519
  make secrets-add-machine HOST=mac2
  make secrets-check
  run cat "$STUB_LOG/calls"
  [[ "${lines[0]}" == "set JWT_SECRET --project demo --env staging"* ]]
  [[ "${lines[1]}" == "init --project demo --gen"* ]]
  [[ "${lines[2]}" == "keygen mcuboot --project demo --type ed25519"* ]]
  [[ "${lines[3]}" == "add-machine mac2 --project demo"* ]]
  [[ "${lines[4]}" == "check --project demo"* ]]
}

@test "secrets-set without NAME refuses, secrets values never appear in make's argv" {
  record_script make/bin/secrets.sh
  run make secrets-set
  [ "$status" -ne 0 ]
  [[ "$output" == *"NAME= is required"* ]]
  run make secrets-add-machine
  [ "$status" -ne 0 ]
  [[ "$output" == *"HOST= is required"* ]]
}

@test "ci-* call gh and actionlint, and say so when they are missing" {
  mkdir -p .github/workflows && : >.github/workflows/checks.yml
  stub_recorder gh
  stub_recorder actionlint
  make ci-lint
  make ci-status
  make ci-run
  [ -f "$STUB_LOG/actionlint.argv" ]
  [[ "$(cat "$STUB_LOG/gh.argv")" == *"run"$'\n'"list"* ]]
  [[ "$(cat "$STUB_LOG/gh.argv")" == *"workflow"$'\n'"run"$'\n'"checks.yml"$'\n'"--ref"* ]]
  rm -f "$STUBS/gh" "$STUBS/actionlint"
  PATH="/usr/bin:/bin" run make ci-status
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh not found"* ]]
  PATH="/usr/bin:/bin" run make ci-lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"actionlint not found"* ]]
}

@test "ci-setup-help prints the commands for the deploy keys with the owner, and no values" {
  export GITHUB_OWNER=acme
  run make ci-setup-help
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh repo deploy-key add ~/.ssh/"*"--repo acme/secrets --title demo-ci-read-only"* ]]
  [[ "$output" == *"gh secret set SECRETS_DEPLOY_KEY --repo acme/demo"* ]]
  [[ "$output" == *"make secrets-ci"* ]]
  [[ "$output" != *"BEGIN OPENSSH"* ]]
  [[ "$output" != *"AGE-SECRET-KEY"* ]]
  # the default CI templates repo is public: no access step
  [[ "$output" != *"Settings > Actions > General > Access"* ]]
  # another CI_TEMPLATES_REPO: a note for when it is private
  run make ci-setup-help CI_TEMPLATES_REPO=acme/ci-own
  [ "$status" -eq 0 ]
  [[ "$output" == *"Only if CI_TEMPLATES_REPO (acme/ci-own) is private"*"Settings > Actions > General > Access"* ]]
  unset GITHUB_OWNER
}


# a fake gh for ci-setup: logs each call, knows the repo, lists the deploy keys in $STUB_LOG/keys
ci_setup_stubs() {
  stub_cmd gh 'printf "%s\n" "$*" >>"$STUB_LOG/gh.calls"
case "$1 $2" in
  "repo view") case "$*" in *visibility*) echo "${CI_VISIBILITY:-PUBLIC}" ;; esac; [ -z "${NO_REPO:-}" ]; exit $? ;;
  "repo deploy-key") case "$3" in
      list) cat "$STUB_LOG/keys" 2>/dev/null ;;
      add) cut -d" " -f1,2 "$4" >>"$STUB_LOG/keys" ;;
    esac ;;
  "secret set") printf "%s %s\n" "$3" "$(wc -c | tr -d " ")" >>"$STUB_LOG/secrets" ;;
esac
exit 0'
  stub_cmd ssh-keygen 'while [ $# -gt 0 ]; do [ "$1" = -f ] && f=$2; shift; done
printf "PRIVATE\n" >"$f"; printf "ssh-ed25519 AAAAfake%s c\n" "$RANDOM" >"$f.pub"; echo "$f" >>"$STUB_LOG/keygen"'
}

@test "ci-setup makes the deploy keys, adds them, sets the secrets and variables, and prints no values" {
  export GITHUB_OWNER=acme
  mkdir -p "$HOME/.ssh"
  ci_setup_stubs
  run make ci-setup STD_SECRETS=:
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUB_LOG/keygen")" -eq 1 ]
  grep -q 'repo deploy-key add .*demo-ci-secrets.pub --repo acme/secrets --title demo-ci-read-only' "$STUB_LOG/gh.calls"
  grep -q '^SECRETS_DEPLOY_KEY [1-9]' "$STUB_LOG/secrets"
  grep -q 'variable set SECRETS_REPO --repo acme/demo --body acme/secrets' "$STUB_LOG/gh.calls"
  [[ "$output" != *"PRIVATE"* ]]
  # a second run keeps the key and adds no second deploy key
  run make ci-setup STD_SECRETS=:
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUB_LOG/keygen")" -eq 1 ]
  [ "$(grep -c 'deploy-key add' "$STUB_LOG/gh.calls")" -eq 1 ]
  [[ "$output" == *"already a deploy key of acme/secrets"* ]]
  # the public default CI templates repo needs no access setting
  grep -q 'repo view mayankgautam-me/ci-templates --json visibility' "$STUB_LOG/gh.calls"
  [[ "$output" != *"Settings > Actions > General > Access"* ]]
  unset GITHUB_OWNER
}

@test "ci-setup warns about the Actions access setting only when CI_TEMPLATES_REPO is not public" {
  export GITHUB_OWNER=acme
  mkdir -p "$HOME/.ssh"
  ci_setup_stubs
  export CI_VISIBILITY=PRIVATE
  run make ci-setup STD_SECRETS=: CI_TEMPLATES_REPO=acme/ci-own
  unset CI_VISIBILITY
  [ "$status" -eq 0 ]
  grep -q 'repo view acme/ci-own --json visibility' "$STUB_LOG/gh.calls"
  [[ "$output" == *"CI_TEMPLATES_REPO acme/ci-own is not public"*"Settings > Actions > General > Access"*"acme"* ]]
  unset GITHUB_OWNER
}

@test "ci-setup refuses without GITHUB_OWNER or without the GitHub repository" {
  ci_setup_stubs
  run make ci-setup STD_SECRETS=: GITHUB_OWNER=
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_OWNER is not set"* ]]
  export NO_REPO=1
  run make ci-setup STD_SECRETS=: GITHUB_OWNER=acme
  unset NO_REPO
  [ "$status" -ne 0 ]
  [[ "$output" == *"no GitHub repository acme/demo"* ]]
  [ ! -f "$STUB_LOG/keygen" ]
}

# --- hooks -------------------------------------------------------------------------------------

@test "hooks: installs a pre-commit hook that blocks files over 5 MB" {
  git init -q -b main .
  run make hooks
  [ "$status" -eq 0 ]
  [ -x .git/hooks/pre-commit ]
  head -c 6000000 /dev/zero >big.bin
  echo hi >small.txt
  git add small.txt
  run git commit -q -m small
  [ "$status" -eq 0 ]
  git add big.bin
  run git commit -q -m big
  [ "$status" -ne 0 ]
  [[ "$output" == *"big.bin"*"limit 5 MB"* ]]
}

@test "hooks: the large-file guard skips KiCad design files, which are text and stay in plain git" {
  git init -q -b main .
  run make hooks
  [ "$status" -eq 0 ]
  mkdir -p hw
  for e in kicad_pcb kicad_sch kicad_pro; do head -c 6000000 /dev/zero | tr '\0' 'x' >"hw/board.$e"; done
  git add hw
  run git commit -q -m board
  [ "$status" -eq 0 ]
  # a large file with another name next to them is still refused
  head -c 6000000 /dev/zero >hw/board.step
  git add hw/board.step
  run git commit -q -m step
  [ "$status" -ne 0 ]
  [[ "$output" == *"hw/board.step"*"limit 5 MB"* ]]
}

@test "hooks: leaves a foreign hook alone, re-install is idempotent" {
  git init -q -b main .
  run make hooks
  run make hooks
  [ "$status" -eq 0 ]
  printf '#!/bin/sh\necho mine\n' >.git/hooks/pre-commit
  run make hooks
  [ "$status" -ne 0 ]
  [[ "$output" == *"not installed by project-standard"* ]]
  grep -q mine .git/hooks/pre-commit
}

@test "hooks: outside a git repository is a clear error" {
  run make hooks
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git repository"* ]]
}

@test "setup runs the parts' setup, installs hooks in a git repo" {
  mkkind "$P" fake 'define kind_fake
$(call std_verb,$(1),setup,setup,Set up $(1))
$(1)-setup:
	@echo SETUP $(1)
endef'
  git init -q -b main .
  run make setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"SETUP fw-a"*"SETUP fw-b"* ]]
  [ -x .git/hooks/pre-commit ]
}

@test "doctor runs every part and reports instead of stopping at the first problem" {
  mkkind "$P" fake 'define kind_fake
$(call std_verb,$(1),doctor,setup,Doctor $(1))
$(1)-doctor:
	@echo DOCTOR $(1); exit 1
endef'
  run make doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"DOCTOR fw-a"* && "$output" == *"DOCTOR fw-b"* ]]
}

@test "stop and status carry on after a part fails" {
  mkkind "$P" fake 'define kind_fake
$(call std_verb,$(1),stop,dev,Stop $(1))
$(1)-stop:
	@echo STOP $(1); exit 1
endef'
  run make stop
  [ "$status" -ne 0 ]
  [[ "$output" == *"STOP fw-a"* && "$output" == *"STOP fw-b"* ]]
}

@test "config.mk of the user is included (DOCKER_REGISTRY reaches recipes)" {
  mkdir -p "$STD_CONFIG"
  printf 'DOCKER_REGISTRY := reg.example/x\n' >"$STD_CONFIG/config.mk"
  cat >make/local.mk <<'EOF'
showreg:
	@echo REG=$$DOCKER_REGISTRY CI=$(CI_TEMPLATES_REPO) ENVCI=$$CI_TEMPLATES_REPO
EOF
  run make showreg
  [[ "$output" == *"REG=reg.example/x CI=mayankgautam-me/ci-templates ENVCI=mayankgautam-me/ci-templates"* ]]
  # GITHUB_OWNER does not move the CI templates; the pre-1.7 CI_TEMPLATES_PROJECT is ignored
  printf 'GITHUB_OWNER := acme\nCI_TEMPLATES_PROJECT := acme/ci-templates\n' >>"$STD_CONFIG/config.mk"
  run make showreg
  [[ "$output" == *"CI=mayankgautam-me/ci-templates"* ]]
  printf 'CI_TEMPLATES_REPO := acme/ci-shared\n' >>"$STD_CONFIG/config.mk"
  run make showreg
  [[ "$output" == *"CI=acme/ci-shared ENVCI=acme/ci-shared"* ]]
  # make/project.mk wins over the user config
  printf 'CI_TEMPLATES_REPO := project-org/ci-templates\n' >>make/project.mk
  run make showreg
  [[ "$output" == *"CI=project-org/ci-templates ENVCI=project-org/ci-templates"* ]]
}

@test "secrets-import: a key file with NAME=, a dotenv file with ENV=" {
  record_script make/bin/secrets.sh
  make secrets-import NAME=oldkey FILE=/tmp/old.key
  make secrets-import FILE=/tmp/.env.old ENV=staging FORCE=1
  run cat "$STUB_LOG/calls"
  [[ "${lines[0]}" == "import oldkey --file /tmp/old.key --project demo"* ]]
  [[ "${lines[1]}" == "import --file /tmp/.env.old --project demo --env staging --force"* ]]
  run make secrets-import
  [ "$status" -ne 0 ]
  [[ "$output" == *"FILE= is required"* ]]
  run make secrets-import FILE=/tmp/x
  [ "$status" -ne 0 ]
  [[ "$output" == *"NAME= is required"* ]]
}

# --- guard bypasses ----------------------------------------------------------------------------

@test "bypass (a): CONFIRM smuggled in through MAKEFLAGS in the environment is refused at parse time" {
  MAKEFLAGS='CONFIRM=production' run make deploy ENV=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not come from the make command line"* ]]
  [[ "$output" != *"DEPLOY"* ]]
  MAKEFLAGS='-- CONFIRM=production' run make erase PART=fw-a
  [ "$status" -ne 0 ]
  [[ "$output" != *"ERASE"* ]]
  MAKEFLAGS='k CONFIRM=erase' run make erase PART=fw-a
  [ "$status" -ne 0 ]
  [[ "$output" != *"ERASE"* ]]
  # typed on the command line it still works, and so does a sub-make (fan-out) that inherits it
  run make deploy ENV=production CONFIRM=production
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEPLOY cloud-api ENV=production"* ]]
}

@test "bypass (a) holds under make 4.x too" {
  command -v gmake >/dev/null 2>&1 || skip "gmake is not installed"
  MAKEFLAGS='CONFIRM=production' run gmake deploy ENV=production
  [ "$status" -ne 0 ]
  [[ "$output" != *"DEPLOY"* ]]
  run gmake deploy ENV=production CONFIRM=production
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEPLOY cloud-api ENV=production"* ]]
}

@test "bypass (b): make -i, --ignore-errors and MAKEFLAGS=i are refused, other flags are fine" {
  run make -i deploy ENV=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"ignore-errors is refused"* ]]
  [[ "$output" != *"DEPLOY"* ]]
  run make --ignore-errors erase PART=fw-a
  [ "$status" -ne 0 ]
  [[ "$output" != *"ERASE"* ]]
  run make -ki erase PART=fw-a
  [ "$status" -ne 0 ]
  MAKEFLAGS=i run make erase PART=fw-a
  [ "$status" -ne 0 ]
  [[ "$output" == *"ignore-errors is refused"* ]]
  # a project's own guard line in local.mk is protected the same way
  cat >make/local.mk <<'MK'
wipe-all:
	@$(call std_confirm,$(ENV))
	@echo WIPED
MK
  run make -i wipe-all
  [ "$status" -ne 0 ]
  [[ "$output" != *WIPED* ]]
  run make -k build
  [ "$status" -eq 0 ]
  run make --no-print-directory build PART=fw-a
  [ "$status" -eq 0 ]
}

@test "bypass (c): every guard shares its shell line with the action, none is a prerequisite" {
  local f bad
  bad="$(
    for f in "$STD_TEMPLATES"/common.mk "$STD_TEMPLATES"/kinds/*.mk; do
      awk -v F="$(basename "$f")" '
        # join recipe lines continued with a backslash, then look at each logical line
        { line = $0
          while (line ~ /\\[ \t]*$/ && (getline nxt) > 0) { sub(/\\[ \t]*$/, "", line); line = line " " nxt }
          if (line ~ /^[ \t]*#/) next
          if (line ~ /^\$\(1\)-[a-z-]*:/ && line ~ /-guard/) print F ": guard as prerequisite or target: " line
          if (line !~ /^\t/) next
          n = match(line, /std_(confirm|production_guard|remote_guard)/)
          if (n == 0) next
          rest = substr(line, RSTART + RLENGTH)
          if (rest !~ /(&&|;)/) print F ": guard alone on its line: " line }
      ' "$f"
    done
  )"
  if [ -n "$bad" ]; then
    echo "$bad" >&2
    return 1
  fi
  ! grep -rn -- '-guard' "$STD_TEMPLATES"/kinds "$STD_TEMPLATES"/common.mk | grep -v 'std_.*_guard\|# ' | grep . >&2
}

@test "a failed guard stops the action on its line even with the line's own set -e off" {
  mkkind "$P" fake 'define kind_fake
$(call std_verb,$(1),erase,firmware,Erase $(1))
$(1)-erase:
	@$$(call std_confirm,erase) && echo ERASED $(1)
endef'
  run make erase PART=fw-a
  [ "$status" -ne 0 ]
  [[ "$output" != *"ERASED"* ]]
  run make erase PART=fw-a CONFIRM=erase
  [[ "$output" == *"ERASED fw-a"* ]]
}

@test "M5: root targets that touch production refuse without CONFIRM, and run with it" {
  record_script make/bin/cf.sh
  record_script make/bin/secrets.sh
  printf '#!/bin/bash\nexit 0\n' >"$STUBS/editor-unused"
  local t
  for t in "cf-migrate" "cf-provision" "cf-secrets" "cf-secrets ROTATE=JWT_SECRET" "cf-seed" "cf-login" "cf-logout" \
    "secrets-set NAME=X" "secrets-rotate NAME=X" "secrets-edit" "secrets-import FILE=/dev/null ENV=production NAME=X"; do
    : >"$STUB_LOG/calls"
    # shellcheck disable=SC2086
    run make $t ENV=production
    [ "$status" -ne 0 ] || { echo "make $t ENV=production ran without CONFIRM"; return 1; }
    [[ "$output" == *"CONFIRM=production"* ]]
    [ ! -s "$STUB_LOG/calls" ] || { echo "make $t reached the script without CONFIRM"; return 1; }
    # a wrong value is refused as well
    # shellcheck disable=SC2086
    run make $t ENV=production CONFIRM=staging
    [ "$status" -ne 0 ]
    [ ! -s "$STUB_LOG/calls" ]
    # with the right one it reaches the script
    # shellcheck disable=SC2086
    run make $t ENV=production CONFIRM=production
    [ -s "$STUB_LOG/calls" ] || { echo "make $t ENV=production CONFIRM=production did not run"; return 1; }
  done
  # staging needs none of it
  : >"$STUB_LOG/calls"
  run make cf-migrate ENV=staging
  [ "$status" -eq 0 ]
  [ -s "$STUB_LOG/calls" ]
}

@test "M5: preview with ENV=production needs CONFIRM too" {
  mkkind "$P" cloud-worker 'define kind_cloud-worker
$(call std_verb,$(1),preview,deploy,Preview $(1))
$(1)-preview:
	@$$(call std_production_guard) && echo PREVIEW $(1) ENV=$$(ENV)
endef'
  run make preview ENV=production
  [ "$status" -ne 0 ]
  [[ "$output" != *"PREVIEW"* ]]
  run make preview ENV=production CONFIRM=production
  [[ "$output" == *"PREVIEW cloud-api ENV=production"* ]]
  run make preview ENV=staging
  [[ "$output" == *"PREVIEW cloud-api ENV=staging"* ]]
}

@test "R2_UNBACKED reaches cf.sh only when typed on the command line" {
  record_script make/bin/cf.sh
  run make cf-wipe ENV=staging CONFIRM=staging PART=cloud-api
  [ "$status" -eq 0 ]
  ! grep -q -- '--r2-unbacked' "$STUB_LOG/calls"
  : >"$STUB_LOG/calls"
  R2_UNBACKED=1 run make cf-wipe ENV=staging CONFIRM=staging PART=cloud-api
  [ "$status" -eq 0 ]
  ! grep -q -- '--r2-unbacked' "$STUB_LOG/calls"
  : >"$STUB_LOG/calls"
  run make cf-destroy ENV=staging CONFIRM=staging PART=cloud-api R2_UNBACKED=1
  [ "$status" -eq 0 ]
  grep -q -- 'destroy --project demo --env staging --dir cloud/api --r2-unbacked' "$STUB_LOG/calls"
}

@test "L3: ROTATE goes to cf.sh as one argument, never through the shell" {
  printf '#!/bin/bash\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done >>"%s/args"\n' "$STUB_LOG" >make/bin/cf.sh
  run make cf-secrets ENV=staging PART=cloud-api 'ROTATE=A B; touch pwned'
  [ "$status" -eq 0 ]
  grep -qx '\[A B; touch pwned\]' "$STUB_LOG/args"
  [ ! -e pwned ]
  run make cf-secrets ENV=staging PART=cloud-api 'ROTATE=$(touch pwned2)'
  [ ! -e pwned2 ]
}

# --- v6: help lists what the parts use, ci-local, OTA_BUCKET from the project ---------------------

# a project with firmware and hardware-like parts only (no cloud kind), the shape of command-deck
v6_no_cloud_project() {
  P2="$BATS_TEST_TMPDIR/nocloud"
  mkproject "$P2" 'PROJECT := deck
PARTS := fw:fake board:board'
  mkfakekinds "$P2"
  mkkind "$P2" board 'define kind_board
$(call std_verb,$(1),check,hardware,Check $(1))
$(1)-check:
	@echo CHECK $(1)
endef'
  cd "$P2"
}

@test "help: a project without a cloud part lists no cloudflare group and no deploy commands; ALL=1 lists them" {
  v6_no_cloud_project
  run make help
  [ "$status" -eq 0 ]
  if printf '%s\n' "$output" | grep -qx cloudflare; then echo "cloudflare group listed"; return 1; fi
  if printf '%s\n' "$output" | grep -qx deploy; then echo "deploy group listed"; return 1; fi
  for t in cf-login cf-provision promote rollback smoke test-remote preview release; do
    if printf '%s\n' "$output" | grep -Eq "^  $t "; then echo "$t listed"; return 1; fi
  done
  # what the parts use, and what every project has, stays
  [[ "$output" == *"  flash "* ]]
  [[ "$output" == *"  secrets-init "* ]]
  [[ "$output" == *"  ci-local "* ]]
  [[ "$output" == *"  check "* ]]
  [[ "$output" == *"board-check"* ]]
  [[ "$output" == *"make help ALL=1"* ]]
  # the targets still exist
  run make promote
  [[ "$output" == *"CONFIRM=production"* ]]
  run make help ALL=1
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx cloudflare
  [[ "$output" == *"  cf-login "* && "$output" == *"  promote "* && "$output" == *"  release "* ]]
}

@test "help: an OTA bucket without a cloud part lists the token commands and cf-provision, not the Worker ones" {
  v6_no_cloud_project
  printf 'OTA_BUCKET := deck-ota\n' >>make/project.mk
  run make help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx cloudflare
  [[ "$output" == *"  cf-login "* && "$output" == *"  cf-token-check "* ]]
  # cf-provision creates the bucket, cf-status checks it
  [[ "$output" == *"  cf-provision "* && "$output" == *"  cf-status "* ]]
  if printf '%s\n' "$output" | grep -Eq '^  cf-(migrate|seed|secrets|backup|wipe|destroy) '; then echo "Worker commands listed"; return 1; fi
  # a part's own bucket does the same
  sed -i.bak '/^OTA_BUCKET/d' make/project.mk
  printf 'fw_OTA_BUCKET := deck-ota\n' >>make/project.mk
  run make help
  [[ "$output" == *"  cf-login "* ]]
}

@test "help: a cloud-worker part brings the cloudflare and deploy entries; no firmware part hides flash" {
  mkproject "$P" 'PROJECT := demo
PARTS := cloud-api:cloud-worker:cloud/api'
  run make help
  [ "$status" -eq 0 ]
  [[ "$output" == *"  cf-login "* && "$output" == *"  cf-provision "* && "$output" == *"  deploy "* ]]
  if printf '%s\n' "$output" | grep -Eq '^  (flash|erase|monitor) '; then echo "firmware commands listed"; return 1; fi
}

@test "ci-local runs the named job with act on the CI workflow, lists the jobs without JOB" {
  mkdir -p .github/workflows && : >.github/workflows/checks.yml
  stub_recorder act
  stub_cmd docker 'exit 0'
  run make ci-local JOB=app-check
  [ "$status" -eq 0 ]
  [[ "$(cat "$STUB_LOG/act.argv")" == *"-W"$'\n'".github/workflows/checks.yml"* ]]
  [[ "$(cat "$STUB_LOG/act.argv")" == *"-j"$'\n'"app-check"* ]]
  : >"$STUB_LOG/act.argv"
  run make ci-local
  [ "$status" -eq 0 ]
  [[ "$(cat "$STUB_LOG/act.argv")" == *"-l"* ]]
  [[ "$output" == *"run one with make ci-local JOB=<job>"* ]]
  run make help
  [[ "$output" == *"ci-local"*"JOB=<job>"* ]]
}

@test "ci-local refuses in a git worktree, where git in the job's container cannot reach the repository" {
  mkdir -p .github/workflows && : >.github/workflows/checks.yml
  stub_recorder act
  stub_cmd docker 'exit 0'
  git init -q -b main .
  git -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git worktree add -q "$BATS_TEST_TMPDIR/wt"
  cp -R make Makefile .github "$BATS_TEST_TMPDIR/wt/"
  cd "$BATS_TEST_TMPDIR/wt"
  run make ci-local JOB=app-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"git worktree"* ]] || false
  [ ! -s "$STUB_LOG/act.argv" ]
}

@test "ci-local runs jobs as linux/amd64 like GitHub's hosted runners; CI_LOCAL_PLATFORM= uses the machine's own" {
  mkdir -p .github/workflows && : >.github/workflows/checks.yml
  stub_cmd act 'printf "%s\n" "$@" >"$STUB_LOG/act.argv"'
  stub_cmd docker 'exit 0'
  run make ci-local JOB=hardware-check
  [ "$status" -eq 0 ]
  [[ "$(cat "$STUB_LOG/act.argv")" == *"--container-architecture"$'\n'"linux/amd64"* ]]
  run make ci-local JOB=hardware-check CI_LOCAL_PLATFORM=
  [ "$status" -eq 0 ]
  [[ "$(cat "$STUB_LOG/act.argv")" != *"--container-architecture"* ]]
}

@test "ci-local refuses without act, without docker, with the daemon down, and without the workflow file" {
  mkdir -p .github/workflows && : >.github/workflows/checks.yml
  stub_cmd docker 'exit 0'
  PATH="$STUBS:/usr/bin:/bin" run make ci-local JOB=x
  [ "$status" -ne 0 ]
  [[ "$output" == *"act not found"*"brew install act"* ]]
  stub_recorder act
  rm -f "$STUBS/docker"
  PATH="$STUBS:/usr/bin:/bin" run make ci-local JOB=x
  [ "$status" -ne 0 ]
  [[ "$output" == *"docker not found"* ]]
  stub_cmd docker '[ "$1" = info ] && exit 1; exit 0'
  PATH="$STUBS:/usr/bin:/bin" run make ci-local JOB=x
  [ "$status" -ne 0 ]
  [[ "$output" == *"Docker daemon is not running"* ]]
  [ ! -s "$STUB_LOG/act.argv" ]
  stub_cmd docker 'exit 0'
  rm -rf .github
  run make ci-local JOB=x
  [ "$status" -ne 0 ]
  [[ "$output" == *"no .github/workflows/checks.yml"* ]]
  [ ! -s "$STUB_LOG/act.argv" ]
}

@test "doctor says when act is missing, and when it is there" {
  PATH="$STUBS:/usr/bin:/bin" run bash -c '. make/bin/lib.sh; doctor_project'
  [[ "$output" == *"act not found"*"make ci-local"* ]]
  stub_cmd act 'exit 0'
  run bash -c '. make/bin/lib.sh; doctor_project'
  [[ "$output" == *"ok act"* ]]
}

@test "OTA_BUCKET comes from make/project.mk; a value in config.mk is ignored with a warning" {
  printf 'OTA_BUCKET := project-bucket\n' >>make/project.mk
  printf 'show-ota:\n\t@echo OTA=$(OTA_BUCKET)\n' >make/local.mk
  run make show-ota
  [ "$status" -eq 0 ]
  [[ "$output" == *"OTA=project-bucket"* ]]
  [[ "$output" != *"ignored"* ]]
  mkdir -p "$STD_CONFIG"
  printf 'OTA_BUCKET := user-bucket\n' >"$STD_CONFIG/config.mk"
  run make show-ota
  [ "$status" -eq 0 ]
  [[ "$output" == *"OTA=project-bucket"* ]]
  [[ "$output" == *"OTA_BUCKET in"*"config.mk is ignored"*"make/project.mk"* ]]
  # a project without its own bucket does not fall back to the user's
  mkproject "$P" 'PROJECT := demo
PARTS := fw-a:fake'
  run make show-ota
  [[ "$output" == *"OTA="$'\n'* || "$output" == *"OTA=" ]]
  [[ "$output" != *"user-bucket"* ]]
}
