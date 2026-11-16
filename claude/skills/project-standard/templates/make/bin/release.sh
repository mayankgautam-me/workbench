#!/usr/bin/env bash
# project-standard v1.5 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Versions, release notes and GitHub Releases of one part. make runs it from the project root.
#
#   release.sh version --part P --kind K [--part-dir D] [--platform X]   print the part's version (from the kind's own source)
#   release.sh bump    --part P --kind K [--part-dir D] (--level patch|minor|major | --version V) [--force]
#                      set the version, move the CHANGELOG's Unreleased section under it, commit the version
#                      file(s) and the CHANGELOG (by name) as "<part>: release <version>", tag <part>-v<version>
#                      (annotated); never pushes
#   release.sh notes   --part P --version V [--part-dir D]   print the CHANGELOG section of V (error when missing)
#   release.sh sums    --dir D [--platform X]                 write D/SHA256SUMS for every other file in D; with a platform,
#                      D/SHA256SUMS-X instead (every other SHA256SUMS* file is left out)
#   release.sh zip     --from DIR --to FILE                   zip the content of DIR (zip, else python3 zipfile)
#   release.sh gate    --part P --version V [--force]         in the release workflow of tag <part>-v<V>: exit 0 go on;
#                      3: the workflow of another tag (nothing to do); 1: refused. Outside CI, --force goes on
#   release.sh create  --part P --version V (--dir D | --notes-only) [--part-dir D2] [--build-note-file F]
#                      the GitHub Release of tag <part>-v<V> (the workflow pushed the tag), titled "<part> <V>", notes from
#                      the CHANGELOG. Its assets are the files of D, except the unlinked ones (*.aab and *-mapping.txt):
#                      those stay in D, and each is printed as "unlinked: NAME" for the workflow to upload as a workflow
#                      artifact. When the Release exists (another platform's job made it, or a retry), its name and notes
#                      are updated and the assets uploaded with --clobber. Build lines ("### Builds", one "- platform: text"
#                      per platform) are kept across updates; F, when given and present, holds this platform's line
#                      ("ios: TestFlight build 42"). --notes-only (the Cloudflare kinds, cloud-worker and web-pages): the
#                      Release carries the notes and no files, and D is not read.
#   release.sh upload  the v8 name of create, same arguments: kept so existing callers still work
#   release.sh push                                           push the branch, then each release tag (<part>-v<version>) on it
#                      that origin does not have, one tag per push: GitHub starts no workflow when more than three
#                      tags arrive in one push. A tag that origin has with another commit is refused
#   release.sh latest  [--part P]                           the newest published Release of part P, or of every part: name,
#                      date and page. GitHub marks one Release of a repository "Latest"; this is the per-part answer
#   release.sh latest-sync --part P --kind K --version V [--project NAME]
#                      (since v20) copy the files of the published Release <part>-v<V> into the Release "latest" (made
#                      when missing), under names without the version, and give it GitHub's Latest badge; see "the latest
#                      Release" below. create runs it from a Mac; the release workflow's latest job runs it in CI
#   release.sh host-platform                                  print the platform this machine builds: macos, linux-amd64,
#                      linux-arm64, windows (Git Bash) or unknown
#
# Platforms (since v8): macos ios android linux-amd64 linux-arm64 windows. The app kinds, which build per platform, write
# SHA256SUMS-<platform>; the other kinds keep one SHA256SUMS. Checksum files are assets of the Release like the others.
#
# GitHub: gh does the work. In a GitHub Actions run (GITHUB_ACTIONS set) the repo is
# GITHUB_REPOSITORY and the token is GH_TOKEN, which the workflow sets from GITHUB_TOKEN (permissions: contents: write);
# on a Mac gh uses its own login and infers the repo from the checkout. The token is read by gh from the environment,
# never put on a command line. Bash 3.2, no here-documents.

set -euo pipefail

STD_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$STD_BIN_DIR/lib.sh"

have() { command -v "$1" >/dev/null 2>&1; }

OPT_PART='' OPT_KIND='' OPT_PDIR='' OPT_LEVEL='' OPT_VERSION='' OPT_DIR='' OPT_FORCE=0 OPT_NOTES_ONLY=0
OPT_FROM='' OPT_TO='' OPT_PLATFORM='' OPT_BUILD_NOTE_FILE='' OPT_PROJECT=''

parse() {
  while (($# > 0)); do
    case $1 in
      --part | --kind | --part-dir | --level | --version | --dir | --from | --to | --platform | --build-note-file | --project)
        (($# >= 2)) || die "$1 needs a value"
        case $1 in
          --part) OPT_PART=$2 ;;
          --kind) OPT_KIND=$2 ;;
          --part-dir) OPT_PDIR=$2 ;;
          --level) OPT_LEVEL=$2 ;;
          --version) OPT_VERSION=$2 ;;
          --dir) OPT_DIR=$2 ;;
          --from) OPT_FROM=$2 ;;
          --to) OPT_TO=$2 ;;
          --platform) OPT_PLATFORM=$2 ;;
          --build-note-file) OPT_BUILD_NOTE_FILE=$2 ;;
          --project) OPT_PROJECT=$2 ;;
        esac
        shift 2
        ;;
      --force)
        OPT_FORCE=1
        shift
        ;;
      --notes-only)
        OPT_NOTES_ONLY=1
        shift
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  if [[ -n $OPT_PART ]]; then
    [[ $OPT_PART =~ ^[a-z][a-z0-9-]*$ ]] || die "part name '$OPT_PART': lowercase letters, digits and '-'"
    [[ -n $OPT_PDIR ]] || OPT_PDIR=$OPT_PART
  fi
}

need_part() { [[ -n $OPT_PART ]] || die "--part is required"; }

# valid_platform X: one of the platforms a release is built for (since v8).
valid_platform() {
  case $1 in
    macos | ios | android | linux-amd64 | linux-arm64 | windows | windows-x64 | windows-arm64) return 0 ;;
  esac
  return 1
}

# host_platform: the platform this machine builds (Git Bash reports MINGW*, MSYS* or CYGWIN*).
host_platform() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)
      case "$(uname -m)" in
        aarch64 | arm64) echo linux-arm64 ;;
        *) echo linux-amd64 ;;
      esac
      ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}
need_kind() { [[ -n $OPT_KIND ]] || die "--kind is required"; }
need_version() {
  [[ -n $OPT_VERSION ]] || die "--version is required"
  valid_version "$OPT_VERSION" || die "version '$OPT_VERSION': use 1 to 3 numbers with dots and an optional -prerelease (1.4.0, 2, 1.5.0-rc1)"
}

valid_version() { [[ $1 =~ ^[0-9]+(\.[0-9]+){0,2}(-[0-9A-Za-z][0-9A-Za-z.]*)?$ ]]; }

# replace_file FILE: move FILE.new over FILE (keeps the mode of FILE).
replace_file() {
  cat "$1.new" >"$1"
  rm -f "$1.new"
}

