# project-standard v1.8 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind altium: an Altium Designer board (one *.PrjPcb per part dir). Altium is Windows only and licensed, so
# nothing here runs Altium: the outputs come from the project's OutJob, run in Altium, into <dir>/outputs/ (never
# committed). The kind checks the project (its layout, its documents, Git LFS), verifies the outputs and packages
# them: the fab zip <dir>/production/<Board>_v<rev>.zip and the GitHub Release.
#
# make/project.mk declares it as   <name>:altium[:<dir>]   (dir usually hardware, or hardware/<board> for several).
# The layout of the part folder (make <part>-check enforces it, make <part>-layout prints the moves to it):
#   <Board>.PrjPcb (.PrjPcbVariants)  <Board>.SchDoc (top sheet)  <Board>.PcbDoc  <Board>.OutJob (writes to outputs\)
#   sheets/NN-Name.SchDoc  sheets/NN-Name.Harness   library/<Board>.SchLib .PcbLib (.IntLib)  library/models/*.step
#   VERSION README.md CHANGELOG.md   outputs/ production/ (generated, ignored)
# The BOM is the one the OutJob writes (1.5): outputs/**/*BOM*.csv, and its .xlsx when it writes one. build requires the
# CSV, release attaches both, make <part>-bom hands the CSV to the bom skill. A bom/ folder left from 1.4 is a warning.
# The documents of the board are Markdown in docs/<dir>/ at the project root.
# Per-part settings: none needed. The revision is <dir>/VERSION; a release's files go to <dir>/release/<rev>/.
# Global: GERBV (gerbv, optional: build renders the Gerbers with it when it is installed).
#
# The shared Altium library (1.4): the repository ALTIUM_LIBRARY_PROJECT (default <owner>/altium-library; make/project.mk
# wins over the user config, see common.mk) is a git submodule of the project at ALTIUM_LIBRARY (default
# hardware/altium-library): a submodule, because an Altium project names its DbLib by a relative path. It holds
# parts.csv, Library.DbLib, sym/*.SchLib, fp/*.PcbLib, models/<MPN>.step and tools/check.py. make <part>-setup adds the
# submodule (or checks it out) and installs the check's requirements in <dir>/.venv; make <part>-lib-check runs
#   tools/check.py project <dir>/<Board>.PrjPcb --root <library>   (WARN=1 adds --warn)
# and make <part>-check runs it too once the library is checked out. make ci-setup gives CI a read-only deploy key for it
# (ALTIUM_LIBRARY_DEPLOY_KEY) and the variable ALTIUM_LIBRARY_REPO; altium.yml checks the submodule out at its pinned
# commit with that key (make <part>-lib-ref prints the path and the commit). A DocumentPath= into the library (the DbLib)
# is accepted by the layout check wherever the library is.
#   ALTIUM_LIBRARY      hardware/altium-library   the submodule, from the project root
#   ALTIUM_LIBRARY_URL  (from ALTIUM_LIBRARY_PROJECT)  the URL setup adds: ../<name>.git when the library has the
#                       project's own GitHub owner (it follows origin, https or ssh), else https://github.com/<owner>/<name>.git
#   ALTIUM_PYTHON       python3                   the Python the tools' venv is made with

