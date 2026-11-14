#!/usr/bin/env bash
# project-standard v1.0 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# secrets.sh: the secrets engine. One private git repo per GitHub owner (SECRETS_DIR, cloned from SECRETS_REMOTE;
# make/common.mk picks the project's) holds the secrets of that owner's projects, encrypted with sops + age. Values reach processes through the environment only; nothing is ever
# written to disk in plain text (with-file uses a mode-600 file in a mode-700 dir, removed on exit).
#
# Usage: secrets.sh SUBCOMMAND [--project P] [--env E] [options] [NAME] [-- cmd args...]
#   exec --env E -- cmd...   with-file NAME -- cmd... {}   get NAME --env E
#   init [--gen]   set NAME --env E   unset NAME --env E   import [NAME] --file F [--env E]   edit --env local|common   list   check
#   keygen NAME --type T   rotate NAME --env E   ci   enroll   recovery   add-machine HOST
#   remove-machine HOST   sync   doctor
# Environment: PROJECT, SECRETS_DIR, STD_CONFIG, SECRETS_REMOTE, SOPS_AGE_KEY (CI), SECRETS_DEFAULT_DIR,
#   GITHUB_OWNER, STD_OWNER_FROM, STD_SE_IDENTITY, SECRETS_SCHEMA, STD_NO_SYNC.
# Plain text never reaches disk, except the mode-600 temp key of `with-file`. That includes the temp files
# bash 3.2 makes for here-documents and here-strings, so a value is never fed to a loop that way.
# Needs bash 3.2+, sops 3.10+, age, jq; age-plugin-se, gh and gitleaks where noted.

# SOPS_AGE_KEY is set on purpose inside subshells that run sops, so it never lands in this shell.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"
# shellcheck source=secret-patterns.sh
. "$SELF_DIR/secret-patterns.sh"

SECRETS_DIR="${SECRETS_DIR:-$HOME/.secrets}"
# the user config's owner's secrets repo (~/.secrets-<owner>): the first place a new repo copies the Macs' public
# recipients from; the other ~/.secrets-* on this Mac come after it
SECRETS_DEFAULT_DIR="${SECRETS_DEFAULT_DIR:-}"
STD_CONFIG="${STD_CONFIG:-$HOME/.config/project-standard}"
SE_IDENTITY="${STD_SE_IDENTITY:-$STD_CONFIG/age/se.txt}"
KEYCHAIN_SERVICE="project-standard-age-dev"
SECRETS_REMOTE="${SECRETS_REMOTE:-}"
GITHUB_OWNER="${GITHUB_OWNER:-}"
PROJECT="${PROJECT:-}"
SCHEMA="${SECRETS_SCHEMA:-secrets.schema}"
SYNC_INTERVAL_MIN=60

# An explicit SOPS_AGE_KEY (CI) wins over the Keychain and the Secure Enclave. Anything else that
# could point sops at an identity is cleared so the identity used is always the one chosen below.
CI_KEY="${SOPS_AGE_KEY:-}"
unset SOPS_AGE_KEY SOPS_AGE_KEY_FILE SOPS_AGE_KEY_CMD

OPT_ENV=""
OPT_TYPE=""
OPT_GEN=0
OPT_FORCE=0
OPT_HOST=""
OPT_FILE=""
POS=()
REST=()
_DEV_KEY=""

# --- argument parsing ---

# optarg_check OPTION COUNT   die when an option has no value.
optarg_check() { [ "$2" -ge 2 ] || die "option $1 needs a value"; }

parse_args() {
  POS=()
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) optarg_check "$1" $#; PROJECT="$2"; shift 2 ;;
      --env) optarg_check "$1" $#; OPT_ENV="$2"; shift 2 ;;
      --type) optarg_check "$1" $#; OPT_TYPE="$2"; shift 2 ;;
      --host) optarg_check "$1" $#; OPT_HOST="$2"; shift 2 ;;
      --file) optarg_check "$1" $#; OPT_FILE="$2"; shift 2 ;;
      --schema) optarg_check "$1" $#; SCHEMA="$2"; shift 2 ;;
      --gen) OPT_GEN=1; shift ;;
      --force) OPT_FORCE=1; shift ;;
      --) shift; REST=("$@"); return 0 ;;
      -*) die "unknown option: $1" ;;
      *) POS+=("$1"); shift ;;
    esac
  done
}

pos() { printf '%s' "${POS[$1]:-}"; }

need_project() {
  [ -n "$PROJECT" ] || die "no project: pass --project P or set PROJECT"
  valid_name "$PROJECT" || die "invalid project name: $PROJECT"
}

check_env() {
  case "$1" in
    local | staging | production | common) ;;
    '') die "no environment: pass --env local|staging|production" ;;
    *) die "invalid environment: $1" ;;
  esac
}

env_rel() { printf '%s/%s.env.sops' "$PROJECT" "$1"; }
key_rel() { printf '%s/keys/%s.sops' "$PROJECT" "$1"; }

# --- identities and sops ---

identity_kind() {
  case "$1" in
    local | common) printf 'dev' ;;
    *) printf 'se' ;;
  esac
}

# identity_name KIND   the identity that is really used: "ci" when SOPS_AGE_KEY was given, else KIND.
identity_name() {
  if [ -n "$CI_KEY" ]; then printf 'ci'; else printf '%s' "$1"; fi
}

dev_key() {
  if [ -z "$_DEV_KEY" ]; then
    _DEV_KEY="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "${USER:-$(id -un)}" -w 2>/dev/null)" ||
      die "no dev identity in the Keychain (service $KEYCHAIN_SERVICE); run: make secrets-enroll"
  fi
  printf '%s' "$_DEV_KEY"
}

# sops_as KIND ARGS...   run sops in SECRETS_DIR with the dev (Keychain) or se (Secure Enclave) identity.
# The key is passed through the environment of the sops process only, never through argv.
sops_as() {
  local kind="$1"
  shift
  if [ -n "$CI_KEY" ]; then
    (
      cd "$SECRETS_DIR"
      export SOPS_AGE_KEY="$CI_KEY"
      exec sops "$@"
    )
  elif [ "$kind" = dev ]; then
    local k
    k="$(dev_key)"
    (
      cd "$SECRETS_DIR"
      export SOPS_AGE_KEY="$k"
      exec sops "$@"
    )
  else
    [ -r "$SE_IDENTITY" ] || die "no Secure Enclave identity at $SE_IDENTITY; run: make secrets-enroll"
    (
      cd "$SECRETS_DIR"
      export SOPS_AGE_KEY_FILE="$SE_IDENTITY"
      exec sops "$@"
    )
  fi
}

# sops_plain ARGS...   sops without any identity (encrypt only; recipients come from .sops.yaml).
sops_plain() {
  (
    cd "$SECRETS_DIR"
    exec sops "$@"
  )
}

sops_type_for() {
  case "$1" in
    *.env.sops) printf 'dotenv' ;;
    *) printf 'binary' ;;
  esac
}

decrypt_env_file() { # KIND REL
  sops_as "$1" --decrypt --input-type dotenv --output-type dotenv "$2"
}

# --- the secrets repo ---

# legacy_dir   the pre-1.8 checkout ~/.secrets when it still waits to become ~/.secrets-<owner> of the user config's
# owner (STD_CONFIG_OWNER, from make): prints the new path, fails when there is nothing to move.
legacy_dir() {
  local owner="${STD_CONFIG_OWNER:-}"
  [ -n "$owner" ] && [ -d "$HOME/.secrets/.git" ] && [ ! -e "$HOME/.secrets-$owner" ] || return 1
  [ "$SECRETS_DIR" != "$HOME/.secrets" ] || return 1
  printf '%s\n' "$HOME/.secrets-$owner"
}

