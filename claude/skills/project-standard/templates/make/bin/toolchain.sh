#!/usr/bin/env bash
# project-standard v1.8 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# What this project uses from the shared machine, what the standard installed there, and the commands that undo it:
# `make teardown` (this project) and `make prune` (the whole machine). make runs it from the project root; STD_PROJECT_DIR
# names the root when a recipe runs it from inside a part. Bash 3.2, no here-documents. Nothing in here touches secrets.
#
# This script is internal: run it through make. Called directly, the only guard on a removal is CONFIRM=teardown or
# CONFIRM=prune in its environment (`--remove` refuses without it); nothing else checks who is calling.
#
# Called by make setup and the kinds' setup (they record, they never remove):
#   toolchain.sh record-begin              a full setup starts: the project's record keeps everything it had and gains what
#                                          setup intends to use; the new record is built beside it (<record>.next)
#   toolchain.sh record-commit             setup finished: the new record replaces the old one. A failed setup never gets here,
#                                          so its record only ever grows and keeps protecting what it names
#   toolchain.sh mise-install              mise install; records the project's current tools before and after it, ledgers the
#                                          versions it added that this project's mise.toml asks for
#   toolchain.sh sdk-begin DIR...          before an install into DIR (a folder directly under STD_TOOLCHAINS): record DIR, and
#                                          ledger it when it is not there yet
#   toolchain.sh sdk-use DIR...            record the folders that exist
#   toolchain.sh rustup-add TARGET...      rustup target add on the active toolchain; ledger the targets that were missing,
#                                          record all of them, with the toolchain
# Called by make teardown and make prune (they list; with --remove they remove, and need CONFIRM=teardown or CONFIRM=prune):
#   toolchain.sh teardown [--remove] [--dirs "d1 d2"] [--brewfile F] [--clean-cmd CMD]
#   toolchain.sh prune [--remove]
#
# State, in ${XDG_STATE_HOME:-~/.local/state}/project-standard (one machine-wide place, kept out of every project):
#   uses/<PROJECT>-<hash>    this project's record, one per project. <hash> is the first 12 hex digits of the SHA-256 of the
#                            project root's physical path, so two projects with one name, or a moved copy, never share a record.
#                            Lines:  path <absolute project root>   project <name>   mise <tool>@<version>
#                            sdk <absolute physical folder>   rustup <toolchain> <target>.
#   installed                the ledger: every item (same `mise|sdk|rustup ...` lines) the standard itself installed. Only
#                            ledger items are ever removed, so what you installed yourself is safe from teardown and prune.
# An item is removed only when it is in the ledger, is a valid line, and no other record names it. Lines are read with CR and
# surrounding blanks stripped. A ledger line that is not valid is never removed. A record line that is not valid protects
# whatever it plausibly names (any word of it found in the item). Both are reported.
# A record is stale when its project folder is gone but its parent folder is there: it counts for nothing and prune can
# remove it. When the parent is missing too (an unmounted drive, a moved parent) it is unreachable: kept, and its items stay
# protected.

set -euo pipefail

STD_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$STD_BIN_DIR/lib.sh"

have() { command -v "$1" >/dev/null 2>&1; }

# --- where things live -------------------------------------------------------------------------

tc_phys() { (cd "$1" 2>/dev/null && pwd -P); }
tc_root() { tc_phys "${STD_PROJECT_DIR:-$PWD}"; }
tc_state() { printf '%s/project-standard' "${XDG_STATE_HOME:-$HOME/.local/state}"; }
tc_toolchains() { printf '%s' "${STD_TOOLCHAINS:-$HOME/.toolchains}"; }
tc_ledger() { printf '%s/installed' "$(tc_state)"; }

# tc_hash TEXT   12 hex digits (cksum's decimal number only when neither shasum nor sha256sum exists).
tc_hash() {
  printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null || cksum; } | awk '{ print substr($1, 1, 12) }'
}

# tc_id   <PROJECT>-<hash of the project root>
tc_id() {
  local root name
  root="$(tc_root)"
  name="$(printf '%s' "${PROJECT:-$(basename "$root")}" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s-%s' "$name" "$(tc_hash "$root")"
}

tc_record() { printf '%s/uses/%s' "$(tc_state)" "$(tc_id)"; }
tc_next() { printf '%s.next' "$(tc_record)"; }

# tc_write FILE   replace FILE with stdin, all at once.
tc_write() {
  local tmp="$1.tmp.$$"
  cat >"$tmp" && mv "$tmp" "$1"
}

