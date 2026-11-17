#!/usr/bin/env bats
# Kind altium (Altium Designer boards; nothing runs Altium): the layout, document and Git LFS checks, the layout
# plan, the verification of the OutJob outputs and the release files, on fake projects in a temp git repo. The
# Altium binaries are committed as Git LFS pointer texts (no git-lfs filter in the test HOME, so git keeps them as
# they are). One test reads a real flat project when it is on this machine, and never changes it.

load helpers

setup() {
  REAL_HOME="$HOME"
  std_setup_env
  stub_gh
  R="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  P="$R/proj"
}

LFS_LINE='*.SchDoc *.PcbDoc *.SchLib *.PcbLib *.IntLib *.Harness *.PrjPcbVariants'

# alproject 'more project.mk lines': a project with an altium part in hardware/ and the .gitattributes lines the
# scaffold writes for it (templates/altium/gitattributes: the binaries in LFS, the .PrjPcb and .OutJob -text)
alproject() {
  mkproject "$P" "PROJECT := demo
PARTS := hardware:altium
$1"
  cp "$STD_TEMPLATES/kinds/altium.mk" "$P/make/kinds/"
  cd "$P"
  git init -q -b main .
  grep -v '^#' "$STD_TEMPLATES/../altium/gitattributes" >.gitattributes
  printf 'hardware/outputs/\nhardware/production/\nhardware/release/\n*.PcbDocPreview\n*.SchDocPreview\n' >.gitignore
  mkdir -p hardware
}

# pointer FILE: an LFS pointer text in FILE (what git stores for a file in LFS)
pointer() {
  mkdir -p "$(dirname "$1")"
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%064d\nsize 1234\n' 0 >"$1"
}

# prjpcb NAME PATH...: hardware/NAME.PrjPcb listing PATH... as its documents (Altium's INI, CRLF, with a UTF-8 BOM)
prjpcb() {
  local name=$1 i=1 p
  shift
  {
    printf '\xEF\xBB\xBF[Design]\r\nVersion=1.0\r\n\r\n'
    for p in "$@"; do printf '[Document%d]\r\nDocumentPath=%s\r\nDocumentUniqueId=%08d\r\n\r\n' "$i" "$p" "$i"; i=$((i + 1)); done
  } >"hardware/$name.PrjPcb"
}

# A project in the standard layout.
conforming() {
  prjpcb Board 'Board.SchDoc' 'sheets\02-Power.SchDoc' 'sheets\02-Power.Harness' 'sheets\03-MCU.SchDoc' 'Board.PcbDoc' \
    'library\Board.SchLib' 'library\Board.PcbLib'
  for f in Board.SchDoc Board.PcbDoc sheets/02-Power.SchDoc sheets/02-Power.Harness sheets/03-MCU.SchDoc \
    library/Board.SchLib library/Board.PcbLib; do pointer "hardware/$f"; done
  printf '[OutputGroup1]\r\nName=Fab\r\n[PublishSettings]\r\nOutputFilePath1=outputs\\\r\n' >hardware/Board.OutJob
  echo 2 >hardware/VERSION
  git add -A && git commit -q -m board
}

# A flat project, as Altium leaves one: sheets, harnesses and libraries at the root, and a BOM/ folder (before 1.5).
flat() {
  prjpcb AirNode 'AirNode.SchDoc' '02-Overview.SchDoc' '03-Power.SchDoc' 'AirNode.PcbDoc' 'AirNode.SchLib' \
    'AirNode.PcbLib' '03-Power.Harness'
  for f in AirNode.SchDoc 02-Overview.SchDoc 03-Power.SchDoc AirNode.PcbDoc AirNode.SchLib AirNode.PcbLib 03-Power.Harness; do
    pointer "hardware/$f"
  done
  mkdir -p hardware/BOM
  printf 'Comment,Designator\r\n' >hardware/BOM/APMD_BOM.csv
  echo 1 >hardware/VERSION
  git add -A && git commit -q -m flat
}

