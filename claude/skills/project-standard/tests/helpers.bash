# Shared helpers for the project-standard tests. Use with:  load helpers
#
# Everything happens inside $BATS_TEST_TMPDIR: HOME, SECRETS_DIR, STD_CONFIG and TMPDIR are redirected
# there, stub tools sit first on PATH, and nothing touches the real ~/.secrets, the Keychain, the Secure
# Enclave, Cloudflare or GitHub.
#
#   std_setup_env                    call from setup(): isolated HOME/TMPDIR/PATH, stubs dir, no GitHub or GitLab CI variables
#   stub_gh                          a gh on PATH: records argv, keeps the Release state in $STUB_LOG (see below)
#   mkproject DIR 'project.mk text'  copy Makefile, make/common.mk and make/bin into DIR with that project.mk
#   mkkind DIR NAME 'kind text'      write DIR/make/kinds/NAME.mk
#   mkfakekinds DIR                  the kinds "fake" (build+flash) and "cloud-worker" (deploy) used by common.bats
#   stub_cmd NAME 'bash body'        executable stub on PATH
#   stub_recorder NAME [stdin]       stub that records argv (and stdin when asked) under $STUB_LOG and prints $STUB_LOG/NAME.out
#   stub_security                    fake macOS `security` keeping the dev key in $STUB_LOG/keychain
#   mksecrets                        throwaway age identities + a secrets repo with a bare remote
#   sec ARGS...                      run templates/make/bin/secrets.sh (PROJECT from the environment)
#   assert_no_plain MARKER DIR...    fail when MARKER is found in any file under the dirs
#   tty_run ANSWER CMD ARGS...       run CMD on a real pty (script) with ANSWER typed on it; the only way to answer
#                                    confirm_typed, which reads /dev/tty and nothing else

STD_SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
STD_TEMPLATES="$STD_SKILL_DIR/templates/make"
export STD_SKILL_DIR STD_TEMPLATES

std_setup_env() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export STD_CONFIG="$HOME/.config/project-standard"
  export SECRETS_DIR="$HOME/.secrets"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  export STUBS="$BATS_TEST_TMPDIR/stubs"
  export STUB_LOG="$BATS_TEST_TMPDIR/stublog"
  mkdir -p "$HOME" "$TMPDIR" "$STUBS" "$STUB_LOG"
  export PATH="$STUBS:$PATH"
  export NO_COLOR=1
  export STD_NO_SYNC=
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
  export STD_SKIP_GITLEAKS=1
  unset ENV CONFIRM PART LEVEL SOPS_AGE_KEY SOPS_AGE_KEY_FILE SOPS_AGE_KEY_CMD SECRETS_REMOTE PROJECT CF_SH_INNER CI
  unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CF_NO_BROWSER
  export STD_AUDIT_OFFLINE=1   # the audit's one online check (the GitHub description) stays off unless a test turns it on
  unset GITHUB_ACTIONS GITHUB_REPOSITORY GITHUB_REPOSITORY_OWNER GITHUB_REF_NAME GITHUB_REF_TYPE GITHUB_TOKEN GH_TOKEN GITHUB_OWNER GITLAB_CI
  unset SECRETS_DEFAULT_DIR STD_OWNER_FROM STD_ORIGIN_OWNER STD_CONFIG_OWNER
}

