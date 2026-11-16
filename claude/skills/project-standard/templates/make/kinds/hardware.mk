# project-standard v1.4 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind hardware: a KiCad board (one .kicad_pro per part dir), driven by kicad-cli.
#
# make/project.mk declares it as   <name>:hardware[:<dir>]. The shared symbol / footprint / 3D
# library is wherever KICAD_LIBRARY_DIR says (set it once per machine in
# $(STD_CONFIG)/config.mk). When it is unset, the library is the one KiCad itself points at: the
# <KICAD_LIB_PREFIX>_LIB_DIR path variable in KiCad's kicad_common.json (under KICAD_PREFS_ROOT, the
# version folder of the KiCad major that kicad-cli reports, else the highest one present).
# `make <part>-setup` checks KiCad's global path variables and library tables against it and, with
# APPLY=1, adds what is missing (after a backup, never changing an existing entry); doctor says
# where the library path came from.
#
# Global settings (config.mk or the command line), with their defaults:
#   KICAD_VERSION        10.0     KiCad major.minor; its preferences are in KICAD_PREFS
#   KICAD_CLI            kicad-cli
#   KICAD_LIBRARY_DIR    (unset)  the shared kicad-library checkout (unset: KiCad's <prefix>_LIB_DIR)
#   KICAD_PREFS_ROOT     KiCad's preferences folder (macOS ~/Library/Preferences/kicad, else ~/.config/kicad)
#   KICAD_LIB_PREFIX     FABROLABS   path variables <prefix>_LIB_DIR, _3DMODEL_DIR, _DATASHEET_DIR
#   KICAD_LIB_SYMBOLS    Symbols, KICAD_LIB_FOOTPRINTS Footprints, KICAD_LIB_3D "3D Models",
#   KICAD_LIB_DATASHEETS Datasheets   sub-folders of the library
#   KICAD_COMPANY        company in the title block of new boards
#   KICAD_LCSC_FIELD     "LCSC Part"   symbol field with the LCSC number (JLCPCB BOM)
#   KICAD_IBOM           InteractiveHtmlBom's generate_interactive_bom.py (found in KiCad's 3rd
#                        party plugin folder when unset); KICAD_PYTHON runs it
# Per-part settings (<part>_<VAR>): SEVERITY (--severity-error: warnings do not fail check),
# TEMPLATE (the skill's templates/hardware), LIBRARY (empty: the shared library above; local: the board's own
# sym-lib-table and fp-lib-table, whose entries point inside the project with ${KIPRJMOD}, are its library: setup and
# doctor check those tables and need none of the shared library's variables, and CI checks out no KiCad library for
# the part: scaffold writes `library: local` on its jobs).
# KICAD_LIBRARY_PROJECT (owner/name of the shared library's repository; make/project.mk wins over the user config,
# default <owner>/kicad-library) is where make ci-setup adds the KiCad deploy key; doctor prints it. The revision is <dir>/VERSION, else the rev of the board's title block.
# Outputs go to <dir>/outputs/, the fab zip to <dir>/production/<Board>_v<rev>.zip, a release's files to
# <dir>/release/<rev>/. make <part>-bump sets VERSION and tags <part>-v<rev>; <part>-release is the GitHub Release.

KICAD_VERSION ?= 10.0
KICAD_CLI ?= kicad-cli
KICAD_LIBRARY_DIR ?=
KICAD_LIB_PREFIX ?= FABROLABS
KICAD_LIB_SYMBOLS ?= Symbols
KICAD_LIB_FOOTPRINTS ?= Footprints
KICAD_LIB_3D ?= 3D Models
KICAD_LIB_DATASHEETS ?= Datasheets
KICAD_COMPANY ?=
KICAD_LCSC_FIELD ?= LCSC Part
STD_SKILL_DIR ?= $(HOME)/.claude/skills/project-standard
KICAD_PREFS_ROOT ?= $(if $(filter Darwin,$(shell uname -s)),$(HOME)/Library/Preferences/kicad,$(HOME)/.config/kicad)
KICAD_PREFS ?= $(KICAD_PREFS_ROOT)/$(KICAD_VERSION)
KICAD_IBOM ?= $(firstword $(wildcard \
  $(HOME)/Documents/KiCad/$(KICAD_VERSION)/3rdparty/plugins/org_openscopeproject_InteractiveHtmlBom/generate_interactive_bom.py \
  $(HOME)/.local/share/kicad/$(KICAD_VERSION)/3rdparty/plugins/org_openscopeproject_InteractiveHtmlBom/generate_interactive_bom.py))