# Outputs as an OutJob writes them: Gerbers and NC drill in their folders, pick and place, BOM, schematic PDF.
outputs() {
  local o=hardware/outputs
  mkdir -p "$o/Gerber" "$o/NC Drill" "$o/Assembly"
  for e in GTL GBL GTO GBO GTS GBS GKO; do echo "%FSLAX46Y46*%" >"$o/Gerber/Board.$e"; done
  printf 'M48\nMETRIC\n%%\nT01\nM30\n' >"$o/NC Drill/Board-RoundHoles.TXT"
  printf 'just a note\n' >"$o/Gerber/Status Report.Txt"
  printf 'Designator,Mid X,Mid Y,Layer,Rotation\nR1,1,2,T,0\n' >"$o/Assembly/Pick Place for Board.csv"
  printf 'Comment,Designator\n10k,R1\n' >"$o/Assembly/Board BOM.csv"
  printf '%%PDF-1.4\n' >"$o/Board-Schematic.pdf"
}

@test "altium: a project in the standard layout passes check, and layout has nothing to move" {
  alproject
  conforming
  run make hardware-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"*"hardware: layout, document paths and Git LFS"* ]]
  run make hardware-layout
  [ "$status" -eq 0 ]
  [[ "$output" == *"hardware already follows the layout, nothing to move"* ]]
}

@test "altium: a flat project fails check with a fix hint for each document, and layout prints the moves without moving" {
  alproject
  flat
  before="$(git status --porcelain; find hardware | LC_ALL=C sort)"
  run make hardware-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"02-Overview.SchDoc: child sheets and harnesses go in sheets/ (make hardware-layout prints the moves)"* ]]
  [[ "$output" == *"AirNode.SchLib: libraries go in library/"* ]]
  [[ "$output" == *'DocumentPath=03-Power.Harness in AirNode.PrjPcb is not in the layout: sheets\03-Power.Harness'* ]]
  [[ "$output" == *"warn"*"BOM/: the BOM is the one AirNode.OutJob writes to outputs/ (*BOM*.csv, since 1.5): remove BOM/ (git rm -r \"hardware/BOM\""* ]]
  [[ "$output" != *"miss  BOM"* ]]
  [[ "$output" != *"AirNode.SchDoc: "* ]]
  run make hardware-layout
  [ "$status" -eq 0 ]
  [[ "$output" == *'mkdir -p "hardware/sheets" "hardware/library"'* ]]
  [[ "$output" == *'git mv "hardware/02-Overview.SchDoc" "hardware/sheets/02-Overview.SchDoc"'* ]]
  [[ "$output" == *'git mv "hardware/03-Power.Harness" "hardware/sheets/03-Power.Harness"'* ]]
  [[ "$output" == *'git mv "hardware/AirNode.PcbLib" "hardware/library/AirNode.PcbLib"'* ]]
  [[ "$output" != *'hardware/BOM'* ]]
  [[ "$output" != *'hardware/bom'* ]]
  [[ "$output" == *'DocumentPath=02-Overview.SchDoc  ->  DocumentPath=sheets\02-Overview.SchDoc'* ]]
  [[ "$output" == *'DocumentPath=AirNode.SchLib  ->  DocumentPath=library\AirNode.SchLib'* ]]
  [[ "$output" != *'git mv "hardware/AirNode.SchDoc"'* ]]
  [[ "$output" != *'git mv "hardware/AirNode.PcbDoc"'* ]]
  [ "$(git status --porcelain; find hardware | LC_ALL=C sort)" = "$before" ]
}

@test "altium: the printed moves and edits, applied, give a project that passes check" {
  alproject
  flat
  make --no-print-directory hardware-layout >plan.txt
  grep -E '^(mkdir|git mv)' plan.txt >moves.sh
  bash -e moves.sh
  sed -n 's/^  DocumentPath=\(.*\)  ->  DocumentPath=\(.*\)$/\1|\2/p' plan.txt >edits.txt
  prj=hardware/AirNode.PrjPcb
  while IFS='|' read -r from to; do
    F="DocumentPath=$from" T="DocumentPath=$to" awk '{ sub(/\r$/, ""); if ($0 == ENVIRON["F"]) $0 = ENVIRON["T"]; printf "%s\r\n", $0 }' "$prj" >"$prj.new"
    mv "$prj.new" "$prj"
  done <edits.txt
  printf '[PublishSettings]\r\nOutputFilePath1=outputs\\\r\n' >hardware/AirNode.OutJob
  rm -f plan.txt moves.sh edits.txt
  git add -A
  run make hardware-check
  [ "$status" -eq 0 ]
}

