#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# The cloud-worker kind, run under make with stubs. Nothing touches the network, Cloudflare, ~/.secrets
# or a device: every tool (npx, curl, secrets.sh, cf.sh) is a stub that records its argv in $STUB_LOG.
# helpers.bash had not landed when this was written, so each file builds its own project under
# $BATS_TEST_TMPDIR with a stub of the contract macros (std_verb, std_extra, std_confirm, std_production_guard).

KINDS_SRC="$BATS_TEST_DIRNAME/../templates/make/kinds"

write_stub_common() {
  cat > "$1" <<'MK'
SHELL := /bin/bash
ENV ?= local
ifneq ($(filter-out local staging production,$(ENV)),)
$(error ENV must be local, staging or production)
endif
STD_BIN ?= make/bin
STD_LIB := . $(STD_BIN)/lib.sh
std_verb = $(eval STD_VERB_$(2) += $(1)-$(2))$(eval STD_HELP += $(3)|$(1)-$(2)|$(4))
std_extra = $(eval STD_HELP += $(3)|$(1)-$(2)|$(4))
std_confirm = if [ "$(origin CONFIRM)" != "command line" ] || [ "$(CONFIRM)" != "$(1)" ]; then echo "refused: CONFIRM=$(1) is needed on the make command line" >&2; exit 1; fi
std_production_guard = $(if $(filter production,$(ENV)),$(call std_confirm,production),true)
std_remote_guard = { test "$(ENV)" != local || { echo "$(1): ENV=local is not deployed, use ENV=staging or ENV=production"; exit 1; }; } && $(std_production_guard)
STD_R2_FLAG =
STD_KINDS := $(sort $(foreach p,$(PARTS),$(word 2,$(subst :, ,$(p)))))
include $(foreach k,$(STD_KINDS),make/kinds/$(k).mk)
std_name = $(word 1,$(subst :, ,$(1)))
std_kind = $(word 2,$(subst :, ,$(1)))
std_dir  = $(or $(word 3,$(subst :, ,$(1))),$(word 1,$(subst :, ,$(1))))
$(foreach p,$(PARTS),$(eval $(call kind_$(call std_kind,$(p)),$(call std_name,$(p)),$(call std_dir,$(p)))))
MK
}

write_stub_tools() {
  local t="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$t"
  cat > "$t/npx" <<'SH'
#!/usr/bin/env bash
echo "npx $*" >> "$STUB_LOG"
echo "env CLOUDFLARE_INCLUDE_PROCESS_ENV=${CLOUDFLARE_INCLUDE_PROCESS_ENV:-unset}" >> "$STUB_LOG"
case " $* " in
  *" wrangler deploy "*--dry-run*) ;;
  *" wrangler deploy "*) echo "Current Version ID: 0b1c2d3e-stage" ;;
  *" versions upload "*) echo "Version Preview URL: https://0b1c.demo.example.test" ;;
esac
exit 0
SH
  cat > "$t/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
if [ -n "${STUB_CURL_NODNS:-}" ]; then
  case " $* " in
    *dns-query*|*/resolve\?*) [ "$STUB_CURL_NODNS" = public ] && echo '{"Answer":[{"type":5,"data":"x."},{"type":1,"data":"203.0.113.7"}]}'; exit 0 ;;
    *" --resolve "*) exit 0 ;;
    *) exit 6 ;;
  esac
fi
exit "${STUB_CURL_RC:-0}"
SH
  chmod +x "$t/npx" "$t/curl"
}

write_stub_bin() {
  cat > "$1/make/bin/secrets.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
case "$cmd" in
  exec)
    env_name=""
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
      case "$1" in --env) env_name="$2"; shift 2 ;; *) shift ;; esac
    done
    shift
    echo "secrets exec --env $env_name" >> "$STUB_LOG"
    exec "$@" ;;
  with-file)
    name="$1"; shift
    [ "$1" = "--" ] && shift
    echo "secrets with-file $name" >> "$STUB_LOG"
    dir="$(mktemp -d)"; chmod 700 "$dir"
    f="$dir/value"; umask 077; printf '%s' "TOPSECRETVALUE" > "$f"
    args=()
    for a in "$@"; do if [ "$a" = "{}" ]; then args+=("$f"); else args+=("$a"); fi; done
    rc=0; "${args[@]}" || rc=$?
    rm -rf "$dir"; exit "$rc" ;;
  *) echo "secrets $cmd" >> "$STUB_LOG"; exit 0 ;;
esac
SH
  cat > "$1/make/bin/cf.sh" <<'SH'
#!/usr/bin/env bash
echo "cf $*" >> "$STUB_LOG"
SH
  chmod +x "$1/make/bin/secrets.sh" "$1/make/bin/cf.sh"
}

setup() {
  P="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$P/make/kinds" "$P/make/bin" "$P/cloud/api"
  export STUB_LOG="$BATS_TEST_TMPDIR/log"
  : > "$STUB_LOG"
  cp "$KINDS_SRC/cloud-worker.mk" "$P/make/kinds/"
  printf 'include make/project.mk\ninclude make/common.mk\n' > "$P/Makefile"
  cat > "$P/make/project.mk" <<'MK'
PROJECT := demo
PORT_BASE := 8100
PARTS := cloud-api:cloud-worker:cloud/api
cloud-api_PORT_OFFSET := 2
cloud-api_URL_staging := https://api-staging.example.test
cloud-api_URL_production := https://api.example.test
MK
  write_stub_common "$P/make/common.mk"
  write_stub_bin "$P"
  cp "$BATS_TEST_DIRNAME/../templates/make/bin/lib.sh" "$P/make/bin/"
  write_stub_tools
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset CONFIRM ROTATE OTA_BUCKET STUB_CURL_RC
}

@test "dev migrates local D1 then runs wrangler dev under secrets exec with the local env on the part port" {
  run make -C "$P" cloud-api-dev
  [ "$status" -eq 0 ]
  migrate_line=$(grep -n '^cf migrate --env local --dir cloud/api' "$STUB_LOG" | cut -d: -f1)
  dev_line=$(grep -n 'wrangler dev --env local --port 8102' "$STUB_LOG" | cut -d: -f1)
  [ -n "$migrate_line" ]
  [ -n "$dev_line" ]
  [ "$migrate_line" -lt "$dev_line" ]
  grep -q '^secrets exec --env local' "$STUB_LOG"
  grep -q '^env CLOUDFLARE_INCLUDE_PROCESS_ENV=true' "$STUB_LOG"
}

