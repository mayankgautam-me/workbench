#!/usr/bin/env bats
# Hardware kind (KiCad through kicad-cli) against a stub kicad-cli that records its argv, a temp copy of
# KiCad's preferences (never the real ~/Library/Preferences/kicad) and a stub gh. One test runs the
# real kicad-cli on a board made from the template when KiCad is installed.

load helpers

setup() {
  std_setup_env
  stub_recorder kicad-cli
  stub_gh
  stub_cmd pgrep 'exit 1'
  R="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  P="$R/proj"
  PREFS="$R/prefs"
  LIB="$R/kicad-library"
}

# hwproject 'more project.mk lines'
hwproject() {
  mkproject "$P" "PROJECT := demo
PARTS := hardware:hardware
KICAD_PREFS := $PREFS
KICAD_LIBRARY_DIR := $LIB
KICAD_IBOM :=
KICAD_COMPANY := Acme & Co | Ltd
$1"
  cp "$STD_TEMPLATES/kinds/hardware.mk" "$P/make/kinds/"
  cd "$P"
  git init -q -b main .
}

# a board whose files the stub kicad-cli never reads
mkboard() {
  mkdir -p hardware
  : >hardware/Board.kicad_pro
  printf '(kicad_sch\n)\n' >hardware/Board.kicad_sch
  printf '(kicad_pcb\n\t(title_block\n\t\t(title "Board")\n\t\t(rev "Version 2")\n\t)\n\t(layers\n\t\t(0 "F.Cu" signal)\n\t\t(4 "In1.Cu" power)\n\t\t(6 "In2.Cu" power)\n\t\t(2 "B.Cu" signal)\n\t)\n)\n' >hardware/Board.kicad_pcb
}

argv() { cat "$STUB_LOG/$1.argv" 2>/dev/null; }

mkprefs() {
  mkdir -p "$PREFS" "$LIB/Symbols" "$LIB/Footprints/Acme_IC.pretty" "$LIB/3D Models" "$LIB/Datasheets"
  : >"$LIB/Symbols/Acme_IC.kicad_sym"
  : >"$LIB/Symbols/Acme_LED.kicad_sym"
  printf '{\n  "environment": {\n    "vars": {\n      "FABROLABS_LIB_DIR": "%s"\n    }\n  },\n  "other": 1\n}\n' "$LIB" >"$PREFS/kicad_common.json"
  printf '(sym_lib_table\n\t(version 7)\n\t(lib (name "Acme_IC") (type "KiCad") (uri "/keep/me.kicad_sym") (options "") (descr "kept"))\n)\n' >"$PREFS/sym-lib-table"
  printf '(fp_lib_table\n\t(version 7)\n)\n' >"$PREFS/fp-lib-table"
}

@test "hardware-check runs ERC and DRC with schematic parity and exit code flags" {
  hwproject
  mkboard
  run make hardware-check
  [ "$status" -eq 0 ]
  a="$(argv kicad-cli)"
  [[ "$a" == *$'sch\nerc\n--exit-code-violations\n--severity-error'* ]]
  [[ "$a" == *"$P/hardware/Board.kicad_sch"* ]]
  [[ "$a" == *$'pcb\ndrc\n--schematic-parity\n--exit-code-violations\n--severity-error'* ]]
  [[ "$a" == *"$P/hardware/Board.kicad_pcb"* ]]
}

@test "hardware-check fails when kicad-cli reports violations, after running both checks" {
  hwproject
  mkboard
  echo 5 >"$STUB_LOG/kicad-cli.rc"
  run make hardware-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERC or DRC failed"* ]]
  [[ "$(argv kicad-cli)" == *"drc"* ]]
}

