# project-standard v1.5 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind mechanical: FreeCAD models (*.FCStd, in Git LFS), driven headless by freecadcmd.
#
# make/project.mk declares it as   <name>:mechanical[:<dir>]   (dir usually mechanical). check opens every *.FCStd
# of the part folder (subfolders too) and recomputes it; build exports each visible body or part (a PartDesign Body,
# an App::Part, or a top-level Part shape) to STEP and STL in <dir>/outputs/<file>-<label>.step|.stl. The revision is
# <dir>/VERSION; a release's files go to <dir>/release/<rev>/.
# Global settings: FREECADCMD (found when unset: freecadcmd or FreeCADCmd on PATH, else FreeCAD.app's, as the Homebrew
# cask freecad installs it).

FREECADCMD ?=
FREECAD_APP_PATHS ?= /Applications/FreeCAD.app/Contents/Resources/bin/freecadcmd /Applications/FreeCAD.app/Contents/Resources/bin/FreeCADCmd /Applications/FreeCAD.app/Contents/MacOS/FreeCADCmd

# The FreeCAD side, run by freecadcmd as a script file: STD_FC_MODE check (open and recompute) or build (also export),
# STD_FC_FILES the .FCStd files (one per line), STD_FC_OUT the outputs folder, STD_FC_RESULT the file it writes its
# exit status to (freecadcmd does not always pass a script's status on).
define MECH_FC_PY
import os, re, sys
import FreeCAD
mode = os.environ["STD_FC_MODE"]
out = os.environ.get("STD_FC_OUT", "")
rc = 0
def say(s):
    sys.stdout.write(s + "\n")
    sys.stdout.flush()
def safe(s):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", s).strip("_") or "part"
def broken(o):
    st = list(getattr(o, "State", []))
    return "Invalid" in st or "Error" in st or (hasattr(o, "isValid") and not o.isValid())
CONTAINERS = ("PartDesign::Body", "App::Part")
def solid(o):
    if o.TypeId in CONTAINERS:
        return True
    return o.isDerivedFrom("Part::Feature") and not o.Shape.isNull()
def top(o):
    for p in o.InList:
        if p.TypeId in CONTAINERS or p.isDerivedFrom("Part::Feature"):
            return False
    return True
for path in [p for p in os.environ["STD_FC_FILES"].split("\n") if p]:
    base = os.path.splitext(os.path.basename(path))[0]
    try:
        doc = FreeCAD.openDocument(path)
    except Exception as e:
        say("  miss  %s: does not open in FreeCAD: %s" % (os.path.basename(path), e))
        rc = 1
        continue
    doc.recompute()
    bad = [o.Label for o in doc.Objects if broken(o)]
    if bad:
        say("  miss  %s: recompute errors in %s" % (os.path.basename(path), ", ".join(bad)))
        rc = 1
    else:
        say("  ok    %s: %d objects recompute cleanly" % (os.path.basename(path), len(doc.Objects)))
    if mode == "build" and not bad:
        import Import, Mesh
        parts = [o for o in doc.Objects if solid(o) and top(o) and getattr(o, "Visibility", True)]
        if not parts:
            say("  miss  %s: no visible body or part to export" % os.path.basename(path))
            rc = 1
        for o in parts:
            stem = os.path.join(out, "%s-%s" % (safe(base), safe(o.Label)))
            try:
                Import.export([o], stem + ".step")
                Mesh.export([o], stem + ".stl")
                say("  ok    %s.step and .stl" % os.path.basename(stem))
            except Exception as e:
                say("  miss  %s: export failed: %s" % (o.Label, e))
                rc = 1
    FreeCAD.closeDocument(doc.Name)
with open(os.environ["STD_FC_RESULT"], "w") as f:
    f.write("%d\n" % rc)
sys.stdout.flush()
os._exit(rc)
endef
export MECH_FC_PY

# --- helpers (shell text expanded when a recipe runs; `$$` for the shell, no `#`) --------------