@test "dev refuses ENV=staging and starts nothing" {
  run make -C "$P" cloud-api-dev ENV=staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs locally only"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "deploy to production without CONFIRM refuses before any step runs" {
  run make -C "$P" cloud-api-deploy ENV=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=production"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "deploy to production with CONFIRM=production on the command line deploys and smokes production" {
  run make -C "$P" cloud-api-deploy ENV=production CONFIRM=production
  [ "$status" -eq 0 ]
  grep -q 'wrangler deploy --env production' "$STUB_LOG"
  grep -q 'curl .*https://api.example.test/health' "$STUB_LOG"
  [ ! -e "$P/cloud/api/.wrangler/project-standard-staging-version" ]
}

@test "smoke: a host this machine cannot resolve is checked at its public DNS address, and said (v40)" {
  run env STUB_CURL_NODNS=public make -C "$P" cloud-api-smoke ENV=production
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot resolve api.example.test yet"* ]]
  grep -q 'curl .*1.1.1.1/dns-query?name=api.example.test&type=A' "$STUB_LOG"
  grep -q 'curl .*--resolve api.example.test:443:203.0.113.7 https://api.example.test/health' "$STUB_LOG"
}

@test "smoke: a host public DNS does not know either fails, and an HTTP error is not retried through DNS (v40)" {
  run env STUB_CURL_NODNS=none make -C "$P" cloud-api-smoke ENV=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not resolve, here or in public DNS"* ]]
  ! grep -q -- '--resolve' "$STUB_LOG"
  : >"$STUB_LOG"
  run env STUB_CURL_RC=22 make -C "$P" cloud-api-smoke ENV=production
  [ "$status" -ne 0 ]
  ! grep -q 'dns-query' "$STUB_LOG"
}

@test "CONFIRM set in the environment instead of the command line does not pass the production guard" {
  run env CONFIRM=production make -C "$P" cloud-api-deploy ENV=production
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "deploy to staging records the version id and the commit for promote, then smokes staging" {
  run make -C "$P" cloud-api-deploy ENV=staging
  [ "$status" -eq 0 ]
  rec="$P/cloud/api/.wrangler/project-standard-staging-version"
  [ -f "$rec" ]
  [ "$(cat "$rec")" = "0b1c2d3e-stage unknown" ]
  grep -q 'curl .*https://api-staging.example.test/health' "$STUB_LOG"
}

@test "a failing health check fails the deploy" {
  export STUB_CURL_RC=22
  run make -C "$P" cloud-api-deploy ENV=staging
  [ "$status" -ne 0 ]
  grep -q 'wrangler deploy --env staging' "$STUB_LOG"
}

@test "promote deploys to production with the recorded staging version in the message" {
  mkdir -p "$P/cloud/api/.wrangler"
  printf '0b1c2d3e-stage unknown\n' > "$P/cloud/api/.wrangler/project-standard-staging-version"
  run make -C "$P" cloud-api-promote ENV=production CONFIRM=production
  [ "$status" -eq 0 ]
  grep -q 'wrangler deploy --env production --message promoted from staging version 0b1c2d3e-stage' "$STUB_LOG"
}

@test "promote refuses without a staging record" {
  run make -C "$P" cloud-api-promote ENV=production CONFIRM=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"no staging record"* ]]
  run ! grep -q 'wrangler deploy' "$STUB_LOG"
}

@test "promote refuses when the recorded commit is not HEAD" {
  mkdir -p "$P/cloud/api/.wrangler"
  printf '0b1c2d3e-stage some-other-commit\n' > "$P/cloud/api/.wrangler/project-standard-staging-version"
  run make -C "$P" cloud-api-promote ENV=production CONFIRM=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"deploy staging from this commit first"* ]]
  run ! grep -q 'wrangler deploy' "$STUB_LOG"
}

@test "promote without CONFIRM refuses" {
  mkdir -p "$P/cloud/api/.wrangler"
  printf '0b1c2d3e-stage unknown\n' > "$P/cloud/api/.wrangler/project-standard-staging-version"
  run make -C "$P" cloud-api-promote ENV=production
  [ "$status" -ne 0 ]
  run ! grep -q 'wrangler deploy' "$STUB_LOG"
}