@test "altium check: a missing or absolute document path, a badly named sheet and a harness without its sheet fail" {
  alproject
  conforming
  prjpcb Board 'Board.SchDoc' 'sheets\02-Power.SchDoc' 'sheets\03-MCU.SchDoc' 'Board.PcbDoc' 'sheets\04-Radio.SchDoc' 'C:\Users\x\Lib.SchLib'
  pointer hardware/sheets/Power.SchDoc
  pointer hardware/sheets/05-Alone.Harness
  run make hardware-check
  [ "$status" -ne 0 ]
  [[ "$output" == *'DocumentPath=sheets\04-Radio.SchDoc in Board.PrjPcb: the file does not exist'* ]]
  [[ "$output" == *'DocumentPath=C:\Users\x\Lib.SchLib in Board.PrjPcb is absolute'* ]]
  [[ "$output" == *"sheets/Power.SchDoc: name child sheets NN-Name.SchDoc"* ]]
  [[ "$output" == *"sheets/05-Alone.Harness: a harness sits beside its sheet of the same name, and there is no 05-Alone.SchDoc"* ]]
}

@test "altium check: an OutJob that writes outside outputs\\ fails" {
  alproject
  conforming
  printf '[PublishSettings]\r\nOutputFilePath1=C:\\Users\\me\\Project Outputs for Board\\\r\n' >hardware/Board.OutJob
  run make hardware-check
  [ "$status" -ne 0 ]
  [[ "$output" == *'Board.OutJob writes to C:\Users\me\Project Outputs for Board\: set its output path to outputs\ (relative to the project)'* ]]
}

@test "altium check: a binary committed as a plain blob, a tracked preview and a missing LFS line fail" {
  alproject
  conforming
  printf 'binary pcb\0data' >hardware/Board.PcbDoc
  echo preview >hardware/Board.PcbDocPreview
  git add hardware/Board.PcbDoc && git add -f hardware/Board.PcbDocPreview && git commit -q -m bad
  grep -v PcbLib .gitattributes >ga && mv ga .gitattributes
  run make hardware-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"hardware/Board.PcbDoc is committed as a plain blob, not through Git LFS"* || "$output" == *"Board.PcbDoc is committed as a plain blob, not through Git LFS"* ]]
  [[ "$output" == *"Board.PcbDocPreview is tracked: Altium's previews"* ]]
  [[ "$output" == *"library/Board.PcbLib is not covered by a Git LFS line in .gitattributes"* ]]
}

