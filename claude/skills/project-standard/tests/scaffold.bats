#!/usr/bin/env bats
# Tests for scripts/scaffold.sh. Projects are built in $BATS_TEST_TMPDIR; nothing touches the
# network, git remotes, ~/.secrets or ~/.config.

if [[ -f "$BATS_TEST_DIRNAME/helpers.bash" ]]; then
  load helpers
fi

SA_HEADER='# project-standard v1.10 (managed: refresh with the project-standard skill, put project changes in make/local.mk)'
SA_KINDS="zephyr espidf pio arm-gcc circuitpython silabs hardware altium mechanical cloud-worker web-pages app-flutter app-tauri app-xcode app-android docker go python"

# One part per kind. Dirs are explicit (the dir equals the part name unless nested), so the tree below stays
# the same as the group-folder defaults change; the defaults themselves are tested further down.
SA_ALL_PARTS=(
  --part firmware:zephyr:firmware
  --part esp:espidf:esp
  --part sensor:pio:sensor
  --part interface:arm-gcc:interface
  --part badge:circuitpython:badge
  --part radio:silabs:radio
  --part hardware:hardware:hardware
  --part board:altium:board
  --part case:mechanical:case
  --part cloud-api:cloud-worker:cloud/api
  --part cloud-web:web-pages:cloud/web
  --part app:app-flutter:app
  --part desktop:app-tauri:desktop
  --part ios:app-xcode:ios
  --part android:app-android:android
  --part worker-image:docker:worker-image
  --part gateway:go:gateway
  --part tools:python:tools
)

# sa_absent GREP-ARGS: fail when grep finds a match (a bare `! grep` does not fail a bats test)
sa_absent() {
  if grep "$@"; then
    return 1
  fi
}

setup() {
  SA_REAL_SKILL=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export NO_COLOR=1
  export STD_CONFIG="$BATS_TEST_TMPDIR/config"
  export SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
  unset CI_TEMPLATES_REPO CI_TEMPLATES_PROJECT GITHUB_OWNER GITLAB_GROUP KICAD_LIBRARY_PROJECT
  mkdir -p "$STD_CONFIG"
  printf 'GITHUB_OWNER := example-owner\n' >"$STD_CONFIG/config.mk"
}

# sa_uses_ok FILE: every uses: line is the CI templates' reusable workflow at @v1.10, or actions/checkout pinned by SHA
sa_uses_ok() {
  local ref
  while IFS= read -r ref; do
    case $ref in
      mayankgautam-me/ci-templates/.github/workflows/*.yml@v1.10) ;;
      actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1) ;;
      *)
        echo "unexpected uses in $1: $ref" >&2
        return 1
        ;;
    esac
  done < <(sed -nE 's/^[[:space:]]*(- )?uses:[[:space:]]*//p' "$1" | sed 's/[[:space:]]*#.*$//')
}

# A copy of the skill whose missing managed templates are filled with minimal fakes, so the
# scaffold's own behaviour is tested whether or not the other templates are finished.
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

sa_scaffold_all() {
  local skill
  skill=$(sa_skill_copy)
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/demo" --project demo "${SA_ALL_PARTS[@]}"
}

