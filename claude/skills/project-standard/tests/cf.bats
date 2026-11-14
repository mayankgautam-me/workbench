#!/usr/bin/env bats
# cf.sh with real sops + age (throwaway keys) and stub npx/wrangler and curl. No Cloudflare, no network.

load helpers

setup() {
  std_setup_env
  mksecrets
  export PROJECT=demo
  export STD_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
  W="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$W/cloud/api/seed"
  cd "$W"
  cat >secrets.schema <<'EOF'
CLOUDFLARE_API_TOKEN   staging,production  auth,ci  no  scoped token
CLOUDFLARE_ACCOUNT_ID  common              auth,ci  no  account id
JWT_SECRET             staging,production  cf       32  HMAC key
OTHER_SECRET           staging             ci       no  not for cf
EOF
  cat >cloud/api/wrangler.jsonc <<'EOF'
// top of file comment
{
  "name": "demo-api",
  "d1_databases": [{ "binding": "DB", "database_name": "demo-local", "database_id": "local" }],
  "env": {
    "staging": {
      "name": "demo-api-staging",
      "d1_databases": [
        {
          "binding": "DB",
          "database_name": "demo-staging-db", // staging database
          "database_id": "", /* filled in by cf-provision */
        },
      ],
      "kv_namespaces": [{ "binding": "CACHE", "id": "" }],
      "r2_buckets": [{ "binding": "FILES", "bucket_name": "demo-staging-files" }],
    },
    "production": {
      "d1_databases": [{ "binding": "DB", "database_name": "demo-production-db", "database_id": "" }],
      "kv_namespaces": [{ "binding": "CACHE", "id": "" }],
    },
  },
}
EOF
  echo "INSERT INTO t VALUES (1);" >cloud/api/seed/01.sql
  cp cloud/api/wrangler.jsonc "$BATS_TEST_TMPDIR/wrangler.orig"

  # stub npx: records every call, answers the wrangler commands cf.sh uses
  cat >"$STUBS/npx" <<EOF
#!/bin/bash
echo "\$*" >>"$STUB_LOG/npx.calls"
pwd >>"$STUB_LOG/npx.cwd"
env | grep '^CLOUDFLARE_API_TOKEN=' | sed 's/=.*//' >>"$STUB_LOG/npx.tokenseen" || true
printf '%s\n' "\$@" >>"$STUB_LOG/npx.argv"
case "\$*" in
  *"secret bulk"*) cat >>"$STUB_LOG/npx.stdin" ;;
  *"d1 list"*) cat "$STUB_LOG/d1list.json" 2>/dev/null || echo '[]' ;;
  *"d1 create"*) echo 'database_id = "11111111-2222-3333-4444-555555555555"' ;;
  *"kv namespace list"*) cat "$STUB_LOG/kvlist.json" 2>/dev/null || echo '[]' ;;
  *"kv namespace create"*) echo '"id": "0123456789abcdef0123456789abcdef"' ;;
  *"r2 bucket list"*) cat "$STUB_LOG/r2list.txt" 2>/dev/null || true ;;
  *"dev-url get"*) cat "$STUB_LOG/devurl.txt" 2>/dev/null || echo "Public access via the r2.dev URL is disabled for bucket '\$5'." ;;
  *"d1 export"*) out=; prev=; for a in "\$@"; do [ "\$prev" = --output ] && out="\$a"; prev="\$a"; done; echo 'CREATE TABLE t (id);' >"\$out" ;;
  *"kv key list"*) echo '[{"name":"k1"},{"name":"key two"}]' ;;
  *"kv key get"*) printf 'value-of-%s' "\$6" ;;
  *"r2 bucket info"*) echo 'objects: 3' ;;
  *"queues list"*) cat "$STUB_LOG/queues.txt" 2>/dev/null || true ;;
esac
exit 0
EOF
  chmod +x "$STUBS/npx"

  # stub curl: config on stdin (-K -), canned answers by URL
  cat >"$STUBS/curl" <<EOF
#!/bin/bash
echo "\$*" >>"$STUB_LOG/curl.argv"
cfg="\$(cat)"
printf '%s\n--\n' "\$cfg" >>"$STUB_LOG/curl.stdin"
url="\$(printf '%s' "\$cfg" | sed -n 's/^url = "\(.*\)"/\1/p')"
case "\$url" in
  */user/tokens/verify) cat "$STUB_LOG/curl.user" 2>/dev/null || echo '{"success":true,"result":{"status":"active","expires_on":"2030-01-01T00:00:00Z"}}' ;;
  */accounts/*/tokens/verify) cat "$STUB_LOG/curl.acct" 2>/dev/null || echo '{"success":true,"result":{"status":"active"}}' ;;
  */accounts) echo '{"success":true,"result":[{"id":"0123456789abcdef0123456789abcdef"}]}' ;;
  *) echo '{"success":true,"result":[]}' ;;
esac
EOF
  chmod +x "$STUBS/curl"

  # secrets for the demo project
  sec init >/dev/null 2>&1
  # one token per project, stored for staging and production (what cf-login does)
  printf 'cf-token-one\n' | sec set CLOUDFLARE_API_TOKEN --env staging 2>/dev/null
  printf 'cf-token-one\n' | sec set CLOUDFLARE_API_TOKEN --env production 2>/dev/null
  printf '0123456789abcdef0123456789abcdef\n' | sec set CLOUDFLARE_ACCOUNT_ID --env common 2>/dev/null
  printf 'JWTVALUE-ZZ-12345\n' | sec set JWT_SECRET --env staging 2>/dev/null
  printf 'JWTPROD-ZZ-67890\n' | sec set JWT_SECRET --env production 2>/dev/null
  printf 'other-value\n' | sec set OTHER_SECRET --env staging 2>/dev/null
}

cf() { bash "$STD_TEMPLATES/bin/cf.sh" "$@"; }

@test "seed refuses production before touching anything" {
  run cf seed --env production --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"never goes into production"* ]]
  [ ! -e "$STUB_LOG/npx.calls" ]
}

@test "seed local runs the seed files against the local database, no token needed" {
  run cf seed --env local --dir cloud/api
  [ "$status" -eq 0 ]
  grep -q 'd1 execute demo-local --file .*/seed/01.sql --local' "$STUB_LOG/npx.calls"
  [ ! -s "$STUB_LOG/npx.tokenseen" ]
}