@test "altium check 1.2: a .PrjPcbVariants is an LFS binary at the part root; the .PrjPcb and .OutJob need -text" {
  alproject
  conforming
  # a variants file in LFS beside the project: check passes, and the template's lines cover it
  pointer hardware/Board.PrjPcbVariants
  git add -A && git commit -q -m variants
  [ "$(git check-attr filter -- hardware/Board.PrjPcbVariants)" = 'hardware/Board.PrjPcbVariants: filter: lfs' ]
  [ "$(git check-attr text -- hardware/Board.PrjPcb)" = 'hardware/Board.PrjPcb: text: unset' ]
  [ "$(git check-attr text -- hardware/Board.OutJob)" = 'hardware/Board.OutJob: text: unset' ]
  run make hardware-check
  echo "$output"
  [ "$status" -eq 0 ]
  # committed as a plain blob (an OLE compound file), with no LFS line, and without the -text lines: each fails
  printf '\xD0\xCF\x11\xE0binary\0variants' >hardware/Board.PrjPcbVariants
  grep -Ev '^\*\.(PrjPcbVariants|PrjPcb|OutJob) ' .gitattributes >ga && mv ga .gitattributes
  git add -A && git commit -q -m plain
  run make hardware-check
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Board.PrjPcbVariants is committed as a plain blob, not through Git LFS"* ]]
  [[ "$output" == *"Board.PrjPcbVariants is not covered by a Git LFS line in .gitattributes (*.PrjPcbVariants filter=lfs"* ]]
  [[ "$output" == *"Board.PrjPcb is not marked -text in .gitattributes"*"*.PrjPcb -text"* ]]
  [[ "$output" == *"Board.OutJob is not marked -text in .gitattributes"*"*.OutJob -text"* ]]
  # doctor reports the same as warnings
  run make hardware-doctor
  [[ "$output" == *"warn"*"Board.PrjPcb is not marked -text"* ]]
  # in a subfolder it belongs at the part root
  git mv hardware/Board.PrjPcbVariants hardware/library/Board.PrjPcbVariants
  run make hardware-layout
  [[ "$output" == *'git mv "hardware/library/Board.PrjPcbVariants" "hardware/Board.PrjPcbVariants"'* ]]
}

@test "altium: a part not started yet (no .PrjPcb): check and build skip, release refuses, doctor warns" {
  alproject
  for v in check build; do
    run make "hardware-$v"
    [ "$status" -eq 0 ]
    [[ "$output" == *"> hardware: not started yet (no *.PrjPcb in hardware): $v skipped"* ]]
  done
  run make hardware-release-assets
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to release"* ]]
  run make hardware-doctor
  [[ "$output" == *"warn"*"hardware: not started yet (no *.PrjPcb in hardware)"* ]]
}

@test "altium build: says where outputs come from, fails without them, and checks each kind of output" {
  alproject
  conforming
  run make hardware-build
  [ "$status" -ne 0 ]
  [[ "$output" == *"Altium Designer runs on Windows only"* || "$output" == *"run Board.OutJob in Altium Designer"* ]]
  [[ "$output" == *"no hardware/outputs: run Board.OutJob in Altium"* ]]
  outputs
  rm "hardware/outputs/Assembly/Pick Place for Board.csv"
  run make hardware-build
  [ "$status" -ne 0 ]
  [[ "$output" == *"no pick and place file"* ]]
  outputs
  # 1.5: the BOM must be a CSV; an xlsx alone is not enough
  mv "hardware/outputs/Assembly/Board BOM.csv" "hardware/outputs/Assembly/Board BOM.xlsx"
  run make hardware-build
  [ "$status" -ne 0 ]
  [[ "$output" == *"no BOM CSV, only Assembly/Board BOM.xlsx: add a CSV Bill of Materials output to Board.OutJob"* ]]
  rm "hardware/outputs/Assembly/Board BOM.xlsx"
  run make hardware-build
  [ "$status" -ne 0 ]
  [[ "$output" == *"no BOM CSV (a Bill of Materials output of Board.OutJob"* ]]
  outputs
  stub_recorder gerbv
  run make hardware-build
  [[ "$output" == *"BOM: Assembly/Board BOM.csv"* ]]
  [ "$status" -eq 0 ]
  [[ "$output" == *"Gerber: 7 files"* ]]
  [[ "$output" == *"NC drill: 1 Excellon files"* ]]
  [[ "$output" == *"gerbv reads the Gerbers"* ]]
  [[ "$(cat "$STUB_LOG/gerbv.argv")" == $'-x\npng\n-o\n'* ]]
  echo 1 >"$STUB_LOG/gerbv.rc"
  run make hardware-build
  [ "$status" -ne 0 ]
  [[ "$output" == *"gerbv could not read the Gerbers"* ]]
}