# legacy_hint   say how to move ~/.secrets to its 1.8 place, by hand; never moves anything.
legacy_hint() {
  local new
  new="$(legacy_dir)" || return 0
  log_warn "$HOME/.secrets is the pre-1.8 checkout of ${STD_CONFIG_OWNER}'s secrets repo; since 1.8 it is $new. Move it yourself (nothing is moved for you):"
  printf '  mv "$HOME/.secrets" "$HOME/.secrets-%s"\n' "$STD_CONFIG_OWNER" >&2
  printf '  git -C "$HOME/.secrets-%s" config core.hooksPath "$HOME/.secrets-%s/.git/hooks"\n' "$STD_CONFIG_OWNER" "$STD_CONFIG_OWNER" >&2
}

# require_repo   the repo exists; a core.hooksPath left pointing elsewhere (the repo was moved) is pinned again.
require_repo() {
  if [ ! -d "$SECRETS_DIR/.git" ]; then
    legacy_hint
    die "no secrets repo at $SECRETS_DIR; run: make secrets-init (clones ${SECRETS_REMOTE:-SECRETS_REMOTE}, or starts it when that is empty) or make secrets-enroll (new Mac)"
  fi
  if [ "$(git -C "$SECRETS_DIR" config core.hooksPath 2>/dev/null || true)" != "$SECRETS_DIR/.git/hooks" ]; then install_repo_hook; fi
}

git_s() { git -C "$SECRETS_DIR" "$@"; }

git_commit_args() {
  if [ -z "$(git_s config user.email 2>/dev/null || true)" ]; then
    printf '%s\n' "-c" "user.name=project-standard" "-c" "user.email=project-standard@localhost"
  fi
}

# commit_push MESSAGE   commit everything in the secrets repo and push when a remote exists.
commit_push() {
  local extra=() line
  while IFS= read -r line; do extra+=("$line"); done < <(git_commit_args)
  install_repo_hook
  git_s add -A
  if ! git_s diff --cached --quiet; then
    git_s -c "core.hooksPath=$SECRETS_DIR/.git/hooks" ${extra[@]+"${extra[@]}"} commit -q -m "$1"
  fi
  if git_s remote | grep -q .; then
    GIT_TERMINAL_PROMPT=0 git_s push -q origin HEAD 2>/dev/null || log_warn "could not push the secrets repo; run it again when online"
  fi
}

# sync_secrets [force]   git pull --ff-only at most once an hour; silent when offline.
sync_secrets() {
  [ -z "${STD_NO_SYNC:-}" ] || return 0
  [ -d "$SECRETS_DIR/.git" ] || return 0
  git_s remote | grep -q . || return 0
  local stamp="$SECRETS_DIR/.git/project-standard-pulled"
  if [ "${1:-}" != force ] && [ -f "$stamp" ] && [ -n "$(find "$stamp" -mmin "-$SYNC_INTERVAL_MIN" 2>/dev/null)" ]; then
    return 0
  fi
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=5 -o BatchMode=yes}" \
    git_s pull --ff-only -q origin "$(git_s rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1 || true
  : >"$stamp"
}

repo_hook_body() {
  cat <<'HOOK'
#!/usr/bin/env bash
# project-standard v1.0 secrets-repo pre-commit hook: refuses anything that is not SOPS-encrypted
set -euo pipefail
bad=0
while IFS= read -r -d '' f; do
  case "$f" in
    recipients/*.txt)
      if git show ":$f" | grep -q -i -E 'age-secret-key-1|age-plugin-[a-z]*-1'; then
        echo "secrets pre-commit: $f holds a private key; recipients/ takes public keys only" >&2
        bad=1
      fi
      continue ;;
    .sops.yaml | .gitignore | .gitattributes | README.md) continue ;;
    *.sops) ;;
    *)
      echo "secrets pre-commit: $f is not a .sops file; refusing to commit plain text" >&2
      bad=1
      continue ;;
  esac
  content="$(git show ":$f")"
  case "$f" in
    *.env.sops)
      if printf '%s\n' "$content" | grep -v -E '^(sops_[A-Za-z0-9_]*=.*)?$' | grep -v -E '^[A-Za-z_][A-Za-z0-9_]*=ENC\[' | grep -q .; then
        echo "secrets pre-commit: $f has a value that is not encrypted" >&2
        bad=1
      fi ;;
    *)
      if ! printf '%s\n' "$content" | grep -q '"data": "ENC\['; then
        echo "secrets pre-commit: $f is not a SOPS-encrypted file" >&2
        bad=1
      fi ;;
  esac
done < <(git diff --cached --name-only --no-renames --diff-filter=ACMR -z)
exit "$bad"
HOOK
}

# install_repo_hook   write the guard into the repo's own .git/hooks (never a tracked folder) and make
# git use exactly that folder, so a global core.hooksPath cannot switch it off. Rewritten before every commit.
install_repo_hook() {
  local hooks="$SECRETS_DIR/.git/hooks"
  [ -d "$SECRETS_DIR/.git" ] || return 0
  mkdir -p "$hooks"
  repo_hook_body >"$hooks/pre-commit.tmp.$$"
  chmod 755 "$hooks/pre-commit.tmp.$$"
  mv "$hooks/pre-commit.tmp.$$" "$hooks/pre-commit"
  git_s config core.hooksPath "$hooks"
  # an older version kept the hook in a tracked .githooks folder: drop it
  if [ -d "$SECRETS_DIR/.githooks" ]; then rm -rf -- "$SECRETS_DIR/.githooks"; fi
}

ensure_repo_files() {
  mkdir -p "$SECRETS_DIR/recipients"
  install_repo_hook
}

# remote_url REMOTE   the git URL for SECRETS_REMOTE: github.com/<owner>/<repo> or <owner>/<repo> becomes the SSH URL
# of that GitHub repo (the private repos are cloned over SSH); anything with a scheme, a host or a path is used as it is.
remote_url() {
  case "$1" in
    *://* | *@*:*) printf '%s\n' "$1" ;;
    github.com/*) printf 'git@github.com:%s.git\n' "${1#github.com/}" ;;
    [!/.~]*/*) printf 'git@github.com:%s.git\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# seed_source   the secrets repo on this Mac a new SECRETS_DIR copies its recipients from: SECRETS_DEFAULT_DIR (the user
