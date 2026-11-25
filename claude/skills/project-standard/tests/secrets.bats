#!/usr/bin/env bats
# secrets.sh with real sops + age and throwaway keys. Never touches the real ~/.secrets, Keychain or
# Secure Enclave: SECRETS_DIR and STD_CONFIG live in $BATS_TEST_TMPDIR, `security` is a stub, and the
# "Secure Enclave" identity is a plain age key file.

load helpers

setup() {
  std_setup_env
  mksecrets
  export PROJECT=demo
  W="$BATS_TEST_TMPDIR/work"
  mkdir -p "$W"
  cd "$W"
  cat >secrets.schema <<'EOF'
# NAME            envs                      used-by   gen   description
JWT_SECRET        local,staging,production  cf        32    HMAC key for sessions
API_KEY           staging                   cf        no    third party key
SHARED_URL        common                    cf        no    shared url
mcuboot           keys                      firmware  ed25519  signing key
EOF
}

enc() { # decrypt a file of the secrets repo with an identity file; prints plain text
  SOPS_AGE_KEY_FILE="$1" sops --decrypt --input-type "${3:-dotenv}" --output-type "${3:-dotenv}" "$SECRETS_DIR/$2"
}

full_setup() {
  sec init --gen
  printf 'api-key-value\n' | sec set API_KEY --env staging
  printf 'https://x.example\n' | sec set SHARED_URL --env common
}

@test "init --gen creates encrypted files, .sops.yaml and a hook-protected repo" {
  run sec init --gen
  [ "$status" -eq 0 ]
  [ -f "$SECRETS_DIR/.sops.yaml" ]
  [ -f "$SECRETS_DIR/demo/local.env.sops" ]
  [ -f "$SECRETS_DIR/demo/staging.env.sops" ]
  [ -f "$SECRETS_DIR/demo/production.env.sops" ]
  [ -f "$SECRETS_DIR/demo/keys/mcuboot.sops" ]
  grep -q 'JWT_SECRET=ENC\[' "$SECRETS_DIR/demo/production.env.sops"
  grep -q '"data": "ENC\[' "$SECRETS_DIR/demo/keys/mcuboot.sops"
  # the guard lives in the repo's own .git/hooks, never in a tracked folder
  [ "$(git -C "$SECRETS_DIR" config core.hooksPath)" = "$SECRETS_DIR/.git/hooks" ]
  [ -x "$SECRETS_DIR/.git/hooks/pre-commit" ]
  [ ! -e "$SECRETS_DIR/.githooks" ]
  # the ones without gen are reported, not invented
  [[ "$output" == *"missing API_KEY (staging)"* ]]
  # committed and pushed to the bare remote
  [ -n "$(git -C "$SECRETS_DIR" log --oneline)" ]
  [ -n "$(git --git-dir="$SECRETS_REMOTE" log --oneline main)" ]
}

@test ".sops.yaml follows the recipient table (production without dev, local with dev)" {
  sec init --gen
  run cat "$SECRETS_DIR/.sops.yaml"
  # production rule lists se and recovery only
  local prod
  prod="$(awk '/production\\.env/{f=1} f' "$SECRETS_DIR/.sops.yaml")"
  [[ "$prod" == *"$SE_PUB"* && "$prod" == *"$REC_PUB"* ]]
  [[ "$prod" != *"$DEV_PUB"* ]]
  local loc
  loc="$(awk '/local\\.env/{f=1} /staging/{f=0} f' "$SECRETS_DIR/.sops.yaml")"
  [[ "$loc" == *"$DEV_PUB"* ]]
}

@test "set / get / list / check round trip" {
  full_setup
  run sec list
  [ "$status" -eq 0 ]
  [[ "$output" == *"API_KEY"*"staging"*"present"* ]]
  [[ "$output" != *"api-key-value"* ]]
  run sec get API_KEY --env staging
  [ "$output" = "api-key-value" ]
  run sec get SHARED_URL --env staging
  [ "$output" = "https://x.example" ]
  run sec check
  [ "$status" -eq 0 ]
}

@test "set refuses an empty value and a bad name; the value never reaches argv or disk" {
  sec init
  run sec set 'bad name' --env staging </dev/null
  [ "$status" -ne 0 ]
  run bash -c 'printf "" | bash "$STD_TEMPLATES/bin/secrets.sh" set API_KEY --env staging'
  [ "$status" -ne 0 ]
  printf 'TOPSECRETMARKER9\n' | sec set API_KEY --env staging
  assert_no_plain TOPSECRETMARKER9 "$SECRETS_DIR" "$W" "$TMPDIR"
  assert_no_files "$TMPDIR"
}

@test "set takes multi-line values from stdin" {
  sec init
  printf 'line1\nline2\nline3\n' | sec set MULTI --env local
  run sec exec --env local -- bash -c 'printf "%s" "$MULTI"'
  [ "$status" -eq 0 ]
  [ "$output" = $'line1\nline2\nline3' ]
}

@test "check reports the names the schema expects but the files lack" {
  sec init
  run sec check
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing: API_KEY (staging)"* ]]
  [[ "$output" == *"missing: SHARED_URL (common)"* ]]
  [[ "$output" == *"missing key: mcuboot"* ]]
}

@test "check: a missing row whose description starts with optional: is a warning, not a problem (doctor passes)" {
  cat >>secrets.schema <<'EOF'
APPLE_SIGNING_IDENTITY production app      no    optional: the Developer ID identity
appstore-api-key  keys                      app       no    optional: the App Store Connect API key
NOT_OPTIONAL      staging                   app       no    says optional: later, so it is required
EOF
  full_setup
  run sec check
  [ "$status" -ne 0 ]
  [[ "$output" == *"optional, not set: APPLE_SIGNING_IDENTITY (production)"* ]]
  [[ "$output" == *"optional key not set: appstore-api-key"* ]]
  [[ "$output" != *"missing: APPLE_SIGNING_IDENTITY"* && "$output" != *"missing key: appstore-api-key"* ]]
  [[ "$output" == *"missing: NOT_OPTIONAL (staging)"* ]]
  [[ "$output" == *"1 problem(s)"* ]]
  printf 'x\n' | sec set NOT_OPTIONAL --env staging
  run sec check
  [ "$status" -eq 0 ]
  [[ "$output" == *"optional, not set: APPLE_SIGNING_IDENTITY (production)"* ]]
  [[ "$output" == *"look complete"* ]]
  run sec list
  [[ "$output" == *"APPLE_SIGNING_IDENTITY"*"production"*"not set (optional)"* ]]
  [[ "$output" == *"appstore-api-key"*"keys"*"not set (optional)"* ]]
  # init does not count the optional ones as missing
  run sec init
  [ "$status" -eq 0 ]
  [[ "$output" == *"optional APPLE_SIGNING_IDENTITY (production) not set"* ]]
  [[ "$output" != *"missing APPLE_SIGNING_IDENTITY"* && "$output" != *"value(s) still missing"* ]]
}

@test "exec: common plus env reach the command, the env wins over common" {
  full_setup
  printf 'from-env\n' | sec set SHARED_URL --env staging
  run sec exec --env staging -- bash -c 'echo "$API_KEY|$SHARED_URL"'
  [ "$status" -eq 0 ]
  [ "$output" = "api-key-value|from-env" ]
}

