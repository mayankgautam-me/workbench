#!/usr/bin/env bats
# Tests for scripts/audit.sh. Every project audited here is built in $BATS_TEST_TMPDIR; the real
# ~/Projects folders are never touched.

if [[ -f "$BATS_TEST_DIRNAME/helpers.bash" ]]; then
  load helpers
fi

SA_HEADER='# project-standard v1.14 (managed: refresh with the project-standard skill, put project changes in make/local.mk)'
SA_KINDS="zephyr espidf pio arm-gcc circuitpython hardware cloud-worker web-pages app-flutter app-tauri app-xcode app-android docker go python"

setup() {
  SA_REAL_SKILL=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export NO_COLOR=1
  export STD_CONFIG="$BATS_TEST_TMPDIR/config"
  export SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
  unset CI_TEMPLATES_REPO CI_TEMPLATES_PROJECT GITHUB_OWNER GITLAB_GROUP
  mkdir -p "$STD_CONFIG"
  printf 'GITHUB_OWNER := example-owner\n' >"$STD_CONFIG/config.mk"
}

# Same as in scaffold.bats: a skill copy with fakes for managed templates not written yet.
sa_skill_copy() {
  local dst="$BATS_TEST_TMPDIR/skill" k f
  if [[ -d $dst ]]; then
    echo "$dst"
    return 0
  fi
  mkdir -p "$dst"
  cp -R "$SA_REAL_SKILL/scripts" "$SA_REAL_SKILL/templates" "$dst/"
  [[ -d "$SA_REAL_SKILL/ci-templates" ]] && cp -R "$SA_REAL_SKILL/ci-templates" "$dst/"
  mkdir -p "$dst/templates/make/bin" "$dst/templates/make/kinds"
  [[ -f "$dst/templates/make/common.mk" ]] || printf '%s\nhelp:\n\t@echo help\n' "$SA_HEADER" >"$dst/templates/make/common.mk"
  for f in lib.sh secrets.sh cf.sh; do
    [[ -f "$dst/templates/make/bin/$f" ]] || printf '#!/usr/bin/env bash\n%s\n' "$SA_HEADER" >"$dst/templates/make/bin/$f"
  done
  for k in $SA_KINDS; do
    [[ -f "$dst/templates/make/kinds/$k.mk" ]] || printf '%s\ndefine kind_%s\nendef\n' "$SA_HEADER" "$k" >"$dst/templates/make/kinds/$k.mk"
  done
  echo "$dst"
}

sa_git() {
  git -C "$1" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "${@:2}"
}

sa_fresh() {
  # sa_fresh DIR: a scaffold with a firmware, a board and a Worker
  local skill
  skill=$(sa_skill_copy)
  "$skill/scripts/scaffold.sh" "$1" --project demo \
    --part firmware:zephyr --part hardware:hardware --part cloud-api:cloud-worker:cloud/api >/dev/null
}

# A small repo shaped like a real unstandard project: PascalCase folders, sub-Makefiles, legacy
# `only:` CI, a tracked signing key.
sa_legacy() {
  local d=$1
  mkdir -p "$d/Firmware/WidgetNode/key" "$d/Hardware/WidgetNode" "$d/Website/pocket" "$d/Application/upmuse.xcodeproj"
  cat >"$d/Firmware/WidgetNode/Makefile" <<'EOF'
BOARD := widget/nrf54l15/cpuapp
.PHONY: help build flash
help:
	@echo help
build: setup
	west build -b $(BOARD)
flash: build
	west flash
setup:
	west update
EOF
  printf 'dev build deploy:\n\tnpm run $@\n' >"$d/Website/Makefile"
  printf 'deploy-full: build\n\t@true\n' >"$d/Website/pocket/Makefile"
  echo "-----BEGIN PRIVATE KEY-----" >"$d/Firmware/WidgetNode/key/boot_signature_key_file_ed25519.pem"
  echo "(kicad_pcb)" >"$d/Hardware/WidgetNode/WidgetNode.kicad_pcb"
  echo "{}" >"$d/Application/upmuse.xcodeproj/project.pbxproj"
  cat >"$d/.gitlab-ci.yml" <<'EOF'
stages:
  - publish
publish_node:
  stage: publish
  script: echo publish
  only:
    refs:
      - main
EOF
  printf '*.step filter=lfs diff=lfs merge=lfs -text\n' >"$d/.gitattributes"
  sa_git "$d" init -q -b main
  sa_git "$d" add -A
  sa_git "$d" commit -q -m legacy
}

@test "audit is clean on a fresh scaffold (no git)" {
  d="$BATS_TEST_TMPDIR/fresh"
  sa_fresh "$d"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"standard v1.14"* ]]
  [[ $output == *clean* ]]
}

@test "audit is clean on a fresh scaffold committed to git, and --json says so" {
  d="$BATS_TEST_TMPDIR/fresh-git"
  sa_fresh "$d"
  sa_git "$d" init -q -b main
  sa_git "$d" add -A
  sa_git "$d" commit -q -m scaffold
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  run "$(sa_skill_copy)/scripts/audit.sh" "$d" --json
  [ "$status" -eq 0 ]
  [[ $output == *'"standard":true'* ]]
  [[ $output == *'"findings":[]'* ]]
  if command -v jq >/dev/null; then
    [ "$(printf '%s' "$output" | jq -r '.project')" = demo ]
  fi
}

@test "audit lists the deviations of an unstandard repo" {
  d="$BATS_TEST_TMPDIR/legacy"
  sa_legacy "$d"
  run "$SA_REAL_SKILL/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"not standard"* ]]
  [[ $output == *"not a project-standard project"* ]]
  [[ $output == *"Firmware: folder name is not lowercase"* ]] || false
  [[ $output == *"git mv 'firmware/WidgetNode' 'firmware/WidgetNode.tmp' && git mv 'firmware/WidgetNode.tmp' 'firmware/widgetnode'"* ]] || false
  [[ $output == *"Hardware/WidgetNode: folder name is not lowercase"* ]] || false
  [[ $output != *"upmuse.xcodeproj: folder"* ]]
  [[ $output == *"Firmware/WidgetNode/Makefile: sub-Makefile, adopt moves its targets"* ]]
  [[ $output == *"Website/Makefile: sub-Makefile"* ]]
  [[ $output == *"boot_signature_key_file_ed25519.pem: secret-like file is tracked in git"* ]]
  [[ $output == *".gitlab-ci.yml: left over from GitLab CI"* ]]
  [[ $output == *".github/workflows/checks.yml: missing"*"generate them: scaffold.sh <dir> --force"* ]]
  [[ $output == *".github/workflows/release.yml: missing"* ]]
  [[ $output == *"no LFS line for: *.stp"* ]]
  [[ $output == *"secrets.schema: missing"* ]]
  [[ $output == *"mise.toml: missing"* ]]
  [[ $output == *"PLAN.md: missing"* ]]
  [[ $output == *"targets today"* ]]
  [[ $output == *"Firmware/WidgetNode/Makefile: help build flash setup"* ]]
  [[ $output == *"Website/Makefile: dev build deploy"* ]]
  [[ $output != *"BOARD"* ]]
}

@test "audit --json of an unstandard repo is valid and carries the targets" {
  command -v jq >/dev/null || skip "jq not installed"
  d="$BATS_TEST_TMPDIR/legacy-json"
  sa_legacy "$d"
  run "$SA_REAL_SKILL/scripts/audit.sh" "$d" --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.standard')" = false ]
  [ "$(printf '%s' "$output" | jq '[.findings[] | select(.area == "secrets" and .severity == "error")] | length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.targets[] | select(.file == "Website/pocket/Makefile") | .targets | join(" ")')" = deploy-full ]
}

@test "audit changes nothing in the project" {
  d="$BATS_TEST_TMPDIR/legacy-ro"
  sa_legacy "$d"
  before=$(cd "$d" && find . -path ./.git/index -prune -o -type f -print0 | xargs -0 shasum | sort; sa_git "$d" status --porcelain)
  run "$SA_REAL_SKILL/scripts/audit.sh" "$d"
  run "$SA_REAL_SKILL/scripts/audit.sh" "$d" --json
  after=$(cd "$d" && find . -path ./.git/index -prune -o -type f -print0 | xargs -0 shasum | sort; sa_git "$d" status --porcelain)
  [ "$before" = "$after" ]
}

@test "audit reports an outdated managed file, a missing part dir and a tracked .env" {
  d="$BATS_TEST_TMPDIR/drift"
  sa_fresh "$d"
  echo "# hand edit" >>"$d/make/common.mk"
  rm -rf "$d/hardware"
  echo "TOKEN=x" >"$d/.env"
  sa_git "$d" init -q -b main
  sa_git "$d" add -A
  sa_git "$d" add -f .env
  sa_git "$d" commit -q -m drift
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"outdated"*"make/common.mk: differs from the skill's current template"* ]]
  [[ $output == *"hardware: folder of part 'hardware' does not exist"* ]]
  [[ $output == *".env: secret-like file is tracked in git"* ]]
}