mech_sh = set -euo pipefail; \
  if [ -t 1 ] && [ -z "$${NO_COLOR:-}" ]; then c_ok=$$'\033[38;2;158;206;106m'; c_warn=$$'\033[38;2;224;175;104m'; c_err=$$'\033[38;2;247;118;142m'; c_info=$$'\033[38;2;122;162;247m'; c_0=$$'\033[0m'; else c_ok=; c_warn=; c_err=; c_info=; c_0=; fi; \
  problems=0; \
  say() { printf '%s>%s %s\n' "$$c_info" "$$c_0" "$$*"; }; \
  ok() { printf '  %sok%s    %s\n' "$$c_ok" "$$c_0" "$$*"; }; \
  warn() { printf '  %swarn%s  %s\n' "$$c_warn" "$$c_0" "$$*"; }; \
  bad() { printf '  %smiss%s  %s\n' "$$c_err" "$$c_0" "$$*"; problems=$$((problems + 1)); }; \
  die() { printf '%serror%s %s\n' "$$c_err" "$$c_0" "$$*" >&2; exit 1; }; \
  have() { command -v "$$1" >/dev/null 2>&1; };

# Sets fc to freecadcmd (empty when not found).
mech_fc = fc="$(FREECADCMD)"; \
  if [ -z "$$fc" ]; then for c in freecadcmd FreeCADCmd; do if have "$$c"; then fc=$$(command -v "$$c"); break; fi; done; fi; \
  if [ -z "$$fc" ]; then for c in $(FREECAD_APP_PATHS); do if [ -x "$$c" ]; then fc="$$c"; break; fi; done; fi;
mech_need_fc = $(mech_fc) [ -n "$$fc" ] || die "freecadcmd not found: brew install --cask freecad (or set FREECADCMD)";

# cd into the part; sets d, out and files (every .FCStd of the part, subfolders too, one per line).
mech_find = d="$(CURDIR)/$(2)"; out="$$d/outputs"; cd "$$d"; \
  files=$$(find "$$d" -type f -name '*.FCStd' -not -path "$$d/outputs/*" -not -path "$$d/release/*" | LC_ALL=C sort); \
  [ -n "$$files" ] || die "no .FCStd in $(2)";

# Git LFS: every tracked .FCStd is an LFS pointer in git and the real file in the work tree (pulled), every .FCStd
# is covered by an LFS line in .gitattributes. Outside a git repository nothing is checked.
mech_lfs = if git rev-parse --git-dir >/dev/null 2>&1; then pre=$$(git rev-parse --show-prefix); \
    while IFS= read -r f; do [ -n "$$f" ] || continue; \
      hdr=$$(git cat-file -p ":$$pre$$f" 2>/dev/null | head -c 64 | tr -d '\000' || true); \
      case "$$hdr" in "version https://git-lfs.github.com/spec/"*) ;; *) bad "$$f is committed as a plain blob, not through Git LFS: git rm --cached \"$$f\" && git add \"$$f\"";; esac; \
      case "$$(head -c 40 "$$f" 2>/dev/null | tr -d '\000' || true)" in "version https://git-lfs.github.com/spec/"*) bad "$$f is an LFS pointer, not the model: git lfs pull";; esac; \
    done < <(git ls-files -- '*.FCStd'); \
    while IFS= read -r f; do [ -n "$$f" ] || continue; \
      a=$$(git check-attr filter -- "$$f" | sed 's/.*: filter: //'); \
      [ "$$a" = lfs ] || bad "$$(basename "$$f") is not covered by a Git LFS line in .gitattributes (the line *.FCStd filter=lfs diff=lfs merge=lfs -text)"; \
    done < <(printf '%s\n' "$$files"); \
  else warn "$(2) is not in a git repository: Git LFS not checked"; fi;

# $(call mech_run,part,dir,mode): MECH_FC_PY through freecadcmd on the files, its status from STD_FC_RESULT.
mech_run = tmpd=$$(mktemp -d); trap 'rm -rf "$$tmpd"' EXIT; printf '%s\n' "$$MECH_FC_PY" > "$$tmpd/std_fc.py"; \
  export STD_FC_MODE=$(3) STD_FC_FILES="$$files" STD_FC_OUT="$$out" STD_FC_RESULT="$$tmpd/rc"; \
  "$$fc" "$$tmpd/std_fc.py" < /dev/null || true; \
  rc=$$(cat "$$tmpd/rc" 2>/dev/null || echo none); \
  [ "$$rc" != none ] || die "freecadcmd did not finish the script (run make $(1)-doctor)"; \
  [ "$$rc" = 0 ] || die "$(1): FreeCAD $(3) failed, above";

mech_check = $(mech_sh) $(call mech_find,$(1),$(2)) $(mech_need_fc) $(mech_lfs) \
  [ "$$problems" -eq 0 ] || die "$(1): $$problems Git LFS problem(s), above"; \
  say "$(1): open and recompute $$(printf '%s\n' "$$files" | grep -c .) model(s) with $$fc"; \
  $(call mech_run,$(1),$(2),check) ok "$(1): every model opens and recomputes"