# --- version sources ------------------------------------------------------------------------------
#
# The file each kind keeps its version in, relative to the part dir:
#   firmware kinds   VERSION (Zephyr VERSION_MAJOR/... format, or a plain first line), else version.txt
#   hardware         VERSION, else the rev of the .kicad_pcb title block (bump then writes VERSION)
#   altium, mechanical   VERSION (a revision, as hardware; the first bump creates it)
#   go, docker, cloud-worker, web-pages   VERSION (plain; the first bump creates it)
#   app-flutter      pubspec.yaml  version: x.y.z+build (bump also counts the build number up)
#   app-tauri        src-tauri/tauri.conf.json "version" (or the package.json it points to); bump also sets the
#                    [package] version of src-tauri/Cargo.toml, the "version" of package.json and, when it is
#                    tracked, the app's entry in src-tauri/Cargo.lock
#   app-android      app/build.gradle.kts versionName (bump also counts versionCode up)
#   app-xcode        the marketing version, through agvtool (bump refuses without it)
#   python           pyproject.toml version

pdir() { printf '%s\n' "$OPT_PDIR"; }

plain_file() {
  local d
  d=$(pdir)
  if [[ -f $d/VERSION ]]; then
    printf '%s\n' "$d/VERSION"
  elif [[ -f $d/version.txt ]]; then
    printf '%s\n' "$d/version.txt"
  fi
}

