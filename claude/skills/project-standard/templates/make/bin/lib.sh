#!/usr/bin/env bash
# project-standard v1.8 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Shared shell helpers for secrets.sh, cf.sh and the recipes in common.mk.
# Source it:   . "$STD_BIN/lib.sh"
# Or run it:   lib.sh install-hook      (installs the pre-commit hook, used by `make hooks`)
# Bash 3.2 compatible. Nothing in here touches secrets.

export STD_VERSION=7

# --- colour (Tokyo Night truecolour; only on a TTY and when NO_COLOR is unset) ---

std_tty() { [ -z "${NO_COLOR:-}" ] && [ -t "$1" ]; }

std_rgb() {
  case "$1" in
    blue) printf '122;162;247' ;;
    green) printf '158;206;106' ;;
    red) printf '247;118;142' ;;
    yellow) printf '224;175;104' ;;
    cyan) printf '125;207;255' ;;
    magenta) printf '187;154;247' ;;
    dim) printf '86;95;139' ;;
    *) printf '169;177;214' ;;
  esac
}

# paint FD COLOUR TEXT...   print TEXT (no newline), coloured when FD is a TTY.
paint() {
  local fd="$1" name="$2"
  shift 2
  if std_tty "$fd"; then
    printf '\033[38;2;%sm%s\033[0m' "$(std_rgb "$name")" "$*"
  else
    printf '%s' "$*"
  fi
}

# --- logging (to stderr) ---

log_info() { printf '%s %s\n' "$(paint 2 blue '>')" "$*" >&2; }
log_ok() { printf '%s %s\n' "$(paint 2 green 'ok')" "$*" >&2; }
log_warn() { printf '%s %s\n' "$(paint 2 yellow 'warn')" "$*" >&2; }

