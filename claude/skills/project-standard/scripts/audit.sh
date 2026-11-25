#!/usr/bin/env bash
# audit.sh: report how a project deviates from the project-standard layout. Read-only.
#
#   audit.sh <dir> [--json]
#
# Exit 0 when the project is standard and current, 1 when there is any deviation, 2 on bad usage.
# For a project that is not standard yet it also lists the make targets its Makefiles define today,
# so adopt can build the old -> new command table.
set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly SKILL_DIR
readonly TPL_MAKE="$SKILL_DIR/templates/make"
readonly TPL_PROJECT="$SKILL_DIR/templates/project"
readonly KINDS="zephyr espidf pio arm-gcc circuitpython silabs hardware altium mechanical cloud-worker web-pages app-flutter app-tauri app-xcode app-android docker go python"
# 3D and CAD models in Git LFS. Every project has a line for each of LFS_EXTS but wrl, which only a KiCad board (kind
# hardware) needs (1.2: KiCad's VRML models).
readonly LFS_EXTS="step stp wrl fcstd"
# Altium Designer's binary documents (a .PrjPcb project file and an ASCII-saved document are text): Git LFS only. The
# .PrjPcbVariants is an OLE compound file (1.2).
readonly ALTIUM_BIN_EXTS="SchDoc PcbDoc SchLib PcbLib IntLib Harness PcbDwf PrjPcbVariants"
# An altium part's .gitattributes lines (templates/altium/gitattributes): these binaries in LFS, and the project and
# OutJob, CRLF text Altium writes (the .PrjPcb with a UTF-8 BOM), -text so they stay byte-exact (1.2).
readonly ALTIUM_LFS_EXTS="SchDoc PcbDoc SchLib PcbLib IntLib Harness PrjPcbVariants"
readonly ALTIUM_TEXT_EXTS="PrjPcb OutJob"
# Managed files a version removed: a project that still has one is outdated (make/bin/refs.sh: 1.2, references are links).
readonly REMOVED_MANAGED="make/bin/refs.sh"
# routed to LFS before 1.1; small files now stay in plain git
readonly OLD_LFS_EXTS="png mp4 zip hex"
# Binary documents are never committed (docs are Markdown); .gitignore ignores them and no LFS line routes them.
readonly BIN_DOC_EXTS="pdf doc docx xls xlsx ppt pptx odt ods odp"
readonly PRUNE_DIRS=".git node_modules .wrangler build .pio .venv __pycache__ DerivedData .gradle .dart_tool target managed_components dist outputs Pods"

usage() {
  echo "usage: audit.sh <dir> [--json]" >&2
  exit 2
}

DIR=''
JSON=0
while (($# > 0)); do
  case $1 in
    --json) JSON=1 ;;
    -h | --help)
      echo "usage: audit.sh <dir> [--json]"
      exit 0
      ;;
    -*) usage ;;
    *)
      [[ -z $DIR ]] || usage
      DIR=$1
      ;;
  esac
  shift
done
[[ -n $DIR ]] || usage
[[ -d $DIR ]] || {
  echo "audit.sh: $DIR is not a folder" >&2
  exit 2
}
DIR=$(cd "$DIR" && pwd)

CURRENT_VERSION=1
if [[ -f "$TPL_PROJECT/make/VERSION" ]]; then
  CURRENT_VERSION=$(tr -d '[:space:]' <"$TPL_PROJECT/make/VERSION")
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/audit.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------------
# findings: one record per line in $WORK/findings, fields separated by US (\037)

readonly US=$'\037'
: >"$WORK/findings"
: >"$WORK/targets"

# add SEVERITY AREA PATH MESSAGE FIX   (severity: error | warn | outdated)
add() {
  printf '%s%s%s%s%s%s%s%s%s\n' "$1" "$US" "$2" "$US" "$3" "$US" "$4" "$US" "$5" >>"$WORK/findings"
}

# ---------------------------------------------------------------------------------------------
# file listing

IS_GIT=0
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT=1
fi

# all_files: tracked plus untracked-but-not-ignored (git), or a pruned find; NUL-separated, relative.
all_files() {
  if ((IS_GIT == 1)); then
    git -C "$DIR" -c core.quotepath=off ls-files -z --cached --others --exclude-standard
  else
    local expr=() d
    for d in $PRUNE_DIRS; do
      expr+=(-name "$d" -o)
    done
    (cd "$DIR" && find . \( -type d \( "${expr[@]}" -false \) -prune \) -o -type f -print0) |
      while IFS= read -r -d '' f; do printf '%s\0' "${f#./}"; done
  fi
}

# tracked_files: what git tracks; without git, every file (reported as "present").
tracked_files() {
  if ((IS_GIT == 1)); then
    git -C "$DIR" -c core.quotepath=off ls-files -z --cached
  else
    all_files
  fi
}

all_files | tr '\0' '\n' | sed '/^$/d' | sort -u >"$WORK/files"
tracked_files | tr '\0' '\n' | sed '/^$/d' | sort -u >"$WORK/tracked"

# ---------------------------------------------------------------------------------------------
# helpers

has_header() {
  # has_header FILE: `project-standard v<N>` on line 1 or 2
  head -n 2 "$1" 2>/dev/null | grep -Eq 'project-standard v[0-9]+'
}

header_version() {
  head -n 2 "$1" 2>/dev/null | sed -n 's/.*project-standard v\([0-9][0-9]*\(\.[0-9][0-9]*\)*\).*/\1/p' | sed -n 1p
}

# sq TEXT: TEXT as one single-quoted shell word, so a suggested command survives spaces and quotes in paths.
sq() {
  local q="'\\''"
  printf "'%s'" "${1//\'/$q}"
}

# slug NAME: a folder name in lowercase kebab: capitals lowered with no split inside a word (SiLabs SiWG917 ->
# silabs-siwg917), dots dropped (SimCOM M.2 -> simcom-m2), every run of other characters (spaces, underscores) one -.
slug() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '.' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')
  [[ -n $s ]] || s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  printf '%s' "$s"
}

# make_var FILE NAME: the value of a make variable assignment, continuation lines joined,
# comments removed. Several assignments (+=) are concatenated.
make_var() {
  awk -v name="$2" '
    {
      line = $0
      if (cont) buf = buf " " line; else buf = line
      if (buf ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", buf); cont = 1; next }
      cont = 0
      re = "^[ \t]*" name "[ \t]*(:|\\+|\\?)?="
      if (buf ~ re) {
        v = buf
        sub(re, "", v)
        sub(/#.*/, "", v)
        out = out " " v
      }
    }
    END { gsub(/[ \t]+/, " ", out); sub(/^ /, "", out); sub(/ $/, "", out); print out }
  ' "$1"
}

# config_value NAME: NAME from the environment, else from the user config (the same reads as scaffold.sh).
config_value() {
  local name=$1 cfg val
  val=$(printenv "$name" || true)
  if [[ -n $val ]]; then
    printf '%s\n' "$val"
    return 0
  fi
  cfg="${STD_CONFIG:-$HOME/.config/project-standard}/config.mk"
  if [[ -f $cfg ]]; then
    sed -n "s/^[[:space:]]*${name}[[:space:]]*[:?]*=[[:space:]]*\\([^[:space:]#]*\\).*/\\1/p" "$cfg" | tail -n 1
  fi
}

# The repository of the reusable workflows when nothing sets CI_TEMPLATES_REPO (the same as scaffold.sh, 1.7).
readonly CI_TEMPLATES_DEFAULT=mayankgautam-me/ci-templates

# ci_project: the repository of the reusable workflows (owner/name), independent of GITHUB_OWNER: CI_TEMPLATES_REPO
# from make/project.mk, else from the environment or the user config, else CI_TEMPLATES_DEFAULT.
ci_project() {
  local val=''
  if [[ -f "$DIR/make/project.mk" ]]; then
    val=$(make_var "$DIR/make/project.mk" CI_TEMPLATES_REPO)
    val=${val##* }
  fi
  [[ -n $val ]] || val=$(config_value CI_TEMPLATES_REPO)
  printf '%s\n' "${val:-$CI_TEMPLATES_DEFAULT}"
}

# The docs a part of kind K has under docs/<part>/ (the same table as scaffold.sh).
kind_docs() {
  case $1 in
    zephyr | espidf | pio | arm-gcc | circuitpython) echo "protocol flashing" ;;
    silabs) echo "protocol flashing power" ;;
    hardware) echo "bringup manufacturing" ;;
    altium) echo "bringup manufacturing library" ;;
    mechanical) echo "assembly" ;;
    cloud-worker) echo "api data" ;;
    app-*) echo "distribution" ;;
    docker | go | python) echo "usage" ;;
    *) : ;;
  esac
}

kind_known() {
  local k
  for k in $KINDS; do
    [[ $k == "$1" ]] && return 0
  done
  return 1
}