# config's owner's) when it has Mac recipients, else the first other ~/.secrets-* that has. Fails when there is none.
seed_source() {
  local d here
  here="$(cd "$SECRETS_DIR" && pwd -P)"
  for d in ${SECRETS_DEFAULT_DIR:+"$SECRETS_DEFAULT_DIR"} "$HOME"/.secrets-*; do
    [ -d "$d/recipients" ] || continue
    [ "$(cd "$d" && pwd -P)" != "$here" ] || continue
    if [ -n "$(find "$d/recipients/se" "$d/recipients/dev" -name '*.txt' 2>/dev/null | head -n 1)" ]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

# seed_recipients   copy the Macs' public recipients (recipients/se/*.txt, recipients/dev/*.txt) and the recovery
# recipient (recipients/recovery.txt) from seed_source into a new SECRETS_DIR. Never the CI keys of its projects,
# never a private key (a file that holds one is skipped). Fails when nothing was copied.
seed_recipients() {
  local src f rel n=0 hosts=""
  src="$(seed_source)" || return 1
  for f in "$src"/recipients/se/*.txt "$src"/recipients/dev/*.txt "$src/recipients/recovery.txt"; do
    [ -f "$f" ] || continue
    rel="${f#"$src"/}"
    if grep -q -i -E 'age-secret-key-1|age-plugin-[a-z]*-1' "$f"; then
      log_warn "skipped $rel: it holds a private key; recipients take public keys only"
      continue
    fi
    mkdir -p "$SECRETS_DIR/$(dirname "$rel")"
    cp "$f" "$SECRETS_DIR/$rel"
    n=$((n + 1))
    case "$rel" in recipients/se/*) hosts="$hosts $(basename "$rel" .txt)" ;; esac
  done
  [ "$n" -gt 0 ] || return 1
  log_ok "copied $n public recipient(s) from $src: Macs:${hosts:- none}$([ -f "$SECRETS_DIR/recipients/recovery.txt" ] && printf '; the recovery key')"
}

# ensure_repo   clone SECRETS_REMOTE when there is one, otherwise git init; add the origin remote. A repo that did not
# exist here and whose remote is empty (or that has no remote) is a new secrets repo: it gets the Macs' and the
# recovery recipients of the default owner's repo, its .sops.yaml, a first commit, and is pushed.
ensure_repo() {
  need_cmd git
  local fresh=0
  if [ ! -d "$SECRETS_DIR/.git" ]; then
    # a pre-1.8 ~/.secrets is moved by hand first: a new checkout beside it would leave its unpushed work behind
    if [ ! -e "$SECRETS_DIR" ] && legacy_dir >/dev/null; then
      legacy_hint
      die "move ~/.secrets first (the commands above), then run this again"
    fi
    [ -e "$SECRETS_DIR" ] || fresh=1
    if [ -n "$SECRETS_REMOTE" ] && [ ! -e "$SECRETS_DIR" ]; then
      GIT_TERMINAL_PROMPT=0 git clone -q "$(remote_url "$SECRETS_REMOTE")" "$SECRETS_DIR" ||
        die "cannot clone $SECRETS_REMOTE into $SECRETS_DIR: create it first as an empty private repository (gh repo create <owner>/secrets --private), check access (gh auth status), then run this again"
      if git_s rev-parse -q --verify HEAD >/dev/null 2>&1; then
        fresh=0
      else
        git_s symbolic-ref HEAD refs/heads/main
      fi
    else
      mkdir -p "$SECRETS_DIR"
      git -C "$SECRETS_DIR" init -q -b main
    fi
  fi
  chmod 700 "$SECRETS_DIR"
  if [ -n "$SECRETS_REMOTE" ] && ! git_s remote | grep -q .; then
    git_s remote add origin "$(remote_url "$SECRETS_REMOTE")"
  fi
  ensure_repo_files
  if [ "$fresh" = 1 ]; then
    log_info "new secrets repo at $SECRETS_DIR${SECRETS_REMOTE:+ (origin $SECRETS_REMOTE)}"
    if seed_recipients; then
      gen_sops_yaml
      commit_push "new secrets repo: the Macs and the recovery key"
      log_ok "secrets repo $SECRETS_DIR started${SECRETS_REMOTE:+ and pushed to $SECRETS_REMOTE}"
    else
      log_warn "no other secrets repo on this Mac (~/.secrets-*) to copy the Macs from: enroll this Mac in the new repo (make secrets-enroll), then make secrets-recovery"
    fi
  fi
}

# --- recipients and .sops.yaml ---

read_recipient() {
  grep -v -E '^[[:space:]]*(#|$)' "$1" | head -n 1 | tr -d '[:space:]'
}

# collect KIND... : one public key per line. KIND: se dev recovery ci:NAME
collect() {
  local k f
  for k in "$@"; do
    case "$k" in
      se | dev)
        for f in "$SECRETS_DIR/recipients/$k"/*.txt; do
          if [ -e "$f" ]; then read_recipient "$f"; echo; fi
        done ;;
      recovery)
        if [ -e "$SECRETS_DIR/recipients/recovery.txt" ]; then read_recipient "$SECRETS_DIR/recipients/recovery.txt"; echo; fi ;;
      ci:*)
        f="$SECRETS_DIR/recipients/ci/${k#ci:}.txt"
        if [ -e "$f" ]; then read_recipient "$f"; echo; fi ;;
    esac
  done | grep -v '^$' | sort -u || true
}

# expected_kinds REL   which recipient kinds may decrypt the file at REL (project/file).
expected_kinds() {
  local p="${1%%/*}" rest="${1#*/}"
  case "$rest" in
    common.env.sops) printf 'se dev recovery ci:%s ci:%s-production' "$p" "$p" ;;
    local.env.sops) printf 'se dev recovery ci:%s' "$p" ;;
    production.env.sops) printf 'se recovery ci:%s-production' "$p" ;;
    *) printf 'se recovery ci:%s' "$p" ;;
  esac
}