KICAD_PYTHON ?= $(or $(wildcard /Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3),python3)

# --- helpers (shell text expanded when a recipe runs; `$$` for the shell, no `#`) --------------

hw_sh = set -euo pipefail; \
  if [ -t 1 ] && [ -z "$${NO_COLOR:-}" ]; then c_ok=$$'\033[38;2;158;206;106m'; c_warn=$$'\033[38;2;224;175;104m'; c_err=$$'\033[38;2;247;118;142m'; c_info=$$'\033[38;2;122;162;247m'; c_0=$$'\033[0m'; else c_ok=; c_warn=; c_err=; c_info=; c_0=; fi; \
  problems=0; \
  say() { printf '%s>%s %s\n' "$$c_info" "$$c_0" "$$*"; }; \
  ok() { printf '  %sok%s    %s\n' "$$c_ok" "$$c_0" "$$*"; }; \
  warn() { printf '  %swarn%s  %s\n' "$$c_warn" "$$c_0" "$$*"; }; \
  bad() { printf '  %smiss%s  %s\n' "$$c_err" "$$c_0" "$$*"; problems=$$((problems + 1)); }; \
  die() { printf '%serror%s %s\n' "$$c_err" "$$c_0" "$$*" >&2; exit 1; }; \
  have() { command -v "$$1" >/dev/null 2>&1; }; \
  kc() { $(KICAD_CLI) "$$@"; };

# Sets d, name, pro, sch, pcb, out for the part's single KiCad project.
hw_find = d="$(CURDIR)/$(2)"; set -- "$$d"/*.kicad_pro; \
  [ -f "$$1" ] || die "no .kicad_pro in $(2): start one with make $(1)-new NAME=..."; \
  [ -z "$${2:-}" ] || die "several .kicad_pro in $(2): one board per part (add a part per board in make/project.mk)"; \
  pro="$$1"; name=$$(basename "$$pro" .kicad_pro); sch="$$d/$$name.kicad_sch"; pcb="$$d/$$name.kicad_pcb"; out="$$d/outputs";

# Sets locks to KiCad's lock files of the project (KiCad has it open).
hw_locks = locks=$$(ls -d "$$d"/*.lck 2>/dev/null || true);

# Sets rev: <dir>/VERSION, else the title block rev of the board ("Version 2" -> 2).
hw_rev = rev=; if [ -f "$$d/VERSION" ]; then rev=$$(head -n 1 "$$d/VERSION" | tr -d '[:space:]'); fi; \
  if [ -z "$$rev" ] && [ -f "$$pcb" ]; then rev=$$(sed -nE 's/^[[:space:]]*\(rev "([^"]*)"\).*/\1/p' "$$pcb" | head -n 1 | sed -E 's/^([Vv]ersion|[Rr]evision|[Rr]ev|[Vv])[[:space:]]*//' | tr ' ' '-'); fi; \
  [ -n "$$rev" ] || die "no revision: write it to $(2)/VERSION or set rev in the title block of $$name.kicad_pcb";

hw_check = $(hw_sh) $(call hw_find,$(1),$(2)) mkdir -p "$$out"; rc=0; \
  say "ERC $$name.kicad_sch"; \
  kc sch erc --exit-code-violations $($(1)_SEVERITY) --format report -o "$$out/$$name-erc.rpt" "$$sch" || { rc=1; warn "ERC violations: $$out/$$name-erc.rpt"; }; \
  say "DRC $$name.kicad_pcb with schematic parity"; \
  kc pcb drc --schematic-parity --exit-code-violations $($(1)_SEVERITY) --format report -o "$$out/$$name-drc.rpt" "$$pcb" || { rc=1; warn "DRC violations: $$out/$$name-drc.rpt"; }; \
  if [ "$$rc" -ne 0 ]; then die "$(1): ERC or DRC failed, reports in $(2)/outputs"; fi; ok "$(1): ERC and DRC clean"