# tc_norm   stdin to stdout with CR and surrounding blanks removed.
tc_norm() { tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

tc_tilde() {
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# tc_human KB   1.1 G, 240.0 M, 12 K
tc_human() {
  local kb="$1" t
  if [ "$kb" -lt 1024 ]; then
    printf '%s K' "$kb"
  elif [ "$kb" -lt 1048576 ]; then
    t=$((kb * 10 / 1024))
    printf '%s.%s M' "$((t / 10))" "$((t % 10))"
  else
    t=$((kb * 10 / 1048576))
    printf '%s.%s G' "$((t / 10))" "$((t % 10))"
  fi
}

# tc_kb PATH...   the size in KB of every path together (0 for what is not there).
tc_kb() {
  local p n total=0
  for p in "$@"; do
    [ -e "$p" ] || continue
    n="$(du -sk "$p" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    case "$n" in '' | *[!0-9]*) n=0 ;; esac
    total=$((total + n))
  done
  printf '%s' "$total"
}

# --- what a valid line is ------------------------------------------------------------------------

# tc_root_ok DIR   a folder the standard may keep SDKs in: absolute, and neither / nor $HOME nor a parent of $HOME.
tc_root_ok() {
  local r="${1%/}" home
  case "$r" in /?*) ;; *) return 1 ;; esac
  home="$(tc_phys "$HOME")" || return 1
  [ "$r" != "$home" ] || return 1
  case "$home/" in "$r"/*) return 1 ;; esac
  return 0
}

# tc_sdk_path_ok PATH   an absolute path of plain characters whose folder is a root that tc_root_ok accepts.
tc_sdk_path_ok() {
  local p="$1" b
  printf '%s' "$p" | grep -Eq '^/[A-Za-z0-9._/+@-]+$' || return 1
  case "$p" in *//* | */ | */./* | */../* | */. | */..) return 1 ;; esac
  b="${p##*/}"
  valid_name "$b" || return 1
  tc_root_ok "${p%/*}"
}

# tc_line_ok "TYPE REST"   the whole line is one the standard writes.
tc_line_ok() {
  local type="${1%% *}" rest="${1#* }"
  [ "$type" != "$1" ] || return 1
  case "$type" in
    mise) printf '%s' "$rest" | grep -Eq '^[A-Za-z0-9._:/+-]+@[A-Za-z0-9._+-]+$' ;;
    sdk) tc_sdk_path_ok "$rest" ;;
    rustup)
      printf '%s' "$rest" | grep -Eq '^[A-Za-z0-9._-]+ [A-Za-z0-9._-]+-[A-Za-z0-9._-]+$'
      ;;
    *) return 1 ;;
  esac
}

# --- the record and the ledger -----------------------------------------------------------------

# tc_has_line FILE LINE   the whole line is in FILE.
tc_has_line() { [ -f "$1" ] && grep -Fxq -- "$2" "$1"; }

tc_ledger_add() {
  local f
  f="$(tc_ledger)"
  mkdir -p "$(tc_state)"
  {
    if [ -f "$f" ]; then tc_norm <"$f"; fi
    printf '%s %s\n' "$1" "$2"
  } | sort -u | tc_write "$f"
}

tc_ledger_del() {
  local f
  f="$(tc_ledger)"
  [ -f "$f" ] || return 0
  # shellcheck disable=SC2094
  tc_norm <"$f" | grep -Fxv -- "$1 $2" | tc_write "$f" || true
}

tc_record_header() {
  printf 'path %s\n' "$(tc_root)"
  printf 'project %s\n' "${PROJECT:-$(basename "$(tc_root)")}"
}

# tc_record_add TYPE REST   add to the record, and to the record being built when a setup is running.
tc_record_add() {
  local f n line="$1 $2"
  f="$(tc_record)"
  n="$(tc_next)"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || tc_record_header | tc_write "$f"
  tc_has_line "$f" "$line" || { cat "$f"; printf '%s\n' "$line"; } | tc_write "$f"
  if [ -f "$n" ]; then
    tc_has_line "$n" "$line" || { cat "$n"; printf '%s\n' "$line"; } | tc_write "$n"
  fi
  return 0
}

cmd_record_begin() {
  local f n keep=''
  f="$(tc_record)"
  n="$(tc_next)"
  mkdir -p "$(dirname "$f")"
  if [ ! -f "$f" ]; then tc_record_header | tc_write "$f"; fi
  # rustup lines carry over: targets are added at release time, not by setup
  keep="$(tc_norm <"$f" | grep -E '^rustup ' || true)"
  {
    tc_record_header
    if [ -n "$keep" ]; then printf '%s\n' "$keep"; fi
  } | tc_write "$n"
}

cmd_record_commit() {
  local n
  n="$(tc_next)"
  [ -f "$n" ] || return 0
  mv "$n" "$(tc_record)"
}

# --- recording (called by setup) ----------------------------------------------------------------