projects() {
  {
    local d n
    for d in "$SECRETS_DIR"/*/; do
      [ -d "$d" ] || continue
      n="$(basename "$d")"
      [ "$n" = recipients ] || printf '%s\n' "$n"
    done
    if [ -n "$PROJECT" ]; then printf '%s\n' "$PROJECT"; fi
  } | sort -u
}

emit_rule() { # REGEX KIND...
  local regex="$1" keys k
  shift
  keys="$(collect "$@")"
  if [ -z "$keys" ]; then
    log_warn "no recipients for $regex; no rule written"
    return 0
  fi
  printf "  - path_regex: '%s'\n    key_groups:\n      - age:\n" "$regex"
  while IFS= read -r k; do printf '          - %s\n' "$k"; done <<EOF
$keys
EOF
}

gen_sops_yaml() {
  local out="$SECRETS_DIR/.sops.yaml.tmp.$$" p pe
  {
    printf '# generated by secrets.sh from recipients/ (do not edit; run make secrets-add-machine)\n'
    printf 'creation_rules:\n'
    for p in $(projects); do
      pe="${p//./\\.}"
      # production CI also reads common (account id and the like), never staging, local or keys
      emit_rule "^$pe/common\\.env\\.sops\$" se dev recovery "ci:$p" "ci:$p-production"
      emit_rule "^$pe/local\\.env\\.sops\$" se dev recovery "ci:$p"
      emit_rule "^$pe/staging\\.env\\.sops\$" se recovery "ci:$p"
      emit_rule "^$pe/keys/.*\\.sops\$" se recovery "ci:$p"
      emit_rule "^$pe/production\\.env\\.sops\$" se recovery "ci:$p-production"
    done
  } >"$out"
  mv "$out" "$SECRETS_DIR/.sops.yaml"
}

# all_sops_files   relative paths of every .sops file under project folders.
all_sops_files() {
  (cd "$SECRETS_DIR" && find . -mindepth 2 -name '*.sops' -not -path './.git/*' -not -path './recipients/*' | sed 's|^\./||' | sort)
}

update_all_keys() { # [PROJECT]
  local f only="${1:-}"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "$only" ] && [ "${f%%/*}" != "$only" ]; then continue; fi
    sops_as se updatekeys -y --input-type "$(sops_type_for "$f")" "$f" >/dev/null 2>&1 ||
      die "cannot re-encrypt $f (is this Mac enrolled and unlocked?)"
  done <<EOF
$(all_sops_files)
EOF
}

# --- schema ---

# schema_rows   NAME|envs|used-by|gen
schema_rows() {
  [ -f "$SCHEMA" ] || die "no secrets.schema ($SCHEMA); create it first"
  local name envs used gen _rest
  while read -r name envs used gen _rest || [ -n "$name" ]; do
    case "$name" in '' | '#'*) continue ;; esac
    valid_env_name "${name//-/_}" || die "secrets.schema: bad name '$name'"
    printf '%s|%s|%s|%s\n' "$name" "${envs:-}" "${used:-}" "${gen:-no}"
  done <"$SCHEMA"
}

schema_gen_for() { # NAME
  schema_rows | awk -F'|' -v n="$1" '$1 == n { print $4; exit }'
}

# schema_optional NAME   true when NAME's description (the rest of the line after the four columns) starts with
# "optional:": a value the project can do without (an app's signing names). Missing, it is a warning, not a problem.
schema_optional() { # NAME
  [ -f "$SCHEMA" ] || return 1
  awk -v n="$1" '
    $1 == n { d = $0; sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", d); found = (d ~ /^optional:/); exit }
    END { exit !found }' "$SCHEMA"
}

# --- values ---

random_value() { # BYTES
  head -c "$1" /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
}

read_secret_value() { # PROMPT ; value on stdout
  local v=""
  if [ -t 0 ] || [ -n "${STD_TTY:-}" ]; then
    local tty="${STD_TTY:-/dev/tty}"
    printf '%s' "$1" >&2
    IFS= read -r -s v <"$tty" || true
    printf '\n' >&2
  else
    # not a terminal: all of stdin, so multi-line values (PEM text, JSON) work; one final newline is dropped
    v="$(cat; printf x)"
    v="${v%x}"
    case "$v" in *$'\n'?*) ;; *) v="${v%$'\n'}" ;; esac
  fi
  printf '%s' "$v"
}

# set_value NAME ENV VALUE   create or update one value; VALUE never reaches argv or a file.
set_value() {
  local name="$1" env="$2" value="$3" rel
  valid_env_name "$name" || die "invalid secret name: $name"
  rel="$(env_rel "$env")"
  mkdir -p "$SECRETS_DIR/$PROJECT/keys"
  if [ -f "$SECRETS_DIR/$rel" ]; then
    printf '%s' "$value" | jq -Rs . | sops_as "$(identity_kind "$env")" set --input-type dotenv --output-type dotenv --value-stdin "$rel" "[\"$name\"]"
  else
    printf '%s=%s\n' "$name" "${value//$'\n'/\\n}" |
      sops_plain --encrypt --input-type dotenv --output-type dotenv --filename-override "$rel" /dev/stdin >"$SECRETS_DIR/$rel.tmp.$$" ||
      {
        rm -f "$SECRETS_DIR/$rel.tmp.$$"
        die "cannot create $rel (are there recipients? run make secrets-enroll)"
      }
    mv "$SECRETS_DIR/$rel.tmp.$$" "$SECRETS_DIR/$rel"
  fi
}

has_name() { # FILE NAME
  [ -f "$1" ] && grep -q -E "^$2=" "$1"
}

gen_key_stdout() { # TYPE
  need_cmd openssl
  case "$1" in
    ed25519) openssl genpkey -algorithm ed25519 ;;
    ecdsa-p256 | mcuboot-ecdsa-p256) openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 ;;
    rsa-3072 | espsecure-v2) openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 ;;
    *) die "unknown key type: $1 (ed25519, ecdsa-p256, rsa-3072, mcuboot-ecdsa-p256, espsecure-v2)" ;;
  esac
}

# keygen_into NAME TYPE   generate straight into keys/NAME.sops; refuses to overwrite.
keygen_into() {
  local name="$1" type="$2" rel tmp
  valid_name "$name" || die "invalid key name: $name"
  rel="$(key_rel "$name")"
  [ ! -e "$SECRETS_DIR/$rel" ] || die "keys/$name.sops already exists; refusing to overwrite it"
  mkdir -p "$SECRETS_DIR/$PROJECT/keys"
  tmp="$SECRETS_DIR/$rel.tmp.$$"
  if ! gen_key_stdout "$type" | sops_plain --encrypt --input-type binary --output-type binary --filename-override "$rel" /dev/stdin >"$tmp"; then
    rm -f "$tmp"
    die "key generation failed"
  fi
  mv "$tmp" "$SECRETS_DIR/$rel"
}

# --- subcommands: using secrets ---

# is_blocked_var NAME   names a secrets file may never put into a child's environment: they change how a
# shell, make, git, ssh, node, python or the dynamic linker behave, or steer this standard's own scripts.
is_blocked_var() {
  case "$1" in
    PATH | HOME | SHELL | IFS | USER | PWD | TMPDIR | BASH_ENV | ENV | PS4 | SHELLOPTS | BASHOPTS | PROMPT_COMMAND) return 0 ;;
    LD_* | DYLD_* | GIT_* | SSH_* | SOPS_* | STD_* | PYTHON* | NODE_OPTIONS | NODE_PATH | NODE_EXTRA_CA_CERTS) return 0 ;;
    npm_config_* | NPM_CONFIG_* | PERL5OPT | PERL5LIB | RUBYOPT | RUBYLIB | GOFLAGS | CURL_CA_BUNDLE | SSL_CERT_FILE | SSL_CERT_DIR) return 0 ;;
    MAKEFLAGS | MAKELEVEL | MAKEOVERRIDES | MFLAGS | CONFIRM | CF_SH_INNER | CF_API_BASE | CLOUDFLARE_API_BASE* | CLOUDFLARE_INCLUDE_PROCESS_ENV) return 0 ;;
    PROJECT | PORT_BASE | SECRETS_DIR | SECRETS_DEFAULT_DIR | SECRETS_REMOTE | SECRETS_SCHEMA | CI | GITHUB_ACTIONS | GITHUB_REF_NAME | GITHUB_REF_TYPE) return 0 ;;
  esac
  return 1
}

# declared_names ENV   the names secrets.schema declares for ENV or for common, space separated and padded
# with a space on both sides (" A B "), so a lookup is a plain pattern match.
declared_names() {
  local row name envs out=" "
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name="${row%%|*}"
    envs="${row#*|}"
    envs="${envs%%|*}"
    case ",$envs," in *,"$1",* | *,common,*) out="$out$name " ;; esac
  done <<EOF
$(schema_rows)
EOF
  printf '%s' "$out"
}

# export_dotenv TEXT [ALLOWED]   export KEY=VALUE lines into this shell without any temp file or here-string.
# With ALLOWED (" A B "), only those names are exported.
export_dotenv() {
  local rest="$1" allowed="${2:-}" line k v
  while [ -n "$rest" ]; do
    line="${rest%%$'\n'*}"
    if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*$'\n'}"; fi
    case "$line" in '' | '#'*) continue ;; esac
    k="${line%%=*}"
    v="${line#*=}"
    valid_env_name "$k" || continue
    if is_blocked_var "$k"; then
      log_warn "not exporting $k from secrets (reserved name)"
      continue
    fi
    if [ -n "$allowed" ]; then
      case "$allowed" in
        *" $k "*) ;;
        *)
          log_warn "not exporting $k: it is not declared in $SCHEMA for this environment"
          continue ;;
      esac
    fi
    v="${v//\\n/$'\n'}"
    export "$k=$v"
  done
}

# dotenv_value TEXT NAME   print the value of NAME in dotenv TEXT decoded exactly as export_dotenv does
# (a literal backslash-n becomes a newline); returns 1 when NAME is not there. No here-document: the text
# is walked with parameter expansion, so the decrypted values never touch a temp file.
dotenv_value() {
  local rest="$1" line v
  while [ -n "$rest" ]; do
    line="${rest%%$'\n'*}"
    if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*$'\n'}"; fi
    case "$line" in
      "$2="*)
        v="${line#*=}"
        printf '%s\n' "${v//\\n/$'\n'}"
        return 0 ;;
    esac
  done
  return 1
}

cmd_exec() {
  parse_args "$@"
  need_project
  check_env "$OPT_ENV"
  [ "${#REST[@]}" -gt 0 ] || die "usage: secrets.sh exec --env E -- cmd args..."
  local kind e rel text="" out allowed=""
  kind="$(identity_kind "$OPT_ENV")"
  if [ ! -d "$SECRETS_DIR/$PROJECT" ] && [ "$OPT_ENV" = local ]; then
    legacy_hint
    log_warn "no secrets for $PROJECT in $SECRETS_DIR; running without them (make secrets-init)"
  else
    case "$OPT_ENV" in
      staging | production)
        # only what the schema declares reaches a deploy: a stray or planted name in the file stays out
        [ -f "$SCHEMA" ] || die "no secrets.schema ($SCHEMA): $OPT_ENV only exports the names it declares"
        allowed="$(declared_names "$OPT_ENV")" ;;
    esac
    sync_secrets
    for e in common "$OPT_ENV"; do
      rel="$(env_rel "$e")"
      if [ ! -f "$SECRETS_DIR/$rel" ]; then
        [ "$e" = common ] && continue
        [ "$OPT_ENV" = local ] && continue
        die "no $rel; run: make secrets-init"
      fi
      out="$(decrypt_env_file "$kind" "$rel")" || die "cannot decrypt $rel with the $(identity_name "$kind") identity"
      text="$text$out"$'\n'
    done
    export_dotenv "$text" "$allowed"
  fi
  unset text out SOPS_AGE_KEY SOPS_AGE_KEY_FILE _DEV_KEY CI_KEY
  exec "${REST[@]}"
}

cmd_with_file() {
  parse_args "$@"
  need_project
  local name rel dir file rc=0 args=() a
  name="$(pos 0)"
  valid_name "$name" || die "usage: secrets.sh with-file NAME -- cmd args... {}"
  [ "${#REST[@]}" -gt 0 ] || die "usage: secrets.sh with-file NAME -- cmd args... {}"
  rel="$(key_rel "$name")"
  [ -f "$SECRETS_DIR/$rel" ] || die "no key $rel; create it with: make secrets-keygen NAME=$name"
  sync_secrets
  dir="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/std-key.XXXXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$dir'" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  chmod 700 "$dir"
  file="$dir/$name"
  (umask 077 && sops_as se --decrypt --input-type binary --output-type binary --output "$file" "$rel") ||
    die "cannot decrypt $rel"
  chmod 600 "$file"
  for a in "${REST[@]}"; do args+=("${a//\{\}/$file}"); done
  "${args[@]}" || rc=$?
  exit "$rc"
}

cmd_get() {
  parse_args "$@"
  need_project
  local name e rel out
  name="$(pos 0)"
  valid_env_name "$name" || die "usage: secrets.sh get NAME --env E"
  check_env "$OPT_ENV"
  sync_secrets
  for e in "$OPT_ENV" common; do
    rel="$(env_rel "$e")"
    [ -f "$SECRETS_DIR/$rel" ] || continue
    has_name "$SECRETS_DIR/$rel" "$name" || continue
    out="$(decrypt_env_file "$(identity_kind "$OPT_ENV")" "$rel")" || die "cannot decrypt $rel with the $(identity_name "$(identity_kind "$OPT_ENV")") identity"
    # no here-document or here-string: bash 3.2 backs those with a file in /var/tmp
    if dotenv_value "$out" "$name"; then return 0; fi
  done
  die "$name not found for $OPT_ENV"
}

# --- subcommands: writing ---

cmd_set() {
  parse_args "$@"
  need_project
  local name value
  name="$(pos 0)"
  valid_env_name "$name" || die "invalid secret name '$name' (letters, digits and _; not starting with a digit or sops_); usage: secrets.sh set NAME --env E"
  check_env "$OPT_ENV"
  require_repo
  sync_secrets
  value="$(read_secret_value "$name ($OPT_ENV): ")"
  [ -n "$value" ] || die "empty value; nothing set"
  # the first value of a project: .sops.yaml may not know this project's rules yet
  if [ ! -f "$SECRETS_DIR/$(env_rel "$OPT_ENV")" ]; then gen_sops_yaml; fi
  set_value "$name" "$OPT_ENV" "$value"
  value=""
  commit_push "set $name ($PROJECT $OPT_ENV)"
  log_ok "set $name for $PROJECT/$OPT_ENV"
}

# clean_editor_cmd   the editor sops should start: the user's $SOPS_EDITOR, $EDITOR or $VISUAL (default vi), with
# the options that stop vim and neovim from keeping a copy of the plain text in a swap, undo, backup or
# viminfo/shada file. Other editors are used as they are, with a warning.
clean_editor_cmd() {
  local ed="${SOPS_EDITOR:-${EDITOR:-${VISUAL:-vi}}}" first base
  first="${ed%% *}"
  base="${first##*/}"
  case "$base" in
    nvim) printf '%s -n -i NONE --cmd "set noundofile noswapfile nobackup nowritebackup"' "$ed" ;;
    vim | vi | view | gvim) printf '%s -n -i NONE -c "set noundofile noswapfile nobackup nowritebackup"' "$ed" ;;
    *)
      log_warn "editor '$base' may keep copies of the decrypted text (swap, backup or history files)"
      printf '%s' "$ed" ;;
  esac
}