@test "exec for local uses only the dev identity (no Secure Enclave)" {
  full_setup
  printf 'not an identity\n' >"$STD_CONFIG/age/se.txt"
  : >"$STUB_LOG/security.calls"
  run sec exec --env local -- bash -c 'test -n "$JWT_SECRET" && echo ok-local'
  [ "$status" -eq 0 ]
  [ "$output" = ok-local ]
  grep -q find-generic-password "$STUB_LOG/security.calls"
  # staging needs the SE identity, which is broken now
  run sec exec --env staging -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot decrypt"* ]]
}

@test "exec for staging and production uses the SE identity, never the Keychain" {
  full_setup
  : >"$STUB_LOG/security.calls"
  rm -f "$STUB_LOG/keychain"
  run sec exec --env production -- bash -c 'test -n "$JWT_SECRET" && echo ok-prod'
  [ "$status" -eq 0 ]
  [ "$output" = ok-prod ]
  [ ! -s "$STUB_LOG/security.calls" ]
}

@test "exec: a CI key in SOPS_AGE_KEY is used for everything and is not passed on" {
  full_setup
  rm -f "$STUB_LOG/keychain" "$STD_CONFIG/age/se.txt"
  SOPS_AGE_KEY="$(grep '^AGE-SECRET-KEY-' "$KEYS/se.txt")" run sec exec --env production -- bash -c 'echo "${SOPS_AGE_KEY:-gone}"'
  [ "$status" -eq 0 ]
  [ "$output" = gone ]
}

@test "exec: no secrets repo and ENV=local runs the command with a warning, staging refuses" {
  rm -rf "$SECRETS_DIR"
  run sec exec --env local -- echo hi
  [ "$status" -eq 0 ]
  [[ "$output" == *hi* ]]
  run sec exec --env staging -- echo hi
  [ "$status" -ne 0 ]
}

@test "exec passes the exit code and leaves no plaintext anywhere, also when the command fails" {
  full_setup
  run sec exec --env staging -- bash -c 'echo "$API_KEY" >/dev/null; exit 7'
  [ "$status" -eq 7 ]
  assert_no_plain api-key-value "$SECRETS_DIR" "$W" "$TMPDIR" "$STD_CONFIG"
  assert_no_files "$TMPDIR"
}

@test "exec does not export reserved names from a secrets file" {
  sec init
  printf '/evil\n' | sec set PATH --env local
  run sec exec --env local -- bash -c 'echo "$PATH"'
  [[ "$output" != "/evil" ]]
}

@test "with-file: a 600 file in a 700 dir, {} replaced, removed afterwards" {
  sec init --gen
  run sec with-file mcuboot -- bash -c 'ls -ld "$(dirname "$1")" | cut -c1-10; ls -l "$1" | cut -c1-10; head -1 "$1"' _ {}
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "drwx------" ]
  [ "${lines[1]}" = "-rw-------" ]
  [ "${lines[2]}" = "-----BEGIN PRIVATE KEY-----" ]  # gitleaks:allow (asserts the PEM header of a throwaway test key)
  assert_no_files "$TMPDIR"
}

@test "with-file: {} inside a larger argument, and cleanup after a failing command" {
  sec init --gen
  run sec with-file mcuboot -- bash -c 'grep -c BEGIN "${1#-DKEY=}"; exit 3' _ -DKEY={}
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = 1 ]
  assert_no_files "$TMPDIR"
  assert_no_plain "BEGIN PRIVATE KEY" "$SECRETS_DIR" "$W" "$TMPDIR"
}

@test "with-file: cleaned up when the command is killed" {
  sec init --gen
  ( sec with-file mcuboot -- bash -c 'sleep 30' _ {} ) &
  local pid=$!
  local n=0
  while [ -z "$(find "$TMPDIR" -type f 2>/dev/null)" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  [ -n "$(find "$TMPDIR" -type f)" ]
  pkill -TERM -P "$pid" -f 'secrets.sh with-file' || kill -TERM "$pid" || true
  pkill -f 'sleep 30' || true
  wait "$pid" || true
  assert_no_files "$TMPDIR"
}

@test "keygen: every type, written straight into keys/, refuses to overwrite" {
  sec init
  local t
  for t in ed25519 ecdsa-p256 mcuboot-ecdsa-p256; do
    run sec keygen "k-$t" --type "$t"
    [ "$status" -eq 0 ]
    [ -f "$SECRETS_DIR/demo/keys/k-$t.sops" ]
  done
  run sec keygen k-ed25519 --type ed25519
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite"* ]]
  run sec keygen nope --type unknown
  [ "$status" -ne 0 ]
  [ ! -e "$SECRETS_DIR/demo/keys/nope.sops" ]
  assert_no_plain "PRIVATE KEY" "$SECRETS_DIR" "$TMPDIR"
  assert_no_files "$TMPDIR"
}

@test "rotate generates a new value for a schema gen secret" {
  sec init --gen
  local before after
  before="$(sec get JWT_SECRET --env production)"
  run sec rotate JWT_SECRET --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"cf-secrets"* ]]
  after="$(sec get JWT_SECRET --env production)"
  [ "$before" != "$after" ]
  [ "${#after}" -ge 32 ]
}

@test "import: a key file into keys/, refusing to overwrite" {
  sec init
  printf 'KEYFILE-CONTENT-77\n' >"$W/old.key"
  run sec import oldkey --file "$W/old.key"
  [ "$status" -eq 0 ]
  [ -f "$SECRETS_DIR/demo/keys/oldkey.sops" ]
  run sec with-file oldkey -- cat {}
  [ "$output" = KEYFILE-CONTENT-77 ]
  run sec import oldkey --file "$W/old.key"
  [ "$status" -ne 0 ]
  assert_no_plain KEYFILE-CONTENT-77 "$SECRETS_DIR"
}

@test "import --force replaces a key file; without it the error says how; a failed encrypt keeps the old key (1.11)" {
  sec init
  printf 'OLD-KEY-11\n' >"$W/old.key"
  printf 'NEW-KEY-11\n' >"$W/new.key"
  sec import ascKey --file "$W/old.key"
  run sec import ascKey --file "$W/new.key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FORCE=1 replaces it"* ]]
  run sec with-file ascKey -- cat {}
  [ "$output" = OLD-KEY-11 ]
  # encryption fails: the old key stays whole and no temp file is left
  local real
  real="$(command -v sops)"
  stub_cmd sops 'for a in "$@"; do [ "$a" = --encrypt ] && { echo "sops: boom" >&2; exit 1; }; done; exec '"$real"' "$@"'
  run sec import ascKey --file "$W/new.key" --force
  [ "$status" -ne 0 ]
  rm "$STUBS/sops"
  run sec with-file ascKey -- cat {}
  [ "$output" = OLD-KEY-11 ]
  [ -z "$(find "$SECRETS_DIR/demo/keys" -name '*.tmp.*')" ]
  run sec import ascKey --file "$W/new.key" --force
  [ "$status" -eq 0 ]
  run sec with-file ascKey -- cat {}
  [ "$output" = NEW-KEY-11 ]
  [ -z "$(git -C "$SECRETS_DIR" status --porcelain)" ]
  assert_no_plain NEW-KEY-11 "$SECRETS_DIR"
  # keygen never replaces a key, --force or not
  run sec keygen ascKey --type ed25519 --force
  [ "$status" -ne 0 ]
  run sec with-file ascKey -- cat {}
  [ "$output" = NEW-KEY-11 ]
}

@test "repo hook: a large key commits; grep stopping early is no false refusal (1.11)" {
  sec init
  head -c 600000 /dev/urandom | base64 >"$W/big.key"
  run sec import bigkey --file "$W/big.key"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not a SOPS-encrypted file"* ]]
  [ -z "$(git -C "$SECRETS_DIR" status --porcelain)" ]
  git -C "$SECRETS_DIR" log --format=%s | grep -qx 'import key bigkey (demo)'
}

