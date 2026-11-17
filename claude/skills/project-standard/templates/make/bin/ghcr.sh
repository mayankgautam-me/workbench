#!/usr/bin/env bash
# project-standard v1.6 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# The GitHub container registry (ghcr.io) for the docker kind. gh does the work; its token reaches docker on stdin only.
#
#   ghcr.sh login  --registry R          docker login ghcr.io with gh's token (gh auth token | docker login
#                                        --password-stdin), as the gh user. Nothing to do when R is not on ghcr.io,
#                                        in CI (the workflow logs in with GITHUB_TOKEN) or when docker already has a
#                                        ghcr.io login. Warns and exits 0 when gh is missing or signed out.
#   ghcr.sh doctor --registry R          warn when gh's token lacks write:packages (fix: gh auth refresh -s
#                                        write:packages) or docker has no ghcr.io login. Exits 0.
#   ghcr.sh prune  --image REF [--keep-days N] [--remove]
#                                        REF = ghcr.io/<owner>/<package>. Lists the package's versions that are
#                                        untagged or tagged only with git shas, older than N days (default 30), and
#                                        never a platform manifest of a version that stays. --remove deletes them and
#                                        needs CONFIRM=prune in its environment (make <part>-prune-images CONFIRM=prune).
# Bash 3.2. Internal: run it through make.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

usage() { die "usage: ghcr.sh login|doctor --registry R | prune --image REF [--keep-days N] [--remove]"; }

cmd=${1:-}
[[ -n $cmd ]] || usage
shift
registry=''
image=''
keep_days=30
remove=0
while (($# > 0)); do
  case $1 in
    --registry) registry=${2-}; shift 2 ;;
    --image) image=${2-}; shift 2 ;;
    --keep-days) keep_days=${2-}; shift 2 ;;
    --remove) remove=1; shift ;;
    *) usage ;;
  esac
done