@test "seed staging runs --remote --env staging with the staging token in the environment" {
  run cf seed --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  grep -q 'd1 execute demo-staging-db --file .*/seed/01.sql --remote --env staging' "$STUB_LOG/npx.calls"
  grep -q CLOUDFLARE_API_TOKEN "$STUB_LOG/npx.tokenseen"
}

@test "migrate: --local for local, --remote and --env for staging, --list lists" {
  run cf migrate --env local --dir cloud/api
  grep -q 'd1 migrations apply demo-local --local' "$STUB_LOG/npx.calls"
  run cf migrate --env staging --dir cloud/api
  grep -q 'd1 migrations apply demo-staging-db --remote --env staging' "$STUB_LOG/npx.calls"
  run cf migrate --env staging --dir cloud/api --list
  grep -q 'd1 migrations list demo-staging-db --remote --env staging' "$STUB_LOG/npx.calls"
}

@test "wrangler runs from the part's directory" {
  cf migrate --env local --dir cloud/api
  [ "$(cd "$(tail -n1 "$STUB_LOG/npx.cwd")" && pwd -P)" = "$(cd cloud/api && pwd -P)" ]
}

@test "secrets: values go to wrangler on stdin as JSON, never in argv, only cf-marked names" {
  run cf secrets --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  grep -q 'secret bulk --env staging' "$STUB_LOG/npx.calls"
  run jq -c . "$STUB_LOG/npx.stdin"
  [ "$output" = '{"JWT_SECRET":"JWTVALUE-ZZ-12345"}' ]
  ! grep -q 'JWTVALUE' "$STUB_LOG/npx.argv"
  ! grep -q 'JWTVALUE' "$STUB_LOG/npx.calls"
  ! grep -q 'cf-token-one' "$STUB_LOG/npx.argv"
  # the token was in wrangler's environment, and no plain file was written
  grep -q CLOUDFLARE_API_TOKEN "$STUB_LOG/npx.tokenseen"
  assert_no_plain JWTVALUE-ZZ-12345 "$W" "$SECRETS_DIR" "$TMPDIR"
  assert_no_files "$TMPDIR"
}

@test "secrets: a key-file row (env keys, a name with -) is skipped, not refused (v39)" {
  printf 'android-upload-keystore  keys  app  no  the upload keystore\n' >>secrets.schema
  run cf secrets --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  run jq -c . "$STUB_LOG/npx.stdin"
  [ "$output" = '{"JWT_SECRET":"JWTVALUE-ZZ-12345"}' ]
}

@test "secrets: production gets the production value" {
  run cf secrets --env production --dir cloud/api
  [ "$status" -eq 0 ]
  run jq -r .JWT_SECRET "$STUB_LOG/npx.stdin"
  [ "$output" = "JWTPROD-ZZ-67890" ]
}

@test "secrets --rotate generates a new value, then pushes only that name" {
  local before
  before="$(sec get JWT_SECRET --env staging)"
  run cf secrets --env staging --dir cloud/api --rotate JWT_SECRET
  [ "$status" -eq 0 ]
  local after
  after="$(sec get JWT_SECRET --env staging)"
  [ "$before" != "$after" ]
  run jq -r .JWT_SECRET "$STUB_LOG/npx.stdin"
  [ "$output" = "$after" ]
}

@test "secrets: a missing value is reported by name and nothing is pushed" {
  printf 'JWT2 staging cf no x\n' >>secrets.schema
  run cf secrets --env staging --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing in the secrets for staging: JWT2"* ]]
  [ ! -e "$STUB_LOG/npx.stdin" ]
}

@test "secrets refuses local" {
  run cf secrets --env local --dir cloud/api
  [ "$status" -ne 0 ]
}

@test "provision creates the missing resources and writes ids back, comments kept, other env untouched" {
  run cf provision --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  grep -q 'd1 create demo-staging-db' "$STUB_LOG/npx.calls"
  grep -q 'kv namespace create demo-staging-cache' "$STUB_LOG/npx.calls"
  grep -q 'r2 bucket create demo-staging-files' "$STUB_LOG/npx.calls"
  run diff "$BATS_TEST_TMPDIR/wrangler.orig" cloud/api/wrangler.jsonc
  [[ "$output" == *'"database_id": "11111111-2222-3333-4444-555555555555", /* filled in by cf-provision */'* ]]
  [[ "$output" == *'"id": "0123456789abcdef0123456789abcdef"'* ]]
  # exactly two lines changed
  [ "$(diff "$BATS_TEST_TMPDIR/wrangler.orig" cloud/api/wrangler.jsonc | grep -c '^>')" -eq 2 ]
  grep -q '// staging database' cloud/api/wrangler.jsonc
  grep -q '// top of file comment' cloud/api/wrangler.jsonc
  # production and the top-level database are as they were
  grep -q '"database_name": "demo-production-db", "database_id": ""' cloud/api/wrangler.jsonc
  grep -q '"database_id": "local"' cloud/api/wrangler.jsonc
}

@test "provision is idempotent: existing resources are not created again" {
  cf provision --env staging --dir cloud/api
  echo '[{"name":"demo-staging-db","uuid":"11111111-2222-3333-4444-555555555555"}]' >"$STUB_LOG/d1list.json"
  echo '[{"title":"demo-staging-cache","id":"0123456789abcdef0123456789abcdef"}]' >"$STUB_LOG/kvlist.json"
  printf 'name:  demo-staging-files\n' >"$STUB_LOG/r2list.txt"
  : >"$STUB_LOG/npx.calls"
  cp cloud/api/wrangler.jsonc "$BATS_TEST_TMPDIR/after1"
  run cf provision --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  ! grep -q ' create ' "$STUB_LOG/npx.calls"
  diff "$BATS_TEST_TMPDIR/after1" cloud/api/wrangler.jsonc
}

@test "provision uses an existing database's id instead of creating one" {
  echo '[{"name":"demo-staging-db","uuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]' >"$STUB_LOG/d1list.json"
  run cf provision --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  ! grep -q 'd1 create' "$STUB_LOG/npx.calls"
  grep -q 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' cloud/api/wrangler.jsonc
}