@test "list: a long schema has no false 'not in schema' rows (grep -q under pipefail, 1.11)" {
  sec init
  local i
  {
    echo '# NAME  envs  used-by  gen  description'
    for i in $(seq 1 400); do printf 'NAME_%03d   staging,production   cf   no   n\n' "$i"; done
  } >secrets.schema
  {
    for i in $(seq 1 400); do printf 'NAME_%03d=v%s\n' "$i" "$i"; done
    echo 'STRAY_ONE=x'
  } >"$W/.env.many"
  sec import --file "$W/.env.many" --env staging
  run sec list
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRAY_ONE"*"not in schema"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'not in schema')" -eq 1 ]
}

@test "import: a dotenv file merges into an env, conflicts need --force" {
  sec init
  printf '# comment\nexport A_ONE="one"\nA_TWO=two words\n\nA_THREE='"'"'3'"'"'\n' >"$W/.env.old"
  run sec import --file "$W/.env.old" --env staging
  [ "$status" -eq 0 ]
  [ "$(sec get A_ONE --env staging)|$(sec get A_TWO --env staging)|$(sec get A_THREE --env staging)" = "one|two words|3" ]
  # staging only exports what secrets.schema declares: these three are not declared
  run sec exec --env staging -- bash -c 'echo "[$A_ONE]"'
  [[ "$output" == *"not exporting A_ONE"* ]]
  [ "${lines[$((${#lines[@]} - 1))]}" = "[]" ]
  printf 'A_ONE=changed\n' >"$W/.env.new"
  run sec import --file "$W/.env.new" --env staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"A_ONE"* ]]
  run sec import --file "$W/.env.new" --env staging --force
  [ "$status" -eq 0 ]
  [ "$(sec get A_ONE --env staging)" = changed ]
}

@test "unset removes a value" {
  full_setup
  run sec unset API_KEY --env staging
  [ "$status" -eq 0 ]
  run sec get API_KEY --env staging
  [ "$status" -ne 0 ]
}

@test "check flags a tracked .env in the project repo" {
  full_setup
  git init -q -b main .
  echo "X=1" >.env
  echo "X=1" >.env.example
  git add .env .env.example
  git commit -q -m t
  run sec check
  [ "$status" -ne 0 ]
  [[ "$output" == *"tracked in the project repo: .env"* ]]
  [[ "$output" != *".env.example"* ]]
  git rm -q --cached .env
  git commit -q -m untrack
  run sec check
  [ "$status" -eq 0 ]
}

@test "check counts gitleaks findings only in files git does not ignore" {
  full_setup
  git init -q -b main .
  printf '%s\n' 'web/.next/' >.gitignore
  git add .gitignore && git commit -q -m t
  # a fake gitleaks: writes the findings listed in LEAKS (one file per line) as a JSON report, and fails when any
  stub_cmd gitleaks 'while [ $# -gt 0 ]; do [ "$1" = -r ] && r=$2; shift; done
[ -n "${LEAKS:-}" ] || { echo "[]" >"$r"; exit 0; }
printf "%s\n" "$LEAKS" | jq -R . | jq -s "map({File: ., Secret: \"REDACTED\"})" >"$r"; exit 1'
  unset STD_SKIP_GITLEAKS
  export LEAKS='web/.next/dev/prerender-manifest.json'
  run sec check
  [ "$status" -eq 0 ]
  export LEAKS=$'web/.next/dev/prerender-manifest.json\nsrc/config.ts'
  run sec check
  [ "$status" -ne 0 ]
  [[ "$output" == *"gitleaks found something in src/config.ts"* ]]
  [[ "$output" != *"prerender-manifest"* ]]
  [[ "$output" != *"REDACTED"* ]]
  unset LEAKS
  export STD_SKIP_GITLEAKS=1
}

@test "check flags files that are encrypted to the wrong recipients" {
  full_setup
  age-keygen -o "$KEYS/new.txt" 2>/dev/null
  age-keygen -y "$KEYS/new.txt" >"$SECRETS_DIR/recipients/dev/newmac.txt"
  run sec check
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong recipients"* ]]
}

@test "add-machine re-encrypts so the new key decrypts; remove-machine revokes it" {
  full_setup
  age-keygen -o "$KEYS/new.txt" 2>/dev/null
  age-keygen -y "$KEYS/new.txt" >"$SECRETS_DIR/recipients/dev/newmac.txt"
  run enc "$KEYS/new.txt" demo/local.env.sops
  [ "$status" -ne 0 ]
  run sec add-machine newmac
  [ "$status" -eq 0 ]
  run enc "$KEYS/new.txt" demo/local.env.sops
  [ "$status" -eq 0 ]
  [[ "$output" == *"JWT_SECRET="* ]]
  # a dev key never opens staging
  run enc "$KEYS/new.txt" demo/staging.env.sops
  [ "$status" -ne 0 ]
  # the existing machines still work
  run sec exec --env staging -- true
  [ "$status" -eq 0 ]
  run sec check
  [ "$status" -eq 0 ]
  run sec remove-machine newmac
  [ "$status" -eq 0 ]
  [[ "$output" == *"rotate"* ]]
  [[ "$output" == *"demo/local"* ]]
  run enc "$KEYS/new.txt" demo/local.env.sops
  [ "$status" -ne 0 ]
  [ ! -e "$SECRETS_DIR/recipients/dev/newmac.txt" ]
}

@test "add-machine for an SE key opens staging and production too" {
  full_setup
  age-keygen -o "$KEYS/new.txt" 2>/dev/null
  age-keygen -y "$KEYS/new.txt" >"$SECRETS_DIR/recipients/se/mac2.txt"
  run sec add-machine mac2
  [ "$status" -eq 0 ]
  run enc "$KEYS/new.txt" demo/production.env.sops
  [ "$status" -eq 0 ]
  run enc "$KEYS/new.txt" demo/keys/mcuboot.sops binary
  [ "$status" -eq 0 ]
  run sec add-machine ghost
  [ "$status" -ne 0 ]
}

@test "the secrets repo pre-commit hook refuses plain files" {
  sec init --gen
  echo "TOKEN=abc" >"$SECRETS_DIR/demo/plain.env"
  git -C "$SECRETS_DIR" add -f demo/plain.env
  run git -C "$SECRETS_DIR" commit -q -m plain
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a .sops file"* ]]
  git -C "$SECRETS_DIR" reset -q
  # a .sops file with an unencrypted value is refused too
  printf 'TOKEN=abc\n' >"$SECRETS_DIR/demo/fake.env.sops"
  git -C "$SECRETS_DIR" add -f demo/fake.env.sops
  run git -C "$SECRETS_DIR" commit -q -m fake
  [ "$status" -ne 0 ]
  [[ "$output" == *"not encrypted"* ]]
  git -C "$SECRETS_DIR" reset -q
  # and a private key in recipients/
  grep '^AGE-SECRET-KEY' "$KEYS/dev.txt" >"$SECRETS_DIR/recipients/dev/oops.txt"
  git -C "$SECRETS_DIR" add recipients/dev/oops.txt
  run git -C "$SECRETS_DIR" commit -q -m oops
  [ "$status" -ne 0 ]
  [[ "$output" == *"private key"* ]]
}