@test "altium release-assets: the flat fab zip in production/ and the outputs in release/<rev> with SHA256SUMS" {
  command -v unzip >/dev/null || skip "unzip is not installed"
  alproject
  conforming
  outputs
  printf 'PK' >"hardware/outputs/Assembly/Board BOM.xlsx"
  run make hardware-release-assets
  [ "$status" -eq 0 ]
  [ -f hardware/production/Board_v2.zip ]
  z="$(unzip -Z1 hardware/production/Board_v2.zip | LC_ALL=C sort | paste -sd' ' -)"
  [ "$z" = "Board-RoundHoles.TXT Board.GBL Board.GBO Board.GBS Board.GKO Board.GTL Board.GTO Board.GTS" ]
  for f in Board_v2.zip "Pick Place for Board.csv" "Board BOM.csv" "Board BOM.xlsx" Board-Schematic.pdf SHA256SUMS; do
    [ -f "hardware/release/2/$f" ] || { echo "missing $f"; false; }
  done
  run make hardware-version
  [ "$output" = "hardware 2" ]
}

@test "altium 1.5: the BOM is the OutJob's: bom points at outputs/ and says to run the OutJob first; a bom/ folder only warns" {
  alproject
  conforming
  run make hardware-bom
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run the OutJob in Altium first"* ]]
  [[ "$output" == *"use the bom skill on hardware/outputs/<the BOM CSV of the OutJob>"* ]]
  [[ "$output" == *"no BOM CSV in hardware/outputs yet: run Board.OutJob in Altium"* ]]
  outputs
  run make hardware-bom
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"use the bom skill on hardware/outputs/Assembly/Board BOM.csv"* ]]
  [[ "$output" != *"bom/"* ]]
  # a project from 1.4 with its committed bom/: check passes with a warning, doctor and bom warn too
  mkdir -p hardware/bom
  printf 'Comment,Designator\r\n10k,R1\r\n' >hardware/bom/Board_BOM.csv
  git add -A && git commit -q -m oldbom
  run make hardware-check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn"*"bom/: the BOM is the one Board.OutJob writes to outputs/ (*BOM*.csv, since 1.5): remove bom/"* ]]
  run make hardware-doctor
  [[ "$output" == *"warn"*"bom/: the BOM is the one Board.OutJob writes"* ]]
  run make hardware-bom
  [[ "$output" == *"warn"*"hardware/bom/: the BOM is the one the OutJob writes since 1.5: remove it (git rm -r hardware/bom)"* ]]
  run make hardware-layout
  [ "$status" -eq 0 ]
  [[ "$output" == *"hardware already follows the layout, nothing to move"* ]]
}

@test "altium doctor: warns about previews git does not ignore and passes the layout through as warnings" {
  alproject
  flat
  echo x >hardware/AirNode.SchDocPreview
  mkdir -p hardware/History
  run make hardware-doctor
  [[ "$output" == *"History is not ignored"* ]]
  [[ "$output" != *"AirNode.SchDocPreview is not ignored"* ]]
  [[ "$output" == *"warn"*"02-Overview.SchDoc: child sheets and harnesses go in sheets/"* ]]
  [[ "$output" != *"miss  02-Overview"* ]]
}

@test "altium layout on a real flat project, read only (when it is on this machine)" {
  real="${STD_ALTIUM_SAMPLE:-$REAL_HOME/Projects/I2Sage/airnode/hardware}"
  [ -f "$real/AirNode.PrjPcb" ] || skip "no sample Altium project at $real"
  # The sample must still be flat: a project already laid out (sheets/) has nothing to move. Point STD_ALTIUM_SAMPLE at a flat one.
  [ ! -d "$real/sheets" ] || skip "the sample at $real is already in the standard layout"
  alproject
  cp -R "$real/." hardware/
  git add -A >/dev/null 2>&1 && git commit -q -m sample
  run make hardware-layout
  [ "$status" -eq 0 ]
  [[ "$output" == *'git mv "hardware/02-Overview.SchDoc" "hardware/sheets/02-Overview.SchDoc"'* ]]
  [[ "$output" == *'DocumentPath=AirNode.PcbLib  ->  DocumentPath=library\AirNode.PcbLib'* ]]
}