# has_part_kind KIND: a part in PARTS has that kind.
has_part_kind() {
  local k
  for k in ${PART_KINDS[@]+"${PART_KINDS[@]}"}; do
    [[ $k == "$1" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------------------------
# 1. standard or not, and the managed files

STANDARD=0
VERSION=''
PROJECT_NAME=$(basename "$DIR")
PART_NAMES=()
PART_KINDS=()
PART_DIRS=()

if [[ -f "$DIR/make/common.mk" ]] && has_header "$DIR/make/common.mk"; then
  STANDARD=1
  VERSION=$(header_version "$DIR/make/common.mk")
else
  add error standard . "not a project-standard project (no managed make/common.mk)" \
    "adopt it with the project-standard skill (adopt mode)"
fi

# compare_managed REL TEMPLATE
compare_managed() {
  local rel=$1 tpl=$2
  if [[ ! -f "$DIR/$rel" ]]; then
    add error managed "$rel" "managed file is missing" "refresh with the project-standard skill (update mode)"
    return 0
  fi
  if ! has_header "$DIR/$rel"; then
    add error managed "$rel" "managed header is missing (first line must say project-standard v$CURRENT_VERSION)" \
      "refresh it with the project-standard skill; move project changes to make/local.mk"
    return 0
  fi
  if [[ -f $tpl ]] && ! cmp -s "$DIR/$rel" "$tpl"; then
    add outdated managed "$rel" "differs from the skill's current template (outdated or edited by hand)" \
      "refresh with the project-standard skill (update mode); project changes belong in make/local.mk"
  fi
}

if ((STANDARD == 1)); then
  if [[ -n $VERSION && $VERSION != "$CURRENT_VERSION" ]]; then
    add outdated managed make/common.mk "standard v$VERSION, the skill is at v$CURRENT_VERSION" \
      "refresh with the project-standard skill (update mode)"
  fi
  compare_managed Makefile "$TPL_PROJECT/Makefile"
  compare_managed make/common.mk "$TPL_MAKE/common.mk"
  for tpl in "$TPL_MAKE"/bin/*.sh; do
    [[ -f $tpl ]] || continue
    compare_managed "make/bin/$(basename "$tpl")" "$tpl"
  done
  for rel in $REMOVED_MANAGED; do
    [[ -f "$DIR/$rel" ]] || continue
    add outdated managed "$rel" "a managed file the standard no longer has (1.2: docs/references.md is links only, nothing is downloaded)" \
      "git rm $rel (update mode)"
  done
  if [[ ! -f "$DIR/make/VERSION" ]]; then
    add error managed make/VERSION "missing" "refresh with the project-standard skill (update mode)"
  elif [[ $(tr -d '[:space:]' <"$DIR/make/VERSION") != "$CURRENT_VERSION" ]]; then
    add outdated managed make/VERSION "says $(tr -d '[:space:]' <"$DIR/make/VERSION"), the skill is at v$CURRENT_VERSION" \
      "refresh with the project-standard skill (update mode)"
  fi
  [[ -f "$DIR/make/local.mk" ]] ||
    add warn managed make/local.mk "missing (project-only targets live here)" "create it, empty, from the skill's template"
fi

# ---------------------------------------------------------------------------------------------
# 2. project.mk

if [[ -f "$DIR/make/project.mk" ]]; then
  pm="$DIR/make/project.mk"
  pname=$(make_var "$pm" PROJECT)
  pname=${pname%% *}
  if [[ -z $pname ]]; then
    add error project make/project.mk "PROJECT is not set" "set PROJECT := <name> (lowercase, the secrets folder name)"
  else
    PROJECT_NAME=$pname
    [[ $pname =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
      add warn project make/project.mk "PROJECT '$pname' is not lowercase letters, digits and '-'" "rename it"
  fi
  parts=$(make_var "$pm" PARTS)
  if [[ -z $parts ]]; then
    add error project make/project.mk "PARTS is not set" "list the parts as name:kind[:dir]"
  else
    for spec in $parts; do
      IFS=':' read -r pn pk pd _rest <<<"$spec"
      pd=${pd:-$pn}
      PART_NAMES+=("$pn")
      PART_KINDS+=("${pk:-}")
      PART_DIRS+=("$pd")
      if [[ -z ${pk:-} ]] || ! kind_known "$pk"; then
        add error project make/project.mk "part '$pn' has unknown kind '${pk:-}'" "use one of: $KINDS"
        continue
      fi
      [[ -d "$DIR/$pd" ]] ||
        add error project "$pd" "folder of part '$pn' does not exist" "create $pd/ or fix the part's dir in make/project.mk"
      if ((STANDARD == 1)); then
        compare_managed "make/kinds/$pk.mk" "$TPL_MAKE/kinds/$pk.mk"
      fi
    done
  fi
elif ((STANDARD == 1)); then
  add error project make/project.mk "missing" "write PROJECT, PORT_BASE and PARTS into make/project.mk"
fi

# A make assignment, commented out or not, with a `# comment` after its value: make keeps the spaces before the `#` in
# the value, so `X := a   # note` sets X to "a   " (once uncommented, for a commented-out one). The same check as the
# skill's own lint (tests/lint.bats, trailing_comments) since 1.2.
for mk in make/project.mk make/local.mk; do
  [[ -f "$DIR/$mk" ]] || continue
  awk '
    {
      line = $0
      sub(/^[[:space:]]*#?[[:space:]]*/, "", line)
      if (line !~ /^[A-Za-z0-9_.$(){}-]+[[:space:]]*(:|\?|\+)?=/) next
      sub(/^[^=]*=/, "", line)
      if (index(line, "#")) printf "%d\t%s\n", FNR, $0
    }
  ' "$DIR/$mk" | while IFS=$'\t' read -r ln text; do
    add warn make "$mk" "line $ln has a comment after its value: $text (make keeps the spaces before the # in the value)" \
      "put the comment on its own line above"
  done
done

# ---------------------------------------------------------------------------------------------
# 2b. hardware build outputs in git: outputs/ (make <part>-build) and production/ (make <part>-release, which
# attaches the fab zip to the GitHub Release) are generated. The hardware folders are the hardware parts'
# dirs, plus every folder with a tracked .kicad_pro (a project that is not standard yet).

if ((IS_GIT == 1)); then
  : >"$WORK/hw_dirs"
  i=0
  while ((i < ${#PART_NAMES[@]})); do
    [[ ${PART_KINDS[$i]} != hardware ]] || printf '%s\n' "${PART_DIRS[$i]}" >>"$WORK/hw_dirs"
    i=$((i + 1))
  done
  { grep -E '\.kicad_pro$' "$WORK/tracked" || true; } | while IFS= read -r f; do
    case $f in
      */*) printf '%s\n' "${f%/*}" ;;
      *) printf '.\n' ;;
    esac
  done >>"$WORK/hw_dirs"
  sort -u "$WORK/hw_dirs" | while IFS= read -r hd; do
    [[ -n $hd ]] || continue
    for sub in outputs production; do
      if [[ $hd == . ]]; then rel=$sub; else rel=$hd/$sub; fi
      n_tracked=$(awk -v p="$rel/" 'index($0, p) == 1 { n++ } END { print n + 0 }' "$WORK/tracked")
      ((n_tracked > 0)) || continue
      add warn hardware "$rel" "$n_tracked tracked file(s) in a build output folder (generated by make <part>-build / <part>-release)" \
        "git rm -r --cached $(sq "$rel") and ignore it in .gitignore ($rel/)"
    done
  done
  # every part's release files (make <part>-release-assets) are generated too: the GitHub Release keeps them
  i=0
  while ((i < ${#PART_NAMES[@]})); do
    rel="${PART_DIRS[$i]}/release"
    n_tracked=$(awk -v p="$rel/" 'index($0, p) == 1 { n++ } END { print n + 0 }' "$WORK/tracked")
    if ((n_tracked > 0)); then
      add warn release "$rel" "$n_tracked tracked file(s) in the release folder (generated by make ${PART_NAMES[$i]}-release-assets)" \
        "git rm -r --cached $(sq "$rel") and ignore it in .gitignore ($rel/)"
    fi
    i=$((i + 1))
  done
fi

# ---------------------------------------------------------------------------------------------
# 2c. each part lives in the folder of its kind (reference/standard.md section 1)

part_group() {
  case $1 in
    zephyr | espidf | pio | arm-gcc | circuitpython | silabs) printf 'firmware' ;;
    hardware | altium) printf 'hardware' ;;
    mechanical) printf 'mechanical' ;;
    cloud-worker | docker | go | python) printf 'cloud' ;;
    web-pages) printf 'web' ;;
    app-flutter | app-tauri | app-xcode | app-android) printf 'app' ;;
  esac
}

# part_group_at KIND DIR: the group of a part where it is. A go or python part under firmware/ runs on a device (an
# agent on a Linux board), so it belongs there; anywhere else it is a service under cloud/.
part_group_at() {
  case $1 in
    go | python) if [[ $2 == firmware || $2 == firmware/* ]]; then printf 'firmware'; return; fi ;;
  esac
  part_group "$1"
}

if ((STANDARD == 1)); then
  i=0
  while ((i < ${#PART_NAMES[@]})); do
    pn=${PART_NAMES[$i]} pk=${PART_KINDS[$i]} pd=${PART_DIRS[$i]}
    i=$((i + 1))
    kind_known "$pk" || continue
    g=$(part_group_at "$pk" "$pd")
    same=0
    j=0
    while ((j < ${#PART_NAMES[@]})); do
      kind_known "${PART_KINDS[$j]}" && [[ $(part_group_at "${PART_KINDS[$j]}" "${PART_DIRS[$j]}") == "$g" ]] && same=$((same + 1))
      j=$((j + 1))
    done
    expected=$g
    ((same == 1)) || expected="$g/$pn"
    if [[ $pd != "$g" && $pd != "$g"/* ]]; then
      add warn layout "$pd" "part $pn ($pk) is outside $g/" \
        "git mv $(sq "$pd") $(sq "$expected") (and the paths that name it): reference/standard.md section 1"
    elif ((same > 1)) && [[ $pd == "$g" ]]; then
      add warn layout "$pd" "part $pn ($pk) shares $g/ with other parts and needs its own subfolder $expected" \
        "git mv $(sq "$pd") $(sq "$expected") (and the paths that name it): reference/standard.md section 1"
    fi
    if ((same > 1)) && [[ $g == firmware && ( $pn == firmware || $pn == firmware-* ) ]]; then
      add warn layout "$pd" "firmware part $pn: name firmware parts for their chip when there are several" \
        "rename it for its chip (nrf9151, stm32f042): reference/standard.md section 1"
    fi
  done
fi

# ---------------------------------------------------------------------------------------------
# 3. folder names are lowercase kebab (a-z, 0-9 and -), at every depth outside code. The rule:
#   - a name with capitals, spaces, dots, underscores or other characters is reported, with the slug to rename it to;
#   - never reported: hidden folders (.github) and everything under them; bundles and library folders whose suffix is a
#     tool's convention (KiCad X.pretty and X.3dshapes, Xcode X.xcodeproj, X.xcassets, X.lproj, X.framework...) and
#     everything under them; a project-local KiCad library's Symbols, Footprints, Models, 3D Models and Datasheets
#     folders and everything under them (the library's tables name those paths: ${KIPRJMOD}/Library/Footprints/X.pretty);
#     the CubeMX folders next to a .ioc (Core, Drivers, Inc, Src, Middlewares: regenerated under those names) and
#     everything under them; everything inside an app part's folder or an Xcode / Swift package folder;
#   - inside code (under a folder that holds a build file such as CMakeLists.txt, Makefile, package.json, Cargo.toml,
#     go.mod, pyproject.toml, platformio.ini, pubspec.yaml, build.gradle(.kts), west.yml, prj.conf, Package.swift or a
#     .ioc, other than the project root; or under a standard part of a code kind) a language's own naming stands
#     (Python packages need underscores): only the first two levels of the project are checked there, and only for
#     capitals and spaces, as before 1.x.

# Every folder that holds a file, at any depth, parents before children.
awk -F/ '{ p = $1; for (i = 2; i <= NF; i++) { print p; p = p "/" $i } }' "$WORK/files" | sort -u >"$WORK/dirs"

# Code roots: folders with a build file (not the project root, whose Makefile is the standard's), and the folders of
# the standard parts of a code kind.
grep -E '/(CMakeLists\.txt|Makefile|GNUmakefile|package\.json|Cargo\.toml|go\.mod|pyproject\.toml|setup\.py|platformio\.ini|pubspec\.yaml|build\.gradle(\.kts)?|settings\.gradle(\.kts)?|west\.yml|prj\.conf|Package\.swift|idf_component\.yml|[^/]*\.ioc)$' "$WORK/files" |
  sed 's%/[^/]*$%%' >"$WORK/code_roots" || true
i=0
while ((i < ${#PART_NAMES[@]})); do
  case ${PART_KINDS[$i]} in
    hardware | altium | mechanical) ;;
    *) [[ ${PART_DIRS[$i]} == . ]] || printf '%s\n' "${PART_DIRS[$i]%/}" >>"$WORK/code_roots" ;;
  esac
  i=$((i + 1))
done
sort -u -o "$WORK/code_roots" "$WORK/code_roots"
# App folders, whose whole subtree keeps its naming: an app part's folder, and a folder with an Xcode project or a
# Swift package in it.
{
  i=0
  while ((i < ${#PART_DIRS[@]})); do
    [[ ${PART_KINDS[$i]} != app-* ]] || printf '%s\n' "${PART_DIRS[$i]%/}"
    i=$((i + 1))
  done
  sed -n -E 's%^(.+)/[^/]*\.(xcodeproj|xcworkspace)/.*$%\1%p; s%^(.+)/Package\.swift$%\1%p' "$WORK/files"
} | sort -u >"$WORK/app_dirs"
# Project-local KiCad libraries: the folder above Symbols/<x>.kicad_sym or Footprints/<x>.pretty ("." at the root).
{ grep -E '(^|/)(Symbols/[^/]*\.kicad_sym|Footprints/[^/]*\.pretty/)' "$WORK/files" || true; } |
  sed -E 's%(^|/)(Symbols|Footprints)/.*$%%' | sed 's%^$%.%' | sort -u >"$WORK/kicad_libs"

# dir_skip DIR: 0 when DIR keeps its name (see the rule above)
dir_skip() {
  local d=$1 comp prefix='' rest=$1 parent lib
  while [[ -n $rest ]]; do
    comp=${rest%%/*}
    if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=''; fi
    case $comp in
      .*) return 0 ;;
      *.pretty | *.3dshapes | *.xcodeproj | *.xcworkspace | *.xcassets | *.lproj | *.framework | *.xcframework | *.bundle | \
        *.app | *.appex | *.imageset | *.appiconset | *.colorset | *.docc | *.playground | *.xctemplate) return 0 ;;
    esac
    parent=$prefix
    prefix=${prefix:+$prefix/}$comp
    if [[ $comp =~ ^(Core|Drivers|Inc|Src|Middlewares)$ ]] && grep -Eq "^${parent:+$parent/}[^/]*\\.ioc$" "$WORK/files"; then
      return 0
    fi
    if [[ $comp =~ ^(Symbols|Footprints|Models|3D\ Models|3DModels|Datasheets)$ ]]; then
      lib=${parent:-.}
      grep -Fxq -- "$lib" "$WORK/kicad_libs" && return 0
    fi
    if [[ $prefix != "$d" ]] && grep -Fxq -- "$prefix" "$WORK/app_dirs"; then
      return 0
    fi
  done
  return 1
}

# in_code DIR: 0 when a folder above DIR is a code root
in_code() {
  local p=$1
  while [[ $p == */* ]]; do
    p=${p%/*}
    grep -Fxq -- "$p" "$WORK/code_roots" && return 0
  done
  return 1
}

renamed=$'\n'
# new_path DIR: DIR with each folder already reported (a parent) replaced by its slug
new_path() {
  local d=$1 rest=$1 comp prefix='' out=''
  while [[ -n $rest ]]; do
    comp=${rest%%/*}
    if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=''; fi
    prefix=${prefix:+$prefix/}$comp
    case $renamed in
      *$'\n'"$prefix"$'\n'*) out=${out:+$out/}$(slug "$comp") ;;
      *) out=${out:+$out/}$comp ;;
    esac
  done
  printf '%s' "$out"
}

while IFS= read -r d; do
  [[ -n $d ]] || continue
  base=${d##*/}
  [[ $base =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && continue
  dir_skip "$d" && continue
  depth=$(($(printf '%s' "$d" | tr -cd '/' | wc -c) + 1))
  if in_code "$d"; then
    ((depth <= 2)) || continue
    [[ $base == *.* ]] && continue
    [[ $base =~ [[:upper:][:space:]] ]] || continue
  fi
  new_base=$(slug "$base")
  [[ $new_base != "$base" ]] || continue
  from=$(new_path "$d")
  renamed="$renamed$d"$'\n'
  case $from in
    */*) to=${from%/*}/$new_base ;;
    *) to=$new_base ;;
  esac
  why="folder name is not lowercase kebab (a-z, 0-9 and -)"
  [[ $base =~ [[:upper:]] && ! $base =~ [[:space:]._] ]] && why="folder name is not lowercase"
  add warn layout "$d" "$why" \
    "rename to $to (parents first) through a temporary name, macOS is case-insensitive: git mv $(sq "$from") $(sq "$from.tmp") && git mv $(sq "$from.tmp") $(sq "$to")"
done <"$WORK/dirs"

# ---------------------------------------------------------------------------------------------
# 3b. design files that no part covers: KiCad (*.kicad_pro, kind hardware), Altium (*.PrjPcb, kind altium) and FreeCAD
# (*.FCStd, kind mechanical). Each folder gets the PARTS entry to add, at its lowercase path.

covered_by_part() {
  local d=$1 i=0 pd
  while ((i < ${#PART_DIRS[@]})); do
    pd=${PART_DIRS[$i]%/}
    if [[ $pd == . || $d == "$pd" || $d == "$pd"/* ]]; then return 0; fi
    i=$((i + 1))
  done
  return 1
}
{ grep -Ei '\.(kicad_pro|prjpcb|fcstd)$' "$WORK/files" || true; } | while IFS= read -r f; do
  case $f in */*) d=${f%/*} ;; *) d=. ;; esac
  case $(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]') in
    kicad_pro) k=hardware ;;
    prjpcb) k=altium ;;
    *) k=mechanical ;;
  esac
  printf '%s\t%s\n' "$d" "$k"
done | sort -u | while IFS=$'\t' read -r d k; do
  covered_by_part "$d" && continue
  [[ $d == . ]] || ! dir_skip "$d" || continue
  if [[ $d == . ]]; then
    nd=$(part_group "$k")
    pn=$k
  else
    nd=''
    rest=$d
    while [[ -n $rest ]]; do
      comp=${rest%%/*}
      if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=''; fi
      nd=${nd:+$nd/}$(slug "$comp")
    done
    pn=$(slug "${d##*/}")
  fi
  case $k in hardware) what="a KiCad project" ;; altium) what="an Altium project (*.PrjPcb)" ;; *) what="a FreeCAD model (*.FCStd)" ;; esac
  # a KiCad project whose own library tables point into the project (${KIPRJMOD}) keeps that library
  locallib=''
  if [[ $k == hardware ]] && grep -qs 'KIPRJMOD' "$DIR/$d/sym-lib-table" "$DIR/$d/fp-lib-table"; then
    locallib=" and ${pn}_LIBRARY := local (its sym-lib-table and fp-lib-table are its library)"
  fi
  add warn parts "$d" "$what with no part (kind $k)" \
    "add $pn:$k:$nd to PARTS in make/project.mk$locallib (the kind's folder is $(part_group "$k")/: reference/standard.md section 1)"
