#!/usr/bin/env bash
# project-standard v1.13 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# cf.sh: the Cloudflare engine. Everything that talks to Cloudflare runs under
# `secrets.sh exec --env E`, so wrangler sees CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID from
# the environment and nothing else. wrangler runs from the part's dir through its package manager:
# `pnpm exec wrangler` when the part has pnpm-lock.yaml, else `npx --no-install wrangler`.
#
# Usage: cf.sh SUBCOMMAND [--project P] [--env E] [--dir D] [options]
#   login | logout | whoami | token-check | token-url | provision | status | migrate [--list]
#   provision-ota | status-ota   the OTA bucket(s) of make/project.mk (OTA_PUBLIC := r2dev turns the r2.dev URL on)
#   seed | secrets [--rotate NAME] | backup | wipe [--r2-unbacked] | destroy [--r2-unbacked] | envs
#   access --part P [--host H] [--path X] [--email-domains "a b"] [--emails "a b"] [--session 24h] [--dry] [--rotate-token]
#   access-check --part P [--host H] [--url-base U] [--health /x] | access-doctor --part P [settings]   (1.7)
# One API token per project: login opens the dashboard's token form pre-filled with the permissions the project's
# wrangler files and its OTA bucket need (token-url prints that URL only), stores the token for staging and production,
# logout removes both.
# The bindings under env.E in D/wrangler.jsonc are the single source of truth.
# wipe and destroy back up first and refuse when the backup cannot hold a declared resource (R2 objects), and
# when a resource name does not start with PROJECT-ENV (so a wrong ENV or a copied config cannot hit another env).
# Only D1, KV, R2 and Queues (dead-letter queues included) are provisioned, checked and backed up; a backup holds D1
# and KV data (R2: bucket info only). Durable Object storage and every other binding go to wrangler on deploy only.
# Environment: PROJECT, SECRETS_DIR, STD_CONFIG, CF_API_BASE, STD_BACKUP_DIR, CONFIRM, STD_TTY (login prompts only),
# CLOUDFLARE_API_TOKEN (login takes it instead of prompting), CF_NO_BROWSER=1 (login prints the URL, opens nothing).
# Needs bash 3.2+, jq, curl, awk; pnpm or npx with wrangler pinned in the part's package.json; age for backups.

set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

SECRETS_SH="$SELF_DIR/secrets.sh"
SECRETS_DIR="${SECRETS_DIR:-$HOME/.secrets}"
STD_CONFIG="${STD_CONFIG:-$HOME/.config/project-standard}"
PROJECT="${PROJECT:-}"
SCHEMA="${SECRETS_SCHEMA:-secrets.schema}"
CF_API="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"
BACKUP_ROOT="${STD_BACKUP_DIR:-$HOME/Backups}"
DASHBOARD_TOKENS_URL="https://dash.cloudflare.com/profile/api-tokens"

OPT_ENV="local"
OPT_DIR="."
OPT_ROTATE=""
OPT_LIST=0
OPT_R2_UNBACKED=0
OPT_PART=""
OPT_HOST=""
OPT_PATH=""
OPT_EMAIL_DOMAINS=""
OPT_EMAILS=""
OPT_SESSION=""
OPT_URL_BASE=""
OPT_HEALTH=""
OPT_DRY=0
OPT_ROTATE_TOKEN=0
POS=()
CUR_SUB=""
ORIG_ARGS=()

parse_args() {
  POS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT="$2"; shift 2 ;;
      --env) [ $# -ge 2 ] || die "--env needs a value"; OPT_ENV="$2"; shift 2 ;;
      --dir) [ $# -ge 2 ] || die "--dir needs a value"; OPT_DIR="$2"; shift 2 ;;
      --rotate) [ $# -ge 2 ] || die "--rotate needs a value"; OPT_ROTATE="$2"; shift 2 ;;
      --list) OPT_LIST=1; shift ;;
      --r2-unbacked) OPT_R2_UNBACKED=1; shift ;;
      --part) [ $# -ge 2 ] || die "--part needs a value"; OPT_PART="$2"; shift 2 ;;
      --host) [ $# -ge 2 ] || die "--host needs a value"; OPT_HOST="$2"; shift 2 ;;
      --path) [ $# -ge 2 ] || die "--path needs a value"; OPT_PATH="$2"; shift 2 ;;
      --email-domains) [ $# -ge 2 ] || die "--email-domains needs a value"; OPT_EMAIL_DOMAINS="$2"; shift 2 ;;
      --emails) [ $# -ge 2 ] || die "--emails needs a value"; OPT_EMAILS="$2"; shift 2 ;;
      --session) [ $# -ge 2 ] || die "--session needs a value"; OPT_SESSION="$2"; shift 2 ;;
      --url-base) [ $# -ge 2 ] || die "--url-base needs a value"; OPT_URL_BASE="$2"; shift 2 ;;
      --health) [ $# -ge 2 ] || die "--health needs a value"; OPT_HEALTH="$2"; shift 2 ;;
      --dry) OPT_DRY=1; shift ;;
      --rotate-token) OPT_ROTATE_TOKEN=1; shift ;;
      --) shift; POS+=("$@"); return 0 ;;
      -*) die "unknown option: $1" ;;
      *) POS+=("$1"); shift ;;
    esac
  done
  if [ -d "$OPT_DIR" ]; then OPT_DIR="$(cd "$OPT_DIR" && pwd -P)"; fi
}

need_env() {
  case "$OPT_ENV" in
    local | staging | production) ;;
    *) die "invalid environment: $OPT_ENV (local, staging or production)" ;;
  esac
}

need_remote_env() {
  need_env
  [ "$OPT_ENV" != local ] || die "this command needs --env staging or production (local has nothing on Cloudflare)"
}

need_project() {
  [ -n "$PROJECT" ] || die "no project: pass --project P or set PROJECT"
  valid_name "$PROJECT" || die "invalid project name: $PROJECT"
}

# --- running commands with Cloudflare credentials ---

# ensure_creds   for staging/production, re-run this same command once under `secrets.sh exec`, so the
# token is in the environment and there is a single unlock (one Touch ID) per cf.sh command.
ensure_creds() {
  if [ "$OPT_ENV" = local ] || [ -n "${CF_SH_INNER:-}" ]; then
    return 0
  fi
  exec "$SECRETS_SH" exec --project "$PROJECT" --env "$OPT_ENV" -- env CF_SH_INNER=1 "$0" "$CUR_SUB" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
}

# run_cf CMD...   run in the part dir (the credentials are already in the environment).
run_cf() {
  (cd "$OPT_DIR" && "$@")
}

# pm_wrangler ARGS...   the part's pinned wrangler through its package manager, in the current dir (the part dir):
# pnpm exec when the part has pnpm-lock.yaml (npx would warn about pnpm-only .npmrc keys), else npx --no-install.
pm_wrangler() {
  if [ -f pnpm-lock.yaml ]; then
    pnpm exec wrangler "$@"
  else
    npx --no-install wrangler "$@"
  fi
}

# wr ARGS...   wrangler with the right --env.
wr() {
  if [ "$OPT_ENV" = local ]; then
    run_cf pm_wrangler "$@"
  else
    run_cf pm_wrangler "$@" --env "$OPT_ENV"
  fi
}

# wr_global ARGS...   wrangler commands that take no --env (list, create, kv, r2, queues).
wr_global() { run_cf pm_wrangler "$@"; }

# cfg_safe VALUE...   a value that goes into a curl config file must not hold a quote, a backslash or a line break
# (it would end the string and let the rest be read as more config lines: another url, another header).
cfg_safe() {
  local v
  for v in "$@"; do
    case "$v" in
      *'"'* | *\\* | *$'\n'* | *$'\r'*) return 1 ;;
    esac
  done
  return 0
}

# need_account_id VALUE   a Cloudflare account id is 32 hex characters; anything else is refused.
need_account_id() {
  is_hex32 "${1:-}" || die "invalid Cloudflare account id (32 hex characters expected)"
}

# api_get URL TOKEN   GET with the token passed on stdin (curl -K -), never in argv.
api_get() {
  cfg_safe "$1" "$2" || die "refused: the URL or token holds a quote, backslash or line break"
  printf 'header = "Authorization: Bearer %s"\nurl = "%s"\n' "$2" "$1" | curl -sS --max-time 20 -K -
}

# api_delete URL TOKEN
api_delete() {
  cfg_safe "$1" "$2" || die "refused: the URL or token holds a quote, backslash or line break"
  printf 'header = "Authorization: Bearer %s"\nurl = "%s"\nrequest = "DELETE"\n' "$2" "$1" | curl -sS --max-time 20 -K - >/dev/null
}

# --- wrangler.jsonc ---

config_file() {
  local f
  for f in wrangler.jsonc wrangler.json; do
    if [ -f "$OPT_DIR/$f" ]; then printf '%s/%s' "$OPT_DIR" "$f"; return 0; fi
  done
  die "no wrangler.jsonc in $OPT_DIR"
}

# strip_jsonc FILE   remove comments and trailing commas, on stdout (for reading only, never for writing back).
strip_jsonc() {
  awk '
    BEGIN { blk = 0; pend = 0; ws = ""; all = "" }
    function emit(x) {
      if (pend) { if (x != "}" && x != "]") all = all ","; pend = 0 }
      all = all ws x; ws = ""
    }
    {
      line = $0; n = length(line); instr = 0
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (blk) { if (c == "*" && substr(line, i + 1, 1) == "/") { blk = 0; i++ } continue }
        if (instr) {
          buf = buf c
          if (c == "\\") { i++; buf = buf substr(line, i, 1) }
          else if (c == "\"") { instr = 0; emit(buf); buf = "" }
          continue
        }
        if (c == "\"") { instr = 1; buf = c; continue }
        if (c == "/" && substr(line, i + 1, 1) == "/") break
        if (c == "/" && substr(line, i + 1, 1) == "*") { blk = 1; i++; continue }
        if (c == " " || c == "\t") { ws = ws c; continue }
        if (c == ",") { if (pend) emit(","); pend = 1; continue }
        emit(c)
      }
      ws = ws "\n"
    }
    END { printf "%s", all }
  ' "$1"
}

has_env_block() { # FILE ENV
  [ "$2" = local ] && return 0
  strip_jsonc "$1" | jq -e --arg e "$2" '.env[$e] != null' >/dev/null 2>&1
}

# need_env_block FILE   refuse a remote ENV that wrangler.jsonc does not declare. Without the block wrangler would use
# the top-level (local) config under the name <name>-<env>: a new Worker with the local bindings. A part without
# env.staging is production-only: it deploys with ENV=production CONFIRM=production.
need_env_block() {
  has_env_block "$1" "$OPT_ENV" && return 0
  if [ "$OPT_ENV" = staging ]; then
    die "no \"staging\" block under env in $1: this part is production-only (deploy it with make <part>-deploy ENV=production CONFIRM=production, or add env.staging)"
  fi
  die "no \"$OPT_ENV\" block under env in $1"
}