# github_repo_slug URL   owner/name of a GitHub repository written as https://github.com/<o>/<n>[.git],
# git@github.com:<o>/<n>[.git], ssh://git@github.com/<o>/<n>, github.com/<o>/<n> or <o>/<n>; prints nothing for
# anything else (a local path, another host). The secrets repo's SECRETS_REMOTE becomes the CI variable SECRETS_REPO.
github_repo_slug() {
  local u="${1:-}" s
  case "$u" in
    https://github.com/* | http://github.com/*) s="${u#*://github.com/}" ;;
    https://*@github.com/*) s="${u#*@github.com/}" ;;
    ssh://git@github.com/*) s="${u#ssh://git@github.com/}" ;;
    git@github.com:*) s="${u#git@github.com:}" ;;
    github.com/*) s="${u#github.com/}" ;;
    *://* | *@*:* | /* | .* | '~'*) return 0 ;;
    *) s="$u" ;;
  esac
  s="${s%/}"
  s="${s%.git}"
  if [[ $s =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]]; then printf '%s\n' "$s"; fi
  return 0
}

# public_dns_a HOST   the first IPv4 address of HOST in public DNS, asked over DNS-over-HTTPS (Cloudflare 1.1.1.1, then
# Google 8.8.8.8), so this machine's own resolver and its cache play no part; empty when neither answers.
public_dns_a() {
  local url ip
  for url in "https://1.1.1.1/dns-query?name=$1&type=A" "https://8.8.8.8/resolve?name=$1&type=A"; do
    ip="$(curl -fsS --max-time 10 -H 'accept: application/dns-json' "$url" 2>/dev/null \
      | jq -r '[.Answer[]? | select(.type == 1) | .data][0] // empty' 2>/dev/null)" || ip=""
    if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
  done
  return 0
}

# smoke_get URL   GET URL for a smoke check (curl -fsS, retried). When this machine cannot resolve the host (curl exit
# 6), as right after a first deploy attaches a custom domain while the local DNS cache still holds the miss from
# before, the host is looked up in public DNS and the check repeated pinned to that address (v40). Any other failure,
# an HTTP error included, fails as before.
smoke_get() {
  local url="$1" rc=0 rest host port ip
  curl -fsS --retry 3 --retry-delay 5 --max-time 20 "$url" >/dev/null || rc=$?
  [ "$rc" = 6 ] || return "$rc"
  rest="${url#*://}"
  rest="${rest%%/*}"
  host="${rest%%:*}"
  case "$rest" in
    *:*) port="${rest##*:}" ;;
    *) case "$url" in http://*) port=80 ;; *) port=443 ;; esac ;;
  esac
  ip="$(public_dns_a "$host")"
  if [ -z "$ip" ]; then
    log_err "$host does not resolve, here or in public DNS: is its custom domain attached?"
    return 6
  fi
  log_warn "this machine cannot resolve $host yet (its DNS cache still holds the miss from before the domain existed); checking it at $ip from public DNS"
  log_warn "the cache clears by itself; on a Mac at once with: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
  curl -fsS --retry 3 --retry-delay 5 --max-time 20 --resolve "$host:$port:$ip" "$url" >/dev/null
}
log_err() { printf '%s %s\n' "$(paint 2 red 'error')" "$*" >&2; }

# die MESSAGE...   print an error and exit 1.
die() {
  log_err "$*"
  exit 1
}

# die_code CODE MESSAGE...
die_code() {
  local code="$1"
  shift
  log_err "$*"
  exit "$code"
}

# --- checks ---

# need_cmd CMD [HINT]   die unless CMD is on PATH.
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found${2:+ ($2)}"
}

# valid_name NAME   letters, digits, dot, dash, underscore; no leading dash or dot.
valid_name() {
  case "$1" in
    '' | -* | .*) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# valid_env_name NAME   a shell/dotenv variable name a user secret may have. Names starting with sops_
# (any case) are refused: sops keeps its own metadata under sops_* keys in a dotenv file.
valid_env_name() {
  case "$1" in
    '' | [0-9]* | *[!A-Za-z0-9_]*) return 1 ;;
    [sS][oO][pP][sS]_*) return 1 ;;
  esac
  return 0
}

# require_confirm ENV   die unless CONFIRM equals ENV (make already checked it came from the command line).
require_confirm() {
  [ "${CONFIRM:-}" = "$1" ] || die "refused: CONFIRM=$1 is required"
}

# confirm_typed EXPECTED PROMPT   the user must type EXPECTED on the controlling terminal. It reads /dev/tty
# only: no environment variable can point it somewhere else (tests drive it through a pty with `script`).
confirm_typed() {
  local expected="$1" prompt="$2" answer=""
  { : </dev/tty; } 2>/dev/null || die "refused: this needs a terminal to type '$expected' on"
  printf '%s ' "$prompt" >&2
  IFS= read -r answer </dev/tty || true
  [ "$answer" = "$expected" ] || die "refused: you typed '$answer', expected '$expected'"
}

# hdr TEXT   a dim section line on stdout (used between parts of a fan-out).
hdr() { printf '%s\n' "$(paint 1 dim "== $*")"; }

# --- help (make help) ---

STD_HELP_ORDER="setup dev test cloudflare secrets deploy ci firmware hardware app release project"

# std_local_help FILE   print `project|target|description` for the `## ` comments in make/local.mk:
#   ## description          on the line above a target, or
#   target: deps  ## description
std_local_help() {
  [ -f "$1" ] || return 0
  awk '
    /^##[ \t]/ { pend = substr($0, 4); next }
    /^[A-Za-z0-9_.-]+:/ && $0 !~ /^[^:]*:=/ && $0 !~ /^\./ {
      name = $0; sub(/:.*/, "", name)
      if (match($0, /##[ \t]+.*$/)) {
        d = substr($0, RSTART); sub(/^##[ \t]+/, "", d); gsub(/\|/, "/", d)
        print "project|" name "|" d; pend = ""; next
      }
      if (pend != "") { gsub(/\|/, "/", pend); print "project|" name "|" pend }
      pend = ""; next
    }
    /^[ \t]*$/ { next }
    { pend = "" }
  ' "$1"
}

# std_help_render PROJECT ENV PARTS   read `group|target|description` lines on stdin, print the grouped help.
std_help_render() {
  local color=0
  if std_tty 1; then color=1; fi
  awk -F'|' -v color="$color" -v order="$STD_HELP_ORDER" -v project="$1" -v env="$2" -v parts="$3" '
    function pad(s, n) { while (length(s) < n) s = s " "; return s }
    function paint(c, s) { return color ? sprintf("\033[38;2;%sm%s\033[0m", c, s) : s }
    BEGIN { no = split(order, ord, " "); for (i = 1; i <= no; i++) known[ord[i]] = 1 }
    {
      sub(/^[ \t]+/, "")
      if ($0 == "" || NF < 3) next
      g = $1
      if (!(g in cnt)) { cnt[g] = 0; if (!(g in known)) { extra[++ne] = g } }
      cnt[g]++; tg[g, cnt[g]] = $2; ds[g, cnt[g]] = $3
      if (length($2) > w) w = length($2)
    }
    END {
      printf "%s\n", paint("122;162;247", "make " project)
      printf "%s\n\n", paint("86;95;139", "usage: make <command> [ENV=local|staging|production] [PART=<part>] [CONFIRM=<env>]")
      for (i = 1; i <= no + ne; i++) {
        g = (i <= no) ? ord[i] : extra[i - no]
        if (!(g in cnt) || cnt[g] == 0) continue
        printf "%s\n", paint("187;154;247", g)
        for (j = 1; j <= cnt[g]; j++)
          printf "  %s  %s\n", paint("158;206;106", pad(tg[g, j], w)), paint("169;177;214", ds[g, j])
        printf "\n"
      }
      printf "%s\n", paint("86;95;139", "environment: ENV=" env "    parts: " parts)
      printf "%s\n", paint("86;95;139", "destroy, reset and anything on production need CONFIRM=<env> on the command line")
      printf "%s\n", paint("86;95;139", "only the commands the parts of this project use are listed: make help ALL=1 lists every one")
    }
  '
}