# read_plain FILE: the version in a VERSION file, Zephyr format or a plain first line.
read_plain() {
  local f=$1 v x
  if grep -q '^VERSION_MAJOR' "$f"; then
    v=$(sed -nE 's/^(VERSION_MAJOR|VERSION_MINOR|PATCHLEVEL)[[:space:]]*=[[:space:]]*([0-9]+).*/\2/p' "$f" | paste -sd. -)
    x=$(sed -nE 's/^EXTRAVERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$f")
    [[ -z $x ]] || v="$v-$x"
    printf '%s\n' "$v"
  else
    head -n 1 "$f" | tr -d '[:space:]'
    echo
  fi
}

hw_pcb() {
  local d f
  d=$(pdir)
  for f in "$d"/*.kicad_pcb; do
    [[ -f $f ]] && printf '%s\n' "$f" && return 0
  done
  return 0
}

tauri_conf() { printf '%s\n' "$(pdir)/src-tauri/tauri.conf.json"; }

# The file that holds a Tauri app's version: tauri.conf.json, or the JSON file its "version" names.
tauri_file() {
  local conf v
  conf=$(tauri_conf)
  [[ -f $conf ]] || return 0
  v=$(sed -nE 's/.*"version":[[:space:]]*"([^"]*)".*/\1/p' "$conf" | head -n 1)
  case $v in
    */* | *.json) printf '%s\n' "$(dirname "$conf")/$v" ;;
    *) printf '%s\n' "$conf" ;;
  esac
}

# json_set_version FILE VERSION: the top-level "version" of a JSON file (one key per line, as tauri.conf.json and
# package.json are written); a nested "version" is left as it is. Status 3 when there is none.
json_set_version() {
  awk -v v="$2" '
    { s = $0; gsub(/"([^"\\]|\\.)*"/, "\"\"", s) }
    !done && depth == 1 && /^[ \t]*"version":[ \t]*"[^"]*"/ { sub(/"version":[ \t]*"[^"]*"/, "\"version\": \"" v "\""); done = 1 }
    { print; o = s; depth += gsub(/[{[]/, "", o); o = s; depth -= gsub(/[]}]/, "", o) }
    END { if (!done) exit 3 }' "$1" >"$1.new" || { rm -f "$1.new"; return 3; }
  replace_file "$1"
}

# cargo_package_key FILE KEY: a string key of the [package] table of a Cargo.toml (empty when missing, as with
# version.workspace = true).
cargo_package_key() {
  awk -v k="$2" '
    /^[ \t]*\[/ { sec = $0; sub(/^[ \t]*/, "", sec); sub(/[ \t]*(#.*)?$/, "", sec); next }
    sec == "[package]" && $0 ~ "^[ \t]*" k "[ \t]*=[ \t]*\"" { v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v); print v; exit }
  ' "$1"
}

# cargo_set_version FILE VERSION: the version key of [package], never a dependency's. Status 3 when there is none.
cargo_set_version() {
  awk -v v="$2" '
    /^[ \t]*\[/ { sec = $0; sub(/^[ \t]*/, "", sec); sub(/[ \t]*(#.*)?$/, "", sec) }
    !done && sec == "[package]" && /^[ \t]*version[ \t]*=[ \t]*"[^"]*"/ { sub(/"[^"]*"/, "\"" v "\""); done = 1 }
    { print }
    END { if (!done) exit 3 }' "$1" >"$1.new" || { rm -f "$1.new"; return 3; }
  replace_file "$1"
}

# lock_set_version FILE NAME OLD NEW: the version of the [[package]] entry NAME at OLD in a Cargo.lock (the app's
# own entry; a dependency of the same name has another version). Status 3 when there is none.
lock_set_version() {
  awk -v n="$2" -v old="$3" -v v="$4" '
    /^\[/ { pkg = ($0 == "[[package]]"); mine = 0 }
    pkg && $0 == "name = \"" n "\"" { mine = 1 }
    !done && pkg && mine && $0 == "version = \"" old "\"" { print "version = \"" v "\""; done = 1; next }
    { print }
    END { if (!done) exit 3 }' "$1" >"$1.new" || { rm -f "$1.new"; return 3; }
  replace_file "$1"
}

# tauri_set_version VERSION: a Tauri app declares its version in up to three files, and bump sets it in each that
# exists: tauri.conf.json (or the JSON file its "version" names), the [package] version of src-tauri/Cargo.toml and
# the "version" of package.json. The app's own entry in src-tauri/Cargo.lock follows Cargo.toml when the lock is
# tracked. Prints the files it changed, one per line.
tauri_set_version() {
  local v=$1 d f cargo lock pkg name old
  d=$(pdir)
  f=$(tauri_file)
  [[ -n $f && -f $f ]] || die "$OPT_PART: no $(tauri_conf) (or the file its version points to)"
  json_set_version "$f" "$v" || die "$OPT_PART: no \"version\" in $f"
  printf '%s\n' "$f"
  cargo="$d/src-tauri/Cargo.toml"
  if [[ -f $cargo ]]; then
    name=$(cargo_package_key "$cargo" name)
    old=$(cargo_package_key "$cargo" version)
    if [[ -z $old ]]; then
      log_info "$OPT_PART: $cargo has no version = \"...\" in [package] (a workspace version?): left as it is"
    else
      cargo_set_version "$cargo" "$v" || die "$OPT_PART: could not set the version in $cargo"
      printf '%s\n' "$cargo"
      lock="$d/src-tauri/Cargo.lock"
      if [[ -n $name && -f $lock ]] && git ls-files --error-unmatch -- "$lock" >/dev/null 2>&1; then
        if lock_set_version "$lock" "$name" "$old" "$v"; then
          printf '%s\n' "$lock"
        else
          log_info "$OPT_PART: $lock has no entry $name $old: left as it is (cargo updates it on the next build)"
        fi
      fi
    fi
  fi
  pkg="$d/package.json"
  if [[ -f $pkg && ! $pkg -ef $f ]]; then
    if json_set_version "$pkg" "$v"; then
      printf '%s\n' "$pkg"
    else
      log_info "$OPT_PART: $pkg has no top-level \"version\": left as it is"
    fi
  fi
}

gradle_file() { printf '%s\n' "$(pdir)/app/build.gradle.kts"; }

# pyproject_version FILE: the version of [project] (or [tool.poetry]); "dynamic" when it is dynamic.
pyproject_version() {
  awk '
    /^\[/ { sec = $0; next }
    (sec == "[project]" || sec == "[tool.poetry]") && /^version[ \t]*=/ { v = $0; sub(/^[^"\x27]*["\x27]/, "", v); sub(/["\x27].*$/, "", v); print v; exit }
    sec == "[project]" && /^dynamic[ \t]*=/ && /"version"/ { print "dynamic"; exit }
  ' "$1"
}

xcode_version() {
  local d v=''
  d=$(pdir)
  if have xcrun; then
    v=$(cd "$d" && xcrun agvtool what-marketing-version -terse1 2>/dev/null | head -n 1 | tr -d '[:space:]') || v=''
  fi
  if [[ -z $v ]]; then
    v=$(cat "$d"/*.xcodeproj/project.pbxproj 2>/dev/null | sed -nE 's/.*MARKETING_VERSION = "?([^";]*)"?;.*/\1/p' | head -n 1)
  fi
  printf '%s\n' "$v"
}

# is_board_kind: the kind versions a physical revision (hardware, altium, mechanical): a first bump starts at a plain
# number (1, 2, ...), and each major revision keeps its own files in the latest Release.
is_board_kind() {
  case $OPT_KIND in hardware | altium | mechanical) return 0 ;; esac
  return 1
}

# current_version: the part's version, empty when it has none yet.
current_version() {
  local d f v=''
  d=$(pdir)
  case $OPT_KIND in
    zephyr | espidf | pio | arm-gcc | circuitpython | silabs | go | docker | cloud-worker | web-pages | altium | mechanical)
      f=$(plain_file)
      [[ -z $f ]] || v=$(read_plain "$f")
      ;;
    hardware)
      f=$(plain_file)
      if [[ -n $f ]]; then
        v=$(read_plain "$f")
      else
        f=$(hw_pcb)
        if [[ -n $f ]]; then
          v=$(sed -nE 's/^[[:space:]]*\(rev "([^"]*)"\).*/\1/p' "$f" | head -n 1 |
            sed -E 's/^([Vv]ersion|[Rr]evision|[Rr]ev|[Vv])[[:space:]]*//' | tr ' ' '-')
        fi
      fi
      ;;
    app-flutter)
      [[ ! -f $d/pubspec.yaml ]] || v=$(sed -nE 's/^version:[[:space:]]*([^+[:space:]]*).*/\1/p' "$d/pubspec.yaml" | head -n 1)
      ;;
    app-tauri)
      f=$(tauri_file)
      [[ -z $f || ! -f $f ]] || v=$(sed -nE 's/.*"version":[[:space:]]*"([^"]*)".*/\1/p' "$f" | head -n 1)
      ;;
    app-android)
      f=$(gradle_file)
      [[ ! -f $f ]] || v=$(sed -nE 's/.*versionName[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$f" | head -n 1)
      ;;
    app-xcode) v=$(xcode_version) ;;
    python)
      if [[ -f $d/pyproject.toml ]]; then
        v=$(pyproject_version "$d/pyproject.toml")
        [[ $v != dynamic ]] || die "$OPT_PART: the version in $d/pyproject.toml is dynamic: make $OPT_PART-bump needs a static version = \"x.y.z\""
      fi
      ;;
    *) die "kind '$OPT_KIND' has no version source" ;;
  esac
  printf '%s\n' "$v"
}

# split_version X[.Y[.Z]]: sets a, b and c (empty when missing). No here-string: bash 3.2 backs those with a file.
split_version() {
  a=${1%%.*} b='' c=''
  local rest=${1#"$a"}
  rest=${rest#.}
  [[ -z $rest ]] && return 0
  b=${rest%%.*}
  rest=${rest#"$b"}
  c=${rest#.}
}

# next_version CURRENT LEVEL: patch/minor/major, keeping the number of components (a hardware rev "2" is
# bumped to "3" whatever the level). A pre-release (1.5.0-rc1) is released as 1.5.0 by patch.
next_version() {
  local cur=$1 level=$2 base pre n a b c
  base=${cur%%-*}
  pre=''
  [[ $base == "$cur" ]] || pre=${cur#*-}
  split_version "$base"
  n=1
  [[ -z ${b:-} ]] || n=2
  [[ -z ${c:-} ]] || n=3
  b=${b:-0}
  c=${c:-0}
  if [[ -n $pre && $level == patch ]]; then
    printf '%s\n' "$base"
    return 0
  fi
  case $level in
    major) a=$((a + 1)) b=0 c=0 ;;
    minor) if ((n >= 2)); then b=$((b + 1)) c=0; else a=$((a + 1)); fi ;;
    patch)
      if ((n >= 3)); then
        c=$((c + 1))
      elif ((n == 2)); then
        b=$((b + 1))
      else
        a=$((a + 1))
      fi
      ;;
  esac
  case $n in
    1) printf '%s\n' "$a" ;;
    2) printf '%s.%s\n' "$a" "$b" ;;
    *) printf '%s.%s.%s\n' "$a" "$b" "$c" ;;
  esac
}