done

# ---------------------------------------------------------------------------------------------
# 4. Makefiles outside make/ (sub-Makefiles), and the targets of every Makefile when not standard

grep -E '(^|/)(Makefile|makefile|GNUmakefile|[^/]*\.mk)$' "$WORK/files" >"$WORK/makefiles" || true

list_targets() {
  # rule lines `a b c: deps` (not `VAR := x`, not special `.TARGETS`), names in first-seen order
  awk '
    /^[A-Za-z0-9_.-]+([ \t]+[A-Za-z0-9_.-]+)*[ \t]*:([^=]|$)/ {
      line = $0
      sub(/:.*/, "", line)
      n = split(line, names, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        t = names[i]
        if (t != "" && t !~ /^\./ && !seen[t]++) out = out " " t
      }
    }
    END { sub(/^ /, "", out); print out }
  ' "$1" 2>/dev/null || true
}

# An arm-gcc part builds through its own Makefile (templates/make/kinds/arm-gcc.mk), so the Makefile at the root
# of its dir is not a sub-Makefile to move; any other Makefile under it still is. A silabs part's make <part>-test
# runs the Makefile in <dir>/test/ or <dir>/tests/ (1.3), so those two are the kind's too.
kind_makefiles=" "
i=0
while ((i < ${#PART_NAMES[@]})); do
  case ${PART_KINDS[$i]} in
    arm-gcc) kind_makefiles+="${PART_DIRS[$i]%/}/Makefile " ;;
    silabs) kind_makefiles+="${PART_DIRS[$i]%/}/test/Makefile ${PART_DIRS[$i]%/}/tests/Makefile " ;;
  esac
  i=$((i + 1))
done

while IFS= read -r mf; do
  [[ -n $mf ]] || continue
  case $mf in
    Makefile | make/*) is_sub=0 ;;
    *) is_sub=1 ;;
  esac
  [[ $kind_makefiles != *" $mf "* ]] || is_sub=0
  targets=$(list_targets "$DIR/$mf")
  if ((is_sub == 1)) && [[ -n $targets ]]; then
    add warn layout "$mf" "sub-Makefile, adopt moves its targets" \
      "move its targets to the root as <part>-<verb> (kind file or make/local.mk), then delete it"
  fi
  if ((STANDARD == 0)) && [[ -n $targets ]]; then
    printf '%s%s%s\n' "$mf" "$US" "$targets" >>"$WORK/targets"
  fi
done <"$WORK/makefiles"

# ---------------------------------------------------------------------------------------------
# 5. secrets

# The list of secret-like file names is the one secrets.sh uses (templates/make/bin/secret-patterns.sh);
# an .npmrc counts only when it sets a credential (read there, never printed).
# shellcheck source=../templates/make/bin/secret-patterns.sh
. "$TPL_MAKE/bin/secret-patterns.sh"

if ((IS_GIT == 1)); then where="is tracked in git"; else where="is in the project folder"; fi
while IFS= read -r f; do
  [[ -n $f ]] || continue
  class=$(std_secret_class "$f" "$DIR")
  case $class in
    secret)
      add error secrets "$f" "secret-like file $where" \
        "move it into the project's secrets repo, $PROJECT_NAME/ in it (adopt does it without printing it), git rm --cached it, then rotate it: it stays in git history"
      ;;
    warn)
      add warn secrets "$f" "file that often holds exported secrets ($where)" \
        "keep secrets out of it: load them with make dev (secrets.sh exec); do not commit values"
      ;;
  esac
done <"$WORK/tracked"

# Untracked secret-like files that sit on disk (also the git-ignored ones): plain text secrets a backup,
# a sync client or a stray `git add -f` can still reach.
if ((IS_GIT == 1)); then
  disk_expr=()
  for d in $PRUNE_DIRS; do
    disk_expr+=(-name "$d" -o)
  done
  while IFS= read -r -d '' f; do
    f=${f#./}
    grep -qxF -- "$f" "$WORK/tracked" && continue
    class=$(std_secret_class "$f" "$DIR")
    [[ -n $class ]] || continue
    add warn secrets "$f" "secret-like file on disk, not tracked (plain text outside the secrets repo)" \
      "move it into the project's secrets repo with make secrets-import, then delete the file"
  done < <(cd "$DIR" && find . \( -type d \( "${disk_expr[@]}" -false \) -prune \) -o -type f -print0)
fi

[[ -f "$DIR/secrets.schema" ]] ||
  add warn secrets secrets.schema "missing (names every secret per env, replaces .env.example)" \
    "write it from the skill's template; adopt fills it from the secrets it moves"

# ---------------------------------------------------------------------------------------------
# 6. git attributes, tools, docs

if [[ ! -f "$DIR/.gitattributes" ]]; then
  add warn lfs .gitattributes "missing" "copy the skill's .gitattributes (LFS for binaries, KiCad files as text)"
else
  missing=''
  for e in $LFS_EXTS; do
    [[ $e != wrl ]] || has_part_kind hardware || continue
    grep -Eq "^\\*\\.${e}[[:space:]].*filter=lfs" "$DIR/.gitattributes" || missing="$missing *.$e"
  done
  [[ -z $missing ]] ||
    add warn lfs .gitattributes "no LFS line for:$missing" "add them from the skill's .gitattributes (scaffold.sh --force adds a kind's lines), then git lfs migrate if such files are tracked"
  if has_part_kind altium; then
    missing=''
    for e in $ALTIUM_LFS_EXTS; do
      grep -Eq "^\\*\\.${e}[[:space:]].*filter=lfs" "$DIR/.gitattributes" || missing="$missing *.$e"
    done
    [[ -z $missing ]] ||
      add warn lfs .gitattributes "no LFS line for Altium's:$missing" \
        "scaffold.sh <dir> --force appends the missing lines of the skill's templates/altium/gitattributes"
    missing=''
    for e in $ALTIUM_TEXT_EXTS; do
      grep -Eq "^\\*\\.${e}[[:space:]]+(.*[[:space:]])?-text([[:space:]]|\$)" "$DIR/.gitattributes" || missing="$missing *.$e"
    done
    [[ -z $missing ]] ||
      add warn lfs .gitattributes "no -text line for:$missing (Altium writes them with CRLF, the .PrjPcb with a UTF-8 BOM; git may rewrite them)" \
        "scaffold.sh <dir> --force appends the missing lines ('*.PrjPcb -text', '*.OutJob -text')"
  fi
  routed=''
  for e in $BIN_DOC_EXTS; do
    if grep -Eq "^\\*\\.${e}[[:space:]].*filter=lfs" "$DIR/.gitattributes"; then routed="$routed *.$e"; fi
  done
  [[ -z $routed ]] ||
    add warn lfs .gitattributes "routes binary documents to LFS:$routed" \
      "remove those lines: binary documents are not committed (.gitignore ignores them; a generated PDF is a release asset)"
  small=''
  for e in $OLD_LFS_EXTS; do
    if grep -Eq "^\\*\\.${e}[[:space:]].*filter=lfs" "$DIR/.gitattributes"; then small="$small *.$e"; fi
  done
  [[ -z $small ]] ||
    add warn lfs .gitattributes "routes small files to LFS:$small (since 1.1 only 3D and CAD models go there)" \
      "remove those lines, then git add --renormalize . and commit: the files go back to plain git (a file over 5 MB keeps a line of its own)"
fi

# An altium part takes its parts from the shared Altium library, a git submodule at ALTIUM_LIBRARY (make/project.mk,
# default hardware/altium-library) of the repository ALTIUM_LIBRARY_PROJECT (default <owner>/altium-library) (1.4).
# Without it in .gitmodules (or as a gitlink in the index) the part's library check cannot run.
if has_part_kind altium; then
  alib=''
  [[ ! -f "$DIR/make/project.mk" ]] || alib=$(make_var "$DIR/make/project.mk" ALTIUM_LIBRARY)
  alib=${alib##* }
  alib=${alib:-hardware/altium-library}
  alib=${alib%/}
  have_sub=0
  if [[ -f "$DIR/.gitmodules" ]] &&
    grep -Fxq -- "$alib" <<<"$(git config -f "$DIR/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{ print $2 }')"; then
    have_sub=1
  fi
  if ((IS_GIT == 1)) && grep -q '^160000 ' <<<"$(git -C "$DIR" ls-files -s -- "$alib" 2>/dev/null)"; then have_sub=1; fi
  if ((have_sub == 0)); then
    aproj=''
    [[ ! -f "$DIR/make/project.mk" ]] || aproj=$(make_var "$DIR/make/project.mk" ALTIUM_LIBRARY_PROJECT)
    aproj=${aproj##* }
    [[ -n $aproj ]] || aproj=$(config_value ALTIUM_LIBRARY_PROJECT)
    if [[ -z $aproj ]]; then
      aown=$(git -C "$DIR" remote get-url origin 2>/dev/null | sed -n -E 's#^.*github\.com[:/]([A-Za-z0-9-]+)/.*$#\1#p' | tr '[:upper:]' '[:lower:]' || true)
      [[ -n $aown ]] || aown=$(config_value GITHUB_OWNER)
      aproj="${aown:-<owner>}/altium-library"
    fi
    i=0
    while ((i < ${#PART_NAMES[@]})); do
      if [[ ${PART_KINDS[$i]} == altium ]]; then
        add warn project "$alib" "part ${PART_NAMES[$i]} (altium) has no Altium library submodule at $alib: its parts are not checked against the shared library" \
          "make ${PART_NAMES[$i]}-setup adds it (git submodule add https://github.com/$aproj.git $alib), then commit .gitmodules and $alib"
      fi
      i=$((i + 1))
    done
  fi
fi

# An altium part's BOM is the one its OutJob writes to outputs/ (1.5); a bom/ folder left from 1.4 is a warning.
if has_part_kind altium; then
  i=0
  while ((i < ${#PART_NAMES[@]})); do
    if [[ ${PART_KINDS[$i]} == altium ]]; then
      apd=${PART_DIRS[$i]%/}
      for bome in "$DIR/$apd"/*; do
        [[ -d $bome ]] || continue
        bomd=${bome##*/}
        [[ $(printf %s "$bomd" | tr '[:upper:]' '[:lower:]') == bom ]] || continue
        if [[ $apd == . ]]; then rel=$bomd; else rel=$apd/$bomd; fi
        add warn layout "$rel" "part ${PART_NAMES[$i]} (altium): since 1.5 the BOM is the one the OutJob writes to $apd/outputs/ (*BOM*.csv), not a committed $bomd/" \
          "git rm -r $(sq "$rel") and commit; make ${PART_NAMES[$i]}-bom points at the OutJob's BOM"
      done
    fi
    i=$((i + 1))
  done