@test "ci: stores the one CI key with gh on stdin as the secret SOPS_AGE_KEY; its public key is the recipient of every environment" {
  full_setup
  export GITHUB_OWNER=owner
  stub_recorder gh stdin
  run sec ci
  [ "$status" -eq 0 ]
  [ -f "$SECRETS_DIR/recipients/ci/demo.txt" ]
  [ -f "$SECRETS_DIR/recipients/ci/demo-production.txt" ]
  [ "$(cat "$SECRETS_DIR/recipients/ci/demo.txt")" = "$(cat "$SECRETS_DIR/recipients/ci/demo-production.txt")" ]
  # the key is on stdin only: never in argv, nothing in the repo; the secret is the project repo's
  ! grep -q 'AGE-SECRET-KEY' "$STUB_LOG/gh.argv"
  [ "$(grep -c '^AGE-SECRET-KEY-' "$STUB_LOG/gh.stdin")" -eq 1 ]
  grep -qx secret "$STUB_LOG/gh.argv"
  grep -qx SOPS_AGE_KEY "$STUB_LOG/gh.argv"
  grep -qx owner/demo "$STUB_LOG/gh.argv"
  assert_no_plain AGE-SECRET-KEY-1 "$SECRETS_DIR"
  grep '^AGE-SECRET-KEY-' "$STUB_LOG/gh.stdin" >"$KEYS/ci.txt"
  # the one CI key reads every environment, production included
  run enc "$KEYS/ci.txt" demo/common.env.sops
  [ "$status" -eq 0 ]
  run enc "$KEYS/ci.txt" demo/local.env.sops
  [ "$status" -eq 0 ]
  run enc "$KEYS/ci.txt" demo/staging.env.sops
  [ "$status" -eq 0 ]
  run enc "$KEYS/ci.txt" demo/production.env.sops
  [ "$status" -eq 0 ]
  run sec check
  [ "$status" -eq 0 ]
  # running again creates nothing new and stores nothing
  : >"$STUB_LOG/gh.argv"
  run sec ci
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG/gh.argv" ]
}

@test "ci: a gh failure leaves no recipient behind" {
  full_setup
  export GITHUB_OWNER=owner
  stub_recorder gh stdin
  echo 1 >"$STUB_LOG/gh.rc"
  run sec ci
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh could not store the CI key"* ]]
  [ ! -e "$SECRETS_DIR/recipients/ci/demo.txt" ]
}

@test "enroll creates the SE and dev identities and publishes only the public keys" {
  rm -rf "$SECRETS_DIR" "$STD_CONFIG/age" "$STUB_LOG/keychain"
  stub_cmd age-plugin-se 'case "$1" in
  keygen) shift; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
    printf "# created\nAGE-PLUGIN-SE-1STUBIDENTITY\n" >"$out" ;;
  recipients) echo age1se1stubrecipientpublickey ;;
esac'
  run sec enroll --host mac9
  [ "$status" -eq 0 ]
  [ -s "$STD_CONFIG/age/se.txt" ]
  [ "$(cat "$SECRETS_DIR/recipients/se/mac9.txt")" = age1se1stubrecipientpublickey ]
  [[ "$(cat "$SECRETS_DIR/recipients/dev/mac9.txt")" == age1* ]]
  grep -q '^AGE-SECRET-KEY-' "$STUB_LOG/keychain"
  assert_no_plain AGE-SECRET-KEY-1 "$SECRETS_DIR"
  [[ "$output" == *"secrets-add-machine HOST=mac9"* ]]
  # pushed to the remote
  [ -n "$(git --git-dir="$SECRETS_REMOTE" log --oneline main)" ]
  # a second enroll keeps the same identities
  local first
  first="$(cat "$SECRETS_DIR/recipients/dev/mac9.txt")"
  run sec enroll --host mac9
  [ "$(cat "$SECRETS_DIR/recipients/dev/mac9.txt")" = "$first" ]
}

@test "sync pulls new commits from the remote and is silent when offline" {
  full_setup
  git clone -q "$SECRETS_REMOTE" "$BATS_TEST_TMPDIR/other"
  echo note >"$BATS_TEST_TMPDIR/other/README.md"
  git -C "$BATS_TEST_TMPDIR/other" add README.md
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m readme
  git -C "$BATS_TEST_TMPDIR/other" push -q origin HEAD
  run sec sync
  [ "$status" -eq 0 ]
  [ -f "$SECRETS_DIR/README.md" ]
  [ -f "$SECRETS_DIR/.git/project-standard-pulled" ]
  mv "$SECRETS_REMOTE" "$BATS_TEST_TMPDIR/gone.git"
  rm -f "$SECRETS_DIR/.git/project-standard-pulled"
  run sec exec --env staging -- true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exec only pulls once an hour" {
  full_setup
  sec exec --env local -- true
  local stamp="$SECRETS_DIR/.git/project-standard-pulled"
  [ -f "$stamp" ]
  git clone -q "$SECRETS_REMOTE" "$BATS_TEST_TMPDIR/other"
  echo n >"$BATS_TEST_TMPDIR/other/NEW.md"
  git -C "$BATS_TEST_TMPDIR/other" add NEW.md
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m n
  git -C "$BATS_TEST_TMPDIR/other" push -q origin HEAD
  sec exec --env local -- true
  [ ! -e "$SECRETS_DIR/NEW.md" ]
  touch -t 202001010000 "$stamp"
  sec exec --env local -- true
  [ -e "$SECRETS_DIR/NEW.md" ]
}

@test "doctor reports tools, identities and recipients" {
  full_setup
  run sec doctor
  [[ "$output" == *"sops"* && "$output" == *"recipient"* ]]
}

@test "works under the macOS system bash 3.2" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run /bin/bash -c 'echo $BASH_VERSION'
  [[ "$output" == 3.* ]] || skip "/bin/bash is not 3.x here"
  /bin/bash "$STD_TEMPLATES/bin/secrets.sh" init --gen
  printf 'v1\n' | /bin/bash "$STD_TEMPLATES/bin/secrets.sh" set API_KEY --env staging
  run /bin/bash "$STD_TEMPLATES/bin/secrets.sh" exec --env staging -- /bin/bash -c 'echo "$API_KEY"'
  [ "$status" -eq 0 ]
  [ "$output" = v1 ]
  run /bin/bash "$STD_TEMPLATES/bin/secrets.sh" with-file mcuboot -- /bin/bash -c 'head -1 "$1"' _ {}
  [ "$status" -eq 0 ]
  [ "$output" = "-----BEGIN PRIVATE KEY-----" ]
}

# --- security fixes ---------------------------------------------------------------------------------

BASH32=/bin/bash

@test "no here-document or here-string is fed anything but a list of names or public keys" {
  # bash 3.2 backs every unquoted here-document and here-string with a file in /var/tmp. Quoted ones are
  # literal text. Everything else must be on this list (names, paths and public keys, never values).
  local f bodies
  bodies="$(
    for f in "$STD_TEMPLATES"/bin/*.sh "$STD_TEMPLATES"/common.mk "$STD_TEMPLATES"/kinds/*.mk; do
      awk -v F="$(basename "$f")" '
        { sub(/^[ \t]+/, "", $0) }
        inh { if ($0 == delim) inh = 0; else print F ": " $0; next }
        /^#/ { next }
        { line = $0
          if (match(line, /<<<[^<]/)) { print F " (here-string): " substr(line, RSTART); next }
          if (match(line, /<<-?[ ]*[A-Za-z_"\x27\\]+/)) {
            tok = substr(line, RSTART, RLENGTH); sub(/^<<-?[ ]*/, "", tok)
            if (tok ~ /^["\x27\\]/) next
            delim = tok; inh = 1 } }
      ' "$f"
    done
  )"
  local allowed='^(cf|secrets)\.sh: (\$keys|\$list|\$\((declared "\$file" "\$OPT_ENV"|d1_names "\$file" "\$OPT_ENV"|schema_rows|all_sops_files|tracked_secret_files)\))$'
  local bad
  bad="$(printf '%s\n' "$bodies" | grep -v -E "$allowed" || true)"
  if [ -n "$bad" ]; then
    echo "unexpected here-document/here-string bodies:" >&2
    echo "$bad" >&2
    return 1
  fi
  # and the one place that used to feed the decrypted env to a loop does not use one
  ! sed -n '/^cmd_get()/,/^}/p' "$STD_TEMPLATES/bin/secrets.sh" | grep -q '<<'
}