mech_build = $(mech_sh) $(call mech_find,$(1),$(2)) $(mech_need_fc) mkdir -p "$$out"; \
  say "$(1): STEP and STL of every visible body and part into $(2)/outputs"; \
  $(call mech_run,$(1),$(2),build) ok "$(1): $$(find "$$out" -maxdepth 1 -type f \( -name '*.step' -o -name '*.stl' \) | grep -c .) files in $(2)/outputs"

# GitHub Release assets: every STEP and STL of outputs/ and the .FCStd sources.
mech_release_assets = $(mech_sh) $(call mech_find,$(1),$(2)) cd "$(CURDIR)"; \
  [ -n "$$(find "$$out" -maxdepth 1 -name '*.step' 2>/dev/null)" ] || die "no STEP files in $(2)/outputs: run make $(1)-build"; \
  od="$$out"; $(call std_rel_begin,$(1),mechanical,$(2)) \
  for f in "$$od"/*.step "$$od"/*.stl; do if [ -f "$$f" ]; then put "$$f"; fi; done; \
  printf '%s\n' "$$files" | while IFS= read -r f; do if [ -n "$$f" ]; then put "$$f"; fi; done; \
  $(std_rel_end)

mech_version = $(mech_sh) d="$(CURDIR)/$(2)"; rev=; if [ -f "$$d/VERSION" ]; then rev=$$(head -n 1 "$$d/VERSION" | tr -d '[:space:]'); fi; \
  [ -n "$$rev" ] || die "no revision: write it to $(2)/VERSION"; printf '%s %s\n' "$(1)" "$$rev"

mech_doctor = $(mech_sh) say "$(1): mechanical (FreeCAD)"; $(mech_fc) \
  if [ -n "$$fc" ]; then ok "freecadcmd $$fc ($$("$$fc" --version 2>/dev/null < /dev/null | grep -m 1 -o 'FreeCAD [0-9][0-9.]*' || echo 'version unknown'))"; \
  else bad "freecadcmd not found: brew install --cask freecad (or set FREECADCMD)"; fi; \
  if git lfs version >/dev/null 2>&1; then ok "git-lfs"; else bad "git-lfs missing (the models are in LFS): brew install git-lfs"; fi; \
  $(call std_doctor_started,$(1),$(2)) \
  if $(call std_started,$(1),$(2)); then $(call mech_find,$(1),$(2)) $(mech_lfs) fi; \
  if have gh; then ok "gh (GitHub Release)"; else warn "gh missing, needed by make $(1)-release: brew install gh"; fi; \
  if [ "$$problems" -eq 0 ]; then ok "$(1) ready"; else die "$(1): $$problems problem(s), fixes above"; fi

define kind_mechanical
# the part is started once its folder has a FreeCAD model (std_started in common.mk)
$(1)_START ?= *.FCStd */*.FCStd

.PHONY: $(1)-doctor $(1)-check $(1)-build $(1)-release $(1)-version $(1)-clean

$(call std_verb,$(1),doctor,hardware,Check freecadcmd and git-lfs and that the models are in Git LFS read only)
$(1)-doctor:
	@$$(call mech_doctor,$(1),$(2))

$(call std_verb,$(1),check,hardware,Open and recompute every FCStd headless and check Git LFS and fail on errors)
$(1)-check:
	@$$(call std_skip_unstarted,$(1),$(2),check) $$(call mech_check,$(1),$(2))

$(call std_verb,$(1),build,hardware,STEP and STL of every visible body and part into $(2)/outputs)
$(1)-build:
	@$$(call std_skip_unstarted,$(1),$(2),build) $$(call mech_build,$(1),$(2))

$(call std_verb,$(1),release,release,The GitHub Release of the models: same as $(1)-github-release)
$(1)-release:
	@$$(MAKE) --no-print-directory $(1)-github-release

# release.sh reads a hardware kind's revision from <dir>/VERSION; mechanical passes hardware until release.sh lists it.
$(call std_release,$(1),mechanical,$(2),mech_release_assets,check build)

$(call std_verb,$(1),version,release,Revision from $(2)/VERSION)
$(1)-version:
	@$$(call mech_version,$(1),$(2))

$(call std_verb,$(1),clean,hardware,Remove $(2)/outputs)
$(1)-clean:
	@rm -rf "$$(CURDIR)/$(2)/outputs"
endef