@test "test-remote and rollback refuse production without CONFIRM" {
  run make -C "$P" cloud-api-test-remote ENV=production
  [ "$status" -ne 0 ]
  run make -C "$P" cloud-api-rollback ENV=production
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "wipe and destroy need CONFIRM equal to the environment" {
  run make -C "$P" cloud-api-wipe ENV=staging
  [ "$status" -ne 0 ]
  run make -C "$P" cloud-api-destroy ENV=staging CONFIRM=production
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "reset refuses anything but local" {
  run make -C "$P" cloud-api-reset ENV=staging CONFIRM=staging
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "seed refuses production and migrate on production needs CONFIRM" {
  run make -C "$P" cloud-api-seed ENV=production
  [ "$status" -ne 0 ]
  run make -C "$P" cloud-api-migrate ENV=production
  [ "$status" -ne 0 ]
  run ! grep -q '^cf ' "$STUB_LOG"
}

@test "extras delegate to cf.sh with the env and the part dir" {
  run make -C "$P" cloud-api-status ENV=staging
  [ "$status" -eq 0 ]
  grep -q '^cf status --env staging --dir cloud/api' "$STUB_LOG"
  run make -C "$P" cloud-api-secrets ENV=staging ROTATE=JWT_SECRET
  [ "$status" -eq 0 ]
  grep -q '^cf secrets --env staging --dir cloud/api --rotate JWT_SECRET' "$STUB_LOG"
}

@test "check runs the typecheck lint and vitest in the part directory" {
  run make -C "$P" cloud-api-check
  [ "$status" -eq 0 ]
  grep -q '^npx --no-install vitest run --passWithNoTests' "$STUB_LOG"
  [[ "$output" == *"lint skipped"* ]]
}

@test "a pnpm part runs its package binaries with pnpm exec, never npx" {
  printf '#!/usr/bin/env bash\necho "pnpm $*" >> "$STUB_LOG"\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/pnpm"
  chmod +x "$BATS_TEST_TMPDIR/bin/pnpm"
  : > "$P/cloud/api/pnpm-lock.yaml"
  : > "$P/cloud/api/tsconfig.json"
  run make -C "$P" cloud-api-check
  [ "$status" -eq 0 ]
  run make -C "$P" cloud-api-build
  [ "$status" -eq 0 ]
  run make -C "$P" cloud-api-dev
  [ "$status" -eq 0 ]
  grep -q '^pnpm exec tsc --noEmit' "$STUB_LOG"
  grep -q '^pnpm exec vitest run --passWithNoTests' "$STUB_LOG"
  grep -q '^pnpm exec wrangler deploy --dry-run --outdir dist --env local' "$STUB_LOG"
  grep -q '^pnpm exec wrangler dev --env local' "$STUB_LOG"
  if grep -q '^npx ' "$STUB_LOG"; then return 1; fi
}

@test "a web-pages part runs lint, typecheck, vitest and vite through pnpm exec with pnpm-lock.yaml, npx without" {
  printf '#!/usr/bin/env bash\necho "pnpm $*" >> "$STUB_LOG"\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/pnpm"
  chmod +x "$BATS_TEST_TMPDIR/bin/pnpm"
  cp "$KINDS_SRC/web-pages.mk" "$P/make/kinds/"
  printf 'PARTS += web:web-pages:cloud/web site:web-pages:cloud/site\n' >> "$P/make/project.mk"
  for w in web site; do
    mkdir -p "$P/cloud/$w"
    : > "$P/cloud/$w/vite.config.ts"
    : > "$P/cloud/$w/vitest.config.ts"
    : > "$P/cloud/$w/tsconfig.json"
    printf '{}\n' > "$P/cloud/$w/biome.json"
  done
  : > "$P/cloud/web/pnpm-lock.yaml"
  run make -C "$P" web-check web-build
  [ "$status" -eq 0 ]
  grep -q '^pnpm exec tsc --noEmit' "$STUB_LOG"
  grep -q '^pnpm exec biome check \.' "$STUB_LOG"
  grep -q '^pnpm exec vitest run --passWithNoTests' "$STUB_LOG"
  grep -q '^pnpm exec vite build' "$STUB_LOG"
  if grep -q '^npx ' "$STUB_LOG"; then return 1; fi
  : > "$STUB_LOG"
  run make -C "$P" site-check site-build
  [ "$status" -eq 0 ]
  grep -q '^npx --no-install biome check \.' "$STUB_LOG"
  grep -q '^npx --no-install vite build' "$STUB_LOG"
  if grep -q '^pnpm ' "$STUB_LOG"; then return 1; fi
}

@test "a web-pages part with wrangler.jsonc deploys as a static-assets Worker and has nothing to provision" {
  cp "$KINDS_SRC/web-pages.mk" "$P/make/kinds/"
  printf 'PARTS += web:web-pages:cloud/web site:web-pages:cloud/site\n' >> "$P/make/project.mk"
  mkdir -p "$P/cloud/web" "$P/cloud/site"
  printf '{ "name": "demo-web", "assets": { "directory": "./dist" }, "workers_dev": false }\n' > "$P/cloud/web/wrangler.jsonc"
  run make -C "$P" -n web-deploy ENV=staging
  [[ "$output" == *"wrangler deploy --env staging"* ]]
  [[ "$output" != *"pages deploy"*"--project-name demo-web"* ]]
  run make -C "$P" -n site-deploy ENV=staging
  [[ "$output" == *"pages deploy"* ]]
  run make -C "$P" web-provision ENV=staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to provision"* ]]
  # the scaffold's Pages config (pages_build_output_dir) keeps a site on Pages
  printf '{ "name": "demo-site", "pages_build_output_dir": "./dist" }\n' > "$P/cloud/site/wrangler.jsonc"
  run make -C "$P" -n site-deploy ENV=staging
  [[ "$output" == *"pages deploy"* ]]
}

@test "L8: CLOUDFLARE_INCLUDE_PROCESS_ENV is set for wrangler dev and for nothing else" {
  run make -C "$P" cloud-api-dev
  [ "$status" -eq 0 ]
  grep -q '^env CLOUDFLARE_INCLUDE_PROCESS_ENV=true' "$STUB_LOG"
  : >"$STUB_LOG"
  run make -C "$P" cloud-api-deploy ENV=staging
  [ "$status" -eq 0 ]
  run make -C "$P" cloud-api-preview ENV=staging
  run make -C "$P" cloud-api-versions ENV=staging
  run make -C "$P" cloud-api-logs ENV=staging
  run make -C "$P" cloud-api-rollback ENV=staging
  run make -C "$P" cloud-api-deploy ENV=production CONFIRM=production
  ! grep -q 'INCLUDE_PROCESS_ENV=true' "$STUB_LOG"
  grep -q 'INCLUDE_PROCESS_ENV=unset' "$STUB_LOG"
  # not in any managed file other than the dev recipe
  [ "$(grep -rl 'INCLUDE_PROCESS_ENV=true' "$KINDS_SRC" "$BATS_TEST_DIRNAME/../templates/make/common.mk" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(grep -v '^#' "$KINDS_SRC/cloud-worker.mk" | grep -c 'INCLUDE_PROCESS_ENV=true')" -eq 1 ]
  grep -v '^#' "$KINDS_SRC/cloud-worker.mk" | grep 'INCLUDE_PROCESS_ENV=true' | grep -q 'wrangler dev'
  [ "$(grep -rv '^\s*#' "$KINDS_SRC" | grep -c 'INCLUDE_PROCESS_ENV=true')" -eq 1 ]
}

@test "deploy and promote to production: the guard is in the same shell line, so make -k cannot go past it" {
  run make -C "$P" -k cloud-api-deploy ENV=production
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
  run make -C "$P" -k cloud-api-promote ENV=production
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
  run make -C "$P" cloud-api-rollback ENV=production
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
  run make -C "$P" cloud-api-secrets ENV=production 'ROTATE=A B'
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
}

# --- cf-login: the pre-filled token form (the real cf.sh, with stub secrets.sh, curl, open and xdg-open) ---

# login_project TEXT-OF-WRANGLER   a project root with make/project.mk, the real cf.sh and lib.sh, a recording
# secrets.sh, and curl/open/xdg-open stubs first on PATH. curl answers success except for paths in $STUB_DENY.
login_project() {
  L="$BATS_TEST_TMPDIR/login"
  mkdir -p "$L/make/bin" "$L/cloud/api" "$L/web" "$BATS_TEST_TMPDIR/cfbin"
  cp "$BATS_TEST_DIRNAME/../templates/make/bin/cf.sh" "$BATS_TEST_DIRNAME/../templates/make/bin/lib.sh" "$L/make/bin/"
  cat >"$L/make/bin/secrets.sh" <<'SH'
#!/usr/bin/env bash
cmd="$1"; shift
case "$cmd" in
  set) v="$(cat)"; echo "secrets set $1 $5" >> "$STUB_LOG"; printf '%s=%s\n' "$1@$5" "$v" >> "$STUB_LOG.store" ;;
  get) exit 1 ;;
  *) echo "secrets $cmd $*" >> "$STUB_LOG" ;;
esac
SH
  chmod +x "$L/make/bin/secrets.sh"
  printf '%s\n' "$1" >"$L/cloud/api/wrangler.jsonc"
  for b in open xdg-open; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n' "$b" >"$BATS_TEST_TMPDIR/cfbin/$b"
  done
  cat >"$BATS_TEST_TMPDIR/cfbin/curl" <<'SH'
#!/usr/bin/env bash
cfg="$(cat)"
url="$(printf '%s' "$cfg" | sed -n 's/^url = "\(.*\)"/\1/p')"
echo "curl $url" >> "$STUB_LOG"
for d in ${STUB_DENY:-}; do
  case "$url" in *"$d") echo '{"success":false}'; exit 0 ;; esac