@test "provision on local says there is nothing to do" {
  run cf provision --env local --dir cloud/api
  [ "$status" -eq 0 ]
  [[ "$output" == *"no provisioning"* ]]
  [ ! -e "$STUB_LOG/npx.calls" ]
}

@test "status shows missing resources, and passes after provision" {
  run cf status --env staging --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo-staging-db"*"missing"* ]]
  cf provision --env staging --dir cloud/api
  echo '[{"name":"demo-staging-db","uuid":"11111111-2222-3333-4444-555555555555"}]' >"$STUB_LOG/d1list.json"
  echo '[{"title":"demo-staging-cache","id":"0123456789abcdef0123456789abcdef"}]' >"$STUB_LOG/kvlist.json"
  printf 'name:  demo-staging-files\n' >"$STUB_LOG/r2list.txt"
  run cf status --env staging --dir cloud/api
  [ "$status" -eq 0 ]
}

@test "provision without an env block fails clearly" {
  run cf provision --env production --dir cloud/api
  [ "$status" -eq 0 ] || [[ "$output" == *"production"* ]]
  sed -i.bak 's/"production": {/"prod2": {/' cloud/api/wrangler.jsonc
  run cf provision --env production --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *'no "production" block'* ]]
}

@test "destroy refuses without CONFIRM, with the wrong CONFIRM, and for local" {
  run cf destroy --env staging --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=staging is required"* ]]
  CONFIRM=production run cf destroy --env staging --dir cloud/api
  [ "$status" -ne 0 ]
  run cf destroy --env local --dir cloud/api
  [ "$status" -ne 0 ]
  [ ! -e "$STUB_LOG/npx.calls" ]
  [ ! -d "$STD_BACKUP_DIR" ]
}

@test "destroy staging with CONFIRM backs up first, then deletes" {
  CONFIRM=staging run cf destroy --env staging --dir cloud/api --r2-unbacked
  [ "$status" -eq 0 ]
  local backup
  backup="$(ls "$STD_BACKUP_DIR/demo/"staging-*.tar.age)"
  [ -f "$backup" ]
  # the backup opens with the recovery key and holds the export
  run bash -c "age -d -i '$KEYS/recovery.txt' '$backup' | tar -t"
  [[ "$output" == *"d1-DB.sql"* ]]
  # export happened before the delete
  local exp del
  exp="$(grep -n 'd1 export' "$STUB_LOG/npx.calls" | head -n1 | cut -d: -f1)"
  del="$(grep -n 'delete --force' "$STUB_LOG/npx.calls" | head -n1 | cut -d: -f1)"
  [ "$exp" -lt "$del" ]
  grep -q 'd1 delete demo-staging-db --env staging -y' "$STUB_LOG/npx.calls"
  grep -q '/storage/kv/namespaces/' "$STUB_LOG/curl.stdin" || true
  assert_no_files "$TMPDIR"
}

@test "destroy production needs the project name typed on the terminal, and never runs in CI" {
  CONFIRM=production run tty_run wrong bash "$STD_TEMPLATES/bin/cf.sh" destroy --env production --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"you typed 'wrong'"* ]]
  ! grep -q 'delete' "$STUB_LOG/npx.calls"
  CI=true CONFIRM=production run cf destroy --env production --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"CI cannot destroy production"* ]]
  GITLAB_CI=true CONFIRM=production run cf destroy --env production --dir cloud/api
  [ "$status" -ne 0 ]
  [ ! -e "$STUB_LOG/npx.calls" ] || ! grep -q 'delete' "$STUB_LOG/npx.calls"
  GITHUB_ACTIONS=true CONFIRM=production run cf destroy --env production --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"CI cannot destroy production"* ]]
  [ ! -e "$STUB_LOG/npx.calls" ] || ! grep -q 'delete' "$STUB_LOG/npx.calls"
  CONFIRM=production run tty_run demo bash "$STD_TEMPLATES/bin/cf.sh" destroy --env production --dir cloud/api
  [ "$status" -eq 0 ]
  grep -q 'd1 delete demo-production-db --env production -y' "$STUB_LOG/npx.calls"
}

@test "destroy production: STD_TTY and CF_SH_INNER cannot answer or skip the typed confirmation" {
  printf 'demo\n' >"$BATS_TEST_TMPDIR/tty"
  # the answer is in the file STD_TTY names, the terminal gets a wrong one: the terminal wins, so it is refused
  CONFIRM=production STD_TTY="$BATS_TEST_TMPDIR/tty" run tty_run wrong bash "$STD_TEMPLATES/bin/cf.sh" destroy --env production --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"you typed 'wrong'"* ]]
  # CF_SH_INNER=1 used to skip the prompt (it is how the re-run under secrets exec is marked)
  CF_SH_INNER=1 CLOUDFLARE_API_TOKEN=x CLOUDFLARE_ACCOUNT_ID=0123456789abcdef0123456789abcdef CONFIRM=production STD_TTY="$BATS_TEST_TMPDIR/tty" \
    run tty_run wrong bash "$STD_TEMPLATES/bin/cf.sh" destroy --env production --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"you typed 'wrong'"* ]]
  ! grep -q 'delete' "$STUB_LOG/npx.calls"
}

@test "wipe refuses without CONFIRM, with CONFIRM backs up and empties" {
  run cf wipe --env staging --dir cloud/api
  [ "$status" -ne 0 ]
  [ ! -e "$STUB_LOG/npx.calls" ]
  CONFIRM=staging run cf wipe --env staging --dir cloud/api --r2-unbacked
  [ "$status" -eq 0 ]
  ls "$STD_BACKUP_DIR/demo/"staging-*.tar.age
  grep -q 'd1 execute demo-staging-db --remote' "$STUB_LOG/npx.calls"
  [[ "$output" == *"R2"*"not emptied"* ]]
}

@test "backup writes an age archive to the Backups folder" {
  run cf backup --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  ls "$STD_BACKUP_DIR/demo/"staging-*.tar.age
  [ "$(ls -ld "$STD_BACKUP_DIR/demo" | cut -c1-10)" = "drwx------" ]
}