# cmd_edit: only local and common. Staging and production values never go through an editor: sops edit writes
# the plain text to a temp file and editors keep more copies of it, so those environments use set / import.
cmd_edit() {
  parse_args "$@"
  need_project
  check_env "$OPT_ENV"
  case "$OPT_ENV" in
    local | common) ;;
    *) die "refused: edit is only for local and common; for $OPT_ENV use: make secrets-set NAME=... ENV=$OPT_ENV (or secrets-import FILE=... ENV=$OPT_ENV)" ;;
  esac
  require_repo
  sync_secrets
  local rel editor tmp rc=0
  rel="$(env_rel "$OPT_ENV")"
  [ -f "$SECRETS_DIR/$rel" ] || die "no $rel yet; set a value first (make secrets-set)"
  editor="$(clean_editor_cmd)"
  # sops writes the plain text into $TMPDIR: give it a private folder that is removed afterwards
  tmp="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/std-edit.XXXXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" EXIT
  (
    export TMPDIR="$tmp" SOPS_EDITOR="$editor"
    unset EDITOR VISUAL
    sops_as "$(identity_kind "$OPT_ENV")" edit --input-type dotenv --output-type dotenv "$rel"
  ) || rc=$?
  rm -rf -- "$tmp"
  trap - EXIT
  [ "$rc" -eq 0 ] || exit "$rc"
  commit_push "edit $PROJECT $OPT_ENV"
}

# cmd_import: NAME --file PATH (key file into keys/) or --file PATH --env E (KEY=VALUE pairs merged into E).
cmd_import() {
  parse_args "$@"
  need_project
  local name src="$OPT_FILE" rel line k v conflicts="" pairs=0 e="$OPT_ENV"
  [ -n "$src" ] || die "usage: secrets.sh import NAME --file PATH   or   secrets.sh import --file PATH --env E"
  [ -r "$src" ] || die "cannot read $src"
  require_repo
  need_cmd sops
  sync_secrets
  if [ -z "$e" ]; then
    name="$(pos 0)"
    valid_name "$name" || die "usage: secrets.sh import NAME --file PATH"
    rel="$(key_rel "$name")"
    [ ! -e "$SECRETS_DIR/$rel" ] || die "keys/$name.sops already exists; refusing to overwrite it"
    gen_sops_yaml
    mkdir -p "$SECRETS_DIR/$PROJECT/keys"
    sops_plain --encrypt --input-type binary --output-type binary --filename-override "$rel" /dev/stdin <"$src" >"$SECRETS_DIR/$rel.tmp.$$" ||
      { rm -f "$SECRETS_DIR/$rel.tmp.$$"; die "could not encrypt $src"; }
    mv "$SECRETS_DIR/$rel.tmp.$$" "$SECRETS_DIR/$rel"
    commit_push "import key $name ($PROJECT)"
    log_ok "imported $src as keys/$name.sops"
    log_info "now remove the plain file and purge it from git history if it was tracked: $src"
    return 0
  fi
  check_env "$e"
  rel="$(env_rel "$e")"
  gen_sops_yaml
  # first pass: refuse on conflicts
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#export }"
    case "$line" in '' | '#'*) continue ;; esac
    k="${line%%=*}"
    valid_env_name "$k" || continue
    pairs=$((pairs + 1))
    if has_name "$SECRETS_DIR/$rel" "$k"; then conflicts="$conflicts $k"; fi
  done <"$src"
  [ "$pairs" -gt 0 ] || die "no KEY=VALUE lines in $src"
  if [ -n "$conflicts" ] && [ "$OPT_FORCE" = 0 ]; then
    die "already set in $e:$conflicts (use --force to overwrite)"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#export }"
    case "$line" in '' | '#'*) continue ;; esac
    k="${line%%=*}"
    v="${line#*=}"
    valid_env_name "$k" || continue
    case "$v" in
      \"*\") v="${v#\"}"; v="${v%\"}" ;;
      \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    [ -n "$v" ] || { log_warn "skipping $k (empty)"; continue; }
    set_value "$k" "$e" "$v"
  done <"$src"
  v=""
  commit_push "import $pairs value(s) ($PROJECT $e)"
  log_ok "imported $pairs value(s) into $PROJECT/$e"
  log_info "now remove the plain file and purge it from git history if it was tracked: $src"
}