# tc_mise_list MODE   tool@version lines, sorted. MODE: --installed (all), --project (current in a config under this
# project), --global (current in the global config). Fails when mise or jq does.
tc_mise_list() {
  local r1 r2 flag="$1" filter
  r1="$(tc_root)/"
  r2="${STD_PROJECT_DIR:-$PWD}/"
  # shellcheck disable=SC2016
  filter='to_entries[] | .key as $t | .value[] | select(.installed != false)'
  case "$flag" in
    --installed) mise ls --installed --json 2>/dev/null ;;
    --global) (cd / && mise ls --global --json 2>/dev/null) ;;  # from /: inside a project mise lists no global tools
    --project)
      mise ls --current --json 2>/dev/null |
        jq --arg r1 "$r1" --arg r2 "$r2" 'with_entries(.value |= map(select((.source.path // "") as $p | ($p | startswith($r1)) or ($p | startswith($r2)))))'
      ;;
    *) return 1 ;;
  esac | jq -r "$filter"' | "\($t)@\(.version)"' | sort -u
}

cmd_mise_install() {
  local tmp rc=0 line ledger_ok=1
  have mise || {
    log_warn "mise not found; skipped mise.toml"
    return 0
  }
  if ! have jq; then
    log_warn "jq not found: the tools mise installs are not recorded, so make teardown will not know them (brew install jq)"
    mise install
    return $?
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/std-toolchain.XXXXXX")"
  tc_mise_list --installed >"$tmp/before" || ledger_ok=0
  # what the project already uses and has installed is recorded before anything is installed
  if tc_mise_list --project >"$tmp/intent"; then
    while IFS= read -r line; do
      [ -n "$line" ] && tc_record_add mise "$line"
    done <"$tmp/intent"
  fi
  mise install || rc=$?
  if [ "$rc" -eq 0 ]; then
    if tc_mise_list --project >"$tmp/current"; then
      while IFS= read -r line; do
        [ -n "$line" ] && tc_record_add mise "$line"
      done <"$tmp/current"
      # the ledger: new since before, and asked for by this project's own mise.toml (a global tool, or one that another
      # install landed meanwhile, is not the standard's)
      if [ "$ledger_ok" -eq 1 ] && tc_mise_list --installed >"$tmp/after"; then
        comm -13 "$tmp/before" "$tmp/after" >"$tmp/new"
        comm -12 "$tmp/new" "$tmp/current" >"$tmp/mine"
        while IFS= read -r line; do
          [ -n "$line" ] && tc_ledger_add mise "$line"
        done <"$tmp/mine"
      else
        log_warn "could not list the installed mise versions: none is recorded as installed by the standard"
      fi
    else
      log_warn "could not list this project's mise tools: none is recorded"
    fi
  fi
  rm -rf "$tmp"
  return "$rc"
}

# tc_sdk_target DIR   the physical path DIR will have, when it sits directly in STD_TOOLCHAINS and that folder is a safe root.
tc_sdk_target() {
  local d="${1%/}" root troot
  root="$(tc_phys "${d%/*}")" || return 1
  troot="$(tc_phys "$(tc_toolchains)")" || return 1
  [ "$root" = "$troot" ] || return 1
  tc_root_ok "$root" || return 1
  valid_name "${d##*/}" || return 1
  printf '%s/%s' "$root" "${d##*/}"
}

cmd_sdk_begin() {
  local d p
  for d in "$@"; do
    p="$(tc_sdk_target "$d")" || {
      log_warn "not recording $d: it is not a plain folder directly in a safe STD_TOOLCHAINS"
      continue
    }
    # recorded first, so nobody prunes it between the folder appearing and the record
    tc_record_add sdk "$p"
    [ -e "$p" ] || tc_ledger_add sdk "$p"
  done
  return 0
}

cmd_sdk_use() {
  local d p
  for d in "$@"; do
    p="$(tc_sdk_target "$d")" || continue
    [ -e "$p" ] && tc_record_add sdk "$p"
  done
  return 0
}

cmd_rustup_add() {
  local t tc list listed=1
  have rustup || return 0
  tc="$(rustup show active-toolchain 2>/dev/null | awk 'NR == 1 { print $1 }')"
  if ! printf '%s' "$tc" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    # the toolchain is not known: add as before, claim nothing
    for t in "$@"; do rustup target add "$t" >/dev/null 2>&1 || true; done
    return 0
  fi
  list="$(rustup target list --installed --toolchain "$tc" 2>/dev/null)" || listed=0
  for t in "$@"; do
    tc_line_ok "rustup $tc $t" || continue
    if [ "$listed" -eq 1 ] && printf '%s\n' "$list" | grep -Fxq -- "$t"; then
      tc_record_add rustup "$tc $t"
    elif rustup target add --toolchain "$tc" "$t" >/dev/null 2>&1; then
      tc_record_add rustup "$tc $t"
      # only a target that was seen to be missing is the standard's
      [ "$listed" -eq 1 ] && tc_ledger_add rustup "$tc $t"
    fi
  done
  return 0
}