# Positions to JLCPCB CPL columns, read from the end of each line so a comma in a value is harmless.
hw_cpl = awk -F, 'NR == 1 { print "Designator,Mid X,Mid Y,Layer,Rotation"; next } { gsub(/"/, ""); side = ($$NF == "top") ? "Top" : "Bottom"; printf "%s,%smm,%smm,%s,%s\n", $$1, $$(NF-3), $$(NF-2), side, $$(NF-1) }'

hw_ibom_run = if [ -n "$(KICAD_IBOM)" ] && [ -f "$(KICAD_IBOM)" ]; then say "iBOM $$name"; \
    "$(KICAD_PYTHON)" "$(KICAD_IBOM)" --no-browser --dest-dir "$$out" --name-format "$$name-ibom" "$$pcb"; \
  else warn "iBOM skipped: InteractiveHtmlBom not found (install it with KiCad's Plugin and Content Manager, or set KICAD_IBOM)"; fi;

hw_build = $(hw_sh) $(call hw_find,$(1),$(2)) $(hw_locks) \
  [ -z "$$locks" ] || warn "KiCad has $$name open: unsaved changes are not in these outputs"; \
  mkdir -p "$$out/gerbers"; \
  inner=$$(grep -oE '^[[:space:]]*\([0-9]+ "In[0-9]+\.Cu"' "$$pcb" | grep -oE 'In[0-9]+\.Cu' | paste -sd, - || true); \
  layers="F.Cu,$${inner:+$$inner,}B.Cu,F.Paste,B.Paste,F.SilkS,B.SilkS,F.Mask,B.Mask,Edge.Cuts"; \
  say "gerbers ($$layers) and drill into outputs/gerbers"; \
  kc pcb export gerbers -o "$$out/gerbers/" --layers "$$layers" "$$pcb"; \
  kc pcb export drill -o "$$out/gerbers/" --format excellon --excellon-units mm --generate-map --map-format gerberx2 "$$pcb"; \
  say "positions and JLCPCB CPL"; \
  kc pcb export pos -o "$$out/$$name-pos.csv" --format csv --units mm --side both --exclude-dnp "$$pcb"; \
  if [ -f "$$out/$$name-pos.csv" ]; then $(hw_cpl) "$$out/$$name-pos.csv" > "$$out/$$name-cpl-jlcpcb.csv"; fi; \
  say "BOM and JLCPCB BOM"; \
  kc sch export bom -o "$$out/$$name-bom.csv" "$$sch"; \
  kc sch export bom -o "$$out/$$name-bom-jlcpcb.csv" --fields 'Value,Reference,Footprint,$(KICAD_LCSC_FIELD)' --labels 'Comment,Designator,Footprint,LCSC Part \#' --group-by 'Value,Footprint,$(KICAD_LCSC_FIELD)' --exclude-dnp "$$sch"; \
  say "schematic PDF"; kc sch export pdf -o "$$out/$$name-schematic.pdf" "$$sch"; \
  say "STEP and WRL"; kc pcb export step -o "$$out/$$name.step" --subst-models --force "$$pcb"; \
  kc pcb export vrml -o "$$out/$$name.wrl" --units mm --force "$$pcb"; \
  $(hw_ibom_run) \
  ok "$(1): outputs in $(2)/outputs"

hw_ibom = $(hw_sh) $(call hw_find,$(1),$(2)) mkdir -p "$$out"; $(hw_ibom_run)

hw_render = $(hw_sh) $(call hw_find,$(1),$(2)) mkdir -p "$$out"; \
  for side in top bottom; do say "render $$side"; kc pcb render -o "$$out/$$name-$$side.png" --side "$$side" --quality high --width 1600 --height 1200 "$$pcb"; done; \
  ok "$(1): renders in $(2)/outputs"