@test "audit reports a managed file without its header and a broken PLAN.md" {
  d="$BATS_TEST_TMPDIR/broken"
  sa_fresh "$d"
  printf 'include make/project.mk\ninclude make/common.mk\n' >"$d/Makefile"
  printf '# plan\n\n## Firmware\n- [ ] something\n' >"$d/PLAN.md"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"Makefile: managed header is missing"* ]]
  [[ $output == *"PLAN.md: no components the project map can read"* ]]
}

@test "audit usage errors exit 2" {
  run "$SA_REAL_SKILL/scripts/audit.sh"
  [ "$status" -eq 2 ]
  run "$SA_REAL_SKILL/scripts/audit.sh" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  run "$SA_REAL_SKILL/scripts/audit.sh" "$BATS_TEST_TMPDIR" --bogus
  [ "$status" -eq 2 ]
}

@test "audit: more secret file kinds are errors when tracked, .envrc is a warning, untracked ones on disk are warnings" {
  d="$BATS_TEST_TMPDIR/secrets-on-disk"
  sa_fresh "$d"
  mkdir -p "$d/infra" "$d/.ssh"
  : >"$d/id_rsa"
  printf '//registry.npmjs.org/:_authToken=npm_SECRETVALUE123\n' >"$d/.npmrc"
  mkdir -p "$d/web"
  printf 'verify-deps-before-run=error\n' >"$d/web/.npmrc"
  : >"$d/infra/prod.tfvars"
  : >"$d/svc-service-account-prod.json"
  : >"$d/cert.pfx"
  : >"$d/.envrc"
  : >"$d/.env.example"
  sa_git "$d" init -q -b main
  sa_git "$d" add -A
  sa_git "$d" add -f id_rsa .npmrc web/.npmrc infra/prod.tfvars svc-service-account-prod.json cert.pfx .envrc
  sa_git "$d" commit -q -m files
  # untracked, and git-ignored: plain secrets sitting on disk
  printf '.env\nignored.p12\n' >"$d/.gitignore"
  : >"$d/.env"
  : >"$d/ignored.p12"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d" --json
  [ "$status" -eq 1 ]
  local errs warns
  errs=$(printf '%s' "$output" | jq -r '[.findings[] | select(.area == "secrets" and .severity == "error") | .path] | sort | join(" ")')
  warns=$(printf '%s' "$output" | jq -r '[.findings[] | select(.area == "secrets" and .severity == "warn") | .path] | sort | join(" ")')
  [[ "$errs" == *"id_rsa"* && "$errs" == *".npmrc"* && "$errs" == *"prod.tfvars"* && "$errs" == *"svc-service-account-prod.json"* && "$errs" == *"cert.pfx"* ]]
  [[ "$errs" != *".envrc"* && "$errs" != *".env.example"* ]]
  # an .npmrc with settings only is not a secret, and no file content reaches the report
  [[ "$errs" != *"web/.npmrc"* && "$warns" != *"web/.npmrc"* ]]
  [[ "$output" != *"SECRETVALUE"* ]]
  [[ "$warns" == *".envrc"* ]]
  [[ "$warns" == *".env"* && "$warns" == *"ignored.p12"* ]]
  [[ "$warns" != *".env.example"* ]]
}

@test "audit reads the same secret file list as secrets.sh" {
  grep -q 'secret-patterns.sh' "$SA_REAL_SKILL/scripts/audit.sh"
  [ -f "$SA_REAL_SKILL/templates/make/bin/secret-patterns.sh" ]
}

# git with the LFS filter wired up from the command line, whatever the user's git config says
sa_git_lfs() {
  sa_git "$1" -c filter.lfs.process='git-lfs filter-process' -c filter.lfs.clean='git-lfs clean -- %f' \
    -c filter.lfs.smudge='git-lfs smudge -- %f' -c filter.lfs.required=true "${@:2}"
}

@test "audit reports tracked files that .gitattributes sends to LFS but are plain blobs, without their content" {
  command -v git-lfs >/dev/null 2>&1 || skip "git-lfs is not installed"
  d="$BATS_TEST_TMPDIR/lfs"
  sa_fresh "$d"
  sa_git "$d" init -q -b main
  # binaries committed before the attributes existed, as adoption finds them
  mv "$d/.gitattributes" "$BATS_TEST_TMPDIR/gitattributes"
  printf 'PLAINPNGCONTENT' >"$d/hardware/render.wrl"
  mkdir -p "$d/docs/manuals"
  printf 'PLAINPDFCONTENT' >"$d/docs/manuals/manual v2.step"
  sa_git "$d" add -A
  sa_git "$d" commit -q -m plain
  mv "$BATS_TEST_TMPDIR/gitattributes" "$d/.gitattributes"
  sa_git "$d" add .gitattributes
  sa_git "$d" commit -q -m attributes
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"lfs"*"hardware/render.wrl: matches an LFS pattern"*"plain git blob"* ]]
  [[ $output == *"docs/manuals/manual v2.step: matches an LFS pattern"* ]]
  [[ $output == *"git add --renormalize ."* ]]
  [[ $output != *GitLab* && $output != *glab* ]]
  [[ $output != *PLAINPNGCONTENT* && $output != *PLAINPDFCONTENT* ]]
  # the same without git-lfs on PATH (the staged blob's first bytes)
  PATH="/usr/bin:/bin" run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  [[ $output == *"hardware/render.wrl: matches an LFS pattern"* ]]
  # after the renormalize commit adoption makes, the audit is clean again
  sa_git_lfs "$d" add --renormalize .
  sa_git_lfs "$d" commit -q -m "Move the binaries already tracked into Git LFS"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  PATH="/usr/bin:/bin" run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  [ "$status" -eq 0 ]
}

@test "audit caps the plain-blob LFS findings at ten and counts the rest" {
  command -v git-lfs >/dev/null 2>&1 || skip "git-lfs is not installed"
  d="$BATS_TEST_TMPDIR/many"
  sa_fresh "$d"
  sa_git "$d" init -q -b main
  mv "$d/.gitattributes" "$BATS_TEST_TMPDIR/gitattributes"
  for i in $(seq 1 13); do printf 'x%s' "$i" >"$d/hardware/icon$i.wrl"; done
  sa_git "$d" add -A
  sa_git "$d" commit -q -m plain
  mv "$BATS_TEST_TMPDIR/gitattributes" "$d/.gitattributes"
  sa_git "$d" add .gitattributes
  sa_git "$d" commit -q -m attributes
  run "$(sa_skill_copy)/scripts/audit.sh" "$d" --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq '[.findings[] | select(.area == "lfs" and (.message | startswith("matches an LFS pattern")))] | length')" -eq 10 ]
  printf '%s' "$output" | jq -e '[.findings[] | select(.area == "lfs" and (.message | startswith("3 more")))] | length == 1' >/dev/null
}

@test "audit warns about tracked files under a hardware part's outputs/ or production/" {
  d="$BATS_TEST_TMPDIR/hwout"
  sa_fresh "$d"
  sa_git "$d" init -q -b main
  mkdir -p "$d/hardware/outputs/gerbers" "$d/hardware/production" "$d/docs/production"
  printf 'g' >"$d/hardware/outputs/gerbers/Board-F_Cu.gtl"
  printf 'd' >"$d/hardware/outputs/gerbers/Board.drl"
  printf 'n' >"$d/docs/production/notes.md"
  printf 'z' >"$d/hardware/production/Board_v1.zip"
  sa_git "$d" add -A
  # committed before the scaffold's .gitignore lines existed, as adoption finds them
  sa_git "$d" add -f hardware/outputs hardware/production
  sa_git "$d" commit -q -m outputs
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"warn"*"hardware"*"hardware/outputs: 2 tracked file(s) in a build output folder"*"git rm -r --cached 'hardware/outputs'"* ]] || false
  [[ $output == *"hardware/production: 1 tracked file(s)"*"git rm -r --cached 'hardware/production'"* ]] || false
  [[ $output != *"docs/production"* ]] || false
  # a folder with a tracked .kicad_pro counts too when the project is not standard
  l="$BATS_TEST_TMPDIR/hwlegacy"
  mkdir -p "$l/Boards/Main/outputs"
  echo "{}" >"$l/Boards/Main/Main.kicad_pro"
  echo x >"$l/Boards/Main/outputs/Main.pdf"
  sa_git "$l" init -q -b main
  sa_git "$l" add -A
  sa_git "$l" commit -q -m legacy
  run "$(sa_skill_copy)/scripts/audit.sh" "$l"
  [[ $output == *"Boards/Main/outputs: 1 tracked file(s)"* ]] || false
  # untracked once removed from the index: clean again
  sa_git "$d" rm -r -q --cached hardware/outputs hardware/production
  sa_git "$d" commit -q -m untrack
  rm -rf "$d/hardware/outputs"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output != *"build output folder"* ]] || false
}

