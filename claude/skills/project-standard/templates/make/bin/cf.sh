#!/usr/bin/env bash
# project-standard v1.6 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
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
      printf '%s\n' "$out" | grep -E "^name:[[:space:]]+$name\$" | head -n1 | sed -E 's/^name:[[:space:]]+//' ;;
    queue)
      # the name as a whole table cell: `grep -w` would also take "jobs" from "jobs-dlq" ("-" ends a word)
      out="$(wr_global queues list)" || return 1
      printf '%s\n' "$out" | awk -v n="$name" '{ for (i = 1; i <= NF; i++) if ($i == n) { print n; exit } }' ;;
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
          found="$(printf '%s' "$out" | grep -o -E '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1)"
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
          found="$(printf '%s' "$out" | grep -o -E '[0-9a-f]{32}' | head -n1)"
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
  wr_global d1 list --json 2>/dev/null | jq -r --arg p "$PROJECT-$OPT_ENV" '.[] | select(.name | startswith($p)) | .name' 2>/dev/null |
    while IFS= read -r name; do
      if ! declared "$file" "$OPT_ENV" | cut -d'|' -f3 | grep -qx -- "$name"; then
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
  printf '%s\n' "$out" | grep -o -E 'https://[A-Za-z0-9.-]+\.r2\.dev[^[:space:]]*' | head -n1 || true
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
    if printf '%s\n' "$list" | grep -Eq "^name:[[:space:]]+$name\$"; then
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
    if ! printf '%s\n' "$list" | grep -Eq "^name:[[:space:]]+$name\$"; then
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
  first="$(d1_names "$file" "$OPT_ENV" | head -n1 | cut -d'|' -f2)"
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
  if declared "$file" "$OPT_ENV" | cut -d'|' -f1 | grep -qx r2; then
    if [ "$OPT_R2_UNBACKED" != 1 ]; then
      die "refused: R2 objects cannot be backed up (wrangler cannot list or download them), so $OPT_ENV would lose them. Copy them yourself first (for example with rclone), then repeat with R2_UNBACKED=1 on the command line"
    fi
    log_warn "R2 objects are NOT in the backup (R2_UNBACKED=1)"
  fi
  if declared "$file" "$OPT_ENV" | cut -d'|' -f1 | grep -qx queue; then
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

# envs --dir D   the environment names under env in D/wrangler.jsonc, one per line (scaffold reads it to find
# production-only parts). Reads the file only; no credentials.
cmd_envs() {
  parse_args "$@"
  need_cmd jq
  strip_jsonc "$(config_file)" | jq -r '(.env // {}) | keys[]'
}

usage() { sed -n '4,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
    help | -h | --help | '') usage ;;
    *) die "unknown subcommand: $sub (try: cf.sh help)" ;;
  esac
}

main "$@"