cmd_unset() {
  parse_args "$@"
  need_project
  local name rel
  name="$(pos 0)"
  valid_env_name "$name" || die "usage: secrets.sh unset NAME --env E"
  check_env "$OPT_ENV"
  require_repo
  sync_secrets
  rel="$(env_rel "$OPT_ENV")"
  has_name "$SECRETS_DIR/$rel" "$name" || { log_info "$name is not set for $PROJECT/$OPT_ENV"; return 0; }
  sops_as "$(identity_kind "$OPT_ENV")" unset --input-type dotenv --output-type dotenv "$rel" "[\"$name\"]"
  commit_push "unset $name ($PROJECT $OPT_ENV)"
  log_ok "removed $name from $PROJECT/$OPT_ENV"
}

cmd_init() {
  parse_args "$@"
  need_project
  need_cmd sops
  need_cmd jq
  ensure_repo
  mkdir -p "$SECRETS_DIR/$PROJECT/keys"
  [ -n "$(collect se dev recovery)" ] || die "no recipients in $SECRETS_DIR/recipients; run first: make secrets-enroll"
  gen_sops_yaml
  local name envs used gen e rel value missing=0 genok
  while IFS='|' read -r name envs used gen; do
    [ -n "$name" ] || continue
    if [ "$envs" = keys ]; then
      rel="$(key_rel "$name")"
      [ -e "$SECRETS_DIR/$rel" ] && continue
      if [ "$OPT_GEN" = 1 ] && [ "$gen" != no ]; then
        keygen_into "$name" "$gen"
        log_ok "generated key $name"
      elif schema_optional "$name"; then
        log_info "optional key $name not set: make secrets-keygen NAME=$name TYPE=${gen/no/ed25519} (or secrets-import)"
      else
        log_warn "missing key $name: make secrets-keygen NAME=$name TYPE=${gen/no/ed25519}"
        missing=$((missing + 1))
      fi
      continue
    fi
    for e in $(printf '%s' "$envs" | tr ',' ' '); do
      check_env "$e"
      rel="$(env_rel "$e")"
      if has_name "$SECRETS_DIR/$rel" "$name"; then continue; fi
      value=""
      genok=0
      case "$gen" in
        no | '') ;;
        *[!0-9]*) ;;
        *) if [ "$OPT_GEN" = 1 ]; then value="$(random_value "$gen")"; genok=1; fi ;;
      esac
      if [ "$genok" = 0 ] && [ -t 0 ]; then
        value="$(read_secret_value "$name ($e, Enter to skip): ")"
      fi
      if [ -n "$value" ]; then
        set_value "$name" "$e" "$value"
        log_ok "set $name ($e)"
      elif schema_optional "$name"; then
        log_info "optional $name ($e) not set: make secrets-set NAME=$name ENV=$e"
      else
        log_warn "missing $name ($e): make secrets-set NAME=$name ENV=$e"
        missing=$((missing + 1))
      fi
      value=""
    done
  done <<EOF
$(schema_rows)
EOF
  commit_push "init $PROJECT"
  if [ "$missing" -gt 0 ]; then log_info "$missing value(s) still missing"; fi
}

cmd_keygen() {
  parse_args "$@"
  need_project
  local name type
  name="$(pos 0)"
  [ -n "$name" ] || die "usage: secrets.sh keygen NAME --type TYPE"
  type="${OPT_TYPE:-}"
  if [ -z "$type" ] && [ -f "$SCHEMA" ]; then
    type="$(schema_gen_for "$name")"
    [ "$type" != no ] || type=""
  fi
  [ -n "$type" ] || die "no key type: pass --type ed25519|ecdsa-p256|rsa-3072|mcuboot-ecdsa-p256|espsecure-v2"
  require_repo
  sync_secrets
  gen_sops_yaml
  keygen_into "$name" "$type"
  commit_push "keygen $name ($PROJECT)"
  log_ok "created keys/$name.sops ($type)"
}

cmd_rotate() {
  parse_args "$@"
  need_project
  local name gen value
  name="$(pos 0)"
  valid_env_name "$name" || die "usage: secrets.sh rotate NAME --env E"
  check_env "$OPT_ENV"
  require_repo
  sync_secrets
  gen=""
  if [ -f "$SCHEMA" ]; then gen="$(schema_gen_for "$name")"; fi
  case "$gen" in
    '' | no | *[!0-9]*) value="$(read_secret_value "new value for $name ($OPT_ENV): ")" ;;
    *) value="$(random_value "$gen")" ;;
  esac
  [ -n "$value" ] || die "empty value; nothing rotated"
  set_value "$name" "$OPT_ENV" "$value"
  value=""
  commit_push "rotate $name ($PROJECT $OPT_ENV)"
  log_ok "rotated $name for $PROJECT/$OPT_ENV"
  log_info "push it to Cloudflare: make cf-secrets ENV=$OPT_ENV ROTATE=$name"
}

# --- subcommands: reading ---

cmd_list() {
  parse_args "$@"
  need_project
  local name envs used gen e rel status shown=""
  [ -d "$SECRETS_DIR/$PROJECT" ] || { legacy_hint; log_warn "no $SECRETS_DIR/$PROJECT yet (make secrets-init)"; }
  printf '%-28s %-11s %-12s %s\n' NAME ENV USED-BY STATE
  while IFS='|' read -r name envs used gen; do
    [ -n "$name" ] || continue
    if [ "$envs" = keys ]; then
      if [ -e "$SECRETS_DIR/$(key_rel "$name")" ]; then status="$(paint 1 green present)"; elif schema_optional "$name"; then status="$(paint 1 yellow 'not set (optional)')"; else status="$(paint 1 red missing)"; fi
      printf '%-28s %-11s %-12s %s\n' "$name" keys "$used" "$status"
      continue
    fi
    for e in $(printf '%s' "$envs" | tr ',' ' '); do
      rel="$(env_rel "$e")"
      if has_name "$SECRETS_DIR/$rel" "$name"; then status="$(paint 1 green present)"; elif schema_optional "$name"; then status="$(paint 1 yellow 'not set (optional)')"; else status="$(paint 1 red missing)"; fi
      printf '%-28s %-11s %-12s %s\n' "$name" "$e" "$used" "$status"
    done
    shown="$shown $name"
  done <<EOF
$(schema_rows)
EOF
  # names in the files that the schema does not know
  for e in common local staging production; do
    rel="$SECRETS_DIR/$(env_rel "$e")"
    [ -f "$rel" ] || continue
    grep -o -E '^[A-Za-z_][A-Za-z0-9_]*=' "$rel" | tr -d '=' | grep -v '^sops_' | while IFS= read -r name; do
      if ! schema_rows | grep -q "^$name|"; then printf '%-28s %-11s %-12s %s\n' "$name" "$e" "-" "$(paint 1 yellow 'not in schema')"; fi
    done || true
  done
}

# tracked_secret_files   tracked secret files (the list and the .npmrc check are in secret-patterns.sh, shared with audit.sh).
tracked_secret_files() {
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  local f
  while IFS= read -r f; do
    [ "$(std_secret_class "$f")" = secret ] && printf '%s\n' "$f"
  done < <(git ls-files)
  return 0
}

expected_set() { # REL ; sorted keys one per line
  # shellcheck disable=SC2046
  collect $(expected_kinds "$1")
}

actual_set() { # FILE
  { sed -n -E 's/^sops_age__list_[0-9]+__map_recipient=(.*)$/\1/p' "$1"
    sed -n -E 's/^[[:space:]]*"recipient": "([^"]+)".*$/\1/p' "$1"; } | sort -u
}