@test "teardown keeps an altium part's outputs/ (only Altium makes them) and removes its production/ and release/" {
  alproject ''
  mkdir -p hardware/outputs hardware/production hardware/release/1
  echo gerber >hardware/outputs/board.GTL
  echo zip >hardware/production/board_v1.zip
  echo r >hardware/release/1/x
  run make teardown
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"hardware/outputs"* ]]
  run make teardown CONFIRM=teardown
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f hardware/outputs/board.GTL ]
  [ ! -e hardware/production ]
  [ ! -e hardware/release ]
  # make <part>-clean, asked for by name, still removes outputs/
  run make hardware-clean
  [ "$status" -eq 0 ]
  [ ! -e hardware/outputs ]
}

# --- the shared Altium library (1.4): a submodule at hardware/altium-library, from a local repo (no network) --------

# mklib: a library repo in $R/altium-library as the other agent's layout has it, with a fake tools/check.py that
# records its arguments in $STUB_LOG/check.argv and exits with $STUB_LOG/check.rc (0 when absent). Two commits; LIB1 and
# LIB2 are their ids. Git refuses file:// submodules unless protocol.file.allow says otherwise (git 2.38.1).
mklib() {
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  local L="$R/altium-library"
  mkdir -p "$L/sym" "$L/fp" "$L/models" "$L/tools"
  git -C "$L" init -q -b main .
  printf 'MPN,Symbol,Footprint\nRC0402FR-0710KL,Resistor,R0402\n' >"$L/parts.csv"
  printf '[OutsideConnection]\r\nConnectionString=parts.csv\r\n' >"$L/Library.DbLib"
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%064d\nsize 1\n' 1 >"$L/sym/Resistor.SchLib"
  printf '# olefile, none in the test\n' >"$L/tools/requirements.txt"
  cat >"$L/tools/check.py" <<PY
import os, sys
open(os.path.join("$STUB_LOG", "check.argv"), "a").write(" ".join(sys.argv[1:]) + "\n")
print("check.py ran")
rc = os.path.join("$STUB_LOG", "check.rc")
sys.exit(int(open(rc).read()) if os.path.exists(rc) else 0)
PY
  git -C "$L" add -A && git -C "$L" commit -q -m one
  LIB1=$(git -C "$L" rev-parse HEAD)
  printf 'MPN,Symbol,Footprint\nRC0402FR-0710KL,Resistor,R0402\nGRM155R71C104KA88D,Capacitor,C0402\n' >"$L/parts.csv"
  git -C "$L" commit -q -am two
  LIB2=$(git -C "$L" rev-parse HEAD)
}

# libproject: an altium project in the standard layout whose library URL is the local repo
libproject() {
  alproject "ALTIUM_LIBRARY_URL := $R/altium-library
$1"
  conforming
}

@test "altium setup 1.4: adds the library submodule from ALTIUM_LIBRARY_URL and its tools venv; doctor and lib-ref see the pin" {
  mklib
  libproject
  run make hardware-setup
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"submodule hardware/altium-library added: commit .gitmodules and hardware/altium-library"* ]] || false
  [[ "$output" == *"the Altium library's tools in hardware/.venv"* ]] || false
  [ -x hardware/.venv/bin/python ]
  grep -q 'path = hardware/altium-library' .gitmodules
  [ "$(git ls-files -s -- hardware/altium-library | cut -d' ' -f1,2)" = "160000 $LIB2" ]
  git commit -q -m library
  # again: nothing to add, the venv stays
  touch hardware/.venv/marker
  run make hardware-setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"submodule hardware/altium-library at its pinned commit ${LIB2:0:12}"* ]] || false
  [ -f hardware/.venv/marker ]
  run make hardware-doctor
  echo "$output"
  [[ "$output" == *"Altium library hardware/altium-library at its pinned commit"* ]] || false
  [[ "$output" == *"the library's tools in hardware/.venv"* ]] || false
  run make hardware-lib-ref
  [ "$status" -eq 0 ]
  [ "$output" = "path=hardware/altium-library
sha=$LIB2" ]
  # the library's files inside the part folder are not the part's, and its DbLib is a document: the layout check passes
  prjpcb Board 'Board.SchDoc' 'sheets\02-Power.SchDoc' 'sheets\02-Power.Harness' 'sheets\03-MCU.SchDoc' 'Board.PcbDoc' \
    'library\Board.SchLib' 'library\Board.PcbLib' 'altium-library\Library.DbLib'
  git add hardware/Board.PrjPcb && git commit -q -m dblib
  run make hardware-check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"altium-library/sym"* ]] || false
}

