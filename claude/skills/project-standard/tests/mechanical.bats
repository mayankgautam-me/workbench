#!/usr/bin/env bats
# Kind mechanical (FreeCAD through freecadcmd). freecadcmd is a stub that runs the kind's own FreeCAD script with
# python3 against a fake FreeCAD module (FreeCAD, Import, Mesh), so the script's logic runs without FreeCAD: a model
# file's text says what the fake document holds (BROKEN: a feature that fails to recompute, HIDDEN: a hidden body,
# CORRUPT: it does not open). Models are committed as Git LFS pointers where a test needs git.

load helpers

setup() {
  std_setup_env
  stub_gh
  R="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  P="$R/proj"
  command -v python3 >/dev/null || skip "python3 is not installed"
  fake_freecad
  stub_cmd freecadcmd 'printf "%s\n" "$@" >>"$STUB_LOG/freecadcmd.argv"
[ "${1:-}" = --version ] && { echo "FreeCAD 1.0.2 Revision: 39319 (Git)"; exit 0; }
PYTHONPATH="'"$R"'/fakefc" exec python3 "$1"'
}

fake_freecad() {
  mkdir -p "$R/fakefc"
  cat >"$R/fakefc/FreeCAD.py" <<'EOF'
class Shape:
    def __init__(self, null=False):
        self.null = null
    def isNull(self):
        return self.null
class Obj:
    def __init__(self, label, type_id, derived=(), visible=True):
        self.Label, self.TypeId, self._d, self.Visibility = label, type_id, derived, visible
        self.State, self.Shape, self.InList = [], Shape(), []
    def isDerivedFrom(self, t):
        return t in self._d
    def isValid(self):
        return "Invalid" not in self.State
class Doc:
    def __init__(self, name, objs):
        self.Name, self.Objects = name, objs
    def recompute(self):
        pass
def openDocument(path):
    text = open(path).read()
    if text.startswith("version https://git-lfs") or "CORRUPT" in text:
        raise Exception("not a FreeCAD document")
    body = Obj("Body", "PartDesign::Body")
    pad = Obj("Pad", "PartDesign::Pad", ("Part::Feature",))
    pad.InList = [body]
    objs = [body, pad]
    if "HIDDEN" in text:
        objs.append(Obj("Spare Body", "PartDesign::Body", visible=False))
        objs.append(Obj("Bracket", "Part::Box", ("Part::Feature",)))
    if "BROKEN" in text:
        pad.State = ["Touched", "Invalid"]
    return Doc(path, objs)
def closeDocument(name):
    pass
EOF
  printf 'def export(objs, path):\n    open(path, "w").write("STEP " + ",".join(o.Label for o in objs) + "\\n")\n' >"$R/fakefc/Import.py"
  printf 'def export(objs, path):\n    open(path, "w").write("STL " + ",".join(o.Label for o in objs) + "\\n")\n' >"$R/fakefc/Mesh.py"
}

# meproject 'more project.mk lines'
meproject() {
  mkproject "$P" "PROJECT := demo
PARTS := mechanical:mechanical
$1"
  cp "$STD_TEMPLATES/kinds/mechanical.mk" "$P/make/kinds/"
  cd "$P"
  git init -q -b main .
  printf '*.FCStd filter=lfs diff=lfs merge=lfs -text\n' >.gitattributes
  mkdir -p mechanical/parts
}

models() {
  echo model >mechanical/Enclosure.FCStd
  echo HIDDEN >mechanical/parts/Lid.FCStd
  echo 3 >mechanical/VERSION
}

@test "mechanical check opens and recomputes every model, subfolders too, through freecadcmd" {
  meproject
  models
  run make mechanical-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok    Enclosure.FCStd: 2 objects recompute cleanly"* ]]
  [[ "$output" == *"ok    Lid.FCStd: 4 objects recompute cleanly"* ]]
  [[ "$output" == *"mechanical: every model opens and recomputes"* ]]
  [[ "$(cat "$STUB_LOG/freecadcmd.argv")" == *"std_fc.py"* ]]
}

