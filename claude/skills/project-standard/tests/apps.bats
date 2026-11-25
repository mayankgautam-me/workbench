#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# The app kinds (app-flutter, app-android, app-xcode, app-tauri), run under make with stubs.
# Nothing touches the network, the App Store, Google Play, Cloudflare, ~/.secrets or a device: flutter,
# dart, xcrun, xcodebuild, fastlane, npx and the Gradle wrapper are stubs that record their argv in $STUB_LOG.
# helpers.bash had not landed when this was written, so each file builds its own project under
# $BATS_TEST_TMPDIR with a stub of the contract macros (std_verb, std_extra). The guards (std_confirm,
# std_production_guard, std_remote_guard) are the real ones, copied from common.mk with lib.sh.
# The signing key is the value TOPSECRETVALUE; the tests check that it never reaches a log or an argv.

KINDS_SRC="$BATS_TEST_DIRNAME/../templates/make/kinds"

write_stub_common() {
  cat > "$1" <<'MK'
SHELL := /bin/bash
ENV ?= local
ifneq ($(filter-out local staging production,$(ENV)),)
$(error ENV must be local, staging or production)
endif
STD_BIN ?= make/bin
std_verb = $(eval STD_VERB_$(2) += $(1)-$(2))$(eval STD_HELP += $(3)|$(1)-$(2)|$(4))
std_extra = $(eval STD_HELP += $(3)|$(1)-$(2)|$(4))
STD_R2_FLAG =
STD_KINDS := $(sort $(foreach p,$(PARTS),$(word 2,$(subst :, ,$(p)))))
include $(foreach k,$(STD_KINDS),make/kinds/$(k).mk)
std_name = $(word 1,$(subst :, ,$(1)))
std_kind = $(word 2,$(subst :, ,$(1)))
std_dir  = $(or $(word 3,$(subst :, ,$(1))),$(word 1,$(subst :, ,$(1))))
$(foreach p,$(PARTS),$(eval $(call kind_$(call std_kind,$(p)),$(call std_name,$(p)),$(call std_dir,$(p)))))
MK
  # the real guards, ahead of the kinds that use them
  # (with their continuation lines: std_android_sdk spans several)
  { awk '/^(STD_BIN|STD_LIB|STD_ANDROID_HOME|std_refuse|std_confirm|std_production_guard|std_remote_guard|std_android_sdk) [:?]?=/ { on = 1 } on { print; if ($0 !~ /\\$/) on = 0 }' "$BATS_TEST_DIRNAME/../templates/make/common.mk"; cat "$1"; } > "$1.new"
  mv "$1.new" "$1"
}

# Records argv and, for the tools that matter, the state the recipe depends on.
write_stub_tools() {
  local t="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$t"
  cat > "$t/flutter" <<'SH'
#!/usr/bin/env bash
echo "flutter $*" >> "$STUB_LOG"
case " $* " in
  *" build ipa "*) mkdir -p build/ios/ipa; : > build/ios/ipa/Runner.ipa ;;
  *" build appbundle "*) mkdir -p build/app/outputs/bundle/release; : > build/app/outputs/bundle/release/app-release.aab ;;
esac
exit 0
SH
  cat > "$t/dart" <<'SH'
#!/usr/bin/env bash
echo "dart $*" >> "$STUB_LOG"
SH
  cat > "$t/xcodebuild" <<'SH'
#!/usr/bin/env bash
echo "xcodebuild $*" >> "$STUB_LOG"
# the export makes the ipa in -exportPath; -authenticationKeyPath must name a readable key file
prev=""; out=""; for a in "$@"; do
  [ "$prev" != -exportPath ] || out=$a
  if [ "$prev" = -authenticationKeyPath ] && [ -f "$a" ]; then echo "xcodebuild key file $(basename "$a") present" >> "$STUB_LOG"; fi
  prev=$a