# GitHub Release assets (make <part>-release-assets, after check and build unless NOBUILD=1): the fab zip
# (gerbers and drill, also kept as <dir>/production/<Board>_v<rev>.zip for ordering), BOM and JLCPCB BOM, positions
# and JLCPCB CPL, the IPC-D-356 netlist (when kicad-cli exports it), schematic PDF, iBOM, STEP, WRL, the renders
# when make <part>-render made them, and the ERC and DRC reports. Outside CI, uncommitted changes refuse.
hw_release_assets = $(hw_sh) $(call hw_find,$(1),$(2)) $(hw_locks) o="$$out"; \
  [ -z "$$locks" ] || die "KiCad has $$name open ($$locks): save and close it before a release"; \
  if [ -z "$${CI:-}$${GITHUB_ACTIONS:-}" ] && [ -n "$$(git status --porcelain -- "$$d" ':!'"$$d/outputs" ':!'"$$d/production" ':!'"$$d/release" 2>/dev/null)" ]; then die "uncommitted changes in $(2): commit them, a release is made from its tag"; fi; \
  [ -d "$$o/gerbers" ] || die "no $(2)/outputs/gerbers: run make $(1)-build"; \
  $(call std_rel_begin,$(1),hardware,$(2)) \
  zipf="$$d/production/$${name}_v$$ver.zip"; mkdir -p "$$d/production"; rm -f "$$zipf"; \
  say "fab zip $(2)/production/$$(basename "$$zipf")"; \
  if have zip; then (cd "$$o/gerbers" && zip -q -X "$$zipf" ./*); else (cd "$$o/gerbers" && python3 -m zipfile -c "$$zipf" ./*); fi; \
  need "$$zipf"; \
  if kc pcb export ipcd356 --help >/dev/null 2>&1; then kc pcb export ipcd356 -o "$$o/$$name.ipc356" "$$pcb" || warn "IPC-D-356 export failed"; fi; \
  for f in "$$name-bom.csv" "$$name-bom-jlcpcb.csv" "$$name-pos.csv" "$$name-cpl-jlcpcb.csv" "$$name-schematic.pdf"; do need "$$o/$$f"; done; \
  for f in "$$name.ipc356" "$$name-ibom.html" "$$name.step" "$$name.wrl" "$$name-top.png" "$$name-bottom.png" "$$name-erc.rpt" "$$name-drc.rpt"; do opt "$$o/$$f"; done; \
  $(std_rel_end)

hw_new = $(hw_sh) name="$(NAME)"; [ -n "$$name" ] || die "NAME= is required (the board name, for example NAME=SensorNode)"; \
  case "$$name" in *[!A-Za-z0-9_-]*) die "NAME=$$name: letters, digits, dash and underscore only";; esac; \
  layers="$(or $(LAYERS),2)"; case "$$layers" in 2|4) ;; *) die "LAYERS=$$layers: the template has 2 and 4 layer boards";; esac; \
  dest="$(CURDIR)/$(or $(DIR),$(2))"; tpl="$($(1)_TEMPLATE)"; \
  [ -d "$$tpl" ] || die "template $$tpl not found (set $(1)_TEMPLATE or STD_SKILL_DIR)"; \
  if ls "$$dest"/*.kicad_pro >/dev/null 2>&1; then die "$$dest already has a KiCad project: one board per part dir (DIR= for another)"; fi; \
  mkdir -p "$$dest"; date=$$(date +%Y-%m-%d); \
  co=$$(printf '%s' "$(KICAD_COMPANY)" | sed 's/[\\&|]/\\&/g'); \
  render() { sed -e "s|@@NAME@@|$$name|g" -e "s|@@DATE@@|$$date|g" -e "s|@@COMPANY@@|$$co|g" -e "s|@@UUID@@|$$(uuidgen | tr '[:upper:]' '[:lower:]')|g" "$$1" > "$$2"; }; \
  render "$$tpl/board.kicad_sch" "$$dest/$$name.kicad_sch"; \
  render "$$tpl/$${layers}layer/board.kicad_pro" "$$dest/$$name.kicad_pro"; \
  render "$$tpl/$${layers}layer/board.kicad_pcb" "$$dest/$$name.kicad_pcb"; \
  [ -f "$$dest/VERSION" ] || echo 1 > "$$dest/VERSION"; \
  ga="$$dest/.gitattributes"; touch "$$ga"; \
  while IFS= read -r line; do [ -z "$$line" ] || grep -qxF "$$line" "$$ga" || printf '%s\n' "$$line" >> "$$ga"; done < "$$tpl/gitattributes"; \
  ok "$$name: $${layers}-layer board with JLCPCB rules in $$dest (revision 1 in VERSION)"; \
  say "open $$dest/$$name.kicad_pro in KiCad; the shared library comes from make $(1)-setup"

# Sets lib (the shared library folder) and lib_from (where that came from): KICAD_LIBRARY_DIR, else the
# <prefix>_LIB_DIR path variable in KiCad's kicad_common.json, from the version folder of the major kicad-cli
# reports (its highest minor), else the highest version folder present. Empty when neither has it.
hw_lib = lib="$(KICAD_LIBRARY_DIR)"; lib_from="KICAD_LIBRARY_DIR"; \
  if [ -z "$$lib" ]; then lib_from=; \
    kmaj=$$($(KICAD_CLI) version 2>/dev/null | head -n 1 | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' || true); \
    kfile=$$(for c in "$(KICAD_PREFS_ROOT)"/*/kicad_common.json; do [ -f "$$c" ] || continue; v=$$(basename "$$(dirname "$$c")"); \
        printf '%s %s\n' "$$v" "$$c"; done | sort -t. -k1,1n -k2,2n | \
      awk -v m="$$kmaj" '$$1 !~ /^[0-9]/ { next } { split($$1, a, "."); all = $$0; if (m != "" && a[1] == m) mine = $$0 } END { print (mine != "" ? mine : all) }' | cut -d' ' -f2-); \
    if [ -n "$$kfile" ] && have jq; then \
      lib=$$(jq -r --arg k "$(KICAD_LIB_PREFIX)_LIB_DIR" '.environment.vars[$$k] // empty' "$$kfile" 2>/dev/null || true); \
      [ -z "$$lib" ] || lib_from="$(KICAD_LIB_PREFIX)_LIB_DIR in $$kfile"; \
    fi; \
  fi;