@test "login verifies the token and stores it without putting it in argv" {
  printf 'brand-new-token\n0123456789abcdef0123456789abcdef\n' | cf login --env staging
  run sec get CLOUDFLARE_API_TOKEN --env staging
  [ "$output" = brand-new-token ]
  run sec get CLOUDFLARE_API_TOKEN --env production
  [ "$output" = brand-new-token ]
  run sec get CLOUDFLARE_ACCOUNT_ID --env staging
  [ "$output" = 0123456789abcdef0123456789abcdef ]
  ! grep -q 'brand-new-token' "$STUB_LOG/curl.argv"
  grep -q 'Bearer brand-new-token' "$STUB_LOG/curl.stdin"
}

@test "login falls back to the account token endpoint when /user says invalid" {
  echo '{"success":false,"result":{"status":"invalid"}}' >"$STUB_LOG/curl.user"
  printf 'acct-owned-token\n' | cf login --env staging
  grep -q '/accounts/0123456789abcdef0123456789abcdef/tokens/verify' "$STUB_LOG/curl.stdin"
  run sec get CLOUDFLARE_API_TOKEN --env staging
  [ "$output" = acct-owned-token ]
}

@test "login rejects a token Cloudflare calls invalid and stores nothing" {
  echo '{"success":false,"result":{"status":"invalid"}}' >"$STUB_LOG/curl.user"
  echo '{"success":false,"result":{"status":"invalid"}}' >"$STUB_LOG/curl.acct"
  run bash -c 'printf "bad-token\n" | bash "$STD_TEMPLATES/bin/cf.sh" login --env staging'
  [ "$status" -ne 0 ]
  run sec get CLOUDFLARE_API_TOKEN --env staging
  [ "$output" = cf-token-one ]
  run sec get CLOUDFLARE_API_TOKEN --env production
  [ "$output" = cf-token-one ]
}

@test "login looks the account up from the token when no id is stored or given" {
  sec unset CLOUDFLARE_ACCOUNT_ID --env common
  printf 'tok-lookup\n\n' | cf login --env staging
  run sec get CLOUDFLARE_ACCOUNT_ID --env staging
  [ "$output" = 0123456789abcdef0123456789abcdef ]
  # an id given on the second stdin line is verified against and stored
  sec unset CLOUDFLARE_ACCOUNT_ID --env common
  echo '{"success":false,"result":{"status":"invalid"}}' >"$STUB_LOG/curl.user"
  printf 'tok2\nfedcba9876543210fedcba9876543210\n' | cf login --env staging
  grep -q '/accounts/fedcba9876543210fedcba9876543210/tokens/verify' "$STUB_LOG/curl.stdin"
  run sec get CLOUDFLARE_ACCOUNT_ID --env staging
  [ "$output" = fedcba9876543210fedcba9876543210 ]
}

@test "login with an account-owned token and no account id finds the account and stores it" {
  sec unset CLOUDFLARE_ACCOUNT_ID --env common
  echo '{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}' >"$STUB_LOG/curl.user"
  run bash -c 'printf "cfat_account-owned\n\n" | bash "$STD_TEMPLATES/bin/cf.sh" login --env staging'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"token verified and stored"*"account 0123456789abcdef0123456789abcdef"* ]]
  [[ "$output" != *cfat_account-owned* ]]
  grep -q '/user/tokens/verify' "$STUB_LOG/curl.stdin"
  grep -q 'url = ".*/accounts"$' "$STUB_LOG/curl.stdin"
  grep -q '/accounts/0123456789abcdef0123456789abcdef/tokens/verify' "$STUB_LOG/curl.stdin"
  ! grep -q 'cfat_account-owned' "$STUB_LOG/curl.argv"
  run sec get CLOUDFLARE_API_TOKEN --env production
  [ "$output" = cfat_account-owned ]
  run sec get CLOUDFLARE_ACCOUNT_ID --env staging
  [ "$output" = 0123456789abcdef0123456789abcdef ]
}

@test "login with a user token and no account id verifies under /user only" {
  sec unset CLOUDFLARE_ACCOUNT_ID --env common
  printf 'user-token\n\n' | cf login --env staging
  ! grep -q '/tokens/verify' <(grep -v '/user/tokens/verify' "$STUB_LOG/curl.stdin")
  run sec get CLOUDFLARE_ACCOUNT_ID --env staging
  [ "$output" = 0123456789abcdef0123456789abcdef ]
}

@test "login with no account id still refuses a token no endpoint accepts, with the same message" {
  sec unset CLOUDFLARE_ACCOUNT_ID --env common
  echo '{"success":false,"result":{"status":"invalid"}}' >"$STUB_LOG/curl.user"
  echo '{"success":false,"result":{"status":"invalid"}}' >"$STUB_LOG/curl.acct"
  run bash -c 'printf "bad-token\n\n" | bash "$STD_TEMPLATES/bin/cf.sh" login --env staging'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cloudflare does not accept this token (status: invalid)"* ]]
  grep -q '/accounts/0123456789abcdef0123456789abcdef/tokens/verify' "$STUB_LOG/curl.stdin"
  run sec get CLOUDFLARE_API_TOKEN --env staging
  [ "$output" = cf-token-one ]
  run sec get CLOUDFLARE_ACCOUNT_ID --env staging
  [ "$status" -ne 0 ]
}

@test "login without --env stores one token for staging and production, never in common" {
  printf 'one-for-all\n' | cf login
  run sec get CLOUDFLARE_API_TOKEN --env staging
  [ "$output" = one-for-all ]
  run sec get CLOUDFLARE_API_TOKEN --env production
  [ "$output" = one-for-all ]
  # the developer keys open common and local: the token is in neither
  run sec get CLOUDFLARE_API_TOKEN --env local
  [ "$status" -ne 0 ]
  run bash -c "SOPS_AGE_KEY_FILE='$KEYS/dev.txt' sops -d --input-type dotenv --output-type dotenv '$SECRETS_DIR/demo/common.env.sops'"
  [ "$status" -eq 0 ]
  [[ "$output" != *CLOUDFLARE_API_TOKEN* ]]
  # --env production does the same
  printf 'second-token\n' | cf login --env production
  run sec get CLOUDFLARE_API_TOKEN --env staging
  [ "$output" = second-token ]
}