done
case "$url" in
  */tokens/verify) echo '{"success":true,"result":{"status":"active","expires_on":"2030-01-01T00:00:00Z"}}' ;;
  *) echo '{"success":true,"result":[]}' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/cfbin/"*
  export PATH="$BATS_TEST_TMPDIR/cfbin:$PATH"
  printf 'pasted-token-123\n' >"$BATS_TEST_TMPDIR/tty"
  export CLOUDFLARE_ACCOUNT_ID=0123456789abcdef0123456789abcdef
  unset CLOUDFLARE_API_TOKEN CF_NO_BROWSER STUB_DENY
}

# the permissionGroupKeys of the URL in $output, decoded, as "key:type" lines
url_keys() {
  local url
  url="$(printf '%s\n' "$output" | grep -o 'https://dash.cloudflare.com/[^ ]*' | head -n1)"
  printf '%s' "$url" | sed -n 's/.*permissionGroupKeys=\([^&]*\).*/\1/p' | jq -Rr '@text | gsub("%(?<h>[0-9A-F]{2})"; ([.h | explode[] | if . < 65 then . - 48 else . - 55 end] | .[0] * 16 + .[1]) | [.] | implode) | fromjson[] | "\(.key):\(.type)"'
}

FULL_WRANGLER='{
  "name": "demo-api", // comment
  "d1_databases": [{ "binding": "DB", "database_name": "demo-local-db", "database_id": "local" }],
  "env": {
    "production": {
      "routes": [
        { "pattern": "api.example.com", "custom_domain": true },
        { "pattern": "example.org/hook/*", "zone_name": "example.org" },
      ],
      "kv_namespaces": [{ "binding": "CACHE", "id": "" }],
      "r2_buckets": [{ "binding": "FILES", "bucket_name": "demo-production-files" }],
      "queues": { "producers": [{ "binding": "Q", "queue": "demo-production-jobs" }] },
    },
  },
}'

@test "cf-login opens the pre-filled token form with every permission the bindings, routes and Pages need" {
  login_project "$FULL_WRANGLER"
  printf 'PROJECT := demo\nPARTS := \\\n  cloud-api:cloud-worker:cloud/api \\\n  site:web-pages:web\n' >"$L/make/project.mk"
  cd "$L"
  run env STD_TTY="$BATS_TEST_TMPDIR/tty" bash make/bin/cf.sh login --project demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys="*"&name=demo"* ]]
  run -0 url_keys
  [ "$output" = "$(printf '%s\n' account_settings:read workers_scripts:edit d1:edit workers_kv_storage:edit \
    workers_r2:edit queues:edit page:edit workers_routes:edit dns:edit)" ]
  run env STD_TTY="$BATS_TEST_TMPDIR/tty" CF_NO_BROWSER=1 bash make/bin/cf.sh login --project demo
  # no Workers Tail: wrangler tail works with Workers Scripts: Edit on an account token
  [[ "$output" != *"Workers Tail"* ]]
  # the link cannot preset zones: the printed text says which to pick in the form, and to set an expiry
  [[ "$output" == *'under the resources of the zone permissions (Workers Routes, DNS), choose "Specific zone"'* ]]
  [[ "$output" == *"and pick example.com example.org (routes and custom domains: api.example.com example.org)"* ]]
  [[ "$output" == *"set an expiry"* ]]
  # the browser got the same URL (open on macOS, xdg-open elsewhere), once: CF_NO_BROWSER=1 opened nothing
  [ "$(grep -cE '^(open|xdg-open) https://dash.cloudflare.com/\?to=/:account/api-tokens&permissionGroupKeys=' "$STUB_LOG")" -eq 1 ]
}

@test "cf-login for a Worker with no bindings asks for the minimal set only" {
  login_project '{ "name": "demo-api", "env": { "production": { "vars": { "A": "1" } } } }'
  printf 'PROJECT := demo\nPARTS := cloud-api:cloud-worker:cloud/api hw:hardware\n' >"$L/make/project.mk"
  cd "$L"
  run env STD_TTY="$BATS_TEST_TMPDIR/tty" CF_NO_BROWSER=1 bash make/bin/cf.sh login --project demo
  [ "$status" -eq 0 ]
  [[ "$output" != *"Specific zone"* && "$output" != *"Workers Tail"* ]]
  [[ "$output" == *"Workers Scripts: Edit"*"set an expiry"* ]]
  run -0 url_keys
  [ "$output" = "$(printf '%s\n' account_settings:read workers_scripts:edit)" ]
  ! grep -qE '^(open|xdg-open) ' "$STUB_LOG"
}