# Library check / apply. Vars and tables are read with jq and grep; APPLY=1 writes only what is
# missing, after copying the three files to a dated backup folder next to them.
hw_setup = $(hw_sh) $(hw_lib) prefs="$(KICAD_PREFS)"; P="$(KICAD_LIB_PREFIX)"; \
  [ -n "$$lib" ] || die "KICAD_LIBRARY_DIR is not set and KiCad has no $(KICAD_LIB_PREFIX)_LIB_DIR: add KICAD_LIBRARY_DIR := <your kicad-library checkout> to $(STD_CONFIG)/config.mk"; \
  [ -d "$$lib" ] || die "the library $$lib (from $$lib_from) does not exist: clone the library there first"; \
  for f in kicad_common.json sym-lib-table fp-lib-table; do [ -f "$$prefs/$$f" ] || die "$$prefs/$$f not found: start KiCad $(KICAD_VERSION) once, then run this again"; done; \
  have jq || die "jq not found: brew install jq"; \
  say "KiCad $(KICAD_VERSION) library setup in $$prefs for $$lib (from $$lib_from)"; \
  vars_add=; \
  for kv in "LIB_DIR=$$lib" "3DMODEL_DIR=$$lib/$(KICAD_LIB_3D)" "DATASHEET_DIR=$$lib/$(KICAD_LIB_DATASHEETS)"; do \
    k="$${P}_$${kv%%=*}"; v=$$(printf '%s' "$$kv" | sed 's/^[^=]*=//'); \
    cur=$$(jq -r --arg k "$$k" '.environment.vars[$$k] // empty' "$$prefs/kicad_common.json"); \
    if [ "$$cur" = "$$v" ]; then ok "$$k"; elif [ -z "$$cur" ]; then bad "$$k is not set"; vars_add="$$vars_add $$k"; \
    else warn "$$k is $$cur, not $$v (left as it is)"; fi; done; \
  sym_add=$$(mktemp); fp_add=$$(mktemp); trap 'rm -f "$$sym_add" "$$fp_add"' EXIT; \
  for f in "$$lib/$(KICAD_LIB_SYMBOLS)"/*.kicad_sym; do [ -f "$$f" ] || continue; n=$$(basename "$$f" .kicad_sym); \
    if grep -qF "(name \"$$n\")" "$$prefs/sym-lib-table"; then :; else bad "symbol library $$n not in sym-lib-table"; \
      printf '\t(lib (name "%s") (type "KiCad") (uri "$${%s_LIB_DIR}/%s/%s.kicad_sym") (options "") (descr "%s"))\n' "$$n" "$$P" "$(KICAD_LIB_SYMBOLS)" "$$n" "$$(printf '%s' "$$n" | tr '_' ' ')" >> "$$sym_add"; fi; done; \
  for f in "$$lib/$(KICAD_LIB_FOOTPRINTS)"/*.pretty; do [ -d "$$f" ] || continue; n=$$(basename "$$f" .pretty); \
    if grep -qF "(name \"$$n\")" "$$prefs/fp-lib-table"; then :; else bad "footprint library $$n not in fp-lib-table"; \
      printf '\t(lib (name "%s") (type "KiCad") (uri "$${%s_LIB_DIR}/%s/%s.pretty") (options "") (descr "%s"))\n' "$$n" "$$P" "$(KICAD_LIB_FOOTPRINTS)" "$$n" "$$(printf '%s' "$$n" | tr '_' ' ')" >> "$$fp_add"; fi; done; \
  if [ "$$problems" -eq 0 ]; then ok "KiCad library setup complete"; exit 0; fi; \
  if [ "$(APPLY)" != 1 ]; then die "$$problems missing: run make $(1)-setup APPLY=1 to add them (existing entries are not changed)"; fi; \
  if pgrep -x kicad >/dev/null 2>&1 || pgrep -x eeschema >/dev/null 2>&1 || pgrep -x pcbnew >/dev/null 2>&1; then die "KiCad is running: quit it first, it rewrites these files when it exits"; fi; \
  bk="$$prefs/project-standard-backup-$$(date +%Y%m%d-%H%M%S)"; mkdir -p "$$bk"; \
  cp -p "$$prefs/kicad_common.json" "$$prefs/sym-lib-table" "$$prefs/fp-lib-table" "$$bk/"; say "backup in $$bk"; \
  for k in $$vars_add; do case "$$k" in \
      *_LIB_DIR) v="$$lib";; *_3DMODEL_DIR) v="$$lib/$(KICAD_LIB_3D)";; *) v="$$lib/$(KICAD_LIB_DATASHEETS)";; esac; \
    jq --arg k "$$k" --arg v "$$v" '.environment.vars = ((.environment.vars // {}) + {($$k): $$v})' "$$prefs/kicad_common.json" > "$$prefs/kicad_common.json.tmp"; \
    mv "$$prefs/kicad_common.json.tmp" "$$prefs/kicad_common.json"; ok "set $$k"; done; \
  for pair in "sym-lib-table:$$sym_add" "fp-lib-table:$$fp_add"; do t="$$prefs/$${pair%%:*}"; add=$$(printf '%s' "$$pair" | sed 's/^[^:]*://'); \
    [ -s "$$add" ] || continue; \
    awk -v add="$$add" '{ l[NR] = $$0 } END { last = 0; for (i = NR; i > 0; i--) if (l[i] ~ /^\)[[:space:]]*$$/) { last = i; break }; \
      if (!last) exit 1; for (i = 1; i < last; i++) print l[i]; while ((getline x < add) > 0) print x; for (i = last; i <= NR; i++) print l[i] }' "$$t" > "$$t.tmp" \
      || die "could not find the closing parenthesis of $$t: left unchanged"; \
    mv "$$t.tmp" "$$t"; ok "added $$(grep -c . "$$add") libraries to $$(basename "$$t")"; done; \
  ok "KiCad library setup applied; restart KiCad to load it"

# The project-local library (<part>_LIBRARY := local): the board's sym-lib-table and fp-lib-table, every entry inside the
# project (${KIPRJMOD}/...) and present. An entry on KiCad's own libraries (${KICAD<n>_...}) is fine; one on the shared
# library's variables (${<prefix>_...}) or an absolute path is a problem. ok, warn and bad come from hw_sh.
hw_local_lib = d="$(CURDIR)/$(2)"; \
  for t in sym-lib-table fp-lib-table; do \
    if [ ! -f "$$d/$$t" ]; then bad "$(2)/$$t missing: with $(1)_LIBRARY := local the board's own $$t is its library"; continue; fi; \
    n=0; while IFS= read -r uri; do [ -n "$$uri" ] || continue; n=$$((n + 1)); \
      case "$$uri" in \
        '$${KIPRJMOD}'/*) f="$$d/$${uri\#'$${KIPRJMOD}'/}"; [ -e "$$f" ] || bad "$(2)/$$t: $$uri does not exist";; \
        '$${KICAD'*) ;; \
        '$${$(KICAD_LIB_PREFIX)_'*) bad "$(2)/$$t: $$uri uses the shared library (with $(1)_LIBRARY := local every entry is under \$${KIPRJMOD})";; \
        *) warn "$(2)/$$t: $$uri is outside the project (use \$${KIPRJMOD}/...)";; \
      esac; done < <(sed -n 's/.*(uri "\([^"]*\)").*/\1/p' "$$d/$$t"); \
    ok "$(2)/$$t: $$n librar$$( [ "$$n" = 1 ] && echo y || echo ies) in the project"; \
  done;