on_ghcr() { case $1 in ghcr.io/*) return 0 ;; *) return 1 ;; esac; }
in_ci() { [[ -n ${CI:-}${GITHUB_ACTIONS:-} ]]; }

# docker has a ghcr.io login: an auths or credHelpers entry in its config (a credential store keeps the secret)
docker_logged_in() {
  local cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
  [[ -f $cfg ]] && grep -q '"ghcr.io"' "$cfg"
}

gh_ready() {
  command -v gh >/dev/null 2>&1 || {
    log_warn "gh not found (brew install gh, then gh auth login -s write:packages)"
    return 1
  }
  gh auth status >/dev/null 2>&1 || {
    log_warn "gh is not signed in: gh auth login -s write:packages"
    return 1
  }
}

cmd_login() {
  on_ghcr "$registry" || return 0
  if in_ci; then return 0; fi
  if docker_logged_in; then
    log_ok "docker is logged in to ghcr.io"
    return 0
  fi
  gh_ready || return 0
  local user
  user=$(gh api user --jq .login 2>/dev/null || true)
  [[ -n $user ]] || {
    log_warn "could not read the gh user (offline?): docker is not logged in to ghcr.io; run make setup again later"
    return 0
  }
  if gh auth token 2>/dev/null | docker login ghcr.io -u "$user" --password-stdin >/dev/null 2>&1; then
    log_ok "docker logged in to ghcr.io as $user (gh's token)"
  else
    log_warn "docker login ghcr.io failed: check gh auth status (it needs write:packages: gh auth refresh -s write:packages)"
  fi
  return 0
}

cmd_doctor() {
  on_ghcr "$registry" || return 0
  in_ci && return 0
  if gh_ready; then
    if gh auth status 2>&1 | grep -q 'write:packages'; then
      log_ok "gh's token has write:packages (ghcr.io pushes)"
    else
      log_warn "gh's token lacks the write:packages scope that pushing to ghcr.io needs: gh auth refresh -s write:packages"
    fi
  fi
  if docker_logged_in; then
    log_ok "docker has a ghcr.io login"
  else
    log_warn "docker is not logged in to ghcr.io: make setup logs in with gh's token"
  fi
  return 0
}

# cutoff N: the UTC time N days ago, ISO 8601 (compares as text with the API's created_at)
cutoff() {
  date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ
}

cmd_prune() {
  [[ -n $image ]] || usage
  [[ $keep_days =~ ^[0-9]+$ ]] || die "KEEP_DAYS=$keep_days is not a number of days"
  on_ghcr "$image" || die "$image is not on ghcr.io: prune-images only knows the GitHub container registry"
  if ((remove == 1)) && [[ ${CONFIRM:-} != prune ]]; then
    die "deleting image versions needs CONFIRM=prune (make <part>-prune-images CONFIRM=prune)"
  fi
  command -v gh >/dev/null 2>&1 || die "gh not found (brew install gh)"
  local rest owner pkg base type cut
  rest=${image#ghcr.io/}
  owner=${rest%%/*}
  pkg=${rest#*/}
  [[ -n $owner && -n $pkg && $pkg != "$rest" ]] || die "$image: expected ghcr.io/<owner>/<package>"
  pkg=${pkg//\//%2F}
  type=$(gh api "users/$owner" --jq .type 2>/dev/null) || die "cannot read the GitHub account $owner (gh auth status)"
  if [[ $type == Organization ]]; then base="orgs/$owner"; else base="users/$owner"; fi
  cut=$(cutoff "$keep_days")

  local list
  list=$(gh api --paginate "$base/packages/container/$pkg/versions?per_page=100" \
    --jq '.[] | [(.id | tostring), .name, .created_at, ((.metadata.container.tags // []) | join(","))] | join(" ")') ||
    die "cannot list the versions of $image (gh auth refresh -s read:packages,write:packages)"

  # versions that stay: a tag other than a git sha, or younger than the cutoff. Their platform manifests stay too.
  local id digest created tags t keep shaonly kept_digests='' children='' cand=''
  while read -r id digest created tags; do
    [[ -n $id ]] || continue
    keep=0
    shaonly=1
    if [[ -n $tags ]]; then
      for t in ${tags//,/ }; do
        [[ $t =~ ^[0-9a-f]{7,40}$ ]] || shaonly=0
      done
    fi
    ((shaonly == 1)) || keep=1
    if [[ $created > $cut ]]; then keep=1; fi
    if ((keep == 1)); then
      [[ -z $tags ]] || kept_digests="$kept_digests $digest"
    else
      cand="$cand$id $digest $created ${tags:-untagged}"$'\n'
    fi
  done < <(printf '%s\n' "$list")

  if [[ -n $cand && -n $kept_digests ]]; then
    command -v docker >/dev/null 2>&1 || die "docker not found: it reads which untagged versions are platform manifests of the images that stay"
    local d raw
    for d in $kept_digests; do
      raw=$(docker buildx imagetools inspect --raw "$image@$d" 2>/dev/null) ||
        die "cannot read the manifest of $image@$d (docker login ghcr.io: make setup): nothing is deleted"
      children="$children $(printf '%s' "$raw" | grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]{64}"' | grep -oE 'sha256:[0-9a-f]{64}' | tr '\n' ' ')"
    done
  fi

  local n=0 del=''
  while read -r id digest created tags; do
    [[ -n $id ]] || continue
    case " $children " in *" $digest "*) continue ;; esac
    n=$((n + 1))
    del="$del $id"
    printf '  %s  %s  %s  %s\n' "$created" "$digest" "$tags" "id $id"
  done < <(printf '%s' "$cand")

  if ((n == 0)); then
    log_ok "$image: no untagged or sha-only version older than $keep_days days"
    return 0
  fi
  if ((remove == 0)); then
    log_info "$image: $n version(s) above are untagged or sha-only and older than $keep_days days"
    log_info "to delete them: make <part>-prune-images CONFIRM=prune (KEEP_DAYS=$keep_days)"
    return 0
  fi
  local rc=0
  for id in $del; do
    if gh api -X DELETE "$base/packages/container/$pkg/versions/$id" >/dev/null 2>&1; then
      log_ok "deleted version $id"
    else
      log_err "could not delete version $id (gh auth refresh -s delete:packages)"
      rc=1
    fi
  done
  return "$rc"
}

case $cmd in
  login) cmd_login ;;
  doctor) cmd_doctor ;;
  prune) cmd_prune ;;
  *) usage ;;
esac