cmd_check() {
  parse_args "$@"
  need_project
  local problems=0 name envs used gen e rel f exp act opt
  [ -d "$SECRETS_DIR/$PROJECT" ] || { log_warn "no $SECRETS_DIR/$PROJECT (make secrets-init)"; }
  if [ -f "$SCHEMA" ]; then
    while IFS='|' read -r name envs used gen; do
      [ -n "$name" ] || continue
      # a row whose description starts with "optional:" is a warning when missing, never a problem
      opt=0
      schema_optional "$name" && opt=1
      if [ "$envs" = keys ]; then
        if [ ! -e "$SECRETS_DIR/$(key_rel "$name")" ]; then
          if [ "$opt" = 1 ]; then
            log_warn "optional key not set: $name"
          else
            log_err "missing key: $name"
            problems=$((problems + 1))
          fi
        fi
        continue
      fi
      for e in $(printf '%s' "$envs" | tr ',' ' '); do
        if ! has_name "$SECRETS_DIR/$(env_rel "$e")" "$name"; then
          if [ "$opt" = 1 ]; then
            log_warn "optional, not set: $name ($e)"
          else
            log_err "missing: $name ($e)"
            problems=$((problems + 1))
          fi
        fi
      done
    done <<EOF
$(schema_rows)
EOF
  else
    log_warn "no $SCHEMA; skipping the completeness check"
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "${f%%/*}" = "$PROJECT" ] || continue
    exp="$(expected_set "$f")"
    act="$(actual_set "$SECRETS_DIR/$f")"
    if [ "$exp" != "$act" ]; then
      log_err "wrong recipients on $f (run: make secrets-add-machine HOST=...)"
      problems=$((problems + 1))
    fi
  done <<EOF
$(all_sops_files)
EOF
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    log_err "secret file tracked in the project repo: $f (git rm --cached, then move it with make secrets-set)"
    problems=$((problems + 1))
  done <<EOF
$(tracked_secret_files)
EOF
  # gitleaks scans the working tree, git-ignored folders included (node_modules, .next, build): a finding in a file
  # git ignores is never committed, so only the others count. The report holds redacted findings, never a value.
  if [ -z "${STD_SKIP_GITLEAKS:-}" ] && command -v gitleaks >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    local report list f
    report="$(mktemp "${TMPDIR:-/tmp}/gitleaks.XXXXXX")"
    if gitleaks dir . --redact --no-banner -f json -r "$report" >/dev/null 2>&1; then
      list=""
    elif list="$(jq -r '.[].File' "$report" 2>/dev/null | sort -u)"; then
      :
    else
      list="."
    fi
    rm -f "$report"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ "$f" != . ] && git check-ignore -q -- "$f" 2>/dev/null; then continue; fi
      log_err "gitleaks found something in ${f#./} (run: gitleaks dir . --redact)"
      problems=$((problems + 1))
    done <<EOF
$list
EOF
  fi
  if [ "$problems" -gt 0 ]; then
    log_err "$problems problem(s)"
    return 1
  fi
  log_ok "secrets for $PROJECT look complete and correctly encrypted"
}

# --- subcommands: machines and CI ---

local_host() {
  local h
  h="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
  printf '%s' "$h" | tr -c 'A-Za-z0-9._-' '-'
}

cmd_enroll() {
  parse_args "$@"
  need_cmd sops
  need_cmd age-keygen
  need_cmd age-plugin-se "brew install age-plugin-se"
  need_cmd security
  local host se_pub dev_key dev_pub
  host="${OPT_HOST:-$(local_host)}"
  valid_name "$host" || die "invalid host name: $host"
  ensure_repo
  mkdir -p "$STD_CONFIG/age"
  chmod 700 "$STD_CONFIG/age"
  if [ ! -s "$SE_IDENTITY" ]; then
    age-plugin-se keygen --access-control=any-biometry -o "$SE_IDENTITY" >/dev/null 2>&1 || die "Secure Enclave key generation failed"
    chmod 600 "$SE_IDENTITY"
  fi
  se_pub="$(age-plugin-se recipients -i "$SE_IDENTITY")"
  if dev_key="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "${USER:-$(id -un)}" -w 2>/dev/null)"; then
    :
  else
    dev_key="$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')"
    printf 'add-generic-password -U -s %s -a %s -w %s\n' "$KEYCHAIN_SERVICE" "${USER:-$(id -un)}" "$dev_key" | security -i >/dev/null ||
      die "could not store the dev identity in the Keychain"
  fi
  dev_pub="$(printf '%s\n' "$dev_key" | age-keygen -y)"
  dev_key=""
  mkdir -p "$SECRETS_DIR/recipients/se" "$SECRETS_DIR/recipients/dev"
  printf '%s\n' "$se_pub" >"$SECRETS_DIR/recipients/se/$host.txt"
  printf '%s\n' "$dev_pub" >"$SECRETS_DIR/recipients/dev/$host.txt"
  if [ -z "$(all_sops_files)" ]; then gen_sops_yaml; fi
  commit_push "enroll $host"
  log_ok "enrolled $host"
  if [ "$(find "$SECRETS_DIR/recipients/se" -name '*.txt' | wc -l | tr -d ' ')" -le 1 ]; then
    log_info "this is the first Mac: nothing to re-encrypt"
  else
    log_info "on an enrolled Mac run: make secrets-add-machine HOST=$host"
  fi
  if [ ! -e "$SECRETS_DIR/recipients/recovery.txt" ]; then
    log_warn "no recovery key yet: this Mac's key cannot be exported, so losing it loses every secret; run: secrets.sh recovery"
  fi
}

# recovery: create the offline recovery key. Its private half is shown once, on the terminal only, and
# never written to disk; its public half goes to recipients/recovery.txt and every file is re-encrypted.
cmd_recovery() {
  parse_args "$@"
  need_cmd age-keygen
  require_repo
  [ -t 1 ] || die "recovery shows a private key: run it in a terminal, not through a pipe, a log or an agent"
  if [ -e "$SECRETS_DIR/recipients/recovery.txt" ] && [ "$OPT_FORCE" != 1 ]; then
    die "a recovery key exists already; --force makes a new one (the old one opens old commits until values are rotated)"
  fi
  sync_secrets force
  local key pub
  key="$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')"
  pub="$(printf '%s\n' "$key" | age-keygen -y)"
  [ -n "$pub" ] || die "could not create the recovery key"
  printf '%s\n' "$pub" >"$SECRETS_DIR/recipients/recovery.txt"
  gen_sops_yaml
  if [ -n "$(all_sops_files)" ]; then update_all_keys; fi
  commit_push "recovery key"
  log_ok "recovery key added; every file is encrypted to it"
  printf '\n  %s\n\n' "$key"
  key=""
  log_warn "write this key down now and keep it offline (paper in a safe). It is not stored anywhere and it opens every secret."
  log_info "clear this terminal's scrollback afterwards (cmd+K in Terminal.app)"
}

cmd_add_machine() {
  parse_args "$@"
  need_cmd sops
  local host
  host="$(pos 0)"
  [ -n "$host" ] || host="$OPT_HOST"
  valid_name "$host" || die "usage: secrets.sh add-machine HOST"
  require_repo
  sync_secrets force
  [ -e "$SECRETS_DIR/recipients/se/$host.txt" ] || [ -e "$SECRETS_DIR/recipients/dev/$host.txt" ] ||
    die "no recipients for $host in $SECRETS_DIR/recipients; run secrets-enroll on that Mac first"
  gen_sops_yaml
  update_all_keys
  commit_push "add machine $host"
  log_ok "re-encrypted every file for $host"
}