@test "cf-login for an OTA-only project (OTA_BUCKET, no Worker or Pages part) asks for Account Settings and R2 only" {
  login_project '{}'
  rm -r "$L/cloud/api"
  printf 'PROJECT := demo\nPARTS := firmware:zephyr hw:hardware app:app-xcode\nOTA_BUCKET := demo-ota\n' >"$L/make/project.mk"
  cd "$L"
  run env STD_TTY="$BATS_TEST_TMPDIR/tty" CF_NO_BROWSER=1 bash make/bin/cf.sh login --project demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workers R2 Storage: Edit"* ]]
  [[ "$output" != *"Workers Scripts"* && "$output" != *"Specific zone"* ]]
  run -0 url_keys
  [ "$output" = "$(printf '%s\n' account_settings:read workers_r2:edit)" ]
  grep -qx 'CLOUDFLARE_API_TOKEN@production=pasted-token-123' "$STUB_LOG.store"
  grep -q "^curl .*/accounts/0123456789abcdef0123456789abcdef/r2/buckets\$" "$STUB_LOG"
  # with a Worker as well, the bucket adds R2 to the Worker's set
  login_project '{ "name": "demo-api" }'
  printf 'PROJECT := demo\nPARTS := api:cloud-worker:cloud/api fw:zephyr\nOTA_BUCKET := demo-ota\n' >"$L/make/project.mk"
  run env STD_TTY="$BATS_TEST_TMPDIR/tty" CF_NO_BROWSER=1 bash make/bin/cf.sh login --project demo
  [ "$status" -eq 0 ]
  run -0 url_keys
  [ "$output" = "$(printf '%s\n' account_settings:read workers_scripts:edit workers_r2:edit)" ]
}

@test "cf-login stores the pasted token as before, never prints it, and reports permissions the token lacks" {
  login_project "$FULL_WRANGLER"
  printf 'PROJECT := demo\nPARTS := cloud-api:cloud-worker:cloud/api\n' >"$L/make/project.mk"
  cd "$L"
  run env STD_TTY="$BATS_TEST_TMPDIR/tty" CF_NO_BROWSER=1 bash make/bin/cf.sh login --project demo
  [ "$status" -eq 0 ]
  [[ "$output" != *pasted-token-123* ]]
  grep -qx 'CLOUDFLARE_API_TOKEN@staging=pasted-token-123' "$STUB_LOG.store"
  grep -qx 'CLOUDFLARE_API_TOKEN@production=pasted-token-123' "$STUB_LOG.store"
  grep -qx 'CLOUDFLARE_ACCOUNT_ID@common=0123456789abcdef0123456789abcdef' "$STUB_LOG.store"
  ! grep -q 'CLOUDFLARE_API_TOKEN@common' "$STUB_LOG.store"
  # the checks of cf-token-check run with the stored token: one probe per resource type the project uses
  for p in workers/scripts d1/database storage/kv/namespaces r2/buckets queues; do
    grep -q "^curl .*/accounts/0123456789abcdef0123456789abcdef/$p\$" "$STUB_LOG"
  done
  # a permission the token lacks: stored all the same, named, exit 1
  : >"$STUB_LOG.store"
  STUB_DENY="/r2/buckets /queues" run env STD_TTY="$BATS_TEST_TMPDIR/tty" CF_NO_BROWSER=1 bash make/bin/cf.sh login --project demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing Workers R2 Storage: Edit"* && "$output" == *"missing Queues: Edit"* ]]
  [[ "$output" != *"missing D1"* ]]
  grep -qx 'CLOUDFLARE_API_TOKEN@production=pasted-token-123' "$STUB_LOG.store"
}

@test "cf-login takes CLOUDFLARE_API_TOKEN from the environment without a prompt, a form or a browser" {
  login_project "$FULL_WRANGLER"
  printf 'PROJECT := demo\nPARTS := cloud-api:cloud-worker:cloud/api\n' >"$L/make/project.mk"
  cd "$L"
  run env CLOUDFLARE_API_TOKEN=env-token-456 STD_TTY="$BATS_TEST_TMPDIR/tty" bash make/bin/cf.sh login --project demo </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"dash.cloudflare.com/?to="* && "$output" != *env-token-456* ]]
  ! grep -qE '^(open|xdg-open) ' "$STUB_LOG"
  grep -qx 'CLOUDFLARE_API_TOKEN@staging=env-token-456' "$STUB_LOG.store"
  grep -qx 'CLOUDFLARE_API_TOKEN@production=env-token-456' "$STUB_LOG.store"
  # stdin without a terminal still works too (line 1 token), with no form either
  : >"$STUB_LOG.store"
  run bash -c 'printf "piped-token\n" | bash make/bin/cf.sh login --project demo'
  [ "$status" -eq 0 ]
  [[ "$output" != *"dash.cloudflare.com/?to="* ]]
  grep -qx 'CLOUDFLARE_API_TOKEN@staging=piped-token' "$STUB_LOG.store"
}