# Watches /var/tmp for the files bash 3.2 makes for here-documents, until STOPFILE disappears.
watch_thd() {
  local stop="$1" f
  while [ -e "$stop" ]; do
    for f in /var/tmp/sh-thd*; do
      if [ -e "$f" ]; then echo seen >"$stop.seen"; break; fi
    done
  done
}

@test "get leaves no here-document temp file behind, while the watcher can see one" {
  [ -x "$BASH32" ] || skip "no /bin/bash"
  # control: a big here-document in bash 3.2 must be seen, or the watcher proves nothing on this system
  : >"$BATS_TEST_TMPDIR/stop1"
  watch_thd "$BATS_TEST_TMPDIR/stop1" &
  local w=$!
  "$BASH32" -c 'big="$(head -c 8000000 /dev/zero | tr "\0" a)"; for i in 1 2 3; do cat >/dev/null <<HD
$big
HD
done'
  rm -f "$BATS_TEST_TMPDIR/stop1"
  wait "$w" || true
  [ -f "$BATS_TEST_TMPDIR/stop1.seen" ] || skip "cannot observe here-document temp files with $BASH32 on this system"
  # a big value, so the old code would hold the file long enough to be caught
  sec init --gen >/dev/null 2>&1
  head -c 150000 /dev/zero | tr '\0' 'x' | sec set BIG_VALUE --env local >/dev/null 2>&1
  : >"$BATS_TEST_TMPDIR/stop2"
  watch_thd "$BATS_TEST_TMPDIR/stop2" &
  w=$!
  local i
  for i in 1 2 3 4 5 6 7 8; do
    "$BASH32" "$STD_TEMPLATES/bin/secrets.sh" get BIG_VALUE --env local --project demo | wc -c | grep -q 150001
    "$BASH32" "$STD_TEMPLATES/bin/secrets.sh" get JWT_SECRET --env local --project demo >/dev/null
  done
  rm -f "$BATS_TEST_TMPDIR/stop2"
  wait "$w" || true
  [ ! -f "$BATS_TEST_TMPDIR/stop2.seen" ]
}

@test "get decodes a newline exactly as exec does" {
  sec init --gen >/dev/null 2>&1
  printf -- '-----BEGIN KEY-----\nabc\n-----END KEY-----' | sec set PEM_KEY --env local >/dev/null 2>&1
  local viaget viaexec
  viaget="$(sec get PEM_KEY --env local)"
  viaexec="$(sec exec --env local -- bash -c 'printf "%s" "$PEM_KEY"' 2>/dev/null)"
  [ "$viaget" = "$viaexec" ]
  [ "$(printf '%s\n' "$viaget" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "edit: refused for staging and production, with the way to do it instead" {
  full_setup >/dev/null 2>&1
  cat >"$STUBS/nvim" <<STUB
#!/bin/bash
echo called >>"$STUB_LOG/nvim.called"
STUB
  chmod +x "$STUBS/nvim"
  EDITOR=nvim run sec edit --env staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"only for local and common"* && "$output" == *"secrets-set"* ]]
  EDITOR=nvim run sec edit --env production
  [ "$status" -ne 0 ]
  [ ! -e "$STUB_LOG/nvim.called" ]
}

@test "edit: neovim gets no swap, undo, backup or shada file, and sops writes into a private folder" {
  full_setup >/dev/null 2>&1
  cat >"$STUBS/nvim" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$STUB_LOG/nvim.argv"
echo "\$TMPDIR" >"$STUB_LOG/nvim.tmpdir"
f="\${@: -1}"
echo "\$f" >"$STUB_LOG/nvim.file"
ls -ld "\$(dirname "\$f")" | cut -c1-10 >"$STUB_LOG/nvim.mode"
printf 'EDITED_VALUE=yes\n' >>"\$f"
STUB
  chmod +x "$STUBS/nvim"
  EDITOR=nvim run sec edit --env local
  [ "$status" -eq 0 ]
  grep -qx -- '-n' "$STUB_LOG/nvim.argv"
  grep -qx -- 'NONE' "$STUB_LOG/nvim.argv"
  grep -qx -- '--cmd' "$STUB_LOG/nvim.argv"
  grep -qx 'set noundofile noswapfile nobackup nowritebackup' "$STUB_LOG/nvim.argv"
  # the plain text lived in a private folder made for this edit, and nothing is left of it
  [[ "$(cat "$STUB_LOG/nvim.tmpdir")" == "$TMPDIR/std-edit."* ]]
  [ "$(cat "$STUB_LOG/nvim.mode")" = "drwx------" ]
  [ ! -e "$(cat "$STUB_LOG/nvim.tmpdir")" ]
  [ "$(sec get EDITED_VALUE --env local)" = yes ]
  git -C "$SECRETS_DIR" log --oneline | grep -q 'edit demo local'
}

@test "edit: vim gets -n -i NONE -c, common is allowed, another editor is warned about" {
  full_setup >/dev/null 2>&1
  local ed
  for ed in vim nano; do
    cat >"$STUBS/$ed" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$STUB_LOG/$ed.argv"
printf 'FROM_$ed=1\n' >>"\${@: -1}"
STUB
    chmod +x "$STUBS/$ed"
  done
  EDITOR=vim run sec edit --env common
  [ "$status" -eq 0 ]
  grep -qx -- '-i' "$STUB_LOG/vim.argv"
  grep -qx -- '-c' "$STUB_LOG/vim.argv"
  grep -qx 'set noundofile noswapfile nobackup nowritebackup' "$STUB_LOG/vim.argv"
  [ "$(sec get FROM_vim --env common)" = 1 ]
  EDITOR=nano run sec edit --env local
  [ "$status" -eq 0 ]
  [[ "$output" == *"may keep copies"* ]]
  ! grep -qx -- '-n' "$STUB_LOG/nano.argv"
}

@test "exec for staging and production exports only the names secrets.schema declares" {
  full_setup >/dev/null 2>&1
  printf 'planted\n' | sec set PLANTED_NAME --env staging >/dev/null 2>&1
  printf 'planted-common\n' | sec set PLANTED_COMMON --env common >/dev/null 2>&1
  run sec exec --env staging -- bash -c 'echo "[$API_KEY][$JWT_SECRET][$PLANTED_NAME][$PLANTED_COMMON][$SHARED_URL]"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not exporting PLANTED_NAME"* && "$output" == *"not exporting PLANTED_COMMON"* ]]
  local last="${lines[$((${#lines[@]} - 1))]}"
  [[ "$last" == "[api-key-value]["*"][][][https://x.example]" ]]
  # local is not restricted to the schema
  printf 'free\n' | sec set ANY_LOCAL --env local >/dev/null 2>&1
  run sec exec --env local -- bash -c 'echo "[$ANY_LOCAL]"'
  [ "${lines[$((${#lines[@]} - 1))]}" = "[free]" ]
  # staging without a schema file declares nothing: refused, not "export all"
  run env SECRETS_SCHEMA="$BATS_TEST_TMPDIR/none.schema" bash "$STD_TEMPLATES/bin/secrets.sh" exec --env staging --project demo -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"only exports the names it declares"* ]]
}