# declared FILE ENV   one resource per line: kind|binding|name|id
# Queues: every producer, then the queues consumers read that no producer declares (binding "(consumer)"), then
# the dead-letter queues of the consumers that are not declared already (binding "(dead-letter)"). Each name once.
declared() {
  strip_jsonc "$1" | jq -r --arg e "$2" '
    def once: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
    def without($a): map(select(. as $q | $a | any(.[]; . == $q) | not));
    (if $e == "local" then . else .env[$e] end) as $c
    | ($c.queues.producers // []) as $prod
    | ($c.queues.consumers // []) as $cons
    | ([$prod[].queue] | once) as $pn
    | ([$cons[].queue | select(type == "string" and . != "")] | once | without($pn)) as $cn
    | ([$cons[].dead_letter_queue | select(type == "string" and . != "")] | once | without($pn + $cn)) as $dn
    | ( ($c.d1_databases // [])[] | ["d1", .binding, .database_name, (.database_id // "")] ),
      ( ($c.kv_namespaces // [])[] | ["kv", .binding, "", (.id // "")] ),
      ( ($c.r2_buckets // [])[] | ["r2", .binding, .bucket_name, ""] ),
      ( $prod[] | ["queue", .binding, .queue, ""] ),
      ( $cn[] | ["queue", "(consumer)", ., ""] ),
      ( $dn[] | ["queue", "(dead-letter)", ., ""] )
    | join("|")'
}

is_uuid() { printf '%s' "$1" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }
is_hex32() { printf '%s' "$1" | grep -q -E '^[0-9a-f]{32}$'; }

# set_id FILE ENV MARKKEY MARKVAL IDKEY NEWID
# Targeted textual replace: inside the "ENV" block, find the line with "MARKKEY": "MARKVAL" and change the
# nearest "IDKEY": "..." within 8 lines. Comments and layout stay as they are.
set_id() {
  local file="$1" env="$2" mk="$3" mv="$4" ik="$5" nid="$6" tmp
  tmp="$file.tmp.$$"
  awk -v env="$env" -v mk="$mk" -v mv="$mv" -v ik="$ik" -v nid="$nid" '
    function depthdelta(s,   t, o, c) {
      t = s
      gsub(/"([^"\\]|\\.)*"/, "", t); sub(/\/\/.*$/, "", t)
      o = gsub(/\{/, "", t); c = gsub(/\}/, "", t)
      return o - c
    }
    { L[NR] = $0 }
    END {
      s = 1; e = NR
      if (env != "local") {
        s = 0; d = 0
        for (i = 1; i <= NR; i++) {
          if (!s && L[i] ~ "^[ \t]*\"" env "\"[ \t]*:[ \t]*\\{") { s = i; d = 0 }
          if (s) { d += depthdelta(L[i]); if (i >= s && d <= 0) { e = i; break } }
        }
        if (!s) exit 3
      }
      m = 0
      for (i = s; i <= e; i++) if (index(L[i], "\"" mk "\"") && index(L[i], "\"" mv "\"")) { m = i; break }
      if (!m) exit 4
      best = 0
      for (k = 0; k <= 8; k++) {
        for (sg = -1; sg <= 1; sg += 2) {
          j = m + sg * k
          if (j >= s && j <= e && L[j] ~ "\"" ik "\"[ \t]*:") { best = j; break }
        }
        if (best) break
      }
      if (!best) exit 5
      line = L[best]
      if (match(line, "\"" ik "\"[ \t]*:[ \t]*\"[^\"]*\"")) {
        seg = substr(line, RSTART, RLENGTH)
        p = index(seg, ":")
        pre = substr(seg, 1, p)
        rest = substr(seg, p + 1); sub(/^[ \t]*/, "", rest)
        lead = substr(seg, p + 1, length(seg) - p - length(rest))
        L[best] = substr(line, 1, RSTART - 1) pre lead "\"" nid "\"" substr(line, RSTART + RLENGTH)
      } else exit 6
      for (i = 1; i <= NR; i++) print L[i]
    }
  ' "$file" >"$tmp" || {
    local rc=$?
    rm -f "$tmp"
    case "$rc" in
      3) die "no \"$env\" block in $file" ;;
      4) die "could not find $mk \"$mv\" in the $env block of $file" ;;
      *) die "could not update \"$ik\" for $mv in $file (give the binding an empty \"$ik\": \"\" first)" ;;
    esac
  }
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod "$(stat -f '%Lp' "$file" 2>/dev/null || echo 644)" "$tmp"
  mv "$tmp" "$file"
}

# --- subcommands: auth ---

store_secret() { # NAME ENV VALUE
  printf '%s' "$3" | "$SECRETS_SH" set "$1" --project "$PROJECT" --env "$2"
}

# verify_token TOKEN [ACCOUNT_ID]   prints "status|expires_on". User tokens verify under /user/tokens/verify;
# account-owned tokens (cfat_...) only under /accounts/ID/tokens/verify, which is tried when the first says invalid.
verify_token() {
  local resp status expires=""
  resp="$(api_get "$CF_API/user/tokens/verify" "$1" 2>/dev/null || true)"
  status="$(printf '%s' "$resp" | jq -r '.result.status // empty' 2>/dev/null || true)"
  if [ "$status" != active ] && [ -n "${2:-}" ]; then
    resp="$(api_get "$CF_API/accounts/$2/tokens/verify" "$1" 2>/dev/null || true)"
    status="$(printf '%s' "$resp" | jq -r '.result.status // empty' 2>/dev/null || true)"
  fi
  expires="$(printf '%s' "$resp" | jq -r '.result.expires_on // empty' 2>/dev/null || true)"
  printf '%s|%s' "${status:-invalid}" "${expires:-never}"
}

# token_account TOKEN   the id of the account an account-owned token belongs to, or nothing: for a token
# /user/tokens/verify refuses and no account id given, it lists the accounts the token sees (GET /accounts) and
# prints the first one under which /accounts/ID/tokens/verify says active.
token_account() {
  local id resp
  resp="$(api_get "$CF_API/accounts" "$1" 2>/dev/null || true)"
  for id in $(printf '%s' "$resp" | jq -r '.result[]?.id // empty' 2>/dev/null || true); do
    is_hex32 "$id" || continue
    case "$(verify_token "$1" "$id")" in
      active\|*) printf '%s' "$id"; return 0 ;;
    esac
  done
  return 0
}

stored_account_id() {
  "$SECRETS_SH" get CLOUDFLARE_ACCOUNT_ID --project "$PROJECT" --env common 2>/dev/null || true
}

# One API token per project, for every environment: cf-login stores the same token in the staging and the
# production file (never common: the developer keys open common), so `secrets.sh exec --env E` hands it to wrangler
# for either environment. Cloudflare permissions cannot be narrowed to resources by name, so a token per environment
# never kept staging away from production resources; one token with the project's permissions is just as narrow.
TOKEN_ENVS="staging production"

# token_copy ENV   the stored token of ENV, or nothing (not stored, or this identity cannot open the file).
token_copy() {
  "$SECRETS_SH" get CLOUDFLARE_API_TOKEN --project "$PROJECT" --env "$1" 2>/dev/null || true
}

# --- cf-login: the token template ---
#
# cf-login opens the dashboard's "create account API token" form already filled in with the token name (the project)
# and the permissions the project's wrangler files need. Cloudflare's account-owned token template URLs:
#   https://developers.cloudflare.com/fundamentals/api/how-to/account-owned-token-template/   (read 2026-11-12)
#   https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=<URL-encoded JSON array>&name=<name>
# Each entry is {"key": KEY, "type": "read"|"edit"}. Account token URLs take a short key or a permission group ID. The
# IDs are published only by the List permission groups API, which needs a token with API Tokens Read (the token being
# created), and no doc lists them, so this uses the short keys the doc's table lists. A key the dashboard cannot
# resolve still opens the form, with a notice naming it. Account token URLs take no zone: the zone permissions'
# resources are chosen in the form, so the zones are printed. Workers Tail is not asked for: wrangler tail works with
# Workers Scripts: Edit on an account token (checked 2026-11-12).
CF_TEMPLATE_BASE="https://dash.cloudflare.com/?to=/:account/api-tokens"

# perm_info ID   "key|type|dashboard name|scope" for one permission.
perm_info() {
  case "$1" in
    account) printf 'account_settings|read|Account Settings: Read|account' ;;
    workers) printf 'workers_scripts|edit|Workers Scripts: Edit|account' ;;
    d1) printf 'd1|edit|D1: Edit|account' ;;
    kv) printf 'workers_kv_storage|edit|Workers KV Storage: Edit|account' ;;
    r2) printf 'workers_r2|edit|Workers R2 Storage: Edit|account' ;;
    queue) printf 'queues|edit|Queues: Edit|account' ;;
    pages) printf 'page|edit|Cloudflare Pages: Edit|account' ;;
    routes) printf 'workers_routes|edit|Workers Routes: Edit|zone' ;;
    dns) printf 'dns|edit|DNS: Edit|zone' ;;
    # no short key the token form accepts (and its group id needs API Tokens Read): cf-login names it to add by hand
    realtime) printf '|edit|Cloudflare Realtime: Edit (add it by hand: the form cannot preset it)|account' ;;
    # the project's own Access application (paths, policies), one token instead of a second (v36)
    access) printf '|edit|Access: Apps and Policies: Edit (add it by hand: the form cannot preset it)|account' ;;
    # with access (v37): the service token a project's machines use to pass its Access application
    access_tokens) printf '|edit|Access: Service Tokens: Edit (add it by hand: the form cannot preset it)|account' ;;
    # with access (v38): the Zero Trust organization, read for its team domain (the Access certs URL)
    access_org) printf '|read|Access: Organizations, Identity Providers, and Groups: Read (add it by hand: the form cannot preset it)|account' ;;
  esac
}

perm_field() { perm_info "$1" | cut -d'|' -f"$2"; } # ID FIELD (1 key, 2 type, 3 name, 4 scope)

# project_setting NAME   the value of NAME := ... in make/project.mk (one line, comments dropped), empty when unset.
project_setting() {
  local f="${STD_PROJECT_MK:-make/project.mk}"
  [ -f "$f" ] || return 0
  awk -v n="$1" '$1 == n && $2 ~ /^(:|::|\?)?=$/ { $1 = ""; $2 = ""; sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }' "$f"
}

