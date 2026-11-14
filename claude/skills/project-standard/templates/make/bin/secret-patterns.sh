#!/usr/bin/env bash
# project-standard v1.0 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# The one list of secret-like file names, and the one content check (.npmrc). Sourced by secrets.sh (`check`)
# and by the skill's scripts/audit.sh, so the two cannot disagree. Globs are matched against the file name and against the whole relative path.
# Bash 3.2 compatible. Nothing in here touches secrets.
# shellcheck shell=bash

# Plaintext secret files: an error when tracked, a warning when they sit untracked on disk.
STD_SECRET_PATTERNS='.env .env.* .dev.vars .dev.vars.* .prod.vars .prod.vars.* *.pem *.p8 *.p12 *.pfx *.ppk *.key *.jks *.keystore id_rsa id_ed25519 id_ecdsa id_dsa .netrc *.tfvars *service-account*.json secrets/* */secrets/* keys/* */keys/*'

# Files that are secrets only when they hold credentials: an .npmrc with only settings is fine, one with an
# auth setting (_authToken, _auth, _password, username, password, also per registry as //host/:_authToken)
# is a secret. A value that is only an environment reference (${NPM_TOKEN}) holds no credential.
STD_SECRET_IF_AUTH_PATTERNS='.npmrc'

# Files that look like templates and are fine.
STD_SECRET_EXEMPT='.env.example .env.sample .env.template .env.defaults'

# Files that often hold exports of secrets (direnv): a warning, not an error.
STD_SECRET_WARN_PATTERNS='.envrc'

# _std_glob_any LIST NAME...   success when a glob of the space separated LIST matches any NAME.
# Walks the list with parameter expansion so no glob is ever expanded against the files in the cwd.
_std_glob_any() {
  local rest="$1" p n
  shift
  while [ -n "$rest" ]; do
    p="${rest%% *}"
    if [ "$p" = "$rest" ]; then rest=""; else rest="${rest#* }"; fi
    [ -n "$p" ] || continue
    for n in "$@"; do
      # shellcheck disable=SC2254
      case "$n" in $p) return 0 ;; esac
    done
  done
  return 1
}

# _std_npmrc_has_auth FILE   success when FILE sets a credential, or cannot be read (then it is not known
# to be safe). Only counts matching lines: nothing of the file is ever printed.
_std_npmrc_has_auth() {
  local file="$1" n
  [ -f "$file" ] && [ -r "$file" ] || return 0
  n=$({ grep -iE '^[[:space:]]*([^=#;[:space:]]*:)?(_authToken|_auth|_password|username|password)[[:space:]]*=' "$file" || true; } |
    { grep -vE '=[[:space:]]*"?\$\{[A-Za-z_][A-Za-z0-9_]*\}"?[[:space:]]*$' || true; } | { grep -c . || true; })
  [ "${n:-0}" -gt 0 ]
}

# std_secret_class PATH [ROOT]   print "secret", "warn" or nothing for PATH, relative to ROOT (default: the
# current directory). Names alone decide, except for the files in STD_SECRET_IF_AUTH_PATTERNS, which are read.
std_secret_class() {
  local f="$1" root="${2:-.}" base
  base="${f##*/}"
  if _std_glob_any "$STD_SECRET_EXEMPT" "$base"; then return 0; fi
  if _std_glob_any "$STD_SECRET_PATTERNS" "$base" "$f"; then printf 'secret'; return 0; fi
  if _std_glob_any "$STD_SECRET_IF_AUTH_PATTERNS" "$base" "$f"; then
    if _std_npmrc_has_auth "$root/$f"; then printf 'secret'; fi
    return 0
  fi
  if _std_glob_any "$STD_SECRET_WARN_PATTERNS" "$base"; then printf 'warn'; fi
  return 0
}