@test "hardware-build requests every output type into outputs/" {
  hwproject
  mkboard
  run make hardware-build
  [ "$status" -eq 0 ]
  a="$(argv kicad-cli)"
  for want in $'pcb\nexport\ngerbers' $'pcb\nexport\ndrill' $'pcb\nexport\npos' $'sch\nexport\nbom' \
    $'sch\nexport\npdf' $'pcb\nexport\nstep' $'pcb\nexport\nvrml'; do
    [[ "$a" == *"$want"* ]] || { echo "missing: $want"; false; }
  done
  # inner layers are found in the board and plotted
  [[ "$a" == *"F.Cu,In1.Cu,In2.Cu,B.Cu,F.Paste,B.Paste,F.SilkS,B.SilkS,F.Mask,B.Mask,Edge.Cuts"* ]]
  [[ "$a" == *"$P/hardware/outputs/gerbers/"* ]]
  [[ "$a" == *"$P/hardware/outputs/Board.step"* ]]
  [[ "$a" == *"$P/hardware/outputs/Board.wrl"* ]]
  [[ "$a" == *"$P/hardware/outputs/Board-schematic.pdf"* ]]
  [[ "$a" == *"LCSC Part #"* ]]
  [[ "$output" == *"iBOM skipped"* ]]
}

@test "hardware-build runs the iBOM when the plugin is found" {
  hwproject "KICAD_PYTHON := $R/kpython"
  mkboard
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"%s/ibom.argv"\n' "$STUB_LOG" >"$R/kpython"
  chmod +x "$R/kpython"
  : >"$R/generate_interactive_bom.py"
  run make hardware-build KICAD_IBOM="$R/generate_interactive_bom.py"
  [ "$status" -eq 0 ]
  [[ "$(cat "$STUB_LOG/ibom.argv")" == *$'--dest-dir\n'"$P/hardware/outputs"$'\n--name-format\nBoard-ibom'* ]]
}

@test "the JLCPCB CPL is converted from the positions file" {
  hwproject
  mkboard
  stub_cmd kicad-cli 'if [ "$1 $2 $3" = "pcb export pos" ]; then out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done; printf "Ref,Val,Package,PosX,PosY,Rot,Side\n\"C1\",\"100n, X7R\",\"C_0402\",10.5,-20.25,90,top\n\"U1\",\"MCU\",\"QFN\",1,2,0,bottom\n" >"$out"; fi'
  run make hardware-build
  [ "$status" -eq 0 ]
  run cat hardware/outputs/Board-cpl-jlcpcb.csv
  [ "${lines[0]}" = "Designator,Mid X,Mid Y,Layer,Rotation" ]
  [ "${lines[1]}" = "C1,10.5mm,-20.25mm,Top,90" ]
  [ "${lines[2]}" = "U1,1mm,2mm,Bottom,0" ]
}

@test "hardware-setup reports what is missing, changes nothing, and fails" {
  hwproject
  mkprefs
  before="$(cat "$PREFS/kicad_common.json" "$PREFS/sym-lib-table" "$PREFS/fp-lib-table")"
  run make hardware-setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"FABROLABS_3DMODEL_DIR is not set"* ]]
  [[ "$output" == *"symbol library Acme_LED"* ]]
  [[ "$output" == *"footprint library Acme_IC"* ]]
  [[ "$output" == *"APPLY=1"* ]]
  [ "$(cat "$PREFS/kicad_common.json" "$PREFS/sym-lib-table" "$PREFS/fp-lib-table")" = "$before" ]
  [ -z "$(find "$PREFS" -name 'project-standard-backup-*')" ]
}

@test "hardware-setup APPLY=1 backs up, adds only what is missing, keeps existing entries" {
  hwproject
  mkprefs
  run make hardware-setup APPLY=1
  [ "$status" -eq 0 ]
  bk="$(find "$PREFS" -maxdepth 1 -name 'project-standard-backup-*')"
  [ -f "$bk/kicad_common.json" ] && [ -f "$bk/sym-lib-table" ] && [ -f "$bk/fp-lib-table" ]
  # the existing Acme_IC symbol entry is untouched (its odd uri stays), the missing one is added
  grep -qF '(name "Acme_IC") (type "KiCad") (uri "/keep/me.kicad_sym")' "$PREFS/sym-lib-table"
  grep -qF '(lib (name "Acme_LED") (type "KiCad") (uri "${FABROLABS_LIB_DIR}/Symbols/Acme_LED.kicad_sym") (options "") (descr "Acme LED"))' "$PREFS/sym-lib-table"
  grep -qF '(uri "${FABROLABS_LIB_DIR}/Footprints/Acme_IC.pretty")' "$PREFS/fp-lib-table"
  [ "$(tail -n 1 "$PREFS/sym-lib-table")" = ")" ]
  [ "$(jq -r '.environment.vars.FABROLABS_3DMODEL_DIR' "$PREFS/kicad_common.json")" = "$LIB/3D Models" ]
  [ "$(jq -r '.environment.vars.FABROLABS_DATASHEET_DIR' "$PREFS/kicad_common.json")" = "$LIB/Datasheets" ]
  [ "$(jq -r '.other' "$PREFS/kicad_common.json")" = 1 ]
  run make hardware-setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"complete"* ]]
}