# project_cloud_parts   "kind|dir" for every cloud-worker and web-pages part in PARTS of make/project.mk (make runs
# cf.sh at the project root). PARTS entries are name:kind[:dir], dir defaulting to name.
project_cloud_parts() {
  local f="${STD_PROJECT_MK:-make/project.mk}" p name kind dir rest
  if [ ! -f "$f" ]; then
    # no project file (a part run on its own): the --dir given is the one Worker
    [ -z "${OPT_DIR:-}" ] || printf 'cloud-worker|%s\n' "$OPT_DIR"
    return 0
  fi
  awk '
    /^[ \t]*PARTS[ \t]*(:|::|\?|\+)?=/ { on = 1; sub(/^[^=]*=/, "") }
    on { line = $0; cont = sub(/\\[ \t]*$/, "", line); sub(/#.*/, "", line); print line; if (!cont) on = 0 }
  ' "$f" | tr -s '[:blank:]' '\n' | while IFS= read -r p; do
    [ -n "$p" ] || continue
    name="${p%%:*}"
    rest="${p#*:}"
    kind="${rest%%:*}"
    dir="$name"
    [ "$rest" = "$kind" ] || dir="${rest#*:}"
    case "$kind" in cloud-worker | web-pages) printf '%s|%s\n' "$kind" "$dir" ;; esac
  done
}

# project_ota_bucket   true when make/project.mk sets OTA_BUCKET or a <part>_OTA_BUCKET: the firmware and app OTA uploads
# put objects in that R2 bucket with the project token (wrangler r2 object put), so the token needs R2 even when the
# project has no cloud-worker or web-pages part.
project_ota_bucket() {
  local f="${STD_PROJECT_MK:-make/project.mk}"
  [ -f "$f" ] || return 1
  grep -Eq '^[[:space:]]*([A-Za-z0-9_-]+_)?OTA_BUCKET[[:space:]]*(:|::|\?)?=[[:space:]]*[^[:space:]#]' "$f"
}

# project_uses_cf   true when the project needs the Cloudflare token: a cloud-worker or web-pages part, or an OTA bucket.
project_uses_cf() {
  [ -n "$(project_cloud_parts)" ] || project_ota_bucket
}

# token_needs   what the project's one token must reach, one item per line: "perm ID" (perm_info ids, fixed order),
# "zone Z" and "host H" for routes and custom domains, "file F" for each wrangler file read. The top level (local)
# and every env block count, since one token serves every environment. A route's zone is its zone_name, else the
# last two labels of its hostname.
token_needs() {
  local kind dir f n needs="" parts
  parts="$(project_cloud_parts)"
  while IFS='|' read -r kind dir; do
    [ -n "$kind" ] || continue
    # a web-pages part with its own wrangler file is a static-assets Worker (its routes count below), not a Pages project
    # (a wrangler file with pages_build_output_dir is a Pages config: the jq below adds pages for it)
    if [ "$kind" = web-pages ] && [ ! -f "$dir/wrangler.jsonc" ] && [ ! -f "$dir/wrangler.json" ]; then needs="$needs pages"; fi
    for f in "$dir/wrangler.jsonc" "$dir/wrangler.json"; do
      [ -f "$f" ] || continue
      printf 'file %s\n' "$f"
      n="$(strip_jsonc "$f" | jq -r '
        [ ([.] + [(.env // {})[]])[] |
          (if ((.d1_databases // []) | length) > 0 then "need d1" else empty end),
          (if ((.kv_namespaces // []) | length) > 0 then "need kv" else empty end),
          (if ((.r2_buckets // []) | length) > 0 then "need r2" else empty end),
          (if (((.queues.producers // []) + (.queues.consumers // [])) | length) > 0 then "need queue" else empty end),
          (if has("pages_build_output_dir") then "need pages" else empty end),
          ( ([.route] + (.routes // [])) | map(select(. != null))[]
            | (if type == "string" then {pattern: .} else . end) as $r
            | ($r.pattern // "" | sub("^[a-z]+://"; "") | sub("/.*$"; "") | sub(":[0-9]+$"; "") | sub("^\\*\\.?"; "")) as $h
            | "need routes", "host \($h)",
              "zone \($r.zone_name // ($h | split(".") | if length > 2 then .[-2:] else . end | join(".")))" )
        ] | unique[]')" || die "could not read $f"
      needs="$needs $(printf '%s\n' "$n" | sed -n 's/^need //p' | tr '\n' ' ')"
      printf '%s\n' "$n" | grep -E '^(zone|host) ' || true
      break
    done
  done < <(printf '%s\n' "$parts")
  # permissions no binding shows, from CF_TOKEN_PERMS in make/project.mk (realtime for a TURN app, access for an
  # Access application the project edits)
  needs="$needs $(project_setting CF_TOKEN_PERMS)"
  # an OTA bucket (firmware or app OTA uploads) needs R2; a project whose only Cloudflare use is that bucket needs no
  # Workers Scripts
  if project_ota_bucket; then
    needs="$needs r2"
    [ -n "$parts" ] || needs="$needs no_workers"
  fi
  # access means the project makes its Access application and its service token: both permissions (v37)
  case " $needs " in *" access "*) needs="$needs access_tokens access_org" ;; esac
  for n in account workers d1 kv r2 queue pages realtime access access_tokens access_org routes; do
    case "$n" in
      account) printf 'perm %s\n' "$n" ;;
      workers) case " $needs " in *" no_workers "*) ;; *) printf 'perm %s\n' "$n" ;; esac ;;
      *) case " $needs " in *" $n "*) printf 'perm %s\n' "$n" ;; esac ;;
    esac
  done
  case " $needs " in *" routes "*) printf 'perm dns\n' ;; esac
}

# token_template NEEDS   the dashboard URL for NEEDS (token_needs output), the token named after the project.
token_template() {
  local id key keys=""
  for id in $(printf '%s\n' "$1" | sed -n 's/^perm //p'); do
    key="$(perm_field "$id" 1)"
    [ -z "$key" ] || keys="$keys$key|$(perm_field "$id" 2)"$'\n'
  done
  printf '%s' "$keys" | jq -Rnr --arg base "$CF_TEMPLATE_BASE" --arg name "$PROJECT" '
    [inputs | select(. != "") | split("|") | {key: .[0], type: .[1]}] | tojson | @uri
    | "\($base)&permissionGroupKeys=\(.)&name=\($name | @uri)"'
}

# token_explain NEEDS URL [SUFFIX]   the URL, the permissions it asks for, and the zones to pick in the form (an account
# token URL cannot preset them).
token_explain() {
  local id zones hosts
  printf 'Create the Cloudflare API token for %s (an account API token; the form is pre-filled):\n  %s\n' "$PROJECT" "$2"
  printf 'Permissions:\n'
  for id in $(printf '%s\n' "$1" | sed -n 's/^perm //p'); do
    printf '  %-26s %s\n' "$(perm_field "$id" 3)" "$(perm_field "$id" 4)"
  done
  zones="$(printf '%s\n' "$1" | sed -n 's/^zone //p' | sort -u | tr '\n' ' ')"
  hosts="$(printf '%s\n' "$1" | sed -n 's/^host //p' | sort -u | tr '\n' ' ')"
  if [ -n "$zones" ]; then
    printf 'In the form, under the resources of the zone permissions (Workers Routes, DNS), choose "Specific zone"\n'
    printf 'and pick %s(routes and custom domains: %s). The link cannot preset zones.\n' "$zones" "${hosts% }"
  fi
  printf 'Pick the account, set an expiry and create the token%s. The account id is the 32 hex characters\n' "${3:-}"
  printf 'after dash.cloudflare.com/ in the address bar.\n'
}

# open_url URL   in the browser: open on macOS, xdg-open elsewhere; nothing with CF_NO_BROWSER=1 or neither command.
open_url() {
  [ "${CF_NO_BROWSER:-}" != 1 ] || return 0
  if [ "$(uname -s)" = Darwin ] && command -v open >/dev/null 2>&1; then
    open "$1" >/dev/null 2>&1 || log_warn "could not open the browser; open the URL above by hand"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1" >/dev/null 2>&1 || log_warn "could not open the browser; open the URL above by hand"
  fi
}

# login_check TOKEN ACCT NEEDS   the cf-token-check probes for what NEEDS lists, with the token just stored. Says
# which permissions it cannot reach and returns 1 when there is one. Tail and the zone permissions are not probed.
login_check() {
  local id path bad=""
  for id in $(printf '%s\n' "$3" | sed -n 's/^perm //p'); do
    case "$id" in
      workers) path=/workers/scripts ;;
      d1) path=/d1/database ;;
      kv) path=/storage/kv/namespaces ;;
      r2) path=/r2/buckets ;;
      queue) path=/queues ;;
      pages) path=/pages/projects ;;
      realtime) path=/calls/turn_keys ;;
      access) path=/access/apps ;;
      access_tokens) path=/access/service_tokens ;;
      access_org) path=/access/organizations ;;
      *) continue ;;
    esac
    probe_one "$id" "$path" "$1" "$2" >&2 || bad="$bad $id"
  done
  [ -n "$bad" ] || return 0
  for id in $bad; do log_warn "the token is missing $(perm_field "$id" 3)"; done
  log_warn "add them to the token in the dashboard (Manage Account > Account API Tokens), then run make cf-token-check"
  return 1
}

# cf.sh token-url: the template URL and the permission list on stdout. Reads the wrangler files only: no token,
# no network, no browser.
cmd_token_url() {
  parse_args "$@"
  need_project
  need_cmd jq
  local needs
  needs="$(token_needs)"
  token_explain "$needs" "$(token_template "$needs")" ", then store it with make cf-login"
}

# cf-login: the token comes from CLOUDFLARE_API_TOKEN when it is set (scripts, CI), else from the terminal (hidden,
# after the pre-filled dashboard form is opened), else from stdin: line 1 token, line 2 account id. The account id,
# when it is not stored or in CLOUDFLARE_ACCOUNT_ID, comes the same way. --env is accepted and changes nothing.
cmd_login() {
  parse_args "$@"
  need_env
  need_project
  need_cmd curl
  need_cmd jq
  local token="${CLOUDFLARE_API_TOKEN:-}" acct="${CLOUDFLARE_ACCOUNT_ID:-}" res status accounts count e needs url
  [ -n "$acct" ] || acct="$(stored_account_id)"
  needs="$(token_needs)"
  if [ -n "$token" ]; then
    log_info "using CLOUDFLARE_API_TOKEN from the environment"
  elif [ -t 0 ] || [ -n "${STD_TTY:-}" ]; then
    local tty="${STD_TTY:-/dev/tty}"
    url="$(token_template "$needs")"
    token_explain "$needs" "$url" ", then paste it below" >&2
    open_url "$url"
    if [ -z "$acct" ]; then
      printf 'Cloudflare account id (Enter to look it up from the token): ' >&2
      IFS= read -r acct <"$tty" || true
    fi
    printf 'Cloudflare API token for %s (all environments), input hidden: ' "$PROJECT" >&2
    IFS= read -r -s token <"$tty" || true
    printf '\n' >&2
  else
    IFS= read -r token || true
    if [ -z "$acct" ]; then IFS= read -r acct || true; fi
  fi
  [ -n "$token" ] || die "no token entered"
  [ -z "$acct" ] || need_account_id "$acct"
  res="$(verify_token "$token" "$acct")"
  status="${res%%|*}"
  if [ "$status" != active ] && [ -z "$acct" ]; then
    # an account-owned token and no id given: find its account and verify under it
    acct="$(token_account "$token")"
    [ -z "$acct" ] || status=active
  fi
  [ "$status" = active ] || die "Cloudflare does not accept this token (status: $status)${acct:+ for account $acct}"
  if [ -z "$acct" ]; then
    accounts="$(api_get "$CF_API/accounts" "$token")" || die "could not list accounts"
    count="$(printf '%s' "$accounts" | jq -r '.result | length' 2>/dev/null || echo 0)"
    [ "$count" = 1 ] || die "the token sees $count accounts; give the account id (CLOUDFLARE_ACCOUNT_ID=... make cf-login)"
    acct="$(printf '%s' "$accounts" | jq -r '.result[0].id')"
    need_account_id "$acct"
  fi
  for e in $TOKEN_ENVS; do
    store_secret CLOUDFLARE_API_TOKEN "$e" "$token" || die "the token was not stored for $e; run make cf-login again (make cf-whoami shows which copies differ)"
  done
  store_secret CLOUDFLARE_ACCOUNT_ID common "$acct"
  log_ok "token verified and stored for $PROJECT in staging and production (account $acct)"
  local rc=0
  login_check "$token" "$acct" "$needs" || rc=1
  token=""
  return "$rc"
}

cmd_logout() {
  parse_args "$@"
  need_env
  need_project
  local e
  for e in $TOKEN_ENVS; do
    "$SECRETS_SH" unset CLOUDFLARE_API_TOKEN --project "$PROJECT" --env "$e"
  done
  log_info "revoke the token itself in the dashboard: $DASHBOARD_TOKENS_URL"
}

# cf-whoami: the account and the project's one token (status, expiry). Reads both stored copies (one unlock each)
# and says when they differ or one is missing, as after a cf-login that stopped half way; exit 1 then.
cmd_whoami() {
  parse_args "$@"
  need_project
  need_cmd curl
  need_cmd jq
  local res acct t_s t_p
  acct="${CLOUDFLARE_ACCOUNT_ID:-}"
  [ -n "$acct" ] || acct="$(stored_account_id)"
  [ -z "$acct" ] || need_account_id "$acct"
  printf 'account: %s\n' "${acct:-unknown}"
  t_s="$(token_copy staging)"
  t_p="$(token_copy production)"
  if [ -z "$t_s" ] && [ -z "$t_p" ]; then
    printf 'token:   none stored (make cf-login)\n'
    return 0
  fi
  if [ "$t_s" = "$t_p" ]; then
    res="$(verify_token "$t_s" "$acct")"
    t_s="" t_p=""
    printf 'token:   %s  expires %s  (one token, stored for staging and production)\n' "${res%%|*}" "${res#*|}"
    return 0
  fi
  if [ -z "$t_s" ] || [ -z "$t_p" ]; then
    local only=production
    [ -z "$t_s" ] || only=staging
    res="$(verify_token "$t_s$t_p" "$acct")"
    t_s="" t_p=""
    printf 'token:   %s  expires %s  (stored for %s only; make cf-login stores it for staging and production)\n' "${res%%|*}" "${res#*|}" "$only"
    return 1
  fi
  printf 'token:   the staging and production copies differ (a cf-login that stopped half way?); make cf-login stores one token for both\n'
  res="$(verify_token "$t_s" "$acct")"
  t_s=""
  printf '  %-11s %s  expires %s\n' staging "${res%%|*}" "${res#*|}"
  res="$(verify_token "$t_p" "$acct")"
  t_p=""
  printf '  %-11s %s  expires %s\n' production "${res%%|*}" "${res#*|}"
  return 1
}

# probe_one NAME PATH [TOKEN ACCOUNT]   without TOKEN and ACCOUNT it runs under secrets exec, so both are in the
# environment; cf-login passes the token it just stored.
probe_one() {
  local resp tok="${3:-${CLOUDFLARE_API_TOKEN:-}}" acct="${4:-${CLOUDFLARE_ACCOUNT_ID:-}}"
  [ -n "$acct" ] || die "CLOUDFLARE_ACCOUNT_ID missing"
  [ -n "$tok" ] || die "CLOUDFLARE_API_TOKEN missing"
  need_account_id "$acct"
  resp="$(api_get "$CF_API/accounts/$acct$2" "$tok" 2>/dev/null || true)"
  if printf '%s' "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
    printf '%s %s\n' "$(paint 1 green ok)" "$1"
    return 0
  fi
  printf '%s %s\n' "$(paint 1 red 'no access')" "$1"
  return 1
}

# cf-token-check: the project's one token against every API the cloud-worker and web-pages parts and the OTA bucket need
# (the same list cf-login asks for: token_needs). Without a remote ENV it reads the production copy. Outside CI it also
# compares the copy of the other environment. A project with no Cloudflare part and no OTA_BUCKET says so.
cmd_token_check() {
  parse_args "$@"
  need_env
  need_project
  need_cmd curl
  need_cmd jq
  if ! project_uses_cf; then
    log_info "no cloud-worker or web-pages part and no OTA_BUCKET: this project uses no Cloudflare token"
    return 0
  fi
  if [ "$OPT_ENV" = local ]; then
    [ -n "${CF_SH_INNER:-}" ] || log_info "no ENV given: checking the production copy of the project token"
    OPT_ENV=production
  fi
  local bad=0 res needs other copy
  ensure_creds
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "no Cloudflare token stored for $OPT_ENV: make cf-login"
  [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || die "CLOUDFLARE_ACCOUNT_ID missing: make cf-login stores it"
  need_account_id "$CLOUDFLARE_ACCOUNT_ID"
  res="$(verify_token "$CLOUDFLARE_API_TOKEN" "$CLOUDFLARE_ACCOUNT_ID")"
  printf 'token   %s  expires %s\n' "${res%%|*}" "${res#*|}"
  [ "${res%%|*}" = active ] || bad=1
  needs="$(token_needs)"
  login_check "$CLOUDFLARE_API_TOKEN" "$CLOUDFLARE_ACCOUNT_ID" "$needs" 2>&1 || bad=1
  # CI keys open one environment each, so the comparison is for a Mac only
  if [ -z "${CI:-}${GITHUB_ACTIONS:-}" ]; then
    other=staging
    [ "$OPT_ENV" != staging ] || other=production
    copy="$(token_copy "$other")"
    if [ -z "$copy" ]; then
      log_warn "no token stored for $other; make cf-login stores the one token for staging and production"
      bad=1
    elif [ "$copy" != "$CLOUDFLARE_API_TOKEN" ]; then
      log_warn "the $other copy of the token differs from the $OPT_ENV copy; make cf-login stores one token for both"
      bad=1
    fi
    copy=""
  fi
  return "$bad"
}

# --- subcommands: resources ---

# find_existing KIND NAME   print the id of an existing resource, or nothing.
find_existing() {
  local kind="$1" name="$2" out
  case "$kind" in
    d1)
      out="$(wr_global d1 list --json)" || return 1
      printf '%s' "$out" | jq -r --arg n "$name" '[.[] | select(.name == $n) | .uuid][0] // empty' ;;
    kv)
      out="$(wr_global kv namespace list)" || return 1
      printf '%s' "$out" | jq -r --arg n "$name" '[.[] | select(.title == $n) | .id][0] // empty' ;;
    r2)
      out="$(wr_global r2 bucket list)" || return 1
      printf '%s\n' "$out" | grep -E "^name:[[:space:]]+$name\$" | sed -n -E '1s/^name:[[:space:]]+//p' ;;
    queue)
      # the name as a whole table cell: `grep -w` would also take "jobs" from "jobs-dlq" ("-" ends a word)
      out="$(wr_global queues list)" || return 1
      printf '%s\n' "$out" | awk -v n="$name" '!f { for (i = 1; i <= NF; i++) if ($i == n) { print n; f = 1; break } }' ;;
  esac
}

kv_title() { printf '%s-%s-%s' "$PROJECT" "$OPT_ENV" "$1" | tr 'A-Z_' 'a-z-'; }