@test "altium lib-check 1.4: runs tools/check.py project on the PrjPcb with --root; findings fail; WARN=1 passes --warn; check runs it" {
  mklib
  libproject
  run make hardware-lib-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Altium library submodule at hardware/altium-library: make hardware-setup adds it"*"git submodule update --init -- hardware/altium-library"* ]] || false
  make hardware-setup >/dev/null
  run make hardware-lib-check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check.py ran"* ]] || false
  [ "$(cat "$STUB_LOG/check.argv")" = "project $P/hardware/Board.PrjPcb --root $P/hardware/altium-library" ]
  echo 1 >"$STUB_LOG/check.rc"
  run make hardware-lib-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"the Altium library's check found problems in Board.PrjPcb"* ]] || false
  run make hardware-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"layout, document paths and Git LFS"*"check.py ran"* ]] || false
  rm "$STUB_LOG/check.rc"
  run make hardware-lib-check WARN=1
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$STUB_LOG/check.argv")" = "project $P/hardware/Board.PrjPcb --root $P/hardware/altium-library --warn" ]
}

@test "altium 1.4: a clone without the submodule checked out: check warns and skips the library check, doctor and lib-check give the command, setup checks it out" {
  mklib
  libproject
  make hardware-setup >/dev/null
  git commit -q -m library
  git clone -q "$P" "$R/clone"
  cd "$R/clone"
  rm -rf hardware/outputs
  run make hardware-check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the Altium library hardware/altium-library is not checked out, its check skipped: git submodule update --init -- hardware/altium-library"* ]] || false
  run make hardware-lib-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not checked out: git submodule update --init -- hardware/altium-library"* ]] || false
  run make hardware-doctor
  [[ "$output" == *"the Altium library hardware/altium-library is not checked out: git submodule update --init -- hardware/altium-library"* ]] || false
  run make hardware-setup
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked out at its pinned commit"* ]] || false
  [ -f hardware/altium-library/tools/check.py ]
  # behind its pin: doctor says so
  git -C hardware/altium-library checkout -q "$LIB1"
  run make hardware-doctor
  echo "$output"
  [[ "$output" == *"the Altium library hardware/altium-library is behind its pinned commit (${LIB1:0:12}, pinned ${LIB2:0:12}): git submodule update -- hardware/altium-library"* ]] || false
}

@test "altium check 1.4: a DocumentPath into the library is accepted inside or outside the part folder; a file missing from it fails" {
  mklib
  alproject "ALTIUM_LIBRARY_URL := $R/altium-library
PARTS := main:altium:hardware/main"
  mkdir -p hardware/main
  prjpcb Main 'Main.SchDoc' 'Main.PcbDoc' '..\altium-library\Library.DbLib'
  mv hardware/Main.PrjPcb hardware/main/
  pointer hardware/main/Main.SchDoc
  pointer hardware/main/Main.PcbDoc
  git add -A && git commit -q -m main
  # not checked out yet: the DbLib is not looked for
  run make main-check
  echo "$output"
  [ "$status" -eq 0 ]
  make main-setup >/dev/null
  run make main-check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check.py ran"* ]] || false
  sed -i.bak 's/Library.DbLib/Missing.DbLib/' hardware/main/Main.PrjPcb && rm hardware/main/Main.PrjPcb.bak
  run make main-check
  [ "$status" -ne 0 ]
  [[ "$output" == *'DocumentPath=..\altium-library\Missing.DbLib in Main.PrjPcb: the file is not in the Altium library hardware/altium-library'* ]] || false
  [[ "$output" != *"points outside the part folder"* ]] || false
}