@test "hardware-setup leaves a variable that points elsewhere alone" {
  hwproject
  mkprefs
  printf '{"environment":{"vars":{"FABROLABS_LIB_DIR":"/elsewhere"}}}\n' >"$PREFS/kicad_common.json"
  run make hardware-setup APPLY=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"FABROLABS_LIB_DIR is /elsewhere"* ]]
  [ "$(jq -r '.environment.vars.FABROLABS_LIB_DIR' "$PREFS/kicad_common.json")" = /elsewhere ]
}

@test "hardware-setup refuses without KICAD_LIBRARY_DIR and while KiCad runs" {
  hwproject 'KICAD_LIBRARY_DIR :='
  mkprefs
  run make hardware-setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"KICAD_LIBRARY_DIR is not set"* ]]
  stub_cmd pgrep 'exit 0'
  run make hardware-setup APPLY=1 KICAD_LIBRARY_DIR="$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"KiCad is running"* ]]
  [ -z "$(find "$PREFS" -name 'project-standard-backup-*')" ]
}

@test "hardware-new starts a board from the template and refuses to overwrite" {
  hwproject
  run make hardware-new NAME=Sensor LAYERS=4
  [ "$status" -eq 0 ]
  [ -f hardware/Sensor.kicad_pro ] && [ -f hardware/Sensor.kicad_sch ] && [ -f hardware/Sensor.kicad_pcb ]
  grep -qF '(title "Sensor")' hardware/Sensor.kicad_pcb
  grep -qF '(company "Acme & Co | Ltd")' hardware/Sensor.kicad_sch
  grep -qF '"In1.Cu"' hardware/Sensor.kicad_pcb
  [ "$(jq -r '.meta.filename' hardware/Sensor.kicad_pro)" = Sensor.kicad_pro ]
  [ "$(jq -r '.board.design_settings.rules.min_track_width' hardware/Sensor.kicad_pro)" = 0.09 ]
  ! grep -q '@@' hardware/Sensor.kicad_pro hardware/Sensor.kicad_sch hardware/Sensor.kicad_pcb
  grep -qx '\*.step filter=lfs diff=lfs merge=lfs -text' hardware/.gitattributes
  [ "$(cat hardware/VERSION)" = 1 ]
  run make hardware-new NAME=Other
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has a KiCad project"* ]]
  run make hardware-new NAME='bad name' DIR=hw2
  [ "$status" -ne 0 ]
}

# the outputs make hardware-build writes (the stub kicad-cli writes none)
mkoutputs() {
  mkdir -p hardware/outputs/gerbers
  echo g >hardware/outputs/gerbers/Board-F_Cu.gtl
  echo d >hardware/outputs/gerbers/Board.drl
  for f in Board-bom.csv Board-bom-jlcpcb.csv Board-pos.csv Board-cpl-jlcpcb.csv Board-schematic.pdf Board.wrl Board-erc.rpt; do
    echo "$f" >"hardware/outputs/$f"
  done
}

@test "hardware-release outside the release workflow of its tag refuses, and creates nothing" {
  hwproject
  mkboard
  printf 'outputs/\nproduction/\nrelease/\n' >hardware/.gitignore
  git add -A && git commit -qm board
  mkoutputs
  run make hardware-release NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"workflow of tag hardware-v2"*"FORCE=1"* ]]
  [ ! -f "$STUB_LOG/gh.argv" ]
  GITHUB_ACTIONS=true run make hardware-release NOBUILD=1
  [ "$status" -ne 0 ]
  [ ! -f "$STUB_LOG/gh.argv" ]
}