cmd_provision() {
  parse_args "$@"
  need_env
  if [ "$OPT_ENV" = local ]; then
    log_info "local needs no provisioning (wrangler dev creates local state)"
    return 0
  fi
  need_project
  need_cmd jq
  local file kind binding name id found out title
  file="$(config_file)"
  need_env_block "$file"
  ensure_creds
  while IFS='|' read -r kind binding name id; do
    [ -n "$kind" ] || continue
    case "$kind" in
      d1)
        found="$(find_existing d1 "$name")"
        if [ -z "$found" ]; then
          out="$(wr_global d1 create "$name")" || die "d1 create $name failed"
          found="$(printf '%s' "$out" | grep -o -E '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | sed -n 1p)"
          [ -n "$found" ] || die "could not read the new database id for $name"
          log_ok "created D1 $name"
        else
          log_info "D1 $name exists"
        fi
        if [ "$id" != "$found" ]; then set_id "$file" "$OPT_ENV" database_name "$name" database_id "$found"; log_ok "wrote database_id for $name"; fi ;;
      kv)
        title="$(kv_title "$binding")"
        found="$(find_existing kv "$title")"
        if [ -z "$found" ] && is_hex32 "$id"; then
          found="$id"
          log_info "KV $binding exists ($id)"
        elif [ -z "$found" ]; then
          out="$(wr_global kv namespace create "$title")" || die "kv namespace create $title failed"
          found="$(printf '%s' "$out" | grep -o -E '[0-9a-f]{32}' | sed -n 1p)"
          [ -n "$found" ] || die "could not read the new namespace id for $title"
          log_ok "created KV $title"
        else
          log_info "KV $title exists"
        fi
        if [ "$id" != "$found" ]; then set_id "$file" "$OPT_ENV" binding "$binding" id "$found"; log_ok "wrote id for KV $binding"; fi ;;
      r2)
        if [ -z "$(find_existing r2 "$name")" ]; then
          wr_global r2 bucket create "$name" >/dev/null || die "r2 bucket create $name failed"
          log_ok "created R2 $name"
        else
          log_info "R2 $name exists"
        fi ;;
      queue)
        if [ -z "$(find_existing queue "$name")" ]; then
          wr_global queues create "$name" >/dev/null || die "queues create $name failed"
          log_ok "created queue $name"
        else
          log_info "queue $name exists"
        fi ;;
    esac
  done <<EOF
$(declared "$file" "$OPT_ENV")
EOF
}

cmd_status() {
  parse_args "$@"
  need_remote_env
  need_project
  need_cmd jq
  local file kind binding name id found state problems=0 key
  file="$(config_file)"
  need_env_block "$file"
  ensure_creds
  printf '%-6s %-24s %-32s %s\n' KIND BINDING NAME STATE
  while IFS='|' read -r kind binding name id; do
    [ -n "$kind" ] || continue
    key="$name"
    [ "$kind" != kv ] || key="$(kv_title "$binding")"
    found="$(find_existing "$kind" "$key")"
    if [ -z "$found" ]; then
      state="$(paint 1 red missing)"
      problems=$((problems + 1))
    elif { [ "$kind" = d1 ] || [ "$kind" = kv ]; } && [ "$id" != "$found" ]; then
      state="$(paint 1 yellow 'exists, id not in wrangler.jsonc (make cf-provision)')"
      problems=$((problems + 1))
    else
      state="$(paint 1 green ok)"
    fi
    printf '%-6s %-24s %-32s %s\n' "$kind" "$binding" "${name:-$key}" "$state"
  done <<EOF
$(declared "$file" "$OPT_ENV")
EOF
  # extras: databases of this project's environment that wrangler.jsonc does not declare
  # the declared names are read once; `producer | grep -q` under pipefail can count a match as none (1.11)
  local dnames
  dnames="$(declared "$file" "$OPT_ENV" | cut -d'|' -f3)" || dnames=''
  wr_global d1 list --json 2>/dev/null | jq -r --arg p "$PROJECT-$OPT_ENV" '.[] | select(.name | startswith($p)) | .name' 2>/dev/null |
    while IFS= read -r name; do
      if ! has_match "$dnames" -xF -- "$name"; then
        printf '%-6s %-24s %-32s %s\n' d1 - "$name" "$(paint 1 yellow 'extra (exists, not declared)')"
      fi
    done || true
  [ "$problems" = 0 ] || return 1
}

# --- the OTA bucket (make/project.mk, not a Worker binding) ---

# ota_buckets   every OTA bucket make/project.mk names (OTA_BUCKET and each <part>_OTA_BUCKET), each once, in file order.
# A value holding a make reference ($(...)) is another setting's name and is skipped; any other value must be an R2
# bucket name.
ota_buckets() {
  local f="${STD_PROJECT_MK:-make/project.mk}" b
  [ -f "$f" ] || return 0
  awk '
    $0 ~ /^[ \t]*([A-Za-z0-9_-]+_)?OTA_BUCKET[ \t]*(:|::|\?)?=/ {
      v = $0; sub(/^[^=]*=/, "", v); sub(/#.*/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v != "" && index(v, "$") == 0 && !seen[v]++) print v
    }' "$f" | while IFS= read -r b; do
    printf '%s' "$b" | grep -Eq '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' ||
      die "invalid OTA bucket name in $f: $b (R2: 3-63 characters, a-z 0-9 and -)"
    printf '%s\n' "$b"
  done
}

# ota_public   the OTA_PUBLIC setting: r2dev (turn the bucket's r2.dev URL on) or empty (leave the bucket private).
ota_public() {
  local v
  v="$(project_setting OTA_PUBLIC)"
  case "$v" in
    "" | r2dev) printf '%s' "$v" ;;
    *) die "OTA_PUBLIC := $v in make/project.mk: the one value is r2dev (or leave it unset for a private bucket)" ;;
  esac
}

# ota_wrangler ARGS...   wrangler for the OTA bucket, which belongs to no part: the pinned wrangler of the first
# cloud-worker or web-pages part that has it installed (in its dir), else `npx --yes wrangler@4` from the project root,
# the same wrangler the firmware releases upload with (<part>_WRANGLER).
ota_wrangler() {
  local kind dir
  while IFS='|' read -r kind dir; do
    [ -n "$dir" ] || continue
    if [ -x "$dir/node_modules/.bin/wrangler" ]; then
      (cd "$dir" && pm_wrangler "$@")
      return
    fi
  done < <(project_cloud_parts)
  npx --yes wrangler@4 "$@"
}

# ota_dev_url NAME   the bucket's public r2.dev URL, empty when it is off.
ota_dev_url() {
  local out
  out="$(ota_wrangler r2 bucket dev-url get "$1" 2>&1)" || return 1
  printf '%s\n' "$out" | grep -o -E 'https://[A-Za-z0-9.-]+\.r2\.dev[^[:space:]]*' | sed -n 1p || true
}

# provision-ota: make sure every OTA bucket exists (one bucket serves every env: objects go under
# <project>/<part>/<env>/), and with OTA_PUBLIC := r2dev turn its r2.dev URL on. Never makes a bucket private and never
# deletes one; wipe and destroy act on the Worker bindings only.
cmd_provision_ota() {
  parse_args "$@"
  need_env
  local buckets public name list url
  buckets="$(ota_buckets)"
  [ -n "$buckets" ] || return 0
  public="$(ota_public)"
  if [ "$OPT_ENV" = local ]; then
    log_info "local needs no OTA bucket (make cf-provision ENV=staging or ENV=production creates it)"
    return 0
  fi
  need_project
  ensure_creds
  list="$(ota_wrangler r2 bucket list)" || die "r2 bucket list failed"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if has_match "$list" -E "^name:[[:space:]]+$name\$"; then
      log_info "R2 OTA bucket $name exists"
    else
      ota_wrangler r2 bucket create "$name" >/dev/null || die "r2 bucket create $name failed"
      log_ok "created R2 OTA bucket $name"
    fi
    if [ "$public" = r2dev ]; then
      ota_wrangler r2 bucket dev-url enable "$name" -y >/dev/null || die "r2 bucket dev-url enable $name failed"
      url="$(ota_dev_url "$name")" || die "r2 bucket dev-url get $name failed"
      log_ok "R2 OTA bucket $name is public at ${url:-its r2.dev URL (wrangler r2 bucket dev-url get $name)}"
    else
      log_info "R2 OTA bucket $name is private: set OTA_PUBLIC := r2dev in make/project.mk and run make cf-provision again for a public r2.dev URL"
    fi
  done < <(printf '%s\n' "$buckets")
}

# status-ota: each OTA bucket, whether it exists and whether its r2.dev URL is on. Nothing when there is none.
cmd_status_ota() {
  parse_args "$@"
  local buckets name list state problems=0 url
  buckets="$(ota_buckets)"
  [ -n "$buckets" ] || return 0
  need_remote_env
  need_project
  ensure_creds
  list="$(ota_wrangler r2 bucket list)" || die "r2 bucket list failed"
  printf '%-6s %-24s %-32s %s\n' KIND BINDING NAME STATE
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! has_match "$list" -E "^name:[[:space:]]+$name\$"; then
      state="$(paint 1 red 'missing (make cf-provision)')"
      problems=$((problems + 1))
    else
      url="$(ota_dev_url "$name")" || url=""
      if [ -n "$url" ]; then state="$(paint 1 green ok), r2.dev on: $url"; else state="$(paint 1 green ok), r2.dev off"; fi
    fi
    printf '%-6s %-24s %-32s %s\n' r2 "(OTA)" "$name" "$state"
  done < <(printf '%s\n' "$buckets")
  [ "$problems" = 0 ] || return 1
}

d1_names() { # FILE ENV
  declared "$1" "$2" | awk -F'|' '$1 == "d1" { print $2 "|" $3 }'
}

cmd_migrate() {
  parse_args "$@"
  need_env
  local file binding name where="--remote" verb=apply
  [ "$OPT_ENV" != local ] || where="--local"
  [ "$OPT_LIST" = 0 ] || verb=list
  [ "$OPT_ENV" = local ] || need_project
  file="$(config_file)"
  need_env_block "$file"
  ensure_creds
  while IFS='|' read -r binding name; do
    [ -n "$name" ] || continue
    wr d1 migrations "$verb" "$name" "$where"
  done <<EOF
$(d1_names "$file" "$OPT_ENV")
EOF
}