@test "logout removes the token from staging and production and prints the dashboard link" {
  run cf logout
  [ "$status" -eq 0 ]
  [[ "$output" == *"dash.cloudflare.com"* ]]
  run sec get CLOUDFLARE_API_TOKEN --env staging
  [ "$status" -ne 0 ]
  run sec get CLOUDFLARE_API_TOKEN --env production
  [ "$status" -ne 0 ]
  run cf whoami
  [ "$status" -eq 0 ]
  [[ "$output" == *"token:   none stored"* ]]
}

@test "whoami reports the one token" {
  run cf whoami
  [ "$status" -eq 0 ]
  [[ "$output" == *"account: 0123456789abcdef0123456789abcdef"* ]]
  [[ "$output" == *"token:   active  expires 2030-01-01T00:00:00Z  (one token, stored for staging and production)"* ]]
  ! grep -q 'cf-token-one' "$STUB_LOG/curl.argv"
}

@test "whoami says when the two copies differ, and when only one is stored" {
  printf 'other-token\n' | sec set CLOUDFLARE_API_TOKEN --env production 2>/dev/null
  run cf whoami
  [ "$status" -eq 1 ]
  [[ "$output" == *"the staging and production copies differ"* ]]
  [[ "$output" == *"staging"*"active"* && "$output" == *"production"*"active"* ]]
  [[ "$output" != *other-token* && "$output" != *cf-token-one* ]]
  sec unset CLOUDFLARE_API_TOKEN --env production >/dev/null 2>&1
  run cf whoami
  [ "$status" -eq 1 ]
  [[ "$output" == *"stored for staging only"* ]]
}

@test "token-check probes the APIs the bindings need" {
  run cf token-check --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  [[ "$output" == *"workers"* && "$output" == *"d1"* && "$output" == *"kv"* && "$output" == *"r2"* ]]
  grep -q '/accounts/0123456789abcdef0123456789abcdef/d1/database' "$STUB_LOG/curl.stdin"
  ! grep -q 'cf-token-one' "$STUB_LOG/curl.argv"
  echo '{"success":false}' >"$STUB_LOG/curl.acct"
  : >"$STUB_LOG/x"
  run cf token-check --env production --dir cloud/api
}

@test "token-check of a project with only a Pages site probes pages, and of one without Cloudflare says so" {
  mkdir -p make web
  printf 'PARTS := \\\n  web:web-pages:web\n' >make/project.mk
  run cf token-check --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok pages"* ]]
  grep -q '/accounts/0123456789abcdef0123456789abcdef/pages/projects' "$STUB_LOG/curl.stdin"
  printf 'PARTS := \\\n  firmware:zephyr\n' >make/project.mk
  run cf token-check --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cloud-worker or web-pages part"* ]]
}

@test "token-check of an OTA-only project (OTA_BUCKET, no Worker or Pages part) probes R2 and not Workers" {
  mkdir -p make
  printf 'PARTS := \\\n  firmware:zephyr \\\n  app:app-xcode\nOTA_BUCKET := fw-ota  # firmware OTA\n' >make/project.mk
  run cf token-check --env production
  [ "$status" -eq 0 ]
  [[ "$output" != *"no cloud-worker or web-pages part"* ]]
  [[ "$output" == *"ok r2"* ]]
  [[ "$output" != *"ok workers"* ]]
  grep -q '/accounts/0123456789abcdef0123456789abcdef/r2/buckets' "$STUB_LOG/curl.stdin"
  ! grep -q '/workers/scripts' "$STUB_LOG/curl.stdin"
  # a part's own bucket counts as well
  printf 'PARTS := \\\n  firmware:zephyr\nfirmware_OTA_BUCKET := fw-ota\n' >make/project.mk
  run cf token-check --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok r2"* ]]
  # an empty or commented OTA_BUCKET is no Cloudflare use
  printf 'PARTS := \\\n  firmware:zephyr\nOTA_BUCKET :=\n# OTA_BUCKET := <bucket>\n' >make/project.mk
  run cf token-check --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cloud-worker or web-pages part and no OTA_BUCKET"* ]]
}

@test "token-check probes realtime when make/project.mk sets CF_TOKEN_PERMS" {
  mkdir -p make
  printf 'PARTS := \\\n  api:cloud-worker:cloud/api\nCF_TOKEN_PERMS := realtime\n' >make/project.mk
  run cf token-check --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok realtime"* ]]
  grep -q '/accounts/0123456789abcdef0123456789abcdef/calls/turn_keys' "$STUB_LOG/curl.stdin"
}

@test "token-check probes Access too with CF_TOKEN_PERMS := realtime access (v36: one token)" {
  mkdir -p make
  printf 'PARTS := \\\n  api:cloud-worker:cloud/api\nCF_TOKEN_PERMS := realtime access\n' >make/project.mk
  run cf token-check --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok realtime"* ]]
  [[ "$output" == *"ok access"* ]]
  [[ "$output" == *"ok access_tokens"* ]]
  [[ "$output" == *"ok access_org"* ]]
  grep -q '/accounts/0123456789abcdef0123456789abcdef/access/apps' "$STUB_LOG/curl.stdin"
  grep -q '/accounts/0123456789abcdef0123456789abcdef/access/service_tokens' "$STUB_LOG/curl.stdin"
  grep -q '/accounts/0123456789abcdef0123456789abcdef/access/organizations' "$STUB_LOG/curl.stdin"
}

@test "token-check without a remote env checks the production bindings, and fails when the copies differ" {
  run cf token-check --env local --dir cloud/api
  [ "$status" -eq 0 ]
  [[ "$output" == *"production copy"* ]]
  [[ "$output" == *"token   active"* ]]
  printf 'other-token\n' | sec set CLOUDFLARE_API_TOKEN --env staging 2>/dev/null
  run cf token-check --env production --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"staging copy of the token differs"* ]]
  [[ "$output" != *other-token* ]]
  # CI keys open one environment each: no comparison there
  CI=true run cf token-check --env production --dir cloud/api
  [ "$status" -eq 0 ]
}