@test "altium 1.4: ALTIUM_LIBRARY_PROJECT from make/project.mk, the config or the owner; the URL follows origin for the same owner" {
  alproject ""
  printf 'show:\n\t@echo "P=$(ALTIUM_LIBRARY_PROJECT) FROM=$(STD_ALTIUM_LIBRARY_PROJECT_FROM) URL=$(ALTIUM_LIBRARY_URL)"\n' >make/local.mk
  git remote add origin git@github.com:Acme/demo.git
  run make show
  [ "$output" = "P=acme/altium-library FROM=owner URL=../altium-library.git" ]
  mkdir -p "$STD_CONFIG"
  printf 'ALTIUM_LIBRARY_PROJECT := beta/parts\n' >"$STD_CONFIG/config.mk"
  run make show
  [ "$output" = "P=beta/parts FROM=config URL=https://github.com/beta/parts.git" ]
  printf 'ALTIUM_LIBRARY_PROJECT := acme/alib\n' >>make/project.mk
  run make show
  [ "$output" = "P=acme/alib FROM=make/project.mk URL=../alib.git" ]
}

@test "ci-setup-help 1.4: an altium part gets the Altium library's deploy key and ALTIUM_LIBRARY_REPO; no altium part, none" {
  alproject "ALTIUM_LIBRARY_PROJECT := beta/alib"
  git remote add origin git@github.com:acme/demo.git
  run make ci-setup-help
  echo "$output"
  [[ "$output" == *"gh repo deploy-key add ~/.ssh/demo-ci-altium.pub --repo beta/alib --title demo-ci-read-only"* ]] || false
  [[ "$output" == *"gh secret set ALTIUM_LIBRARY_DEPLOY_KEY --repo acme/demo < ~/.ssh/demo-ci-altium"* ]] || false
  [[ "$output" == *"gh variable set ALTIUM_LIBRARY_REPO --repo acme/demo --body beta/alib"* ]] || false
  [[ "$output" != *"KICAD_LIBRARY"* ]] || false
  mkproject "$P" "PROJECT := demo
PARTS :=
ALTIUM_LIBRARY_PROJECT := beta/alib"
  run make ci-setup-help
  [[ "$output" != *"ALTIUM"* ]] || false
}

@test "ci-setup 1.4: an altium part's deploy key goes to the Altium library and its secret and variable to the project" {
  alproject ""
  git remote add origin git@github.com:acme/demo.git
  mkdir -p "$HOME/.ssh"
  stub_cmd gh 'printf "%s\n" "$*" >>"$STUB_LOG/gh.calls"
case "$1 $2" in
  "repo view") case "$*" in *visibility*) echo PUBLIC ;; esac; exit 0 ;;
  "repo deploy-key") case "$3" in list) cat "$STUB_LOG/keys" 2>/dev/null ;; add) cut -d" " -f1,2 "$4" >>"$STUB_LOG/keys" ;; esac ;;
  "secret set") printf "%s %s\n" "$3" "$(wc -c | tr -d " ")" >>"$STUB_LOG/secrets" ;;
esac
exit 0'
  stub_cmd ssh-keygen 'while [ $# -gt 0 ]; do [ "$1" = -f ] && f=$2; shift; done
printf "PRIVATE\n" >"$f"; printf "ssh-ed25519 AAAAfake%s c\n" "$RANDOM" >"$f.pub"'
  run make ci-setup STD_SECRETS=:
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q 'repo deploy-key add .*demo-ci-altium.pub --repo acme/altium-library --title demo-ci-read-only' "$STUB_LOG/gh.calls"
  grep -q '^ALTIUM_LIBRARY_DEPLOY_KEY [1-9]' "$STUB_LOG/secrets"
  grep -q 'variable set ALTIUM_LIBRARY_REPO --repo acme/demo --body acme/altium-library' "$STUB_LOG/gh.calls"
  ! grep -q KICAD "$STUB_LOG/gh.calls"
  [[ "$output" != *"PRIVATE"* ]] || false
}