# write_plain FILE VERSION ZEPHYR(0|1): a VERSION file in Zephyr format (keeps its other lines) or plain.
write_plain() {
  local f=$1 v=$2 zephyr=$3 base pre a b c
  base=${v%%-*}
  pre=''
  [[ $base == "$v" ]] || pre=${v#*-}
  if ((zephyr == 1)); then
    split_version "$base"
    if [[ -f $f ]]; then
      awk -v a="$a" -v b="${b:-0}" -v c="${c:-0}" -v x="$pre" '
        /^VERSION_MAJOR[ \t]*=/ { print "VERSION_MAJOR = " a; ma = 1; next }
        /^VERSION_MINOR[ \t]*=/ { print "VERSION_MINOR = " b; mi = 1; next }
        /^PATCHLEVEL[ \t]*=/ { print "PATCHLEVEL = " c; pl = 1; next }
        /^EXTRAVERSION[ \t]*=/ { print "EXTRAVERSION =" (x == "" ? "" : " " x); ex = 1; next }
        { print }
        END {
          if (!ma) print "VERSION_MAJOR = " a; if (!mi) print "VERSION_MINOR = " b; if (!pl) print "PATCHLEVEL = " c
          if (!ex) print "EXTRAVERSION =" (x == "" ? "" : " " x)
        }' "$f" >"$f.new"
      replace_file "$f"
    else
      printf 'VERSION_MAJOR = %s\nVERSION_MINOR = %s\nPATCHLEVEL = %s\nVERSION_TWEAK = 0\nEXTRAVERSION =%s\n' \
        "$a" "${b:-0}" "${c:-0}" "${pre:+ $pre}" >"$f"
    fi
  else
    if [[ -f $f ]]; then
      { printf '%s\n' "$v"; tail -n +2 "$f"; } >"$f.new"
      replace_file "$f"
    else
      printf '%s\n' "$v" >"$f"
    fi
  fi
}

# set_version VERSION: write it into the kind's source; prints the files it changed, one per line.
set_version() {
  local v=$1 d f code
  d=$(pdir)
  case $OPT_KIND in
    zephyr | espidf | pio | arm-gcc | circuitpython | silabs | go | docker | cloud-worker | web-pages | hardware | altium | mechanical)
      f=$(plain_file)
      if [[ -z $f ]]; then
        f="$d/VERSION"
        if [[ $OPT_KIND == hardware && -n $(hw_pcb) ]]; then
          log_info "$OPT_PART: no $d/VERSION: created it (the revision was in the title block of $(basename "$(hw_pcb)"), which is left as it is)"
        else
          log_info "$OPT_PART: created $f"
        fi
        if [[ $OPT_KIND == zephyr ]]; then write_plain "$f" "$v" 1; else write_plain "$f" "$v" 0; fi
      elif grep -q '^VERSION_MAJOR' "$f"; then
        write_plain "$f" "$v" 1
      else
        write_plain "$f" "$v" 0
      fi
      printf '%s\n' "$f"
      ;;
    app-flutter)
      f="$d/pubspec.yaml"
      [[ -f $f ]] || die "$OPT_PART: no $f"
      awk -v v="$v" '
        !done && /^version:/ { b = $0; n = ""; if (b ~ /\+[0-9]+/) { sub(/^[^+]*\+/, "", b); sub(/[^0-9].*$/, "", b); n = "+" (b + 1) }
          print "version: " v n; done = 1; next }
        { print }
        END { if (!done) exit 3 }' "$f" >"$f.new" || { rm -f "$f.new"; die "$OPT_PART: no version: line in $f"; }
      replace_file "$f"
      printf '%s\n' "$f"
      ;;
    app-tauri)
      tauri_set_version "$v"
      ;;
    app-android)
      f=$(gradle_file)
      [[ -f $f ]] || die "$OPT_PART: no $f"
      code=$(sed -nE 's/.*versionCode[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$f" | head -n 1)
      awk -v v="$v" -v code="${code:-}" '
        !dn && /versionName[ \t]*=[ \t]*"[^"]*"/ { sub(/versionName[ \t]*=[ \t]*"[^"]*"/, "versionName = \"" v "\""); dn = 1 }
        !dc && code != "" && /versionCode[ \t]*=[ \t]*[0-9]+/ { sub(/versionCode[ \t]*=[ \t]*[0-9]+/, "versionCode = " (code + 1)); dc = 1 }
        { print }
        END { if (!dn) exit 3 }' "$f" >"$f.new" || { rm -f "$f.new"; die "$OPT_PART: no versionName = \"...\" in $f"; }
      replace_file "$f"
      printf '%s\n' "$f"
      ;;
    app-xcode)
      have xcrun || die "$OPT_PART: the version of an Xcode project is set with agvtool (xcrun), which this machine does not have: bump it on a Mac with Xcode"
      (cd "$d" && xcrun agvtool new-marketing-version "$v" >/dev/null && xcrun agvtool next-version -all >/dev/null) ||
        die "$OPT_PART: agvtool could not set the version (the project needs Versioning System: Apple Generic)"
      git diff --name-only -- "$d"
      ;;
    python)
      f="$d/pyproject.toml"
      [[ -f $f ]] || die "$OPT_PART: no $f"
      awk -v v="$v" '
        /^\[/ { sec = $0 }
        !done && (sec == "[project]" || sec == "[tool.poetry]") && /^version[ \t]*=/ { print "version = \"" v "\""; done = 1; next }
        { print }
        END { if (!done) exit 3 }' "$f" >"$f.new" || { rm -f "$f.new"; die "$OPT_PART: no version = \"...\" in [project] of $f"; }
      replace_file "$f"
      printf '%s\n' "$f"
      ;;
    *) die "kind '$OPT_KIND' has no version source" ;;
  esac
}

# --- CHANGELOG ------------------------------------------------------------------------------------

changelog() { printf '%s\n' "$(pdir)/CHANGELOG.md"; }

# section FILE NAME: the lines of the "## [NAME]" section (case-insensitive for Unreleased), without
# the heading; exit 3 when there is no such section.
section() {
  awk -v want="$2" '
    function key(h) { sub(/^##[ \t]+/, "", h); sub(/^\[/, "", h); sub(/[] \t].*$/, "", h); return tolower(h) }
    /^## / { if (inside) exit; if (key($0) == tolower(want)) { inside = 1; found = 1; next } }
    inside { print }
    END { if (!found) exit 3 }
  ' "$1"
}

# trim: drop leading and trailing blank lines.
trim() {
  awk '{ l[NR] = $0 } END { s = 1; while (s <= NR && l[s] ~ /^[ \t]*$/) s++; e = NR; while (e >= s && l[e] ~ /^[ \t]*$/) e--; for (i = s; i <= e; i++) print l[i] }'
}

# has_entries: stdin holds something besides blank lines and ### headings.
has_entries() { grep -v -E '^[[:space:]]*$|^###[[:space:]]' >/dev/null; }

# move_unreleased FILE VERSION DATE: a fresh empty Unreleased section, then the old one as VERSION.
move_unreleased() {
  local f=$1 v=$2 date=$3
  awk -v ver="$v" -v date="$date" '
    function key(h) { sub(/^##[ \t]+/, "", h); sub(/^\[/, "", h); sub(/[] \t].*$/, "", h); return tolower(h) }
    function flush(   i, j, s, e, keep, out, n) {
      # drop ### headings with nothing under them, then blank lines at both ends
      n = 0
      for (i = 1; i <= cn; i++) {
        if (c[i] ~ /^###[ \t]/) { keep = 0; for (j = i + 1; j <= cn && c[j] !~ /^###[ \t]/; j++) if (c[j] !~ /^[ \t]*$/) keep = 1
          if (!keep) { i = j - 1; continue } }
        out[++n] = c[i]
      }
      s = 1; while (s <= n && out[s] ~ /^[ \t]*$/) s++
      e = n; while (e >= s && out[e] ~ /^[ \t]*$/) e--
      print "## [Unreleased]"; print ""; print "### Added"; print ""; print "### Changed"; print ""; print "### Fixed"; print ""
      print "## [" ver "] - " date
      if (e >= s) { print ""; for (i = s; i <= e; i++) print out[i] }
      print ""
    }
    state == 0 && /^## / && key($0) == "unreleased" { state = 1; next }
    state == 1 && /^## / { flush(); state = 2 }
    state == 1 { c[++cn] = $0; next }
    { print }
    END { if (state == 1) flush(); if (state == 0) exit 3 }
  ' "$f" >"$f.new" || {
    rm -f "$f.new"
    die "$OPT_PART: no ## [Unreleased] section in $f"
  }
  # no blank line run at the end of the file
  trim <"$f.new" >"$f.trim" && mv "$f.trim" "$f.new"
  replace_file "$f"
}

# --- subcommands ----------------------------------------------------------------------------------

cmd_version() {
  need_part
  need_kind
  local v
  # the app kinds build per platform: a wrong PLATFORM is refused before anything is built
  if [[ $OPT_KIND == app-* && -n $OPT_PLATFORM ]]; then
    valid_platform "$OPT_PLATFORM" || die "PLATFORM=$OPT_PLATFORM: use macos, ios, android, linux-amd64, linux-arm64, windows-x64, windows-arm64 or windows"
  fi
  v=$(current_version)
  [[ -n $v ]] || die "$OPT_PART: no version yet ($(where_version)): make $OPT_PART-bump VERSION=x.y.z sets the first one"
  printf '%s\n' "$v"
}

where_version() {
  case $OPT_KIND in
    app-flutter) echo "pubspec.yaml" ;;
    app-tauri) echo "src-tauri/tauri.conf.json" ;;
    app-android) echo "app/build.gradle.kts versionName" ;;
    app-xcode) echo "the marketing version" ;;
    python) echo "pyproject.toml" ;;
    hardware) echo "$(pdir)/VERSION or the title block rev" ;;
    *) echo "$(pdir)/VERSION" ;;
  esac
}