fi

# Tracked files that .gitattributes routes to LFS but that are committed as plain blobs (git shows them as
# modified forever). Compares the files with the lfs filter attribute against `git lfs ls-files`; without
# git-lfs, against the first bytes of the staged blob. No file content is printed.
readonly LFS_FIX="git add --renormalize . and commit \"Move the binaries already tracked into Git LFS\" (the old blobs stay in history)"
readonly LFS_SHOW=10
if ((IS_GIT == 1)) && [[ -f "$DIR/.gitattributes" ]] && grep -q 'filter=lfs' "$DIR/.gitattributes"; then
  : >"$WORK/lfs_want"
  git -C "$DIR" -c core.quotepath=off ls-files -z --cached |
    git -C "$DIR" check-attr -z --stdin filter |
    while IFS= read -r -d '' path && IFS= read -r -d '' _attr && IFS= read -r -d '' value; do
      if [[ $value == lfs ]]; then printf '%s\n' "$path"; fi
    done | sort -u >"$WORK/lfs_want"
  if [[ -s "$WORK/lfs_want" ]]; then
    : >"$WORK/lfs_plain"
    if git -C "$DIR" lfs version >/dev/null 2>&1 &&
      git -C "$DIR" -c core.quotepath=off lfs ls-files -n >"$WORK/lfs_have.raw" 2>/dev/null; then
      sed '/^$/d' "$WORK/lfs_have.raw" | sort -u >"$WORK/lfs_have"
      comm -23 "$WORK/lfs_want" "$WORK/lfs_have" >"$WORK/lfs_plain"
    else
      while IFS= read -r f; do
        start=$(git -C "$DIR" cat-file -p ":$f" 2>/dev/null | head -c 48 | tr -d '\0' || true)
        [[ $start == "version https://git-lfs.github.com/spec/"* ]] || printf '%s\n' "$f" >>"$WORK/lfs_plain"
      done <"$WORK/lfs_want"
    fi
    plain_count=$(wc -l <"$WORK/lfs_plain" | tr -d ' ')
    shown=0
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      if ((shown == LFS_SHOW)); then
        add warn lfs .gitattributes "$((plain_count - LFS_SHOW)) more tracked file(s) that should be in LFS are plain git blobs" "$LFS_FIX"
        break
      fi
      add warn lfs "$f" "matches an LFS pattern in .gitattributes but is tracked as a plain git blob, not an LFS pointer" "$LFS_FIX"
      shown=$((shown + 1))
    done <"$WORK/lfs_plain"
  fi