@test "one unlock per command: staging commands re-run themselves once under secrets exec" {
  : >"$STUB_LOG/security.calls"
  cf migrate --env staging --dir cloud/api
  run cat "$STUB_LOG/npx.calls"
  [ "${#lines[@]}" -eq 1 ]
}

@test "the jsonc reader copes with comments, trailing commas and strings holding // or /*" {
  cat >cloud/api/wrangler.jsonc <<'EOF'
{
  /* block
     comment */
  "env": {
    "staging": {
      "vars": { "URL": "https://x.example/a//b", "G": "/* not a comment */" },
      "d1_databases": [ { "binding": "DB", "database_name": "demo-staging-db", "database_id": "", }, ],
    },
  },
}
EOF
  run cf status --env staging --dir cloud/api
  [[ "$output" == *"demo-staging-db"* ]]
}

# --- security fixes ---------------------------------------------------------------------------------

@test "backup holds every KV value, not only the key list" {
  run cf backup --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  local backup out="$BATS_TEST_TMPDIR/restore"
  backup="$(ls "$STD_BACKUP_DIR/demo/"staging-*.tar.age)"
  mkdir -p "$out"
  age -d -i "$KEYS/recovery.txt" "$backup" | tar -x -C "$out"
  [ "$(cat "$out/kv-CACHE.values/0")" = "value-of-k1" ]
  [ "$(cat "$out/kv-CACHE.values/1")" = "value-of-key two" ]
  jq -e 'length == 2' "$out/kv-CACHE.json" >/dev/null
  rm -rf "$out"
}

@test "backups are encrypted to the Secure Enclave and recovery keys, never the developer key" {
  run cf backup --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  local backup
  backup="$(ls "$STD_BACKUP_DIR/demo/"staging-*.tar.age)"
  age -d -i "$KEYS/se.txt" "$backup" >/dev/null
  age -d -i "$KEYS/recovery.txt" "$backup" >/dev/null
  run age -d -i "$KEYS/dev.txt" "$backup"
  [ "$status" -ne 0 ]
}

@test "wipe and destroy refuse while R2 objects are not in the backup, and say how to go on" {
  CONFIRM=staging run cf wipe --env staging --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"R2 objects cannot be backed up"* && "$output" == *"R2_UNBACKED=1"* ]]
  CONFIRM=staging run cf destroy --env staging --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"R2_UNBACKED=1"* ]]
  # nothing was exported, emptied or deleted, and no backup was written
  [ ! -e "$STUB_LOG/npx.calls" ] || ! grep -q 'export\|delete\|execute' "$STUB_LOG/npx.calls"
  [ ! -d "$STD_BACKUP_DIR" ]
}

@test "wipe and destroy refuse a resource name that does not start with PROJECT-ENV" {
  sed -i.bak 's/"demo-staging-db"/"demo-production-db"/; s/database_name": "demo-staging-db"/database_name": "other-db"/' cloud/api/wrangler.jsonc
  sed -i.bak 's/"database_name": "demo-staging-db"/"database_name": "demo-production-db"/' cloud/api/wrangler.jsonc
  CONFIRM=staging run cf wipe --env staging --dir cloud/api --r2-unbacked
  [ "$status" -ne 0 ]
  [[ "$output" == *"not starting with demo-staging"* && "$output" == *"d1:demo-production-db"* ]]
  CONFIRM=staging run cf destroy --env staging --dir cloud/api --r2-unbacked
  [ "$status" -ne 0 ]
  [ ! -d "$STD_BACKUP_DIR" ]
  # a Worker name of another environment is refused too
  cp "$BATS_TEST_TMPDIR/wrangler.orig" cloud/api/wrangler.jsonc
  sed -i.bak 's/"name": "demo-api-staging"/"name": "demo-api-production"/' cloud/api/wrangler.jsonc
  CONFIRM=staging run cf wipe --env staging --dir cloud/api --r2-unbacked
  [ "$status" -ne 0 ]
  [[ "$output" == *"Worker name"* ]]
}

@test "an account id that is not 32 hex characters is refused before it reaches a URL or a curl config" {
  run bash -c "printf 'tok\n' | CLOUDFLARE_ACCOUNT_ID='abc\"; url = \"https://evil.example' bash '$STD_TEMPLATES/bin/cf.sh' login --env staging"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid Cloudflare account id"* ]]
  [ ! -e "$STUB_LOG/curl.stdin" ]
  CLOUDFLARE_ACCOUNT_ID=short run cf whoami
  [ "$status" -ne 0 ]
}

@test "a token with a quote, backslash or line break never gets into a curl config" {
  run bash -c "printf 'tok\"en\n' | bash '$STD_TEMPLATES/bin/cf.sh' login --env staging"
  [ "$status" -ne 0 ]
  [ ! -e "$STUB_LOG/curl.stdin" ] || ! grep -q 'tok"en' "$STUB_LOG/curl.stdin"
  # the helper itself
  run bash -c 'eval "$(sed -n "/^cfg_safe()/,/^}/p" "$1")"; cfg_safe ok-value && ! cfg_safe "a\"b" && ! cfg_safe "a\\b" && ! cfg_safe "$(printf "a\nb")"' _ "$STD_TEMPLATES/bin/cf.sh"
  [ "$status" -eq 0 ]
}

@test "secrets: a schema name that is not a plain variable name is refused" {
  printf 'BAD-NAME  staging  cf  no  x\n' >>secrets.schema
  run cf secrets --env staging --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad name"* ]]
  [ ! -e "$STUB_LOG/npx.stdin" ]
  run cf secrets --env staging --dir cloud/api --rotate 'X Y'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid secret name"* ]]
}

# --- v3: queues, production-only parts, Durable Objects ------------------------------------------

# a staging block with a producer, a consumer of another queue and dead-letter queues
queue_config() {
  cat >cloud/api/wrangler.jsonc <<'JSON'
{
  "name": "demo-api",
  "env": {
    "staging": {
      "name": "demo-api-staging",
      "queues": {
        "producers": [{ "binding": "JOBS", "queue": "demo-staging-jobs" }],
        "consumers": [
          { "queue": "demo-staging-jobs", "dead_letter_queue": "demo-staging-jobs-dlq" },
          { "queue": "demo-staging-events", "dead_letter_queue": "demo-staging-jobs-dlq" },
          { "queue": "demo-staging-mail", "dead_letter_queue": "demo-staging-jobs" },
        ],
      },
    },
  },
}
JSON
}