# --- other records ------------------------------------------------------------------------------

# tc_record_path FILE   the project folder a record names.
tc_record_path() { tc_norm <"$1" | sed -n 's/^path //p' | head -n 1; }

# tc_path_state PATH   live (a folder), stale (gone, its parent is there) or unreachable (the parent is missing too, or it is
# on a drive that is not mounted).
tc_path_state() {
  local p="$1" rest v
  case "$p" in /?*) ;; *)
    printf unreachable
    return 0
    ;;
  esac
  if [ -d "$p" ]; then
    printf live
    return 0
  fi
  case "$p" in
    /Volumes/*)
      rest="${p#/Volumes/}"
      v="${rest%%/*}"
      if [ ! -d "/Volumes/$v" ]; then
        printf unreachable
        return 0
      fi
      ;;
  esac
  if [ -d "${p%/*}" ]; then printf stale; else printf unreachable; fi
}

# tc_collect OUT SKIP_ID STALE UNREACH BAD
#   OUT     `<type> <item><TAB><project path>` for every valid line of every record that counts (live or unreachable) except
#           the one with the id SKIP_ID
#   STALE   the files of the stale records;   UNREACH   the files of the unreachable ones
#   BAD     the lines of those records that are not valid: they protect whatever they plausibly name
tc_collect() {
  local out="$1" skip="$2" stale="$3" unreach="$4" bad="$5" f id p st line type
  : >"$out"
  : >"$stale"
  : >"$unreach"
  : >"$bad"
  for f in "$(tc_state)"/uses/*; do
    [ -f "$f" ] || continue
    case "$f" in *.next) continue ;; esac
    id="$(basename "$f")"
    p="$(tc_record_path "$f")"
    st="$(tc_path_state "$p")"
    if [ "$st" = stale ]; then
      printf '%s\n' "$f" >>"$stale"
      continue
    fi
    [ "$st" = unreachable ] && printf '%s\n' "$f" >>"$unreach"
    [ "$id" = "$skip" ] && continue
    tc_norm <"$f" | while IFS= read -r line; do
      type="${line%% *}"
      case "$type" in
        path | project | '') continue ;;
      esac
      if tc_line_ok "$line"; then
        printf '%s\t%s\n' "$line" "$p" >>"$out"
      else
        printf '%s\n' "$line" >>"$bad"
      fi
    done
  done
}

# tc_user_of REFS LINE   the first project that records LINE.
tc_user_of() { awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }

# tc_bad_hit BAD REST   an invalid record line has a word of REST in it.
tc_bad_hit() {
  local w
  [ -s "$1" ] || return 1
  set -f
  for w in $2; do
    if grep -Fq -- "$w" "$1"; then
      set +f
      return 0
    fi
  done
  set +f
  return 1
}

# --- classifying what could go ------------------------------------------------------------------

C_STATE='' C_PATH='' C_WHY=''
TC_GLOBAL_STATE=''

# tc_global_load   read the global mise tools once; fails when they cannot be read.
tc_global_load() {
  if [ -z "$TC_GLOBAL_STATE" ]; then
    if have jq && tc_mise_list --global >"$TC_TMP/global"; then TC_GLOBAL_STATE=ok; else TC_GLOBAL_STATE=failed; fi
  fi
  [ "$TC_GLOBAL_STATE" = ok ]
}

# tc_classify TYPE REST   sets C_STATE: remove (C_PATH is what takes the space), gone (not on the machine any more) or
# keep (C_WHY says why it stays).
tc_classify() {
  local type="$1" rest="$2" host p tc target
  C_STATE=gone C_PATH='' C_WHY=''
  tc_line_ok "$type $rest" || {
    C_STATE=keep C_WHY="not a valid line"
    return 0
  }
  case "$type" in
    mise)
      if ! have mise; then
        C_STATE=keep C_WHY="mise not found"
        return 0
      fi
      if ! tc_global_load; then
        C_STATE=keep C_WHY="cannot read the global mise config"
        return 0
      fi
      if grep -Fxq -- "$rest" "$TC_TMP/global"; then
        C_STATE=keep C_WHY="in use by the global mise config"
        return 0
      fi
      p="$(mise where "$rest" 2>/dev/null)" || p=''
      if [ -n "$p" ] && [ -e "$p" ]; then C_STATE=remove C_PATH="$p"; fi
      ;;
    sdk)
      if [ ! -e "$rest" ] && [ ! -L "$rest" ]; then return 0; fi
      if [ -L "$rest" ] || [ ! -d "$rest" ] || [ "$(tc_phys "$rest")" != "$rest" ]; then
        C_STATE=keep C_WHY="not a plain folder"
        return 0
      fi
      C_STATE=remove C_PATH="$rest"
      ;;
    rustup)
      tc="${rest%% *}"
      target="${rest#* }"
      if ! have rustup; then
        C_STATE=keep C_WHY="rustup not found"
        return 0
      fi
      host="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
      if [ -z "$host" ]; then
        C_STATE=keep C_WHY="cannot tell the host target"
      elif [ "$target" = "$host" ]; then
        C_STATE=keep C_WHY="host target"
      elif rustup target list --installed --toolchain "$tc" 2>/dev/null | grep -Fxq -- "$target"; then
        C_STATE=remove
        p="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$tc/lib/rustlib/$target"
        if [ -d "$p" ]; then C_PATH="$p"; fi
      fi
      ;;
    *) C_STATE=keep C_WHY="unknown kind of item" ;;
  esac
}

# tc_remove_item TYPE REST   remove one shared item; non-zero when it is still there or was refused.
tc_remove_item() {
  tc_line_ok "$1 $2" || return 1
  case "$1" in
    mise) mise uninstall "$2" >/dev/null ;;
    sdk)
      [ -d "$2" ] && [ ! -L "$2" ] && [ "$(tc_phys "$2")" = "$2" ] || return 1
      rm -rf -- "$2"
      ;;
    rustup) rustup target remove --toolchain "${2%% *}" "${2#* }" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# --- plan and removal, shared by teardown and prune ---------------------------------------------

TC_TMP=''
TC_REMOVE='' TC_KEEP='' TC_GONE='' TC_INVALID=''

tc_tmp_init() {
  TC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/std-toolchain.XXXXXX")"
  trap 'rm -rf "$TC_TMP"' EXIT
  TC_REMOVE="$TC_TMP/remove"
  TC_KEEP="$TC_TMP/keep"
  TC_GONE="$TC_TMP/gone"
  TC_INVALID="$TC_TMP/invalid"
  : >"$TC_REMOVE"
  : >"$TC_KEEP"
  : >"$TC_GONE"
  : >"$TC_INVALID"
  # the ledger as read: CR and blanks stripped
  if [ -f "$(tc_ledger)" ]; then tc_norm <"$(tc_ledger)" >"$TC_TMP/ledger"; else : >"$TC_TMP/ledger"; fi
}

# tc_sort_item TYPE REST   file the item under remove / keep / gone (TAB separated lines: type item path kb / type item why;
# no field is empty: read would fold the tabs).
tc_sort_item() {
  tc_classify "$1" "$2"
  case "$C_STATE" in
    remove) printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${C_PATH:--}" "$(tc_kb "$C_PATH")" >>"$TC_REMOVE" ;;
    gone) printf '%s\t%s\t%s\n' "$1" "$2" "-" >>"$TC_GONE" ;;
    *) printf '%s\t%s\t%s\n' "$1" "$2" "${C_WHY:--}" >>"$TC_KEEP" ;;
  esac
}

# tc_print_removals   the removable items with their sizes; sets TOTAL_KB to their sum.
tc_print_removals() {
  local type item kb
  TOTAL_KB=0
  while IFS="$(printf '\t')" read -r type item _ kb; do
    [ -n "$type" ] || continue
    printf '  %8s  %-6s %s\n' "$(tc_human "$kb")" "$type" "$(tc_tilde "$item")"
    TOTAL_KB=$((TOTAL_KB + kb))
  done <"$TC_REMOVE"
}

tc_print_kept() {
  local type item why
  while IFS="$(printf '\t')" read -r type item why; do
    [ -n "$type" ] || continue
    printf '  %8s  %-6s %-24s %s\n' '' "$type" "$(tc_tilde "$item")" "$(tc_tilde "$why")"
  done <"$TC_KEEP"
  while IFS="$(printf '\t')" read -r type item why; do
    [ -n "$type" ] || continue
    printf '  %8s  %-6s %-24s %s\n' '' "$type" "$(tc_tilde "$item")" "already gone, only its ledger entry is dropped"
  done <"$TC_GONE"
}

# tc_print_invalid   the lines that were ignored because they are not valid.
tc_print_invalid() {
  [ -s "$TC_INVALID" ] || return 0
  printf '\nignored lines (not valid; never removed, and they protect what they name)\n'
  while IFS= read -r line; do
    printf '  %s\n' "$line"
  done <"$TC_INVALID"
}

# tc_remove_all   remove every item in TC_REMOVE, update the ledger, print one line each. Sets FREED_KB; returns 1 when one stayed.
tc_remove_all() {
  local type item kb rc=0
  FREED_KB=0
  while IFS="$(printf '\t')" read -r type item _ kb; do
    [ -n "$type" ] || continue
    if tc_remove_item "$type" "$item"; then
      tc_ledger_del "$type" "$item"
      FREED_KB=$((FREED_KB + kb))
      printf 'removed  %-6s %s\n' "$type" "$(tc_tilde "$item")"
    else
      log_warn "could not remove $type $item; it stays in the ledger"
      rc=1
    fi
  done <"$TC_REMOVE"
  while IFS="$(printf '\t')" read -r type item _; do
    [ -n "$type" ] || continue
    tc_ledger_del "$type" "$item"
  done <"$TC_GONE"
  return "$rc"
}

# tc_note_removals   one line under a list of removable items.
tc_note_removals() {
  [ -s "$TC_REMOVE" ] || return 0
  printf '  A project that is not on the standard and uses one of these would lose it; check the list before removing.\n'
}

# --- make teardown -------------------------------------------------------------------------------

# tc_brew_names FILE   the formulae and casks of a Brewfile on one line.
tc_brew_names() {
  [ -f "$1" ] || return 0
  awk '$1 == "brew" || $1 == "cask" { n = $2; gsub(/[",]/, "", n); printf "%s%s", (c++ ? " " : ""), n } END { if (c) printf "\n" }' "$1"
}

# tc_plan_teardown   what this project's record asks for, sorted into remove, keep and gone.
tc_plan_teardown() {
  local own line type item who
  own="$(tc_record)"
  tc_collect "$TC_TMP/refs" "$(tc_id)" "$TC_TMP/stale" "$TC_TMP/unreach" "$TC_TMP/bad"
  [ -f "$own" ] || return 0
  tc_norm <"$own" | grep -E '^(mise|sdk|rustup)( |$)' >"$TC_TMP/own.items" || true
  while IFS= read -r line; do
    type="${line%% *}"
    item="${line#* }"
    if ! tc_line_ok "$line"; then
      printf '%s\n' "$line" >>"$TC_INVALID"
    elif ! tc_has_line "$TC_TMP/ledger" "$line"; then
      printf '%s\t%s\t%s\n' "$type" "$item" "not installed by project-standard" >>"$TC_KEEP"
    else
      who="$(tc_user_of "$TC_TMP/refs" "$line")"
      if [ -n "$who" ]; then
        printf '%s\t%s\t%s\n' "$type" "$item" "used by $who" >>"$TC_KEEP"
      elif tc_bad_hit "$TC_TMP/bad" "$item"; then
        printf '%s\t%s\t%s\n' "$type" "$item" "named by an unreadable line of another record" >>"$TC_KEEP"
      else
        tc_sort_item "$type" "$item"
      fi
    fi
  done <"$TC_TMP/own.items"
}

cmd_teardown() {
  local remove=0 dirs='' brewfile='' clean_cmd='' d kb dir_kb=0 gone_kb=0 rc=0 own own_kb=0 names root
  while (($# > 0)); do
    case "$1" in
      --remove) remove=1 ;;
      --dirs | --brewfile | --clean-cmd)
        (($# >= 2)) || die "$1 needs a value"
        case "$1" in
          --dirs) dirs="$2" ;;
          --brewfile) brewfile="$2" ;;
          --clean-cmd) clean_cmd="$2" ;;
        esac
        shift
        ;;
      *) die "teardown: unknown argument $1" ;;
    esac
    shift
  done
  if [ "$remove" -eq 1 ]; then require_confirm teardown; fi
  root="$(tc_root)"
  own="$(tc_record)"
  tc_tmp_init
  tc_plan_teardown
  [ -f "$own" ] && own_kb="$(tc_kb "$own")"

  # the project's own folders, as listed by make (what each part's distclean or clean removes); no globbing, and nothing
  # that leaves the project
  : >"$TC_TMP/dirs"
  set -f
  for d in $dirs; do
    case "$d" in /* | -* | .. | ../* | */.. | */../*) continue ;; esac
    [ -e "$root/$d" ] || continue
    # a folder that is a link out of the project is not ours to list
    case "$(tc_phys "$root/$d")/" in "$root"/*) ;; *) [ -d "$root/$d" ] && continue ;; esac
    printf '%s\t%s\n' "$d" "$(tc_kb "$root/$d")" >>"$TC_TMP/dirs"
  done
  set +f

  if [ "$remove" -eq 0 ]; then
    printf 'teardown %s: what would be removed (nothing is removed without CONFIRM=teardown)\n' "${PROJECT:-$(basename "$root")}"
    printf '\nproject folders (what make distclean removes, and the local release files)\n'
    if [ -s "$TC_TMP/dirs" ]; then
      while IFS="$(printf '\t')" read -r d kb; do
        printf '  %8s  %s\n' "$(tc_human "$kb")" "$d"
        dir_kb=$((dir_kb + kb))
      done <"$TC_TMP/dirs"
    else
      printf '  none\n'
    fi
    printf '\nusage record\n'
    if [ -f "$own" ]; then
      printf '  %8s  %s\n' "$(tc_human "$own_kb")" "$(tc_tilde "$own")"
    else
      printf '  none (make setup writes it)\n'
    fi
    printf '\nshared installs that no other standard project records\n'
    if [ -s "$TC_REMOVE" ]; then
      tc_print_removals
      tc_note_removals
    else
      TOTAL_KB=0
      printf '  none\n'
    fi
    if [ -s "$TC_KEEP" ] || [ -s "$TC_GONE" ]; then
      printf '\nstay\n'
      tc_print_kept
    fi
    tc_print_invalid
    if [ -s "$TC_TMP/unreach" ]; then
      printf '\nrecords of projects on a drive or folder that is not reachable (kept, and their items stay protected)\n'
      while IFS= read -r d; do printf '  %s\n' "$(tc_record_path "$d")"; done <"$TC_TMP/unreach"
    fi
    printf '\ntotal %s\n' "$(tc_human $((dir_kb + TOTAL_KB + own_kb)))"
    printf 'Homebrew packages are never removed.\n'
    printf '\nto remove these: make teardown CONFIRM=teardown\n'
    return 0
  fi

  # removal: the project's folders through the parts' own distclean and clean, then the shared installs, then the record
  if [ -n "$clean_cmd" ]; then
    bash -c "$clean_cmd" || log_warn "a part's clean reported an error; carrying on"
  fi
  while IFS="$(printf '\t')" read -r d kb; do
    [ -n "$d" ] || continue
    if [ -e "$root/$d" ]; then
      log_warn "$d is still there after distclean"
    else
      gone_kb=$((gone_kb + kb))
      printf 'removed  %s\n' "$d"
    fi
  done <"$TC_TMP/dirs"
  tc_remove_all || rc=1
  if [ -f "$own" ]; then
    gone_kb=$((gone_kb + own_kb))
    rm -f -- "$own" "$own.next"
    printf 'removed  usage record %s\n' "$(tc_tilde "$own")"
  fi
  if [ -s "$TC_KEEP" ]; then
    printf 'stayed:\n'
    tc_print_kept
  fi
  tc_print_invalid
  printf 'freed about %s (project folders and record %s, shared installs %s)\n' \
    "$(tc_human $((gone_kb + FREED_KB)))" "$(tc_human "$gone_kb")" "$(tc_human "$FREED_KB")"
  names="$(tc_brew_names "$brewfile")"
  if [ -n "$names" ]; then
    printf 'Homebrew packages stay: %s\n' "$names"
    printf 'remove one you no longer need with: brew uninstall <name>\n'
  else
    printf 'Homebrew packages stay (this project has no Brewfile).\n'
  fi
  printf 'make setup puts back what this project needs.\n'
  return "$rc"
}

# --- make prune ----------------------------------------------------------------------------------

# tc_cache_pnpm REMOVE   the pnpm store: the packages no project references any more.
tc_cache_pnpm() {
  local store before after
  if ! have pnpm; then
    printf '  %8s  %-14s skipped: pnpm not found\n' '' 'pnpm store'
    return 0
  fi
  store="$(pnpm store path 2>/dev/null || true)"
  before="$(tc_kb "$store")"
  if [ "$1" -eq 0 ]; then
    printf '  %8s  %-14s pnpm store prune drops the packages no project references (%s)\n' "$(tc_human "$before")" 'pnpm store' "$(tc_tilde "$store")"
    return 0
  fi
  if pnpm store prune >/dev/null 2>&1; then
    after="$(tc_kb "$store")"
    [ "$after" -le "$before" ] || after="$before"
    CACHE_FREED_KB=$((CACHE_FREED_KB + before - after))
    printf 'pruned   pnpm store, %s freed\n' "$(tc_human $((before - after)))"
  else
    log_warn "pnpm store prune failed"
    return 1
  fi
}

# tc_cache_cargo REMOVE   cargo's extracted sources and git checkouts, through cargo-cache when it is installed.
tc_cache_cargo() {
  local home before after
  if ! { have cargo && cargo cache --version >/dev/null 2>&1; }; then
    printf '  %8s  %-14s skipped: cargo-cache is not installed, so the registry and git caches stay (brew install cargo-cache)\n' '' 'cargo caches'
    return 0
  fi
  home="${CARGO_HOME:-$HOME/.cargo}"
  before="$(tc_kb "$home/registry" "$home/git")"
  if [ "$1" -eq 0 ]; then
    printf '  %8s  %-14s cargo cache --autoclean drops extracted sources and git checkouts (the downloads stay)\n' "$(tc_human "$before")" 'cargo caches'
    return 0
  fi
  if cargo cache --autoclean >/dev/null 2>&1; then
    after="$(tc_kb "$home/registry" "$home/git")"
    [ "$after" -le "$before" ] || after="$before"
    CACHE_FREED_KB=$((CACHE_FREED_KB + before - after))
    printf 'pruned   cargo caches, %s freed\n' "$(tc_human $((before - after)))"
  else
    log_warn "cargo cache --autoclean failed"
    return 1
  fi
}

tc_cache_docker() {
  printf '  %8s  %-14s skipped: the images of a part go with its make distclean, and there is no way to tell other images from yours\n' '' 'docker images'
}

CACHE_FREED_KB=0

cmd_prune() {
  local remove=0 f p rc=0 line type item nstale=0 used=0 sz
  while (($# > 0)); do
    case "$1" in
      --remove) remove=1 ;;
      *) die "prune: unknown argument $1" ;;
    esac
    shift
  done
  if [ "$remove" -eq 1 ]; then require_confirm prune; fi
  tc_tmp_init
  tc_collect "$TC_TMP/refs" '' "$TC_TMP/stale" "$TC_TMP/unreach" "$TC_TMP/bad"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    type="${line%% *}"
    item="${line#* }"
    if ! tc_line_ok "$line"; then
      printf '%s\n' "$line" >>"$TC_INVALID"
    elif [ -n "$(tc_user_of "$TC_TMP/refs" "$line")" ] || tc_bad_hit "$TC_TMP/bad" "$item"; then
      used=$((used + 1))
    else
      tc_sort_item "$type" "$item"
    fi
  done <"$TC_TMP/ledger"
  nstale="$(grep -c . "$TC_TMP/stale" || true)"

  if [ "$remove" -eq 0 ]; then
    printf 'prune: what would be removed (nothing is removed without CONFIRM=prune)\n'
    printf '\nstale usage records (the project folder is gone)\n'
    if [ "$nstale" -gt 0 ]; then
      while IFS= read -r f; do
        p="$(tc_record_path "$f")"
        sz="$(tc_kb "$f")"
        printf '  %8s  %s\n' "$(tc_human "$sz")" "${p:-$(basename "$f")}"
      done <"$TC_TMP/stale"
    else
      printf '  none\n'
    fi
    if [ -s "$TC_TMP/unreach" ]; then
      printf '\nunreachable usage records (kept: the folder or drive is not there now, so their items stay protected)\n'
      while IFS= read -r f; do printf '  %s\n' "$(tc_record_path "$f")"; done <"$TC_TMP/unreach"
    fi
    printf '\nshared installs that no project records, installed by project-standard\n'
    if [ -s "$TC_REMOVE" ]; then
      tc_print_removals
      tc_note_removals
    else
      TOTAL_KB=0
      printf '  none\n'
    fi
    if [ -s "$TC_KEEP" ] || [ -s "$TC_GONE" ]; then
      printf '\nstay or already gone\n'
      tc_print_kept
    fi
    tc_print_invalid
    printf '\ncaches\n'
    tc_cache_pnpm 0
    tc_cache_cargo 0
    tc_cache_docker
    printf '\n%s still recorded by a project and kept; what project-standard did not install is never touched\n' "$used"
    printf 'total %s without the caches\n' "$(tc_human "$TOTAL_KB")"
    printf '\nto remove these: make prune CONFIRM=prune\n'
    return 0
  fi

  if [ "$nstale" -gt 0 ]; then
    while IFS= read -r f; do
      rm -f -- "$f" "$f.next"
      printf 'removed  stale record %s\n' "$(tc_tilde "$f")"
    done <"$TC_TMP/stale"
  fi
  tc_remove_all || rc=1
  tc_print_invalid
  tc_cache_pnpm 1 || rc=1
  tc_cache_cargo 1 || rc=1
  tc_cache_docker
  printf 'freed about %s (shared installs %s, caches %s)\n' "$(tc_human $((FREED_KB + CACHE_FREED_KB)))" "$(tc_human "$FREED_KB")" "$(tc_human "$CACHE_FREED_KB")"
  return "$rc"
}

# --- main ----------------------------------------------------------------------------------------

usage() {
  printf '%s\n' "usage: toolchain.sh record-begin | record-commit | mise-install | sdk-begin DIR... | sdk-use DIR... | rustup-add TARGET... |" \
    "       toolchain.sh teardown [--remove] [--dirs \"d1 d2\"] [--brewfile F] [--clean-cmd CMD] | prune [--remove]" >&2
  exit 2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  [ -n "$cmd" ] || usage
  shift
  case "$cmd" in
    record-begin) cmd_record_begin ;;
    record-commit) cmd_record_commit ;;
    mise-install) cmd_mise_install ;;
    sdk-begin) cmd_sdk_begin "$@" ;;
    sdk-use) cmd_sdk_use "$@" ;;
    rustup-add) cmd_rustup_add "$@" ;;
    teardown) cmd_teardown "$@" ;;
    prune) cmd_prune "$@" ;;
    *) usage ;;
  esac
fi