# doctor's library lines: the board's own tables (LIBRARY=local, checked once the board exists) or the shared library.
hw_doctor_lib_local = say "library: the board's own tables ($(1)_LIBRARY := local)"; if [ -f "$$1" ]; then $(call hw_local_lib,$(1),$(2)) fi;
hw_doctor_lib_shared = $(hw_lib) if [ -n "$$lib" ]; then ok "library $$lib (from $$lib_from)"; \
  else warn "no shared library: KICAD_LIBRARY_DIR is not set in $(STD_CONFIG)/config.mk and KiCad has no $(KICAD_LIB_PREFIX)_LIB_DIR"; fi; \
  if [ -n "$(KICAD_LIBRARY_PROJECT)" ]; then ok "library repository for CI: $(KICAD_LIBRARY_PROJECT) (from $(STD_KICAD_LIBRARY_PROJECT_FROM))"; fi; \
  if [ -f "$(KICAD_PREFS)/kicad_common.json" ] && have jq; then \
    for s in LIB_DIR 3DMODEL_DIR DATASHEET_DIR; do k="$(KICAD_LIB_PREFIX)_$$s"; v=$$(jq -r --arg k "$$k" '.environment.vars[$$k] // empty' "$(KICAD_PREFS)/kicad_common.json"); \
      if [ -n "$$v" ] && [ -d "$$v" ]; then ok "$$k"; elif [ -n "$$v" ]; then bad "$$k points at $$v, which does not exist"; else bad "$$k not set: make $(1)-setup APPLY=1"; fi; done; \
  else warn "KiCad $(KICAD_VERSION) preferences not found in $(KICAD_PREFS) (or jq missing)"; fi;