fi

# CAD files in LFS on every checkout: git matches .gitattributes patterns without case only where core.ignorecase is
# true (macOS), so *.fcstd routes Case.FCStd to LFS on a Mac but a Linux CI checkout gets the pointer file. The 3D and
# CAD files (LFS_EXTS) and Altium's binary documents are checked with core.ignorecase=false. An Altium binary committed
# as a plain git blob is an error: it is large, never merges, and history keeps every copy.
if ((IS_GIT == 1)); then
  cad_re="\\.($(printf '%s %s' "$LFS_EXTS" "$ALTIUM_BIN_EXTS" | tr ' ' '|'))\$"
  grep -Ei "$cad_re" "$WORK/tracked" >"$WORK/cad" || true
  if [[ -s "$WORK/cad" ]]; then
    : >"$WORK/cad_ptr"
    if git -C "$DIR" lfs version >/dev/null 2>&1; then
      git -C "$DIR" -c core.quotepath=off lfs ls-files -n 2>/dev/null | sort -u >"$WORK/cad_ptr" || true
    fi
    is_pointer() {
      grep -Fxq -- "$1" "$WORK/cad_ptr" && return 0
      local start
      start=$(git -C "$DIR" cat-file -p ":$1" 2>/dev/null | head -c 48 | tr -d '\0' || true)
      [[ $start == "version https://git-lfs.github.com/spec/"* ]]
    }
    is_binary() {
      local all text
      all=$(git -C "$DIR" cat-file -p ":$1" 2>/dev/null | head -c 8000 | wc -c | tr -d ' ')
      text=$(git -C "$DIR" cat-file -p ":$1" 2>/dev/null | head -c 8000 | tr -d '\0' | wc -c | tr -d ' ')
      [[ $all != "$text" ]]
    }
    tr '\n' '\0' <"$WORK/cad" | git -C "$DIR" -c core.ignorecase=false check-attr -z --stdin filter |
      while IFS= read -r -d '' path && IFS= read -r -d '' _attr && IFS= read -r -d '' value; do
        printf '%s\t%s\n' "$path" "$value"
      done >"$WORK/cad_attr"
    shown=0
    while IFS=$'\t' read -r f value; do
      [[ -n $f ]] || continue
      ext=${f##*.}
      altium=0
      case " $(printf '%s' "$ALTIUM_BIN_EXTS" | tr '[:upper:]' '[:lower:]') " in
        *" $(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]') "*) altium=1 ;;
      esac
      if is_pointer "$f"; then
        [[ $value == lfs ]] && continue
        ((shown < LFS_SHOW)) || continue
        shown=$((shown + 1))
        add warn lfs "$f" "in Git LFS, but no .gitattributes line routes *.$ext there with this case: a case-sensitive checkout (Linux CI) gets the pointer file" \
          "add the line '*.$ext filter=lfs diff=lfs merge=lfs -text' to .gitattributes (git matches patterns with case on Linux)"
      elif ((altium == 1)) && is_binary "$f"; then
        add error lfs "$f" "Altium binary document committed as a plain git blob (it belongs in Git LFS)" \
          "add '*.$ext filter=lfs diff=lfs merge=lfs -text' to .gitattributes, then git add --renormalize $(sq "$f") and commit (git lfs migrate import --include='*.$ext' --everything rewrites history, only with the team's agreement)"
      fi
    done <"$WORK/cad_attr"
  fi