@test "provision creates producer, consumer-only and dead-letter queues, each once" {
  queue_config
  run cf provision --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  [ "$(grep -c 'queues create demo-staging-jobs$' "$STUB_LOG/npx.calls")" -eq 1 ]
  [ "$(grep -c 'queues create demo-staging-jobs-dlq$' "$STUB_LOG/npx.calls")" -eq 1 ]
  [ "$(grep -c 'queues create demo-staging-events$' "$STUB_LOG/npx.calls")" -eq 1 ]
  [ "$(grep -c 'queues create demo-staging-mail$' "$STUB_LOG/npx.calls")" -eq 1 ]
  [ "$(grep -c 'queues create' "$STUB_LOG/npx.calls")" -eq 4 ]
}

@test "status lists dead-letter queues, and an existing dead-letter queue does not hide a missing main queue" {
  queue_config
  # wrangler's table: only the dead-letter queue exists
  printf '%s\n' '│ id   │ name                  │ producers │' '│ 0f1e │ demo-staging-jobs-dlq │ 0         │' >"$STUB_LOG/queues.txt"
  run cf status --env staging --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"(dead-letter)"*"demo-staging-jobs-dlq"*"ok"* ]]
  [[ "$output" == *"JOBS"*"demo-staging-jobs "*"missing"* ]]
  [[ "$output" == *"(consumer)"*"demo-staging-events"*"missing"* ]]
  : >"$STUB_LOG/npx.calls"
  run cf provision --env staging --dir cloud/api
  grep -q 'queues create demo-staging-jobs$' "$STUB_LOG/npx.calls"
  ! grep -q 'queues create demo-staging-jobs-dlq' "$STUB_LOG/npx.calls"
}

@test "destroy deletes dead-letter queues too, and refuses one named for another environment" {
  queue_config
  CONFIRM=staging run cf destroy --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  grep -q 'queues delete demo-staging-jobs-dlq' "$STUB_LOG/npx.calls"
  grep -q 'queues delete demo-staging-events' "$STUB_LOG/npx.calls"
  queue_config
  sed -i.bak 's/"dead_letter_queue": "demo-staging-jobs-dlq"/"dead_letter_queue": "demo-production-dlq"/' cloud/api/wrangler.jsonc
  : >"$STUB_LOG/npx.calls"
  CONFIRM=staging run cf wipe --env staging --dir cloud/api
  [ "$status" -ne 0 ]
  [[ "$output" == *"queue:demo-production-dlq"* ]]
  ! grep -q 'delete\|execute' "$STUB_LOG/npx.calls"
}

@test "a production-only part: staging commands are refused before any unlock, production works" {
  cat >cloud/api/wrangler.jsonc <<'JSON'
{
  "name": "legacy-api",
  "d1_databases": [{ "binding": "DB", "database_name": "legacy-local", "database_id": "local" }],
  "env": {
    "production": {
      "name": "legacy-api",
      "d1_databases": [{ "binding": "DB", "database_name": "legacy-db", "database_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }],
    },
  },
}
JSON
  : >"$STUB_LOG/security.calls"
  for sub in migrate secrets provision status backup; do
    run cf "$sub" --env staging --dir cloud/api
    [ "$status" -ne 0 ]
    [[ "$output" == *"production-only"* ]] || { echo "$sub: $output"; return 1; }
  done
  [ ! -e "$STUB_LOG/npx.calls" ]
  run cf migrate --env production --dir cloud/api
  [ "$status" -eq 0 ]
  grep -q 'd1 migrations apply legacy-db --remote --env production' "$STUB_LOG/npx.calls"
  run cf envs --dir cloud/api
  [ "$output" = production ]
}

@test "backup says plainly that Durable Object storage is not in it" {
  cat >cloud/api/wrangler.jsonc <<'JSON'
{
  "name": "demo-api",
  "env": {
    "staging": {
      "name": "demo-api-staging",
      "durable_objects": { "bindings": [{ "name": "ROOMS", "class_name": "Room" }] },
    },
  },
}
JSON
  run cf backup --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  [[ "$output" == *"Durable Object storage is NOT in this backup"* ]]
}

@test "a part with pnpm-lock.yaml runs wrangler with pnpm exec in the part dir, never npx" {
  cat >"$STUBS/pnpm" <<EOF
#!/bin/bash
echo "\$*" >>"$STUB_LOG/pnpm.calls"
pwd >>"$STUB_LOG/pnpm.cwd"
exit 0
EOF
  chmod +x "$STUBS/pnpm"
  : >cloud/api/pnpm-lock.yaml
  run cf migrate --env local --dir cloud/api
  [ "$status" -eq 0 ]
  grep -q '^exec wrangler d1 migrations apply demo-local --local' "$STUB_LOG/pnpm.calls"
  grep -q '/cloud/api$' "$STUB_LOG/pnpm.cwd"
  [ ! -e "$STUB_LOG/npx.calls" ]
}

@test "backup, wipe and destroy reach a D1 by name through the env, not the local top level" {
  run cf backup --env staging --dir cloud/api
  [ "$status" -eq 0 ]
  grep -q 'd1 export demo-staging-db --remote --env staging --output' "$STUB_LOG/npx.calls"
  ! grep -E 'd1 (export|execute|delete) [^ ]+ --remote( |$)' "$STUB_LOG/npx.calls" | grep -qv -- '--env'
}

# --- the OTA bucket (make/project.mk OTA_BUCKET / <part>_OTA_BUCKET, cf.sh provision-ota and status-ota) ---

ota_project() { # project.mk lines after PARTS (firmware and an app, no Worker or Pages part)
  mkdir -p make
  printf 'PROJECT := demo\nPARTS := \\\n  firmware:zephyr \\\n  app:app-xcode\n%s\n' "$1" >make/project.mk
}

@test "provision-ota of an OTA-only project creates the bucket with npx --yes wrangler@4 from the project root" {
  ota_project 'OTA_BUCKET := demo-ota  # firmware OTA'
  run cf provision-ota --project demo --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"created R2 OTA bucket demo-ota"* ]]
  [ "$(grep -c '^--yes wrangler@4 r2 bucket list$' "$STUB_LOG/npx.calls")" -eq 1 ]
  grep -qx -- '--yes wrangler@4 r2 bucket create demo-ota' "$STUB_LOG/npx.calls"
  grep -q CLOUDFLARE_API_TOKEN "$STUB_LOG/npx.tokenseen"
  [ "$(cd "$(tail -n1 "$STUB_LOG/npx.cwd")" && pwd -P)" = "$(pwd -P)" ]
  # private unless OTA_PUBLIC asks: one line says how, and the r2.dev URL is never touched
  [[ "$output" == *"R2 OTA bucket demo-ota is private: set OTA_PUBLIC := r2dev in make/project.mk"* ]]
  ! grep -q 'dev-url' "$STUB_LOG/npx.calls"
}