@test "audit warns about tracked release files of any part, and the scaffold ignores each part's release/" {
  d="$BATS_TEST_TMPDIR/relout"
  sa_fresh "$d"
  grep -qx 'hardware/release/' "$d/.gitignore"
  sa_git "$d" init -q -b main
  mkdir -p "$d/hardware/release/2"
  printf 'z' >"$d/hardware/release/2/SHA256SUMS"
  sa_git "$d" add -A
  sa_git "$d" add -f hardware/release
  sa_git "$d" commit -q -m release
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  [ "$status" -eq 1 ]
  [[ $output == *"hardware/release: 1 tracked file(s) in the release folder"*"git rm -r --cached 'hardware/release'"* ]] || false
}

# --- v7: documents ---------------------------------------------------------------------------

@test "audit warns about each missing doc of the set, by kind, and operations.md only with a deployable part" {
  d="$BATS_TEST_TMPDIR/docs-missing"
  sa_fresh "$d"
  rm "$d/docs/firmware/protocol.md" "$d/cloud/api/CHANGELOG.md" "$d/hardware/README.md" "$d/docs/operations.md" \
    "$d/docs/architecture.md"
  rm -r "$d/docs/cloud-api"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d" --json
  [ "$status" -eq 1 ]
  got=$(printf '%s' "$output" | jq -r '[.findings[] | select(.area == "docs") | .severity + " " + .path] | sort | join(",")')
  echo "$got"
  [ "$got" = "warn cloud/api/CHANGELOG.md,warn docs/architecture.md,warn docs/cloud-api/api.md,warn docs/cloud-api/data.md,warn docs/firmware/protocol.md,warn docs/operations.md,warn hardware/README.md" ]
  printf '%s' "$output" | jq -e '[.findings[] | select(.path == "docs/operations.md") | .message | test("cloud-api")] | all' >/dev/null
  printf '%s' "$output" | jq -e '[.findings[] | select(.area == "docs") | .fix | test("scaffold.sh --force")] | all' >/dev/null
  # the scaffold puts back exactly what is missing, and the audit is clean again
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d" --force --project demo \
    --part firmware:zephyr --part hardware:hardware --part cloud-api:cloud-worker:cloud/api >/dev/null
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  # no deployable part: no operations.md expected; web-pages has no docs/<part>/
  d="$BATS_TEST_TMPDIR/docs-nodeploy"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d" --project demo --part fw:pio --part desk:app-tauri >/dev/null
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  [ "$status" -eq 0 ]
  d="$BATS_TEST_TMPDIR/docs-web"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d" --project demo --part site:web-pages >/dev/null
  rm "$d/docs/operations.md"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"docs/operations.md: missing (deployable parts: site)"* ]]
  [[ $output != *"docs/site/"* ]]
}

@test "audit: docs/decisions/ is not part of the standard, so a fresh project is clean with and without its own" {
  d="$BATS_TEST_TMPDIR/decisions"
  sa_fresh "$d"
  [ ! -e "$d/docs/decisions" ]
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output != *"decision"* ]] || false
  # a project's own decision records, with or without a README, change nothing
  mkdir -p "$d/docs/decisions"
  echo "# 0001. Use Zephyr" >"$d/docs/decisions/0001-use-zephyr.md"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output != *"decision"* ]] || false
  echo "# Decisions" >"$d/docs/decisions/README.md"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '[.findings[] | select(.area == "docs")] | length')" -eq 0 ]
}