mkproject() {
  local dir="$1" text="$2"
  mkdir -p "$dir/make/kinds"
  printf '# project-standard v1.12 (managed: test)\ninclude make/project.mk\ninclude make/common.mk\n' >"$dir/Makefile"
  printf '%s\n' "$text" >"$dir/make/project.mk"
  cp "$STD_TEMPLATES/common.mk" "$dir/make/common.mk"
  mkdir -p "$dir/make/bin"
  cp "$STD_TEMPLATES"/bin/*.sh "$dir/make/bin/"
  chmod +x "$dir"/make/bin/*.sh
  printf '8\n' >"$dir/make/VERSION"
}

mkkind() {
  printf '%s\n' "$3" >"$1/make/kinds/$2.mk"
}

mkfakekinds() {
  mkkind "$1" fake 'define kind_fake
$(1)_BOARD ?= nrf
$(call std_verb,$(1),build,firmware,Build for $$($(1)_BOARD) into $(2)/build)
$(call std_verb,$(1),flash,firmware,Flash $(1))
$(call std_verb,$(1),erase,firmware,Erase $(1))
$(1)-build:
	@echo BUILD $(1) ENV=$$(ENV)
$(1)-flash:
	@echo FLASH $(1)
$(1)-erase:
	@echo ERASE $(1)
endef'
  mkkind "$1" cloud-worker 'define kind_cloud-worker
$(call std_verb,$(1),deploy,deploy,Deploy $(1) from $(2))
$(call std_verb,$(1),build,deploy,Build $(1))
$(1)-deploy:
	@echo DEPLOY $(1) ENV=$$(ENV) DIR=$(2)
$(1)-build:
	@echo BUILD $(1)
endef'
}

stub_cmd() {
  printf '#!/bin/bash\n%s\n' "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

stub_recorder() {
  # second argument "stdin": also record stdin (only for stubs that are fed through a pipe)
  local readstdin=0
  [ "${2:-}" = stdin ] && readstdin=1
  cat >"$STUBS/$1" <<EOF
#!/bin/bash
name="$1"
printf '%s\n' "\$@" >>"$STUB_LOG/\$name.argv"
printf -- '--\n' >>"$STUB_LOG/\$name.argv"
if [ "$readstdin" = 1 ]; then cat >>"$STUB_LOG/\$name.stdin"; printf -- '\n--\n' >>"$STUB_LOG/\$name.stdin"; fi
env | grep -E '^(CLOUDFLARE_|JWT_|STD_ENV)' >>"$STUB_LOG/\$name.env" || true
[ ! -f "$STUB_LOG/\$name.out" ] || cat "$STUB_LOG/\$name.out"
rc=0
[ ! -f "$STUB_LOG/\$name.rc" ] || rc=\$(cat "$STUB_LOG/\$name.rc")
exit "\$rc"
EOF
  chmod +x "$STUBS/$1"
}

# Fake `security`: find-generic-password -w prints the dev key; `security -i` reads an
# add-generic-password line from stdin and stores the -w value.
stub_security() {
  cat >"$STUBS/security" <<EOF
#!/bin/bash
echo "\$*" >>"$STUB_LOG/security.calls"
case "\$1" in
  find-generic-password)
    [ -s "$STUB_LOG/keychain" ] || exit 44
    case " \$* " in *" -w "*) cat "$STUB_LOG/keychain" ;; esac ;;
  -i)
    read -r line
    key="\${line##* -w }"
    printf '%s\n' "\$key" >"$STUB_LOG/keychain" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$STUBS/security"
}

# stub_gh: a gh on PATH. It records its argv under $STUB_LOG/gh.argv (one argument per line, "--" after each call), and
# the Release lives in $STUB_LOG: release.exists (there is one), release.body (its body: view --jq .body prints it;
# create and edit store the --notes-file there, and keep the file in notes.txt). create.fail makes the next create
# refused and leaves the Release there (another job made it meanwhile). secret set reads its value from stdin into
# secret.stdin; nothing else is recorded from stdin.
stub_gh() {
  cat >"$STUBS/gh" <<'EOF'
#!/bin/bash
log="$STUB_LOG"
printf '%s\n' "$@" >>"$log/gh.argv"; printf -- '--\n' >>"$log/gh.argv"
notes=''; prev=''; jq=0
for a in "$@"; do
  [ "$prev" = --notes-file ] && notes="$a"
  [ "$a" = --jq ] && jq=1
  prev=$a
done
case "$1 $2" in
  "release view")
    [ -f "$log/release.exists" ] || exit 1
    if [ "$jq" = 1 ]; then cat "$log/release.body" 2>/dev/null; else echo '{"name":"x"}'; fi
    exit 0 ;;
  "release create")
    if [ -f "$log/create.fail" ]; then touch "$log/release.exists"; exit 1; fi
    touch "$log/release.exists"
    if [ -n "$notes" ]; then cp "$notes" "$log/notes.txt"; cp "$notes" "$log/release.body"; fi
    exit 0 ;;
  "release edit")
    if [ -n "$notes" ]; then cp "$notes" "$log/notes.txt"; cp "$notes" "$log/release.body"; fi
    exit 0 ;;
  "release upload") exit 0 ;;
  "secret set") cat >"$log/secret.stdin"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUBS/gh"
}

# Throwaway identities. Exports KEYS (dir), SE_PUB, DEV_PUB, REC_PUB and wires everything up:
# the "Secure Enclave" identity file is a plain age key, the Keychain is the stub, the secrets repo has a
# bare local remote.
mksecrets() {
  export KEYS="$BATS_TEST_TMPDIR/keys"
  mkdir -p "$KEYS" "$STD_CONFIG/age" "$SECRETS_DIR/recipients/se" "$SECRETS_DIR/recipients/dev"
  age-keygen -o "$KEYS/se.txt" 2>/dev/null
  age-keygen -o "$KEYS/dev.txt" 2>/dev/null
  age-keygen -o "$KEYS/recovery.txt" 2>/dev/null
  SE_PUB="$(age-keygen -y "$KEYS/se.txt")"
  DEV_PUB="$(age-keygen -y "$KEYS/dev.txt")"
  REC_PUB="$(age-keygen -y "$KEYS/recovery.txt")"
  export SE_PUB DEV_PUB REC_PUB
  cp "$KEYS/se.txt" "$STD_CONFIG/age/se.txt"
  chmod 600 "$STD_CONFIG/age/se.txt"
  printf '%s\n' "$SE_PUB" >"$SECRETS_DIR/recipients/se/testhost.txt"
  printf '%s\n' "$DEV_PUB" >"$SECRETS_DIR/recipients/dev/testhost.txt"
  printf '%s\n' "$REC_PUB" >"$SECRETS_DIR/recipients/recovery.txt"
  stub_security
  grep '^AGE-SECRET-KEY-' "$KEYS/dev.txt" >"$STUB_LOG/keychain"
  git init -q --bare -b main "$BATS_TEST_TMPDIR/remote.git"
  export SECRETS_REMOTE="$BATS_TEST_TMPDIR/remote.git"
}

sec() {
  bash "$STD_TEMPLATES/bin/secrets.sh" "$@"
}

assert_no_plain() {
  local marker="$1" hits
  shift
  hits="$(grep -rIl --binary-files=text -F -- "$marker" "$@" 2>/dev/null | grep -v '/\.git/' || true)"
  if [ -n "$hits" ]; then
    echo "plain text '$marker' found in: $hits" >&2
    return 1
  fi
}

assert_no_files() {
  local found
  found="$(find "$1" -type f 2>/dev/null | head -n 5)"
  if [ -n "$found" ]; then
    echo "files left behind in $1: $found" >&2
    return 1
  fi
}

# tty_run ANSWER CMD ARGS...   CMD gets a controlling terminal (script makes a pty) and ANSWER is typed on it.
# The writer stays open for a second: script sends EOF to the pty as soon as its own stdin closes.
tty_run() {
  local answer="$1"
  shift
  (
    printf '%s\n' "$answer"
    sleep 1
  ) | script -q /dev/null "$@"
}