@test "provision-ota reports an existing bucket and does not create it again" {
  ota_project 'OTA_BUCKET := demo-ota'
  printf 'name:  other\ncreation_date: x\nname:  demo-ota\n' >"$STUB_LOG/r2list.txt"
  run cf provision-ota --project demo --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"R2 OTA bucket demo-ota exists"* ]]
  ! grep -q 'bucket create' "$STUB_LOG/npx.calls"
}

@test "provision-ota counts each <part>_OTA_BUCKET, creates a bucket named twice once, skips make references" {
  ota_project 'OTA_BUCKET := demo-ota
firmware_OTA_BUCKET := demo-ota
app_OTA_BUCKET ?= demo-app-ota
other_OTA_BUCKET = $(OTA_BUCKET)
# OTA_BUCKET := <bucket>'
  run cf provision-ota --project demo --env staging
  [ "$status" -eq 0 ]
  [ "$(grep -c 'r2 bucket list' "$STUB_LOG/npx.calls")" -eq 1 ]
  [ "$(grep -c 'r2 bucket create demo-ota$' "$STUB_LOG/npx.calls")" -eq 1 ]
  [ "$(grep -c 'r2 bucket create demo-app-ota$' "$STUB_LOG/npx.calls")" -eq 1 ]
  [ "$(grep -c 'bucket create' "$STUB_LOG/npx.calls")" -eq 2 ]
}

@test "provision-ota with OTA_PUBLIC := r2dev turns the r2.dev URL on and prints it" {
  ota_project 'OTA_BUCKET := demo-ota
OTA_PUBLIC := r2dev'
  printf 'name:  demo-ota\n' >"$STUB_LOG/r2list.txt"
  echo "Public access via the r2.dev URL is enabled at https://pub-0123abcd.r2.dev." >"$STUB_LOG/devurl.txt"
  run cf provision-ota --project demo --env production
  [ "$status" -eq 0 ]
  grep -qx -- '--yes wrangler@4 r2 bucket dev-url enable demo-ota -y' "$STUB_LOG/npx.calls"
  [[ "$output" == *"R2 OTA bucket demo-ota is public at https://pub-0123abcd.r2.dev"* ]]
  [[ "$output" != *"is private"* ]]
}

@test "provision-ota refuses an OTA_PUBLIC it does not know and a bucket name R2 would refuse, before wrangler" {
  ota_project 'OTA_BUCKET := demo-ota
OTA_PUBLIC := yes'
  run cf provision-ota --project demo --env staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"OTA_PUBLIC := yes"*"r2dev"* ]]
  ota_project 'OTA_BUCKET := Demo_OTA'
  run cf provision-ota --project demo --env staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid OTA bucket name"* ]]
  [ ! -e "$STUB_LOG/npx.calls" ]
}

@test "provision-ota on local creates nothing remote, and a project without an OTA bucket does nothing" {
  ota_project 'OTA_BUCKET := demo-ota'
  run cf provision-ota --project demo --env local
  [ "$status" -eq 0 ]
  [[ "$output" == *"local needs no OTA bucket"* ]]
  ota_project '# OTA_BUCKET := <bucket>'
  run cf provision-ota --project demo --env staging
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$STUB_LOG/npx.calls" ]
}

@test "provision-ota in a project with a Worker uses the Worker's installed wrangler in its dir" {
  mkdir -p make cloud/api/node_modules/.bin
  printf '#!/bin/sh\n' >cloud/api/node_modules/.bin/wrangler
  chmod +x cloud/api/node_modules/.bin/wrangler
  printf 'PROJECT := demo\nPARTS := api:cloud-worker:cloud/api firmware:zephyr\nOTA_BUCKET := demo-ota\n' >make/project.mk
  run cf provision-ota --project demo --env staging
  [ "$status" -eq 0 ]
  grep -qx -- '--no-install wrangler r2 bucket create demo-ota' "$STUB_LOG/npx.calls"
  [ "$(cd "$(tail -n1 "$STUB_LOG/npx.cwd")" && pwd -P)" = "$(cd cloud/api && pwd -P)" ]
}

@test "status-ota shows the OTA bucket, missing or there, and whether its r2.dev URL is on" {
  ota_project 'firmware_OTA_BUCKET := demo-ota'
  run cf status-ota --project demo --env staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"(OTA)"*"demo-ota"*"missing"* ]]
  printf 'name:  demo-ota\n' >"$STUB_LOG/r2list.txt"
  run cf status-ota --project demo --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"demo-ota"*"ok, r2.dev off"* ]]
  echo "Public access via the r2.dev URL is enabled at https://pub-0123abcd.r2.dev." >"$STUB_LOG/devurl.txt"
  run cf status-ota --project demo --env staging
  [[ "$output" == *"ok, r2.dev on: https://pub-0123abcd.r2.dev"* ]]
}

@test "destroy never deletes the shared OTA bucket" {
  mkdir -p make
  printf 'PROJECT := demo\nPARTS := api:cloud-worker:cloud/api\nOTA_BUCKET := demo-ota\n' >make/project.mk
  CONFIRM=staging run cf destroy --env staging --dir cloud/api --r2-unbacked
  [ "$status" -eq 0 ]
  ! grep -q 'demo-ota' "$STUB_LOG/npx.calls"
}
