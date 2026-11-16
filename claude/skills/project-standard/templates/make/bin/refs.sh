#!/usr/bin/env bash
# project-standard v1.1 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Reference documents: datasheets, manuals and application notes the project works from, never committed.
# docs/references.md lists them in a Markdown table whose header names the columns (any order, any case):
#
#   | Title | Vendor | File | URL | SHA256 |
#   |---|---|---|---|---|
#   | CQM220 hardware manual | Cavli | cavli/cqm220-hardware-manual.pdf | https://... | 3f2a... |
#
#   refs.sh [--file F] [--dir D] fetch   download each row's URL into D/<File> (curl -fL, https only), check its
#                                        SHA256; a file already there with the right SHA256 is skipped; a row without
#                                        SHA256 gets the value printed (paste it into the table: F is never edited)
#   refs.sh [--file F] [--dir D] check   the same checks without downloading: a missing file or a wrong SHA256 fails
#
# Defaults: --file docs/references.md, --dir references (in .gitignore). File is a path inside D: relative, no "..".
# Bash 3.2.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

file=docs/references.md
dir=references
cmd=''
while (($# > 0)); do
  case $1 in
    --file) file=${2:?--file needs a value}; shift 2 ;;
    --dir) dir=${2:?--dir needs a value}; shift 2 ;;
    fetch | check) cmd=$1; shift ;;
    *) die "usage: refs.sh [--file F] [--dir D] fetch|check" ;;
  esac
done
[[ -n $cmd ]] || die "usage: refs.sh [--file F] [--dir D] fetch|check"
[[ -f $file ]] || die "no $file: list the reference documents there (| Title | Vendor | File | URL | SHA256 |)"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

# trim TEXT: no surrounding blanks or backticks; a Markdown link [x](url) or <url> becomes the url
cell() {
  local v=$1
  # shellcheck disable=SC2016 # the backticks are Markdown, not a command
  v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^`(.*)`$/\1/')
  case $v in
    \[*\]\(*\)) v=$(printf '%s' "$v" | sed -E 's/^\[[^]]*\]\((.*)\)$/\1/') ;;
    \<*\>) v=${v#<}; v=${v%>} ;;
  esac
  printf '%s' "$v"
}

# The table: a first line "head" once its header is found, then one line per row, fields Title, File, URL, SHA256
# separated by US. Header columns are matched by name.
US=$'\037'
rows=$(awk -v us="$US" '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  /^[ \t]*\|/ {
    line = $0; sub(/^[ \t]*\|/, "", line); sub(/\|[ \t]*$/, "", line)
    n = split(line, c, /\|/)
    if (!head) {
      for (i = 1; i <= n; i++) { h = tolower(trim(c[i])); col[h] = i }
      if (("file" in col) && ("url" in col)) { head = 1; print "head" } else { delete col }
      next
    }
    if (line ~ /^[ \t:|-]+$/) next
    t = ("title" in col) ? c[col["title"]] : ""
    s = ("sha256" in col) ? c[col["sha256"]] : ""
    print t us c[col["file"]] us c[col["url"]] us s
    next
  }
  head { exit }
' "$file")
[[ -n $rows ]] || die "$file has no table with File and URL columns (| Title | Vendor | File | URL | SHA256 |)"
rows=${rows#head}
rows=${rows#$'\n'}
if [[ -z $rows ]]; then
  log_info "$file lists no reference documents yet: add a row per datasheet or manual"
  exit 0
fi

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git check-ignore -q "$dir/x" 2>/dev/null || log_warn "$dir/ is not in .gitignore: add the line $dir/ (reference documents are never committed)"
fi

rc=0
n=0
while IFS="$US" read -r title rel url want; do
  title=$(cell "$title")
  rel=$(cell "$rel")
  url=$(cell "$url")
  want=$(cell "$want" | tr 'A-F' 'a-f')
  n=$((n + 1))
  [[ -n $rel ]] || { log_err "row $n ($title): no File"; rc=1; continue; }
  case "/$rel/" in
    */../* | //*) log_err "row $n: File '$rel' must be a relative path inside $dir/"; rc=1; continue ;;
  esac
  case $rel in -*) log_err "row $n: File '$rel' must not start with -"; rc=1; continue ;; esac
  if [[ -n $want && ! $want =~ ^[0-9a-f]{64}$ ]]; then
    log_err "$rel: SHA256 '$want' in $file is not 64 hex digits"
    rc=1
    continue
  fi
  dest="$dir/$rel"
  if [[ -f $dest ]]; then
    have=$(sha256_of "$dest")
    if [[ -z $want ]]; then
      log_warn "$rel: no SHA256 in $file; this file's is $have (paste it into the row)"
      continue
    fi
    if [[ $have == "$want" ]]; then
      log_ok "$rel"
      continue
    fi
    if [[ $cmd == check ]]; then
      log_err "$rel: SHA256 is $have, $file says $want (make refs-fetch downloads it again)"
      rc=1
      continue
    fi
    log_warn "$rel: SHA256 is $have, $file says $want: downloading it again"
  elif [[ $cmd == check ]]; then
    log_err "$rel: missing (make refs-fetch downloads it)"
    rc=1
    continue
  fi
  case $url in
    https://*) ;;
    *) log_err "$rel: URL '$url' is not https://"; rc=1; continue ;;
  esac
  mkdir -p "$(dirname "$dest")"
  tmp="$dest.part"
  rm -f "$tmp"
  if ! curl -fsSL --retry 2 -o "$tmp" "$url"; then
    rm -f "$tmp"
    log_err "$rel: download failed ($url)"
    rc=1
    continue
  fi
  got=$(sha256_of "$tmp")
  if [[ -n $want && $got != "$want" ]]; then
    rm -f "$tmp"
    log_err "$rel: the download's SHA256 is $got, $file says $want: not kept (has the document changed upstream?)"
    rc=1
    continue
  fi
  mv -f "$tmp" "$dest"
  if [[ -z $want ]]; then
    log_warn "$rel: downloaded; no SHA256 in $file: $got (paste it into the row)"
  else
    log_ok "$rel: downloaded"
  fi
done < <(printf '%s\n' "$rows")
exit "$rc"