cmd_seed() {
  parse_args "$@"
  need_env
  [ "$OPT_ENV" != production ] || die "refused: seed data never goes into production"
  [ "$OPT_ENV" = local ] || need_project
  local file where="--remote" binding name sql first="" any=0 sub
  [ "$OPT_ENV" != local ] || where="--local"
  file="$(config_file)"
  need_env_block "$file"
  ensure_creds
  first="$(d1_names "$file" "$OPT_ENV" | sed -n 1p | cut -d'|' -f2)"
  [ -n "$first" ] || die "no D1 database declared for $OPT_ENV in $file"
  for sql in "$OPT_DIR"/seed/*.sql; do
    [ -e "$sql" ] || continue
    wr d1 execute "$first" --file "$sql" "$where"
    any=1
  done
  while IFS='|' read -r binding name; do
    [ -n "$name" ] || continue
    for sub in "$OPT_DIR/seed/$binding"/*.sql; do
      [ -e "$sub" ] || continue
      wr d1 execute "$name" --file "$sub" "$where"
      any=1
    done
  done <<EOF
$(d1_names "$file" "$OPT_ENV")
EOF
  [ "$any" = 1 ] || log_warn "no seed files in $OPT_DIR/seed"
}

# --- secrets to Cloudflare ---

# cf_secret_names ENV   names the schema marks as used by cf for ENV (or common), never CLOUDFLARE_*.
cf_secret_names() {
  [ -f "$SCHEMA" ] || die "no secrets.schema ($SCHEMA)"
  local name envs used _g _d
  while read -r name envs used _g _d || [ -n "$name" ]; do
    case "$name" in '' | '#'*) continue ;; esac
    case "$name" in CLOUDFLARE_*) continue ;; esac
    # a key file (env keys) is never a Worker secret, and its name may hold '-' (v39)
    case "$envs" in keys) continue ;; esac
    valid_env_name "$name" || die "secrets.schema: bad name '$name'"
    case ",$used," in *,cf,*) ;; *) continue ;; esac
    case ",$envs," in *,"$1",* | *,common,*) printf '%s\n' "$name" ;; esac
  done <"$SCHEMA"
}

cmd_secrets() {
  parse_args "$@"
  need_remote_env
  need_project
  need_cmd jq
  local names=() line n missing="" list file
  file="$(config_file)"
  need_env_block "$file"
  if [ -n "$OPT_ROTATE" ]; then
    valid_env_name "$OPT_ROTATE" || die "invalid secret name: $OPT_ROTATE"
    # rotate before the environment is loaded, so the new value is the one that gets pushed
    [ -n "${CF_SH_INNER:-}" ] || "$SECRETS_SH" rotate "$OPT_ROTATE" --project "$PROJECT" --env "$OPT_ENV"
    names=("$OPT_ROTATE")
  else
    # assigned first, so a bad schema name stops here instead of being swallowed by the substitution
    list="$(cf_secret_names "$OPT_ENV")"
    while IFS= read -r line; do [ -z "$line" ] || names+=("$line"); done <<EOF
$list
EOF
  fi
  ensure_creds
  if [ "${#names[@]}" -eq 0 ]; then
    log_info "no secrets are marked for cf in $SCHEMA for $OPT_ENV"
    return 0
  fi
  for n in "${names[@]}"; do
    valid_env_name "$n" || die "invalid secret name: $n"
    if [ -z "${!n:-}" ]; then missing="$missing $n"; fi
  done
  [ -z "$missing" ] || die "missing in the secrets for $OPT_ENV:$missing (make secrets-set)"
  # the JSON is built from the environment and goes to wrangler on stdin: no file, no argv
  jq -n 'reduce $ARGS.positional[] as $n ({}; .[$n] = env[$n])' --args "${names[@]}" |
    (cd "$OPT_DIR" && pm_wrangler secret bulk --env "$OPT_ENV")
  log_ok "pushed ${#names[@]} secret(s) to $OPT_ENV"
}

# --- backup, wipe, destroy ---

# recipient_file ENV   prints a temp file of public keys (not secret) the backup is encrypted to: the Secure
# Enclave keys of the enrolled Macs and the recovery key. Developer (Keychain) keys are only for local data.
recipient_file() {
  local f tmp kinds="se"
  tmp="$(mktemp "${TMPDIR:-/tmp}/std-rcpt.XXXXXXXX")"
  [ "$1" != local ] || kinds="se dev"
  for k in $kinds; do
    for f in "$SECRETS_DIR"/recipients/"$k"/*.txt; do
      if [ -e "$f" ]; then grep -v -E '^[[:space:]]*(#|$)' "$f" >>"$tmp" || true; fi
    done
  done
  if [ -e "$SECRETS_DIR/recipients/recovery.txt" ]; then grep -v -E '^[[:space:]]*(#|$)' "$SECRETS_DIR/recipients/recovery.txt" >>"$tmp" || true; fi
  [ -s "$tmp" ] || { rm -f "$tmp"; die "no recipients in $SECRETS_DIR/recipients to encrypt the backup to"; }
  printf '%s' "$tmp"
}

# backup_kv ID BINDING STAGE   every key with its value: kv-BINDING.json is the key list (with metadata), the
# values are kv-BINDING.values/N, N the position in the list. Names are read as base64, so any key name works.
backup_kv() {
  local id="$1" binding="$2" stage="$3" n=0 b64 name vdir="$3/kv-$2.values"
  wr_global kv key list --namespace-id "$id" >"$stage/kv-$binding.json" || die "kv key list $binding failed"
  mkdir -p "$vdir"
  while IFS= read -r b64; do
    [ -n "$b64" ] || continue
    name="$(printf '%s' "$b64" | base64 --decode)"
    wr_global kv key get "$name" --namespace-id "$id" >"$vdir/$n" || die "kv key get '$name' in $binding failed"
    n=$((n + 1))
  done < <(jq -r '.[].name | @base64' "$stage/kv-$binding.json")
}

cmd_backup() {
  parse_args "$@"
  need_remote_env
  need_project
  need_cmd age
  need_cmd tar
  need_cmd jq
  local file stage rcpt dest binding name id kind stamp
  file="$(config_file)"
  need_env_block "$file"
  ensure_creds
  stage="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/std-backup.XXXXXXXX")"
  rcpt="$(recipient_file "$OPT_ENV")"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$stage' '$rcpt'" EXIT
  # A D1 by name resolves through wrangler.jsonc, so every remote call names the env: the top level holds the local
  # bindings, and an adopted Worker's local database_id is a placeholder ("local") that the API refuses.
  while IFS='|' read -r kind binding name id; do
    [ -n "$kind" ] || continue
    case "$kind" in
      d1) wr_global d1 export "$name" --remote --env "$OPT_ENV" --output "$stage/d1-$binding.sql" >/dev/null || die "d1 export $name failed" ;;
      kv) backup_kv "$id" "$binding" "$stage" ;;
      r2) wr_global r2 bucket info "$name" >"$stage/r2-$binding.txt" || die "r2 bucket info $name failed" ;;
    esac
  done <<EOF
$(declared "$file" "$OPT_ENV")
EOF
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_ROOT/$PROJECT"
  chmod 700 "$BACKUP_ROOT/$PROJECT"
  dest="$BACKUP_ROOT/$PROJECT/$OPT_ENV-$stamp.tar.age"
  tar -C "$stage" -cf - . | age -R "$rcpt" -o "$dest.tmp" || { rm -f "$dest.tmp"; die "backup encryption failed"; }
  mv "$dest.tmp" "$dest"
  log_ok "backup written: $dest"
  if strip_jsonc "$file" | jq -e --arg e "$OPT_ENV" '(.env[$e].durable_objects.bindings // []) | length > 0' >/dev/null 2>&1; then
    log_warn "Durable Object storage is NOT in this backup (it holds D1 and KV only); deleting the Worker deletes that storage"
  fi
}

# check_destructive_ok   run before wipe and destroy: refuse when a name does not belong to this environment, and
# when the backup cannot hold a declared resource (it would be deleted or left with nothing to restore from).
check_destructive_ok() {
  local file="$1" kind binding name id wname bad=""
  while IFS='|' read -r kind binding name id; do
    [ -n "$kind" ] || continue
    case "$kind" in
      d1 | r2 | queue)
        case "$name" in
          "$PROJECT-$OPT_ENV"*) ;;
          *) bad="$bad $kind:$name" ;;
        esac ;;
    esac
  done <<EOF
$(declared "$file" "$OPT_ENV")
EOF
  [ -z "$bad" ] || die "refused: resource name(s) not starting with $PROJECT-$OPT_ENV:$bad (rename them in $file, then make cf-provision ENV=$OPT_ENV)"
  wname="$(strip_jsonc "$file" | jq -r --arg e "$OPT_ENV" '.env[$e].name // empty' 2>/dev/null || true)"
  if [ -n "$wname" ]; then
    case "$wname" in
      *"-$OPT_ENV" | "$PROJECT-$OPT_ENV"*) ;;
      *) die "refused: the Worker name '$wname' neither ends with -$OPT_ENV nor starts with $PROJECT-$OPT_ENV" ;;
    esac
  fi
  local dkinds
  dkinds="$(declared "$file" "$OPT_ENV" | cut -d'|' -f1)" || dkinds=''
  if has_match "$dkinds" -x r2; then
    if [ "$OPT_R2_UNBACKED" != 1 ]; then
      die "refused: R2 objects cannot be backed up (wrangler cannot list or download them), so $OPT_ENV would lose them. Copy them yourself first (for example with rclone), then repeat with R2_UNBACKED=1 on the command line"
    fi
    log_warn "R2 objects are NOT in the backup (R2_UNBACKED=1)"
  fi
  if has_match "$dkinds" -x queue; then
    log_warn "queue messages are not backed up (queues hold no stored data, only messages in flight)"
  fi
}

cmd_wipe() {
  parse_args "$@"
  need_remote_env
  need_project
  require_confirm "$OPT_ENV"
  local file kind binding name id tables t sql keyfile
  file="$(config_file)"
  check_destructive_ok "$file"
  ensure_creds
  cmd_backup --project "$PROJECT" --env "$OPT_ENV" --dir "$OPT_DIR"
  while IFS='|' read -r kind binding name id; do
    [ -n "$kind" ] || continue
    case "$kind" in
      d1)
        tables="$(wr_global d1 execute "$name" --remote --env "$OPT_ENV" --json --command "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> 'd1_migrations'" |
          jq -r '.[0].results[].name')"
        sql="PRAGMA defer_foreign_keys = on;"
        for t in $tables; do sql="$sql DELETE FROM \"$t\";"; done
        wr_global d1 execute "$name" --remote --env "$OPT_ENV" --command "$sql" >/dev/null
        log_ok "emptied D1 $name" ;;
      kv)
        # key names only (no values) go into the bulk delete file
        keyfile="$(umask 077 && mktemp "${TMPDIR:-/tmp}/std-kv.XXXXXXXX")"
        wr_global kv key list --namespace-id "$id" | jq '[.[].name]' >"$keyfile"
        wr_global kv bulk delete "$keyfile" --namespace-id "$id" --force >/dev/null
        rm -f "$keyfile"
        log_ok "emptied KV $binding" ;;
      r2) log_warn "R2 $name not emptied: wrangler cannot list objects; empty it in the dashboard" ;;
    esac
  done <<EOF
$(declared "$file" "$OPT_ENV")
EOF
}

cmd_destroy() {
  parse_args "$@"
  need_remote_env
  need_project
  require_confirm "$OPT_ENV"
  if [ "$OPT_ENV" = production ]; then
    [ -z "${CI:-}${GITHUB_ACTIONS:-}" ] || die "refused: CI cannot destroy production"
  fi
  local file kind binding name id
  file="$(config_file)"
  check_destructive_ok "$file"
  ensure_creds
  if [ "$OPT_ENV" = production ]; then
    # asked in this process, after the unlock, on the terminal only: an environment variable cannot answer it
    confirm_typed "$PROJECT" "Type the project name ($PROJECT) to destroy production:"
  fi
  cmd_backup --project "$PROJECT" --env "$OPT_ENV" --dir "$OPT_DIR"
  wr delete --force || log_warn "worker delete failed or the worker does not exist"
  while IFS='|' read -r kind binding name id; do
    [ -n "$kind" ] || continue
    case "$kind" in
      d1) wr_global d1 delete "$name" --env "$OPT_ENV" -y >/dev/null || log_warn "d1 delete $name failed" ;;
      r2) wr_global r2 bucket delete "$name" >/dev/null || log_warn "r2 bucket delete $name failed (it must be empty)" ;;
      queue) wr_global queues delete "$name" >/dev/null || log_warn "queues delete $name failed" ;;
      kv)
        if [ -n "$id" ]; then
          need_account_id "${CLOUDFLARE_ACCOUNT_ID:-}"
          api_delete "$CF_API/accounts/$CLOUDFLARE_ACCOUNT_ID/storage/kv/namespaces/$id" "${CLOUDFLARE_API_TOKEN:?}" ||
            log_warn "kv delete $binding failed"
        fi ;;
    esac
  done <<EOF
$(declared "$file" "$OPT_ENV")
EOF
  log_ok "destroyed the $OPT_ENV resources of $PROJECT (backup kept)"
}

# --- Cloudflare Access (1.7): make <part>-access, <part>-access-check, and the part's doctor line ---
#
# One self-hosted Access application per part and remote env, found or made by name: <project>-<env>-<part> on the
# part's host[/path] (the custom domain of env.<env> in its wrangler.jsonc unless --host names one). It has two reusable
# policies: <name>-allow (Allow; include: the email domains and the single addresses, synced to the settings on every
# run) and <name>-service (Service Auth; include: the service token). The service token is the one whose client id is
# CF_ACCESS_CLIENT_ID in the env's secrets, else the one named <name>, else a new one named <name>; a new or rotated
# token's id and secret go straight into the secrets (secrets.sh set, on stdin), never printed. The application's aud
# and the team domain go into env.<env>.vars of the wrangler file as ACCESS_AUD and ACCESS_TEAM_DOMAIN (a textual edit
# that keeps comments). API (developers.cloudflare.com/api/resources/zero_trust/subresources/access/, read 2026-11-18):
#   GET  /accounts/A/access/organizations                 auth_domain, the team domain <team>.cloudflareaccess.com
#   GET  /accounts/A/access/service_tokens                POST {name, duration}; POST .../service_tokens/ID/rotate
#   GET  /accounts/A/access/policies                      POST {name, decision, include}; GET and PUT .../policies/ID
#   GET  /accounts/A/access/apps                          POST {name, type, domain, destinations, policies, ...}; PUT .../apps/ID
# The token needs CF_TOKEN_PERMS := access (Access: Apps and Policies: Edit, Service Tokens: Edit, Organizations: Read).

ACCESS_NAME=""
ACCESS_HOST=""
ACCESS_PATH=""
ACCESS_DOMAIN=""
ACCESS_SESSION=""
ACCESS_DOMAINS=""
ACCESS_EMAILS=""
TOK_ID=""
TOK_NAME=""
POL_ID=""
APP_AUD=""
ACCESS_STORED=0
ACCESS_VARS_CHANGED=0

valid_host() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }
valid_email() { printf '%s' "$1" | grep -Eq '^[a-z0-9._%+-]+@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }

# words LIST   the space or comma separated items of LIST, lowercased, each once, one per line.
words() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr ',' ' ' | tr -s ' \t' '\n' | awk 'NF && !seen[$0]++'; }

# a_found TEXT / a_did VERB TEXT   one line of what access found or did (with --dry: what it would do), on stdout.
a_found() { printf '%s %s\n' "$(paint 1 blue found)" "$*"; }
a_did() {
  local now
  if [ "$OPT_DRY" = 1 ]; then
    case "$1" in wrote) now="write" ;; *) now="${1%d}" ;; esac
    printf '%s %s %s\n' "$(paint 1 yellow would)" "$now" "$2"
  else
    printf '%s %s\n' "$(paint 1 green "$1")" "$2"
  fi
}

# access_default_host   the custom domain of env.<ENV> in the part's wrangler file: its one route with "custom_domain": true.
access_default_host() {
  local file hosts n
  file=""
  for n in wrangler.jsonc wrangler.json; do
    if [ -f "$OPT_DIR/$n" ]; then file="$OPT_DIR/$n"; break; fi
  done
  [ -n "$file" ] || die "no wrangler.jsonc in $OPT_DIR to read the custom domain from: set ${OPT_PART}_ACCESS_HOST in make/project.mk"
  hosts="$(strip_jsonc "$file" | jq -r --arg e "$OPT_ENV" '
    (.env[$e] // {}) | ([.route] + (.routes // []))[]
    | select(type == "object" and .custom_domain == true) | .pattern // empty
    | sub("^[a-z]+://"; "") | sub("/.*$"; "")' 2>/dev/null | awk 'NF && !seen[$0]++')" || die "could not read $file"
  n="$(printf '%s\n' "$hosts" | awk 'NF' | wc -l | tr -d ' ')"
  [ "$n" != 0 ] || die "no custom domain for $OPT_ENV in $file (a route with \"custom_domain\": true under env.$OPT_ENV): set ${OPT_PART}_ACCESS_HOST in make/project.mk"
  [ "$n" = 1 ] || die "env.$OPT_ENV of $file has $n custom domains ($(printf '%s' "$hosts" | tr '\n' ' ')): set ${OPT_PART}_ACCESS_HOST to the one Access protects"
  printf '%s' "$hosts"
}

# access_settings   check and normalise the part's settings: ACCESS_NAME, ACCESS_HOST, ACCESS_PATH, ACCESS_DOMAIN
# (host[/path], what the application covers), ACCESS_DOMAINS, ACCESS_EMAILS (one per line), ACCESS_SESSION.
access_settings() {
  local w
  if [ -z "$OPT_PART" ] || ! valid_name "$OPT_PART"; then die "this command needs --part P (a part name)"; fi
  ACCESS_NAME="$PROJECT-$OPT_ENV-$OPT_PART"
  ACCESS_HOST="$(printf '%s' "$OPT_HOST" | tr '[:upper:]' '[:lower:]')"
  [ -n "$ACCESS_HOST" ] || ACCESS_HOST="$(access_default_host)"
  valid_host "$ACCESS_HOST" || die "invalid Access host: $ACCESS_HOST (${OPT_PART}_ACCESS_HOST is a host name only, no scheme or path)"
  ACCESS_PATH="$OPT_PATH"
  case "$ACCESS_PATH" in "" | /*) ;; *) ACCESS_PATH="/$ACCESS_PATH" ;; esac
  [ "$ACCESS_PATH" != / ] || ACCESS_PATH=""
  if [ -n "$ACCESS_PATH" ]; then
    printf '%s' "$ACCESS_PATH" | grep -Eq '^(/[A-Za-z0-9._~%*-]+)+/?$' ||
      die "invalid ${OPT_PART}_ACCESS_PATH: $ACCESS_PATH (a URL path such as /admin; empty means the whole host)"
  fi
  ACCESS_DOMAIN="$ACCESS_HOST$ACCESS_PATH"
  ACCESS_SESSION="${OPT_SESSION:-24h}"
  printf '%s' "$ACCESS_SESSION" | grep -Eq '^[0-9]+(h|m|s)$' ||
    die "invalid ${OPT_PART}_ACCESS_SESSION: $ACCESS_SESSION (a duration such as 24h, 30m)"
  ACCESS_DOMAINS="$(words "$OPT_EMAIL_DOMAINS")"
  ACCESS_EMAILS="$(words "$OPT_EMAILS")"
  for w in $ACCESS_DOMAINS; do
    case "$w" in *@*) die "${OPT_PART}_ACCESS_EMAIL_DOMAINS holds an address ($w): single addresses go in ${OPT_PART}_ACCESS_EMAILS" ;; esac
    valid_host "$w" || die "invalid email domain in ${OPT_PART}_ACCESS_EMAIL_DOMAINS: $w"
  done
  for w in $ACCESS_EMAILS; do
    valid_email "$w" || die "invalid address in ${OPT_PART}_ACCESS_EMAILS: $w"
  done
}

# access_need_perms   the project token is made with the Access permissions only when CF_TOKEN_PERMS names access.
access_need_perms() {
  case " $(project_setting CF_TOKEN_PERMS) " in *" access "*) return 0 ;; esac
  log_err "the project's Cloudflare token is not made for Access: CF_TOKEN_PERMS in make/project.mk does not name access"
  printf '  add access to make/project.mk, on its CF_TOKEN_PERMS line or as a new one:\n    CF_TOKEN_PERMS := access\n' >&2
  printf '  then run make cf-login again: it names the Access permissions to add to the token, and make cf-token-check probes them\n' >&2
  exit 1
}

# schema_declares NAME ENV   secrets.schema has a row for NAME whose envs name ENV.
schema_declares() {
  [ -f "$SCHEMA" ] || return 1
  awk -v n="$1" -v e="$2" '$1 == n && index("," $2 ",", "," e ",") { f = 1 } END { exit !f }' "$SCHEMA"
}

# access_schema_rows   the two secrets.schema rows of the service token (scaffold.sh writes the same).
access_schema_rows() {
  printf '%-22s %-26s %-14s %-5s %s\n' CF_ACCESS_CLIENT_ID staging,production auth,ci no \
    "the Cloudflare Access service token's client id (make <part>-access stores it; the smoke sends it)"
  printf '%-22s %-26s %-14s %-5s %s\n' CF_ACCESS_CLIENT_SECRET staging,production auth,ci no \
    "the Cloudflare Access service token's secret (make <part>-access stores it)"
}

access_need_schema() {
  local n miss=""
  for n in CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET; do
    schema_declares "$n" "$OPT_ENV" || miss="$miss $n"
  done
  [ -n "$miss" ] || return 0
  log_err "$SCHEMA does not declare$miss for $OPT_ENV: the service token's id and secret are kept under those names"
  printf '  add these rows to %s (scaffold.sh --force adds them to a project that sets <part>_ACCESS_* settings):\n' "$SCHEMA" >&2
  access_schema_rows | sed 's/^/    /' >&2
  exit 1
}

# api_call METHOD PATH [BODY]   one Cloudflare API call with the project token, which goes in a curl config on stdin and
# never in argv; the body (no secret: names, addresses, ids) is an argument. The response JSON on stdout. On failure it
# says the status and Cloudflare's own error codes and messages, never the response (a token's secret can be in one),
# and returns 2 when the token itself was refused (401, 403, codes 10000 and 9109), else 1.
api_call() {
  local method="$1" url="$CF_API$2" body="${3:-}" out code resp msg
  cfg_safe "$url" "${CLOUDFLARE_API_TOKEN:-}" || die "refused: the URL or token holds a quote, backslash or line break"
  if [ -n "$body" ]; then
    out="$(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\nurl = "%s"\nrequest = "%s"\n' \
      "$CLOUDFLARE_API_TOKEN" "$url" "$method" | curl -sS --max-time 30 -w '\n%{http_code}' -K - --data-binary "$body")" || out=""
  else
    out="$(printf 'header = "Authorization: Bearer %s"\nurl = "%s"\nrequest = "%s"\n' \
      "$CLOUDFLARE_API_TOKEN" "$url" "$method" | curl -sS --max-time 30 -w '\n%{http_code}' -K -)" || out=""
  fi
  [ -n "$out" ] || { log_err "could not reach the Cloudflare API ($method ${2%%\?*})"; return 1; }
  code="${out##*$'\n'}"
  resp="${out%$'\n'*}"
  if printf '%s' "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
    printf '%s' "$resp"
    return 0
  fi
  msg="$(printf '%s' "$resp" | jq -r '[.errors[]? | "\(.code // "") \(.message // "")"] | join("; ")' 2>/dev/null || true)"
  log_err "$method ${2%%\?*} answered ${code:-?}${msg:+: $msg}"
  case "$code" in 401 | 403) return 2 ;; esac
  if printf '%s' "$resp" | jq -e '[.errors[]?.code] | any(. == 10000 or . == 9109)' >/dev/null 2>&1; then return 2; fi
  return 1
}

# access_api METHOD PATH [BODY]   api_call, stopping with what to do when it fails. Call as x="$(access_api ...)" || exit 1.
access_api() {
  local rc=0 out
  out="$(api_call "$@")" || rc=$?
  if [ "$rc" = 2 ]; then
    die "the Cloudflare API refused the project token for $1 ${2%%\?*}: it needs Access: Apps and Policies: Edit, Access: Service Tokens: Edit and Access: Organizations, Identity Providers, and Groups: Read (make cf-login names them, make cf-token-check probes them)"
  fi
  [ "$rc" = 0 ] || die "stopped at $1 ${2%%\?*}: what was made before is kept, and running the command again reuses it"
  printf '%s' "$out"
}

# access_list PATH   every item of a paged list, as one JSON array.
access_list() {
  local page=1 all='[]' resp items n total
  while :; do
    resp="$(access_api GET "$1?page=$page&per_page=50")" || exit 1
    items="$(printf '%s' "$resp" | jq -c '.result // []')"
    all="$(printf '%s\n%s' "$all" "$items" | jq -cs '.[0] + .[1]')"
    n="$(printf '%s' "$items" | jq 'length')"
    total="$(printf '%s' "$resp" | jq -r '.result_info.total_pages // empty')"
    if [ -n "$total" ]; then [ "$page" -lt "$total" ] || break; else [ "$n" -ge 50 ] || break; fi
    [ "$n" -gt 0 ] || break
    page=$((page + 1))
    [ "$page" -le 100 ] || break
  done
  printf '%s' "$all"
}

# access_store NAME VALUE   one value into the env's secrets, on stdin (STD_TTY emptied so set reads stdin, not a terminal).
access_store() {
  printf '%s' "$2" | STD_TTY='' "$SECRETS_SH" set "$1" --project "$PROJECT" --env "$OPT_ENV"
}

# access_store_token RESPONSE [CLIENT_ID]   the client id and secret of a token Cloudflare just made or rotated, into the
# secrets at once: the API shows a secret only in that answer.
access_store_token() {
  local cid sec
  cid="$(printf '%s' "$1" | jq -r '.result.client_id // empty')"
  [ -n "$cid" ] || cid="${2:-}"
  sec="$(printf '%s' "$1" | jq -r '.result.client_secret // empty')"
  if [ -z "$cid" ] || [ -z "$sec" ]; then
    die "the Cloudflare API answered without the service token's client id or secret: run make $OPT_PART-access ENV=$OPT_ENV ROTATE=1"
  fi
  if ! access_store CF_ACCESS_CLIENT_ID "$cid" || ! access_store CF_ACCESS_CLIENT_SECRET "$sec"; then
    sec=""
    die "could not store the service token in the $OPT_ENV secrets, and Cloudflare will not show its secret again: fix the secrets (make secrets-doctor), then make $OPT_PART-access ENV=$OPT_ENV ROTATE=1 gives it a new one"
  fi
  sec=""
  ACCESS_STORED=1
  a_did stored "CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET in the $OPT_ENV secrets (not shown)"
}

# access_service_token A   TOK_ID, TOK_NAME: the env's service token (the secrets' one, else the one named ACCESS_NAME,
# else a new one), made or rotated as needed.
access_service_token() {
  local A="$1" list stored="${CF_ACCESS_CLIENT_ID:-}" have_secret=0 tok="" n resp cid=""
  [ -z "${CF_ACCESS_CLIENT_SECRET:-}" ] || have_secret=1
  list="$(access_list "$A/access/service_tokens")" || exit 1
  if [ -n "$stored" ]; then
    tok="$(printf '%s' "$list" | jq -c --arg c "$stored" '[.[] | select(.client_id == $c)][0] // empty')"
  fi
  TOK_NAME="$ACCESS_NAME"
  if [ -n "$tok" ]; then
    TOK_ID="$(printf '%s' "$tok" | jq -r '.id')"
    TOK_NAME="$(printf '%s' "$tok" | jq -r '.name // empty')"
    if [ "$have_secret" = 1 ] && [ "$OPT_ROTATE_TOKEN" != 1 ]; then
      a_found "service token $TOK_NAME (the one in the $OPT_ENV secrets)"
      return 0
    fi
  else
    n="$(printf '%s' "$list" | jq --arg n "$ACCESS_NAME" '[.[] | select(.name == $n)] | length')"
    [ "$n" -le 1 ] || die "$n service tokens are named $ACCESS_NAME: remove the extra ones in the dashboard (Zero Trust, Access controls, Service credentials), then run this again"
    tok="$(printf '%s' "$list" | jq -c --arg n "$ACCESS_NAME" '[.[] | select(.name == $n)][0] // empty')"
    [ -z "$tok" ] || TOK_ID="$(printf '%s' "$tok" | jq -r '.id')"
  fi
  [ -z "$tok" ] || cid="$(printf '%s' "$tok" | jq -r '.client_id // empty')"
  if [ -z "$TOK_ID" ]; then
    a_did created "service token $ACCESS_NAME (it does not expire; its id and secret go into the $OPT_ENV secrets, never shown)"
    if [ "$OPT_DRY" = 1 ]; then TOK_ID="(new)"; return 0; fi
    resp="$(access_api POST "$A/access/service_tokens" "$(jq -nc --arg n "$ACCESS_NAME" '{name: $n, duration: "forever"}')")" || exit 1
    TOK_ID="$(printf '%s' "$resp" | jq -r '.result.id // empty')"
    [ -n "$TOK_ID" ] || die "the Cloudflare API made the service token $ACCESS_NAME but answered without its id: remove it in the dashboard and run this again"
    access_store_token "$resp"
    resp=""
    return 0
  fi
  if [ "$OPT_ROTATE_TOKEN" != 1 ]; then
    local why="the service token $TOK_NAME exists, but its secret is not in the $OPT_ENV secrets, and Cloudflare shows a secret only when it makes one: make $OPT_PART-access ENV=$OPT_ENV ROTATE=1 gives it a new secret and stores it (the old one stops working at once)"
    if [ "$OPT_DRY" = 1 ]; then log_warn "would stop here: $why"; return 0; fi
    die "$why. Nothing was changed."
  fi
  a_did rotated "service token $TOK_NAME: a new secret into the $OPT_ENV secrets (the old one stops working at once)"
  [ "$OPT_DRY" != 1 ] || return 0
  resp="$(access_api POST "$A/access/service_tokens/$TOK_ID/rotate" '{}')" || exit 1
  access_store_token "$resp" "$cid"
  resp=""
}

# The rules of a policy's include list, comparable: sorted "domain d", "email e", "token id", or the rule as JSON.
JQ_RULES='def rules: [ .[]? | if .email_domain then "domain " + (.email_domain.domain | ascii_downcase)
  elif .email then "email " + (.email.email | ascii_downcase)
  elif .service_token then "token " + .service_token.token_id
  else "rule " + tojson end ] | sort;'

# access_policy A NAME DECISION INCLUDE TEXT   POL_ID: the reusable policy NAME, made when missing, its include list set to
# INCLUDE (JSON) when it differs. TEXT says what INCLUDE is.
access_policy() {
  local A="$1" name="$2" decision="$3" include="$4" text="$5" label=Allow list n pol full resp have want
  [ "$decision" != non_identity ] || label="Service Auth"
  list="$(access_list "$A/access/policies")" || exit 1
  n="$(printf '%s' "$list" | jq --arg n "$name" '[.[] | select(.name == $n)] | length')"
  [ "$n" -le 1 ] || die "$n Access policies are named $name: remove the extra ones in the dashboard (Zero Trust, Access controls, Policies), then run this again"
  pol="$(printf '%s' "$list" | jq -c --arg n "$name" '[.[] | select(.name == $n)][0] // empty')"
  if [ -z "$pol" ]; then
    a_did created "$label policy $name ($text)"
    if [ "$OPT_DRY" = 1 ]; then POL_ID="(new)"; return 0; fi
    resp="$(access_api POST "$A/access/policies" "$(jq -nc --arg n "$name" --arg d "$decision" --argjson i "$include" '{name: $n, decision: $d, include: $i}')")" || exit 1
    POL_ID="$(printf '%s' "$resp" | jq -r '.result.id // empty')"
    [ -n "$POL_ID" ] || die "the Cloudflare API made the policy $name but answered without its id: run this again (it finds it)"
    return 0
  fi
  POL_ID="$(printf '%s' "$pol" | jq -r '.id')"
  [ "$(printf '%s' "$pol" | jq -r '.decision // empty')" = "$decision" ] ||
    die "the Access policy $name exists with the action $(printf '%s' "$pol" | jq -r '.decision // "?"'), not $label: rename or fix it in the dashboard, then run this again"
  full="$(access_api GET "$A/access/policies/$POL_ID")" || exit 1
  full="$(printf '%s' "$full" | jq -c '.result')"
  have="$(printf '%s' "$full" | jq -c "$JQ_RULES .include | rules")"
  want="$(printf '%s' "$include" | jq -c "$JQ_RULES rules")"
  if [ "$have" = "$want" ]; then
    a_found "$label policy $name ($text)"
    return 0
  fi
  a_did updated "$label policy $name: now $text (was $(printf '%s' "$have" | jq -r 'if length == 0 then "empty" else join(", ") end'))"
  [ "$OPT_DRY" != 1 ] || return 0
  access_api PUT "$A/access/policies/$POL_ID" "$(printf '%s' "$full" | jq -c --argjson i "$include" '.include = $i')" >/dev/null || exit 1
}

# access_app A POLICY_IDS   APP_AUD: the self-hosted application ACCESS_NAME (else the self-hosted one already on
# ACCESS_DOMAIN), made when missing; its domain, session duration and the two policies set when they differ.
access_app() {
  local A="$1" pols="$2" list n app id full resp changes="" missing body other
  list="$(access_list "$A/access/apps")" || exit 1
  n="$(printf '%s' "$list" | jq --arg n "$ACCESS_NAME" '[.[] | select(.name == $n)] | length')"
  [ "$n" -le 1 ] || die "$n Access applications are named $ACCESS_NAME: remove the extra ones in the dashboard (Zero Trust, Access controls, Applications), then run this again"
  app="$(printf '%s' "$list" | jq -c --arg n "$ACCESS_NAME" '[.[] | select(.name == $n)][0] // empty')"
  if [ -z "$app" ]; then
    app="$(printf '%s' "$list" | jq -c --arg d "$ACCESS_DOMAIN" '[.[] | select(.type == "self_hosted" and ((.domain // "") | ascii_downcase) == $d)][0] // empty')"
    if [ -n "$app" ]; then
      other="$(printf '%s' "$app" | jq -r '.name // "(no name)"')"
      log_info "no application named $ACCESS_NAME, but $other is already on $ACCESS_DOMAIN: using it (its name stays)"
    fi
  fi
  if [ -z "$app" ]; then
    a_did created "self-hosted Access application $ACCESS_NAME on $ACCESS_DOMAIN (session $ACCESS_SESSION, its policies attached)"
    if [ "$OPT_DRY" = 1 ]; then APP_AUD=""; return 0; fi
    body="$(jq -nc --arg n "$ACCESS_NAME" --arg d "$ACCESS_DOMAIN" --arg s "$ACCESS_SESSION" --argjson p "$pols" '{
      name: $n, type: "self_hosted", domain: $d, destinations: [{type: "public", uri: $d}],
      session_duration: $s, app_launcher_visible: false,
      policies: ($p | to_entries | map({id: .value, precedence: (.key + 1)}))}')"
    resp="$(access_api POST "$A/access/apps" "$body")" || exit 1
    APP_AUD="$(printf '%s' "$resp" | jq -r '.result.aud // empty')"
    [ -n "$APP_AUD" ] || die "the Cloudflare API made the application but answered without its aud: run this again (it finds it)"
    return 0
  fi
  id="$(printf '%s' "$app" | jq -r '.id')"
  full="$(access_api GET "$A/access/apps/$id")" || exit 1
  full="$(printf '%s' "$full" | jq -c '.result')"
  [ "$(printf '%s' "$full" | jq -r '.type // empty')" = self_hosted ] ||
    die "the Access application $(printf '%s' "$full" | jq -r '.name // "?"') is of type $(printf '%s' "$full" | jq -r '.type // "?"'), not self-hosted: nothing was changed"
  APP_AUD="$(printf '%s' "$full" | jq -r '.aud // empty')"
  if [ "$(printf '%s' "$full" | jq -r '(.domain // "") | ascii_downcase')" != "$ACCESS_DOMAIN" ]; then
    changes="$changes, domain $ACCESS_DOMAIN (was $(printf '%s' "$full" | jq -r '.domain // "none"'))"
  fi
  if [ "$(printf '%s' "$full" | jq -r '.session_duration // empty')" != "$ACCESS_SESSION" ]; then
    changes="$changes, session $ACCESS_SESSION (was $(printf '%s' "$full" | jq -r '.session_duration // "none"'))"
  fi
  missing="$(printf '%s' "$full" | jq -c --argjson p "$pols" '$p - [(.policies // [])[].id]')"
  [ "$missing" = '[]' ] || changes="$changes, attach $(printf '%s' "$missing" | jq 'length') policy(ies)"
  if [ -z "$changes" ]; then
    a_found "Access application $(printf '%s' "$full" | jq -r '.name') on $ACCESS_DOMAIN (session $ACCESS_SESSION, its policies attached)"
    return 0
  fi
  a_did updated "Access application $(printf '%s' "$full" | jq -r '.name'): ${changes#, }"
  [ "$OPT_DRY" != 1 ] || return 0
  body="$(printf '%s' "$full" | jq -c --arg d "$ACCESS_DOMAIN" --arg s "$ACCESS_SESSION" --argjson m "$missing" '
    ([(.policies // [])[] | {id, precedence}]) as $old
    | ([$old[].precedence // 0] | max // 0) as $top
    | .domain = $d
    | .destinations = ([{type: "public", uri: $d}] + [(.destinations // [])[] | select((.type // "public") != "public")])
    | (if has("self_hosted_domains") then .self_hosted_domains = [$d] else . end)
    | .session_duration = $s
    | .policies = ($old + ($m | to_entries | map({id: .value, precedence: ($top + .key + 1)})))')"
  access_api PUT "$A/access/apps/$id" "$body" >/dev/null || exit 1
}

# set_vars FILE ENV KEY=VALUE...   Targeted textual edit of env.ENV.vars: a key that is there gets the new value, the
# others are added inside the object (a one-line object stays one line), a missing "vars" is added as the env block's
# first key. Comments and layout stay. Values are plain (checked by the caller: no quote, backslash or line break).
# Exit 3: no ENV block; 7: the edit cannot place them (the caller prints what to add).
set_vars() {
  local file="$1" env="$2" kv tmp
  shift 2
  kv="$(printf '%s;' "$@")"
  tmp="$file.tmp.$$"
  awk -v env="$env" -v kv="$kv" '
    function depthdelta(s,   t, o, c) {
      t = s
      gsub(/"([^"\\]|\\.)*"/, "", t); sub(/\/\/.*$/, "", t)
      o = gsub(/\{/, "", t); c = gsub(/\}/, "", t)
      return o - c
    }
    function lead(s) { match(s, /^[ \t]*/); return substr(s, 1, RLENGTH) }
    function ent(i) { return "\"" K[i] "\": \"" V[i] "\"" }
    { L[NR] = $0 }
    END {
      m = split(kv, P, ";"); nk = 0
      for (i = 1; i <= m; i++) if (P[i] != "") { nk++; p = index(P[i], "="); K[nk] = substr(P[i], 1, p - 1); V[nk] = substr(P[i], p + 1) }
      s = 0; e = 0; d = 0
      for (i = 1; i <= NR; i++) {
        if (!s && L[i] ~ "^[ \t]*\"" env "\"[ \t]*:[ \t]*\\{") { s = i; d = 0 }
        if (s) { d += depthdelta(L[i]); if (d <= 0) { e = i; break } }
      }
      if (!s) exit 3
      if (e <= s) exit 7
      v = 0
      for (i = s + 1; i < e; i++) if (L[i] ~ /"vars"[ \t]*:[ \t]*\{/) { v = i; break }
      ins = 0
      if (!v) {
        # no vars: a one-line "vars" object as the first key of the env block
        ind = lead(L[s + 1]); if (s + 1 == e) ind = lead(L[s]) "  "
        line = ind "\"vars\": { "
        for (i = 1; i <= nk; i++) line = line (i > 1 ? ", " : "") ent(i)
        line = line " }" (s + 1 < e ? "," : "")
        ins = s; NEW[1] = line; nn = 1
      } else {
        match(L[v], /"vars"[ \t]*:[ \t]*\{/); col = RSTART + RLENGTH - 1
        depth = 1; instr = 0; blk = 0; nonempty = 0; done = 0
        for (i = v; i <= e && !done; i++) {
          line = L[i]; n = length(line); j = (i == v) ? col + 1 : 1
          for (; j <= n; j++) {
            c = substr(line, j, 1)
            if (blk) { if (c == "*" && substr(line, j + 1, 1) == "/") { blk = 0; j++ } continue }
            if (instr) { if (c == "\\") j++; else if (c == "\"") instr = 0; continue }
            if (c == "\"") { instr = 1; nonempty = 1; continue }
            if (c == "/" && substr(line, j + 1, 1) == "/") break
            if (c == "/" && substr(line, j + 1, 1) == "*") { blk = 1; j++; continue }
            if (c == "{") { depth++; nonempty = 1; continue }
            if (c == "}") { depth--; if (depth == 0) { cl = i; cc = j; done = 1; break } continue }
            if (c != " " && c != "\t" && c != ",") nonempty = 1
          }
        }
        if (!done) exit 7
        # which keys are there
        for (k = 1; k <= nk; k++) {
          F[k] = 0
          for (i = v; i <= cl; i++) if (index(L[i], "\"" K[k] "\"")) {
            if (L[i] !~ "\"" K[k] "\"[ \t]*:[ \t]*\"[^\"]*\"") exit 7
            F[k] = i; break
          }
        }
        nn = 0
        if (cl == v) {
          add = ""
          for (k = 1; k <= nk; k++) if (!F[k]) add = add (add != "" ? ", " : "") ent(k)
          if (add != "") {
            before = substr(L[v], 1, cc - 1); after = substr(L[v], cc)
            sub(/[ \t]+$/, "", before)
            sep = (nonempty && before !~ /,$/) ? ", " : " "
            L[v] = before sep add " " after
          }
        } else {
          ind = lead(L[v + 1]); if (v + 1 == cl) ind = lead(L[v]) "  "
          miss = 0; for (k = 1; k <= nk; k++) if (!F[k]) miss++
          t = 0
          for (k = 1; k <= nk; k++) if (!F[k]) { t++; NEW[++nn] = ind ent(k) ((t < miss || nonempty) ? "," : "") }
          ins = v
        }
        # replace the values of the keys that are there
        for (k = 1; k <= nk; k++) if (F[k]) {
          i = F[k]; line = L[i]
          match(line, "\"" K[k] "\"[ \t]*:[ \t]*\"[^\"]*\"")
          seg = substr(line, RSTART, RLENGTH); p = index(seg, ":")
          rest = substr(seg, p + 1); sub(/^[ \t]*/, "", rest)
          lsp = substr(seg, p + 1, length(seg) - p - length(rest))
          L[i] = substr(line, 1, RSTART - 1) substr(seg, 1, p) lsp "\"" V[k] "\"" substr(line, RSTART + RLENGTH)
        }
      }
      for (i = 1; i <= NR; i++) {
        print L[i]
        if (i == ins) for (k = 1; k <= nn; k++) print NEW[k]
      }
    }
  ' "$file" >"$tmp" || {
    local rc=$?
    rm -f "$tmp"
    return "$rc"
  }
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod "$(stat -f '%Lp' "$file" 2>/dev/null || echo 644)" "$tmp"
  mv "$tmp" "$file"
}