@test "mechanical check fails on a model that does not recompute or does not open" {
  meproject
  models
  echo BROKEN >mechanical/Enclosure.FCStd
  echo CORRUPT >mechanical/parts/Lid.FCStd
  run make mechanical-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"miss  Enclosure.FCStd: recompute errors in Pad"* ]]
  [[ "$output" == *"miss  Lid.FCStd: does not open in FreeCAD"* ]]
  [[ "$output" == *"FreeCAD check failed"* ]]
}

@test "mechanical build exports each visible top-level body and part to STEP and STL, not its features or hidden bodies" {
  meproject
  models
  run make mechanical-build
  [ "$status" -eq 0 ]
  [ "$(cat mechanical/outputs/Enclosure-Body.step)" = "STEP Body" ]
  [ "$(cat mechanical/outputs/Enclosure-Body.stl)" = "STL Body" ]
  [ -f mechanical/outputs/Lid-Bracket.step ] && [ -f mechanical/outputs/Lid-Body.stl ]
  [ ! -e mechanical/outputs/Enclosure-Pad.step ]
  [ ! -e mechanical/outputs/Lid-Spare_Body.step ]
  [[ "$output" == *"mechanical: 6 files in mechanical/outputs"* ]]
}

@test "mechanical: a freecadcmd that does not run the script is an error, not a pass" {
  meproject
  models
  stub_cmd freecadcmd 'exit 0'
  run make mechanical-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"freecadcmd did not finish the script"* ]]
}

@test "mechanical check: a model committed as a plain blob, an LFS pointer not pulled and a missing LFS line fail" {
  meproject
  models
  git add -A && git commit -q -m models
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%064d\nsize 9\n' 0 >mechanical/parts/Lid.FCStd
  printf '' >.gitattributes
  echo model >mechanical/Base.FCStd
  run make mechanical-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"Enclosure.FCStd is committed as a plain blob, not through Git LFS"* ]]
  [[ "$output" == *"parts/Lid.FCStd is an LFS pointer, not the model: git lfs pull"* ]]
  [[ "$output" == *"Base.FCStd is not covered by a Git LFS line in .gitattributes"* ]]
  [ ! -f "$STUB_LOG/freecadcmd.argv" ]
}

@test "mechanical: a part not started yet (no .FCStd): check and build skip, release refuses" {
  meproject
  for v in check build; do
    run make "mechanical-$v"
    [ "$status" -eq 0 ]
    [[ "$output" == *"> mechanical: not started yet (no *.FCStd or */*.FCStd in mechanical): $v skipped"* ]]
  done
  run make mechanical-release-assets
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to release"* ]]
  [ ! -f "$STUB_LOG/freecadcmd.argv" ]
}

@test "mechanical release-assets: STEP, STL and the models in release/<rev> with SHA256SUMS; version from VERSION" {
  meproject
  models
  run make mechanical-release-assets
  [ "$status" -eq 0 ]
  for f in Enclosure-Body.step Enclosure-Body.stl Lid-Body.step Lid-Bracket.stl Enclosure.FCStd Lid.FCStd SHA256SUMS; do
    [ -f "mechanical/release/3/$f" ] || { echo "missing $f"; false; }
  done
  run make mechanical-version
  [ "$output" = "mechanical 3" ]
}

@test "mechanical doctor: finds freecadcmd and its version, or says how to install it" {
  meproject
  models
  run make mechanical-doctor
  [[ "$output" == *"freecadcmd $STUBS/freecadcmd (FreeCAD 1.0.2)"* ]]
  rm "$STUBS/freecadcmd"
  run make mechanical-doctor FREECAD_APP_PATHS=/nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"freecadcmd not found: brew install --cask freecad"* ]]
  run make mechanical-check FREECAD_APP_PATHS=/nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"freecadcmd not found"* ]]
}