GERBV ?= gerbv
ALTIUM_LIBRARY ?= hardware/altium-library
ALTIUM_PYTHON ?= python3
ALTIUM_LIBRARY_URL ?= $(if $(strip $(ALTIUM_LIBRARY_PROJECT)),$(if $(and $(STD_ORIGIN_OWNER),$(filter $(STD_ORIGIN_OWNER),$(call std_lc,$(firstword $(subst /, ,$(ALTIUM_LIBRARY_PROJECT)))))),../$(lastword $(subst /, ,$(ALTIUM_LIBRARY_PROJECT))).git,https://github.com/$(strip $(ALTIUM_LIBRARY_PROJECT)).git))

# The layout, document and Git LFS checks, a bash script run as bash -c "$$ALT_SH" altium MODE DIR REL PART with
# MODE check (violations fail), doctor (violations warn) or plan (print the git mv commands and DocumentPath= edits).
define ALT_SH
# altium layout and git checks: bash -c "$$ALT_SH" altium MODE PARTDIR RELDIR PART
#   MODE check   every violation as a "miss" line, exit 1 when there is one
#   MODE doctor  the same as "warn" lines, exit 0
#   MODE plan    the git mv commands and the DocumentPath= edits that move the part into the layout
# The layout (standard.md): <Board>.PrjPcb, <Board>.SchDoc (top sheet), <Board>.PcbDoc and <Board>.OutJob at the
# part root; sheets/NN-Name.SchDoc and sheets/NN-Name.Harness; library/*.SchLib *.PcbLib *.IntLib and library/models/
# for 3D models; outputs/ (the OutJob's, the BOM among them) and production/ generated; a bom/ folder is a warning
# (1.5). ALT_LIB is the shared Altium library (a submodule, from the project root ALT_ROOT): its files are not the
# part's, and a DocumentPath= into it is accepted.
set -euo pipefail
mode=$$1 d=$$2 rel=$$3 part=$$4
cd "$$d"
lib=$${ALT_LIB:-} root=$${ALT_ROOT:-}
lib=$${lib%/}
# the library as a path from the part folder, when it is inside it (hardware/altium-library in hardware)
libin=
case $$lib in "$$rel"/*) libin=$${lib#"$$rel"/} ;; esac
problems=0 warns=0
c_err=$${c_err:-} c_warn=$${c_warn:-} c_info=$${c_info:-} c_0=$${c_0:-}
say() { if [ "$$mode" != plan ]; then printf '%s>%s %s\n' "$$c_info" "$$c_0" "$$*"; fi; }
# a violation: counted, and a miss in check, a warn in doctor
bad() {
  problems=$$((problems + 1))
  if [ "$$mode" = check ]; then printf '  %smiss%s  %s\n' "$$c_err" "$$c_0" "$$*"
  elif [ "$$mode" = doctor ]; then printf '  %swarn%s  %s\n' "$$c_warn" "$$c_0" "$$*"; fi
}
# a warning: never counted
note() { warns=$$((warns + 1)); if [ "$$mode" != plan ]; then printf '  %swarn%s  %s\n' "$$c_warn" "$$c_0" "$$*"; fi; }
lc() { printf '%s' "$$1" | tr '[:upper:]' '[:lower:]'; }
# q PATH: PATH in double quotes, with \ " $$ and backquote escaped
q() { printf '"%s"' "$$(printf '%s' "$$1" | sed 's/[\\"$$`]/\\&/g')"; }
fix="make $$part-layout prints the moves"

prjs=()
for f in *.PrjPcb *.prjpcb *.PRJPCB; do [ -f "$$f" ] && prjs+=("$$f"); done
if [ "$${#prjs[@]}" -eq 0 ]; then bad "no .PrjPcb at the root of $$rel"; [ "$$mode" = check ] && exit 1; exit 0; fi
if [ "$${#prjs[@]}" -gt 1 ]; then bad "several .PrjPcb in $$rel: one board per part (a part per board, hardware/<board>/)"; [ "$$mode" = check ] && exit 1; exit 0; fi
prj=$${prjs[0]}
board=$${prj%.*}

# want PATH: where PATH (relative, / separated) belongs in the layout; empty for a file the layout has no rule for.
want() {
  local p=$$1 base ext
  base=$${p##*/}
  ext=$$(lc "$${base##*.}")
  case $$ext in
    prjpcb | prjpcbvariants | pcbdoc | outjob) printf '%s\n' "$$base" ;;
    schdoc) if [ "$$(lc "$$base")" = "$$(lc "$$board.SchDoc")" ]; then printf '%s\n' "$$base"; else printf 'sheets/%s\n' "$$base"; fi ;;
    harness) printf 'sheets/%s\n' "$$base" ;;
    schlib | pcblib | intlib) printf 'library/%s\n' "$$base" ;;
    step | stp | wrl)
      case $$(lc "$$p") in outputs/* | production/* | release/*) ;; *) printf 'library/models/%s\n' "$$base" ;; esac ;;
  esac
}

# norm PATH: PATH (relative to the part folder, / separated) as a path from the project root, with . and .. resolved;
# fails when it leaves the project
norm() (
  out= rest=$$rel/$$1
  while [ -n "$$rest" ]; do
    s=$${rest%%/*}
    case $$rest in */*) rest=$${rest#*/} ;; *) rest= ;; esac
    case $$s in
      '' | .) ;;
      ..) [ -n "$$out" ] || exit 1; case $$out in */*) out=$${out%/*} ;; *) out= ;; esac ;;
      *) out=$${out:+$$out/}$$s ;;
    esac
  done
  printf '%s\n' "$$out"
)

# exists PATH: true when PATH exists, also in another letter case (Altium runs on case-insensitive Windows)
exists() {
  [ -e "$$1" ] && return 0
  [ -n "$$(find . -ipath "./$$1" -print 2>/dev/null | head -n 1)" ]
}

moves=() edits=()
add_move() {
  local m
  for m in "$${moves[@]+"$${moves[@]}"}"; do [ "$$m" = "$$1|$$2" ] && return 0; done
  moves+=("$$1|$$2")
}

say "$$part: Altium layout of $$rel ($$prj)"

# 1. Every Altium document on disk is where the layout puts it.
files=()
while IFS= read -r f; do files+=("$${f#./}"); done < <(find . -type f \( -iname '*.SchDoc' -o -iname '*.PcbDoc' -o -iname '*.SchLib' \
  -o -iname '*.PcbLib' -o -iname '*.IntLib' -o -iname '*.Harness' -o -iname '*.OutJob' -o -iname '*.PrjPcbVariants' -o -iname '*.step' -o -iname '*.stp' \) \
  -not -path './outputs/*' -not -path './production/*' -not -path './release/*' -not -path './History/*' \
  -not -path './__Previews/*' -not -path './Project Logs for *' -not -path './Project Outputs for *' \
  -not -path "./$${libin:-/}/*" | LC_ALL=C sort)
for f in "$${files[@]+"$${files[@]}"}"; do
  w=$$(want "$$f")
  [ -n "$$w" ] || continue
  if [ "$$w" != "$$f" ]; then
    case $$w in
      sheets/*) bad "$$f: child sheets and harnesses go in sheets/ ($$fix)" ;;
      library/models/*) bad "$$f: 3D models go in library/models/ ($$fix)" ;;
      library/*) bad "$$f: libraries go in library/ ($$fix)" ;;
      *) bad "$$f: belongs at the part root as $$w ($$fix)" ;;
    esac
    add_move "$$f" "$$w"
  fi
  case $$w in
    sheets/*)
      n=$${w#sheets/}
      if ! printf '%s\n' "$$n" | grep -Eq '^[0-9][0-9]-[A-Za-z0-9_.-]+\.(SchDoc|Harness)$$'; then
        bad "sheets/$$n: name child sheets NN-Name.SchDoc (two-digit order, for example 02-Overview.SchDoc)"
      fi
      case $$(lc "$$n") in
        *.harness)
          s="$${n%.*}.SchDoc" found=
          for g in "$${files[@]+"$${files[@]}"}"; do [ "$$(lc "$${g##*/}")" = "$$(lc "$$s")" ] && found=1; done
          [ -n "$$found" ] || bad "sheets/$$n: a harness sits beside its sheet of the same name, and there is no $$s"
          ;;
      esac
      ;;
  esac