@test "cf.sh token-url prints the form URL and the permissions without a token, network or browser" {
  login_project "$FULL_WRANGLER"
  printf 'PROJECT := demo\nPARTS := cloud-api:cloud-worker:cloud/api\n' >"$L/make/project.mk"
  cd "$L"
  : >"$STUB_LOG"
  run bash make/bin/cf.sh token-url --project demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"&name=demo"* && "$output" == *"DNS: Edit"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "cf.sh token-url names a CF_TOKEN_PERMS permission the form cannot preset, and leaves it out of the URL" {
  login_project "$FULL_WRANGLER"
  printf 'PROJECT := demo\nPARTS := cloud-api:cloud-worker:cloud/api\nCF_TOKEN_PERMS := realtime  # the TURN app\n' >"$L/make/project.mk"
  cd "$L"
  run bash make/bin/cf.sh token-url --project demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cloudflare Realtime: Edit (add it by hand"* ]]
  local url
  url="$(printf '%s\n' "$output" | grep -m1 'dash.cloudflare.com/?to=')"
  [[ "$url" != *"realtime"* && "$url" != *"%22%22"* ]]
}

@test "cf.sh token-url names Access: Apps and Policies with CF_TOKEN_PERMS := access, and leaves it out of the URL (v36)" {
  login_project "$FULL_WRANGLER"
  printf 'PROJECT := demo\nPARTS := cloud-api:cloud-worker:cloud/api\nCF_TOKEN_PERMS := access\n' >"$L/make/project.mk"
  cd "$L"
  run bash make/bin/cf.sh token-url --project demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Access: Apps and Policies: Edit (add it by hand"* ]]
  [[ "$output" == *"Access: Service Tokens: Edit (add it by hand"* ]]
  [[ "$output" == *"Access: Organizations, Identity Providers, and Groups: Read (add it by hand"* ]]
  local url
  url="$(printf '%s\n' "$output" | grep -m1 'dash.cloudflare.com/?to=')"
  [[ "$url" != *"access"* && "$url" != *"%22%22"* ]]
}

# --- setup on demand (std_ready) -------------------------------------------------------------
# These run with the real common.mk (and its lib.sh, release.sh, toolchain.sh), which defines std_ready; secrets.sh
# and cf.sh stay the stubs above. npm and pnpm are stubs that record their argv.

ready_project() {
  local tpl="$BATS_TEST_DIRNAME/../templates/make"
  cp "$tpl/common.mk" "$P/make/common.mk"
  for f in lib.sh release.sh toolchain.sh; do cp "$tpl/bin/$f" "$P/make/bin/"; done
  cp "$KINDS_SRC/web-pages.mk" "$P/make/kinds/"
  export HOME="$BATS_TEST_TMPDIR/home" STD_CONFIG="$BATS_TEST_TMPDIR/home/.config/project-standard"
  mkdir -p "$HOME"
  printf '{"devDependencies":{"wrangler":"4"}}\n' > "$P/cloud/api/package.json"
  printf '{}\n' > "$P/cloud/api/package-lock.json"
  local t
  for t in npm pnpm; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\nexit 0\n' "$t" > "$BATS_TEST_TMPDIR/bin/$t"
    chmod +x "$BATS_TEST_TMPDIR/bin/$t"
  done
}

# line LINE-REGEX: the line number of the first log line that matches (0 when none)
logline() { local n; n=$(grep -n -m1 -E "$1" "$STUB_LOG" | cut -d: -f1); echo "${n:-0}"; }

@test "a fresh Worker part runs its setup once before the command; a ready part does not set up again" {
  ready_project
  run make -C "$P" cloud-api-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"> cloud-api: not set up yet, running make cloud-api-setup first"* ]]
  [ "$(grep -c '^npm ci' "$STUB_LOG")" -eq 1 ]
  [ "$(logline '^npm ci')" -lt "$(logline 'vitest run')" ]
  [ -f "$P/cloud/api/node_modules/.std-setup" ]
  : > "$STUB_LOG"
  run make -C "$P" cloud-api-test
  [ "$status" -eq 0 ]
  [[ "$output" != *"not set up yet"* ]]
  [ "$(grep -c '^npm ' "$STUB_LOG")" -eq 0 ]
  grep -q 'vitest run' "$STUB_LOG"
  # node_modules older than the lockfile (a pull changed it): set up again
  touch -t 200001010000 "$P/cloud/api/node_modules/.std-setup"
  : > "$STUB_LOG"
  run make -C "$P" cloud-api-check
  [ "$status" -eq 0 ]
  [ "$(grep -c '^npm ci' "$STUB_LOG")" -eq 1 ]
  # packages installed by hand count as set up (npm's own node_modules/.package-lock.json)
  rm "$P/cloud/api/node_modules/.std-setup"
  : > "$P/cloud/api/node_modules/.package-lock.json"
  : > "$STUB_LOG"
  run make -C "$P" cloud-api-build
  [ "$status" -eq 0 ]
  [ "$(grep -c '^npm ' "$STUB_LOG")" -eq 0 ]
}

@test "cloud-logs in a fresh clone installs the packages then tails under the secrets of ENV, with nothing interactive" {
  ready_project
  run make -C "$P" cloud-api-logs ENV=production
  [ "$status" -eq 0 ]
  [ "$(logline '^npm ci')" -gt 0 ]
  [ "$(logline '^npm ci')" -lt "$(logline '^secrets exec --env production')" ]
  grep -q '^npx --no-install wrangler tail --env production --format pretty' "$STUB_LOG"
  # only the part's own setup is chained: no login, no secrets prompt, no cf.sh
  [ "$(grep -c '^cf ' "$STUB_LOG")" -eq 0 ]
  [ "$(grep -c '^secrets ' "$STUB_LOG")" -eq "$(grep -c '^secrets exec' "$STUB_LOG")" ]
  # the production guard still refuses a deploy without CONFIRM, and nothing reaches wrangler deploy
  : > "$STUB_LOG"
  run make -C "$P" cloud-api-deploy ENV=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=production"* ]]
  [ "$(grep -c 'wrangler deploy' "$STUB_LOG")" -eq 0 ]
}

@test "setup, doctor, clean, distclean and version never run setup first" {
  ready_project
  local t
  for t in doctor clean distclean version; do
    : > "$STUB_LOG"
    run make -C "$P" "cloud-api-$t"
    [[ "$output" != *"not set up yet"* ]]
    [ "$(grep -c '^npm ' "$STUB_LOG")" -eq 0 ]
  done
  : > "$STUB_LOG"
  run make -C "$P" cloud-api-setup
  [ "$status" -eq 0 ]
  [[ "$output" != *"not set up yet"* ]]
  [ "$(grep -c '^npm ci' "$STUB_LOG")" -eq 1 ]
  # the internal target is not in help
  run make -C "$P" help ALL=1
  [[ "$output" != *"-ready"* ]]
}

@test "a web-pages part with package.json sets up once with its package manager; a static one never sets up" {
  ready_project
  printf 'PARTS += site:web-pages:site static:web-pages:static\n' >> "$P/make/project.mk"
  mkdir -p "$P/site" "$P/static"
  printf '{}\n' > "$P/site/package.json"
  : > "$P/site/pnpm-lock.yaml"
  : > "$P/site/vite.config.js"
  run make -C "$P" site-build
  [ "$status" -eq 0 ]
  [[ "$output" == *"> site: not set up yet, running make site-setup first"* ]]
  [ "$(logline '^pnpm install')" -gt 0 ]
  [ "$(logline '^pnpm install')" -lt "$(logline '^pnpm exec vite build')" ]
  : > "$STUB_LOG"
  run make -C "$P" site-build
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pnpm install' "$STUB_LOG")" -eq 0 ]
  grep -q '^pnpm exec vite build' "$STUB_LOG"
  : > "$STUB_LOG"
  run make -C "$P" static-build
  [ "$status" -eq 0 ]
  [[ "$output" != *"not set up yet"* ]]
  [[ "$output" == *"static site, nothing to build"* ]]
}

@test "root verbs and the cf commands chain the setup through the parts" {
  ready_project
  run make -C "$P" check
  [ "$status" -eq 0 ]
  [ "$(logline '^npm ci')" -gt 0 ]
  [ "$(logline '^npm ci')" -lt "$(logline 'vitest run')" ]
  rm -rf "$P/cloud/api/node_modules"
  : > "$STUB_LOG"
  run make -C "$P" cf-migrate-list
  [ "$status" -eq 0 ]
  [ "$(logline '^npm ci')" -gt 0 ]
  [ "$(logline '^npm ci')" -lt "$(logline '^cf migrate')" ]
  # ready: cf-status runs cf.sh only
  : > "$STUB_LOG"
  run make -C "$P" cf-status
  [ "$status" -eq 0 ]
  [ "$(grep -c '^npm ' "$STUB_LOG")" -eq 0 ]
  grep -q '^cf status' "$STUB_LOG"
}

@test "web-pages: astro.config.* makes an Astro site: astro build, astro dev on the part port, dist/ as OUT, astro check with @astrojs/check" {
  printf '#!/usr/bin/env bash\necho "pnpm $*" >> "$STUB_LOG"\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/pnpm"
  chmod +x "$BATS_TEST_TMPDIR/bin/pnpm"
  cp "$KINDS_SRC/web-pages.mk" "$P/make/kinds/"
  printf 'PARTS += site:web-pages:cloud/site\nsite_PORT_OFFSET := 4\n' >> "$P/make/project.mk"
  mkdir -p "$P/cloud/site"
  printf 'show:\n\t@echo "$(site_FRAMEWORK) $(site_OUT)"\n' > "$P/show.mk"
  # every config extension Astro reads is detected; a vite.config next to it does not make it vite
  for e in mjs js ts cjs; do
    rm -f "$P/cloud/site/"astro.config.*
    : > "$P/cloud/site/astro.config.$e"
    : > "$P/cloud/site/vite.config.ts"
    run make -C "$P" --no-print-directory -f Makefile -f show.mk show
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$output" = "astro cloud/site/dist" ] || { echo "got: $output"; false; }
  done
  rm -f "$P/cloud/site/vite.config.ts"
  : > "$P/cloud/site/pnpm-lock.yaml"
  printf '{"devDependencies": {"astro": "^5.0.0"}}\n' > "$P/cloud/site/package.json"
  run make -C "$P" site-build site-check
  [ "$status" -eq 0 ]
  grep -q '^pnpm exec astro build$' "$STUB_LOG"
  [[ "$output" == *"site: astro check skipped (@astrojs/check is not a dependency of cloud/site)"* ]]
  if grep -q 'astro check' "$STUB_LOG"; then return 1; fi
  if grep -q 'vite' "$STUB_LOG"; then return 1; fi
  : > "$STUB_LOG"
  printf '{"devDependencies": {"astro": "^5.0.0", "@astrojs/check": "^0.9.0", "typescript": "^5.0.0"}}\n' > "$P/cloud/site/package.json"
  : > "$P/cloud/site/tsconfig.json"
  run make -C "$P" site-check site-dev
  [ "$status" -eq 0 ]
  grep -q '^pnpm exec astro check$' "$STUB_LOG"
  # what the kind already did still runs: typecheck and the lint note
  grep -q '^pnpm exec tsc --noEmit' "$STUB_LOG"
  [[ "$output" == *"lint skipped"* ]]
  grep -q '^pnpm exec astro dev --port 8104 --strictPort$' "$STUB_LOG"
  # without pnpm-lock.yaml it goes through npx --no-install
  rm -f "$P/cloud/site/pnpm-lock.yaml"
  : > "$STUB_LOG"
  run make -C "$P" site-build
  [ "$status" -eq 0 ]
  grep -q '^npx --no-install astro build$' "$STUB_LOG"
}

# --- docker kind (the real common.mk, through helpers.bash) --------------------------------------

load helpers

D_A=sha256:$(printf 'a%.0s' {1..64})
D_B=sha256:$(printf 'b%.0s' {1..64})
D_C=sha256:$(printf 'c%.0s' {1..64})
D_D=sha256:$(printf 'd%.0s' {1..64})
D_E=sha256:$(printf 'e%.0s' {1..64})

# dockerproject: a docker part svc in svc/, origin on GitHub, a docker stub that records argv (and stdin of login)
dockerproject() {
  std_setup_env
  P="$BATS_TEST_TMPDIR/dproj"
  mkproject "$P" 'PROJECT := demo
PARTS := svc:docker:svc'
  cp "$KINDS_SRC/docker.mk" "$P/make/kinds/"
  cd "$P"
  mkdir -p svc
  printf 'FROM scratch\n' >svc/Dockerfile
  git init -q -b main .
  git remote add origin git@github.com:Acme-Org/Demo-Repo.git
  git add -A && git commit -q -m init
  # buildx is "set up" (the builder file exists), so build and release do not run setup first
  mkdir -p "$HOME/.docker/buildx/instances"
  : >"$HOME/.docker/buildx/instances/project-standard"
  stub_cmd docker 'printf "%s\n" "$@" >>"$STUB_LOG/docker.argv"; printf -- "--\n" >>"$STUB_LOG/docker.argv"
case "$*" in
  "buildx build --help") [ -n "${STUB_ANN:-}" ] && echo "      --annotation stringArray"; exit 0 ;;
  login*) cat >"$STUB_LOG/docker.login.stdin"; exit 0 ;;
  *"imagetools inspect --raw"*) printf "{\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[{\"digest\": \"%s\"}]}" "$STUB_CHILD"; exit 0 ;;