@test "exec never exports names that steer a shell, make, git, node, python or the standard's own scripts" {
  sec init >/dev/null 2>&1
  local n
  for n in NODE_OPTIONS GIT_SSH_COMMAND GIT_DIR SSH_AUTH_SOCK npm_config_registry PYTHONPATH PERL5OPT MAKEFLAGS MAKELEVEL CONFIRM \
    CF_SH_INNER STD_TTY TMPDIR PATH HOME LD_PRELOAD DYLD_INSERT_LIBRARIES BASH_ENV ENV IFS PS4 SHELLOPTS CF_API_BASE PROJECT SECRETS_DIR; do
    printf 'evil\n' | sec set "$n" --env local >/dev/null 2>&1
  done
  printf 'fine\n' | sec set HARMLESS --env local >/dev/null 2>&1
  run sec exec --env local -- bash -c 'echo "[$HARMLESS][$NODE_OPTIONS][$GIT_SSH_COMMAND][$MAKEFLAGS][$CONFIRM][$CF_API_BASE][$PYTHONPATH][$CF_SH_INNER]"; [ "$PATH" != evil ] && [ "$HOME" != evil ] && [ "${TMPDIR:-}" != evil ] && [ "${BASH_ENV:-}" != evil ]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[fine][][][][][][][]"* ]]
  [[ "$output" == *"not exporting NODE_OPTIONS"* && "$output" == *"not exporting MAKEFLAGS"* && "$output" == *"not exporting CONFIRM"* ]]
}

@test "a secret name may not start with sops_ in any case" {
  sec init >/dev/null 2>&1
  local n
  for n in sops_foo SOPS_FOO Sops_x SOPS_AGE_KEY; do
    run sec set "$n" --env local
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid secret name"* ]]
  done
}

@test "decrypt failures name the identity really used (ci in CI)" {
  full_setup >/dev/null 2>&1
  local wrong
  wrong="$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')"
  run env SOPS_AGE_KEY="$wrong" bash "$STD_TEMPLATES/bin/secrets.sh" exec --env staging --project demo -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"with the ci identity"* ]]
  [[ "$output" != *"with the se identity"* ]]
}

@test "the secrets repo hook is rewritten before every commit, and a wrong hooksPath cannot switch it off" {
  full_setup >/dev/null 2>&1
  printf '#!/bin/sh\nexit 0\n' >"$SECRETS_DIR/.git/hooks/pre-commit"
  git -C "$SECRETS_DIR" config core.hooksPath /nonexistent
  printf 'again\n' | sec set API_KEY --env staging >/dev/null 2>&1
  grep -q 'secrets-repo pre-commit hook' "$SECRETS_DIR/.git/hooks/pre-commit"
  [ "$(git -C "$SECRETS_DIR" config core.hooksPath)" = "$SECRETS_DIR/.git/hooks" ]
}

@test "the hook refuses a plain file that was renamed, and a private key in any letter case" {
  full_setup >/dev/null 2>&1
  echo "TOKEN=abc" >"$SECRETS_DIR/demo/plain.txt"
  git -C "$SECRETS_DIR" add -f demo/plain.txt
  git -C "$SECRETS_DIR" commit -q --no-verify -m "sneak a plain file in"
  git -C "$SECRETS_DIR" mv demo/plain.txt demo/plain2.txt
  run git -C "$SECRETS_DIR" commit -q -m rename
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a .sops file"* ]]
  git -C "$SECRETS_DIR" reset -q --hard
  grep '^AGE-SECRET-KEY' "$KEYS/dev.txt" | tr 'A-Z' 'a-z' >"$SECRETS_DIR/recipients/dev/lower.txt"
  git -C "$SECRETS_DIR" add recipients/dev/lower.txt
  run git -C "$SECRETS_DIR" commit -q -m lower
  [ "$status" -ne 0 ]
  [[ "$output" == *"private key"* ]]
}

@test "ci --force replaces the secret; without it an existing key is not stored again" {
  full_setup >/dev/null 2>&1
  export GITHUB_OWNER=owner
  stub_recorder gh stdin
  run sec ci
  [ "$status" -eq 0 ]
  : >"$STUB_LOG/gh.argv"
  run sec ci
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG/gh.argv" ]
  run sec ci --force
  [ "$status" -eq 0 ]
  grep -qx secret "$STUB_LOG/gh.argv"
  grep -qx set "$STUB_LOG/gh.argv"
}

@test "set on a project that has no files yet writes .sops.yaml rules for it first" {
  rm -rf "$SECRETS_DIR/.git"
  git -C "$SECRETS_DIR" init -q -b main
  run bash -c "printf 'v1\n' | PROJECT=fresh bash '$STD_TEMPLATES/bin/secrets.sh' set FIRST --env local"
  [ "$status" -eq 0 ]
  [ -f "$SECRETS_DIR/fresh/local.env.sops" ]
  grep -q '\^fresh/' "$SECRETS_DIR/.sops.yaml"
  [ "$(PROJECT=fresh bash "$STD_TEMPLATES/bin/secrets.sh" get FIRST --env local)" = v1 ]
}

@test "check and audit share one list of secret file names" {
  . "$STD_TEMPLATES/bin/secret-patterns.sh"
  local f
  for f in .env .env.local .dev.vars x/.prod.vars a.pem a.p8 a.p12 a.pfx a.ppk a.key a.jks a.keystore id_rsa .ssh/id_ed25519 .netrc infra/prod.tfvars my-service-account-prod.json secrets/x keys/x a/keys/y; do
    [ "$(std_secret_class "$f")" = secret ] || { echo "$f is not seen as a secret"; return 1; }
  done
  for f in .env.example .env.sample .env.template README.md src/main.rs keys.md; do
    [ -z "$(std_secret_class "$f")" ] || { echo "$f is wrongly seen as a secret"; return 1; }
  done
  [ "$(std_secret_class .envrc)" = warn ]
  # the audit script reads the very same file
  grep -q 'secret-patterns.sh' "$STD_SKILL_DIR/scripts/audit.sh"
  ! grep -q 'TRACKED_PATTERNS' "$STD_TEMPLATES/bin/secrets.sh"
  # and check flags a tracked id_rsa and .npmrc in the project repo
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo"
  git init -q
  : >id_rsa
  printf '//registry.npmjs.org/:_authToken=npm_SECRETVALUE123\n' >.npmrc
  mkdir -p web
  printf 'verify-deps-before-run=error\n' >web/.npmrc
  git add -f id_rsa .npmrc web/.npmrc
  run sec check
  [[ "$output" == *"project repo: id_rsa"* && "$output" == *".npmrc"* ]]
  [[ "$output" != *"web/.npmrc"* ]]
  [[ "$output" != *"SECRETVALUE"* ]]
}