done
case " $* " in *" -exportArchive "*) mkdir -p "$out"; : > "$out/Runner.ipa" ;; esac
exit 0
SH
  cat > "$t/xcrun" <<'SH'
#!/usr/bin/env bash
echo "xcrun $*" >> "$STUB_LOG"
if [ "${1:-}" = altool ]; then
  echo "altool API_PRIVATE_KEYS_DIR=${API_PRIVATE_KEYS_DIR:-unset}" >> "$STUB_LOG"
  for k in "${API_PRIVATE_KEYS_DIR:-/nonexistent}"/AuthKey_*.p8; do
    [ -f "$k" ] && echo "altool key file $(basename "$k") present" >> "$STUB_LOG"
  done
fi
exit 0
SH
  cat > "$t/fastlane" <<'SH'
#!/usr/bin/env bash
echo "fastlane $*" >> "$STUB_LOG"
exit 0
SH
  cat > "$t/npx" <<'SH'
#!/usr/bin/env bash
echo "npx $*" >> "$STUB_LOG"
echo "env CLOUDFLARE_INCLUDE_PROCESS_ENV=${CLOUDFLARE_INCLUDE_PROCESS_ENV:-unset}" >> "$STUB_LOG"
exit 0
SH
  chmod +x "$t"/*
}

write_stub_bin() {
  cat > "$1/make/bin/secrets.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
case "$cmd" in
  exec)
    env_name=""
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
      case "$1" in --env) env_name="$2"; shift 2 ;; *) shift ;; esac
    done
    shift
    echo "secrets exec --env $env_name" >> "$STUB_LOG"
    exec "$@" ;;
  with-file)
    name="$1"; shift
    [ "$1" = "--" ] && shift
    echo "secrets with-file $name" >> "$STUB_LOG"
    dir="$(mktemp -d)"; chmod 700 "$dir"
    f="$dir/value"; umask 077; printf '%s' "TOPSECRETVALUE" > "$f"
    args=()
    for a in "$@"; do args+=("${a//\{\}/$f}"); done
    rc=0; "${args[@]}" || rc=$?
    rm -rf "$dir"; exit "$rc" ;;
  *) echo "secrets $cmd" >> "$STUB_LOG"; exit 0 ;;
esac
SH
  chmod +x "$1/make/bin/secrets.sh"
}

setup() {
  P="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$P/make/kinds" "$P/make/bin" "$P/app/fl" "$P/app/an" "$P/app/tauri" "$P/app/xc/App.xcodeproj"
  export STUB_LOG="$BATS_TEST_TMPDIR/log"
  : > "$STUB_LOG"
  for k in app-flutter app-android app-tauri app-xcode; do cp "$KINDS_SRC/$k.mk" "$P/make/kinds/"; done
  printf 'include make/project.mk\ninclude make/common.mk\n' > "$P/Makefile"
  cat > "$P/make/project.mk" <<'MK'
PROJECT := demo
PORT_BASE := 8100
PARTS := fl:app-flutter:app/fl an:app-android:app/an tauri:app-tauri:app/tauri xc:app-xcode:app/xc
fl_ASC_KEY_ID := KEYID123
fl_ASC_ISSUER := 11111111-2222-3333
fl_APP_ID := com.example.fl
an_APP_ID := com.example.an
an_OTA_URL := https://dl.example.test/an
MK
  write_stub_common "$P/make/common.mk"
  write_stub_bin "$P"
  cp "$BATS_TEST_DIRNAME/../templates/make/bin/lib.sh" "$P/make/bin/lib.sh"
  cp "$BATS_TEST_DIRNAME/../templates/make/bin/store-ios.sh" "$P/make/bin/store-ios.sh"
  mkdir -p "$P/app/fl/ios/Runner.xcworkspace"
  write_stub_tools
  cat > "$P/app/an/gradlew" <<'SH'
#!/usr/bin/env bash
echo "gradlew $*" >> "$STUB_LOG"
for a in "$@"; do
  case "$a" in
    assembleRelease) mkdir -p app/build/outputs/apk/release; : > app/build/outputs/apk/release/app-release.apk ;;
    bundleRelease) mkdir -p app/build/outputs/bundle/release; : > app/build/outputs/bundle/release/app-release.aab ;;
  esac
done
exit 0
SH
  chmod +x "$P/app/an/gradlew"
  mkdir -p "$P/app/an/app"
  printf 'android {\n  defaultConfig {\n    versionName = "1.4.0"\n  }\n}\n' > "$P/app/an/app/build.gradle.kts"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset CONFIRM OTA_BUCKET CHANNEL TRACK TARGET
}

@test "flutter check runs the format check, analyze and tests" {
  mkdir -p "$P/app/fl/test" "$P/app/fl/lib"
  : > "$P/app/fl/lib/main.dart"
  run make -C "$P" fl-check
  [ "$status" -eq 0 ]
  grep -q '^dart format --output=none --set-exit-if-changed .*lib/main\.dart' "$STUB_LOG"
  grep -q '^flutter analyze' "$STUB_LOG"
  grep -q '^flutter test' "$STUB_LOG"
}

# 1.9: `dart format .` also formatted the generated, gitignored Dart files of a build (build/ios/SourcePackages after an
# iOS build), so the check failed on a clean tree. Only the project's own files are formatted and checked.
@test "flutter check and format leave build/ and .dart_tool/ alone outside git" {
  d="$P/app/fl"
  mkdir -p "$d/lib/src" "$d/test" "$d/build/ios/SourcePackages/x" "$d/.dart_tool/y"
  : > "$d/lib/main.dart"; : > "$d/lib/src/a b.dart"; : > "$d/test/w_test.dart"
  : > "$d/build/ios/SourcePackages/x/gen.dart"; : > "$d/.dart_tool/y/gen.dart"
  run make -C "$P" fl-check
  [ "$status" -eq 0 ]
  line=$(grep '^dart format --output=none' "$STUB_LOG")
  [[ $line == *lib/main.dart* && $line == *"lib/src/a b.dart"* && $line == *test/w_test.dart* ]]
  [[ $line != *build/* && $line != *.dart_tool* ]]
  : > "$STUB_LOG"
  run make -C "$P" fl-format
  [ "$status" -eq 0 ]
  line=$(grep '^dart format' "$STUB_LOG")
  [[ $line == *lib/main.dart* && $line != *build/* && $line != *.dart_tool* && $line != *" ." ]]
}

@test "flutter check in git formats the tracked and new files, not the ignored ones" {
  command -v git >/dev/null 2>&1 || skip "git is not installed"
  d="$P/app/fl"
  mkdir -p "$d/lib" "$d/build/ios/SourcePackages" "$d/ios/.symlinks/plugins/p/lib"
  : > "$d/lib/main.dart"; : > "$d/lib/new.dart"
  : > "$d/build/ios/SourcePackages/gen.dart"; : > "$d/ios/.symlinks/plugins/p/lib/p.dart"
  printf 'build/\n.dart_tool/\nios/.symlinks/\n' > "$d/.gitignore"
  git -C "$P" init -q
  git -C "$P" add app/fl/lib/main.dart app/fl/.gitignore
  run make -C "$P" fl-check
  [ "$status" -eq 0 ]
  line=$(grep '^dart format --output=none' "$STUB_LOG")
  [[ $line == *lib/main.dart* && $line == *lib/new.dart* ]]
  [[ $line != *build/* && $line != *.symlinks* ]]
}

@test "flutter check with no Dart files skips the format check and still analyzes" {
  run make -C "$P" fl-check
  [ "$status" -eq 0 ]
  ! grep -q '^dart format' "$STUB_LOG"
  grep -q '^flutter analyze' "$STUB_LOG"
}

@test "flutter build TARGET=ios compiles without code signing" {
  run make -C "$P" fl-build TARGET=ios
  [ "$status" -eq 0 ]
  grep -q '^flutter build ios --release --no-codesign' "$STUB_LOG"
}

@test "flutter release TARGET=ios hands the App Store key over as a temp file, never as a value" {
  [ "$(uname -s)" = Darwin ] || skip "the iOS store build runs on a Mac"
  run make -C "$P" fl-release TARGET=ios CONFIRM=production fl_STORE_ARGS=--dart-define=API=https://api.example.test
  [ "$status" -eq 0 ]
  grep -q '^secrets with-file appstore-api-key' "$STUB_LOG"
  # 1.10: the defines go into Generated.xcconfig, then xcodebuild archives and exports with automatic signing by the key
  grep -q '^flutter build ios --config-only --release --dart-define=API=https://api.example.test' "$STUB_LOG"
  grep -q '^xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release .* -allowProvisioningUpdates -authenticationKeyPath .*AuthKey_KEYID123.p8 -authenticationKeyID KEYID123 -authenticationKeyIssuerID 11111111-2222-3333 archive' "$STUB_LOG"
  grep -q '^xcodebuild -exportArchive .*-exportOptionsPlist .*ExportOptions.plist -allowProvisioningUpdates' "$STUB_LOG"
  grep -q 'xcodebuild key file AuthKey_KEYID123.p8 present' "$STUB_LOG"
  grep -q "^xcrun altool --upload-app --type ios -f build/ios/ipa/Runner.ipa --apiKey KEYID123" "$STUB_LOG"
  grep -q 'altool key file AuthKey_KEYID123.p8 present' "$STUB_LOG"
  run ! grep -q 'TOPSECRETVALUE' "$STUB_LOG"
  [[ "$output" != *TOPSECRETVALUE* ]]
}

@test "flutter release TARGET=ios refuses without an App Store key id and uploads nothing" {
  run make -C "$P" fl-release TARGET=ios fl_ASC_KEY_ID= CONFIRM=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"set fl_ASC_KEY_ID"* ]]
  run ! grep -q 'altool' "$STUB_LOG"
}

@test "flutter release TARGET=appbundle passes the Play service account as a temp file path" {
  run make -C "$P" fl-release TARGET=appbundle CONFIRM=production
  [ "$status" -eq 0 ]
  grep -q '^secrets with-file play-service-account' "$STUB_LOG"
  grep -q '^fastlane supply --json_key /.* --package_name com.example.fl --track internal --aab .* --skip_upload_metadata' "$STUB_LOG"
  run ! grep -q 'TOPSECRETVALUE' "$STUB_LOG"
  # no upload key in the secrets: Gradle signs on its own, and make says so
  [[ "$output" == *"no keys/android-upload-keystore"* ]]
  run ! grep -q 'android-upload-keystore' "$STUB_LOG"
}

@test "flutter release TARGET=appbundle signs with the upload key and the store args when the secrets hold it (1.10)" {
  export SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
  mkdir -p "$SECRETS_DIR/demo/keys"
  : > "$SECRETS_DIR/demo/keys/android-upload-keystore.sops"
  cat > "$BATS_TEST_TMPDIR/bin/env" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in ANDROID_KEYSTORE_FILE=*) [ -f "${a#*=}" ] && echo "env keystore file present" >> "$STUB_LOG" ;; esac; done
exec /usr/bin/env "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/env"
  run make -C "$P" fl-release TARGET=appbundle CONFIRM=production 'fl_STORE_ARGS=--dart-define=A=1 --dart-define=B=2'
  [ "$status" -eq 0 ]
  grep -q '^secrets exec --env production' "$STUB_LOG"
  grep -q '^secrets with-file android-upload-keystore' "$STUB_LOG"
  grep -q '^env keystore file present' "$STUB_LOG"
  grep -q '^flutter build appbundle --release --dart-define=A=1 --dart-define=B=2' "$STUB_LOG"
  grep -q '^fastlane supply ' "$STUB_LOG"
  run ! grep -q 'TOPSECRETVALUE' "$STUB_LOG"
}

@test "android-sdk installs with the android CLI, in its package names, and falls back to sdkmanager (1.10)" {
  export ANDROID_HOME="$BATS_TEST_TMPDIR/sdk"
  cat > "$BATS_TEST_TMPDIR/bin/android" <<'SH'
#!/usr/bin/env bash
case " $* " in *" --help "*) echo "Installs SDK packages"; exit 0 ;; esac
echo "android $*" >> "$STUB_LOG"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/android"
  run make -C "$P" fl-android-sdk 'fl_ANDROID_PACKAGES=platform-tools platforms;android-36 build-tools;36.0.0'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q "^android --no-metrics --sdk=$ANDROID_HOME sdk install platform-tools platforms/android-36 build-tools/36.0.0" "$STUB_LOG"
  grep -q "^flutter config --android-sdk $ANDROID_HOME" "$STUB_LOG"
  # an android that is not the new CLI (the old SDK tool, or none): sdkmanager with its own names, licences first
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/android"
  cat > "$BATS_TEST_TMPDIR/bin/sdkmanager" <<'SH'
#!/usr/bin/env bash
echo "sdkmanager $*" >> "$STUB_LOG"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/sdkmanager"
  : > "$STUB_LOG"
  run make -C "$P" an-android-sdk 'an_ANDROID_PACKAGES=platform-tools platforms/android-36'
  [ "$status" -eq 0 ]
  [[ "$output" == *"deprecated sdkmanager"* ]]
  grep -q "^sdkmanager --sdk_root=$ANDROID_HOME --licenses" "$STUB_LOG"
  grep -q "^sdkmanager --sdk_root=$ANDROID_HOME platform-tools platforms;android-36" "$STUB_LOG"
}

@test "android check runs the Gradle lint" {
  run make -C "$P" an-check
  [ "$status" -eq 0 ]
  grep -q '^gradlew lint' "$STUB_LOG"
}

@test "android release signs with the keystore from the secrets, then refuses OTA without OTA_BUCKET" {
  run env -u OTA_BUCKET make -C "$P" an-release CHANNEL=ota ENV=production CONFIRM=production
  [ "$status" -ne 0 ]
  [[ "$output" == *"OTA_BUCKET"* ]]
  grep -q '^secrets exec --env production' "$STUB_LOG"
  grep -q '^secrets with-file android-keystore' "$STUB_LOG"
  grep -q '^gradlew assembleRelease' "$STUB_LOG"
  run ! grep -q 'TOPSECRETVALUE' "$STUB_LOG"
}

@test "android release CHANNEL=play builds the bundle and uploads it on the chosen track" {
  run make -C "$P" an-release CHANNEL=play TRACK=beta CONFIRM=production
  [ "$status" -eq 0 ]
  grep -q '^gradlew bundleRelease' "$STUB_LOG"
  grep -q '^fastlane supply --json_key .* --package_name com.example.an --track beta --aab ' "$STUB_LOG"
  run ! grep -q 'TOPSECRETVALUE' "$STUB_LOG"
}

@test "xcode build compiles the scheme for generic iOS without signing" {
  run make -C "$P" xc-build
  [ "$status" -eq 0 ]
  grep -q '^xcodebuild build -project app/xc/App.xcodeproj -scheme xc -configuration Release -destination generic/platform=iOS' "$STUB_LOG"
  grep -q 'CODE_SIGNING_ALLOWED=NO' "$STUB_LOG"
}

@test "tauri build with TARGET=host runs tauri build in the app directory" {
  run make -C "$P" tauri-build TARGET=host
  [ "$status" -eq 0 ]
  grep -q '^npx --no-install tauri build' "$STUB_LOG"
}

@test "tauri build with an unknown TARGET fails" {
  run make -C "$P" tauri-build TARGET=windows
  [ "$status" -ne 0 ]
  [[ "$output" == *"TARGET must be host, ios, android or linux"* ]]
}

# Releases publish to the stores and the OTA bucket with production keys: refused without CONFIRM=production.
# Nothing may run before the refusal: no build, no secrets, no upload.
release_refused() {
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM=production"* ]]
  if [ -s "$STUB_LOG" ]; then
    echo "ran before the refusal:"; cat "$STUB_LOG"
    return 1
  fi
}

@test "every app release is refused without CONFIRM=production, before it builds or decrypts anything" {
  for args in "fl-release TARGET=ios" "fl-release TARGET=appbundle" "an-release CHANNEL=ota" "an-release CHANNEL=play" \
    "tauri-release TARGET=ios" "tauri-release TARGET=android CHANNEL=ota" "tauri-release TARGET=android CHANNEL=play" "xc-release"; do
    : > "$STUB_LOG"
    # shellcheck disable=SC2086
    run make -C "$P" $args OTA_BUCKET=bucket ENV=production
    echo "make $args"
    release_refused
  done
}

@test "an app release is refused with CONFIRM from the environment or with the wrong value" {
  run env CONFIRM=production make -C "$P" an-release CHANNEL=play
  release_refused
  run make -C "$P" fl-release TARGET=appbundle CONFIRM=staging
  release_refused
  run make -C "$P" xc-release CONFIRM="production production"
  release_refused
}

@test "android OTA release with CONFIRM=production uploads the apk and then latest.json with the production env" {
  run make -C "$P" an-release CHANNEL=ota OTA_BUCKET=bucket CONFIRM=production
  [ "$status" -eq 0 ]
  grep -q '^npx --no-install wrangler r2 object put bucket/an/1.4.0/app.apk ' "$STUB_LOG"
  grep -q '^npx --no-install wrangler r2 object put bucket/an/latest.json ' "$STUB_LOG"
  [ "$(grep -c '^secrets exec --env production' "$STUB_LOG")" -eq 3 ]
  run ! grep -q 'TOPSECRETVALUE' "$STUB_LOG"
}

@test "xcode and tauri releases with CONFIRM=production get past the guard to the archive and the build" {
  run make -C "$P" xc-release CONFIRM=production
  grep -q '^xcodebuild archive ' "$STUB_LOG"
  : > "$STUB_LOG"
  run make -C "$P" tauri-release TARGET=ios CONFIRM=production
  grep -q '^npx --no-install tauri ios build' "$STUB_LOG"
}

# The tauri front end's package binaries go through the part's package manager (pnpm exec with pnpm-lock.yaml,
# npx --no-install without), and a SvelteKit front end gets svelte-kit sync before svelte-check.
tauri_stub_pm() {
  local t="$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "pnpm $*" >> "$STUB_LOG"\ncase " $* " in *" svelte-kit sync "*) exit "${STUB_SYNC_RC:-0}" ;; esac\nexit 0\n' > "$t/pnpm"
  printf '#!/usr/bin/env bash\necho "cargo $*" >> "$STUB_LOG"\nexit 0\n' > "$t/cargo"
  chmod +x "$t/pnpm" "$t/cargo"
}

@test "tauri check in a SvelteKit pnpm part runs svelte-kit sync then svelte-check, both with pnpm exec" {
  tauri_stub_pm
  printf '{ "devDependencies": { "@sveltejs/kit": "^2.0.0" } }\n' > "$P/app/tauri/package.json"
  printf 'export default {};\n' > "$P/app/tauri/svelte.config.js"
  : > "$P/app/tauri/pnpm-lock.yaml"
  run make -C "$P" tauri-check
  [ "$status" -eq 0 ]
  sync=$(grep -n '^pnpm exec svelte-kit sync$' "$STUB_LOG" | cut -d: -f1)
  check=$(grep -n '^pnpm exec svelte-check --tsconfig ./tsconfig.json$' "$STUB_LOG" | cut -d: -f1)
  [ -n "$sync" ] && [ -n "$check" ] && [ "$sync" -lt "$check" ]
  grep -q '^cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings' "$STUB_LOG"
  if grep -q '^npx ' "$STUB_LOG"; then return 1; fi
}

@test "tauri check finds SvelteKit from svelte.config.js alone and stops when svelte-kit sync fails" {
  tauri_stub_pm
  printf "import adapter from '@sveltejs/adapter-static';\nimport { vitePreprocess } from '@sveltejs/kit/vite';\nexport default { kit: { adapter: adapter() } };\n" > "$P/app/tauri/svelte.config.js"
  : > "$P/app/tauri/pnpm-lock.yaml"
  export STUB_SYNC_RC=1
  run make -C "$P" tauri-check
  [ "$status" -ne 0 ]
  grep -q '^pnpm exec svelte-kit sync$' "$STUB_LOG"
  if grep -q 'svelte-check\|^cargo clippy' "$STUB_LOG"; then return 1; fi
}

@test "tauri check without pnpm-lock.yaml uses npx --no-install and a plain Svelte front end gets no svelte-kit sync" {
  tauri_stub_pm
  printf '{ "devDependencies": { "svelte": "^5.0.0" } }\n' > "$P/app/tauri/package.json"
  printf 'export default {};\n' > "$P/app/tauri/svelte.config.js"
  run make -C "$P" tauri-check
  [ "$status" -eq 0 ]
  grep -q '^npx --no-install svelte-check --tsconfig ./tsconfig.json' "$STUB_LOG"
  if grep -q 'svelte-kit\|^pnpm ' "$STUB_LOG"; then return 1; fi
}

@test "tauri dev, test and build in a pnpm part run tauri and vitest with pnpm exec, never npx" {
  tauri_stub_pm
  : > "$P/app/tauri/pnpm-lock.yaml"
  : > "$P/app/tauri/vitest.config.ts"
  run make -C "$P" tauri-build TARGET=host
  [ "$status" -eq 0 ]
  run make -C "$P" tauri-dev
  [ "$status" -eq 0 ]
  run make -C "$P" tauri-test
  [ "$status" -eq 0 ]
  grep -q '^pnpm exec tauri build$' "$STUB_LOG"
  grep -q '^pnpm exec tauri dev$' "$STUB_LOG"
  grep -q '^pnpm exec vitest run --passWithNoTests' "$STUB_LOG"
  if grep -q '^npx ' "$STUB_LOG"; then return 1; fi
}

# docker records its argv; the container script is its last argument
tauri_stub_docker() {
  local t="$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do echo "docker-arg $a" >> "$STUB_LOG"; done\nexit 0\n' > "$t/docker"
  chmod +x "$t/docker"
}

@test "tauri linux build in a pnpm part installs pnpm in the container and builds with pnpm exec, and installs xdg-utils" {
  tauri_stub_docker
  : > "$P/app/tauri/pnpm-lock.yaml"
  run make -C "$P" tauri-build TARGET=linux
  [ "$status" -eq 0 ]
  script=$(grep '^docker-arg set -e;' "$STUB_LOG")
  [[ "$script" == *"npm install -g --no-fund --no-audit pnpm@10 && pnpm install --frozen-lockfile;"* ]]
  [[ "$script" == *"pnpm exec tauri build --bundles deb,appimage;"* ]]
  [[ "$script" == *" xdg-utils "* ]]
  [[ "$script" != *"npm ci"* && "$script" != *"npx"* ]]
  run make -C "$P" tauri-build TARGET=linux tauri_LINUX_PNPM=9
  [[ "$(grep '^docker-arg set -e;' "$STUB_LOG" | tail -n 1)" == *"pnpm@9 &&"* ]]
}

@test "tauri linux build without pnpm-lock.yaml keeps npm ci and npx --no-install" {
  tauri_stub_docker
  run make -C "$P" tauri-build TARGET=linux
  [ "$status" -eq 0 ]
  script=$(grep '^docker-arg set -e;' "$STUB_LOG")
  [[ "$script" == *"; npm ci; npx --no-install tauri build --bundles deb,appimage;"* ]]
  [[ "$script" != *"pnpm"* ]]
}

@test "tauri check stops with the mise fix when clippy is not installed with Rust" {
  tauri_stub_pm
  printf '#!/usr/bin/env bash\necho "cargo $*" >> "$STUB_LOG"\n[ "$1" = clippy ] && { echo "error: no such command: clippy" >&2; exit 101; }\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/cargo"
  run make -C "$P" tauri-check
  [ "$status" -ne 0 ]
  [[ "$output" == *'clippy is not installed with Rust'*'components = "clippy,rustfmt"'*'mise install'* ]]
  if grep -q '^cargo clippy --manifest-path' "$STUB_LOG"; then return 1; fi
}

@test "tauri doctor checks cargo, clippy, rustfmt and the part's package manager" {
  tauri_stub_pm
  : > "$P/app/tauri/pnpm-lock.yaml"
  run make -C "$P" tauri-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok tauri: cargo clippy"* && "$output" == *"ok tauri: cargo fmt"* && "$output" == *"ok tauri: pnpm"* ]]
  printf '#!/usr/bin/env bash\n[ "$1" = clippy ] && exit 101\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/cargo"
  run make -C "$P" tauri-doctor
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cargo clippy is missing"*'components = "clippy,rustfmt"'* ]]
}

# --- setup on demand (std_ready, with the real common.mk) ------------------------------------

ready_common() {
  local tpl="$BATS_TEST_DIRNAME/../templates/make"
  cp "$tpl/common.mk" "$P/make/common.mk"
  for f in release.sh toolchain.sh; do cp "$tpl/bin/$f" "$P/make/bin/"; done
  export HOME="$BATS_TEST_TMPDIR/home" STD_CONFIG="$BATS_TEST_TMPDIR/home/.config/project-standard"
  mkdir -p "$HOME"
  printf 'name: fl\n' > "$P/app/fl/pubspec.yaml"
}

@test "a fresh flutter part fetches its packages once before check; android, which gradle sets up itself, is not chained" {
  ready_common
  run make -C "$P" fl-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"> fl: not set up yet, running make fl-setup first"* ]]
  [ "$(grep -c '^flutter pub get' "$STUB_LOG")" -eq 1 ]
  first_get=$(grep -n -m1 '^flutter pub get' "$STUB_LOG" | cut -d: -f1)
  first_analyze=$(grep -n -m1 '^flutter analyze' "$STUB_LOG" | cut -d: -f1)
  [ "$first_get" -lt "$first_analyze" ]
  : > "$STUB_LOG"
  run make -C "$P" fl-build
  [ "$status" -eq 0 ]
  [[ "$output" != *"not set up yet"* ]]
  [ "$(grep -c '^flutter pub get' "$STUB_LOG")" -eq 0 ]
  # pubspec.yaml changed since: fetch again
  touch -t 200001010000 "$P/app/fl/.dart_tool/.std-setup"
  : > "$STUB_LOG"
  run make -C "$P" fl-test
  [ "$(grep -c '^flutter pub get' "$STUB_LOG")" -eq 1 ]
  # setup, doctor, clean and version are never chained
  touch -t 200001010000 "$P/app/fl/.dart_tool/.std-setup"
  for t in doctor clean version; do
    : > "$STUB_LOG"
    run make -C "$P" "fl-$t"
    [[ "$output" != *"not set up yet"* ]]
    [ "$(grep -c '^flutter pub get' "$STUB_LOG")" -eq 0 ]
  done
  : > "$STUB_LOG"
  run make -C "$P" an-check
  [ "$status" -eq 0 ]
  [[ "$output" != *"not set up yet"* ]]
  grep -q '^gradlew lint' "$STUB_LOG"
  [ "$(grep -c 'gradlew help' "$STUB_LOG")" -eq 0 ]
}