# doctor_project   read-only checks for the project itself; returns 1 when something is wrong.
doctor_project() {
  local bad=0 t
  for t in git make bash; do
    if command -v "$t" >/dev/null 2>&1; then log_ok "$t"; else log_err "$t not found"; bad=1; fi
  done
  for t in brew mise gitleaks sops age jq; do
    if command -v "$t" >/dev/null 2>&1; then log_ok "$t"; else log_warn "$t not found (brew install $t)"; fi
  done
  if command -v act >/dev/null 2>&1; then
    log_ok "act"
  else
    log_warn "act not found, make ci-local needs it (brew install act)"
  fi
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    log_ok "gh (signed in)"
  else
    log_warn "gh missing or not signed in, the release and the ci targets need it (brew install gh; gh auth login)"
  fi
  if [ -f make/VERSION ]; then log_ok "standard v$(cat make/VERSION)"; else log_warn "make/VERSION missing"; fi
  [ -f Brewfile ] || log_warn "no Brewfile"
  [ -f mise.toml ] || log_warn "no mise.toml"
  [ -f secrets.schema ] || log_warn "no secrets.schema"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    if [ -x "$(git rev-parse --git-path hooks)/pre-commit" ]; then log_ok "pre-commit hook"; else log_warn "pre-commit hook missing: make hooks"; fi
  else
    log_warn "not a git repository"
  fi
  return "$bad"
}

# --- pre-commit hook for the project repo (make hooks) ---

STD_HOOK_MARK='# project-standard v[0-9][0-9.]* pre-commit hook'

install_hook_body() {
  cat <<'HOOK'
#!/usr/bin/env bash
# project-standard v1.8 pre-commit hook (installed by `make hooks`; fast checks only)
set -euo pipefail
max_mb="${STD_MAX_FILE_MB:-5}"
limit=$((max_mb * 1024 * 1024))
fail=0

if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks git --help >/dev/null 2>&1; then
    gitleaks git --pre-commit --staged --redact --no-banner || fail=1
  else
    gitleaks protect --staged --redact --no-banner || fail=1
  fi
fi

if [ -f .gitattributes ] && grep -q 'filter=lfs' .gitattributes && ! command -v git-lfs >/dev/null 2>&1; then
  echo "pre-commit: .gitattributes uses git-lfs but git-lfs is not installed (brew install git-lfs; git lfs install)" >&2
  fail=1
fi

while IFS= read -r -d '' f; do
  size="$(git cat-file -s ":$f" 2>/dev/null || echo 0)"
  # KiCad design files are text: git stores them as deltas and diffs them, so a large board stays in plain git
  case "$f" in *.kicad_pcb | *.kicad_sch | *.kicad_pro) size=0 ;; esac
  if [ "$size" -gt "$limit" ]; then
    echo "pre-commit: $f is $((size / 1024 / 1024)) MB (limit ${max_mb} MB) and not in LFS: git lfs track '$f'" >&2
    fail=1
  fi
  attr="$(git check-attr filter -- "$f" | sed 's/.*: //')"
  if [ "$attr" = "lfs" ] && ! git cat-file -p ":$f" 2>/dev/null | head -c 64 | grep -q 'git-lfs'; then
    echo "pre-commit: $f should be an LFS pointer; run: git lfs install && git add --renormalize '$f'" >&2
    fail=1
  fi
done < <(git diff --cached --name-only --diff-filter=ACM -z)

exit "$fail"
HOOK
}

# install_hook   write .git/hooks/pre-commit (never overwrites a hook this standard did not write).
install_hook() {
  local hooks_dir hook
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository (run git init -b main first)"
  hooks_dir="$(git rev-parse --git-path hooks)"
  mkdir -p "$hooks_dir"
  hook="$hooks_dir/pre-commit"
  if [ -e "$hook" ] && ! grep -q "$STD_HOOK_MARK" "$hook"; then
    die "$hook exists and was not installed by project-standard; move it away first"
  fi
  install_hook_body >"$hook.tmp.$$"
  chmod 755 "$hook.tmp.$$"
  mv "$hook.tmp.$$" "$hook"
  log_ok "pre-commit hook installed ($hook)"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  case "${1:-}" in
    install-hook) install_hook ;;
    *) die "usage: lib.sh install-hook" ;;
  esac
fi