cmd_remove_machine() {
  parse_args "$@"
  need_cmd sops
  local host had_se=0 p f
  host="$(pos 0)"
  [ -n "$host" ] || host="$OPT_HOST"
  valid_name "$host" || die "usage: secrets.sh remove-machine HOST"
  require_repo
  sync_secrets force
  [ -e "$SECRETS_DIR/recipients/se/$host.txt" ] && had_se=1
  rm -f -- "$SECRETS_DIR/recipients/se/$host.txt" "$SECRETS_DIR/recipients/dev/$host.txt"
  gen_sops_yaml
  update_all_keys
  commit_push "remove machine $host"
  log_ok "$host can no longer decrypt new versions of the files"
  log_warn "old ciphertext stays in git history: rotate every value $host could read"
  for p in $(projects); do
    for f in common local staging production; do
      [ -f "$SECRETS_DIR/$p/$f.env.sops" ] || continue
      if [ "$had_se" = 0 ] && [ "$f" != common ] && [ "$f" != local ]; then continue; fi
      printf '%s/%s: %s\n' "$p" "$f" "$(grep -o -E '^[A-Za-z_][A-Za-z0-9_]*=' "$SECRETS_DIR/$p/$f.env.sops" | tr -d '=' | grep -v '^sops_' | tr '\n' ' ')"
    done
    if [ "$had_se" = 1 ] && [ -d "$SECRETS_DIR/$p/keys" ]; then
      for f in "$SECRETS_DIR/$p/keys"/*.sops; do
        if [ -e "$f" ]; then printf '%s/keys: %s\n' "$p" "$(basename "$f" .sops)"; fi
      done
    fi
  done
}

# ci_store_secret: store the key on stdin as the GitHub Actions secret SOPS_AGE_KEY of the project's repo. gh reads the
# value from stdin, so it is never on an argument list. One secret for every environment: environment secrets need a
# paid plan for private repos, so production jobs use the same key, and the production workflow is guarded by its
# workflow_dispatch confirm.
ci_store_secret() {
  local key="$1"
  [ -n "$GITHUB_OWNER" ] || die "GITHUB_OWNER is not set: put GITHUB_OWNER := <your GitHub account> in the user config (~/.config/project-standard/config.mk)"
  printf '%s' "$key" | gh secret set SOPS_AGE_KEY --repo "$GITHUB_OWNER/$PROJECT" >/dev/null
}

# cmd_ci: the CI key of the project is created once and stored as the repo secret SOPS_AGE_KEY. Its public key is the
# recipient of the staging, signing and production files (production gets the same key: see ci_store_secret).
cmd_ci() {
  parse_args "$@"
  need_project
  need_cmd gh
  need_cmd age-keygen
  require_repo
  sync_secrets
  local name="$PROJECT" key pub made=0
  if [ -e "$SECRETS_DIR/recipients/ci/$name.txt" ] && [ "$OPT_FORCE" = 0 ]; then
    log_info "ci key $name exists (use --force to replace it)"
  else
    key="$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')" || die "age-keygen failed"
    pub="$(printf '%s\n' "$key" | age-keygen -y)"
    ci_store_secret "$key" || die "gh could not store the CI key as SOPS_AGE_KEY of $GITHUB_OWNER/$PROJECT (gh auth status?)"
    key=""
    mkdir -p "$SECRETS_DIR/recipients/ci"
    printf '%s\n' "$pub" >"$SECRETS_DIR/recipients/ci/$name.txt"
    printf '%s\n' "$pub" >"$SECRETS_DIR/recipients/ci/$name-production.txt"
    made=1
    log_ok "CI key stored as the GitHub Actions secret SOPS_AGE_KEY of $GITHUB_OWNER/$PROJECT (one key for staging and production)"
  fi
  gen_sops_yaml
  update_all_keys "$PROJECT"
  commit_push "ci keys for $PROJECT"
  [ "$made" -gt 0 ] || log_info "nothing new; files re-checked"
}

cmd_sync() {
  parse_args "$@"
  require_repo
  sync_secrets force
  log_ok "secrets repo up to date"
}

cmd_doctor() {
  parse_args "$@"
  local fails=0 t n
  for t in sops age age-keygen jq git; do
    if command -v "$t" >/dev/null 2>&1; then log_ok "$t"; else log_err "$t not found (brew install $t)"; fails=$((fails + 1)); fi
  done
  for t in age-plugin-se gh gitleaks; do
    if command -v "$t" >/dev/null 2>&1; then log_ok "$t"; else log_warn "$t not found (brew install $t)"; fi
  done
  if [ -r "$SE_IDENTITY" ]; then log_ok "Secure Enclave identity $SE_IDENTITY"; else log_warn "no Secure Enclave identity (make secrets-enroll)"; fi
  if [ -n "$CI_KEY" ]; then
    log_ok "SOPS_AGE_KEY is set (CI)"
  elif command -v security >/dev/null 2>&1; then
    if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "${USER:-$(id -un)}" >/dev/null 2>&1; then log_ok "dev identity in the Keychain"; else log_warn "no dev identity in the Keychain (make secrets-enroll)"; fi
  fi
  if [ -n "$GITHUB_OWNER" ]; then
    case "${STD_OWNER_FROM:-}" in
      origin) log_ok "owner $GITHUB_OWNER (the project's git remote origin)" ;;
      ci) log_ok "owner $GITHUB_OWNER (GitHub Actions)" ;;
      config) log_warn "owner $GITHUB_OWNER from the user config: the project has no GitHub remote origin yet; its secrets repo follows the origin's owner once it has one" ;;
      *) log_info "owner $GITHUB_OWNER" ;;
    esac
  elif [ -n "${STD_OWNER_FROM+x}" ]; then
    log_warn "no GitHub owner: no remote origin on github.com and no GITHUB_OWNER in the user config"
  fi
  legacy_hint
  if [ -d "$SECRETS_DIR/.git" ]; then
    log_ok "secrets repo $SECRETS_DIR${SECRETS_REMOTE:+ ($SECRETS_REMOTE)}"
    git_s remote | grep -q . || log_warn "the secrets repo has no remote (SECRETS_REMOTE)"
    if [ -x "$SECRETS_DIR/.git/hooks/pre-commit" ] && [ "$(git_s config core.hooksPath || true)" = "$SECRETS_DIR/.git/hooks" ]; then
      log_ok "secrets repo pre-commit hook"
    else
      log_warn "secrets repo hook not active (run any write command to install it)"
    fi
    for t in se dev; do
      n="$(collect "$t" | grep -c . || true)"
      if [ "$n" -gt 0 ]; then log_ok "$n $t recipient(s)"; else log_warn "no $t recipients"; fi
    done
    if [ -n "$(collect recovery)" ]; then log_ok "recovery recipient"; else log_warn "no recovery recipient (recipients/recovery.txt)"; fi
  else
    log_warn "no secrets repo at $SECRETS_DIR"
  fi
  if [ -n "$PROJECT" ] && [ -f "$SCHEMA" ] && [ -d "$SECRETS_DIR/$PROJECT" ]; then
    cmd_check || fails=$((fails + 1))
  fi
  [ "$fails" = 0 ]
}

usage() {
  sed -n '4,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local sub="${1:-}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    exec) cmd_exec "$@" ;;
    with-file) cmd_with_file "$@" ;;
    get) cmd_get "$@" ;;
    init) cmd_init "$@" ;;
    set) cmd_set "$@" ;;
    unset) cmd_unset "$@" ;;
    import) cmd_import "$@" ;;
    edit) cmd_edit "$@" ;;
    list) cmd_list "$@" ;;
    check) cmd_check "$@" ;;
    keygen) cmd_keygen "$@" ;;
    rotate) cmd_rotate "$@" ;;
    ci) cmd_ci "$@" ;;
    enroll) cmd_enroll "$@" ;;
    add-machine) cmd_add_machine "$@" ;;
    recovery) cmd_recovery "$@" ;;
    remove-machine) cmd_remove_machine "$@" ;;
    sync) cmd_sync "$@" ;;
    doctor) cmd_doctor "$@" ;;
    help | -h | --help | '') usage ;;
    *) die "unknown subcommand: $sub (try: secrets.sh help)" ;;
  esac
}

main "$@"