# setup of a part with its own library: check its tables; nothing goes into KiCad's global tables. Not started yet: skipped.
hw_setup_local = $(hw_sh) $(call std_skip_unstarted,$(1),$(2),library setup) \
  say "$(1): the board's own library ($(1)_LIBRARY := local): KiCad's global tables and the shared library variables are not needed"; \
  $(call hw_local_lib,$(1),$(2)) \
  if [ "$$problems" -eq 0 ]; then ok "$(1): library tables complete"; else die "$(1): $$problems problem(s) in the board's library tables, fixes above"; fi

hw_doctor = $(hw_sh) say "$(1): hardware, KiCad $(KICAD_VERSION)"; \
  if have $(KICAD_CLI); then v=$$($(KICAD_CLI) version 2>/dev/null | head -n 1); \
    case "$$v" in $(KICAD_VERSION)*|$(firstword $(subst ., ,$(KICAD_VERSION))).*) ok "kicad-cli $$v";; *) bad "kicad-cli is $$v, the standard is KiCad $(KICAD_VERSION)";; esac; \
  else bad "kicad-cli: brew install --cask kicad"; fi; \
  d="$(CURDIR)/$(2)"; set -- "$$d"/*.kicad_pro; \
  if [ -f "$$1" ]; then name=$$(basename "$$1" .kicad_pro); ok "project $(2)/$$name.kicad_pro"; \
    $(hw_locks) if [ -n "$$locks" ]; then warn "KiCad has the project open ($$(echo $$locks | xargs -n 1 basename | tr '\n' ' ')): save before build or release"; fi; \
  else warn "$(1): not started yet (no *.kicad_pro in $(2)): check and build skip it, release refuses; start it with make $(1)-new NAME=..."; fi; \
  $(call hw_doctor_lib_$(if $(filter local,$($(1)_LIBRARY)),local,shared),$(1),$(2)) \
  if [ -n "$(KICAD_IBOM)" ] && [ -f "$(KICAD_IBOM)" ]; then ok "InteractiveHtmlBom"; else warn "InteractiveHtmlBom not found: build skips the iBOM"; fi; \
  if git lfs version >/dev/null 2>&1; then ok "git-lfs"; else warn "git-lfs missing (STEP, WRL and zips go to LFS): brew install git-lfs"; fi; \
  if have gh; then ok "gh (GitHub Release)"; else warn "gh missing, needed by make $(1)-release: brew install gh"; fi; \
  if [ "$$problems" -eq 0 ]; then ok "$(1) ready"; else die "$(1): $$problems problem(s), fixes above"; fi

hw_bom = $(hw_sh) $(call hw_find,$(1),$(2)) \
  say "sourcing and pricing are the bom skill's job. Ask Claude, in this project:"; \
  printf '\n    use the bom skill on %s\n    (schematic %s, %s field %s, fab JLCPCB)\n\n' "$(2)/$$name.kicad_sch" "$$name.kicad_sch" "LCSC" "$(KICAD_LCSC_FIELD)"; \
  if [ -f "$$out/$$name-bom.csv" ]; then say "current BOM: $(2)/outputs/$$name-bom.csv and $$name-bom-jlcpcb.csv"; else say "make $(1)-build writes the BOM CSVs first"; fi


hw_version = $(hw_sh) $(call hw_find,$(1),$(2)) $(call hw_rev,$(1),$(2)) printf '%s %s\n' "$(1)" "$$rev"

define kind_hardware
$(1)_SEVERITY ?= --severity-error
# the part is started once its folder has a KiCad project (std_started in common.mk)
$(1)_START ?= *.kicad_pro

$(1)_TEMPLATE ?= $$(STD_SKILL_DIR)/templates/hardware
# empty: the shared library (KICAD_LIBRARY_DIR); local: the board's own sym-lib-table and fp-lib-table
$(1)_LIBRARY ?=

.PHONY: $(1)-doctor $(1)-setup $(1)-check $(1)-build $(1)-release $(1)-clean $(1)-version $(1)-new $(1)-bom $(1)-ibom $(1)-render

$(call std_verb,$(1),doctor,hardware,Check kicad-cli and the library variables and iBOM and warn when KiCad has the board open)
$(1)-doctor:
	@$$(call hw_doctor,$(1),$(2))

$(call std_verb,$(1),setup,hardware,Check KiCad library paths and tables against KICAD_LIBRARY_DIR and APPLY=1 adds what is missing (LIBRARY=local: the board's own tables))
$(1)-setup:
	@$$(if $$(filter local,$$($(1)_LIBRARY)),$$(call hw_setup_local,$(1),$(2)),$$(call hw_setup,$(1),$(2)))

$(call std_extra,$(1),new,hardware,Start a board from the template NAME= and LAYERS=2 or 4 with JLCPCB rules)
$(1)-new:
	@$$(call hw_new,$(1),$(2))

$(call std_verb,$(1),check,hardware,ERC and DRC with schematic parity and fail on violations)
$(1)-check:
	@$$(call std_skip_unstarted,$(1),$(2),check) $$(call hw_check,$(1),$(2))

$(call std_verb,$(1),build,hardware,Gerbers drill positions BOM schematic PDF STEP WRL and iBOM into $(2)/outputs)
$(1)-build:
	@$$(call std_skip_unstarted,$(1),$(2),build) $$(call hw_build,$(1),$(2))

$(call std_extra,$(1),ibom,hardware,Interactive HTML BOM into $(2)/outputs)
$(1)-ibom:
	@$$(call hw_ibom,$(1),$(2))

$(call std_extra,$(1),render,hardware,3D renders of the top and bottom into $(2)/outputs)
$(1)-render:
	@$$(call hw_render,$(1),$(2))

$(call std_extra,$(1),bom,hardware,Hand sourcing and pricing to the bom skill)
$(1)-bom:
	@$$(call hw_bom,$(1),$(2))

# A board is published as its GitHub Release (the release workflow of tag <part>-v<rev>): release is
# github-release (since v7; make $(1)-bump makes the tag, which release no longer does).
$(call std_verb,$(1),release,release,The GitHub Release of the board: same as $(1)-github-release)
$(1)-release:
	@$$(MAKE) --no-print-directory $(1)-github-release

$(call std_release,$(1),hardware,$(2),hw_release_assets,check build)

$(call std_verb,$(1),version,release,Board revision from $(2)/VERSION or the title block)
$(1)-version:
	@$$(call hw_version,$(1),$(2))

$(call std_verb,$(1),clean,hardware,Remove $(2)/outputs)
$(1)-clean:
	@rm -rf "$$(CURDIR)/$(2)/outputs"
endef