# access_vars AUD TEAM   ACCESS_AUD and ACCESS_TEAM_DOMAIN in env.ENV.vars of the part's wrangler file, so the Worker can
# check the Cf-Access-Jwt-Assertion it gets (aud and the team's certs). A Pages site has no Worker vars: said, skipped.
access_vars() {
  local aud="$1" team="$2" file="" f cur shown=""
  for f in wrangler.jsonc wrangler.json; do
    if [ -f "$OPT_DIR/$f" ]; then file="$OPT_DIR/$f"; break; fi
  done
  if [ -n "$file" ]; then
    shown="${file#"$(pwd -P)"/}"
  fi
  if [ -z "$file" ] || grep -q pages_build_output_dir "$file"; then
    log_info "no Worker config in $OPT_DIR (a Pages site): ACCESS_AUD and ACCESS_TEAM_DOMAIN are not written anywhere"
    return 0
  fi
  if [ -z "$aud" ]; then
    a_did wrote "ACCESS_AUD (the new application's aud) and ACCESS_TEAM_DOMAIN $team into env.$OPT_ENV.vars of $shown"
    return 0
  fi
  printf '%s' "$aud" | grep -Eq '^[A-Za-z0-9]+$' || die "the application's aud is not a plain tag: $aud"
  cur="$(strip_jsonc "$file" | jq -r --arg e "$OPT_ENV" '(.env[$e].vars // {}) | "\(.ACCESS_AUD // "")|\(.ACCESS_TEAM_DOMAIN // "")"' 2>/dev/null || true)"
  if [ "$cur" = "$aud|$team" ]; then
    a_found "ACCESS_AUD and ACCESS_TEAM_DOMAIN in env.$OPT_ENV.vars of $shown"
    return 0
  fi
  a_did wrote "ACCESS_AUD $aud and ACCESS_TEAM_DOMAIN $team into env.$OPT_ENV.vars of $shown"
  [ "$OPT_DRY" != 1 ] || return 0
  if ! set_vars "$file" "$OPT_ENV" "ACCESS_AUD=$aud" "ACCESS_TEAM_DOMAIN=$team"; then
    log_err "could not place them in $shown (no env.$OPT_ENV block, or a vars object this edit cannot read); add them by hand under env.$OPT_ENV:"
    printf '  "vars": {\n    "ACCESS_AUD": "%s",\n    "ACCESS_TEAM_DOMAIN": "%s"\n  }\n' "$aud" "$team" >&2
    exit 1
  fi
  ACCESS_VARS_CHANGED=1
}

# cf.sh access: find or create the part's Access application, its two policies and its service token for ENV, store a
# new token in the secrets, write ACCESS_AUD and ACCESS_TEAM_DOMAIN into wrangler.jsonc. --dry reads only.
cmd_access() {
  parse_args "$@"
  need_remote_env
  need_project
  need_cmd jq
  need_cmd curl
  access_settings
  access_need_perms
  access_need_schema
  ensure_creds
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "no Cloudflare token stored for $OPT_ENV: make cf-login"
  need_account_id "${CLOUDFLARE_ACCOUNT_ID:-}"
  local A="/accounts/$CLOUDFLARE_ACCOUNT_ID" resp team include text allow_id="" pols
  hdr "Access for $OPT_PART in $OPT_ENV: $ACCESS_DOMAIN"
  [ "$OPT_DRY" != 1 ] || log_info "DRY=1: reading only, nothing is changed"

  resp="$(access_api GET "$A/access/organizations")" || exit 1
  team="$(printf '%s' "$resp" | jq -r '.result.auth_domain // empty' | sed -e 's|^https*://||' -e 's|/*$||' | tr '[:upper:]' '[:lower:]')"
  [ -n "$team" ] || die "this account has no Zero Trust organization, so Access has no team to sign people in: set Zero Trust up once in the dashboard (Zero Trust: a team name and a plan), then run this again. Nothing was made."
  valid_host "$team" || die "the Zero Trust organization's team domain is not a host name: $team"
  a_found "team domain $team"

  access_service_token "$A"

  if [ -n "$ACCESS_DOMAINS$ACCESS_EMAILS" ]; then
    include="$(jq -nc --arg d "$ACCESS_DOMAINS" --arg e "$ACCESS_EMAILS" '
      [($d | split("\n")[] | select(. != "") | {email_domain: {domain: .}}),
       ($e | split("\n")[] | select(. != "") | {email: {email: .}})]')"
    text="$(printf '%s\n%s' "$(printf '%s' "$ACCESS_DOMAINS" | sed 's/^/@/')" "$ACCESS_EMAILS" | awk 'NF' | paste -sd ' ' - | sed 's/ /, /g')"
    access_policy "$A" "$ACCESS_NAME-allow" allow "$include" "$text"
    allow_id="$POL_ID"
  else
    log_info "no ${OPT_PART}_ACCESS_EMAIL_DOMAINS or ${OPT_PART}_ACCESS_EMAILS: only the service token passes Access (no Allow policy)"
  fi
  include="$(jq -nc --arg t "$TOK_ID" '[{service_token: {token_id: $t}}]')"
  access_policy "$A" "$ACCESS_NAME-service" non_identity "$include" "the service token $TOK_NAME"
  pols="$(jq -nc --arg a "$allow_id" --arg s "$POL_ID" '[$a, $s] | map(select(. != ""))')"

  access_app "$A" "$pols"
  access_vars "$APP_AUD" "$team"

  if [ "$OPT_DRY" = 1 ]; then
    log_info "DRY=1: nothing was changed"
    return 0
  fi
  [ "$ACCESS_STORED" = 0 ] || log_info "the new service token is in the $OPT_ENV secrets: the smoke and make $OPT_PART-access-check send it"
  [ "$ACCESS_VARS_CHANGED" = 0 ] || log_info "deploy so the Worker gets ACCESS_AUD and ACCESS_TEAM_DOMAIN: make $OPT_PART-deploy ENV=$OPT_ENV, then commit the wrangler file"
  log_ok "Access for $OPT_PART in $OPT_ENV is set up; make $OPT_PART-access-check ENV=$OPT_ENV checks it"
}

# cf.sh access-check: read only. A GET of the health path without the service token must be stopped by Access (a
# redirect to <team>.cloudflareaccess.com, or 401 / 403), and the same GET with it (the smoke's headers) must get through.
cmd_access_check() {
  parse_args "$@"
  need_remote_env
  need_project
  need_cmd curl
  local base url health upath res code loc lhost bad=0 access
  OPT_EMAIL_DOMAINS="" OPT_EMAILS=""
  access_settings
  base="${OPT_URL_BASE:-https://$ACCESS_HOST$ACCESS_PATH}"
  health="${OPT_HEALTH:-/}"
  case "$health" in /*) ;; *) health="/$health" ;; esac
  url="${base%/}$health"
  cfg_safe "$url" || die "refused: the URL holds a quote, backslash or line break"
  if [ -n "$ACCESS_PATH" ]; then
    upath="/${url#*://*/}"
    case "$upath" in "${ACCESS_PATH%\*}"*) ;; *) log_warn "$url is outside the protected path $ACCESS_PATH: Access may not see it" ;; esac
  fi
  ensure_creds
  hdr "Access check for $OPT_PART in $OPT_ENV: $url"
  res="$(printf 'url = "%s"\n' "$url" | curl -sS --max-time 20 -o /dev/null -w '%{http_code} %{redirect_url}' -K - 2>/dev/null)" || true
  code="${res%% *}"
  loc="${res#* }"
  [ "$loc" != "$res" ] || loc=""
  lhost="${loc#*://}"
  lhost="${lhost%%/*}"
  case "$code" in
    401 | 403) printf '%s without the service token: Access refuses it (%s)\n' "$(paint 1 green ok)" "$code" ;;
    30?)
      case "$lhost" in
        *.cloudflareaccess.com) printf '%s without the service token: Access sends it to sign in at %s (%s)\n' "$(paint 1 green ok)" "$lhost" "$code" ;;
        *) printf '%s without the service token: %s to %s, not to a *.cloudflareaccess.com sign-in\n' "$(paint 1 red fail)" "$code" "${loc:-nowhere}"; bad=1 ;;
      esac ;;
    *) printf '%s without the service token: %s (expected a redirect to *.cloudflareaccess.com, or 401 or 403): Access does not guard it\n' "$(paint 1 red fail)" "${code:-no answer}"; bad=1 ;;
  esac
  if [ -z "${CF_ACCESS_CLIENT_ID:-}" ] || [ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
    printf '%s with the service token: CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET are not in the %s secrets (make %s-access ENV=%s)\n' "$(paint 1 red fail)" "$OPT_ENV" "$OPT_PART" "$OPT_ENV"
    return 1
  fi
  access="$(smoke_access)" || exit 1
  res="$({ printf 'url = "%s"\n' "$url"; printf '%s' "$access"; } | curl -sS --max-time 20 -o /dev/null -w '%{http_code} %{redirect_url}' -K - 2>/dev/null)" || true
  access=""
  code="${res%% *}"
  loc="${res#* }"
  [ "$loc" != "$res" ] || loc=""
  case "$code" in
    2??) printf '%s with the service token: it gets through (%s)\n' "$(paint 1 green ok)" "$code" ;;
    30?)
      case "$loc" in
        *.cloudflareaccess.com/*) printf '%s with the service token: Access still sends it to sign in: the token is not in the application'"'"'s Service Auth policy\n' "$(paint 1 red fail)"; bad=1 ;;
        *) printf '%s with the service token: it gets through (%s to %s)\n' "$(paint 1 green ok)" "$code" "$loc" ;;
      esac ;;
    401 | 403) printf '%s with the service token: refused (%s): the token is not in the application'"'"'s Service Auth policy, or the secrets hold an old secret (make %s-access ENV=%s ROTATE=1)\n' "$(paint 1 red fail)" "$code" "$OPT_PART" "$OPT_ENV"; bad=1 ;;
    *) printf '%s with the service token: %s\n' "$(paint 1 red fail)" "${code:-no answer}"; bad=1 ;;
  esac
  return "$bad"
}

# cf.sh access-doctor: for a part with Access settings, whether the token is made for Access (CF_TOKEN_PERMS) and
# secrets.schema has the service token's rows. Nothing for a part without them. Reads files only.
cmd_access_doctor() {
  parse_args "$@"
  [ -n "$OPT_HOST$OPT_PATH$OPT_EMAIL_DOMAINS$OPT_EMAILS" ] || return 0
  local bad=0 n miss=""
  case " $(project_setting CF_TOKEN_PERMS) " in
    *" access "*) printf '%s %s: CF_TOKEN_PERMS names access\n' "$(paint 1 green ok)" "$OPT_PART" ;;
    *) printf '%s %s: has Access settings, but CF_TOKEN_PERMS in make/project.mk does not name access: add CF_TOKEN_PERMS := access, then make cf-login\n' "$(paint 1 red fail)" "$OPT_PART"; bad=1 ;;
  esac
  for n in CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET; do
    [ -f "$SCHEMA" ] && awk -v n="$n" '$1 == n { f = 1 } END { exit !f }' "$SCHEMA" || miss="$miss $n"
  done
  if [ -z "$miss" ]; then
    printf '%s %s: secrets.schema declares CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET\n' "$(paint 1 green ok)" "$OPT_PART"
  else
    printf '%s %s: has Access settings, but secrets.schema lacks%s (scaffold.sh --force adds the rows)\n' "$(paint 1 red fail)" "$OPT_PART" "$miss"
    bad=1
  fi
  return "$bad"
}

# envs --dir D   the environment names under env in D/wrangler.jsonc, one per line (scaffold reads it to find
# production-only parts). Reads the file only; no credentials.
cmd_envs() {
  parse_args "$@"
  need_cmd jq
  strip_jsonc "$(config_file)" | jq -r '(.env // {}) | keys[]'
}

usage() { sed -n '4,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local sub="${1:-}"
  [ $# -eq 0 ] || shift
  CUR_SUB="$sub"
  ORIG_ARGS=("$@")
  case "$sub" in
    login) cmd_login "$@" ;;
    logout) cmd_logout "$@" ;;
    whoami) cmd_whoami "$@" ;;
    token-check) cmd_token_check "$@" ;;
    token-url) cmd_token_url "$@" ;;
    provision) cmd_provision "$@" ;;
    provision-ota) cmd_provision_ota "$@" ;;
    status-ota) cmd_status_ota "$@" ;;
    status) cmd_status "$@" ;;
    migrate) cmd_migrate "$@" ;;
    seed) cmd_seed "$@" ;;
    secrets) cmd_secrets "$@" ;;
    backup) cmd_backup "$@" ;;
    wipe) cmd_wipe "$@" ;;
    destroy) cmd_destroy "$@" ;;
    envs) cmd_envs "$@" ;;
    access) cmd_access "$@" ;;
    access-check) cmd_access_check "$@" ;;
    access-doctor) cmd_access_doctor "$@" ;;
    help | -h | --help | '') usage ;;
    *) die "unknown subcommand: $sub (try: cf.sh help)" ;;
  esac
}

main "$@"