cmd_bump() {
  need_part
  need_kind
  local cur new tag cl unrel files f date branch
  git rev-parse --git-dir >/dev/null 2>&1 || die "$OPT_PART: not a git repository: a release is a commit and a tag"
  cur=$(current_version)
  if [[ -n $OPT_VERSION ]]; then
    valid_version "$OPT_VERSION" || die "VERSION=$OPT_VERSION: use 1 to 3 numbers with dots and an optional -prerelease (1.4.0, 2, 1.5.0-rc1)"
    new=$OPT_VERSION
  else
    case $OPT_LEVEL in
      patch | minor | major) ;;
      '') die "LEVEL=patch, minor or major (or VERSION=x.y.z) is required" ;;
      *) die "LEVEL=$OPT_LEVEL: use patch, minor or major" ;;
    esac
    if [[ -z $cur ]]; then
      if is_board_kind; then cur=0; else cur=0.0.0; fi
    else
      valid_version "$cur" || die "$OPT_PART: the current version '$cur' is not x.y.z: give the new one with VERSION="
    fi
    new=$(next_version "$cur" "$OPT_LEVEL")
  fi
  [[ $new != "$cur" ]] || die "$OPT_PART is already at $new"
  tag="$OPT_PART-v$new"
  ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 || die "tag $tag exists already: pick another version"

  cl=$(changelog)
  [[ -f $cl ]] || die "$OPT_PART: no $cl: the release notes come from it (the project-standard skill writes it)"
  unrel=$(section "$cl" Unreleased) || die "$OPT_PART: no ## [Unreleased] section in $cl"
  if ! printf '%s\n' "$unrel" | has_entries; then
    ((OPT_FORCE == 1)) || die "$OPT_PART: the Unreleased section of $cl is empty: write what changed first (FORCE=1 releases without notes)"
    log_warn "$OPT_PART: releasing $new with an empty Unreleased section (FORCE=1)"
  fi

  files=$(set_version "$new")
  date=$(date +%Y-%m-%d)
  move_unreleased "$cl" "$new" "$date"
  files="$files"$'\n'"$cl"

  # stage and commit only these files, by name (part dirs and these names have no spaces)
  set --
  for f in $files; do
    set -- "$@" "$f"
  done
  git add -- "$@"
  git commit -q -m "$OPT_PART: release $new" -- "$@"
  git tag -a "$tag" -m "$OPT_PART $new"
  log_ok "$OPT_PART: ${cur:-none} -> $new, committed $(printf '%s ' "$@")and tagged $tag"
  branch=$(git branch --show-current 2>/dev/null || true)
  log_info "nothing is pushed. Publish the release with: make release-push (the branch, then each new tag on its own)"
  [[ -n $branch ]] || log_warn "HEAD is not on a branch: check out the branch first"
}

cmd_notes() {
  need_part
  need_version
  local cl body
  cl=$(changelog)
  [[ -f $cl ]] || die "$OPT_PART: no $cl"
  body=$(section "$cl" "$OPT_VERSION") || die "$OPT_PART: no ## [$OPT_VERSION] section in $cl"
  printf '%s\n' "$body" | trim
}