esac
exit 0'
}

dargv() { cat "$STUB_LOG/docker.argv" 2>/dev/null; }

@test "docker: build and release carry the OCI labels (source from the origin, revision, version on the tag, created); release annotates the index when buildx can" {
  dockerproject
  run make svc-build
  echo "$output"
  [ "$status" -eq 0 ]
  sha=$(git rev-parse HEAD)
  [[ "$(dargv)" == *$'--label\norg.opencontainers.image.source=https://github.com/acme-org/Demo-Repo\n'* ]] || false
  [[ "$(dargv)" == *$'--label\norg.opencontainers.image.revision='"$sha"$'\n'* ]] || false
  [[ "$(dargv)" == *$'--label\norg.opencontainers.image.created='* ]] || false
  [[ "$(dargv)" != *"image.version"* ]] || false
  [[ "$(dargv)" != *"--annotation"* ]] || false
  : >"$STUB_LOG/docker.argv"
  git tag svc-v1.4.0
  STUB_ANN=1 run make svc-release
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$(dargv)" == *$'--label\norg.opencontainers.image.version=1.4.0\n'* ]] || false
  [[ "$(dargv)" == *$'--annotation\nindex:org.opencontainers.image.source=https://github.com/acme-org/Demo-Repo\n'* ]] || false
  [[ "$(dargv)" == *$'-t\nghcr.io/acme-org/demo/svc:1.4.0\n'* ]] || false
  [[ "$(dargv)" == *$'--push\n'* ]] || false
  # in CI the source is the workflow's repository (DOCKER_IMAGE_SOURCE)
  : >"$STUB_LOG/docker.argv"
  DOCKER_IMAGE_SOURCE=https://github.com/acme-org/other run make svc-build
  [[ "$(dargv)" == *"org.opencontainers.image.source=https://github.com/acme-org/other"* ]] || false
}