@test ".npmrc is a secret only when it sets a credential, and its contents are never printed" {
  . "$STD_TEMPLATES/bin/secret-patterns.sh"
  local d="$BATS_TEST_TMPDIR/npmrc" line out
  mkdir -p "$d/sub"
  # settings only, comments, and credentials that are only environment references: not secrets
  printf 'verify-deps-before-run=error\nengine-strict=true\n@acme:registry=https://npm.example.com/\n' >"$d/.npmrc"
  [ -z "$(std_secret_class .npmrc "$d")" ]
  printf '# _authToken=abc\n; password=abc\n' >"$d/.npmrc"
  [ -z "$(std_secret_class .npmrc "$d")" ]
  printf '//npm.example.com/:_authToken=${NPM_TOKEN}\n_auth = "${NPM_AUTH}"\n' >"$d/.npmrc"
  [ -z "$(std_secret_class .npmrc "$d")" ]
  : >"$d/.npmrc"
  [ -z "$(std_secret_class .npmrc "$d")" ]
  # each auth setting, top level or per registry, with spaces: a secret
  for line in '_authToken=tok' '_auth=dXNlcjpwYXNz' '_password=cGFzcw==' 'username=me' 'password=pw' \
    '//registry.npmjs.org/:_authToken=npm_SECRETVALUE' '  //npm.example.com/repo/:_password = cGFzcw==' \
    '//npm.example.com/:username=me' '//npm.example.com/:_authToken=${NPM_TOKEN}x'; do
    printf 'verify-deps-before-run=error\n%s\n' "$line" >"$d/sub/.npmrc"
    out=$(std_secret_class sub/.npmrc "$d")
    [ "$out" = secret ] || { echo "not a secret: $line"; return 1; }
  done
  # relative to the current directory by default
  (cd "$d" && [ "$(std_secret_class sub/.npmrc)" = secret ])
  # a .npmrc that cannot be read is not known to be safe
  [ "$(std_secret_class missing/.npmrc "$d")" = secret ]
  # only a class word comes out, never the file
  out=$(printf '_authToken=npm_SECRETVALUE\n' >"$d/.npmrc"; std_secret_class .npmrc "$d" 2>&1)
  [ "$out" = secret ]
}

@test "recovery refuses without a terminal and when a recovery key exists" {
  full_setup
  run sec recovery
  [ "$status" -ne 0 ]
  [[ "$output" == *"run it in a terminal"* ]]
  run tty_run "" bash "$STD_TEMPLATES/bin/secrets.sh" recovery
  [[ "$output" == *"a recovery key exists already"* ]]
}

@test "recovery: new key shown once, never stored, and it opens every file after re-encryption" {
  full_setup
  rm "$SECRETS_DIR/recipients/recovery.txt"
  run tty_run "" bash "$STD_TEMPLATES/bin/secrets.sh" recovery
  [[ "$output" == *"recovery key added"* ]]
  key="$(printf '%s\n' "$output" | tr -d '\r' | grep -o 'AGE-SECRET-KEY-1[0-9A-Z]*' | head -n 1)"
  [ -n "$key" ]
  [ -s "$SECRETS_DIR/recipients/recovery.txt" ]
  # the private half is nowhere on disk
  assert_no_plain "$key" "$SECRETS_DIR" "$STD_CONFIG" "$BATS_TEST_TMPDIR/project"
  printf '%s\n' "$key" >"$KEYS/newrec.txt"
  for f in demo/common.env.sops demo/local.env.sops demo/staging.env.sops demo/production.env.sops; do
    run enc "$KEYS/newrec.txt" "$f"
    [ "$status" -eq 0 ]
  done
}

@test "enroll on the first Mac does not ask for add-machine and warns about the missing recovery key" {
  rm -rf "$SECRETS_DIR" "$STD_CONFIG/age"
  stub_security
  stub_cmd age-plugin-se 'case "$1" in keygen) shift; while [ $# -gt 0 ]; do [ "$1" = -o ] && { age-keygen -o "$2" 2>/dev/null; }; shift; done ;; recipients) age-keygen -y "$3" ;; esac'
  run sec enroll
  [ "$status" -eq 0 ]
  [[ "$output" == *"first Mac"* ]]
  [[ "$output" != *"secrets-add-machine"* ]]
  [[ "$output" == *"no recovery key yet"* ]]
}

# --- one secrets repo per owner (1.8) ------------------------------------------------------------

# owner_repo: the default owner's repo is mksecrets' recipients (Macs, recovery, and a CI key of another project) at
# ~/.secrets-fabrolabs-innovations; the project's is a new SECRETS_DIR with an empty remote of its own.
owner_repo() {
  mkdir -p "$SECRETS_DIR/recipients/ci"
  age-keygen -o "$KEYS/otherci.txt" 2>/dev/null
  OTHER_CI_PUB="$(age-keygen -y "$KEYS/otherci.txt")"
  printf '%s\n' "$OTHER_CI_PUB" >"$SECRETS_DIR/recipients/ci/other.txt"
  mv "$SECRETS_DIR" "$HOME/.secrets-fabrolabs-innovations"
  export SECRETS_DEFAULT_DIR="$HOME/.secrets-fabrolabs-innovations"
  export SECRETS_DIR="$HOME/.secrets-mayankgautam-me"
  git init -q --bare -b main "$BATS_TEST_TMPDIR/personal.git"
  export SECRETS_REMOTE="$BATS_TEST_TMPDIR/personal.git"
}

@test "new secrets repo: an empty remote starts with the Macs' and the recovery recipients only, hook, origin, pushed" {
  owner_repo
  run sec init --gen
  [ "$status" -eq 0 ]
  [[ "$output" == *"new secrets repo at $SECRETS_DIR"* ]]
  [[ "$output" == *"copied 3 public recipient(s) from $SECRETS_DEFAULT_DIR: Macs: testhost; the recovery key"* ]]
  [ "$(cat "$SECRETS_DIR/recipients/se/testhost.txt")" = "$SE_PUB" ]
  [ "$(cat "$SECRETS_DIR/recipients/dev/testhost.txt")" = "$DEV_PUB" ]
  [ "$(cat "$SECRETS_DIR/recipients/recovery.txt")" = "$REC_PUB" ]
  # no other project's CI key, and it is not a recipient of anything
  [ ! -e "$SECRETS_DIR/recipients/ci/other.txt" ]
  run grep -c "$OTHER_CI_PUB" "$SECRETS_DIR/.sops.yaml"
  [ "$output" = 0 ]
  grep -q "$SE_PUB" "$SECRETS_DIR/.sops.yaml"
  [ "$(git -C "$SECRETS_DIR" remote get-url origin)" = "$SECRETS_REMOTE" ]
  [ "$(git -C "$SECRETS_DIR" config core.hooksPath)" = "$SECRETS_DIR/.git/hooks" ]
  [ -x "$SECRETS_DIR/.git/hooks/pre-commit" ]
  [ "$(git -C "$SECRETS_DIR" rev-parse --abbrev-ref HEAD)" = main ]
  # the first commit holds the recipients and .sops.yaml; then init's own; all pushed
  [ "$(git --git-dir="$SECRETS_REMOTE" log --format=%s main | tail -n 1)" = "new secrets repo: the Macs and the recovery key" ]
  [ "$(git --git-dir="$SECRETS_REMOTE" rev-parse main)" = "$(git -C "$SECRETS_DIR" rev-parse HEAD)" ]
  [ -f "$SECRETS_DIR/demo/production.env.sops" ]
  run enc "$KEYS/se.txt" demo/production.env.sops
  [ "$status" -eq 0 ]
  # nothing private copied or printed, and the default repo is untouched
  assert_no_plain AGE-SECRET-KEY-1 "$SECRETS_DIR"
  [[ "$output" != *"AGE-SECRET-KEY"* ]]
  [ ! -e "$SECRETS_DEFAULT_DIR/.git" ]
  [ ! -e "$SECRETS_DEFAULT_DIR/demo" ]
}