@test "hardware-release-assets refuses while KiCad has the board open" {
  hwproject
  mkboard
  : >"hardware/~Board.kicad_sch.lck"
  run make hardware-doctor
  [[ "$output" == *"KiCad has the project open"* ]]
  run make hardware-release-assets NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"save and close it"* ]]
  [ ! -d hardware/release ]
}

@test "hardware-release-assets: the fab zip and every output in release/<rev>, with SHA256SUMS; no tag is made" {
  hwproject
  mkboard
  printf 'outputs/\nproduction/\nrelease/\n' >hardware/.gitignore
  git add -A && git commit -qm board
  mkoutputs
  run make hardware-release-assets NOBUILD=1
  [ "$status" -eq 0 ]
  r=hardware/release/2
  [ -f hardware/production/Board_v2.zip ]
  unzip -l "$r/Board_v2.zip" | grep -q 'Board-F_Cu.gtl'
  for f in Board-bom.csv Board-bom-jlcpcb.csv Board-pos.csv Board-cpl-jlcpcb.csv Board-schematic.pdf Board.wrl Board-erc.rpt SHA256SUMS; do
    [ -f "$r/$f" ]
  done
  [[ "$output" == *"skip  Board.step"* ]]
  [ "$(grep -c . "$r/SHA256SUMS")" -eq 8 ]
  [ "$(grep -c SHA256SUMS "$r/SHA256SUMS" || true)" = 0 ]
  # the netlist export is asked for
  [[ "$(argv kicad-cli)" == *$'pcb\nexport\nipcd356\n-o\n'*"Board.ipc356"* ]]
  [ -z "$(git tag -l hardware-v2)" ]
  # uncommitted changes refuse outside CI
  echo x >>hardware/Board.kicad_sch
  run make hardware-release-assets NOBUILD=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "hardware-release in its tag's release workflow creates the GitHub Release with the assets; another part's tag does nothing" {
  hwproject
  mkboard
  mkdir -p hardware
  printf '# Changelog\n\n## [Unreleased]\n\n## [3] - 2026-11-11\n\n### Changed\n\n- new USB connector\n' >hardware/CHANGELOG.md
  echo 3 >hardware/VERSION
  git add -A && git commit -qm board
  mkoutputs
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=hardware-v3 GH_TOKEN=tok \
    run make hardware-release NOBUILD=1
  [ "$status" -eq 0 ]
  a="$(argv gh)"
  [[ "$a" == *$'release\ncreate\nhardware-v3\n'* ]]
  [[ "$a" == *"hardware/release/3/Board_v3.zip"* ]]
  [[ "$a" == *"hardware/release/3/SHA256SUMS"* ]]
  [[ "$a" != *tok* ]]
  rm -f "$STUB_LOG/gh.argv"
  GITHUB_ACTIONS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=firmware-v1 run make hardware-release NOBUILD=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a hardware release"* ]]
  [ ! -f "$STUB_LOG/gh.argv" ]
}

@test "hardware-bom hands over to the bom skill" {
  hwproject
  mkboard
  run make hardware-bom
  [ "$status" -eq 0 ]
  [[ "$output" == *"bom skill"* ]]
  [[ "$output" == *"hardware/Board.kicad_sch"* ]]
}

@test "real kicad-cli: a template board passes ERC and DRC and exports" {
  real="$(PATH="${PATH#"$STUBS:"}" command -v kicad-cli || true)"
  [ -n "$real" ] || skip "kicad-cli is not installed"
  hwproject "KICAD_CLI := $real"
  run make hardware-new NAME=Real LAYERS=2
  [ "$status" -eq 0 ]
  run make hardware-check
  [ "$status" -eq 0 ]
  run make hardware-build
  [ "$status" -eq 0 ]
  [ -f hardware/outputs/gerbers/Real-F_Cu.gtl ]
  [ -f hardware/outputs/gerbers/Real.drl ]
  [ -f hardware/outputs/Real.step ]
  [ -f hardware/outputs/Real.wrl ]
  [ -f hardware/outputs/Real-schematic.pdf ]
}

# KiCad preferences under a fake KICAD_PREFS_ROOT: version folders 9.0 and 10.0, each pointing
# <prefix>_LIB_DIR at its own library.
mkroot() {
  ROOT="$R/kicad-root"
  mkdir -p "$ROOT/9.0" "$ROOT/10.0" "$R/lib9" "$R/lib10" "$ROOT/notaversion"
  printf '{"environment":{"vars":{"FABROLABS_LIB_DIR":"%s"}}}\n' "$R/lib9" >"$ROOT/9.0/kicad_common.json"
  printf '{"environment":{"vars":{"FABROLABS_LIB_DIR":"%s"}}}\n' "$R/lib10" >"$ROOT/10.0/kicad_common.json"
  printf '{"environment":{"vars":{"FABROLABS_LIB_DIR":"/wrong"}}}\n' >"$ROOT/notaversion/kicad_common.json"
}

@test "hardware: without KICAD_LIBRARY_DIR the library is KiCad's own <prefix>_LIB_DIR, for the major kicad-cli reports" {
  mkroot
  hwproject "KICAD_LIBRARY_DIR :=
KICAD_PREFS_ROOT := $R/kicad-root"
  mkprefs
  mkboard
  echo "9.0.4" >"$STUB_LOG/kicad-cli.out"
  run make hardware-setup
  echo "$output"
  [[ "$output" == *"for $R/lib9 (from FABROLABS_LIB_DIR in $R/kicad-root/9.0/kicad_common.json)"* ]]
  run make hardware-doctor
  [[ "$output" == *"library $R/lib9 (from FABROLABS_LIB_DIR in $R/kicad-root/9.0/kicad_common.json)"* ]]
  # a kicad-cli that says nothing: the highest version folder
  : >"$STUB_LOG/kicad-cli.out"
  run make hardware-setup
  [[ "$output" == *"for $R/lib10 (from FABROLABS_LIB_DIR in $R/kicad-root/10.0/kicad_common.json)"* ]]
  # another prefix reads its own variable, and finds none here
  run make hardware-setup KICAD_LIB_PREFIX=ACME
  [ "$status" -ne 0 ]
  [[ "$output" == *"KICAD_LIBRARY_DIR is not set and KiCad has no ACME_LIB_DIR"* ]]
}

@test "hardware: KICAD_LIBRARY_DIR from the config wins over KiCad's setting, and doctor says so" {
  mkroot
  hwproject "KICAD_PREFS_ROOT := $R/kicad-root"
  mkprefs
  mkboard
  run make hardware-setup
  [[ "$output" == *"for $LIB (from KICAD_LIBRARY_DIR)"* ]]
  run make hardware-doctor
  echo "$output"
  [[ "$output" == *"library $LIB (from KICAD_LIBRARY_DIR)"* ]]
}

@test "a hardware part not started yet (no .kicad_pro): check and build skip with exit 0, doctor warns, release refuses" {
  hwproject
  mkdir -p hardware
  echo 1 >hardware/VERSION
  run make hardware-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"> hardware: not started yet (no *.kicad_pro in hardware): check skipped"* ]]
  run make hardware-build
  [ "$status" -eq 0 ]
  [[ "$output" == *"> hardware: not started yet (no *.kicad_pro in hardware): build skipped"* ]]
  [ ! -f "$STUB_LOG/kicad-cli.argv" ] || [[ "$(argv kicad-cli)" != *$'erc\n'* && "$(argv kicad-cli)" != *$'export\n'* ]]
  # the root check fans out to it and passes too
  run make check
  [ "$status" -eq 0 ]
  run make hardware-doctor
  [[ "$output" == *"warn"*"hardware: not started yet (no *.kicad_pro in hardware)"* ]]
  [[ "$output" != *"miss"*"kicad_pro"* ]]
  run make hardware-release-assets
  [ "$status" -ne 0 ]
  [[ "$output" == *"hardware: not started yet (no *.kicad_pro in hardware): nothing to release"* ]]
  [ ! -d hardware/release ]
  run make hardware-release-assets NOBUILD=1
  [ "$status" -ne 0 ]
  # once a board is there, check runs ERC and DRC again
  mkboard
  run make hardware-check
  [ "$status" -eq 0 ]
  [[ "$output" != *"not started yet"* ]]
  [[ "$(argv kicad-cli)" == *$'sch\nerc\n'* ]]
}