@test "docker: setup logs docker in to ghcr.io with the gh token on stdin only, once; never in CI or for another registry" {
  dockerproject
  stub_cmd gh 'case "$*" in "auth status") exit 0 ;; "auth token") echo gho_TOPSECRET ;; "api user --jq .login") echo octo ;; *) exit 0 ;; esac'
  run make svc-setup
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker logged in to ghcr.io as octo"* ]] || false
  [ "$(cat "$STUB_LOG/docker.login.stdin")" = gho_TOPSECRET ]
  [[ "$(dargv)" == *$'login\nghcr.io\n-u\nocto\n--password-stdin\n'* ]] || false
  [[ "$(dargv)" != *TOPSECRET* ]] || false
  [[ "$output" != *TOPSECRET* ]] || false
  # already logged in: nothing to do
  printf '{"auths":{"ghcr.io":{}}}\n' >"$HOME/.docker/config.json"
  rm "$STUB_LOG/docker.login.stdin"
  run make svc-setup
  [[ "$output" == *"docker is logged in to ghcr.io"* ]] || false
  [ ! -f "$STUB_LOG/docker.login.stdin" ]
  rm "$HOME/.docker/config.json"
  CI=true run make svc-setup
  [ ! -f "$STUB_LOG/docker.login.stdin" ]
  printf 'DOCKER_REGISTRY := registry.example/team\n' >>make/project.mk
  run make svc-setup
  [ ! -f "$STUB_LOG/docker.login.stdin" ]
}

@test "docker: doctor names the registry and warns when the gh token lacks write:packages" {
  dockerproject
  stub_cmd gh 'case "$*" in "auth status") echo "  - Token scopes: '"'"'gist'"'"', '"'"'repo'"'"'"; exit 0 ;; *) exit 0 ;; esac'
  run make svc-doctor
  echo "$output"
  [[ "$output" == *"svc: registry ghcr.io/acme-org (from owner)"* ]] || false
  [[ "$output" == *"lacks the write:packages scope"*"gh auth refresh -s write:packages"* ]] || false
  stub_cmd gh 'case "$*" in "auth status") echo "  - Token scopes: '"'"'repo'"'"', '"'"'write:packages'"'"'"; exit 0 ;; *) exit 0 ;; esac'
  run make svc-doctor
  [[ "$output" == *"has write:packages"* ]] || false
  [[ "$output" != *"lacks"* ]] || false
}

@test "docker: prune-images lists old untagged and sha-only versions, keeps tags, young ones and the platform manifests of kept ones; deletes only with CONFIRM=prune" {
  dockerproject
  export STUB_CHILD=$D_C
  cat >"$STUB_LOG/versions" <<EOF
1 $D_A 2020-01-01T00:00:00Z 1.0.0,production
2 $D_B 2020-01-02T00:00:00Z 
3 $D_C 2020-01-01T00:00:00Z 
4 $D_D 2020-01-03T00:00:00Z 0123456789ab
5 $D_E 2999-01-01T00:00:00Z 
EOF
  stub_cmd gh 'printf "%s\n" "$*" >>"$STUB_LOG/gh.calls"
case "$*" in
  "api users/acme-org --jq .type") echo Organization ;;
  "api --paginate orgs/acme-org/packages/container/demo%2Fsvc/versions?per_page=100 "*) cat "$STUB_LOG/versions" ;;
  "api -X DELETE "*) exit 0 ;;
esac'
  run make svc-prune-images
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$D_B"*"untagged"*"id 2"* ]] || false
  [[ "$output" == *"$D_D"*"0123456789ab"*"id 4"* ]] || false
  [[ "$output" != *"id 1"* && "$output" != *"id 3"* && "$output" != *"id 5"* ]] || false
  [[ "$output" == *"make <part>-prune-images CONFIRM=prune"* ]] || false
  [[ "$(cat "$STUB_LOG/gh.calls")" != *DELETE* ]] || false
  [[ "$(dargv)" == *"imagetools"*"ghcr.io/acme-org/demo/svc@$D_A"* ]] || false
  run make svc-prune-images CONFIRM=yes
  [ "$status" -ne 0 ]
  [[ "$(cat "$STUB_LOG/gh.calls")" != *DELETE* ]] || false
  run make svc-prune-images CONFIRM=prune KEEP_DAYS=7
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c DELETE "$STUB_LOG/gh.calls")" -eq 2 ]
  grep -q 'api -X DELETE orgs/acme-org/packages/container/demo%2Fsvc/versions/2' "$STUB_LOG/gh.calls"
  grep -q 'api -X DELETE orgs/acme-org/packages/container/demo%2Fsvc/versions/4' "$STUB_LOG/gh.calls"
  # the script alone refuses to delete without CONFIRM=prune in its environment
  run bash make/bin/ghcr.sh prune --image ghcr.io/acme-org/demo/svc --remove
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs CONFIRM=prune"* ]] || false
}