fi

[[ -f "$DIR/mise.toml" ]] ||
  add warn tools mise.toml "missing (pins node / python / go / rust)" "write it from the skill's template with the versions in use"
[[ -f "$DIR/Brewfile" ]] ||
  add warn tools Brewfile "missing (system tools for make setup)" "write it from the skill's template"

for doc in README.md CLAUDE.md PLAN.md; do
  [[ -f "$DIR/$doc" ]] || add warn docs "$doc" "missing" "write it from the skill's template"
done

# The document set: project docs, and per part its README, CHANGELOG and the kind's docs in docs/<part>/.
# scaffold.sh --force writes the missing ones and keeps every doc that exists.
readonly DOC_FIX="write it with scaffold.sh --force (it adds only the docs that are missing), then fill it in"
for doc in docs/README.md docs/architecture.md; do
  [[ -f "$DIR/$doc" ]] || add warn docs "$doc" "missing" "$DOC_FIX"
done
# docs/references.md is a list of links since 1.2: a 1.1 table with File or SHA256 columns (what refs-fetch read) converts.
if [[ -f "$DIR/docs/references.md" ]] && awk '
    /^[[:space:]]*\|/ {
      n = split($0, c, "|")
      for (j = 1; j <= n; j++) {
        v = tolower(c[j]); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v == "sha256" || v == "file") found = 1
      }
    }
    END { exit !found }' "$DIR/docs/references.md"; then
  add warn docs docs/references.md "a table with File / SHA256 columns (1.1): since 1.2 it is a list of links, nothing is downloaded" \
    "rewrite each row as a line '- [Title (MPN) — Vendor](URL)' under ## headings (keep Title, Vendor and URL; drop File and SHA256), remove references/ from .gitignore and git rm make/bin/refs.sh"