done
for f in "$$board.SchDoc" "$$board.PcbDoc"; do exists "$$f" || bad "no $$f at the root of $$rel: the top sheet and the board are named after the project ($$board)"; done

# 2. Every DocumentPath= of the project is relative, inside the layout, and exists.
while IFS= read -r line; do
  orig=$${line#DocumentPath=}
  orig=$${orig%$$'\r'}
  p=$${orig//\\//}
  # a document of the shared Altium library (its DbLib): wherever the library is; present once it is checked out
  if [ -n "$$lib" ]; then
    np=$$(norm "$$p") || np=
    case $$(lc "$$np") in
      "$$(lc "$$lib")"/*)
        if [ -n "$$(ls -A "$$root/$$lib" 2>/dev/null)" ] && [ ! -e "$$root/$$np" ] &&
          [ -z "$$(find "$$root/$$lib" -ipath "$$root/$$np" -print 2>/dev/null | head -n 1)" ]; then
          bad "DocumentPath=$$orig in $$prj: the file is not in the Altium library $$lib"
        fi
        continue ;;
    esac
  fi
  case $$p in
    /* | [A-Za-z]:*) bad "DocumentPath=$$orig in $$prj is absolute: make it relative to the project"; continue ;;
    ../* | */../* | ..) bad "DocumentPath=$$orig in $$prj points outside the part folder"; continue ;;
  esac
  w=$$(want "$$p")
  if [ -n "$$w" ] && [ "$$w" != "$$p" ]; then
    bad "DocumentPath=$$orig in $$prj is not in the layout: $${w//\//\\} ($$fix)"
    edits+=("$$orig|$${w//\//\\}")
    exists "$$p" && add_move "$$p" "$$w"
    exists "$$p" || exists "$$w" || bad "DocumentPath=$$orig in $$prj: the file does not exist"
  elif ! exists "$$p"; then
    bad "DocumentPath=$$orig in $$prj: the file does not exist"
  fi
done < <(LC_ALL=C sed -e 's/^\xEF\xBB\xBF//' "$$prj" | tr -d '\r' | grep '^DocumentPath=' || true)

# 3. The OutJob writes to outputs\ (relative).
for oj in *.OutJob *.outjob *.OUTJOB; do
  [ -f "$$oj" ] || continue
  paths=$$(tr -d '\r' <"$$oj" | grep -iE '^Output(Base|File)?Path[0-9]*=' | sed 's/^[^=]*=//' | grep -v '^$$' || true)
  if [ -z "$$paths" ]; then note "$$oj: no output path found in it: check that it writes to outputs\\ (relative)"; continue; fi
  while IFS= read -r v; do
    n=$$(lc "$${v//\\//}")
    n=$${n%/}
    case $$n in
      outputs | outputs/*) ;;
      *) bad "$$oj writes to $$v: set its output path to outputs\\ (relative to the project)" ;;
    esac
  done < <(printf '%s\n' "$$paths")
done

# 4. The BOM is the one the OutJob writes to outputs/ (1.5). A bom/ folder left from 1.4 is a warning, not a violation.
for e in *; do
  [ -d "$$e" ] || continue
  case $$(lc "$$e") in
    bom) note "$$e/: the BOM is the one $$board.OutJob writes to outputs/ (*BOM*.csv, since 1.5): remove $$e/ (git rm -r $$(q "$$rel/$$e"), from the project root)" ;;
  esac
done

# 5. Documents are Markdown under docs/hardware/ at the project root, not in the part folder.
if [ -d docs ]; then
  note "docs/ in $$rel: Markdown documents go in docs/hardware/ at the project root; PDFs and Office files stay out of git"
  while IFS= read -r f; do add_move "$${f#./}" "ROOT:docs/$$rel/$${f##*/}"; done < <(find ./docs -type f -iname '*.md' | LC_ALL=C sort)
fi

# 6. Git: the binaries in LFS, the project and OutJob -text, no Altium previews, locks or history tracked.
if git rev-parse --git-dir >/dev/null 2>&1; then
  prefix=$$(git rev-parse --show-prefix)
  while IFS= read -r f; do
    case $$(lc "$$f") in
      *.schdocpreview | *.pcbdocpreview | *.prjpcbstructure | .~lock.* | */.~lock.* | history/* | */history/* | __previews/* | */__previews/* | "project logs for "* | "project outputs for "*)
        bad "$$f is tracked: Altium's previews, locks, history and logs stay out of git (git rm --cached $$(q "$$f"))"
        continue ;;
      *.schdoc | *.pcbdoc | *.schlib | *.pcblib | *.intlib | *.harness | *.prjpcbvariants) ;;
      *) continue ;;
    esac
    hdr=$$(git cat-file -p ":$$prefix$$f" 2>/dev/null | head -c 64 | tr -d '\000' || true)
    case $$hdr in
      "version https://git-lfs.github.com/spec/"*) ;;
      *) bad "$$f is committed as a plain blob, not through Git LFS: git rm --cached $$(q "$$f") && git add $$(q "$$f") (after the .gitattributes LFS line)" ;;
    esac
  done < <(git ls-files -- . | LC_ALL=C sort)
  for f in "$${files[@]+"$${files[@]}"}"; do
    case $$(lc "$$f") in *.schdoc | *.pcbdoc | *.schlib | *.pcblib | *.intlib | *.harness | *.prjpcbvariants) ;; *) continue ;; esac
    a=$$(git check-attr filter -- "$$f" | sed 's/.*: filter: //')
    [ "$$a" = lfs ] || bad "$$f is not covered by a Git LFS line in .gitattributes (*.$${f##*.} filter=lfs diff=lfs merge=lfs -text lockable)"
  done
  # the project and the OutJob are CRLF text (the .PrjPcb with a UTF-8 BOM): -text keeps them byte-exact (1.2)
  for f in *.PrjPcb *.prjpcb *.PRJPCB *.OutJob *.outjob *.OUTJOB; do
    [ -f "$$f" ] || continue
    a=$$(git check-attr text -- "$$f" | sed 's/.*: text: //')
    [ "$$a" = unset ] || bad "$$f is not marked -text in .gitattributes: git may change its CRLF line ends (add the line *.$${f##*.} -text)"
  done
else
  note "$$rel is not in a git repository: Git LFS not checked"
fi

if [ "$$mode" = plan ]; then
  if [ "$${#moves[@]}" -eq 0 ] && [ "$${#edits[@]}" -eq 0 ]; then
    printf '> %s: %s already follows the layout, nothing to move\n' "$$part" "$$rel"
    exit 0
  fi
  printf '> %s: %d moves and %d DocumentPath= edits put %s into the layout. Nothing has been moved: run these from\n' "$$part" "$${#moves[@]}" "$${#edits[@]}" "$$rel"
  printf '  the project root with Altium closed, then make %s-check.\n\n' "$$part"
  dirs=()
  # path T: a move target as a path from the project root (ROOT: targets already are)
  path() { case $$1 in ROOT:*) printf '%s\n' "$${1#ROOT:}" ;; *) printf '%s/%s\n' "$$rel" "$$1" ;; esac; }
  for m in "$${moves[@]+"$${moves[@]}"}"; do
    t=$$(path "$${m#*|}")
    dd=$${t%/*}
    [ "$$dd" != "$$t" ] && [ "$$dd" != "$$rel" ] || continue
    # a folder that a move makes itself (BOM -> bom) is not made beforehand
    seen=
    for x in "$${dirs[@]+"$${dirs[@]}"}" "$${moves[@]+"$${moves[@]}"}"; do
      case $$x in "$$dd" | *"|$${dd#"$$rel"/}") seen=1 ;; esac
    done
    [ -n "$$seen" ] || dirs+=("$$dd")
  done
  if [ "$${#dirs[@]}" -gt 0 ]; then
    printf 'mkdir -p'
    for x in "$${dirs[@]}"; do printf ' %s' "$$(q "$$x")"; done
    printf '\n'
  fi
  for m in "$${moves[@]+"$${moves[@]}"}"; do
    from=$$rel/$${m%%|*} to=$$(path "$${m#*|}")
    if [ "$$(lc "$$from")" = "$$(lc "$$to")" ]; then
      # a change of letter case only: through a temporary name, for case-insensitive file systems
      printf 'git mv %s %s && git mv %s %s\n' "$$(q "$$from")" "$$(q "$$to.tmp")" "$$(q "$$to.tmp")" "$$(q "$$to")"
    else
      printf 'git mv %s %s\n' "$$(q "$$from")" "$$(q "$$to")"
    fi
  done
  if [ "$${#edits[@]}" -gt 0 ]; then
    printf '\nThen in %s/%s (a text file; edit it with Altium closed), change:\n' "$$rel" "$$prj"
    for e in "$${edits[@]}"; do printf '  DocumentPath=%s  ->  DocumentPath=%s\n' "$${e%%|*}" "$${e#*|}"; done
  fi
  exit 0
fi

if [ "$$problems" -eq 0 ]; then
  printf '  %sok%s    %s: layout, document paths and Git LFS\n' "$${c_ok:-}" "$$c_0" "$$rel"
fi
if [ "$$mode" = check ] && [ "$$problems" -gt 0 ]; then
  printf '%serror%s %s: %d layout or Git LFS problem(s), above\n' "$$c_err" "$$c_0" "$$part" "$$problems" >&2
  exit 1
fi
exit 0
endef
export ALT_SH

# --- helpers (shell text expanded when a recipe runs; `$$` for the shell, no `#`) --------------

alt_sh = set -euo pipefail; \
  if [ -t 1 ] && [ -z "$${NO_COLOR:-}" ]; then c_ok=$$'\033[38;2;158;206;106m'; c_warn=$$'\033[38;2;224;175;104m'; c_err=$$'\033[38;2;247;118;142m'; c_info=$$'\033[38;2;122;162;247m'; c_0=$$'\033[0m'; else c_ok=; c_warn=; c_err=; c_info=; c_0=; fi; \
  problems=0; \
  say() { printf '%s>%s %s\n' "$$c_info" "$$c_0" "$$*"; }; \
  ok() { printf '  %sok%s    %s\n' "$$c_ok" "$$c_0" "$$*"; }; \
  warn() { printf '  %swarn%s  %s\n' "$$c_warn" "$$c_0" "$$*"; }; \
  bad() { printf '  %smiss%s  %s\n' "$$c_err" "$$c_0" "$$*"; problems=$$((problems + 1)); }; \
  die() { printf '%serror%s %s\n' "$$c_err" "$$c_0" "$$*" >&2; exit 1; }; \
  have() { command -v "$$1" >/dev/null 2>&1; };

# Sets d, prj, name (the board: the .PrjPcb's name) and out for the part's single Altium project.
alt_find = d="$(CURDIR)/$(2)"; set -- "$$d"/*.PrjPcb; \
  [ -f "$$1" ] || die "no .PrjPcb in $(2): an Altium part is started by saving its project there"; \
  [ -z "$${2:-}" ] || die "several .PrjPcb in $(2): one board per part (a part per board, hardware/<board>)"; \
  prj="$$1"; name=$$(basename "$$prj" .PrjPcb); out="$$d/outputs";

# $(call alt_run,part,dir,mode): the ALT_SH script on the part folder.
alt_run = c_ok="$$c_ok" c_warn="$$c_warn" c_err="$$c_err" c_info="$$c_info" c_0="$$c_0" ALT_LIB="$(ALTIUM_LIBRARY)" ALT_ROOT="$(CURDIR)" \
  bash -c "$$ALT_SH" altium $(3) "$(CURDIR)/$(2)" "$(2)" "$(1)"

# Sets d and windows (1 on a Windows host: Git Bash, MSYS, Cygwin).
alt_host = windows=; case "$$(uname -s)" in MINGW* | MSYS* | CYGWIN*) windows=1;; esac;

# Sets the newline-separated lists gerbers, drills, pnp, bomcsv (the BOM CSVs), boms (those and the BOM xlsx) and pdfs,
# and odb (the ODB++ folder or archive), from <dir>/outputs, whatever subfolders the OutJob made. A drill file is an Excellon file (its M48 header).
alt_outputs = [ -d "$$out" ] || die "no $(2)/outputs: run $$name.OutJob in Altium (it writes to outputs\\), then make $(1)-build"; \
  lst() { find "$$out" -type f \( "$$@" \) 2>/dev/null | LC_ALL=C sort; }; \
  gerbers=$$(lst -iname '*.gbr' -o -iname '*.ger' -o -iname '*.gtl' -o -iname '*.gbl' -o -iname '*.gto' -o -iname '*.gbo' -o -iname '*.gts' -o -iname '*.gbs' \
    -o -iname '*.gtp' -o -iname '*.gbp' -o -iname '*.gko' -o -iname '*.gm' -o -iname '*.gm[0-9]*' -o -iname '*.g[0-9]' -o -iname '*.g[0-9][0-9]' -o -iname '*.gp[0-9]'); \
  odb=$$(find "$$out" -iname 'odb*' 2>/dev/null | LC_ALL=C sort | head -n 1 || true); \
  drills=$$(find "$$out" -type f \( -iname '*.drl' -o -iname '*.txt' -o -iname '*.xln' -o -iname '*.exc' \) -exec grep -l '^M48' {} + 2>/dev/null | LC_ALL=C sort || true); \
  pnp=$$(lst -ipath '*pick*place*' -o -iname '*pnp*' -o -iname '*-pos.*' -o -iname '*cpl*'); \
  bomcsv=$$(lst -iname '*bom*.csv'); boms=$$(lst -iname '*bom*.csv' -o -iname '*bom*.xlsx'); \
  pdfs=$$(lst -iname '*.pdf');
alt_count = $$(printf '%s\n' "$$$(1)" | grep -c . || true)

# The outputs a board needs: Gerber (or ODB++), NC drill, pick and place, the BOM as CSV (1.5), schematic PDF; gerbv
# renders the Gerbers when it is installed (a Gerber it cannot read fails).
alt_verify = say "outputs in $(2)/outputs"; \
  if [ -n "$$gerbers" ]; then ok "Gerber: $(call alt_count,gerbers) files"; elif [ -n "$$odb" ]; then ok "ODB++: $$(printf '%s' "$$odb" | sed "s|^$$out/||")"; else bad "no Gerber or ODB++ files"; fi; \
  if [ -n "$$drills" ]; then ok "NC drill: $(call alt_count,drills) Excellon files"; elif [ -n "$$odb" ]; then ok "NC drill: in the ODB++"; else bad "no NC drill (Excellon) files"; fi; \
  if [ -n "$$pnp" ]; then ok "pick and place: $$(printf '%s\n' "$$pnp" | head -n 1 | sed "s|^$$out/||")"; else bad "no pick and place file (Pick Place, pnp, pos or cpl in its name)"; fi; \
  if [ -n "$$bomcsv" ]; then ok "BOM: $$(printf '%s\n' "$$bomcsv" | head -n 1 | sed "s|^$$out/||")"; \
  elif [ -n "$$boms" ]; then bad "no BOM CSV, only $$(printf '%s\n' "$$boms" | head -n 1 | sed "s|^$$out/||"): add a CSV Bill of Materials output to $$name.OutJob"; \
  else bad "no BOM CSV (a Bill of Materials output of $$name.OutJob, BOM in its name, .csv)"; fi; \
  if [ -n "$$pdfs" ]; then ok "PDF: $(call alt_count,pdfs) files (the schematic among them)"; else bad "no schematic PDF"; fi; \
  if [ -n "$$gerbers" ] && have $(GERBV); then \
    if printf '%s\n' "$$gerbers" | tr '\n' '\0' | xargs -0 $(GERBV) -x png -o "$$out/gerbv-check.png" >/dev/null 2>&1; then ok "gerbv reads the Gerbers ($(2)/outputs/gerbv-check.png)"; else bad "gerbv could not read the Gerbers"; fi; \
  elif [ -n "$$gerbers" ]; then warn "gerbv not installed: Gerbers not rendered (brew install gerbv)"; fi; \
  [ "$$problems" -eq 0 ] || die "$(1): $$problems output(s) missing from $(2)/outputs: run $$name.OutJob in Altium (its output path is outputs\\)";

alt_build = $(alt_sh) $(call alt_find,$(1),$(2)) $(alt_host) \
  if [ -n "$$windows" ]; then say "$$name: run $$name.OutJob in Altium Designer (it writes to outputs\\); this checks what it made"; \
  else say "$$name: Altium Designer runs on Windows only: the outputs come from $$name.OutJob run there into $(2)/outputs; this checks what is there"; fi; \
  $(call alt_outputs,$(1),$(2)) $(call alt_verify,$(1),$(2)) \
  ok "$(1): outputs complete in $(2)/outputs"

alt_check = $(alt_sh) $(call alt_run,$(1),$(2),check)

alt_layout = $(alt_sh) $(call alt_find,$(1),$(2)) $(call alt_run,$(1),$(2),plan)

# GitHub Release assets (make <part>-release-assets, after check and build unless NOBUILD=1): the fab zip (Gerber and
# drill files, or the ODB++, flat; also kept as <dir>/production/<Board>_v<rev>.zip for ordering) and the pick and place,
# BOM (CSV, and xlsx when the OutJob writes one) and PDF files of outputs/. Outside CI, uncommitted changes refuse.
alt_release_assets = $(alt_sh) $(call alt_find,$(1),$(2)) \
  if [ -z "$${CI:-}$${GITHUB_ACTIONS:-}" ] && [ -n "$$(git status --porcelain -- "$$d" ':!'"$$d/outputs" ':!'"$$d/production" ':!'"$$d/release" ':!'"$$d/.venv" 2>/dev/null)" ]; then die "uncommitted changes in $(2): commit them, a release is made from its tag"; fi; \
  $(call alt_outputs,$(1),$(2)) $(call alt_verify,$(1),$(2)) \
  $(call std_rel_begin,$(1),altium,$(2)) \
  zipf="$$d/production/$${name}_v$$ver.zip"; mkdir -p "$$d/production"; rm -f "$$zipf"; \
  if [ -n "$$gerbers" ]; then fab=$$(printf '%s\n%s\n' "$$gerbers" "$$drills" | grep . || true); \
  elif [ -d "$$odb" ]; then fab=$$(find "$$odb" -type f | LC_ALL=C sort); else fab="$$odb"; fi; \
  say "fab zip $(2)/production/$$(basename "$$zipf")"; \
  if have zip; then printf '%s\n' "$$fab" | zip -q -X -j "$$zipf" -@; \
  else printf '%s\n' "$$fab" | python3 -c 'import os, sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED); [z.write(p, os.path.basename(p)) for p in sys.stdin.read().split("\n") if p]; z.close()' "$$zipf"; fi; \
  need "$$zipf"; \
  printf '%s\n' "$$pnp" "$$boms" "$$pdfs" | while IFS= read -r f; do if [ -n "$$f" ]; then put "$$f"; fi; done; \
  $(std_rel_end)

# The BOM is the OutJob's (1.5): the first outputs/**/*BOM*.csv.
alt_bom = $(alt_sh) $(call alt_find,$(1),$(2)) \
  bom=$$(find "$$out" -type f -iname '*bom*.csv' 2>/dev/null | LC_ALL=C sort | head -n 1 || true); \
  say "sourcing and pricing are the bom skill's job, on the BOM $$name.OutJob writes: run the OutJob in Altium first, then ask Claude, in this project:"; \
  if [ -n "$$bom" ]; then bomrel="$(2)/outputs/$$(printf '%s' "$$bom" | sed "s|^$$out/||")"; else bomrel="$(2)/outputs/<the BOM CSV of the OutJob>"; fi; \
  printf '\n    use the bom skill on %s\n    (Altium project %s, fab JLCPCB)\n\n' "$$bomrel" "$$name.PrjPcb"; \
  if [ -n "$$bom" ]; then say "BOM: $$bomrel (from $$name.OutJob)"; \
  else say "no BOM CSV in $(2)/outputs yet: run $$name.OutJob in Altium (its Bill of Materials output, as CSV), then make $(1)-bom"; fi; \
  for e in "$$d"/[Bb][Oo][Mm]; do if [ -d "$$e" ]; then b=$$(basename "$$e"); warn "$(2)/$$b/: the BOM is the one the OutJob writes since 1.5: remove it (git rm -r $(2)/$$b)"; fi; done

alt_version = $(alt_sh) d="$(CURDIR)/$(2)"; rev=; if [ -f "$$d/VERSION" ]; then rev=$$(head -n 1 "$$d/VERSION" | tr -d '[:space:]'); fi; \
  [ -n "$$rev" ] || die "no revision: write it to $(2)/VERSION"; printf '%s %s\n' "$(1)" "$$rev"

# --- the shared Altium library (1.4) --------------------------------------------------------------

# Sets lib (the library's folder), pin (the commit the project pins it at: its gitlink in the index; empty when it is no
# submodule) and venv (the part's .venv for the library's tools); vpy prints its python (Scripts\python.exe on Windows).
alt_lib = lib="$(CURDIR)/$(ALTIUM_LIBRARY)"; venv="$(CURDIR)/$(2)/.venv"; \
  vpy() { if [ -x "$$venv/Scripts/python.exe" ]; then printf '%s\n' "$$venv/Scripts/python.exe"; else printf '%s\n' "$$venv/bin/python"; fi; }; \
  pin=$$(git ls-files -s -- "$(ALTIUM_LIBRARY)" 2>/dev/null | awk '$$1 == "160000" { print $$2; exit }' || true);

# The tools' venv: made with ALTIUM_PYTHON and the library's tools/requirements.txt installed, again only when that
# file changed since (the copy in .venv/.std-requirements).
alt_venv = req="$$lib/tools/requirements.txt"; \
  if [ -x "$$(vpy)" ] && { [ ! -f "$$req" ] || cmp -s "$$req" "$$venv/.std-requirements"; }; then :; else \
    have $(ALTIUM_PYTHON) || die "$(ALTIUM_PYTHON) not found: the Altium library's check is Python (mise use -g python@3.13, or ALTIUM_PYTHON=)"; \
    say "the Altium library's tools into $(2)/.venv (tools/requirements.txt)"; \
    $(ALTIUM_PYTHON) -m venv "$$venv" || die "$(ALTIUM_PYTHON) -m venv $(2)/.venv failed"; \
    if [ -f "$$req" ]; then "$$(vpy)" -m pip install -q --disable-pip-version-check -r "$$req" || die "pip could not install $(ALTIUM_LIBRARY)/tools/requirements.txt into $(2)/.venv"; \
      cp "$$req" "$$venv/.std-requirements"; fi; \
  fi;

# The fix for a library that is not checked out.
alt_lib_fix = if [ -n "$$pin" ]; then die "$(1): the Altium library $(ALTIUM_LIBRARY) is not checked out: git submodule update --init -- $(ALTIUM_LIBRARY) (or make $(1)-setup)"; \
  else die "$(1): no Altium library submodule at $(ALTIUM_LIBRARY): make $(1)-setup adds it ($(ALTIUM_LIBRARY_PROJECT)), then git submodule update --init -- $(ALTIUM_LIBRARY) in every other clone"; fi;

alt_setup = $(alt_sh) $(call alt_lib,$(1),$(2)) say "$(1): the Altium library $(ALTIUM_LIBRARY)"; \
  if ! git rev-parse --git-dir >/dev/null 2>&1; then warn "not in a git repository: the Altium library is a submodule (git init first)"; \
  elif [ -z "$$pin" ]; then \
    url="$(ALTIUM_LIBRARY_URL)"; \
    if [ -z "$$url" ]; then warn "no Altium library submodule, and ALTIUM_LIBRARY_PROJECT is not set (no GitHub owner): add the remote origin or set ALTIUM_LIBRARY_PROJECT := <owner>/altium-library in make/project.mk"; \
    else \
      if [ -n "$$(ls -A "$$lib" 2>/dev/null)" ]; then die "$(ALTIUM_LIBRARY) exists and is not a submodule: move it away, then make $(1)-setup adds the submodule"; fi; \
      say "adding $(ALTIUM_LIBRARY_PROJECT) as the submodule $(ALTIUM_LIBRARY) ($$url)"; \
      git submodule add -- "$$url" "$(ALTIUM_LIBRARY)" || die "could not add the submodule: check that you can read $(ALTIUM_LIBRARY_PROJECT) (gh repo view $(ALTIUM_LIBRARY_PROJECT))"; \
      ok "submodule $(ALTIUM_LIBRARY) added: commit .gitmodules and $(ALTIUM_LIBRARY)"; \
    fi; \
  elif [ ! -e "$$lib/.git" ]; then \
    git submodule update --init -- "$(ALTIUM_LIBRARY)" || die "git submodule update --init -- $(ALTIUM_LIBRARY) failed: check that you can read $(ALTIUM_LIBRARY_PROJECT)"; \
    ok "submodule $(ALTIUM_LIBRARY) checked out at its pinned commit $${pin:0:12}"; \
  else \
    at=$$(git -C "$$lib" rev-parse HEAD 2>/dev/null || true); \
    if [ "$$at" = "$$pin" ]; then ok "submodule $(ALTIUM_LIBRARY) at its pinned commit $${pin:0:12}"; \
    else warn "submodule $(ALTIUM_LIBRARY) is at $${at:0:12}, not its pinned $${pin:0:12}: git submodule update -- $(ALTIUM_LIBRARY) (or commit the new pin)"; fi; \
  fi; \
  if [ -f "$$lib/tools/check.py" ]; then $(call alt_venv,$(1),$(2)) ok "the Altium library's tools in $(2)/.venv"; fi

alt_lib_check = $(alt_sh) $(call alt_find,$(1),$(2)) $(call alt_lib,$(1),$(2)) \
  [ -f "$$lib/tools/check.py" ] || { $(call alt_lib_fix,$(1),$(2)) }; \
  $(call alt_venv,$(1),$(2)) \
  say "$(1): the Altium library's check of $(2)/$$name.PrjPcb"; \
  "$$(vpy)" "$$lib/tools/check.py" project "$$prj" --root "$$lib" $(if $(filter 1,$(WARN)),--warn) || die "$(1): the Altium library's check found problems in $$name.PrjPcb (above)"; \
  ok "$(1): $$name.PrjPcb passes the Altium library's check"

# check: the library's check too once the library is checked out; a submodule not checked out is a warning.
alt_check_lib = $(alt_sh) $(call alt_lib,$(1),$(2)) \
  if [ -f "$$lib/tools/check.py" ]; then $(MAKE) --no-print-directory $(1)-lib-check; \
  elif [ -n "$$pin" ]; then warn "$(1): the Altium library $(ALTIUM_LIBRARY) is not checked out, its check skipped: git submodule update --init -- $(ALTIUM_LIBRARY)"; fi

# path= and sha= of the library's submodule, for $$GITHUB_OUTPUT (altium.yml checks it out at that commit).
alt_lib_ref = $(alt_sh) $(call alt_lib,$(1),$(2)) printf 'path=%s\nsha=%s\n' "$(ALTIUM_LIBRARY)" "$$pin"

alt_lib_doctor = $(call alt_lib,$(1),$(2)) \
  if [ -n "$(ALTIUM_LIBRARY_PROJECT)" ]; then ok "Altium library repository: $(ALTIUM_LIBRARY_PROJECT) (from $(STD_ALTIUM_LIBRARY_PROJECT_FROM))"; fi; \
  if [ -z "$$pin" ]; then warn "no Altium library submodule at $(ALTIUM_LIBRARY): make $(1)-setup adds it"; \
  elif [ ! -e "$$lib/.git" ]; then warn "the Altium library $(ALTIUM_LIBRARY) is not checked out: git submodule update --init -- $(ALTIUM_LIBRARY)"; \
  else at=$$(git -C "$$lib" rev-parse HEAD 2>/dev/null || true); \
    if [ "$$at" = "$$pin" ]; then ok "Altium library $(ALTIUM_LIBRARY) at its pinned commit $${pin:0:12}"; \
    elif git -C "$$lib" merge-base --is-ancestor "$$at" "$$pin" 2>/dev/null; then warn "the Altium library $(ALTIUM_LIBRARY) is behind its pinned commit ($${at:0:12}, pinned $${pin:0:12}): git submodule update -- $(ALTIUM_LIBRARY)"; \
    else warn "the Altium library $(ALTIUM_LIBRARY) is at $${at:0:12}, not its pinned $${pin:0:12}: git submodule update -- $(ALTIUM_LIBRARY), or git add $(ALTIUM_LIBRARY) to pin it there"; fi; \
    if [ -x "$$(vpy)" ]; then ok "the library's tools in $(2)/.venv"; else warn "the Altium library's tools are not installed: make $(1)-setup"; fi; \
  fi;

alt_doctor = $(alt_sh) $(alt_host) say "$(1): altium"; \
  if [ -n "$$windows" ]; then ok "Windows: Altium Designer runs the OutJob here"; \
  else ok "$$(uname -s): check, layout and release run here; the outputs come from Altium Designer on Windows"; fi; \
  if git lfs version >/dev/null 2>&1; then ok "git-lfs"; else bad "git-lfs missing (every Altium binary is in LFS): brew install git-lfs"; fi; \
  $(call std_doctor_started,$(1),$(2)) \
  if $(call std_started,$(1),$(2)); then $(call alt_run,$(1),$(2),doctor) || problems=$$((problems + 1)); fi; \
  d="$(CURDIR)/$(2)"; \
  for f in "$$d"/*.PcbDocPreview "$$d"/*.SchDocPreview "$$d"/.~lock.* "$$d"/History "$$d"/__Previews "$$d"/*.PrjPcbStructure; do \
    [ -e "$$f" ] || continue; if git check-ignore -q "$$f" 2>/dev/null; then :; else warn "$$(basename "$$f") is not ignored: add Altium's .gitignore lines (make $(1)-layout says which)"; fi; done; \
  if [ -d "$$d/outputs" ]; then ok "outputs in $(2)/outputs"; else warn "no $(2)/outputs yet: run the OutJob in Altium"; fi; \
  if have $(GERBV); then ok "gerbv (renders the Gerbers in build)"; else warn "gerbv not installed (optional): brew install gerbv"; fi; \
  if have gh; then ok "gh (GitHub Release)"; else warn "gh missing, needed by make $(1)-release: brew install gh"; fi; \
  $(call alt_lib_doctor,$(1),$(2)) \
  if [ "$$problems" -eq 0 ]; then ok "$(1) ready"; else die "$(1): $$problems problem(s), fixes above"; fi

define kind_altium
# the part is started once its folder has an Altium project (std_started in common.mk)
$(1)_START ?= *.PrjPcb

.PHONY: $(1)-doctor $(1)-setup $(1)-check $(1)-lib-check $(1)-lib-ref $(1)-build $(1)-layout $(1)-bom $(1)-release $(1)-version $(1)-clean

$(call std_verb,$(1),doctor,hardware,Check git-lfs and the Altium layout and LFS and ignored previews read only)
$(1)-doctor:
	@$$(call alt_doctor,$(1),$(2))

$(call std_verb,$(1),setup,hardware,Add or check out the shared Altium library submodule and install its tools in $(2)/.venv)
$(1)-setup:
	@$$(call alt_setup,$(1),$(2))

$(call std_verb,$(1),check,hardware,The PrjPcb and its documents and the folder layout and Git LFS and the Altium library check and fail on violations)
$(1)-check:
	@$$(call std_skip_unstarted,$(1),$(2),check) $$(call alt_check,$(1),$(2)); $$(call alt_check_lib,$(1),$(2))

$(call std_extra,$(1),lib-check,hardware,Every part of the PrjPcb against the Altium library with its tools/check.py (WARN=1: findings as warnings))
$(1)-lib-check:
	@$$(call std_skip_unstarted,$(1),$(2),lib-check) $$(call alt_lib_check,$(1),$(2))

# for CI (altium.yml): the library's path and pinned commit, as path= and sha= lines
$(1)-lib-ref:
	@$$(call alt_lib_ref,$(1),$(2))

$(call std_verb,$(1),build,hardware,Verify the OutJob outputs in $(2)/outputs: Gerber or ODB++ and drill and pick and place and BOM CSV and PDF)
$(1)-build:
	@$$(call std_skip_unstarted,$(1),$(2),build) $$(call alt_build,$(1),$(2))

$(call std_extra,$(1),layout,hardware,Print the git mv commands and DocumentPath edits that move the project into the standard layout and move nothing)
$(1)-layout:
	@$$(call alt_layout,$(1),$(2))

$(call std_extra,$(1),bom,hardware,Hand the OutJob BOM in $(2)/outputs to the bom skill for sourcing and pricing)
$(1)-bom:
	@$$(call alt_bom,$(1),$(2))

# A board is published as its GitHub Release, as a KiCad board is (release is github-release; make $(1)-bump tags).
# The outputs are not committed, so the release is made where they are: make $(1)-github-release FORCE=1 after the tag.
$(call std_verb,$(1),release,release,The GitHub Release of the board from the outputs here: same as $(1)-github-release)
$(1)-release:
	@$$(MAKE) --no-print-directory $(1)-github-release

# release.sh reads a hardware kind's revision from <dir>/VERSION; altium passes hardware until release.sh lists altium.
$(call std_release,$(1),altium,$(2),alt_release_assets,check build)

$(call std_verb,$(1),version,release,Board revision from $(2)/VERSION)
$(1)-version:
	@$$(call alt_version,$(1),$(2))

$(call std_verb,$(1),clean,hardware,Remove $(2)/outputs which only the OutJob in Altium makes again)
$(1)-clean:
	@rm -rf "$$(CURDIR)/$(2)/outputs"
endef