sha256() {
  if have sha256sum; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

cmd_sums() {
  [[ -n $OPT_DIR && -d $OPT_DIR ]] || die "--dir must be an existing folder"
  local name=SHA256SUMS
  if [[ -n $OPT_PLATFORM ]]; then
    valid_platform "$OPT_PLATFORM" || die "--platform $OPT_PLATFORM: use macos, ios, android, linux-amd64, linux-arm64, windows-x64, windows-arm64 or windows"
    name="SHA256SUMS-$OPT_PLATFORM"
  fi
  (
    cd "$OPT_DIR"
    set --
    for f in *; do
      case $f in SHA256SUMS | SHA256SUMS-*) continue ;; esac
      [[ -f $f ]] && set -- "$@" "$f"
    done
    (($# > 0)) || die "no files in $OPT_DIR"
    sha256 "$@" >"$name.new"
    mv "$name.new" "$name"
  )
  log_ok "$name in $OPT_DIR"
}

cmd_zip() {
  [[ -n $OPT_FROM && -d $OPT_FROM ]] || die "--from must be an existing folder"
  [[ -n $OPT_TO ]] || die "--to is required"
  local to
  to="$(cd "$(dirname "$OPT_TO")" && pwd)/$(basename "$OPT_TO")"
  rm -f "$to"
  (
    cd "$OPT_FROM"
    set --
    for f in * .[!.]*; do
      [[ -e $f ]] || continue
      case $f in release | node_modules | .git) continue ;; esac
      set -- "$@" "$f"
    done
    (($# > 0)) || die "$OPT_FROM is empty"
    if have zip; then
      zip -q -r -X -y "$to" "$@"
    else
      python3 -m zipfile -c "$to" "$@"
    fi
  )
}

cmd_gate() {
  need_part
  need_version
  local tag="$OPT_PART-v$OPT_VERSION"
  if in_ci; then
    if [[ ${GITHUB_REF_TYPE:-} == tag && -n ${GITHUB_REF_NAME:-} ]]; then
      case $GITHUB_REF_NAME in
        "$OPT_PART"-v[0-9]*) ;;
        *)
          log_info "$OPT_PART: tag $GITHUB_REF_NAME is not a $OPT_PART release, nothing to do"
          exit 3
          ;;
      esac
      [[ $GITHUB_REF_NAME == "$tag" ]] ||
        die "$OPT_PART: tag $GITHUB_REF_NAME does not match the version of $OPT_PART ($OPT_VERSION): tag with make $OPT_PART-bump"
      return 0
    fi
    die "$OPT_PART: a GitHub Release is made only by the release workflow of a $OPT_PART-v* tag"
  fi
  if ((OPT_FORCE == 1)); then
    log_warn "$OPT_PART: releasing $OPT_VERSION from this machine (FORCE=1); the tag $tag must be on GitHub for the Release"
    return 0
  fi
  die "$OPT_PART: the GitHub Release is made by the release workflow of tag $tag (make $OPT_PART-bump, then push the tag); FORCE=1 makes it from here"
}

# --- GitHub ---------------------------------------------------------------------------------------

# in_ci: a GitHub Actions run (GitHub sets GITHUB_ACTIONS on every job).
in_ci() { [[ -n ${GITHUB_ACTIONS:-} ]]; }

need_gh() { have gh || die "gh not found: brew install gh (and gh auth login)"; }

# gh_cli ARGS...: gh for the repo of the workflow (GITHUB_REPOSITORY) in CI; on a Mac gh infers the repo from the
# checkout's origin remote, so no flag is added there.
gh_cli() {
  if [[ -n ${GITHUB_REPOSITORY:-} ]]; then
    gh "$@" --repo "$GITHUB_REPOSITORY"
  else
    gh "$@"
  fi
}

# unlinked_file NAME: never on the public Release (since v9): the Play bundle and the R8 mapping. They are left in --dir,
# and the workflow uploads them as workflow artifacts (retention 7 days); the store and crash tools take them from there.
unlinked_file() {
  case $1 in
    *.aab | *-mapping.txt) return 0 ;;
  esac
  return 1
}