@test "audit warns about committed binary documents without printing them, and about .gitignore and LFS lines for them" {
  d="$BATS_TEST_TMPDIR/bindocs"
  sa_fresh "$d"
  sa_git "$d" init -q -b main
  mkdir -p "$d/docs/manuals"
  printf 'SECRETPDFBODY' >"$d/docs/manuals/HID Protocol.pdf"
  printf 'x' >"$d/hardware/bom.XLSX"
  printf 'x' >"$d/docs/spec.docx"
  printf 'x' >"$d/docs/notes.odt"
  sa_git "$d" add -A
  # ignored by the scaffold's .gitignore: only a forced add commits them
  [ -z "$(sa_git "$d" diff --cached --name-only | grep -Ei '\.(pdf|xlsx|docx|odt)$')" ]
  sa_git "$d" add -f "docs/manuals/HID Protocol.pdf" hardware/bom.XLSX docs/spec.docx docs/notes.odt
  sa_git "$d" commit -q -m docs
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"docs/manuals/HID Protocol.pdf: binary document is committed"*"git rm --cached 'docs/manuals/HID Protocol.pdf'"*"release as an asset"* ]] || false
  [[ $output == *"hardware/bom.XLSX: binary document is committed"* ]] || false
  [[ $output == *"docs/spec.docx: binary document is committed"* ]] || false
  [[ $output == *"docs/notes.odt: binary document is committed"* ]] || false
  [[ $output != *SECRETPDFBODY* ]] || false
  [[ $output != *"does not ignore binary documents"* ]] || false
  # an old .gitignore and .gitattributes (v6: PDFs in LFS)
  grep -vFx '*.pdf' "$d/.gitignore" | grep -vFx '*.pptx' >"$d/gi" && mv "$d/gi" "$d/.gitignore"
  printf '*.pdf filter=lfs diff=lfs merge=lfs -text\n*.xlsx filter=lfs diff=lfs merge=lfs -text\n' >>"$d/.gitattributes"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *".gitignore: does not ignore binary documents: *.pdf *.pptx"* ]] || false
  [[ $output == *".gitattributes: routes binary documents to LFS: *.pdf *.xlsx"* ]] || false
  # removed from the index (they stay in history): clean of binary-document findings
  sa_git "$d" checkout -q -- .gitignore .gitattributes
  sa_git "$d" rm -q --cached "docs/manuals/HID Protocol.pdf" hardware/bom.XLSX docs/spec.docx docs/notes.odt
  sa_git "$d" commit -q -m untrack
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "audit caps the committed binary documents at ten and counts the rest" {
  d="$BATS_TEST_TMPDIR/manydocs"
  sa_fresh "$d"
  sa_git "$d" init -q -b main
  for i in $(seq 1 12); do printf 'x' >"$d/docs/d$i.pdf"; done
  sa_git "$d" add -A
  sa_git "$d" add -f docs/*.pdf
  sa_git "$d" commit -q -m pdfs
  run "$(sa_skill_copy)/scripts/audit.sh" "$d" --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq '[.findings[] | select(.area == "docs" and (.message | startswith("binary document")))] | length')" -eq 10 ]
  printf '%s' "$output" | jq -e '[.findings[] | select(.message == "2 more binary document(s) are committed")] | length == 1' >/dev/null
}

@test "audit: a third-party action is an error, an unpinned actions/* and an older CI templates version are warnings" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/uses"
  sa_fresh "$d"
  ci="$d/.github/workflows/checks.yml"
  sed -i.bak -e 's|actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1|actions/checkout@v7|' "$ci"
  sed -i.bak -e 's|zephyr.yml@v1.14|zephyr.yml@v8|' "$ci"
  printf '      - uses: some-org/deploy-tool@v1\n' >>"$ci"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"error    ci        .github/workflows/checks.yml: uses some-org/deploy-tool@v1: a third-party action"* ]]
  [[ $output == *"uses actions/checkout@v7: not pinned by a full commit SHA"* ]]
  [[ $output == *"uses mayankgautam-me/ci-templates/.github/workflows/zephyr.yml@v8: the skill is at v1.14"* ]]
}

@test "audit: a reusable workflow with no @version is an error, and one from another owner is a warning" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/nover"
  sa_fresh "$d"
  ci="$d/.github/workflows/checks.yml"
  sed -i.bak -e 's|zephyr.yml@v1.14|zephyr.yml|' -e 's|mayankgautam-me/ci-templates/.github/workflows/go|other-owner/ci-templates/.github/workflows/go|' "$ci"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"uses mayankgautam-me/ci-templates/.github/workflows/zephyr.yml has no @version"* ]]
}

@test "audit: a uses line on the pre-1.7 <owner>/ci-templates is outdated, with the fix; CI_TEMPLATES_REPO decides (1.7)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/oldrepo"
  sa_fresh "$d"
  ci="$d/.github/workflows/checks.yml"
  # a fresh scaffold names the default repo, whatever GITHUB_OWNER is, and the audit is quiet about it
  run "$skill/scripts/audit.sh" "$d"
  [[ $output != *"outdated, the CI templates are"* ]]
  sed -i.bak -e 's|mayankgautam-me/ci-templates/|fabrolabs-innovations/ci-templates/|' "$ci"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"warn     ci        .github/workflows/checks.yml: uses fabrolabs-innovations/ci-templates/.github/workflows/zephyr.yml@v1.14: outdated, the CI templates are mayankgautam-me/ci-templates (CI_TEMPLATES_REPO), not fabrolabs-innovations/ci-templates"* ]]
  [[ $output == *"change the uses lines to mayankgautam-me/ci-templates"* ]]
  [[ $output != *"release.yml: uses fabrolabs-innovations"* ]]
  # the project's CI_TEMPLATES_REPO makes that repo the right one, and the other file's lines outdated
  printf 'CI_TEMPLATES_REPO := fabrolabs-innovations/ci-templates\n' >>"$d/make/project.mk"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output != *"checks.yml: uses fabrolabs-innovations"*"outdated"* ]]
  [[ $output == *"release.yml: uses mayankgautam-me/ci-templates/"*"outdated, the CI templates are fabrolabs-innovations/ci-templates"* ]]
  # from the user config, and the pre-1.7 CI_TEMPLATES_PROJECT is reported as ignored
  sed -i.bak -e '/^CI_TEMPLATES_REPO/d' "$d/make/project.mk"
  printf 'GITHUB_OWNER := example-owner\nCI_TEMPLATES_REPO := fabrolabs-innovations/ci-templates\nCI_TEMPLATES_PROJECT := x/ci-templates\n' >"$STD_CONFIG/config.mk"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output != *"checks.yml: uses fabrolabs-innovations"*"outdated"* ]]
  [[ $output == *"CI_TEMPLATES_PROJECT is ignored since 1.7"* ]]
}

@test "audit: the workflows are needed, each part has its job in both, and a missing GITHUB_OWNER is a warning" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/nojob"
  sa_fresh "$d"
  # a part with no job in release.yml
  sed -i.bak -e '/^  hardware-release:/,/^$/d' "$d/.github/workflows/release.yml"
  sed -i.bak -e '/^      part: hardware$/d' "$d/.github/workflows/checks.yml"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"no checks job for part hardware (hardware)"* ]]
  [[ $output == *"no release job for part hardware (hardware)"* ]]
  # no workflows at all: an error that says how to generate them
  rm -rf "$d/.github"
  run "$skill/scripts/audit.sh" "$d"
  [ "$status" -eq 1 ]
  [[ $output == *"generate them: scaffold.sh <dir> --force"* ]]
  # no owner configured: the placeholder is what the workflows would carry
  : >"$STD_CONFIG/config.mk"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output == *"GITHUB_OWNER is not set"* ]]
}

@test "audit: a project with workflows warns when .gitignore does not ignore .ci/" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/noci"
  sa_fresh "$d"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output != *"does not ignore .ci/"* ]]
  sed -i.bak -e '/^\.ci\/$/d' "$d/.gitignore"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output == *".gitignore: does not ignore .ci/"* ]]
}

@test "audit: a v15 project's ci.yml is reported as the old name of checks.yml" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/oldname"
  sa_fresh "$d"
  git -C "$d" init -q 2>/dev/null || true
  mv "$d/.github/workflows/checks.yml" "$d/.github/workflows/ci.yml"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output == *".github/workflows/ci.yml: the v15 name of checks.yml"* ]]
  [[ $output == *".github/workflows/checks.yml: missing"* ]]
  # scaffold --force keeps it and does not write a second checks workflow next to it
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part firmware:zephyr --part hardware:hardware --part cloud-api:cloud-worker:cloud/api --force
  [[ $output == *"rename it with git mv .github/workflows/ci.yml .github/workflows/checks.yml"* ]] || false
  [ ! -e "$d/.github/workflows/checks.yml" ]
}

@test "audit: a release.yml without the latest job (before v20) is a warning, and one with it is not" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/nolatest"
  sa_fresh "$d"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output != *"no latest job"* ]]
  # take the latest job out
  sed -i.bak -e '/^  latest:/,/^$/d' "$d/.github/workflows/release.yml"
  rm -f "$d/.github/workflows/release.yml.bak"
  ! grep -q -- '-release-latest' "$d/.github/workflows/release.yml"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"warn"*".github/workflows/release.yml: no latest job"* ]]
  [[ $output == *"make <part>-release-latest once per part"* ]]
}

@test "audit: a Cloudflare part whose tag job does not deploy production (no confirm: production) is a warning (v26)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/tagdeploy"
  sa_scaf "$d" api:cloud-worker:cloud/api site:web-pages:web fw:zephyr
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output != *"does not deploy production"* ]]
  # a release.yml from before: the tag job of api releases without deploying
  sed -i.bak -e '/^  api-release:/,/^  [a-z]/{/^      confirm: production$/d;}' "$d/.github/workflows/release.yml"
  rm -f "$d/.github/workflows/release.yml.bak"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"warn"*"release.yml: the tag job of part api (cloud-worker) does not deploy production"* ]]
  [[ $output == *"add 'confirm: production' under with: of job api-release"* ]]
  [[ $output != *"part site (web-pages) does not deploy"* ]]
  [[ $output != *"part fw"*"does not deploy"* ]]
}

@test "audit 1.9: a Flutter part's <part>_FLUTTER_VERSION that its CI jobs do not pass warns; passed, or not set, is clean" {
  d="$BATS_TEST_TMPDIR/flver"
  sa_scaf "$d" app:app-flutter
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output != *"FLUTTER_VERSION"* ]]
  printf 'app_FLUTTER_VERSION := 3.50.0\n' >>"$d/make/project.mk"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"checks.yml: job app does not pass app_FLUTTER_VERSION (3.50.0)"* ]]
  [[ $output == *"release.yml: job app-release does not pass app_FLUTTER_VERSION (3.50.0)"* ]]
  [[ $output == *"add flutter_version: '3.50.0' under with: of job app-release"* ]]
  # the scaffold writes the input into new workflow files
  rm "$d/.github/workflows/checks.yml" "$d/.github/workflows/release.yml"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d" --project demo --part app:app-flutter --force >/dev/null
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output != *"FLUTTER_VERSION"* ]]
}

@test "audit 1.10: a Flutter part's <part>_STORE that its tag job does not pass warns; the scaffold's job is clean" {
  d="$BATS_TEST_TMPDIR/flstore"
  sa_scaf "$d" app:app-flutter
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  [[ $output != *"_STORE"* ]]
  printf 'app_STORE := android ios\n' >>"$d/make/project.mk"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"release.yml: job app-release does not pass app_STORE (android ios) with confirm: production"* ]]
  [[ $output == *"add store: 'android ios' and confirm: production under with: of job app-release"* ]]
  rm "$d/.github/workflows/checks.yml" "$d/.github/workflows/release.yml"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d" --project demo --part app:app-flutter --force >/dev/null
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output != *"_STORE"* ]]
}

# sa_scaf DIR PART...: scaffold DIR with the given --part specs
sa_scaf() {
  local d=$1
  shift
  local args=() p
  for p in "$@"; do
    args+=(--part "$p")
    # a web site has its custom domain (v34: without one the audit reports the CHANGE-ME route)
    [[ $p != *:web-pages* ]] || args+=(--domain "${p%%:*}=${p%%:*}.example.com")
  done
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d" --project demo "${args[@]}" >/dev/null
}

# sa_layout DIR: run the audit on DIR and show its output
sa_layout() {
  run "$(sa_skill_copy)/scripts/audit.sh" "$1"
  echo "$output"
}

@test "audit 2c: a scaffold that follows the group-folder rule has no layout finding" {
  d="$BATS_TEST_TMPDIR/rule-one"
  sa_scaf "$d" fw:zephyr board:hardware api:cloud-worker site:web-pages app:app-flutter
  sa_layout "$d"
  [ "$status" -eq 0 ]
  [[ $output != *"outside"* ]]
  [[ $output != *"own subfolder"* ]]
  [[ $output != *"name firmware parts"* ]]
  d="$BATS_TEST_TMPDIR/rule-many"
  sa_scaf "$d" nrf9151:zephyr stm32f042:pio api:cloud-worker tools:python
  sa_layout "$d"
  [ "$status" -eq 0 ]
  [[ $output != *"outside"* ]]
  [[ $output != *"own subfolder"* ]]
  [[ $output != *"name firmware parts"* ]]
}

@test "audit 2c: a part outside its group folder warns, with the git mv that fixes it" {
  d="$BATS_TEST_TMPDIR/outside"
  sa_scaf "$d" api:cloud-worker:api fw:zephyr:src/fw
  sa_layout "$d"
  [[ $output == *"part api (cloud-worker) is outside cloud/"* ]]
  [[ $output == *"git mv 'api' 'cloud'"* ]] || false
  [[ $output == *"part fw (zephyr) is outside firmware/"* ]]
  [[ $output == *"git mv 'src/fw' 'firmware'"* ]] || false
  # with several parts of the group the fix names <group>/<name>
  d="$BATS_TEST_TMPDIR/outside-many"
  sa_scaf "$d" api:cloud-worker:api tools:python
  sa_layout "$d"
  [[ $output == *"part api (cloud-worker) is outside cloud/"* ]]
  [[ $output == *"git mv 'api' 'cloud/api'"* ]] || false
  [[ $output != *"part tools"* ]]
}

@test "audit 2c: a go part under firmware/ runs on a device and is accepted; elsewhere it belongs in cloud/" {
  d="$BATS_TEST_TMPDIR/device-go"
  sa_scaf "$d" lattepanda:go:firmware/lattepanda atmega328p:pio:firmware/atmega328p api:cloud-worker:cloud/backend
  sa_layout "$d"
  [[ $output != *"outside"* ]]
  [[ $output != *"own subfolder"* ]]
  d="$BATS_TEST_TMPDIR/stray-go"
  sa_scaf "$d" agent:go:src/agent
  sa_layout "$d"
  [[ $output == *"part agent (go) is outside cloud/"* ]]
}

@test "audit: CubeMX folders next to a .ioc keep their names; the same names elsewhere warn" {
  d="$BATS_TEST_TMPDIR/cubemx"
  sa_scaf "$d" firmware:arm-gcc hw:hardware:hardware
  mkdir -p "$d/firmware/Src" "$d/firmware/Drivers/CMSIS" "$d/hardware/Src"
  : >"$d/firmware/board.ioc"
  : >"$d/firmware/Src/main.c"
  : >"$d/firmware/Drivers/CMSIS/a.h"
  : >"$d/hardware/Src/x.txt"
  sa_layout "$d"
  [[ $output != *"firmware/Src: folder name is not lowercase"* ]] || false
  [[ $output != *"firmware/Drivers: folder name is not lowercase"* ]] || false
  [[ $output == *"hardware/Src: folder name is not lowercase"* ]] || false
}

@test "audit 2c: several firmware parts with one directly in firmware/ warns about the subfolder" {
  d="$BATS_TEST_TMPDIR/shared"
  sa_scaf "$d" nrf9151:zephyr:firmware stm32f042:pio
  sa_layout "$d"
  [[ $output == *"part nrf9151 (zephyr) shares firmware/ with other parts and needs its own subfolder firmware/nrf9151"* ]]
  [[ $output == *"git mv 'firmware' 'firmware/nrf9151'"* ]] || false
  [[ $output != *"part stm32f042"* ]]
  [[ $output != *"name firmware parts"* ]]
}

@test "audit 2c: several firmware parts, one named firmware, warns to name them for their chip" {
  d="$BATS_TEST_TMPDIR/chipname"
  sa_scaf "$d" firmware:zephyr stm32f042:pio
  sa_layout "$d"
  [[ $output == *"firmware part firmware: name firmware parts for their chip when there are several"* ]]
  [[ $output != *"outside"* ]]
  d="$BATS_TEST_TMPDIR/chipname2"
  sa_scaf "$d" firmware-main:zephyr stm32f042:pio
  sa_layout "$d"
  [[ $output == *"firmware part firmware-main: name firmware parts for their chip"* ]]
}

@test "audit 2c: a single firmware part named firmware does not warn" {
  d="$BATS_TEST_TMPDIR/singlefw"
  sa_scaf "$d" firmware:zephyr board:hardware
  sa_layout "$d"
  [ "$status" -eq 0 ]
  [[ $output != *"name firmware parts"* ]]
  [[ $output != *"outside"* ]]
}

@test "audit 2c: a cloud part inside cloud/ (cloud/backend) does not warn" {
  d="$BATS_TEST_TMPDIR/cloudsub"
  sa_scaf "$d" backend:cloud-worker:cloud/backend
  sa_layout "$d"
  [ "$status" -eq 0 ]
  [[ $output != *"outside"* ]]
  [[ $output != *"own subfolder"* ]]
}

# a gh that answers repo view with the description in $GH_DESC (an empty one when unset), or fails with GH_FAIL=1
sa_fake_gh() {
  mkdir -p "$BATS_TEST_TMPDIR/ghbin"
  cat >"$BATS_TEST_TMPDIR/ghbin/gh" <<'GH'
#!/bin/sh
echo "$*" >>"$BATS_TEST_TMPDIR/gh.calls"
[ -n "${GH_FAIL:-}" ] && exit 1
[ "$1 $2" = "repo view" ] && { printf '%s\n' "${GH_DESC:-}"; exit 0; }
exit 0
GH
  chmod +x "$BATS_TEST_TMPDIR/ghbin/gh"
}

@test "audit: a GitHub repository without a description is a warning; with one, offline or gh failing it is not (v24)" {
  d="$BATS_TEST_TMPDIR/desc"
  sa_scaf "$d" fw:pio
  git -C "$d" init -q && git -C "$d" remote add origin git@github.com:example-owner/demo.git
  sa_fake_gh
  unset STD_AUDIT_OFFLINE
  PATH="$BATS_TEST_TMPDIR/ghbin:$PATH" GH_DESC='' sa_layout "$d"
  [[ $output == *"example-owner/demo: the GitHub repository has no description"* ]]
  [[ $output == *'gh repo edit example-owner/demo --description'* ]]
  grep -q 'repo view example-owner/demo' "$BATS_TEST_TMPDIR/gh.calls"
  PATH="$BATS_TEST_TMPDIR/ghbin:$PATH" GH_DESC='Demo: a test project' sa_layout "$d"
  [[ $output != *"has no description"* ]]
  PATH="$BATS_TEST_TMPDIR/ghbin:$PATH" GH_FAIL=1 sa_layout "$d"
  [[ $output != *"has no description"* ]]
  PATH="$BATS_TEST_TMPDIR/ghbin:$PATH" STD_AUDIT_OFFLINE=1 GH_DESC='' sa_layout "$d"
  [[ $output != *"has no description"* ]]
  git -C "$d" remote set-url origin git@gitlab.com:example-owner/demo.git
  PATH="$BATS_TEST_TMPDIR/ghbin:$PATH" GH_DESC='' sa_layout "$d"
  [[ $output != *"has no description"* ]]
}

@test "audit does not count an arm-gcc part's own Makefile as a sub-Makefile, but still a deeper one" {
  d="$BATS_TEST_TMPDIR/armgcc"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d" --project demo --part blinky:arm-gcc --part fw:zephyr >/dev/null
  printf 'all:\n\t@true\nflash:\n\t@true\n' >"$d/firmware/blinky/Makefile"
  mkdir -p "$d/firmware/blinky/tools"
  printf 'gen:\n\t@true\n' >"$d/firmware/blinky/tools/Makefile"
  printf 'build:\n\t@true\n' >"$d/firmware/fw/Makefile"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output != *"firmware/blinky/Makefile:"* ]] || false
  [[ $output == *"firmware/blinky/tools/Makefile: sub-Makefile, adopt moves its targets"* ]] || false
  [[ $output == *"firmware/fw/Makefile: sub-Makefile, adopt moves its targets"* ]] || false
}

@test "audit 1.3: a silabs part's test/Makefile and tests/Makefile are its make <part>-test, not sub-Makefiles" {
  d="$BATS_TEST_TMPDIR/silabs"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d" --project demo --part firmware:silabs:firmware --part fw2:zephyr >/dev/null
  mkdir -p "$d/firmware/tests" "$d/firmware/test" "$d/firmware/tools" "$d/firmware/tests/unit"
  printf 'all:\n\t@true\nclean:\n\t@true\n' >"$d/firmware/tests/Makefile"
  printf 'all:\n\t@true\n' >"$d/firmware/test/Makefile"
  # anything else under the part, and a tests/Makefile of another kind, is still a sub-Makefile
  printf 'gen:\n\t@true\n' >"$d/firmware/tools/Makefile"
  printf 'unit:\n\t@true\n' >"$d/firmware/tests/unit/Makefile"
  printf 'all:\n\t@true\n' >"$d/firmware/Makefile"
  mkdir -p "$d/firmware/fw2/tests"
  printf 'all:\n\t@true\n' >"$d/firmware/fw2/tests/Makefile"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output != *"firmware/tests/Makefile:"* ]] || false
  [[ $output != *"firmware/test/Makefile:"* ]] || false
  [[ $output == *"firmware/tools/Makefile: sub-Makefile, adopt moves its targets"* ]] || false
  [[ $output == *"firmware/tests/unit/Makefile: sub-Makefile, adopt moves its targets"* ]] || false
  [[ $output == *"firmware/Makefile: sub-Makefile, adopt moves its targets"* ]] || false
  [[ $output == *"firmware/fw2/tests/Makefile: sub-Makefile, adopt moves its targets"* ]] || false
}

@test "audit 1.3: a make/project.mk or make/local.mk assignment with a trailing comment, commented out or not, is a warning" {
  d="$BATS_TEST_TMPDIR/trailing"
  sa_fresh "$d"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output != *"comment after its value"* ]] || false
  printf '%s\n' 'firmware_BOARD := nrf9151dk   # the dev kit' '# firmware_NCS := v3.2.1 # the pinned NCS' \
    '# a note # with a hash' 'X ?= $(HOME) # home' '# OK := fine' 'Y = 1' >>"$d/make/project.mk"
  printf '%s\n' 'LOCAL_FLAG := 1 # why' >>"$d/make/local.mk"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"warn     make      make/project.mk: line "*" has a comment after its value: firmware_BOARD := nrf9151dk   # the dev kit (make keeps the spaces before the # in the value)  fix: put the comment on its own line above"* ]] || false
  [[ $output == *"make/project.mk: line "*": # firmware_NCS := v3.2.1 # the pinned NCS"* ]] || false
  [[ $output == *"make/project.mk: line "*": X ?= \$(HOME) # home"* ]] || false
  [[ $output == *"make/local.mk: line "*": LOCAL_FLAG := 1 # why"* ]] || false
  [ "$(printf '%s\n' "$output" | grep -c 'comment after its value')" -eq 4 ]
  # the line number is the file's
  n=$(grep -n 'nrf9151dk   # the dev kit' "$d/make/project.mk" | cut -d: -f1)
  [[ $output == *"make/project.mk: line $n has a comment after its value: firmware_BOARD"* ]] || false
  # --json carries the same finding in area make
  run "$(sa_skill_copy)/scripts/audit.sh" --json "$d"
  [[ $output == *'"severity":"warn","area":"make","path":"make/project.mk"'* ]] || false
}

@test "audit v34: a web-pages part without a wrangler file or with a CHANGE-ME route warns; with its domain it does not" {
  d="$BATS_TEST_TMPDIR/webdom"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d" --project demo --part web:web-pages --part docs:web-pages >/dev/null
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"web/web/wrangler.jsonc: part web has no custom domain yet (CHANGE-ME)"* ]] || false
  d2="$BATS_TEST_TMPDIR/webdom2"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d2" --project demo --part web:web-pages --domain web=demo.example.com >/dev/null
  mv "$d2/web/wrangler.jsonc" "$BATS_TEST_TMPDIR/kept.jsonc"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d2"
  echo "$output"
  [[ $output == *"web: part web (web-pages) has no wrangler.jsonc"* ]] || false
  mv "$BATS_TEST_TMPDIR/kept.jsonc" "$d2/web/wrangler.jsonc"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d2"
  echo "$output"
  [[ $output != *"wrangler"* ]] || false
}

@test "audit 1.1: .gitattributes that still routes png, mp4, zip or hex to LFS is a warning with the renormalize fix" {
  d="$BATS_TEST_TMPDIR/oldlfs"
  sa_fresh "$d"
  printf '*.png   filter=lfs diff=lfs merge=lfs -text\n*.zip   filter=lfs diff=lfs merge=lfs -text\n' >>"$d/.gitattributes"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"routes small files to LFS: *.png *.zip"* ]]
  [[ $output == *"git add --renormalize ."* ]]
  # step stp, and FreeCAD's fcstd in both cases (1.1: git matches with case on Linux); *.wrl comes with a KiCad
  # board's kind lines (1.2)
  run grep -c 'filter=lfs' "$(sa_skill_copy)/templates/project/.gitattributes"
  [ "$output" = 4 ]
}

# sa_refs DIR: an unstandard repo with reference folders named the way vendors name them, a project-local KiCad
# library, and code whose naming is its language's
sa_refs() {
  local d=$1
  mkdir -p "$d/References/Cavli CQM220" "$d/References/SiLabs SiWG917" \
    "$d/References/SimCOM M.2/simcom_sim82xx__sim83xx_application_note_archive" \
    "$d/Hardware/Library/Footprints/Capacitor.pretty" "$d/Hardware/Library/Symbols" "$d/Hardware/Library/Models/Capacitor" \
    "$d/cloud/agent/my_pkg/sub_mod" "$d/app/Assets.xcassets/Icon_1" "$d/.github/Odd_Name"
  : >"$d/References/Cavli CQM220/a.md"
  : >"$d/References/SiLabs SiWG917/a.md"
  : >"$d/References/SimCOM M.2/simcom_sim82xx__sim83xx_application_note_archive/a.md"
  : >"$d/Hardware/Library/Footprints/Capacitor.pretty/C_0402.kicad_mod"
  : >"$d/Hardware/Library/Symbols/Capacitor.kicad_sym"
  : >"$d/Hardware/Library/Models/Capacitor/C.wrl"
  : >"$d/Hardware/Board.kicad_pro"
  : >"$d/cloud/agent/pyproject.toml"
  : >"$d/cloud/agent/my_pkg/sub_mod/__init__.py"
  : >"$d/app/Assets.xcassets/Icon_1/x.json"
  : >"$d/.github/Odd_Name/x"
  sa_git "$d" init -q -b main
  sa_git "$d" add -A
  sa_git "$d" commit -q -m refs
}

@test "audit: folder slugs keep words whole, drop dots, turn runs of spaces and underscores into one -, and the git mv quotes paths" {
  d="$BATS_TEST_TMPDIR/refs"
  sa_refs "$d"
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"References/Cavli CQM220: folder name is not lowercase kebab"*"git mv 'references/Cavli CQM220' 'references/Cavli CQM220.tmp' && git mv 'references/Cavli CQM220.tmp' 'references/cavli-cqm220'"* ]] || false
  [[ $output == *"rename to references/silabs-siwg917 "* ]] || false
  [[ $output == *"rename to references/simcom-m2 "* ]] || false
  [[ $output == *"References/SimCOM M.2/simcom_sim82xx__sim83xx_application_note_archive: folder name is not lowercase kebab"* ]] || false
  [[ $output == *"git mv 'references/simcom-m2/simcom_sim82xx__sim83xx_application_note_archive' 'references/simcom-m2/simcom_sim82xx__sim83xx_application_note_archive.tmp' && git mv 'references/simcom-m2/simcom_sim82xx__sim83xx_application_note_archive.tmp' 'references/simcom-m2/simcom-sim82xx-sim83xx-application-note-archive'"* ]] || false
  [[ $output == *"Hardware/Library: folder name is not lowercase"* ]] || false
  [[ $output != *"si-labs"* ]] || false
  # not reported: KiCad library folders, a bundle, hidden folders, and a Python package inside code
  [[ $output != *"Capacitor.pretty: folder"* ]] || false
  [[ $output != *"Hardware/Library/Symbols: folder"* ]] || false
  [[ $output != *"Hardware/Library/Footprints: folder"* ]] || false
  [[ $output != *"Hardware/Library/Models"* ]] || false
  [[ $output != *"my_pkg"* ]] || false
  [[ $output != *"xcassets"* ]] || false
  [[ $output != *"Odd_Name"* ]] || false
}

@test "audit: an origin that is not on GitHub is an error with the move to GitHub as its fix; a GitHub origin is not" {
  d="$BATS_TEST_TMPDIR/gitlab"
  sa_refs "$d"
  sa_git "$d" remote add origin git@gitlab.com:acme-labs/corelink.git
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"error    repo      origin: origin is not on GitHub (git@gitlab.com:acme-labs/corelink.git)"* ]] || false
  [[ $output == *"gh repo create acme-labs/corelink --private && git lfs fetch --all origin && git remote rename origin gitlab && git remote add origin git@github.com:acme-labs/corelink.git && git push origin --all && git push origin --tags && git lfs push --all origin"* ]] || false
  sa_git "$d" remote set-url origin https://github.com/acme-labs/corelink.git
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  [[ $output != *"not on GitHub"* ]] || false
}

@test "audit: KiCad, Altium and FreeCAD folders with no part get the PARTS entry to add" {
  d="$BATS_TEST_TMPDIR/cad"
  mkdir -p "$d/Hardware" "$d/Altium Board" "$d/Mechanical"
  : >"$d/Hardware/Board.kicad_pro"
  printf '(sym_lib_table (lib (name "X") (uri "${KIPRJMOD}/Library/X.kicad_sym")))\n' >"$d/Hardware/sym-lib-table"
  printf '[Design]\n' >"$d/Altium Board/Main.PrjPcb"
  printf 'x' >"$d/Mechanical/Case.FCStd"
  sa_git "$d" init -q -b main
  sa_git "$d" add -A
  sa_git "$d" commit -q -m cad
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"parts     Hardware: a KiCad project with no part (kind hardware)"*"add hardware:hardware:hardware to PARTS in make/project.mk and hardware_LIBRARY := local"* ]] || false
  [[ $output == *"parts     Altium Board: an Altium project (*.PrjPcb) with no part (kind altium)"*"add altium-board:altium:altium-board to PARTS"* ]] || false
  [[ $output == *"parts     Mechanical: a FreeCAD model (*.FCStd) with no part (kind mechanical)"*"add mechanical:mechanical:mechanical to PARTS"* ]] || false
}

@test "audit: a binary Altium document as a plain blob is an error; an ASCII one is not; LFS patterns must match the case" {
  d="$BATS_TEST_TMPDIR/altium"
  mkdir -p "$d/hardware" "$d/mechanical"
  printf '[Design]\n' >"$d/hardware/Main.PrjPcb"
  printf 'bin\000ary' >"$d/hardware/Main.PcbDoc"
  printf '|RECORD=1|\n' >"$d/hardware/Text.SchDoc"
  # an LFS pointer committed while *.fcstd (lowercase) routed it: on Linux the pattern does not match Case.FCStd
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%064d\nsize 1\n' 0 >"$d/mechanical/Case.FCStd"
  printf '*.fcstd filter=lfs diff=lfs merge=lfs -text\n' >"$d/.gitattributes"
  sa_git "$d" init -q -b main
  sa_git "$d" -c core.ignorecase=false -c filter.lfs.clean=cat -c filter.lfs.smudge=cat -c filter.lfs.process= add -A
  sa_git "$d" commit -q -m altium
  run "$(sa_skill_copy)/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"error    lfs       hardware/Main.PcbDoc: Altium binary document committed as a plain git blob"*"*.PcbDoc filter=lfs diff=lfs merge=lfs -text"*"git add --renormalize 'hardware/Main.PcbDoc'"* ]] || false
  [[ $output != *"Text.SchDoc"* ]] || false
  [[ $output != *"Main.PrjPcb: "* ]] || false
  [[ $output == *"mechanical/Case.FCStd: in Git LFS, but no .gitattributes line routes *.FCStd there with this case"* ]] || false
}

@test "audit 1.1: a fresh hardware + silabs + mechanical scaffold and a fresh altium one are clean (altium: no release job)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/trio"
  "$skill/scripts/scaffold.sh" "$d" --project trio --part hardware:hardware --part firmware:silabs --part mechanical:mechanical >/dev/null
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  d="$BATS_TEST_TMPDIR/alt"
  "$skill/scripts/scaffold.sh" "$d" --project alt --part hardware:altium >/dev/null
  # the scaffold adds no submodule (no network): until make setup adds the Altium library, the audit warns (1.4)
  run "$skill/scripts/audit.sh" "$d"
  [[ $output == *"warn     project   hardware/altium-library: part hardware (altium) has no Altium library submodule"*"make hardware-setup adds it"* ]] || false
  sa_submodule "$d"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output != *"no release job"* ]]
  [[ $output != *"no latest job"* ]]
  # a missing kind doc is still reported, with the lists the scaffold writes
  rm "$d/docs/hardware/manufacturing.md" "$BATS_TEST_TMPDIR/trio/docs/firmware/power.md" "$BATS_TEST_TMPDIR/trio/docs/mechanical/assembly.md"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output == *"docs/hardware/manufacturing.md: missing (part hardware, altium)"* ]]
  run "$skill/scripts/audit.sh" "$BATS_TEST_TMPDIR/trio"
  [[ $output == *"docs/firmware/power.md: missing (part firmware, silabs)"* ]]
  [[ $output == *"docs/mechanical/assembly.md: missing (part mechanical, mechanical)"* ]]
}

@test "audit 1.1: a project still on 1.0 is outdated: make/VERSION, the managed headers and the @v1.0 uses lines" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/old"
  sa_fresh "$d"
  printf '1.0\n' >"$d/make/VERSION"
  sed -i.bak '1s/v1\.14/v1.0/' "$d/make/common.mk"
  sed -i.bak 's/\.yml@v1\.14/.yml@v1.0/' "$d/.github/workflows/checks.yml"
  rm -f "$d"/make/*.bak "$d"/.github/workflows/*.bak
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"standard v1.0"* ]]
  [[ $output == *"make/common.mk: standard v1.0, the skill is at v1.14"* ]]
  [[ $output == *"make/VERSION: says 1.0, the skill is at v1.14"* ]]
  [[ $output == *"zephyr.yml@v1.0: the skill is at v1.14"* ]]
}

@test "audit 1.12: a project still on 1.11 is outdated (make/VERSION, the managed header, the @v1.11 uses lines)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/on111"
  sa_fresh "$d"
  printf '1.11\n' >"$d/make/VERSION"
  sed -i.bak '1s/v1\.14/v1.11/' "$d/make/common.mk"
  sed -i.bak 's/\.yml@v1\.14/.yml@v1.11/' "$d/.github/workflows/checks.yml"
  rm -f "$d"/make/*.bak "$d"/.github/workflows/*.bak
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"make/common.mk: standard v1.11, the skill is at v1.14"* ]] || false
  [[ $output == *"make/VERSION: says 1.11, the skill is at v1.14"* ]] || false
  [[ $output == *"zephyr.yml@v1.11: the skill is at v1.14"* ]] || false
}

@test "audit 1.11: a project still on 1.10 is outdated (make/VERSION, the managed header, the @v1.10 uses lines)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/on110"
  sa_fresh "$d"
  printf '1.10\n' >"$d/make/VERSION"
  sed -i.bak '1s/v1\.14/v1.10/' "$d/make/common.mk"
  sed -i.bak 's/\.yml@v1\.14/.yml@v1.10/' "$d/.github/workflows/checks.yml"
  rm -f "$d"/make/*.bak "$d"/.github/workflows/*.bak
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"make/common.mk: standard v1.10, the skill is at v1.14"* ]] || false
  [[ $output == *"make/VERSION: says 1.10, the skill is at v1.14"* ]] || false
  [[ $output == *"zephyr.yml@v1.10: the skill is at v1.14"* ]] || false
}

@test "audit 1.10: a project still on 1.9 is outdated (make/VERSION, the managed header, the @v1.9 uses lines)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/on19"
  sa_fresh "$d"
  printf '1.9\n' >"$d/make/VERSION"
  sed -i.bak '1s/v1\.14/v1.9/' "$d/make/common.mk"
  sed -i.bak 's/\.yml@v1\.14/.yml@v1.9/' "$d/.github/workflows/checks.yml"
  rm -f "$d"/make/*.bak "$d"/.github/workflows/*.bak
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"make/common.mk: standard v1.9, the skill is at v1.14"* ]] || false
  [[ $output == *"make/VERSION: says 1.9, the skill is at v1.14"* ]] || false
  [[ $output == *"zephyr.yml@v1.9: the skill is at v1.14"* ]] || false
}

@test "audit 1.9: a project still on 1.8 is outdated (make/VERSION, the managed header, the @v1.8 uses lines)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/on18"
  sa_fresh "$d"
  printf '1.8\n' >"$d/make/VERSION"
  sed -i.bak '1s/v1\.14/v1.8/' "$d/make/common.mk"
  sed -i.bak 's/\.yml@v1\.14/.yml@v1.8/' "$d/.github/workflows/checks.yml"
  rm -f "$d"/make/*.bak "$d"/.github/workflows/*.bak
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"make/common.mk: standard v1.8, the skill is at v1.14"* ]] || false
  [[ $output == *"make/VERSION: says 1.8, the skill is at v1.14"* ]] || false
  [[ $output == *"zephyr.yml@v1.8: the skill is at v1.14"* ]] || false
}

@test "audit 1.8: a project still on 1.7 is outdated (make/VERSION, the managed header, the @v1.7 uses lines)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/on17"
  sa_fresh "$d"
  printf '1.7\n' >"$d/make/VERSION"
  sed -i.bak '1s/v1\.14/v1.7/' "$d/make/common.mk"
  sed -i.bak 's/\.yml@v1\.14/.yml@v1.7/' "$d/.github/workflows/checks.yml"
  rm -f "$d"/make/*.bak "$d"/.github/workflows/*.bak
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"make/common.mk: standard v1.7, the skill is at v1.14"* ]] || false
  [[ $output == *"make/VERSION: says 1.7, the skill is at v1.14"* ]] || false
  [[ $output == *"zephyr.yml@v1.7: the skill is at v1.14"* ]] || false
}

# sa_on_11 DIR: a fresh scaffold turned back into a 1.1 project: make/VERSION, the managed headers, the @v1.1 uses
# lines, the 1.1 make/bin/refs.sh and the references/ line of .gitignore
sa_on_11() {
  local d=$1 f
  printf '1.1\n' >"$d/make/VERSION"
  for f in "$d/Makefile" "$d/make/common.mk" "$d"/make/bin/*.sh "$d"/make/kinds/*.mk; do
    sed -i.bak '1,2s/project-standard v1\.14 /project-standard v1.1 /' "$f"
  done
  sed -i.bak 's/\.yml@v1\.14/.yml@v1.1/' "$d/.github/workflows/checks.yml" "$d/.github/workflows/release.yml"
  printf '#!/usr/bin/env bash\n%s\n' "$(sed -n 1p "$d/make/common.mk")" >"$d/make/bin/refs.sh"
  printf '\n# reference documents (make refs-fetch downloads what docs/references.md lists; never committed)\nreferences/\n' >>"$d/.gitignore"
  rm -f "$d"/make/*.bak "$d"/make/bin/*.bak "$d"/make/kinds/*.bak "$d"/*.bak "$d"/.github/workflows/*.bak
}

@test "audit 1.2: a 1.1 project with a links-only references.md and no KiCad board is outdated, with no wrl or references warning" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/on11"
  "$skill/scripts/scaffold.sh" "$d" --project on11 --part firmware:zephyr --part api:cloud-worker:cloud/api >/dev/null
  sa_on_11 "$d"
  printf '# on11: references\n\n## Datasheets\n\n### MCU\n\n- [nRF9151 (NRF9151-LACA) — Nordic](https://example.invalid/nrf9151.pdf)\n' >"$d/docs/references.md"
  # a 1.1 .gitattributes had *.wrl in every project; one without it is fine without a KiCad board
  sed -i.bak '/^\*\.wrl /d' "$d/.gitattributes" && rm -f "$d/.gitattributes.bak"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"make/common.mk: standard v1.1, the skill is at v1.14"* ]] || false
  [[ $output == *"make/VERSION: says 1.1, the skill is at v1.14"* ]] || false
  [[ $output == *"zephyr.yml@v1.1: the skill is at v1.14"* ]] || false
  [[ $output == *"make/bin/refs.sh: a managed file the standard no longer has"*"git rm make/bin/refs.sh"* ]] || false
  [[ $output != *"wrl"* ]] || false
  [[ $output != *"docs      docs/references.md"* ]] || false
  [[ $output != *"error"* ]] || false
  # --json carries the same finding
  run "$skill/scripts/audit.sh" "$d" --json
  [[ $output == *"make/bin/refs.sh"* ]] || false
}

@test "audit 1.2: a references.md table with File or SHA256 columns is a docs warning with the conversion as its fix" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/reftable"
  sa_fresh "$d"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  printf '# References\n\n| Title | Vendor | File | URL | SHA256 |\n|---|---|---|---|---|\n| Manual | Acme | acme/m.pdf | https://example.invalid/m.pdf | |\n' >"$d/docs/references.md"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"warn     docs      docs/references.md: a table with File / SHA256 columns (1.1)"* ]] || false
  [[ $output == *"'- [Title (MPN) — Vendor](URL)'"*"keep Title, Vendor and URL; drop File and SHA256"*"remove references/ from .gitignore"*"git rm make/bin/refs.sh"* ]] || false
  # a lowercase header with only one of the columns counts too; a table of other columns does not
  printf '| title | sha256 | url |\n|---|---|---|\n' >"$d/docs/references.md"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output == *"docs/references.md: a table with File / SHA256 columns"* ]] || false
  printf '# References\n\n| Part | Notes |\n|---|---|\n| U1 | the profile picture of a file |\n' >"$d/docs/references.md"
  run "$skill/scripts/audit.sh" "$d"
  [ "$status" -eq 0 ]
}

@test "audit 1.2: *.wrl is required only with a hardware part; step, stp and fcstd always" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/wrlhw"
  sa_fresh "$d"
  grep -Eq '^\*\.wrl filter=lfs' "$d/.gitattributes"
  sed -i.bak '/^\*\.wrl /d' "$d/.gitattributes" && rm -f "$d/.gitattributes.bak"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *".gitattributes: no LFS line for: *.wrl"* ]] || false
  d="$BATS_TEST_TMPDIR/nokicad"
  "$skill/scripts/scaffold.sh" "$d" --project nokicad --part firmware:zephyr --part case:mechanical >/dev/null
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  sed -i.bak '/^\*\.stp /d' "$d/.gitattributes" && rm -f "$d/.gitattributes.bak"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output == *".gitattributes: no LFS line for: *.stp"* ]] || false
  [[ $output != *"wrl"* ]] || false
}

@test "audit 1.2: an altium part needs the PrjPcbVariants LFS line and the -text lines of its project and OutJob" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/altattrs"
  "$skill/scripts/scaffold.sh" "$d" --project altattrs --part hardware:altium >/dev/null
  sa_submodule "$d"
  run "$skill/scripts/audit.sh" "$d"
  [ "$status" -eq 0 ]
  grep -Ev '^\*\.(PrjPcbVariants|PrjPcb|OutJob) ' "$d/.gitattributes" >"$d/ga" && mv "$d/ga" "$d/.gitattributes"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *".gitattributes: no LFS line for Altium's: *.PrjPcbVariants"* ]] || false
  [[ $output == *".gitattributes: no -text line for: *.PrjPcb *.OutJob"*"scaffold.sh <dir> --force appends"* ]] || false
  # scaffold --force puts them back, and the audit is clean again
  "$skill/scripts/scaffold.sh" "$d" --project altattrs --part hardware:altium --force >/dev/null
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  # a project without an altium part is not asked for them
  d="$BATS_TEST_TMPDIR/noalt"
  sa_fresh "$d"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output != *"PrjPcb"* ]] || false
}

@test "audit 1.2: a .PrjPcbVariants committed as a plain blob is an Altium binary error" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/variants"
  "$skill/scripts/scaffold.sh" "$d" --project variants --part hardware:altium >/dev/null
  sa_git "$d" init -q -b main
  printf '\xD0\xCF\x11\xE0binary\0variants' >"$d/hardware/Board.PrjPcbVariants"
  # committed before the LFS line was there: a plain blob
  grep -Ev '^\*\.PrjPcbVariants ' "$d/.gitattributes" >"$d/ga" && mv "$d/ga" "$d/.gitattributes"
  sa_git "$d" add -A
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"hardware/Board.PrjPcbVariants: Altium binary document committed as a plain git blob"* ]] || false
}

# sa_submodule DIR: the .gitmodules entry make <part>-setup writes for the Altium library at its default path
sa_submodule() {
  printf '[submodule "hardware/altium-library"]\n\tpath = hardware/altium-library\n\turl = https://github.com/example-owner/altium-library.git\n' >"$1/.gitmodules"
}

@test "audit 1.4: an altium part without the Altium library submodule is a warning with the fix; ALTIUM_LIBRARY moves it" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/altlib"
  "$skill/scripts/scaffold.sh" "$d" --project altlib --part hardware:altium >/dev/null
  [ -f "$d/docs/hardware/library.md" ]
  printf 'ALTIUM_LIBRARY_PROJECT := beta/alib\n' >>"$d/make/project.mk"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"part hardware (altium) has no Altium library submodule at hardware/altium-library"*"git submodule add https://github.com/beta/alib.git hardware/altium-library"* ]] || false
  sa_submodule "$d"
  run "$skill/scripts/audit.sh" "$d"
  [ "$status" -eq 0 ]
  printf 'ALTIUM_LIBRARY := lib/altium\n' >>"$d/make/project.mk"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output == *"no Altium library submodule at lib/altium"* ]] || false
  # the library notes are a kind doc of altium
  rm "$d/docs/hardware/library.md"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output == *"docs/hardware/library.md: missing"* ]] || false
}

@test "audit 1.5: an altium part with a bom/ folder (from 1.4) gets a warning to remove it; the OutJob's BOM is the one" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/altbom"
  "$skill/scripts/scaffold.sh" "$d" --project altbom --part hardware:altium >/dev/null
  sa_submodule "$d"
  [ ! -e "$d/hardware/bom" ]
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 0 ]
  mkdir -p "$d/hardware/BOM"
  printf 'Comment,Designator\r\n' >"$d/hardware/BOM/Board_BOM.csv"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"warn"*"layout"*"hardware/BOM: part hardware (altium): since 1.5 the BOM is the one the OutJob writes to hardware/outputs/"*"git rm -r 'hardware/BOM'"* ]] || false
  [[ $output != *"error"*"hardware/BOM"* ]] || false
}

@test "audit 1.8: ENV_DEFINES on an espidf part without the CMakeLists block, an arm-gcc Makefile without STD_ENV_CFLAGS, a circuitpython part" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/envdefs"
  "$skill/scripts/scaffold.sh" "$d" --project envdefs --part esp:espidf --part iface:arm-gcc --part cpy:circuitpython >/dev/null
  printf 'cmake_minimum_required(VERSION 3.16)\ninclude($ENV{IDF_PATH}/tools/cmake/project.cmake)\nproject(esp)\n' >"$d/firmware/esp/CMakeLists.txt"
  printf 'build:\n\tarm-none-eabi-gcc $(CFLAGS) -c main.c\n' >"$d/firmware/iface/Makefile"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output != *"ENV_DEFINES"* ]] || false
  printf 'esp_ENV_DEFINES_staging := CLOUD_URL="wss://x/ws"\niface_ENV_DEFINES_production := N=1\ncpy_ENV_DEFINES_local := N=2\n' >>"$d/make/project.mk"
  run "$skill/scripts/audit.sh" "$d"
  echo "$output"
  [[ $output == *"firmware/esp/CMakeLists.txt: part esp sets esp_ENV_DEFINES_* but its CMakeLists.txt does not apply STD_ENV_DEFINES"*'foreach(std_define IN LISTS STD_ENV_DEFINES) idf_build_set_property(COMPILE_DEFINITIONS "${std_define}" APPEND) endforeach()'* ]] || false
  [[ $output == *"firmware/iface/Makefile: part iface sets iface_ENV_DEFINES_* but its Makefile never uses STD_ENV_CFLAGS"*'CFLAGS += $(STD_ENV_CFLAGS)'* ]] || false
  [[ $output == *"part cpy (circuitpython) sets cpy_ENV_DEFINES_*"* ]] || false
  # the block and the Makefile line make the warnings go
  printf 'cmake_minimum_required(VERSION 3.16)\ninclude($ENV{IDF_PATH}/tools/cmake/project.cmake)\nforeach(std_define IN LISTS STD_ENV_DEFINES)\n  idf_build_set_property(COMPILE_DEFINITIONS "${std_define}" APPEND)\nendforeach()\nproject(esp)\n' >"$d/firmware/esp/CMakeLists.txt"
  printf 'CFLAGS += $(STD_ENV_CFLAGS)\nbuild:\n\tarm-none-eabi-gcc $(CFLAGS) -c main.c\n' >"$d/firmware/iface/Makefile"
  run "$skill/scripts/audit.sh" "$d"
  [[ $output != *"STD_ENV_DEFINES"* ]] || false
  [[ $output != *"STD_ENV_CFLAGS"* ]] || false
}
