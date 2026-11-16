# project-standard v1.3 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
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
#   bom/<Board>_BOM.csv   VERSION README.md CHANGELOG.md   outputs/ production/ (generated, ignored)
# The documents of the board are Markdown in docs/<dir>/ at the project root.
# Per-part settings: none needed. The revision is <dir>/VERSION; a release's files go to <dir>/release/<rev>/.
# Global: GERBV (gerbv, optional: build renders the Gerbers with it when it is installed).

GERBV ?= gerbv

# The layout, document and Git LFS checks, a bash script run as bash -c "$$ALT_SH" altium MODE DIR REL PART with
# MODE check (violations fail), doctor (violations warn) or plan (print the git mv commands and DocumentPath= edits).
define ALT_SH
# altium layout and git checks: bash -c "$$ALT_SH" altium MODE PARTDIR RELDIR PART
#   MODE check   every violation as a "miss" line, exit 1 when there is one
#   MODE doctor  the same as "warn" lines, exit 0
#   MODE plan    the git mv commands and the DocumentPath= edits that move the part into the layout
# The layout (standard.md): <Board>.PrjPcb, <Board>.SchDoc (top sheet), <Board>.PcbDoc and <Board>.OutJob at the
# part root; sheets/NN-Name.SchDoc and sheets/NN-Name.Harness; library/*.SchLib *.PcbLib *.IntLib and library/models/
# for 3D models; bom/<Board>_BOM.csv; outputs/ and production/ generated.
set -euo pipefail
mode=$$1 d=$$2 rel=$$3 part=$$4
cd "$$d"
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
  -not -path './__Previews/*' -not -path './Project Logs for *' -not -path './Project Outputs for *' | LC_ALL=C sort)
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

# 4. bom/ in lower case, holding <Board>_BOM.csv.
bomdir=
for e in *; do
  [ -d "$$e" ] || continue
  case $$(lc "$$e") in bom) bomdir=$$e ;; esac
done
if [ -n "$$bomdir" ] && [ "$$bomdir" != bom ]; then
  bad "$$bomdir/: the sourcing BOM folder is bom/ in lower case ($$fix)"
  add_move "$$bomdir" "bom"
fi
if [ -n "$$bomdir" ]; then
  csvs=()
  for f in "$$bomdir"/*.csv "$$bomdir"/*.CSV; do [ -f "$$f" ] && csvs+=("$${f#*/}"); done
  if [ "$${#csvs[@]}" -eq 1 ] && [ "$${csvs[0]}" != "$${board}_BOM.csv" ]; then
    bad "$$bomdir/$${csvs[0]}: the sourcing BOM is bom/$${board}_BOM.csv ($$fix)"
    add_move "bom/$${csvs[0]}" "bom/$${board}_BOM.csv"
  fi
fi

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
alt_run = c_ok="$$c_ok" c_warn="$$c_warn" c_err="$$c_err" c_info="$$c_info" c_0="$$c_0" bash -c "$$ALT_SH" altium $(3) "$(CURDIR)/$(2)" "$(2)" "$(1)"

# Sets d and windows (1 on a Windows host: Git Bash, MSYS, Cygwin).
alt_host = windows=; case "$$(uname -s)" in MINGW* | MSYS* | CYGWIN*) windows=1;; esac;

# Sets the newline-separated lists gerbers, drills, pnp, boms and pdfs and odb (the ODB++ folder or archive) from
# <dir>/outputs, whatever subfolders the OutJob made. A drill file is an Excellon file (its M48 header).
alt_outputs = [ -d "$$out" ] || die "no $(2)/outputs: run $$name.OutJob in Altium (it writes to outputs\\), then make $(1)-build"; \
  lst() { find "$$out" -type f \( "$$@" \) 2>/dev/null | LC_ALL=C sort; }; \
  gerbers=$$(lst -iname '*.gbr' -o -iname '*.ger' -o -iname '*.gtl' -o -iname '*.gbl' -o -iname '*.gto' -o -iname '*.gbo' -o -iname '*.gts' -o -iname '*.gbs' \
    -o -iname '*.gtp' -o -iname '*.gbp' -o -iname '*.gko' -o -iname '*.gm' -o -iname '*.gm[0-9]*' -o -iname '*.g[0-9]' -o -iname '*.g[0-9][0-9]' -o -iname '*.gp[0-9]'); \
  odb=$$(find "$$out" -iname 'odb*' 2>/dev/null | LC_ALL=C sort | head -n 1 || true); \
  drills=$$(find "$$out" -type f \( -iname '*.drl' -o -iname '*.txt' -o -iname '*.xln' -o -iname '*.exc' \) -exec grep -l '^M48' {} + 2>/dev/null | LC_ALL=C sort || true); \
  pnp=$$(lst -ipath '*pick*place*' -o -iname '*pnp*' -o -iname '*-pos.*' -o -iname '*cpl*'); \
  boms=$$(lst -iname '*bom*.csv' -o -iname '*bom*.xlsx' -o -iname '*bom*.xls'); \
  pdfs=$$(lst -iname '*.pdf');