# asset_files: the linked files of --dir (every regular file but the unlinked ones) go to $WORK/assets.txt, one name per
# line. Each unlinked file is printed on stdout as "unlinked: NAME" for the workflow.
asset_files() {
  : >"$WORK/assets.txt"
  ((OPT_NOTES_ONLY == 0)) || return 0
  [[ -n $OPT_DIR && -d $OPT_DIR ]] || die "--dir $OPT_DIR is not a folder: run make $OPT_PART-release-assets"
  local f
  : >"$WORK/assets.txt"
  for f in "$OPT_DIR"/*; do
    [[ -f $f ]] || continue
    f=$(basename "$f")
    if unlinked_file "$f"; then
      printf 'unlinked: %s\n' "$f"
    else
      printf '%s\n' "$f" >>"$WORK/assets.txt"
    fi
  done
  [[ -s $WORK/assets.txt ]] || die "no release assets in $OPT_DIR"
}

# build_note_text: this run's build line (the first line of --build-note-file), empty when there is none.
build_note_text() {
  if [[ -n $OPT_BUILD_NOTE_FILE && -f $OPT_BUILD_NOTE_FILE ]]; then
    head -n 1 "$OPT_BUILD_NOTE_FILE"
  fi
}

# builds_of FILE: the "- platform: text" lines under "### Builds" of the Release body in FILE (none when unreadable).
builds_of() {
  [[ -s $1 ]] || return 0
  sed -n '/^### Builds$/,$p' "$1" | sed '1d' | grep '^- ' || true
}

# description_for NOTES OLD_FILE: the body to write. The CHANGELOG notes, then a "### Builds" section with one
# "- platform: text" line per platform: the lines of the Release body in OLD_FILE (another platform's job wrote them)
# and this run's line from --build-note-file, which replaces an older line of the same platform.
description_for() {
  local notes=$1 old=$2 builds='' bnote key
  builds=$(builds_of "$old")
  bnote=$(build_note_text)
  if [[ -n $bnote ]]; then
    key=${bnote%%:*}
    builds=$(printf '%s\n' "$builds" | grep -v "^- $key:" || true)
    builds=$(printf '%s\n%s' "$builds" "- $bnote" | sed '/^$/d')
  fi
  if [[ -n $builds ]]; then
    printf '%s\n\n### Builds\n%s\n' "$notes" "$builds"
  else
    printf '%s\n' "$notes"
  fi
}

# builds_kept BEFORE AFTER KEY: every build line of BEFORE, except the platform KEY's own, is still in AFTER.
builds_kept() {
  local l
  while IFS= read -r l; do
    [[ -z $l ]] && continue
    if [[ -n $3 ]]; then
      case $l in "- $3:"*) continue ;; esac
    fi
    printf '%s\n' "$2" | grep -Fxq -- "$l" || return 1
  done < <(printf '%s\n' "$1")
  return 0
}

# update_release TAG NAME NOTES: the existing Release gets its name and body (the build lines of the other platforms
# kept, this run's line in), then the linked files are uploaded over the old ones.
update_release() {
  local tag=$1 name=$2 notes=$3 bnote key try f
  bnote=$(build_note_text)
  key=${bnote%%:*}
  for try in 1 2 3; do
    gh_cli release view "$tag" --json body --jq .body >"$WORK/old.md" 2>/dev/null || die "could not read the release $tag"
    description_for "$notes" "$WORK/old.md" >"$WORK/notes.md"
    gh_cli release edit "$tag" --title "$name" --notes-file "$WORK/notes.md" >/dev/null || die "could not update the release $tag"
    # another job may write its build line between our read and our edit, and our edit then drops it: read the body back
    # and, when a line is gone, go round again with what is there now (three tries at most)
    gh_cli release view "$tag" --json body --jq .body >"$WORK/after.md" 2>/dev/null || break
    if builds_kept "$(builds_of "$WORK/old.md")" "$(builds_of "$WORK/after.md")" "$key" &&
      { [[ -z $bnote ]] || grep -Fxq -- "- $bnote" "$WORK/after.md"; }; then
      break
    fi
    log_info "$OPT_PART: a build line of the Release was overwritten meanwhile: writing it again (try $try)"
    sleep "$try"
  done
  if [[ ! -s $WORK/assets.txt ]]; then
    log_ok "release $tag updated: the notes only, no files"
    return 0
  fi
  set --
  while IFS= read -r f; do set -- "$@" "$OPT_DIR/$f"; done <"$WORK/assets.txt"
  gh_cli release upload "$tag" --clobber "$@" >/dev/null || die "could not upload the assets to $tag"
  log_ok "release $tag updated: $(wc -l <"$WORK/assets.txt" | tr -d ' ') assets"
}

cmd_create() {
  need_part
  need_version
  need_gh
  local tag name notes attempt
  tag="$OPT_PART-v$OPT_VERSION"
  name="$OPT_PART $OPT_VERSION"
  notes=$(cmd_notes)
  asset_files
  # The Release is made first with its notes only: a Release created with its assets can be a draft that the next
  # view does not see yet. Two platform jobs can create it at the same moment: the second create is refused, which is
  # fine, because update_release below then writes the notes and uploads the assets (--clobber) either way.
  for attempt in 1 2 3; do
    if gh_cli release view "$tag" --json body >/dev/null 2>&1; then
      break
    fi
    description_for "$notes" /dev/null >"$WORK/notes.md"
    # --latest=false (since v20): GitHub's Latest badge belongs to the latest Release, which holds every part
    if gh_cli release create "$tag" --title "$name" --notes-file "$WORK/notes.md" --verify-tag --latest=false >/dev/null 2>&1; then
      log_ok "release $tag created: \"$name\""
      break
    fi
    log_info "$OPT_PART: the release $tag could not be created; checking whether another job made it (try $attempt)"
    sleep $((attempt * 2))
  done
  update_release "$tag" "$name" "$notes"
  # From a Mac (FORCE=1, the macOS app build) no workflow job follows, so the latest Release is brought up to date here.
  # In CI the release workflow's latest job does it once the part's jobs are done.
  # Its own process, so a failure there leaves this (done) Release alone and only warns.
  if ! in_ci && [[ -n $OPT_KIND ]]; then
    bash "${BASH_SOURCE[0]}" latest-sync --part "$OPT_PART" --kind "$OPT_KIND" --version "$OPT_VERSION" \
      ${OPT_PROJECT:+--project "$OPT_PROJECT"} || log_warn "$OPT_PART: the latest Release was not updated: make $OPT_PART-release-latest"
  fi
}

# --- the latest Release (since v20) ---------------------------------------------------------------
# GitHub marks one Release of a repository "Latest". The Release on the tag "latest" holds the newest files of every
# part and carries that badge (the part Releases are made with --latest=false). Its files keep their names from one
# version to the next, so a link to .../releases/download/latest/<file> always gets the newest:
#   the version is taken out of the name (app-1.0.0-linux-amd64.deb -> app-linux-amd64.deb) and the group is put in
#   front when the name does not start with it (rev4-firmware.bin -> firmware-rev4-firmware.bin).
# A group is the part, or for a hardware, altium or mechanical part the part and its major version (hardware-v3,
# hardware-v4): each board revision keeps its own files. The part's SHA256SUMS files are left out; <group>-SHA256SUMS checks the group's files
# under their new names. The Release body is a table of the groups, and one line per group that this script reads back:
#   <!-- latest GROUP VERSION DATE TAG URL FILE... -->

LATEST_TAG=latest

# ver_lt A B: version A is older than B (numeric, component by component; a missing component is 0).
ver_lt() {
  local a b c a1 b1 c1
  split_version "$1"
  a1=$a b1=${b:-0} c1=${c:-0}
  split_version "$2"
  b=${b:-0} c=${c:-0}
  ((a1 != a)) && { ((a1 < a)); return; }
  ((b1 != b)) && { ((b1 < b)); return; }
  ((c1 < c))
}

latest_group() {
  if is_board_kind; then
    printf '%s-v%s\n' "$OPT_PART" "${OPT_VERSION%%.*}"
  else
    printf '%s\n' "$OPT_PART"
  fi
}

# latest_name FILE GROUP: the file's name in the latest Release.
latest_name() {
  local n=$1 v=$OPT_VERSION p
  for p in "-v$v" "_v$v" "-$v" "_$v" ".v$v" ".$v"; do
    n=${n//"$p"/}
  done
  [[ $n == "$2"-* ]] || n="$2-$n"
  printf '%s\n' "$n"
}

# latest_marker GROUP: "VERSION DATE TAG URL FILE..." of the group in $WORK/latest.md (nothing when it has none).
latest_marker() {
  awk -v g="$1" '$1 == "<!--" && $2 == "latest" && $3 == g { s = $4; for (i = 5; i < NF; i++) s = s " " $i; print s; exit }' "$WORK/latest.md"
}

# latest_body MARKERS URL: the latest Release's body, from the marker lines in the file MARKERS (sorted by group).
latest_body() {
  local base=${2%/tag/*}/download/$LATEST_TAG
  printf 'The newest release of each part, with its files. A file keeps its name from one version to the next, so a link to it\n'
  # shellcheck disable=SC2016 # the backticks are Markdown
  printf 'always gets the newest: `%s/<file>`. `<part>-SHA256SUMS` checks the files of a part.\n\n' "$base"
  printf '| Part | Version | Released | Release |\n|---|---|---|---|\n'
  awk '{ printf "| %s | %s | %s | [%s](%s) |\n", $3, $4, $5, $6, $7 }' "$1"
  printf '\n'
  cat "$1"
}

# latest-sync --part P --kind K --version V [--project NAME]: copy the files of the published Release <part>-v<V> into the
# latest Release (made when missing, titled "<project> latest"), replacing the group's older files, and give it the
# Latest badge. A draft or a pre-release is left out, and so is a version older than the one the group has.
cmd_latest_sync() {
  need_part
  need_version
  need_gh
  local tag="$OPT_PART-v$OPT_VERSION" group info draft pre url date nassets cur old f n names have=0 project
  project=${OPT_PROJECT:-$(basename "$PWD")}
  if [[ $OPT_VERSION == *-* ]]; then
    log_info "$tag is a pre-release: the latest Release keeps what it has"
    return 0
  fi
  group=$(latest_group)
  info=$(gh_cli release view "$tag" --json isDraft,isPrerelease,url,publishedAt,assets \
    --jq '"\(.isDraft) \(.isPrerelease) \(.url) \(.publishedAt) \(.assets | length)"' 2>/dev/null) ||
    die "no Release $tag to copy into the latest Release (make $OPT_PART-github-release makes it)"
  # shellcheck disable=SC2086 # five words, split on purpose
  set -- $info
  draft=$1 pre=$2 url=$3 date=${4%%T*} nassets=${5:-}
  if [[ $draft != false || $pre != false ]]; then
    log_info "$tag is a draft or a pre-release: the latest Release keeps what it has"
    return 0
  fi
  # a Release with the notes only (cloud-worker, web-pages): nothing to copy, and gh release download refuses it
  if [[ $nassets == 0 ]]; then
    log_info "$tag has no files: the latest Release keeps what it has"
    return 0
  fi
  if gh_cli release view "$LATEST_TAG" --json body --jq .body >"$WORK/latest.md" 2>/dev/null; then have=1; else : >"$WORK/latest.md"; fi
  cur=$(latest_marker "$group")
  if [[ -n $cur ]] && ver_lt "$OPT_VERSION" "${cur%% *}"; then
    log_info "the latest Release has $group ${cur%% *}, newer than $OPT_VERSION: unchanged"
    return 0
  fi
  # shellcheck disable=SC2086 # the marker's words
  old=$( (set -- $cur && shift 4 && printf '%s\n' "$@") 2>/dev/null || true)

  mkdir -p "$WORK/dl" "$WORK/up"
  gh_cli release download "$tag" --dir "$WORK/dl" >/dev/null || die "could not download the files of $tag"
  for f in "$WORK/dl"/*; do
    [[ -f $f ]] || continue
    f=$(basename "$f")
    case $f in SHA256SUMS | SHA256SUMS-*) continue ;; esac
    n=$(latest_name "$f" "$group")
    [[ $n != *[[:space:]]* ]] || die "$tag has a file with a space in its name ($f): the latest Release lists names by spaces"
    [[ ! -e $WORK/up/$n ]] || die "two files of $tag would both be $n in the latest Release"
    cp "$WORK/dl/$f" "$WORK/up/$n"
  done
  names=$(cd "$WORK/up" && /bin/ls)
  if [[ -z $names ]]; then
    log_info "$tag has no files: the latest Release keeps what it has"
    return 0
  fi
  (
    cd "$WORK/up"
    set -- *
    sha256 "$@" >"$group-SHA256SUMS"
  )
  names=$(cd "$WORK/up" && /bin/ls)

  if ((have == 0)); then
    gh_cli release create "$LATEST_TAG" --title "$project latest" --notes "The newest release of each part." --latest >/dev/null ||
      die "could not create the latest Release"
    log_ok "release $LATEST_TAG created: \"$project latest\""
  fi
  set --
  while IFS= read -r f; do set -- "$@" "$WORK/up/$f"; done < <(printf '%s\n' "$names")
  gh_cli release upload "$LATEST_TAG" --clobber "$@" >/dev/null || die "could not upload the files of $tag to the latest Release"
  # the group's files of the version it replaces that this version does not have
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    printf '%s\n' "$names" | grep -Fxq -- "$f" && continue
    gh_cli release delete-asset "$LATEST_TAG" "$f" --yes >/dev/null 2>&1 || log_warn "could not remove $f from the latest Release"
  done < <(printf '%s\n' "$old")

  {
    awk -v g="$group" '$1 == "<!--" && $2 == "latest" && $3 != g' "$WORK/latest.md"
    printf '<!-- latest %s %s %s %s %s %s -->\n' "$group" "$OPT_VERSION" "$date" "$tag" "$url" "$(printf '%s\n' "$names" | tr '\n' ' ' | sed 's/ $//')"
  } | sort -k3,3 >"$WORK/markers"
  latest_body "$WORK/markers" "$url" >"$WORK/body.md"
  gh_cli release edit "$LATEST_TAG" --title "$project latest" --notes-file "$WORK/body.md" --latest >/dev/null ||
    die "could not update the latest Release"
  log_ok "latest Release: $group $OPT_VERSION ($(printf '%s\n' "$names" | wc -l | tr -d ' ') files)"
}

# push: publish what bump made. The current branch first, then every release tag (<part>-v<version>) reachable from HEAD
# that origin does not have, each in its own push: GitHub starts no workflow for the tags of a push that carries more
# than three, so pushing several tags at once would release nothing. A tag origin already has with the same commit is
# skipped; with another commit it is refused (move it on purpose, by hand).
cmd_push() {
  local branch remote_tags t mine theirs n=0
  branch=$(git branch --show-current 2>/dev/null || true)
  [[ -n $branch ]] || die "HEAD is not on a branch: check out the branch the release commits are on"
  git push origin "$branch"
  remote_tags=$(git ls-remote --tags origin 2>/dev/null || true)
  for t in $(git tag --merged HEAD --list '*-v[0-9]*'); do
    mine=$(git rev-parse "refs/tags/$t^{commit}")
    theirs=$(printf '%s\n' "$remote_tags" | awk -v r="refs/tags/$t^{}" '$2 == r { print $1; exit }')
    [[ -n $theirs ]] || theirs=$(printf '%s\n' "$remote_tags" | awk -v r="refs/tags/$t" '$2 == r { print $1; exit }')
    if [[ -n $theirs ]]; then
      [[ $theirs == "$mine" ]] || die "tag $t is on origin with another commit ($theirs): move it on purpose, by hand"
      continue
    fi
    git push origin "refs/tags/$t"
    log_ok "pushed $t: its release workflow starts"
    n=$((n + 1))
    sleep 2
  done
  ((n > 0)) || log_info "no new release tag to push"
}

# latest [--part P]: the newest published Release (no drafts, no pre-releases) of part P, or of every part that has a
# release tag (<part>-v<version>), one line each: part, name, date, page. GitHub marks only one Release of a repository
# "Latest" (the newest of any part), so a project with several parts asks here for each part's.
cmd_latest() {
  local rows best
  need_gh
  rows=$(gh_cli release list --limit 200 --exclude-drafts --exclude-pre-releases \
    --json tagName,name,publishedAt --jq '.[] | "\(.tagName)\t\(.name)\t\(.publishedAt)"') ||
    die "could not list the Releases (gh auth status, and is this the project's checkout?)"
  best=$(printf '%s\n' "$rows" | awk -F '\t' -v want="$OPT_PART" '
    NF >= 3 {
      p = $1; sub(/-v[0-9][^-]*.*$/, "", p)
      if (p == $1 || (want != "" && p != want)) next
      if (!(p in d) || $3 > d[p]) { d[p] = $3; line[p] = p "\t" $1 "\t" $2 "\t" $3 }
    }
    END { for (p in line) print line[p] }' | sort)
  if [[ -z $best ]]; then
    if [[ -n $OPT_PART ]]; then log_info "no published Release of $OPT_PART yet"; else log_info "no published Release yet"; fi
    return 0
  fi
  printf '%s\n' "$best" | while IFS="$(printf '\t')" read -r part tag name date; do
    [[ -n $tag ]] || continue
    printf '%-14s %-22s %s  %s\n' "$part" "$name" "${date%%T*}" "$(gh_cli release view "$tag" --json url --jq .url)"
  done
}

# upload: the v8 name of create, with the same arguments.
cmd_upload() {
  cmd_create
}

# --- main -----------------------------------------------------------------------------------------

main() {
  (($# > 0)) || die "usage: release.sh version|bump|notes|sums|zip|gate|upload|create|push|latest|latest-sync [options] (see the header)"
  local cmd=$1
  shift
  parse "$@"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/release.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  case $cmd in
    version) cmd_version ;;
    host-platform) host_platform ;;
    bump) cmd_bump ;;
    notes) cmd_notes ;;
    sums) cmd_sums ;;
    zip) cmd_zip ;;
    gate) cmd_gate ;;
    upload) cmd_upload ;;
    create) cmd_create ;;
    push) cmd_push ;;
    latest) cmd_latest ;;
    latest-sync) cmd_latest_sync ;;
    *) die "unknown subcommand '$cmd'" ;;
  esac
}

main "$@"