fi
deployable=''
i=0
while ((i < ${#PART_NAMES[@]})); do
  pn=${PART_NAMES[$i]} pk=${PART_KINDS[$i]} pd=${PART_DIRS[$i]}
  i=$((i + 1))
  kind_known "$pk" || continue
  case $pk in cloud-worker | web-pages | docker) deployable="$deployable $pn" ;; esac
  if [[ -d "$DIR/$pd" ]]; then
    for doc in README.md CHANGELOG.md; do
      [[ -f "$DIR/$pd/$doc" ]] || add warn docs "$pd/$doc" "missing (part $pn)" "$DOC_FIX"
    done
  fi
  for doc in $(kind_docs "$pk"); do
    [[ -f "$DIR/docs/$pn/$doc.md" ]] || add warn docs "docs/$pn/$doc.md" "missing (part $pn, $pk)" "$DOC_FIX"
  done
done
# A web-pages part is a static-assets Worker on its custom domain (v34): its wrangler file names the domain. Pages
# (pages_build_output_dir) only when the project asked for it; a CHANGE-ME route is a domain still to be chosen.
i=0
while ((i < ${#PART_NAMES[@]})); do
  pn=${PART_NAMES[$i]} pk=${PART_KINDS[$i]} pd=${PART_DIRS[$i]}
  i=$((i + 1))
  [[ $pk == web-pages && -d "$DIR/$pd" ]] || continue
  wf=''
  for f in wrangler.jsonc wrangler.json; do [[ -f "$DIR/$pd/$f" ]] && wf=$pd/$f && break; done
  if [[ -z $wf ]]; then
    add warn project "$pd" "part $pn (web-pages) has no wrangler.jsonc" "write it with scaffold.sh --force --domain $pn=HOST: a static-assets Worker on that custom domain (--pages $pn only when Pages was asked for)"
  elif grep -q 'CHANGE-ME' "$DIR/$wf"; then
    add warn project "$wf" "part $pn has no custom domain yet (CHANGE-ME)" "put the site's host in the routes of each env block, and in ${pn}_URL_<env> in make/project.mk"
  fi
done
if [[ -n $deployable && ! -f "$DIR/docs/operations.md" ]]; then
  add warn docs docs/operations.md "missing (deployable parts:$deployable)" "$DOC_FIX"
fi
# Per-environment defines (1.8): <part>_ENV_DEFINES_<env> reaches an espidf build through the STD_ENV_DEFINES block of
# its top CMakeLists.txt, and an arm-gcc Makefile build through STD_ENV_CFLAGS in its Makefile; without them the build
# stops. circuitpython has no compile step to take them.
# shellcheck disable=SC2016 # CMake text: ${std_define} is CMake's
readonly ESPIDF_ENV_BLOCK='foreach(std_define IN LISTS STD_ENV_DEFINES) idf_build_set_property(COMPILE_DEFINITIONS "${std_define}" APPEND) endforeach()'
if [[ -f "$DIR/make/project.mk" ]]; then
  i=0
  while ((i < ${#PART_NAMES[@]})); do
    pn=${PART_NAMES[$i]} pk=${PART_KINDS[$i]} pd=${PART_DIRS[$i]}
    i=$((i + 1))
    grep -Eq "^[[:space:]]*${pn}_ENV_DEFINES_(local|staging|production)[[:space:]]*[:?+]?=" "$DIR/make/project.mk" || continue
    case $pk in
      espidf)
        if [[ -f "$DIR/$pd/CMakeLists.txt" ]] && ! grep -q 'STD_ENV_DEFINES' "$DIR/$pd/CMakeLists.txt"; then
          add warn project "$pd/CMakeLists.txt" "part $pn sets ${pn}_ENV_DEFINES_* but its CMakeLists.txt does not apply STD_ENV_DEFINES: its build stops" \
            "add after include(\$ENV{IDF_PATH}/tools/cmake/project.cmake) and before project(): $ESPIDF_ENV_BLOCK"
        fi
        ;;
      arm-gcc)
        if [[ ! -f "$DIR/$pd/CMakeLists.txt" && -f "$DIR/$pd/Makefile" ]] && ! grep -q 'STD_ENV_CFLAGS' "$DIR/$pd/Makefile"; then
          add warn project "$pd/Makefile" "part $pn sets ${pn}_ENV_DEFINES_* but its Makefile never uses STD_ENV_CFLAGS: its build stops" \
            "add CFLAGS += \$(STD_ENV_CFLAGS) (and to CXXFLAGS when it compiles C++)"
        fi
        ;;
      circuitpython)
        add warn project make/project.mk "part $pn (circuitpython) sets ${pn}_ENV_DEFINES_*, which no circuitpython command uses (no compile step)" \
          "remove it; per-environment settings go in the code's own files (settings.toml)"
        ;;
    esac
  done
fi

# The CI jobs check the secrets repo and the KiCad library out into .ci/: without the ignore line a local act run or a
# stray checkout could be committed.
if [[ -d "$DIR/.github/workflows" ]] && { [[ ! -f "$DIR/.gitignore" ]] || ! grep -Fxq -- ".ci/" "$DIR/.gitignore"; }; then
  add warn ci .gitignore "does not ignore .ci/ (the CI checkouts of the secrets repo and the KiCad library)" \
    "scaffold.sh <dir> --force adds it, or add the line .ci/"
fi

# Binary documents: ignored by .gitignore, never tracked. Only names are reported, never content.
missing=''
for e in $BIN_DOC_EXTS; do
  if [[ ! -f "$DIR/.gitignore" ]] || ! grep -Fxq -- "*.$e" "$DIR/.gitignore"; then missing="$missing *.$e"; fi
done
[[ -z $missing ]] ||
  add warn docs .gitignore "does not ignore binary documents:$missing" "add the lines from the skill's .gitignore (binary documents block)"
if ((IS_GIT == 1)); then
  bin_re=$(printf '%s' "$BIN_DOC_EXTS" | tr ' ' '|')
  grep -Ei "\\.(${bin_re})\$" "$WORK/tracked" >"$WORK/bin_docs" || true
  bin_count=$(wc -l <"$WORK/bin_docs" | tr -d ' ')
  shown=0
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    if ((shown == LFS_SHOW)); then
      add warn docs . "$((bin_count - LFS_SHOW)) more binary document(s) are committed" \
        "git rm --cached each one (it stays in history); attach generated ones to a release as assets"
      break
    fi
    add warn docs "$f" "binary document is committed (docs are Markdown; binary documents are never committed)" \
      "git rm --cached '$f' (it stays in history) and attach it to a release as an asset; write its content as Markdown in docs/"
    shown=$((shown + 1))
  done <"$WORK/bin_docs"
fi

# ---------------------------------------------------------------------------------------------
# 7. CI

CI_PROJECT=$(ci_project)
if [[ ! $CI_PROJECT =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]]; then
  add error ci "CI_TEMPLATES_REPO" "'$CI_PROJECT' is not owner/name" \
    "set CI_TEMPLATES_REPO := <owner>/<name> (make/project.mk or the user config), or remove it for $CI_TEMPLATES_DEFAULT"
fi
if [[ -n $(config_value CI_TEMPLATES_PROJECT) ]]; then
  add warn ci "user config ~/.config/project-standard/config.mk" \
    "CI_TEMPLATES_PROJECT is ignored since 1.7: the workflows call $CI_PROJECT (CI_TEMPLATES_REPO)" \
    "remove CI_TEMPLATES_PROJECT; set CI_TEMPLATES_REPO := <owner>/<name> only for a repository other than $CI_TEMPLATES_DEFAULT"
fi
# The project's owner is its GitHub origin's (1.8): its secrets repo and CI follow it; the user config's
# GITHUB_OWNER is only the fallback before the repository exists.
ORIGIN_OWNER=''
if ((IS_GIT == 1)); then
  ORIGIN_OWNER=$(git -C "$DIR" remote get-url origin 2>/dev/null |
    sed -n -E 's%^(https?://([^@/]*@)?github\.com/|ssh://git@github\.com/|git@github\.com:)([A-Za-z0-9][A-Za-z0-9-]*)/[A-Za-z0-9._-]+/?$%\3%p' |
    tr 'A-Z' 'a-z' || true)
fi
# A project whose origin is elsewhere (GitLab, Bitbucket, a server) moves to GitHub: CI, releases, the secrets repo and
# ghcr.io all follow the GitHub owner. The fix is adopt's move step.
ORIGIN_URL=''
if ((IS_GIT == 1)); then
  ORIGIN_URL=$(git -C "$DIR" remote get-url origin 2>/dev/null || true)
fi
if [[ -n $ORIGIN_URL && -z $ORIGIN_OWNER ]] && ! printf '%s' "$ORIGIN_URL" | grep -Eq '^(https?://([^@/]*@)?github\.com/|ssh://git@github\.com/|git@github\.com:)'; then
  o_host=$(printf '%s' "$ORIGIN_URL" | sed -E 's%^[a-z+]+://%%; s%^[^@/]*@%%; s%[:/].*$%%')
  o_path=$(printf '%s' "$ORIGIN_URL" | sed -E 's%^[a-z+]+://[^/]*/%%; s%^[^@/]*@[^:/]*[:/]%%; s%\.git/?$%%; s%/$%%')
  o_owner=$(printf '%s' "${o_path%%/*}" | tr '[:upper:]' '[:lower:]')
  o_name=$(printf '%s' "${o_path##*/}" | tr '[:upper:]' '[:lower:]')
  [[ -n $o_owner && $o_owner != "$o_path" ]] || o_owner='<owner>'
  [[ -n $o_name ]] || o_name=$PROJECT_NAME
  o_old=old-origin
  case $o_host in *gitlab*) o_old=gitlab ;; *bitbucket*) o_old=bitbucket ;; esac
  add error repo origin "origin is not on GitHub ($ORIGIN_URL): CI, releases, the secrets repo and ghcr.io need the project on GitHub" \
    "move it (adopt's move step; $o_owner is the GitHub account that will own it): gh repo create $o_owner/$o_name --private && git lfs fetch --all origin && git remote rename origin $o_old && git remote add origin git@github.com:$o_owner/$o_name.git && git push origin --all && git push origin --tags && git lfs push --all origin"
fi
if [[ -z $ORIGIN_OWNER && -z $(config_value GITHUB_OWNER) ]]; then
  add warn ci "user config ~/.config/project-standard/config.mk" "GITHUB_OWNER is not set: make ci-setup and the releases need it" \
    "add the project's GitHub remote origin (its owner is the project's), or set GITHUB_OWNER := <owner> in the user config"
fi

WF="$DIR/.github/workflows"
for wf in checks release; do
  [[ -f "$WF/$wf.yml" ]] ||
    add error ci ".github/workflows/$wf.yml" "missing" "generate them: scaffold.sh <dir> --force"
done
# v15 and earlier called the push and pull-request workflow ci.yml; since v16 it is checks.yml
if [[ -f "$WF/ci.yml" ]]; then
  add warn ci .github/workflows/ci.yml "the v15 name of checks.yml" \
    "git mv '.github/workflows/ci.yml' '.github/workflows/checks.yml', and set its name: to checks"
fi
# kind_has_release K: the kind has a job in release.yml. altium has none: Altium makes its outputs on Windows, so its
# Release is made there (make <part>-github-release FORCE=1) and CI only checks the board (1.1).
kind_has_release() { [[ $1 != altium ]]; }
# since v20 release.yml ends with a latest job that copies the part's Release into the Release "latest" (when a part
# has a release job at all)
any_release=0
for pk in ${PART_KINDS[@]+"${PART_KINDS[@]}"}; do
  if kind_known "$pk" && kind_has_release "$pk"; then any_release=1; fi
done
if ((any_release == 1)) && [[ -f "$WF/release.yml" ]] && ! grep -q -- '-release-latest' "$WF/release.yml"; then
  add warn ci .github/workflows/release.yml "no latest job: the Release \"latest\" (every part's newest files) is not kept up to date" \
    "add the latest job of a v20 release.yml (scaffold a scratch project to see it), then make <part>-release-latest once per part"
fi
# since v24: the project's GitHub repository has a description (its "About" line). The one online check: it runs only
# when gh is installed and a remote points at github.com, and says nothing when gh cannot read the repository
# (offline, not signed in). STD_AUDIT_OFFLINE=1 skips it.
if [[ -z ${STD_AUDIT_OFFLINE:-} ]] && command -v gh >/dev/null 2>&1; then
  gh_repo=$(git -C "$DIR" remote -v 2>/dev/null | awk '$2 ~ /github\.com[:\/]/ && !f { print $2; f = 1 }' |
    sed -E 's#^.*github\.com[:/]##; s#\.git$##' || true)
  if [[ -n $gh_repo ]] && gh_desc=$(gh repo view "$gh_repo" --json description --jq .description 2>/dev/null); then
    [[ -n $gh_desc ]] ||
      add warn ci "$gh_repo" "the GitHub repository has no description" \
        "gh repo edit $gh_repo --description \"<the first sentence of README.md>\""
  fi
fi
if [[ -f "$DIR/.gitlab-ci.yml" ]]; then
  add warn ci .gitlab-ci.yml "left over from GitLab CI" \
    "once the workflows are in place, git rm .gitlab-ci.yml (you run it)"
fi

# check_uses REL REF: a reusable workflow is the CI templates at @v<standard>; an action is actions/* pinned by a
# full commit SHA. Any other action is an error: the standard does not run third-party actions.
check_uses() {
  local rel=$1 ref=$2 ver old_repo
  case $ref in
    ./*) return 0 ;;
    */.github/workflows/*) ;;
    actions/*) ;;
    *)
      add error ci "$rel" "uses $ref: a third-party action (only actions/* and the CI templates are allowed)" \
        "replace it with a make target, or use an actions/* action pinned by a commit SHA"
      return 0
      ;;
  esac
  if [[ $ref != *@* ]]; then
    add error ci "$rel" "uses $ref has no @version" "pin it: @v$CURRENT_VERSION for the CI templates, a 40-hex commit SHA for actions/*"
    return 0
  fi
  ver=${ref##*@}
  case $ref in
    */.github/workflows/*)
      if [[ $ref != "$CI_PROJECT/.github/workflows/"* ]]; then
        # owner/name/.github/workflows/...: another CI templates repository, such as the pre-1.7 <owner>/ci-templates
        old_repo=${ref%%/.github/workflows/*}
        add warn ci "$rel" "uses $ref: outdated, the CI templates are $CI_PROJECT (CI_TEMPLATES_REPO), not $old_repo" \
          "change the uses lines to $CI_PROJECT: sed -i '' 's#$old_repo/.github/workflows/#$CI_PROJECT/.github/workflows/#' .github/workflows/*.yml"
      fi
      [[ $ver == "v$CURRENT_VERSION" ]] ||
        add warn ci "$rel" "uses $ref: the skill is at v$CURRENT_VERSION" "bump it to @v$CURRENT_VERSION, after checking the CI templates' notes"
      ;;
    actions/*)
      [[ $ver =~ ^[0-9a-f]{40}$ ]] ||
        add warn ci "$rel" "uses $ref: not pinned by a full commit SHA" "pin it as actions/<name>@<40-hex sha> # <tag>"
      ;;
  esac
}

if [[ -d $WF ]]; then
  for wf in "$WF"/*.yml; do
    [[ -f $wf ]] || continue
    rel=${wf#"$DIR"/}
    while IFS= read -r ref; do
      [[ -n $ref ]] || continue
      check_uses "$rel" "$ref"
    done < <(sed -nE 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//p' "$wf" |
      sed -e 's/[[:space:]]*#.*$//' -e "s/[\"']//g" -e 's/[[:space:]]*$//')
  done
  # every part has its job in both workflows: checks.yml (every push) and release.yml (its tag), each calling the kind's file
  i=0
  while ((i < ${#PART_NAMES[@]})); do
    pn=${PART_NAMES[$i]} pk=${PART_KINDS[$i]}
    i=$((i + 1))
    kind_known "$pk" || continue
    for wf in checks release; do
      f="$WF/$wf.yml"
      [[ -f $f ]] || continue
      [[ $wf == checks ]] || kind_has_release "$pk" || continue
      if ! grep -Eq "^[[:space:]]+part:[[:space:]]+${pn}[[:space:]]*\$" "$f" || ! grep -Fq "/.github/workflows/${pk}.yml@" "$f"; then
        add warn ci ".github/workflows/$wf.yml" "no $wf job for part $pn ($pk)" \
          "scaffold the workflows again (scaffold.sh <dir> --force, which keeps the existing files) or add a job that calls $pk.yml"
      fi
    done
    # since v26 the tag of a cloud-worker or web-pages part deploys production before its Release: its release.yml job
    # passes confirm: production (the reusable workflow makes no Release without that deploy)
    case $pk in
      cloud-worker | web-pages)
        f="$WF/release.yml"
        [[ -f $f ]] || continue
        if ! awk -v job="  $pn-release:" '
            $0 == job { in_job = 1; next }
            in_job && /^  [^ #]/ { exit }
            in_job && /^[[:space:]]+confirm:[[:space:]]+production[[:space:]]*$/ { found = 1; exit }
            END { exit !found }' "$f"; then
          add warn ci .github/workflows/release.yml "the tag job of part $pn ($pk) does not deploy production, so its tag makes no Release" \
            "add 'confirm: production' under with: of job $pn-release (scaffold a scratch project to see the job)"
        fi
        ;;
      # 1.9: CI installs the Flutter of flutter_version (from <part>_FLUTTER_VERSION), else the part's .fvmrc, else the
      # latest stable (no pin is no finding); a pinned version that the jobs do not pass is not the one CI builds with
      app-flutter)
        # 1.10: <part>_STORE (android, ios or both) is what the tag uploads; the tag job must pass it as store, with
        # confirm: production, or the tag uploads nothing
        stv=''
        [[ ! -f "$DIR/make/project.mk" ]] || stv=$(make_var "$DIR/make/project.mk" "${pn}_STORE" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
        f="$WF/release.yml"
        if [[ -n $stv && -f $f ]] && ! awk -v job="  $pn-release:" -v want="$stv" '
            $0 == job { in_job = 1; next }
            in_job && /^  [^ #]/ { exit }
            in_job && /^[[:space:]]+confirm:[[:space:]]+production[[:space:]]*$/ { conf = 1 }
            in_job && /^[[:space:]]+store:/ { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/["\047]/, "", v); gsub(/[[:space:]]+/, " ", v); sub(/^ /, "", v); sub(/ $/, "", v); st = (v == want) }
            END { exit !(conf && st) }' "$f"; then
          add warn ci .github/workflows/release.yml "job $pn-release does not pass ${pn}_STORE ($stv) with confirm: production, so its tag uploads to no store" \
            "add store: '$stv' and confirm: production under with: of job $pn-release"
        fi
        flv=''
        [[ ! -f "$DIR/make/project.mk" ]] || flv=$(make_var "$DIR/make/project.mk" "${pn}_FLUTTER_VERSION")
        [[ -n $flv ]] || continue
        for wf in checks release; do
          f="$WF/$wf.yml" job="  $pn:"
          [[ $wf == checks ]] || job="  $pn-release:"
          [[ -f $f ]] || continue
          if ! awk -v job="$job" -v want="$flv" '
              $0 == job { in_job = 1; next }
              in_job && /^  [^ #]/ { exit }
              in_job && /^[[:space:]]+flutter_version:/ { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/["\047[:space:]]/, "", v); found = (v == want); exit }
              END { exit !found }' "$f"; then
            add warn ci ".github/workflows/$wf.yml" "job ${job#  } does not pass ${pn}_FLUTTER_VERSION ($flv), so CI builds with another Flutter" \
              "add flutter_version: '$flv' under with: of job ${job#  }"
          fi
        done
        ;;
    esac
  done
fi

# ---------------------------------------------------------------------------------------------
# 8. PLAN.md parses as the project map

if [[ -f "$DIR/PLAN.md" ]]; then
  sed -n 's/^## .* {#\([A-Za-z0-9_-]*\)}[[:space:]]*$/\1/p' "$DIR/PLAN.md" >"$WORK/plan_ids"
  if [[ ! -s "$WORK/plan_ids" ]]; then
    add warn docs PLAN.md "no components the project map can read (## Name {#id})" \
      "write one component per part, with tech:, files: and tasks"
  else
    dups=$(sort "$WORK/plan_ids" | uniq -d | tr '\n' ' ' | sed 's/ $//')
    [[ -z $dups ]] || add warn docs PLAN.md "duplicate component ids: $dups" "make each {#id} unique"
    refs=$(sed -nE 's/^(needs|links):[[:space:]]*\[(.*)\][[:space:]]*$/\2/p' "$DIR/PLAN.md" | tr ',' '\n' | tr -d ' ' | sed '/^$/d' | sort -u)
    for r in $refs; do
      grep -Fxq -- "$r" "$WORK/plan_ids" ||
        add warn docs PLAN.md "needs/links names unknown component '$r'" "fix the id or add the component"
    done
  fi
fi

# ---------------------------------------------------------------------------------------------
# output

count=$(wc -l <"$WORK/findings" | tr -d ' ')

json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '"%s"' "$s"
}

if ((JSON == 1)); then
  {
    printf '{"dir":%s,"project":%s,"standard":%s,"version":%s,"current_version":%s,"git":%s,"findings":[' \
      "$(json_str "$DIR")" "$(json_str "$PROJECT_NAME")" \
      "$([[ $STANDARD == 1 ]] && echo true || echo false)" \
      "$([[ -n $VERSION ]] && json_str "$VERSION" || echo null)" \
      "$(json_str "$CURRENT_VERSION")" \
      "$([[ $IS_GIT == 1 ]] && echo true || echo false)"
    sep=''
    while IFS="$US" read -r sev area path msg fix; do
      printf '%s{"severity":%s,"area":%s,"path":%s,"message":%s,"fix":%s}' "$sep" \
        "$(json_str "$sev")" "$(json_str "$area")" "$(json_str "$path")" "$(json_str "$msg")" "$(json_str "$fix")"
      sep=','
    done <"$WORK/findings"
    printf '],"targets":['
    sep=''
    while IFS="$US" read -r mf targets; do
      printf '%s{"file":%s,"targets":[' "$sep" "$(json_str "$mf")"
      tsep=''
      for t in $targets; do
        printf '%s%s' "$tsep" "$(json_str "$t")"
        tsep=','
      done
      printf ']}'
      sep=','
    done <"$WORK/targets"
    printf ']}\n'
  }
else
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    c_red=$'\033[38;2;247;118;142m' c_yellow=$'\033[38;2;224;175;104m' c_green=$'\033[38;2;158;206;106m'
    c_blue=$'\033[38;2;122;162;247m' c_cyan=$'\033[38;2;125;207;255m' c_dim=$'\033[38;2;86;95;137m'
    c_fg=$'\033[38;2;192;202;245m' c_off=$'\033[0m'
  else
    c_red='' c_yellow='' c_green='' c_blue='' c_cyan='' c_dim='' c_fg='' c_off=''
  fi
  if ((STANDARD == 1)); then
    state="standard v$VERSION"
  else
    state="not standard"
  fi
  printf '%sproject-standard audit%s %s%s%s %s(%s)%s\n' "$c_blue" "$c_off" "$c_fg" "$PROJECT_NAME" "$c_off" "$c_dim" "$state" "$c_off"
  if ((count == 0)); then
    printf '%sclean%s: matches the standard v%s\n' "$c_green" "$c_off" "$CURRENT_VERSION"
  else
    while IFS="$US" read -r sev area path msg fix; do
      case $sev in
        error) c=$c_red ;;
        outdated) c=$c_cyan ;;
        *) c=$c_yellow ;;
      esac
      printf '%s%-8s%s %s%-9s%s %s: %s  %sfix: %s%s\n' "$c" "$sev" "$c_off" "$c_dim" "$area" "$c_off" \
        "$path" "$msg" "$c_dim" "$fix" "$c_off"
    done <"$WORK/findings"
  fi
  if [[ -s "$WORK/targets" ]]; then
    printf '\n%stargets today%s %s(for the old -> new command table)%s\n' "$c_blue" "$c_off" "$c_dim" "$c_off"
    while IFS="$US" read -r mf targets; do
      printf '%s%s%s: %s\n' "$c_fg" "$mf" "$c_off" "$targets"
    done <"$WORK/targets"
  fi
  if ((count > 0)); then
    printf '\n%s%s deviation(s)%s\n' "$c_dim" "$count" "$c_off"
  fi
fi

if ((count > 0)); then
  exit 1
fi
exit 0