@test "scaffold with every kind produces the expected tree" {
  sa_scaffold_all
  [ "$status" -eq 0 ]
  d="$BATS_TEST_TMPDIR/demo"
  skill=$(sa_skill_copy)

  # managed files
  cmp "$d/Makefile" "$skill/templates/project/Makefile"
  [ "$(sed -n 1p "$d/Makefile")" = "$SA_HEADER" ]
  [ "$(tr -d '[:space:]' <"$d/make/VERSION")" = 1.10 ]
  cmp "$d/make/common.mk" "$skill/templates/make/common.mk"
  for f in "$skill"/templates/make/bin/*.sh; do
    [ -x "$d/make/bin/$(basename "$f")" ]
  done
  for k in $SA_KINDS; do
    cmp "$d/make/kinds/$k.mk" "$skill/templates/make/kinds/$k.mk"
  done

  # project.mk
  grep -Eq '^PROJECT +:= demo$' "$d/make/project.mk"
  grep -Eq '^PORT_BASE +:= [0-9]+$' "$d/make/project.mk"
  grep -Fq '  cloud-api:cloud-worker:cloud/api \' "$d/make/project.mk"
  grep -Eq '^  tools:python(:tools)?$' "$d/make/project.mk"
  grep -Fq 'firmware_BOARD' "$d/make/project.mk"
  grep -Eq '^cloud-web_OUT := cloud/web/public' "$d/make/project.mk"
  grep -Eq '^cloud-api_PORT_OFFSET := 0' "$d/make/project.mk"
  grep -Eq '^cloud-web_PORT_OFFSET := 1' "$d/make/project.mk"
  sa_absent -q '@@' "$d/make/project.mk"

  # project files
  for f in make/local.mk Brewfile mise.toml secrets.schema .gitignore .gitattributes .github/workflows/checks.yml \
    .github/workflows/release.yml README.md CLAUDE.md PLAN.md tests/smoke/README.md tests/remote/README.md; do
    [ -f "$d/$f" ]
    sa_absent -q '@@' "$d/$f"
  done
  [ ! -e "$d/.env.example" ]
  [ ! -e "$d/.gitlab-ci.yml" ]

  # Brewfile: base plus per-kind lines, no duplicates
  grep -Fxq 'brew "age-plugin-se"' "$d/Brewfile"
  grep -Fxq 'cask "kicad"' "$d/Brewfile"
  grep -Fxq 'cask "gcc-arm-embedded"' "$d/Brewfile"
  [ "$(grep -c '^brew "cmake"$' "$d/Brewfile")" -eq 1 ]

  # mise.toml
  grep -Fxq 'node = "22"' "$d/mise.toml"
  grep -Fxq 'go = "1.25"' "$d/mise.toml"
  [ "$(grep -c '^python = ' "$d/mise.toml")" -eq 1 ]

  # .gitignore blocks
  grep -Fxq 'node_modules/' "$d/.gitignore"
  grep -Fxq '.pio/' "$d/.gitignore"
  grep -Fxq '*.pem' "$d/.gitignore"
  [ "$(grep -c '^build/$' "$d/.gitignore")" -eq 1 ]
  # the local CI runs: work folder and secrets file
  grep -Fxq '.act/' "$d/.gitignore"
  grep -Fxq '.secrets' "$d/.gitignore"

  # .gitattributes LFS lines
  for e in step stp wrl fcstd; do
    grep -Eq "^\*\.$e +filter=lfs" "$d/.gitattributes"
  done
  # since 1.1 small files stay in plain git
  for e in png mp4 zip hex; do
    sa_absent -Eq "^\*\.$e[[:space:]].*filter=lfs" "$d/.gitattributes"
  done
  # binary documents: not in LFS, ignored instead
  for e in pdf docx doc xlsx xls pptx ppt odt ods odp; do
    sa_absent -Eq "^\*\.$e[[:space:]]" "$d/.gitattributes"
    grep -Fxq "*.$e" "$d/.gitignore"
  done
  grep -Eq '^\*\.kicad_pcb +text$' "$d/.gitattributes"

  # secrets.schema: cloudflare lines because there is a cloud part
  grep -Eq '^CLOUDFLARE_API_TOKEN +staging,production +auth,ci +no ' "$d/secrets.schema"
  grep -Eq '^CLOUDFLARE_ACCOUNT_ID +common ' "$d/secrets.schema"

  # CI: checks.yml and release.yml, the reusable workflows of the owner's CI templates repository, a job per part
  ci="$d/.github/workflows/checks.yml"
  rel="$d/.github/workflows/release.yml"
  grep -Fxq 'name: checks' "$ci"
  grep -Fxq 'name: release' "$rel"
  grep -Fxq "    branches: ['**']" "$ci"
  grep -Fxq "    tags: ['*-v*']" "$rel"
  grep -Fxq '  group: checks-${{ github.ref }}' "$ci"
  grep -Fxq "  cancel-in-progress: \${{ github.event_name != 'workflow_dispatch' }}" "$ci"
  grep -Fxq '  contents: read' "$ci"
  grep -Fxq '  contents: read' "$rel"
  grep -Fxq '  contents: read' "$ci"   # the top level is read-only; a job grants what it needs
  for k in $SA_KINDS; do
    grep -Fq "mayankgautam-me/ci-templates/.github/workflows/$k.yml@v1.10" "$ci"
    # altium: CI checks the board only, its Release is made where Altium's outputs are (no release job)
    if [[ $k == altium ]]; then
      sa_absent -Fq "mayankgautam-me/ci-templates/.github/workflows/$k.yml@v1.10" "$rel"
    else
      grep -Fq "mayankgautam-me/ci-templates/.github/workflows/$k.yml@v1.10" "$rel"
    fi
  done
  grep -Fxq '  firmware:' "$ci"
  grep -Fxq "    if: needs.changes.outputs.firmware == 'true'" "$ci"
  grep -Fxq '  cloud-api:' "$ci"
  grep -Fxq "    if: needs.changes.outputs.cloud_api == 'true'" "$ci"
  grep -Fxq '      part_dir: cloud/api' "$ci"
  grep -Fxq '      run_release: false' "$ci"
  grep -Fxq '  desktop:' "$ci"
  grep -Fxq "    if: needs.changes.outputs.desktop == 'true'" "$ci"
  grep -Fxq '      cloud_api: ${{ steps.changes.outputs.cloud_api }}' "$ci"
  grep -Fq "if changed 'cloud/api'; then echo 'cloud_api=true'; else echo 'cloud_api=false'; fi" "$ci"
  grep -Fq 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' "$ci"
  # the tag jobs: one per part, filtered by its tag, releasing
  grep -Fxq '  firmware-release:' "$rel"
  grep -Fxq "    if: needs.tag.outputs.part == 'firmware'" "$rel"
  grep -Fxq '  desktop-release:' "$rel"
  grep -Fxq "    if: needs.tag.outputs.part == 'desktop'" "$rel"
  [ "$(grep -c "needs.tag.outputs.part == " "$rel")" -eq 17 ]
  sa_absent -Fxq '  board-release:' "$rel"
  sa_absent -Fq 'board-release' "$rel"
  # every release and production job, and the latest job (v20), grants its own contents: write (the caller's ceiling for the called job)
  [ "$(grep -c 'contents: write' "$rel")" -eq "$(( $(grep -c '^    needs: tag$' "$rel") + $(grep -c '^  [a-z0-9-]*-production:$' "$rel") + $(grep -c '^  latest:$' "$rel") ))" ]
  grep -Fxq '      run_release: true' "$rel"
  # production steps: by hand (workflow_dispatch with part and confirm), for the kinds that have one
  grep -Fxq '  firmware-production:' "$rel"
  grep -Fxq "    if: github.event_name == 'workflow_dispatch' && inputs.part == 'firmware' && inputs.confirm == 'production'" "$rel"
  grep -Fxq '  cloud-api-production:' "$rel"
  # the tag of a Cloudflare part deploys production before its Release: confirm: production in its tag job only
  [ "$(grep -c '^      confirm: production$' "$rel")" -eq 2 ]
  for p in cloud-api cloud-web; do
    job=$(sed -n "/^  $p-release:/,/^  [a-z]/p" "$rel")
    [[ $job == *$'\n      confirm: production\n'* ]]
  done
  job=$(sed -n '/^  firmware-release:/,/^  [a-z]/p' "$rel")
  [[ $job != *confirm* ]]
  # production never comes from checks.yml
  sa_absent -Fq 'confirm' "$ci"
  # python has no publish job in CI (PyPI is made by hand with make <part>-release PUBLISH=1), so no production job
  sa_absent -Fxq '  tools-production:' "$rel"
  for p in hardware board case worker-image gateway; do
    sa_absent -Fxq "  $p-production:" "$rel"
  done
  # silabs is firmware: a production step (OTA) by hand, from the build run
  grep -Fxq '  radio-production:' "$rel"
  job=$(sed -n '/^  radio-production:/,/^  [a-z]/p' "$rel")
  [[ $job == *'source_run_id: ${{ inputs.source_run_id }}'* ]]
  # the hardware part's KiCad library: the deploy key is passed to its jobs only
  grep -Fq 'KICAD_LIBRARY_DEPLOY_KEY: ${{ secrets.KICAD_LIBRARY_DEPLOY_KEY }}' "$ci"
  [ "$(grep -c 'KICAD_LIBRARY_DEPLOY_KEY' "$ci")" -eq 1 ]
  # every uses line is the CI templates at the standard's version or an actions/* pin by SHA; no placeholder left
  sa_uses_ok "$ci"
  sa_uses_ok "$rel"
  sa_absent -q 'OWNER' "$ci" "$rel"
  if command -v yq >/dev/null 2>&1; then
    [ "$(yq '.jobs.firmware.uses' "$ci")" = 'mayankgautam-me/ci-templates/.github/workflows/zephyr.yml@v1.10' ]
    [ "$(yq '.jobs.hardware.secrets.KICAD_LIBRARY_DEPLOY_KEY' "$ci")" = '${{ secrets.KICAD_LIBRARY_DEPLOY_KEY }}' ]
    [ "$(yq '.jobs.firmware-release.with.run_release' "$rel")" = true ]
    yq '.' "$ci" >/dev/null
    yq '.' "$rel" >/dev/null
  fi

  # PLAN.md: the root component plus one per part
  grep -Fxq '## Project {#project}' "$d/PLAN.md"
  grep -Fxq '## Cloud api {#cloud-api}' "$d/PLAN.md"
  grep -Fxq 'files: [cloud/api/**, docs/cloud-api/**]' "$d/PLAN.md"
  grep -Fxq 'files: [cloud/web/**]' "$d/PLAN.md"
  grep -Fxq 'kind: zephyr' "$d/PLAN.md"
  [ "$(grep -Ec '^## .* \{#[a-z0-9-]+\}$' "$d/PLAN.md")" -eq 19 ]
  grep -Fxq 'kind: silabs' "$d/PLAN.md"
  grep -Fxq 'files: [board/**, docs/board/**]' "$d/PLAN.md"
  grep -Fxq 'files: [case/**, docs/case/**]' "$d/PLAN.md"

  # starters
  grep -Fq '"wrangler": "' "$d/cloud/api/package.json"
  sa_absent -Eq '"wrangler": "[~^]' "$d/cloud/api/package.json"
  grep -Fq '"staging"' "$d/cloud/api/wrangler.jsonc"
  grep -Fq '"production"' "$d/cloud/api/wrangler.jsonc"
  grep -Fq '"name": "demo-staging-cloud-api"' "$d/cloud/api/wrangler.jsonc"
  grep -Fq '"name": "demo-production-cloud-api"' "$d/cloud/api/wrangler.jsonc"   # <project>-<env>-<part>, like the resources
  grep -Fq '/health' "$d/cloud/api/src/index.ts"
  [ -f "$d/cloud/web/public/index.html" ]
  grep -Fq 'make hardware-new NAME=' "$d/hardware/README.md"
  [ "$(find "$d/hardware" -type f | wc -l | tr -d ' ')" -eq 2 ]
  grep -Fq 'firmware_BOARD' "$d/firmware/README.md"
  grep -Fq 'esp_TARGET' "$d/esp/README.md"
  # 1.8: per-environment defines; espidf's README carries the CMakeLists block, a circuitpython part's none
  grep -Fq 'esp_ENV_DEFINES_staging' "$d/esp/README.md"
  grep -Fq 'idf_build_set_property(COMPILE_DEFINITIONS "${std_define}" APPEND)' "$d/esp/README.md"
  grep -Fq 'firmware_ENV_DEFINES_production' "$d/firmware/README.md"
  if grep -q 'ENV_DEFINES' "$d/badge/README.md"; then false; fi
  [ -f "$d/ios/README.md" ]
  [ -f "$d/tools/README.md" ]

  # no network, no git
  [ ! -d "$d/.git" ]
  [ ! -d "$d/cloud/api/node_modules" ]
}

@test "scaffold pio part: <part>_PIO_ENV in project.mk and README, PlatformIO pinned by mise and not in the Brewfile" {
  local skill d
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/piofw"
  run "$skill/scripts/scaffold.sh" "$d" --project piofw --part fw:pio
  [ "$status" -eq 0 ]
  [ -f "$d/firmware/README.md" ]
  grep -Fq '# fw_PIO_ENV := <env>' "$d/make/project.mk"
  sa_absent -Eq '(^|[^A-Za-z])fw_ENV' "$d/make/project.mk"
  grep -Fq 'fw_PIO_ENV := <env>' "$d/firmware/README.md"
  sa_absent -Eq '(^|[^A-Za-z])fw_ENV([^_]|$)' "$d/firmware/README.md"
  # the variable the kind reads is the one the comment names
  grep -Fq '$(1)_PIO_ENV ?=' "$SA_REAL_SKILL/templates/make/kinds/pio.mk"
  grep -Fxq '"pipx:platformio" = "6"' "$d/mise.toml"
  grep -Fxq 'uv = "0.9"' "$d/mise.toml"
  sa_absent -iq 'platformio' "$d/Brewfile"
}

@test "scaffold refuses a non-empty dir without --force and writes nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/busy"
  echo keep >"$BATS_TEST_TMPDIR/busy/notes.txt"
  run "$SA_REAL_SKILL/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/busy" --project busy --part api:go
  [ "$status" -eq 1 ]
  [[ $output == *"not empty"* ]]
  [ "$(find "$BATS_TEST_TMPDIR/busy" -type f | wc -l | tr -d ' ')" -eq 1 ]
}

@test "scaffold --force keeps project-owned files and existing part dirs" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/existing"
  mkdir -p "$d/cloud"
  echo "# mine" >"$d/README.md"
  echo "package main" >"$d/cloud/main.go"
  echo "# my api" >"$d/cloud/README.md"
  run "$skill/scripts/scaffold.sh" "$d" --project existing --part api:go --force
  [ "$status" -eq 0 ]
  [ "$(cat "$d/README.md")" = "# mine" ]
  [ "$(cat "$d/cloud/README.md")" = "# my api" ]
  [ "$(cat "$d/cloud/main.go")" = "package main" ]
  # no starter code in an existing part folder, but its missing docs are added
  [ ! -f "$d/cloud/go.mod" ]
  [ -f "$d/cloud/CHANGELOG.md" ]
  [ -f "$d/docs/api/usage.md" ]
  [ -f "$d/make/common.mk" ]
  [[ $output == *"kept existing README.md"* ]]
}

@test "scaffold rejects bad arguments" {
  skill=$(sa_skill_copy)
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/a" --project Bad --part api:go
  [ "$status" -eq 1 ]
  [[ $output == *"lowercase"* ]]
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/b" --project ok --part api:cobol
  [ "$status" -eq 1 ]
  [[ $output == *"unknown kind"* ]]
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/c" --project ok --part api:go --part api:python
  [ "$status" -eq 1 ]
  [[ $output == *"given twice"* ]]
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/d" --project ok --part api:go:../out
  [ "$status" -eq 1 ]
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/e" --project ok
  [ "$status" -eq 1 ]
  [[ $output == *"--part"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/a" ]
  [ ! -e "$BATS_TEST_TMPDIR/b" ]
}

@test "scaffold without a cloud part has no Cloudflare secrets and takes --port-base" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/fw"
  run "$skill/scripts/scaffold.sh" "$d" --project fw --part firmware:zephyr --part board:hardware --port-base 8300
  [ "$status" -eq 0 ]
  sa_absent -q CLOUDFLARE "$d/secrets.schema"
  grep -Eq '^PORT_BASE +:= 8300$' "$d/make/project.mk"
  sa_absent -Fq 'cloud-worker' "$d/.github/workflows/checks.yml" "$d/.github/workflows/release.yml"
  grep -Fxq '  firmware-release:' "$d/.github/workflows/release.yml"
  grep -Fxq '  board-release:' "$d/.github/workflows/release.yml"
  sa_absent -Fxq '  board-production:' "$d/.github/workflows/release.yml"
  [ ! -e "$d/make/kinds/cloud-worker.mk" ]
  # no Cloudflare and no OTA bucket: the firmware publish is skipped, so no production job and the README says so
  sa_absent -Fxq '  firmware-production:' "$d/.github/workflows/release.yml"
  grep -Fq 'No OTA upload: the project has no OTA bucket' "$d/firmware/README.md"
  # an OTA bucket in the project's project.mk brings the production job back (scaffold again with --force)
  printf 'OTA_BUCKET := fw-ota\n' >>"$d/make/project.mk"
  rm "$d/.github/workflows/release.yml"
  run "$skill/scripts/scaffold.sh" "$d" --force --project fw --part firmware:zephyr --part board:hardware --port-base 8300
  [ "$status" -eq 0 ]
  grep -Fxq '  firmware-production:' "$d/.github/workflows/release.yml"
}

@test "scaffold: an OTA bucket alone (no Worker or Pages part) brings the Cloudflare rows; a kept schema is named when it lacks them" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/ota"
  mkdir -p "$d/make"
  printf 'OTA_BUCKET := fw-ota\n' >"$d/make/project.mk"
  run "$skill/scripts/scaffold.sh" "$d" --force --project ota --part firmware:zephyr --part hardware:hardware --part app:app-xcode
  [ "$status" -eq 0 ]
  grep -Eq '^CLOUDFLARE_API_TOKEN +staging,production +auth,ci +no ' "$d/secrets.schema"
  grep -Eq '^CLOUDFLARE_ACCOUNT_ID +common ' "$d/secrets.schema"
  grep -Fxq '  firmware-production:' "$d/.github/workflows/release.yml"
  # a part's own bucket counts too
  d2="$BATS_TEST_TMPDIR/ota2"
  mkdir -p "$d2/make"
  printf 'firmware_OTA_BUCKET := fw-ota\n' >"$d2/make/project.mk"
  run "$skill/scripts/scaffold.sh" "$d2" --force --project ota2 --part firmware:zephyr
  [ "$status" -eq 0 ]
  grep -Eq '^CLOUDFLARE_API_TOKEN ' "$d2/secrets.schema"
  # a kept schema without the rows: the scaffold says so and leaves the file as it was
  printf '# NAME envs used-by gen description\n' >"$d2/secrets.schema"
  run "$skill/scripts/scaffold.sh" "$d2" --force --project ota2 --part firmware:zephyr
  [ "$status" -eq 0 ]
  [[ $output == *"secrets.schema has no CLOUDFLARE_API_TOKEN row"* ]]
  sa_absent -q CLOUDFLARE "$d2/secrets.schema"
}

@test "scaffold 1.7: a part with Access settings brings the service token rows; --force appends them to a kept schema once" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/acc"
  run "$skill/scripts/scaffold.sh" "$d" --project acc --part api:cloud-worker:cloud/api
  [ "$status" -eq 0 ]
  # a new project: the settings are offered commented out, and no rows yet
  grep -Fxq '# api_ACCESS_EMAIL_DOMAINS := example.com' "$d/make/project.mk"
  grep -Fxq '# api_ACCESS_EMAILS := someone@example.com' "$d/make/project.mk"
  sa_absent -q CF_ACCESS_CLIENT_ID "$d/secrets.schema"
  # the user sets them: --force appends both rows to the kept schema and says so
  printf 'api_ACCESS_EMAIL_DOMAINS := example.com\nCF_TOKEN_PERMS := access\n' >>"$d/make/project.mk"
  run "$skill/scripts/scaffold.sh" "$d" --force --project acc --part api:cloud-worker:cloud/api
  [ "$status" -eq 0 ]
  [[ $output == *"secrets.schema: added CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET"* ]]
  grep -Eq '^CF_ACCESS_CLIENT_ID +staging,production +auth,ci +no ' "$d/secrets.schema"
  grep -Eq '^CF_ACCESS_CLIENT_SECRET +staging,production +auth,ci +no ' "$d/secrets.schema"
  run "$skill/scripts/scaffold.sh" "$d" --force --project acc --part api:cloud-worker:cloud/api
  [ "$status" -eq 0 ]
  [ "$(grep -c '^CF_ACCESS_CLIENT_ID ' "$d/secrets.schema")" -eq 1 ]
  # a production-only project: the rows are for production only
  d2="$BATS_TEST_TMPDIR/acc2"
  mkdir -p "$d2/make"
  printf 'web_ACCESS_EMAILS := a@example.com\n' >"$d2/make/project.mk"
  run "$skill/scripts/scaffold.sh" "$d2" --force --project acc2 --part web:web-pages --domain web=site.example.com --production-only web
  [ "$status" -eq 0 ]
  grep -Eq '^CF_ACCESS_CLIENT_ID +production +auth,ci ' "$d2/secrets.schema"
}

@test "scaffold writes each app signing and store row only for the app kinds that read it" {
  skill=$(sa_skill_copy)
  local k d names
  for k in app-xcode app-flutter app-tauri app-android go; do
    d="$BATS_TEST_TMPDIR/sign-$k"
    run "$skill/scripts/scaffold.sh" "$d" --project sign --part app:$k
    [ "$status" -eq 0 ]
    names=$(awk '!/^#/ && NF { print $1 }' "$d/secrets.schema" | tr '\n' ' ')
    case $k in
      app-xcode) [ "$names" = "appstore-api-key " ] ;;
      app-flutter) [ "$names" = "appstore-api-key play-service-account android-upload-keystore ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD " ] ;;
      app-tauri) [ "$names" = "APPLE_SIGNING_IDENTITY APPLE_API_KEY APPLE_API_ISSUER appstore-api-key play-service-account windows-codesign WINDOWS_CERT_PASSWORD " ] ;;
      app-android) [ "$names" = "play-service-account android-keystore ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD " ] ;;
      go) [ -z "$names" ] ;;
    esac
    # every app row is optional: doctor warns about a missing one, never fails on it
    [ -z "$(awk '!/^#/ && NF && $5 != "optional:"' "$d/secrets.schema")" ]
  done
  # the descriptions name the kind's use: xcode uploads, Tauri also notarises
  grep -Eq '^appstore-api-key +keys +app +no +optional: .*App Store Connect upload' "$BATS_TEST_TMPDIR/sign-app-xcode/secrets.schema"
  sa_absent -q notarisation "$BATS_TEST_TMPDIR/sign-app-xcode/secrets.schema"
  grep -Eq '^appstore-api-key .*Tauri macOS notarisation' "$BATS_TEST_TMPDIR/sign-app-tauri/secrets.schema"
  grep -Eq '^APPLE_SIGNING_IDENTITY +production +app +no +optional: .*Tauri macOS build' "$BATS_TEST_TMPDIR/sign-app-tauri/secrets.schema"
  grep -Eq '^WINDOWS_CERT_PASSWORD +staging +ci +no +optional:' "$BATS_TEST_TMPDIR/sign-app-tauri/secrets.schema"
  # two kinds: the union, each row once
  d="$BATS_TEST_TMPDIR/sign-mix"
  run "$skill/scripts/scaffold.sh" "$d" --project sign --part ios:app-xcode --part droid:app-android
  [ "$status" -eq 0 ]
  [ "$(grep -c '^appstore-api-key ' "$d/secrets.schema")" -eq 1 ]
  [ "$(grep -c '^play-service-account ' "$d/secrets.schema")" -eq 1 ]
  grep -q '^android-keystore ' "$d/secrets.schema"
  sa_absent -Eq '^(APPLE_|windows-codesign|WINDOWS_)' "$d/secrets.schema"
}

@test "scaffold: the uses lines name the default CI templates repo, not the project's GITHUB_OWNER (1.7)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/defrepo"
  run "$skill/scripts/scaffold.sh" "$d" --project defrepo --part api:go
  [ "$status" -eq 0 ]
  grep -Fq '    uses: mayankgautam-me/ci-templates/.github/workflows/go.yml@v1.10' "$d/.github/workflows/checks.yml"
  grep -Fq '    uses: mayankgautam-me/ci-templates/.github/workflows/go.yml@v1.10' "$d/.github/workflows/release.yml"
  sa_absent -q 'example-owner/ci-templates' "$d/.github/workflows/checks.yml" "$d/.github/workflows/release.yml"
}

@test "scaffold takes CI_TEMPLATES_REPO from config.mk, and make/project.mk wins over it" {
  skill=$(sa_skill_copy)
  printf 'GITHUB_OWNER := example-owner\nCI_TEMPLATES_REPO := example-group/ci-shared   # a comment\n' >"$STD_CONFIG/config.mk"
  d="$BATS_TEST_TMPDIR/cfg"
  run "$skill/scripts/scaffold.sh" "$d" --project cfg --part api:go
  [ "$status" -eq 0 ]
  grep -Fq 'example-group/ci-shared/.github/workflows/go.yml@v1.10' "$d/.github/workflows/checks.yml"
  grep -Fq 'example-group/ci-shared/.github/workflows/go.yml@v1.10' "$d/.github/workflows/release.yml"
  # the project's own setting wins; the workflows are written again from it
  printf 'CI_TEMPLATES_REPO := project-org/ci-templates\n' >>"$d/make/project.mk"
  rm "$d/.github/workflows/checks.yml" "$d/.github/workflows/release.yml"
  run "$skill/scripts/scaffold.sh" "$d" --project cfg --part api:go --force
  [ "$status" -eq 0 ]
  grep -Fq 'project-org/ci-templates/.github/workflows/go.yml@v1.10' "$d/.github/workflows/checks.yml"
  grep -Fq 'project-org/ci-templates/.github/workflows/go.yml@v1.10' "$d/.github/workflows/release.yml"
  sa_absent -q 'example-group' "$d/.github/workflows/checks.yml"
}

@test "scaffold: CI_TEMPLATES_REPO must be owner/name, and the pre-1.7 CI_TEMPLATES_PROJECT is ignored with a warning" {
  skill=$(sa_skill_copy)
  printf 'CI_TEMPLATES_REPO := no-slash\n' >"$STD_CONFIG/config.mk"
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/badrepo" --project badrepo --part api:go
  [ "$status" -eq 1 ]
  [[ $output == *"CI_TEMPLATES_REPO 'no-slash' must be owner/name"* ]]
  printf 'GITHUB_OWNER := example-owner\nCI_TEMPLATES_PROJECT := example-owner/ci-templates\n' >"$STD_CONFIG/config.mk"
  d="$BATS_TEST_TMPDIR/oldsetting"
  run "$skill/scripts/scaffold.sh" "$d" --project oldsetting --part api:go
  [ "$status" -eq 0 ]
  [[ $output == *"CI_TEMPLATES_PROJECT in the user config is ignored"* ]]
  grep -Fq 'mayankgautam-me/ci-templates/.github/workflows/go.yml@v1.10' "$d/.github/workflows/checks.yml"
  sa_absent -q 'example-owner/ci-templates' "$d/.github/workflows/checks.yml"
}

@test "scaffold without GITHUB_OWNER still names the default CI templates repo" {
  skill=$(sa_skill_copy)
  : >"$STD_CONFIG/config.mk"
  d="$BATS_TEST_TMPDIR/noowner"
  run "$skill/scripts/scaffold.sh" "$d" --project noowner --part api:go
  [ "$status" -eq 0 ]
  grep -Fq 'mayankgautam-me/ci-templates/.github/workflows/go.yml@v1.10' "$d/.github/workflows/checks.yml"
  sa_absent -q 'OWNER/ci-templates' "$d/.github/workflows/checks.yml"
}

@test "scaffold: GITHUB_OWNER must be a GitHub name, and the GitLab-era GITLAB_GROUP is ignored with a warning" {
  skill=$(sa_skill_copy)
  printf 'GITHUB_OWNER := -bad\n' >"$STD_CONFIG/config.mk"
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/badowner" --project badowner --part api:go
  [ "$status" -eq 1 ]
  [[ $output == *"must be a GitHub user or organisation name"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/badowner" ]
  printf 'GITHUB_OWNER := new-owner\nGITLAB_GROUP := old-group\n' >"$STD_CONFIG/config.mk"
  d="$BATS_TEST_TMPDIR/newowner"
  run "$skill/scripts/scaffold.sh" "$d" --project newowner --part api:go
  [ "$status" -eq 0 ]
  [[ $output == *"GITLAB_GROUP"*"ignored"* ]]
  grep -Fq 'mayankgautam-me/ci-templates/.github/workflows/go.yml@v1.10' "$d/.github/workflows/checks.yml"
  sa_absent -q 'old-group' "$d/.github/workflows/checks.yml" "$d/.github/workflows/release.yml"
}

@test "scaffold: a leftover .gitlab-ci.yml is kept, and the output says to git rm it; existing workflows are kept" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/leftover"
  mkdir -p "$d"
  echo 'stages: [build]' >"$d/.gitlab-ci.yml"
  run "$skill/scripts/scaffold.sh" "$d" --force --project leftover --part api:go
  [ "$status" -eq 0 ]
  [[ $output == *"git rm .gitlab-ci.yml"* ]]
  [ "$(cat "$d/.gitlab-ci.yml")" = 'stages: [build]' ]
  [ -f "$d/.github/workflows/checks.yml" ]
  [ -f "$d/.github/workflows/release.yml" ]
  echo '# mine' >"$d/.github/workflows/checks.yml"
  run "$skill/scripts/scaffold.sh" "$d" --force --project leftover --part api:go
  [ "$status" -eq 0 ]
  [[ $output == *"kept existing .github/workflows/checks.yml"* ]]
  [ "$(cat "$d/.github/workflows/checks.yml")" = '# mine' ]
}

@test "scaffold: the part names changes and project are reserved (the CI changes job and the root component)" {
  skill=$(sa_skill_copy)
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/rsv" --project rsv --part changes:go
  [ "$status" -eq 1 ]
  [[ $output == *"reserved"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/rsv" ]
}

@test "make help runs in a scaffold with every kind (real templates)" {
  local missing='' k f
  [[ -f "$SA_REAL_SKILL/templates/make/common.mk" ]] || missing="$missing common.mk"
  for f in lib.sh secrets.sh cf.sh; do
    [[ -f "$SA_REAL_SKILL/templates/make/bin/$f" ]] || missing="$missing bin/$f"
  done
  for k in $SA_KINDS; do
    [[ -f "$SA_REAL_SKILL/templates/make/kinds/$k.mk" ]] || missing="$missing kinds/$k.mk"
  done
  if [[ -n $missing ]]; then
    skip "managed templates not written yet:$missing"
  fi
  run "$SA_REAL_SKILL/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/real" --project real "${SA_ALL_PARTS[@]}"
  [ "$status" -eq 0 ]
  run make --no-print-directory -C "$BATS_TEST_TMPDIR/real" help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *firmware-build* ]]
  [[ $output == *cloud-api-deploy* ]]
  [[ $output == *hardware* ]]
  [[ $output == *radio-power* ]]
  [[ $output == *board-layout* ]]
  [[ $output == *case-build* ]]
}

@test "scaffold --production-only: no staging job, the tag deploys production, no env.staging in a new Worker" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/prod"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part api:cloud-worker:cloud/api --part web:web-pages \
    --part next:cloud-worker --production-only api --production-only web
  [ "$status" -eq 0 ]
  ci="$d/.github/workflows/checks.yml"
  rel="$d/.github/workflows/release.yml"
  # no staging anywhere for the production-only parts
  sa_absent -Fq 'deploy-staging' "$ci" "$rel"
  # checks.yml never deploys production: no confirm input, no confirm in any job
  grep -Fxq '  api:' "$ci"
  grep -Fxq '  web:' "$ci"
  sa_absent -Fq 'confirm' "$ci"
  [ "$(grep -c '^      production_only: true$' "$ci")" -eq 2 ]
  # every Cloudflare part, production-only or not: its tag job deploys production (then the Release), and a
  # production job in release.yml is the hotfix by hand
  for p in api web next; do
    job=$(sed -n "/^  $p-release:/,/^  [a-z]/p" "$rel")
    [[ $job == *$'\n      confirm: production\n'* ]]
    grep -Fxq "  $p-production:" "$rel"
    job=$(sed -n "/^  $p-production:/,/^  [a-z]/p" "$rel")
    [[ $job == *'confirm: ${{ inputs.confirm }}'* ]]
    [[ $job != *source_run_id* ]]
  done
  # the README says how production goes: the tag, a hotfix by hand
  grep -Fq 'Pushing the tag deploys production' "$d/cloud/api/README.md"
  grep -Fq 'A push to main deploys nothing (production-only: no staging).' "$d/cloud/api/README.md"
  grep -Fq 'A push to main deploys staging; production only ever comes from the tag.' "$d/cloud/next/README.md"
  grep -Fq 'release.yml with part `web` and confirm `production`' "$d/web/README.md"
  sa_absent -Fq '"staging"' "$d/cloud/api/wrangler.jsonc"
  grep -Fq '"production"' "$d/cloud/api/wrangler.jsonc"
  grep -Fq '"staging"' "$d/cloud/next/wrangler.jsonc"
  grep -Fq 'api is production-only' "$d/make/project.mk"
  grep -Fq 'make api-deploy ENV=production CONFIRM=production {#api-first-deploy}' "$d/PLAN.md"
  grep -Fq 'make cf-login {#api-token}' "$d/PLAN.md"
  grep -Eq '^CLOUDFLARE_API_TOKEN +staging,production +auth,ci +no +the project.s one API token' "$d/secrets.schema"
}

@test "scaffold finds a production-only Worker from its wrangler.jsonc, and refuses bad --production-only names" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/adopt"
  mkdir -p "$d/api"
  printf '{\n  // the existing Worker\n  "name": "old-api",\n  "env": { "local": {}, "production": { "name": "old-api" } },\n}\n' >"$d/api/wrangler.jsonc"
  run "$skill/scripts/scaffold.sh" "$d" --force --project demo --part api:cloud-worker:api
  [ "$status" -eq 0 ]
  [[ $output == *"production-only"* ]]
  grep -Fxq '      production_only: true' "$d/.github/workflows/checks.yml"
  grep -Fxq '      confirm: production' "$d/.github/workflows/release.yml"
  grep -Fxq '  api-production:' "$d/.github/workflows/release.yml"
  # the existing config is kept as it was
  grep -Fq '"name": "old-api"' "$d/api/wrangler.jsonc"
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/x1" --project demo --part fw:zephyr --production-only fw
  [ "$status" -ne 0 ]
  [[ $output == *"only cloud-worker and web-pages"* ]]
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/x2" --project demo --part api:cloud-worker --production-only nope
  [ "$status" -ne 0 ]
  [[ $output == *"no part named 'nope'"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/x1" ] && [ ! -e "$BATS_TEST_TMPDIR/x2" ]
}

@test "scaffold app-tauri: mise pins Rust with clippy and rustfmt" {
  local skill d
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/tauri"
  run "$skill/scripts/scaffold.sh" "$d" --project tauri --part app:app-tauri
  [ "$status" -eq 0 ]
  grep -Eq '^rust = \{ version = "[0-9.]+", components = "clippy,rustfmt" \}$' "$d/mise.toml"
  [ "$(grep -c '^rust' "$d/mise.toml")" -eq 1 ]
  # mise.toml stays valid TOML
  if command -v yq >/dev/null 2>&1; then
    [ "$(yq -p toml -o json '.tools.rust.components' "$d/mise.toml")" = '"clippy,rustfmt"' ]
  fi
}

@test "scaffold: the local CI runs' work folder and secrets file are ignored in .gitignore" {
  sa_scaffold_all
  [ "$status" -eq 0 ]
  d="$BATS_TEST_TMPDIR/demo"
  grep -Fxq '.act/' "$d/.gitignore"
  grep -Fxq '.secrets' "$d/.gitignore"
  # the scaffold adds them once, whether or not the template already has them
  [ "$(grep -c '^\.act/$' "$d/.gitignore")" -eq 1 ]
  [ "$(grep -c '^\.secrets$' "$d/.gitignore")" -eq 1 ]
}

@test "scaffold does not write the KiCad library into the caller: the library is the KICAD_LIBRARY_REPO repo variable, and the hardware job takes its deploy key" {
  local skill d ci
  skill=$(sa_skill_copy)
  printf 'CI_TEMPLATES_REPO := acme/ci-templates\nKICAD_LIBRARY_PROJECT := acme/kicad-library   # the shared library\n' >"$STD_CONFIG/config.mk"
  d="$BATS_TEST_TMPDIR/board"
  run "$skill/scripts/scaffold.sh" "$d" --project board --part fw:pio --part hardware:hardware
  [ "$status" -eq 0 ]
  ci="$d/.github/workflows/checks.yml"
  # a reusable workflow reads only its own inputs, secrets and vars: an env in the caller reaches nothing
  [ "$(grep -c 'KICAD_LIBRARY_REPO' "$ci")" -eq 0 ]
  grep -Fq 'KICAD_LIBRARY_DEPLOY_KEY' "$ci"
  sa_absent -Fq 'gitlab' "$ci"
}

@test "scaffold leaves a commented OTA_BUCKET in project.mk for the kinds that release OTA, and none otherwise" {
  local skill d
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/ota"
  run "$skill/scripts/scaffold.sh" "$d" --project ota --part fw:pio --part app:app-tauri
  [ "$status" -eq 0 ]
  [ "$(grep -c '^# OTA_BUCKET := <bucket>$' "$d/make/project.mk")" -eq 1 ]
  grep -q 'cf-provision ENV=production CONFIRM=production creates it' "$d/make/project.mk"
  [ "$(grep -c '^# OTA_PUBLIC := r2dev$' "$d/make/project.mk")" -eq 1 ]
  d="$BATS_TEST_TMPDIR/noota"
  run "$skill/scripts/scaffold.sh" "$d" --project noota --part gateway:go
  [ "$status" -eq 0 ]
  sa_absent -q 'OTA_BUCKET' "$d/make/project.mk"
  sa_absent -q 'OTA_PUBLIC' "$d/make/project.mk"
}

@test "scaffold places tests/smoke and tests/remote only with a deployable part" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/nodeploy"
  run "$skill/scripts/scaffold.sh" "$d" --project gadget --part firmware:zephyr --part hardware:hardware \
    --part desktop:app-tauri --part image:docker
  [ "$status" -eq 0 ]
  [ ! -e "$d/tests" ]
  for k in cloud-worker web-pages; do
    d="$BATS_TEST_TMPDIR/deploy-$k"
    run "$skill/scripts/scaffold.sh" "$d" --project gadget --part firmware:zephyr --part site:$k
    [ "$status" -eq 0 ]
    [ -f "$d/tests/smoke/README.md" ]
    [ -f "$d/tests/remote/README.md" ]
  done
}

@test "scaffold .gitignore: each hardware part's production/, SvelteKit and Vite outputs for app-tauri and web-pages" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/ignore"
  run "$skill/scripts/scaffold.sh" "$d" --project gadget --part hardware:hardware:hardware --part io:hardware:boards/io \
    --part desktop:app-tauri:app
  [ "$status" -eq 0 ]
  grep -Fxq 'hardware/production/' "$d/.gitignore"
  grep -Fxq 'boards/io/production/' "$d/.gitignore"
  sa_absent -Fxq 'production/' "$d/.gitignore"
  sa_absent -Fxq '/production/' "$d/.gitignore"
  grep -Fxq 'outputs/' "$d/.gitignore"
  [ "$(grep -c '^\.svelte-kit/$' "$d/.gitignore")" -eq 1 ]
  grep -Fxq 'vite.config.*.timestamp-*' "$d/.gitignore"
  # git agrees: the fab zip and SvelteKit output are ignored, an unrelated production/ is not
  git -C "$d" init -q -b main
  mkdir -p "$d/hardware/production" "$d/app/.svelte-kit" "$d/docs/production"
  : >"$d/hardware/production/Board_v1.zip"
  : >"$d/app/.svelte-kit/tsconfig.json"
  : >"$d/app/vite.config.ts.timestamp-1700000000000-abc.mjs"
  : >"$d/docs/production/notes.md"
  git -C "$d" check-ignore -q hardware/production/Board_v1.zip
  git -C "$d" check-ignore -q app/.svelte-kit/tsconfig.json
  git -C "$d" check-ignore -q app/vite.config.ts.timestamp-1700000000000-abc.mjs
  run git -C "$d" check-ignore -q docs/production/notes.md
  [ "$status" -eq 1 ]

  d="$BATS_TEST_TMPDIR/ignore-web"
  run "$skill/scripts/scaffold.sh" "$d" --project gadget --part site:web-pages:web --part api:cloud-worker
  [ "$status" -eq 0 ]
  grep -Fxq '.svelte-kit/' "$d/.gitignore"
  grep -Fxq 'vite.config.*.timestamp-*' "$d/.gitignore"
  sa_absent -q 'production/' "$d/.gitignore"

  d="$BATS_TEST_TMPDIR/ignore-fw"
  run "$skill/scripts/scaffold.sh" "$d" --project gadget --part firmware:zephyr
  [ "$status" -eq 0 ]
  sa_absent -q 'svelte-kit\|production/' "$d/.gitignore"
}

# --- v7: documents ---------------------------------------------------------------------------

# sa_links_resolve FILE: every relative Markdown link in FILE points at a file that exists.
sa_links_resolve() {
  local f=$1 dir link
  dir=$(dirname "$f")
  while IFS= read -r link; do
    [[ -n $link ]] || continue
    case $link in http*://*) continue ;; esac
    if [[ ! -e "$dir/$link" ]]; then
      echo "$f: broken link $link" >&2
      return 1
    fi
  done < <(grep -oE '\]\([^)#]+\)' "$f" | sed -e 's/^](//' -e 's/)$//')
}

# sa_hinted FILE: every ## heading is followed by a blank line and then an italic hint, a table or content
# the scaffold fills in (not another heading).
sa_hinted() {
  awk -v f="$1" '
    want == 1 { if ($0 ~ /^#/ || $0 == "") { print f ": no hint under " h; bad = 1 } want = 0 }
    want == 2 { if ($0 != "") { print f ": no blank line after " h; bad = 1 } want = 1; next }
    /^## / { h = $0; want = 2; next }
    END { if (want) { print f ": nothing under " h; bad = 1 } exit bad }
  ' "$1"
}

@test "scaffold writes the doc set for every kind: project docs, README and CHANGELOG per part, the kind's docs" {
  sa_scaffold_all
  [ "$status" -eq 0 ]
  d="$BATS_TEST_TMPDIR/demo"
  for f in docs/README.md docs/architecture.md docs/operations.md; do
    [ -f "$d/$f" ]
  done
  # per kind (name kind dir)
  while read -r p k dir docs; do
    [ -f "$d/$dir/README.md" ]
    [ -f "$d/$dir/CHANGELOG.md" ]
    for s in '## Purpose' '## Build and run' '## Configuration' '## Interfaces' '## Docs'; do
      grep -Fxq "$s" "$d/$dir/README.md"
    done
    sa_links_resolve "$d/$dir/README.md"
    # Keep a Changelog 1.1.0, tag scheme <part>-v<version>
    grep -Fxq "# Changelog: $p" "$d/$dir/CHANGELOG.md"
    grep -Fq 'https://keepachangelog.com/en/1.1.0/' "$d/$dir/CHANGELOG.md"
    grep -Fq "\`$p-v<version>\`" "$d/$dir/CHANGELOG.md"
    grep -Fq '`## [<version>] - YYYY-MM-DD`' "$d/$dir/CHANGELOG.md"
    [ "$(grep -E '^##' "$d/$dir/CHANGELOG.md" | tr '\n' '|')" = '## [Unreleased]|### Added|### Changed|### Fixed|' ]
    if [[ $docs == - ]]; then
      [ ! -e "$d/docs/$p" ]
    else
      [ "$(cd "$d/docs/$p" && /bin/ls | tr '\n' ' ')" = "$docs " ]
      for f in "$d/docs/$p"/*.md; do
        sa_hinted "$f"
        sa_absent -q '@@' "$f"
      done
    fi
  done <<'PARTS'
firmware zephyr firmware flashing.md protocol.md
esp espidf esp flashing.md protocol.md
sensor pio sensor flashing.md protocol.md
interface arm-gcc interface flashing.md protocol.md
badge circuitpython badge flashing.md protocol.md
radio silabs radio flashing.md power.md protocol.md
hardware hardware hardware bringup.md manufacturing.md
board altium board bringup.md library.md manufacturing.md
case mechanical case assembly.md
cloud-api cloud-worker cloud/api api.md data.md
cloud-web web-pages cloud/web -
app app-flutter app distribution.md
desktop app-tauri desktop distribution.md
ios app-xcode ios distribution.md
android app-android android distribution.md
worker-image docker worker-image usage.md
gateway go gateway usage.md
tools python tools usage.md
PARTS
  # a nested part folder links back to the root docs
  grep -Fq '](../../docs/cloud-api/api.md)' "$d/cloud/api/README.md"
  # the index links every doc, and every link resolves
  sa_links_resolve "$d/docs/README.md"
  # project docs (README, architecture, operations, references) + README and changelog per part + the kinds' docs
  [ "$(grep -c '](.*\.md)' "$d/docs/README.md")" -eq $((4 + 18 + 28)) ]
  # the architecture diagram has a node per part, and the table a row per part
  grep -Fxq '```mermaid' "$d/docs/architecture.md"
  grep -Fxq '  cloud_api["cloud-api<br/>cloud-worker"]' "$d/docs/architecture.md"
  [ "$(grep -c '^  [a-z_]*\["' "$d/docs/architecture.md")" -eq 18 ]
  grep -Fq '| cloud-web | web-pages | Cloudflare Pages | `cloud/web/` |' "$d/docs/architecture.md"
  # operations names the deployable parts only
  grep -Fq 'cloud-api cloud-web worker-image._' "$d/docs/operations.md"
  for f in docs/README.md docs/architecture.md docs/operations.md; do sa_absent -q '@@' "$d/$f"; done
  sa_hinted "$d/docs/operations.md"
  # CLAUDE.md asks to keep them current
  grep -Fq '## [Unreleased]' "$d/CLAUDE.md"
  grep -Fq 'Never commit a binary document' "$d/CLAUDE.md"
}

@test "scaffold: an app-tauri + pio + hardware project (command-deck) gets exactly its doc tree, no operations.md" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/deck"
  run "$skill/scripts/scaffold.sh" "$d" --project command-deck --part app:app-tauri --part firmware:pio --part hardware:hardware
  [ "$status" -eq 0 ]
  got=$(cd "$d" && find docs app firmware hardware -type f | sort | tr '\n' ' ')
  [ "$got" = "app/CHANGELOG.md app/README.md docs/README.md docs/app/distribution.md docs/architecture.md docs/firmware/flashing.md docs/firmware/protocol.md docs/hardware/bringup.md docs/hardware/manufacturing.md docs/references.md firmware/CHANGELOG.md firmware/README.md hardware/CHANGELOG.md hardware/README.md " ]
  sa_absent -q 'operations' "$d/docs/README.md"
  # PLAN.md: each part's component claims its docs/<part>/, the root one the project docs
  grep -Fxq 'files: [firmware/**, docs/firmware/**]' "$d/PLAN.md"
  grep -Fxq 'files: [app/**, docs/app/**]' "$d/PLAN.md"
  grep -Fq 'docs/*.md, docs/images/**' "$d/PLAN.md"
  sa_absent -Fq 'docs/**]' "$d/PLAN.md"
}

@test "scaffold writes docs/operations.md only with a deployable part (cloud-worker, web-pages, docker)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/nodeploy"
  run "$skill/scripts/scaffold.sh" "$d" --project gadget --part fw:zephyr --part board:hardware --part app:app-flutter \
    --part cli:go --part lib:python
  [ "$status" -eq 0 ]
  [ ! -e "$d/docs/operations.md" ]
  for k in cloud-worker web-pages docker; do
    d="$BATS_TEST_TMPDIR/deploy-$k"
    run "$skill/scripts/scaffold.sh" "$d" --project gadget --part fw:zephyr --part svc:$k
    [ "$status" -eq 0 ]
    [ -f "$d/docs/operations.md" ]
    grep -Fq '_The runbook for the deployed parts: svc._' "$d/docs/operations.md"
    grep -Fq '[Operations](operations.md)' "$d/docs/README.md"
  done
  d="$BATS_TEST_TMPDIR/prodonly"
  run "$skill/scripts/scaffold.sh" "$d" --project gadget --part api:cloud-worker --production-only api
  [ "$status" -eq 0 ]
  grep -Fq '| api | (none: production-only) |' "$d/docs/operations.md"
  grep -Fq 'make api-deploy ENV=production CONFIRM=production' "$d/cloud/README.md"
}

@test "scaffold never overwrites a doc that exists, leaves a project's own docs/decisions/ alone, and is idempotent" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/keep"
  mkdir -p "$d/fw" "$d/docs/fw" "$d/docs/decisions"
  echo "# our protocol" >"$d/docs/fw/protocol.md"
  echo "# our changelog" >"$d/fw/CHANGELOG.md"
  echo "# our index" >"$d/docs/README.md"
  echo "# our architecture" >"$d/docs/architecture.md"
  echo "# 0001. Use Zephyr" >"$d/docs/decisions/0001-use-zephyr.md"
  echo "# 0002. Use nRF" >"$d/docs/decisions/0002-use-nrf.md"
  run "$skill/scripts/scaffold.sh" "$d" --force --project keep --part fw:zephyr:fw --part web:web-pages:web
  [ "$status" -eq 0 ]
  [ "$(cat "$d/docs/fw/protocol.md")" = "# our protocol" ]
  [ "$(cat "$d/fw/CHANGELOG.md")" = "# our changelog" ]
  [ "$(cat "$d/docs/README.md")" = "# our index" ]
  [ "$(cat "$d/docs/architecture.md")" = "# our architecture" ]
  [[ $output == *"kept existing docs/fw/protocol.md"* ]]
  [[ $output == *"kept existing fw/CHANGELOG.md"* ]]
  # what was missing is added
  [ -f "$d/docs/fw/flashing.md" ]
  [ -f "$d/fw/README.md" ]
  [ -f "$d/docs/operations.md" ]
  # the project's own decision records are kept, and nothing is added next to them
  [ "$(cd "$d/docs/decisions" && /bin/ls | tr '\n' ' ')" = "0001-use-zephyr.md 0002-use-nrf.md " ]
  # a second run changes nothing
  before=$(cd "$d" && find docs fw web -type f -print0 | xargs -0 shasum | sort)
  run "$skill/scripts/scaffold.sh" "$d" --force --project keep --part fw:zephyr:fw --part web:web-pages:web
  [ "$status" -eq 0 ]
  after=$(cd "$d" && find docs fw web -type f -print0 | xargs -0 shasum | sort)
  [ "$before" = "$after" ]
}

@test "scaffold: a fresh project has no docs/decisions/, and nothing it writes mentions decision records" {
  sa_scaffold_all
  [ "$status" -eq 0 ]
  d="$BATS_TEST_TMPDIR/demo"
  [ ! -e "$d/docs/decisions" ]
  sa_absent -rqi 'decision' "$d/docs" "$d/CLAUDE.md" "$d/PLAN.md" "$d/README.md"
}

@test "scaffold: binary documents are ignored and not in LFS, in the project and the hardware board template" {
  sa_scaffold_all
  [ "$status" -eq 0 ]
  d="$BATS_TEST_TMPDIR/demo"
  git -C "$d" init -q -b main
  mkdir -p "$d/docs/manuals"
  for e in pdf doc docx xls xlsx ppt pptx odt ods odp; do
    : >"$d/docs/manuals/manual.$e"
    git -C "$d" check-ignore -q "docs/manuals/manual.$e"
  done
  run git -C "$d" check-ignore -q docs/README.md
  [ "$status" -eq 1 ]
  for f in "$SA_REAL_SKILL/templates/project/.gitattributes" "$SA_REAL_SKILL/templates/hardware/gitattributes"; do
    sa_absent -Eq '^\*\.(pdf|xlsx|docx)[[:space:]]' "$f"
  done
}

@test "scaffold: a release job per part on its own tag, production steps by hand on it, release/ ignored, README says how" {
  sa_scaffold_all
  [ "$status" -eq 0 ]
  d="$BATS_TEST_TMPDIR/demo"
  rel="$d/.github/workflows/release.yml"
  for spec in "${SA_ALL_PARTS[@]}"; do
    [ "$spec" != --part ] || continue
    p=${spec%%:*}
    rest=${spec#*:}
    k=${rest%%:*}
    dir=${rest#*:}
    [ "$dir" != "$k" ] || dir=$p
    grep -Fxq "$dir/release/" "$d/.gitignore" || { echo "$dir/release/ not ignored"; return 1; }
    grep -Fq "make $p-bump LEVEL=patch" "$d/$dir/README.md" || { echo "$dir/README.md has no release section"; return 1; }
    if [[ $k == altium ]]; then
      # no release job: the Release is made where the OutJob's outputs are, and the README says how
      sa_absent -Fxq "  $p-release:" "$rel" || { echo "$p: altium has a release job"; return 1; }
      grep -Fq "make $p-github-release FORCE=1" "$d/$dir/README.md" || { echo "$p: README does not say how to release"; return 1; }
      continue
    fi
    grep -Fxq "  $p-release:" "$rel" || { echo "$p: no release job"; return 1; }
    grep -Fxq "    if: needs.tag.outputs.part == '$p'" "$rel" || { echo "$p: release job not on its tag"; return 1; }
    grep -Fxq "    needs: tag" "$rel" || { echo "$p: release job does not need the tag job"; return 1; }
    grep -Fxq "$dir/release/" "$d/.gitignore" || { echo "$dir/release/ not ignored"; return 1; }
    grep -Fq "make $p-bump LEVEL=patch" "$d/$dir/README.md" || { echo "$dir/README.md has no release section"; return 1; }
  done
  # the production steps run from workflow_dispatch only, with the part named and confirm
  grep -Fq "    tags: ['*-v*']" "$rel"
  grep -Fxq "  workflow_dispatch:" "$rel"
  grep -Fxq "    if: github.event_name == 'workflow_dispatch' && inputs.part == 'app' && inputs.confirm == 'production'" "$rel"
  grep -Fxq "    if: github.event_name == 'workflow_dispatch' && inputs.part == 'desktop' && inputs.confirm == 'production'" "$rel"
  # a board has no production step; docker's release pushes the image itself in its tag job
  sa_absent -Fxq '  board-production:' "$rel"
  sa_absent -Fxq '  worker-image-production:' "$rel"
  if command -v yq >/dev/null 2>&1; then
    [ "$(yq '.jobs.firmware-release.uses' "$rel")" = 'mayankgautam-me/ci-templates/.github/workflows/zephyr.yml@v1.10' ]
    [ "$(yq '.jobs.tools-release.permissions.contents' "$rel")" = write ]
  fi
}

@test "scaffold distribution.md: the release command is written literally, and the release job is the one the workflow runs" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/dist"
  run "$skill/scripts/scaffold.sh" "$d" --project dist --part app:app-tauri
  [ "$status" -eq 0 ]
  grep -Fq 'make app-github-release FORCE=1' "$d/docs/app/distribution.md"
  grep -Fq 'make app-github-release`' "$d/docs/app/distribution.md"
  grep -Fq 'tag `app-v<version>`' "$d/docs/app/distribution.md"
  grep -Fq '## Release files (GitHub Release)' "$d/docs/app/distribution.md"
  grep -Fq 'workflow artifacts (kept 7 days)' "$d/docs/app/distribution.md"
  grep -Fxq '  app-release:' "$d/.github/workflows/release.yml"
}

@test "scaffold: nothing in the scaffolded tree names GitLab, glab or the GitLab job token" {
  sa_scaffold_all
  [ "$status" -eq 0 ]
  d="$BATS_TEST_TMPDIR/demo"
  hits=$(grep -ril -E 'gitlab|glab|CI_JOB_TOKEN' "$d" || true)
  if [ -n "$hits" ]; then
    echo "GitLab text left in: $hits"
    return 1
  fi
  hits=$(grep -ril 'package registry' "$d" || true)
  if [ -n "$hits" ]; then
    echo "package registry text left in: $hits"
    return 1
  fi
}

@test "scaffold --force on an existing .gitignore appends the standard's missing CI and release lines once, and keeps the rest" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/keep"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part fw:pio:fw --part hw:hardware:hw
  [ "$status" -eq 0 ]
  printf 'node_modules/\n# mine\n' >"$d/.gitignore"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part fw:pio:fw --part hw:hardware:hw --force
  [ "$status" -eq 0 ]
  [[ $output == *"added the standard's missing CI and release lines"* ]]
  [ "$(sed -n 1p "$d/.gitignore")" = "node_modules/" ]
  for l in .ci/ .act/ .secrets fw/release/ hw/release/ hw/production/; do grep -Fxq -- "$l" "$d/.gitignore"; done
  before=$(cat "$d/.gitignore")
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part fw:pio:fw --part hw:hardware:hw --force
  [ "$status" -eq 0 ]
  [[ $output == *"kept existing .gitignore"* ]]
  [ "$(cat "$d/.gitignore")" = "$before" ]
}

@test "scaffold: release.yml ends its release jobs with a latest job that needs the tag and every part's release job (v20)" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/latestjob"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part firmware:zephyr --part hardware:hardware --part api:cloud-worker:cloud/api
  [ "$status" -eq 0 ]
  rel="$d/.github/workflows/release.yml"
  grep -Fxq '  latest:' "$rel"
  grep -Fxq '    needs: [tag, firmware-release, hardware-release, api-release]' "$rel"
  grep -Fxq "    if: always() && (needs.firmware-release.result == 'success' || needs.hardware-release.result == 'success' || needs.api-release.result == 'success')" "$rel"
  grep -Fxq '      group: release-latest' "$rel"
  grep -Fxq '      cancel-in-progress: false' "$rel"
  grep -Fq 'run: make "$PART-release-latest" VERSION="${REF_NAME##*-v}"' "$rel"
  grep -Fq 'PART: ${{ needs.tag.outputs.part }}' "$rel"
  grep -Fq 'GH_TOKEN: ${{ github.token }}' "$rel"
  # one latest job, after the part jobs and before the production jobs
  [ "$(grep -c '^  latest:$' "$rel")" -eq 1 ]
  l=$(grep -n '^  latest:$' "$rel" | cut -d: -f1)
  [ "$(grep -n '^  api-release:$' "$rel" | cut -d: -f1)" -lt "$l" ]
  [ "$(grep -n '^  firmware-production:$' "$rel" | cut -d: -f1)" -gt "$l" ]
  # the job's checkout is pinned by SHA and grants contents: write to itself only
  sa_uses_ok "$rel"
  # a single part: the list has the one
  d2="$BATS_TEST_TMPDIR/latestone"
  run "$skill/scripts/scaffold.sh" "$d2" --project demo --part firmware:zephyr
  [ "$status" -eq 0 ]
  grep -Fxq '    needs: [tag, firmware-release]' "$d2/.github/workflows/release.yml"
  grep -Fxq "    if: always() && (needs.firmware-release.result == 'success')" "$d2/.github/workflows/release.yml"
}

@test "scaffold: the release.yml with a latest job passes actionlint when it is installed" {
  command -v actionlint >/dev/null 2>&1 || skip "actionlint is not installed"
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/latestlint"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part firmware:zephyr --part hardware:hardware
  [ "$status" -eq 0 ]
  run actionlint "$d/.github/workflows/release.yml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "scaffold: a single part of each group goes in the group folder (firmware/ hardware/ mechanical/ cloud/ web/ app/)" {
  skill=$(sa_skill_copy)
  for spec in zephyr:firmware espidf:firmware pio:firmware arm-gcc:firmware circuitpython:firmware silabs:firmware \
    hardware:hardware altium:hardware mechanical:mechanical cloud-worker:cloud docker:cloud go:cloud python:cloud web-pages:web \
    app-flutter:app app-tauri:app app-xcode:app app-android:app; do
    k=${spec%%:*}
    g=${spec#*:}
    d="$BATS_TEST_TMPDIR/one-$k"
    run "$skill/scripts/scaffold.sh" "$d" --project demo --part thing:$k
    [ "$status" -eq 0 ] || { echo "$k: $output"; return 1; }
    [ -f "$d/$g/README.md" ] || { echo "$k: no $g/README.md"; return 1; }
    [ ! -e "$d/thing" ] || { echo "$k: part folder thing/ made"; return 1; }
    grep -Fq "files: [$g/**" "$d/PLAN.md" || { echo "$k: PLAN.md does not claim $g/**"; return 1; }
  done
}

@test "scaffold: several firmware parts each get firmware/<name>, and the other groups keep their own folder" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/two"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part nrf9151:zephyr --part stm32f042:pio \
    --part board:hardware --part api:cloud-worker
  [ "$status" -eq 0 ]
  [ -f "$d/firmware/nrf9151/README.md" ]
  [ -f "$d/firmware/stm32f042/README.md" ]
  [ ! -e "$d/firmware/README.md" ]
  [ -f "$d/hardware/README.md" ]
  [ -f "$d/cloud/README.md" ]
  grep -Fxq 'files: [firmware/nrf9151/**, docs/nrf9151/**]' "$d/PLAN.md"
  grep -Fq 'nrf9151:zephyr:firmware/nrf9151' "$d/make/project.mk"
  grep -Fq 'stm32f042:pio:firmware/stm32f042' "$d/make/project.mk"
  grep -Fxq 'firmware/nrf9151/release/' "$d/.gitignore"
  run make -C "$d" help
  [ "$status" -eq 0 ]
}

@test "scaffold: an explicit dir next to a defaulted part of its group makes the defaulted one <group>/<name>" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/mixed"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part api:cloud-worker:cloud/api --part tools:python
  [ "$status" -eq 0 ]
  [ -f "$d/cloud/api/README.md" ]
  [ -f "$d/cloud/tools/README.md" ]
  [ ! -e "$d/cloud/README.md" ]
  # an explicit dir elsewhere still counts as a part of the group: the defaulted one is not alone
  d="$BATS_TEST_TMPDIR/mixed2"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part api:cloud-worker:services/api --part tools:python
  [ "$status" -eq 0 ]
  [ -f "$d/services/api/README.md" ]
  [ -f "$d/cloud/tools/README.md" ]
  [ ! -e "$d/cloud/README.md" ]
}

@test "scaffold: two parts ending on the same dir are refused, defaulted or explicit, and nothing is written" {
  skill=$(sa_skill_copy)
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/dup1" --project demo --part a:go:cloud/x --part x:python
  [ "$status" -ne 0 ]
  [[ $output == *"share the dir 'cloud/x'"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/dup1" ]
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/dup2" --project demo --part a:go:svc --part b:python:svc
  [ "$status" -ne 0 ]
  [[ $output == *"share the dir 'svc'"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/dup2" ]
  # a lone part defaulted to the group folder meets an explicit part on that folder
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/dup3" --project demo --part a:hardware --part b:docker:hardware
  [ "$status" -ne 0 ]
  [[ $output == *"share the dir 'hardware'"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/dup3" ]
}

@test "scaffold: an explicit dir is kept as given, even outside the group folder, and a bad default dir is still validated" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/outside"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part fw:zephyr:src/fw --part site:web-pages:docs-site
  [ "$status" -eq 0 ]
  [ -f "$d/src/fw/README.md" ]
  [ -f "$d/docs-site/README.md" ]
  [ ! -e "$d/firmware" ] && [ ! -e "$d/web" ]
  grep -Fq 'fw:zephyr:src/fw' "$d/make/project.mk"
  # the final dirs are validated: <group>/<name> from an uppercase-free name is fine, a reserved explicit dir is not
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/bad" --project demo --part fw:zephyr:tests/fw
  [ "$status" -ne 0 ]
  [[ $output == *"reserved"* ]]
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/bad2" --project demo --part fw:zephyr:Firmware
  [ "$status" -ne 0 ]
  [[ $output == *"lowercase"* ]]
}

@test "scaffold: a Worker and a site starter allow pnpm to run wrangler's install scripts (pnpm 10 and 11+ keys) (v24)" {
  local skill; skill=$(sa_skill_copy)
  run "$skill/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/pn" --project demo --part api:cloud-worker --part site:web-pages
  [ "$status" -eq 0 ]
  for d in cloud web; do
    f="$BATS_TEST_TMPDIR/pn/$d/pnpm-workspace.yaml"
    [ -f "$f" ]
    for p in esbuild sharp workerd; do
      grep -Fxq "  - $p" "$f"
      grep -Fxq "  $p: true" "$f"
    done
    grep -q '^onlyBuiltDependencies:$' "$f"
    grep -q '^allowBuilds:$' "$f"
  done
}

@test "scaffold v34: a web-pages part is a static-assets Worker on its --domain; --pages keeps Pages; adopt writes the file" {
  d="$BATS_TEST_TMPDIR/v34"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$d" --project demo --part web:web-pages --part blog:web-pages \
    --domain web=app.example.com --pages blog --production-only blog >/dev/null
  w="$d/web/web/wrangler.jsonc"
  grep -Fq '"workers_dev": false' "$w"
  grep -Fq '"preview_urls": false' "$w"
  grep -Fq '"name": "demo-production-web"' "$w"
  grep -Fq '"name": "demo-staging-web"' "$w"
  grep -Fq '"pattern": "app.example.com", "custom_domain": true' "$w"
  grep -Fq '"pattern": "app-staging.example.com", "custom_domain": true' "$w"
  sa_absent -Fq pages_build_output_dir "$w"
  grep -Fxq 'web_URL_production := https://app.example.com' "$d/make/project.mk"
  grep -Fxq 'web_URL_staging := https://app-staging.example.com' "$d/make/project.mk"
  grep -Fq '"pages_build_output_dir": "./public"' "$d/web/blog/wrangler.jsonc"
  sa_absent -Fq 'blog_URL_' "$d/make/project.mk"
  # an apex domain gets staging.<domain>; production-only has no staging block
  a="$BATS_TEST_TMPDIR/v34apex"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$a" --project demo --part web:web-pages --domain web=example.com >/dev/null
  grep -Fq '"pattern": "staging.example.com"' "$a/web/wrangler.jsonc"
  # adopt: an existing Vite site with no wrangler file gets one serving dist/
  o="$BATS_TEST_TMPDIR/v34adopt"
  mkdir -p "$o/web"
  printf 'export default {}\n' >"$o/web/vite.config.ts"
  "$(sa_skill_copy)/scripts/scaffold.sh" "$o" --project demo --part web:web-pages --production-only web --domain web=x.example.com --force >/dev/null
  grep -Fq '"directory": "./dist"' "$o/web/wrangler.jsonc"
  sa_absent -Fq '"staging"' "$o/web/wrangler.jsonc"
  # bad names are refused
  run "$(sa_skill_copy)/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/v34bad" --project demo --part api:cloud-worker --domain api=x.example.com
  [[ $status -ne 0 && $output == *"no web-pages part named 'api'"* ]] || false
  run "$(sa_skill_copy)/scripts/scaffold.sh" "$BATS_TEST_TMPDIR/v34bad2" --project demo --part web:web-pages --domain web
  [[ $status -ne 0 ]] || false
}

@test "scaffold: project.mk explains the owner's secrets repo and carries the override only as a comment" {
  local skill d
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/demo"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part api:go
  [ "$status" -eq 0 ]
  grep -Fq '# The secrets repo follows the project'"'"'s GitHub owner, the owner of its git remote origin' "$d/make/project.mk"
  grep -Fq '#   SECRETS_DIR    ?= $(HOME)/.secrets-<name>' "$d/make/project.mk"
  grep -Fq '#   SECRETS_REMOTE ?= https://github.com/<owner>/<repo>.git' "$d/make/project.mk"
  sa_absent -Eq '^[[:space:]]*(SECRETS_DIR|SECRETS_REMOTE|GITHUB_OWNER)[[:space:]]*[:?]?=' "$d/make/project.mk"
}

@test "scaffold 1.1: hardware + silabs + mechanical: folders, docs, Brewfile, ignore and LFS lines, schema row, CI jobs" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/trio"
  run "$skill/scripts/scaffold.sh" "$d" --project trio --part hardware:hardware --part firmware:silabs --part mechanical:mechanical
  echo "$output"
  [ "$status" -eq 0 ]
  # each in its group folder, with its docs (silabs: protocol, flashing, power; mechanical: assembly)
  got=$(cd "$d" && find docs firmware hardware mechanical -type f | sort | tr '\n' ' ')
  [ "$got" = "docs/README.md docs/architecture.md docs/firmware/flashing.md docs/firmware/power.md docs/firmware/protocol.md docs/hardware/bringup.md docs/hardware/manufacturing.md docs/mechanical/assembly.md docs/references.md firmware/CHANGELOG.md firmware/README.md hardware/CHANGELOG.md hardware/README.md mechanical/CHANGELOG.md mechanical/README.md " ]
  for f in docs/firmware/power.md docs/mechanical/assembly.md; do sa_hinted "$d/$f"; done
  grep -Fq 'make firmware-power' "$d/docs/firmware/power.md"
  grep -Fq '[Power](../docs/firmware/power.md)' "$d/firmware/README.md"
  grep -Fq '[Assembly](../docs/mechanical/assembly.md)' "$d/mechanical/README.md"
  sa_links_resolve "$d/docs/README.md"
  grep -Fq '| mechanical | mechanical |' "$d/docs/architecture.md"
  # project.mk: the silabs settings as comments
  grep -Fxq '# firmware_BOARD := brd4338a' "$d/make/project.mk"
  grep -Fxq '# the slc board (radio board), see firmware/README.md' "$d/make/project.mk"
  grep -Fq '# hardware_LIBRARY := local' "$d/make/project.mk"
  # Brewfile, .gitignore, .gitattributes
  grep -Fxq 'cask "segger-jlink"' "$d/Brewfile"
  grep -Fxq 'cask "freecad"' "$d/Brewfile"
  grep -Fxq 'build/' "$d/.gitignore"
  grep -Fxq '*.FCBak' "$d/.gitignore"
  [ "$(grep -c '^outputs/$' "$d/.gitignore")" -eq 1 ]
  grep -Fxq 'hardware/production/' "$d/.gitignore"
  grep -Fxq 'mechanical/release/' "$d/.gitignore"
  grep -Eq '^\*\.FCStd +filter=lfs diff=lfs merge=lfs -text' "$d/.gitattributes"
  grep -Eq '^\*\.fcstd +filter=lfs' "$d/.gitattributes"
  [ "$(grep -c '^\*\.FCStd ' "$d/.gitattributes")" -eq 1 ]
  # secrets.schema: the optional silabs signing key
  grep -Eq '^silabs-m4 +keys +firmware +ecdsa-p256 +optional: ' "$d/secrets.schema"
  # CI: a check job each; release jobs for all three; silabs gets an OTA production step only with an OTA bucket
  ci="$d/.github/workflows/checks.yml"
  rel="$d/.github/workflows/release.yml"
  for p in hardware firmware mechanical; do
    grep -Fxq "  $p:" "$ci"
    grep -Fxq "  $p-release:" "$rel"
  done
  grep -Fq 'workflows/silabs.yml@v1.10' "$ci"
  grep -Fq 'workflows/mechanical.yml@v1.10' "$rel"
  grep -Fxq '    needs: [tag, hardware-release, firmware-release, mechanical-release]' "$rel"
  sa_absent -Fxq '  firmware-production:' "$rel"
  sa_absent -Fxq '  mechanical-production:' "$rel"
  sa_absent -Fq 'library:' "$ci" "$rel"
  sa_uses_ok "$ci"
  sa_uses_ok "$rel"
  # PLAN.md: a component each, mechanical/ claimed
  grep -Fxq 'files: [mechanical/**, docs/mechanical/**]' "$d/PLAN.md"
  grep -Fxq 'kind: mechanical' "$d/PLAN.md"
  if command -v actionlint >/dev/null 2>&1; then
    run actionlint "$ci" "$rel"
    echo "$output"
    [ "$status" -eq 0 ]
  fi
}

@test "scaffold 1.1: an altium board: Altium's ignore and LFS lines, outputs/ and production/ ignored, a check job and no release job" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/alt"
  run "$skill/scripts/scaffold.sh" "$d" --project alt --part hardware:altium
  echo "$output"
  [ "$status" -eq 0 ]
  got=$(cd "$d" && find docs hardware -type f | sort | tr '\n' ' ')
  [ "$got" = "docs/README.md docs/architecture.md docs/hardware/bringup.md docs/hardware/library.md docs/hardware/manufacturing.md docs/references.md hardware/CHANGELOG.md hardware/README.md " ]
  grep -Fq 'Layer Stack Manager' "$d/docs/hardware/manufacturing.md"
  # the shared Altium library (1.4): its submodule documented, not added (no network); .venv ignored
  grep -Fq 'git submodule update --init -- hardware/altium-library' "$d/hardware/README.md"
  grep -Fq 'git submodule update --init -- hardware/altium-library' "$d/docs/hardware/library.md"
  grep -Fq 'make hardware-lib-check' "$d/docs/hardware/library.md"
  grep -Fq '[Library](../docs/hardware/library.md)' "$d/hardware/README.md"
  [ ! -e "$d/.gitmodules" ]
  grep -Fxq '.venv/' "$d/.gitignore"
  sa_absent -Fq 'kicad_pcb' "$d/docs/hardware/manufacturing.md"
  grep -Fq 'make hardware-layout' "$d/hardware/README.md"
  grep -Fq 'make hardware-github-release FORCE=1' "$d/hardware/README.md"
  # Altium's own files ignored, the part's outputs/ and production/ too (outputs/ is not a global line)
  for l in 'History/' '__Previews/' '*.PcbDocPreview' 'hardware/outputs/' 'hardware/production/' 'hardware/release/'; do
    grep -Fxq -- "$l" "$d/.gitignore"
  done
  sa_absent -Fxq 'outputs/' "$d/.gitignore"
  # Altium's binary documents in LFS (the variants file too, 1.2), its project and OutJob byte-exact; no KiCad *.wrl
  for e in SchDoc PcbDoc SchLib PcbLib IntLib Harness PrjPcbVariants; do
    grep -Eq "^\*\.$e filter=lfs diff=lfs merge=lfs -text lockable$" "$d/.gitattributes"
  done
  grep -Fxq '*.PrjPcb -text' "$d/.gitattributes"
  grep -Fxq '*.OutJob -text' "$d/.gitattributes"
  sa_absent -Eq '^\*\.wrl[[:space:]]' "$d/.gitattributes"
  # no KiCad or other Brewfile lines for it, no KiCad library key in CI (the Altium library's, 1.4)
  sa_absent -Fq 'kicad' "$d/Brewfile"
  ci="$d/.github/workflows/checks.yml"
  rel="$d/.github/workflows/release.yml"
  grep -Fq 'workflows/altium.yml@v1.10' "$ci"
  sa_absent -Fq 'KICAD_LIBRARY_DEPLOY_KEY' "$ci"
  grep -Fq 'ALTIUM_LIBRARY_DEPLOY_KEY: ${{ secrets.ALTIUM_LIBRARY_DEPLOY_KEY }}' "$ci"
  sa_absent -Fq 'altium.yml' "$rel"
  sa_absent -Fxq '  latest:' "$rel"
  grep -Fxq '  tag:' "$rel"
  grep -Fxq 'kind: altium' "$d/PLAN.md"
  grep -Fq 'make hardware-layout' "$d/PLAN.md"
  if command -v actionlint >/dev/null 2>&1; then
    run actionlint "$ci" "$rel"
    echo "$output"
    [ "$status" -eq 0 ]
  fi
  # --force on an existing .gitignore and .gitattributes adds Altium's missing lines once, and keeps the rest
  printf '# mine\n*.SchDoc filter=lfs diff=lfs merge=lfs -text\n' >"$d/.gitattributes"
  printf '# mine\nHistory/\n' >"$d/.gitignore"
  run "$skill/scripts/scaffold.sh" "$d" --project alt --part hardware:altium --force
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"added the .gitattributes lines of the project's kinds"* ]] || false
  [ "$(sed -n 1p "$d/.gitattributes")" = '# mine' ]
  [ "$(grep -c '^\*\.SchDoc ' "$d/.gitattributes")" -eq 1 ]
  grep -Eq '^\*\.PcbDoc filter=lfs' "$d/.gitattributes"
  grep -Eq '^\*\.PrjPcbVariants filter=lfs' "$d/.gitattributes"
  grep -Fxq '*.PrjPcb -text' "$d/.gitattributes"
  grep -Fxq '*.OutJob -text' "$d/.gitattributes"
  [ "$(grep -c '^History/$' "$d/.gitignore")" -eq 1 ]
  for l in '__Previews/' 'hardware/outputs/' 'hardware/production/'; do grep -Fxq -- "$l" "$d/.gitignore"; done
  sa_absent -Fxq 'references/' "$d/.gitignore"
  before_a=$(cat "$d/.gitattributes")
  before_i=$(cat "$d/.gitignore")
  run "$skill/scripts/scaffold.sh" "$d" --project alt --part hardware:altium --force
  [ "$status" -eq 0 ]
  [ "$(cat "$d/.gitattributes")" = "$before_a" ]
  [ "$(cat "$d/.gitignore")" = "$before_i" ]
}

@test "scaffold 1.1: an altium part next to a KiCad one shares hardware/; --force adds *.FCStd to a kept .gitattributes" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/two-boards"
  run "$skill/scripts/scaffold.sh" "$d" --project two --part main:hardware --part daughter:altium
  [ "$status" -eq 0 ]
  [ -f "$d/hardware/main/README.md" ]
  [ -f "$d/hardware/daughter/README.md" ]
  grep -Fxq 'hardware/main/production/' "$d/.gitignore"
  grep -Fxq 'hardware/daughter/production/' "$d/.gitignore"
  grep -Fxq 'hardware/daughter/outputs/' "$d/.gitignore"
  d="$BATS_TEST_TMPDIR/oldattrs"
  mkdir -p "$d"
  printf '*.fcstd filter=lfs diff=lfs merge=lfs -text\n' >"$d/.gitattributes"
  run "$skill/scripts/scaffold.sh" "$d" --project old --part case:mechanical --force
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$d/.gitattributes")" = '*.fcstd filter=lfs diff=lfs merge=lfs -text' ]
  grep -Fxq '*.FCStd filter=lfs diff=lfs merge=lfs -text' "$d/.gitattributes"
}

@test "scaffold 1.9: a Flutter part with <part>_FLUTTER_VERSION in project.mk gets flutter_version on its CI jobs" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/flver"
  mkdir -p "$d/make"
  printf 'PROJECT := flver\nPARTS := app:app-flutter:app desk:app-flutter:desk\napp_FLUTTER_VERSION := 3.50.0 # pinned\n' >"$d/make/project.mk"
  run "$skill/scripts/scaffold.sh" "$d" --project flver --part app:app-flutter:app --part desk:app-flutter:desk --force
  echo "$output"
  [ "$status" -eq 0 ]
  ci="$d/.github/workflows/checks.yml"
  rel="$d/.github/workflows/release.yml"
  [ "$(sed -n '/^  app:/,/^  [a-z]/p' "$ci" | grep -c "^      flutter_version: '3.50.0'\$")" -eq 1 ]
  [ "$(sed -n '/^  app-release:/,/^  [a-z]/p' "$rel" | grep -c "^      flutter_version: '3.50.0'\$")" -eq 1 ]
  # a part without the setting: no input, the workflow falls back to .fvmrc or the latest stable
  [ "$(grep -c 'flutter_version:' "$ci")" -eq 1 ]
}

@test "scaffold 1.10: a Flutter part with <part>_STORE gets store and confirm: production on its tag job only" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/flstore"
  mkdir -p "$d/make"
  printf 'PROJECT := flstore\nPARTS := app:app-flutter:app desk:app-flutter:desk\n# the stores a tag uploads to\napp_STORE := android  ios # both\n' >"$d/make/project.mk"
  run "$skill/scripts/scaffold.sh" "$d" --project flstore --part app:app-flutter:app --part desk:app-flutter:desk --force
  echo "$output"
  [ "$status" -eq 0 ]
  ci="$d/.github/workflows/checks.yml"
  rel="$d/.github/workflows/release.yml"
  job=$(sed -n '/^  app-release:/,/^  [a-z]/p' "$rel")
  [ "$(grep -c "^      store: 'android ios'\$" <<<"$job")" -eq 1 ]
  [ "$(grep -c '^      confirm: production$' <<<"$job")" -eq 1 ]
  # the other part, the push jobs and the manual production job get neither
  [ "$(sed -n '/^  desk-release:/,/^  [a-z]/p' "$rel" | grep -c 'store:\|confirm: production')" -eq 0 ]
  ! grep -q 'store:' "$ci"
  [ "$(grep -c 'store:' "$rel")" -eq 1 ]
}

@test "scaffold 1.1: a hardware part with <part>_LIBRARY := local in project.mk gets library: local on its CI jobs" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/locallib"
  mkdir -p "$d/make"
  printf 'PROJECT := locallib\nPARTS := board:hardware fw:zephyr\nboard_LIBRARY := local\n' >"$d/make/project.mk"
  run "$skill/scripts/scaffold.sh" "$d" --project locallib --part board:hardware --part fw:zephyr --force
  echo "$output"
  [ "$status" -eq 0 ]
  ci="$d/.github/workflows/checks.yml"
  rel="$d/.github/workflows/release.yml"
  [ "$(sed -n '/^  board:/,/^  [a-z]/p' "$ci" | grep -c '^      library: local$')" -eq 1 ]
  [ "$(sed -n '/^  board-release:/,/^  [a-z]/p' "$rel" | grep -c '^      library: local$')" -eq 1 ]
  [ "$(grep -c 'library:' "$ci")" -eq 1 ]
  # the commented setting is not a setting
  d2="$BATS_TEST_TMPDIR/sharedlib"
  run "$skill/scripts/scaffold.sh" "$d2" --project sharedlib --part board:hardware
  [ "$status" -eq 0 ]
  grep -Fq '# board_LIBRARY := local' "$d2/make/project.mk"
  sa_absent -Fq 'library:' "$d2/.github/workflows/checks.yml"
}

@test "scaffold 1.2: docs/references.md is links only (headings and a hint, no table, no rows), nothing ignored, never overwritten" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/refs"
  run "$skill/scripts/scaffold.sh" "$d" --project refs --part api:cloud-worker
  [ "$status" -eq 0 ]
  f="$d/docs/references.md"
  [ "$(sed -n 1p "$f")" = '# refs: references' ]
  grep -Fq -- '- [Title (MPN) — Vendor](URL)' "$f"
  grep -Fxq '## Datasheets' "$f"
  grep -Fxq '## Vendors and modules' "$f"
  sa_absent -Eq '^[[:space:]]*\|' "$f"
  sa_absent -Eq '^- \[' "$f"
  sa_absent -Eiq 'sha256|refs-fetch|refs-check|references/' "$f"
  grep -Fxq -- '- [References](references.md): links to the datasheets, manuals and drawings' "$d/docs/README.md"
  sa_absent -Fxq 'references/' "$d/.gitignore"
  sa_absent -Fq 'refs' "$d/make/common.mk"
  [ ! -e "$d/make/bin/refs.sh" ]
  printf '# mine\n' >"$f"
  run "$skill/scripts/scaffold.sh" "$d" --project refs --part api:cloud-worker --force
  [ "$status" -eq 0 ]
  [ "$(cat "$f")" = '# mine' ]
  sa_absent -Fxq 'references/' "$d/.gitignore"
}

@test "scaffold 1.2: *.wrl in .gitattributes only with a KiCad board (hardware), added once, also by --force" {
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/nowrl"
  run "$skill/scripts/scaffold.sh" "$d" --project nowrl --part fw:zephyr --part case:mechanical --part board:altium
  [ "$status" -eq 0 ]
  sa_absent -Eq '^\*\.wrl[[:space:]]' "$d/.gitattributes"
  for e in step stp fcstd FCStd; do grep -Eq "^\*\.$e +filter=lfs" "$d/.gitattributes"; done
  d="$BATS_TEST_TMPDIR/kicad"
  run "$skill/scripts/scaffold.sh" "$d" --project kicad --part board:hardware --part fw:zephyr
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\*\.wrl filter=lfs diff=lfs merge=lfs -text$' "$d/.gitattributes")" -eq 1 ]
  # a kept .gitattributes without it gets it from --force, once
  printf '*.step filter=lfs diff=lfs merge=lfs -text\n' >"$d/.gitattributes"
  run "$skill/scripts/scaffold.sh" "$d" --project kicad --part board:hardware --part fw:zephyr --force
  [ "$status" -eq 0 ]
  [[ $output == *"added the .gitattributes lines of the project's kinds"* ]] || false
  [ "$(sed -n 1p "$d/.gitattributes")" = '*.step filter=lfs diff=lfs merge=lfs -text' ]
  [ "$(grep -c '^\*\.wrl ' "$d/.gitattributes")" -eq 1 ]
  run "$skill/scripts/scaffold.sh" "$d" --project kicad --part board:hardware --part fw:zephyr --force
  [ "$(grep -c '^\*\.wrl ' "$d/.gitattributes")" -eq 1 ]
}

@test "scaffold 1.3: the next steps are git init for a new folder, and no git init with --force into a git repository" {
  local skill d
  skill=$(sa_skill_copy)
  d="$BATS_TEST_TMPDIR/newproj"
  run "$skill/scripts/scaffold.sh" "$d" --project demo --part firmware:silabs
  [ "$status" -eq 0 ]
  [[ "$output" == *"next: git init -b main && make setup && make secrets-init && make doctor"* ]] || false
  # an existing checkout (update, adopt): no git init
  git -C "$d" init -q -b main
  run "$skill/scripts/scaffold.sh" "$d" --force --project demo --part firmware:silabs
  [ "$status" -eq 0 ]
  [[ "$output" == *"next: git diff to review, then make setup && make doctor"* ]] || false
  [[ "$output" != *"git init"* ]] || false
  # a worktree, whose .git is a file, is a git repository too
  d2="$BATS_TEST_TMPDIR/wt"
  mkdir -p "$d2"
  printf 'gitdir: %s/.git/worktrees/wt\n' "$d" >"$d2/.git"
  run "$skill/scripts/scaffold.sh" "$d2" --force --project demo --part firmware:silabs
  [ "$status" -eq 0 ]
  [[ "$output" != *"git init"* ]] || false
}