alt_count = $$(printf '%s\n' "$$$(1)" | grep -c . || true)

# The outputs a board needs: Gerber (or ODB++), NC drill, pick and place, BOM, schematic PDF; gerbv renders the Gerbers
# when it is installed (a Gerber it cannot read fails).
alt_verify = say "outputs in $(2)/outputs"; \
  if [ -n "$$gerbers" ]; then ok "Gerber: $(call alt_count,gerbers) files"; elif [ -n "$$odb" ]; then ok "ODB++: $$(printf '%s' "$$odb" | sed "s|^$$out/||")"; else bad "no Gerber or ODB++ files"; fi; \
  if [ -n "$$drills" ]; then ok "NC drill: $(call alt_count,drills) Excellon files"; elif [ -n "$$odb" ]; then ok "NC drill: in the ODB++"; else bad "no NC drill (Excellon) files"; fi; \
  if [ -n "$$pnp" ]; then ok "pick and place: $$(printf '%s\n' "$$pnp" | head -n 1 | sed "s|^$$out/||")"; else bad "no pick and place file (Pick Place, pnp, pos or cpl in its name)"; fi; \
  if [ -n "$$boms" ]; then ok "BOM: $$(printf '%s\n' "$$boms" | head -n 1 | sed "s|^$$out/||")"; else bad "no BOM (BOM in its name, csv or xlsx)"; fi; \
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
# drill files, or the ODB++, flat; also kept as <dir>/production/<Board>_v<rev>.zip for ordering), the pick and place,
# BOM and PDF files of outputs/, and bom/<Board>_BOM.csv. Outside CI, uncommitted changes refuse.
alt_release_assets = $(alt_sh) $(call alt_find,$(1),$(2)) \
  if [ -z "$${CI:-}$${GITHUB_ACTIONS:-}" ] && [ -n "$$(git status --porcelain -- "$$d" ':!'"$$d/outputs" ':!'"$$d/production" ':!'"$$d/release" 2>/dev/null)" ]; then die "uncommitted changes in $(2): commit them, a release is made from its tag"; fi; \
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
  opt "$$d/bom/$${name}_BOM.csv"; \
  $(std_rel_end)

alt_bom = $(alt_sh) $(call alt_find,$(1),$(2)) \
  say "sourcing and pricing are the bom skill's job. Ask Claude, in this project:"; \
  printf '\n    use the bom skill on %s\n    (Altium project %s, fab JLCPCB)\n\n' "$(2)/bom/$${name}_BOM.csv" "$$name.PrjPcb"; \
  if [ -f "$$d/bom/$${name}_BOM.csv" ]; then say "sourcing BOM: $(2)/bom/$${name}_BOM.csv"; else say "no $(2)/bom/$${name}_BOM.csv yet: export the BOM from Altium (or the OutJob) there"; fi

alt_version = $(alt_sh) d="$(CURDIR)/$(2)"; rev=; if [ -f "$$d/VERSION" ]; then rev=$$(head -n 1 "$$d/VERSION" | tr -d '[:space:]'); fi; \
  [ -n "$$rev" ] || die "no revision: write it to $(2)/VERSION"; printf '%s %s\n' "$(1)" "$$rev"

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
  if [ "$$problems" -eq 0 ]; then ok "$(1) ready"; else die "$(1): $$problems problem(s), fixes above"; fi

define kind_altium
# the part is started once its folder has an Altium project (std_started in common.mk)
$(1)_START ?= *.PrjPcb

.PHONY: $(1)-doctor $(1)-check $(1)-build $(1)-layout $(1)-bom $(1)-release $(1)-version $(1)-clean

$(call std_verb,$(1),doctor,hardware,Check git-lfs and the Altium layout and LFS and ignored previews read only)
$(1)-doctor:
	@$$(call alt_doctor,$(1),$(2))

$(call std_verb,$(1),check,hardware,The PrjPcb and its documents and the folder layout and Git LFS and fail on violations)
$(1)-check:
	@$$(call std_skip_unstarted,$(1),$(2),check) $$(call alt_check,$(1),$(2))

$(call std_verb,$(1),build,hardware,Verify the OutJob outputs in $(2)/outputs: Gerber or ODB++ and drill and pick and place and BOM and PDF)
$(1)-build:
	@$$(call std_skip_unstarted,$(1),$(2),build) $$(call alt_build,$(1),$(2))

$(call std_extra,$(1),layout,hardware,Print the git mv commands and DocumentPath edits that move the project into the standard layout and move nothing)
$(1)-layout:
	@$$(call alt_layout,$(1),$(2))

$(call std_extra,$(1),bom,hardware,Hand sourcing and pricing to the bom skill)
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