@test "new secrets repo: a recipient file that holds a private key is not copied" {
  owner_repo
  cp "$KEYS/dev.txt" "$SECRETS_DEFAULT_DIR/recipients/dev/leaky.txt"
  run sec init --gen
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped recipients/dev/leaky.txt: it holds a private key"* ]]
  [ ! -e "$SECRETS_DIR/recipients/dev/leaky.txt" ]
  assert_no_plain AGE-SECRET-KEY-1 "$SECRETS_DIR"
}

@test "new secrets repo: with no other secrets repo on this Mac to copy from it says how to enroll" {
  owner_repo
  rm -rf "$SECRETS_DEFAULT_DIR"
  run sec init --gen
  [ "$status" -ne 0 ]
  [[ "$output" == *"no other secrets repo on this Mac (~/.secrets-*) to copy the Macs from"*"make secrets-enroll"*"make secrets-recovery"* ]]
  [ -d "$SECRETS_DIR/.git" ]
  [ "$(git -C "$SECRETS_DIR" remote get-url origin)" = "$SECRETS_REMOTE" ]
}

@test "new secrets repo: a remote that has content is cloned as it is, nothing copied" {
  owner_repo
  local seed="$BATS_TEST_TMPDIR/seed"
  git clone -q "$SECRETS_REMOTE" "$seed" 2>/dev/null
  mkdir -p "$seed/recipients/se" "$seed/recipients/dev"
  printf '%s\n' "$SE_PUB" >"$seed/recipients/se/othermac.txt"
  printf '%s\n' "$DEV_PUB" >"$seed/recipients/dev/othermac.txt"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m existing
  git -C "$seed" push -q origin HEAD:main
  run sec init --gen
  [ "$status" -eq 0 ]
  [[ "$output" != *"new secrets repo"* ]]
  [ -f "$SECRETS_DIR/recipients/se/othermac.txt" ]
  [ ! -e "$SECRETS_DIR/recipients/se/testhost.txt" ]
  [ ! -e "$SECRETS_DIR/recipients/recovery.txt" ]
  [ "$(git -C "$SECRETS_DIR" log --format=%s | tail -n 1)" = existing ]
}

@test "new secrets repo: a remote that cannot be cloned stops with what to do" {
  owner_repo
  export SECRETS_REMOTE="$BATS_TEST_TMPDIR/missing.git"
  run sec init --gen
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot clone $SECRETS_REMOTE into $SECRETS_DIR"*"gh repo create <owner>/secrets --private"* ]]
}

@test "per-owner repo: the machine commands act on the project's SECRETS_DIR, enroll adds this Mac to it" {
  owner_repo
  sec init --gen
  stub_cmd age-plugin-se 'case "$1" in
  keygen) shift; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
    printf "# created\nAGE-PLUGIN-SE-1STUBIDENTITY\n" >"$out" ;;
  recipients) echo age1se1stubrecipientpublickey ;;
esac'
  run sec enroll --host mac9
  [ "$status" -eq 0 ]
  [ -f "$SECRETS_DIR/recipients/se/mac9.txt" ]
  [ ! -e "$SECRETS_DEFAULT_DIR/recipients/se/mac9.txt" ]
  [[ "$output" == *"secrets-add-machine HOST=mac9"* ]]
  run sec remove-machine mac9
  [ "$status" -eq 0 ]
  [ ! -e "$SECRETS_DIR/recipients/se/mac9.txt" ]
  run sec sync
  [ "$status" -eq 0 ]
  [ "$(git --git-dir="$SECRETS_REMOTE" rev-parse main)" = "$(git -C "$SECRETS_DIR" rev-parse HEAD)" ]
  [ -f "$SECRETS_DEFAULT_DIR/recipients/se/testhost.txt" ]
  [ ! -e "$SECRETS_DEFAULT_DIR/.git" ]
}

@test "doctor names the project's owner and where it came from" {
  owner_repo
  sec init --gen
  GITHUB_OWNER=mayankgautam-me STD_OWNER_FROM=origin run sec doctor
  [[ "$output" == *"owner mayankgautam-me (the project's git remote origin)"* ]]
  [[ "$output" == *"secrets repo $SECRETS_DIR ($SECRETS_REMOTE)"* ]]
  GITHUB_OWNER=fabrolabs-innovations STD_OWNER_FROM=config run sec doctor
  [[ "$output" == *"owner fabrolabs-innovations from the user config: the project has no GitHub remote origin yet"* ]]
  GITHUB_OWNER= STD_OWNER_FROM= run sec doctor
  [[ "$output" == *"no GitHub owner"* ]]
}

@test "new secrets repo: without SECRETS_DEFAULT_DIR it copies from another ~/.secrets-* on this Mac" {
  owner_repo
  unset SECRETS_DEFAULT_DIR
  mkdir -p "$HOME/.secrets-empty-owner/recipients"
  run sec init --gen
  [ "$status" -eq 0 ]
  [[ "$output" == *"copied 3 public recipient(s) from $HOME/.secrets-fabrolabs-innovations"* ]]
  [ -f "$SECRETS_DIR/recipients/se/testhost.txt" ]
  [ ! -e "$SECRETS_DIR/recipients/ci" ]
}

@test "pre-1.8 ~/.secrets: the secrets commands stop with the mv and hooksPath commands and move nothing" {
  git -C "$SECRETS_DIR" init -q -b main
  export STD_CONFIG_OWNER=fabrolabs-innovations
  export SECRETS_DIR="$HOME/.secrets-fabrolabs-innovations"
  run sec init --gen
  [ "$status" -ne 0 ]
  [[ "$output" == *"pre-1.8 checkout of fabrolabs-innovations's secrets repo"* ]]
  [[ "$output" == *'mv "$HOME/.secrets" "$HOME/.secrets-fabrolabs-innovations"'* ]]
  [[ "$output" == *'git -C "$HOME/.secrets-fabrolabs-innovations" config core.hooksPath "$HOME/.secrets-fabrolabs-innovations/.git/hooks"'* ]]
  [ -d "$HOME/.secrets/.git" ]
  [ ! -e "$SECRETS_DIR" ]
  run sec sync
  [ "$status" -ne 0 ]
  [[ "$output" == *'mv "$HOME/.secrets"'* ]]
  # exec in local and list do not stop, but say it
  run sec list
  [[ "$output" == *'mv "$HOME/.secrets"'* ]]
  run sec doctor
  [[ "$output" == *'mv "$HOME/.secrets"'* ]]
  # a project of another owner stops too: its new repo would have no Macs to copy
  SECRETS_DIR="$HOME/.secrets-mayankgautam-me" run sec init --gen
  [ "$status" -ne 0 ]
  [[ "$output" == *"move ~/.secrets first"* ]]
  [ ! -e "$HOME/.secrets-mayankgautam-me" ]
}

@test "pre-1.8 ~/.secrets moved by hand: the next command re-pins core.hooksPath" {
  STD_CONFIG_OWNER= sec init --gen
  [ "$(git -C "$SECRETS_DIR" config core.hooksPath)" = "$HOME/.secrets/.git/hooks" ]
  mv "$HOME/.secrets" "$HOME/.secrets-fabrolabs-innovations"
  export STD_CONFIG_OWNER=fabrolabs-innovations
  export SECRETS_DIR="$HOME/.secrets-fabrolabs-innovations"
  run sec sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"pre-1.8"* ]]
  [ "$(git -C "$SECRETS_DIR" config core.hooksPath)" = "$SECRETS_DIR/.git/hooks" ]
  printf 'v2\n' | sec set API_KEY --env staging
  [ -n "$(git --git-dir="$SECRETS_REMOTE" log --oneline main)" ]
}
