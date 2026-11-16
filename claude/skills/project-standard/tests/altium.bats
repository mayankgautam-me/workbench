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

LFS_LINE='*.SchDoc *.PcbDoc *.SchLib *.PcbLib *.IntLib *.Harness'

# alproject 'more project.mk lines': a project with an altium part in hardware/, LFS lines for the Altium binaries
alproject() {
  mkproject "$P" "PROJECT := demo
PARTS := hardware:altium
$1"
  cp "$STD_TEMPLATES/kinds/altium.mk" "$P/make/kinds/"
  cd "$P"
  git init -q -b main .
  for e in SchDoc PcbDoc SchLib PcbLib IntLib Harness; do printf '*.%s filter=lfs diff=lfs merge=lfs -text lockable\n' "$e"; done >.gitattributes
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
  mkdir -p hardware/bom
  printf 'Comment,Designator,LCSC Part #\r\n10k,R1,C25804\r\n' >hardware/bom/Board_BOM.csv
  echo 2 >hardware/VERSION
  git add -A && git commit -q -m board
}

# A flat project, as Altium leaves one: sheets, harnesses and libraries at the root, BOM/ in upper case.
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
  [[ "$output" == *"BOM/: the sourcing BOM folder is bom/ in lower case"* ]]
  [[ "$output" == *"BOM/APMD_BOM.csv: the sourcing BOM is bom/AirNode_BOM.csv"* ]]
  [[ "$output" != *"AirNode.SchDoc: "* ]]
  run make hardware-layout
  [ "$status" -eq 0 ]
  [[ "$output" == *'mkdir -p "hardware/sheets" "hardware/library"'* ]]
  [[ "$output" == *'git mv "hardware/02-Overview.SchDoc" "hardware/sheets/02-Overview.SchDoc"'* ]]
  [[ "$output" == *'git mv "hardware/03-Power.Harness" "hardware/sheets/03-Power.Harness"'* ]]
  [[ "$output" == *'git mv "hardware/AirNode.PcbLib" "hardware/library/AirNode.PcbLib"'* ]]
  [[ "$output" == *'git mv "hardware/BOM" "hardware/bom.tmp" && git mv "hardware/bom.tmp" "hardware/bom"'* ]]
  [[ "$output" == *'git mv "hardware/bom/APMD_BOM.csv" "hardware/bom/AirNode_BOM.csv"'* ]]
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
  stub_recorder gerbv
  run make hardware-build
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
  run make hardware-release-assets
  [ "$status" -eq 0 ]
  [ -f hardware/production/Board_v2.zip ]
  z="$(unzip -Z1 hardware/production/Board_v2.zip | LC_ALL=C sort | paste -sd' ' -)"
  [ "$z" = "Board-RoundHoles.TXT Board.GBL Board.GBO Board.GBS Board.GKO Board.GTL Board.GTO Board.GTS" ]
  for f in Board_v2.zip "Pick Place for Board.csv" "Board BOM.csv" Board-Schematic.pdf Board_BOM.csv SHA256SUMS; do
    [ -f "hardware/release/2/$f" ] || { echo "missing $f"; false; }
  done
  run make hardware-version
  [ "$output" = "hardware 2" ]
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
