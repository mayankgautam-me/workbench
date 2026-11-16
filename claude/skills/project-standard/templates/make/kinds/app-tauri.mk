# project-standard v1.2 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind app-tauri: a Tauri 2 application (Svelte or another web front end, Rust in src-tauri/).
#
# make/project.mk declares it as   <name>:app-tauri:<dir>   and may set, per part:
#   <name>_APP_ID        Android application id and iOS bundle id (release, logs)
#   <name>_ASC_KEY_ID    App Store Connect API key id (ios release)
#   <name>_ASC_ISSUER    App Store Connect issuer id (ios release)
#   <name>_OTA_URL       public URL prefix of the R2 OTA objects (android release CHANNEL=ota)
#
# Command line:  TARGET=host|ios|android|linux   BUNDLE=apk|aab   CHANNEL=ota|play   TRACK=internal   TEST=name
#
# linux builds run in a container (deb and AppImage), because a Mac cannot make them.
# The OTA channel uploads the apk to R2 under OTA_BUCKET (make/project.mk) as <name>/<version>/app.apk
# and rewrites <name>/latest.json. Both go through `secrets.sh exec --env production`, which holds the Cloudflare token.
# The package.json of the app pins wrangler, as for cloud-worker.
#
# Package binaries (tauri, svelte-kit, svelte-check, vitest, wrangler) run through the part's package manager:
# `pnpm exec` when the part has pnpm-lock.yaml, else `npx --no-install` (<name>_EXEC overrides it).
# The linux container build does the same inside the image: with pnpm-lock.yaml it installs pnpm
# (<name>_LINUX_PNPM, default 10) with npm, then `pnpm install --frozen-lockfile` and `pnpm exec tauri build`;
# without, `npm ci` and `npx --no-install tauri build` (<name>_LINUX_SETUP and <name>_LINUX_EXEC override them).
#
# check runs clippy, which must be installed with Rust: mise.toml pins
#   rust = { version = "<version>", components = "clippy,rustfmt" }
# (a plain `rust = "<version>"` installs the minimal profile, without clippy). `make <name>-doctor` checks it.

# GitHub Release assets, one set per PLATFORM (since v8; reference/standard.md 4.12). Each platform is built on its own
# host, and every job adds its files to the same Release. NOBUILD=1 collects what is already built.
#   macos (a Mac)                universal-apple-darwin: <name>-<version>-macos-universal.dmg and .app.zip
#   linux-amd64, linux-arm64     a Linux runner: <name>-<version>-linux-<arch>.deb, .rpm and .AppImage
#   windows (Git Bash)           x86_64 and aarch64 MSVC: <name>-<version>-windows-x64|arm64.msi and .exe
#   ios (a Mac)                  the dSYMs of the archive as <name>-<version>-ios-dSYMs.zip; the build number goes to the
#                                Release notes. No ipa in the Release (TestFlight is make <name>-release)
#   android (a Mac)              the release apk as <name>-<version>-android.apk; the aab is kept as a workflow artifact, not linked
# macos and ios are signed with the production secrets when they exist (APPLE_* variables), windows with the key
# keys/windows-codesign when the secrets hold it; without them the build is unsigned and the helper says so.
app_tauri_release_assets = set -euo pipefail; $(call std_rel_begin,$(1),app-tauri,$(2)) cd "$(CURDIR)/$(2)"; \
  rustup_add() { $(STD_TC) rustup-add "$$@" || true; }; \
  case "$$plat" in \
    macos) \
      [ "$$(uname -s)" = Darwin ] || { echo "$(1): PLATFORM=macos is built on a Mac" >&2; exit 1; }; \
      $(if $(call std_has_env,production),,echo "$(1): no production secrets: the macOS build is unsigned and not notarised" >&2;) \
      rustup_add aarch64-apple-darwin x86_64-apple-darwin; \
      $(if $(NOBUILD),,$(call std_apple_prefix) $($(1)_EXEC) tauri build --target universal-apple-darwin --bundles dmg,app || \
        { echo "$(1): tauri build failed; one retry (its DMG step fails now and then on macOS)" >&2; \
          $(call std_apple_prefix) $($(1)_EXEC) tauri build --target universal-apple-darwin --bundles dmg,app; };) \
      b=src-tauri/target/universal-apple-darwin/release/bundle; \
      need_glob "$$b/dmg/*.dmg" "$(1)-$$ver-macos-universal.dmg"; \
      app=$$(ls -d "$$b"/macos/*.app 2>/dev/null | head -n 1); \
      [ -n "$$app" ] || { echo "$(1): no .app in $$b/macos: run make $(1)-build" >&2; exit 1; }; \
      ditto -c -k --keepParent "$$app" "$$out/$(1)-$$ver-macos-universal.app.zip"; printf '  asset %s\n' "$(1)-$$ver-macos-universal.app.zip" ;; \
    linux-amd64 | linux-arm64) \
      [ "$$(uname -s)" = Linux ] || { echo "$(1): PLATFORM=$$plat is built on a Linux runner (its CI job)" >&2; exit 1; }; \
      $(if $(NOBUILD),,APPIMAGE_EXTRACT_AND_RUN=1 $($(1)_EXEC) tauri build --bundles deb,rpm,appimage;) \
      b=src-tauri/target/release/bundle; \
      need_glob "$$b/deb/*.deb" "$(1)-$$ver-$$plat.deb"; \
      need_glob "$$b/rpm/*.rpm" "$(1)-$$ver-$$plat.rpm"; \
      need_glob "$$b/appimage/*.AppImage" "$(1)-$$ver-$$plat.AppImage" ;; \
    windows | windows-x64 | windows-arm64) \
      case "$$(uname -s)" in MINGW* | MSYS* | CYGWIN*) ;; *) echo "$(1): PLATFORM=windows is built under Git Bash on Windows" >&2; exit 1 ;; esac; \
      cfg="$(CURDIR)/$(2)/release/signcfg.json"; mkdir -p "$(CURDIR)/$(2)/release"; ccfg=""; \
      if [ -f "$(SECRETS_DIR)/$(PROJECT)/keys/windows-codesign.sops" ]; then \
        gb="$$(cygpath -m /usr/bin/bash.exe)"; sc="$$(cygpath -m "$(CURDIR)/$(STD_BIN)/sign-windows.sh")"; \
        printf '{"bundle":{"windows":{"signCommand":"\\"%s\\" \\"%s\\" %%1"}}}\n' "$$gb" "$$sc" >"$$cfg"; ccfg="--config $$cfg"; \
      else echo "$(1): no keys/windows-codesign in the secrets: the Windows build is unsigned" >&2; fi; \
      case $$plat in windows-x64) want=x86_64 ;; windows-arm64) want=aarch64 ;; *) want= ;; esac; \
      for t in x86_64-pc-windows-msvc aarch64-pc-windows-msvc; do \
        [ -z "$$want" ] || case $$t in $$want*) ;; *) continue ;; esac; \
        case $$t in aarch64*) a=arm64; bn=nsis ;; *) a=x64; bn=msi,nsis ;; esac; \
        rustup_add $$t; \
        $(if $(NOBUILD),,$($(1)_EXEC) tauri build --target $$t --bundles $$bn $$ccfg;) \
        [ $$a = arm64 ] || need_glob "src-tauri/target/$$t/release/bundle/msi/*.msi" "$(1)-$$ver-windows-$$a.msi"; \
        need_glob "src-tauri/target/$$t/release/bundle/nsis/*.exe" "$(1)-$$ver-windows-$$a.exe"; \
      done ;; \
    ios) \
      [ "$$(uname -s)" = Darwin ] || { echo "$(1): PLATFORM=ios is built on a Mac" >&2; exit 1; }; \
      $(if $(NOBUILD),,$(call std_secret_prefix,production) $($(1)_EXEC) tauri ios build;) \
      arch=$$(find src-tauri/gen/apple -name '*.xcarchive' -maxdepth 4 | head -n 1); \
      [ -n "$$arch" ] || { echo "$(1): no .xcarchive under src-tauri/gen/apple: run make $(1)-build TARGET=ios" >&2; exit 1; }; \
      zipdir "$$arch/dSYMs" "$(1)-$$ver-ios-dSYMs.zip"; \
      bn=$$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$$arch/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$$arch/Info.plist"); \
      printf 'ios: TestFlight build %s (version %s)\n' "$$bn" "$$ver" >"$(CURDIR)/$(2)/release/$$ver.build-note" ;; \
    android) \
      $(if $(NOBUILD),,$(call std_secret_prefix,production) $($(1)_EXEC) tauri android build --apk --aab;) \
      apk=$$(find src-tauri/gen/android -path '*release*' -name '*.apk' | head -n 1); \
      aab=$$(find src-tauri/gen/android -path '*release*' -name '*.aab' | head -n 1); \
      [ -n "$$apk" ] || { echo "$(1): no release apk under src-tauri/gen/android" >&2; exit 1; }; \
      need "$$apk" "$(1)-$$ver-android.apk"; \
      if [ -n "$$aab" ]; then need "$$aab" "$(1)-$$ver.aab"; else echo "  skip  aab (not built)"; fi ;; \
    *) echo "$(1): PLATFORM=$$plat is not one of macos ios android linux-amd64 linux-arm64 windows windows-x64 windows-arm64" >&2; exit 1 ;; \
  esac; \
  $(std_rel_end_plat)

define kind_app-tauri
$(1)_SEC := $(CURDIR)/$(STD_BIN)/secrets.sh
$(1)_EXEC ?= $$(if $$(wildcard $(2)/pnpm-lock.yaml),pnpm exec,npx --no-install)
$(1)_LINUX_IMAGE ?= rust:1.99.1-bookworm
$(1)_LINUX_PNPM ?= 10
$(1)_LINUX_SETUP ?= $$(if $$(wildcard $(2)/pnpm-lock.yaml),npm install -g --no-fund --no-audit pnpm@$$($(1)_LINUX_PNPM) && pnpm install --frozen-lockfile,npm ci)
$(1)_LINUX_EXEC ?= $$(if $$(wildcard $(2)/pnpm-lock.yaml),pnpm exec,npx --no-install)
$(1)_RUST_FIX := in mise.toml pin rust = { version = \"<version>\", components = \"clippy,rustfmt\" }, then mise install
.PHONY: $(1)-doctor $(1)-setup $(1)-dev $(1)-check $(1)-test $(1)-format $(1)-build $(1)-build-release $(1)-release $(1)-logs $(1)-version $(1)-clean $(1)-distclean

$(call std_verb,$(1),doctor,setup,Check cargo with clippy and rustfmt and the part's package manager read only)
$(1)-doctor:
	@bad=0; $(STD_LIB); \
	if command -v cargo >/dev/null 2>&1; then log_ok "$(1): cargo"; else log_err "$(1): cargo not found: $$($(1)_RUST_FIX)"; bad=1; fi; \
	for c in clippy fmt; do \
	  if cargo $$$$c --version >/dev/null 2>&1; then log_ok "$(1): cargo $$$$c"; \
	  else log_err "$(1): cargo $$$$c is missing: $$($(1)_RUST_FIX)"; bad=1; fi; \
	done; \
	if [ -f $(2)/pnpm-lock.yaml ]; then pm=pnpm; else pm=npm; fi; \
	if command -v $$$$pm >/dev/null 2>&1; then log_ok "$(1): $$$$pm"; else log_err "$(1): $$$$pm not found: pin it in mise.toml, then mise install"; bad=1; fi; \
	exit $$$$bad

$(call std_verb,$(1),setup,setup,Install the frontend packages and fetch the Rust crates)
$(1)-setup:
	@set -euo pipefail; cd $(2); \
	$(STD_NODE_SETUP); \
	cargo fetch --manifest-path src-tauri/Cargo.toml

# The commands that run the front end packages install them first when node_modules is missing or older than
# package.json or the lockfile (std_ready in common.mk). cargo fetches missing crates by itself.
$(call std_ready,$(1),$(2),std_node_ready,dev check test build build-release)
# release-assets builds too, unless NOBUILD=1 (then it only collects what is built)
$(1)-release-assets: $$(if $$(NOBUILD),,$(1)-ready)

$(call std_verb,$(1),dev,dev,Run tauri dev for TARGET host ios or android)
$(1)-dev:
	@cd $(2) && $$($(1)_EXEC) tauri $(if $(filter ios,$(TARGET)),ios dev,$(if $(filter android,$(TARGET)),android dev,dev))

$(call std_verb,$(1),check,test,svelte-check when the front end is Svelte after svelte-kit sync for SvelteKit and clippy with warnings as errors)
$(1)-check:
	@set -euo pipefail; cd $(2); \
	if grep -q '"@sveltejs/kit"' package.json 2>/dev/null || grep -qs '@sveltejs/kit' svelte.config.js; then $$($(1)_EXEC) svelte-kit sync; fi; \
	if [ -f svelte.config.js ]; then $$($(1)_EXEC) svelte-check --tsconfig ./tsconfig.json; fi; \
	cargo clippy --version >/dev/null 2>&1 || { echo "$(1): clippy is not installed with Rust: $$($(1)_RUST_FIX)" >&2; exit 1; }; \
	cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings

$(call std_verb,$(1),test,test,Rust tests with cargo and front end tests when vitest is configured with TEST=name for one)
$(1)-test:
	@set -euo pipefail; cd $(2); \
	cargo test --manifest-path src-tauri/Cargo.toml $(TEST); \
	if ls vitest.config.* >/dev/null 2>&1; then $$($(1)_EXEC) vitest run --passWithNoTests; fi

$(call std_verb,$(1),format,test,Rewrite the Rust formatting with cargo fmt)
$(1)-format:
	@cargo fmt --manifest-path $(2)/src-tauri/Cargo.toml

$(call std_verb,$(1),build,app,Build TARGET host ios android or linux with BUNDLE apk or aab for android)
$(1)-build:
	@set -euo pipefail; \
	case "$(or $(TARGET),host)" in \
	  host) cd $(2) && $$($(1)_EXEC) tauri build ;; \
	  ios) cd $(2) && $$($(1)_EXEC) tauri ios build ;; \
	  android) cd $(2) && $$($(1)_EXEC) tauri android build $(if $(filter aab,$(BUNDLE)),--aab,--apk) ;; \
	  linux) mkdir -p $(2)/dist-linux && docker run --rm -v "$(CURDIR)/$(2):/src:ro" -v "$(CURDIR)/$(2)/dist-linux:/out" $$($(1)_LINUX_IMAGE) sh -c 'set -e; apt-get update; apt-get install -y --no-install-recommends libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev patchelf xdg-utils nodejs npm; mkdir /work; cd /src; tar --exclude=node_modules --exclude=target --exclude=dist-linux -cf - . | tar -xf - -C /work; cd /work; $$($(1)_LINUX_SETUP); $$($(1)_LINUX_EXEC) tauri build --bundles deb,appimage; cp -r src-tauri/target/release/bundle/. /out/' ;; \
	  *) echo "$(1): TARGET must be host, ios, android or linux"; exit 1 ;; \
	esac

# Builds the store or OTA artifact and leaves its path in $(2)/dist-release/artifact.path
$(1)-build-release:
	@set -euo pipefail; cd $(2); mkdir -p dist-release; \
	case "$(or $(TARGET),ios)" in \
	  ios) $$($(1)_EXEC) tauri ios build; find src-tauri/gen/apple -name '*.ipa' | head -n 1 > dist-release/artifact.path ;; \
	  android) $$($(1)_EXEC) tauri android build $(if $(filter play,$(CHANNEL)),--aab,--apk); find src-tauri/gen/android -path '*release*' \( -name '*.apk' -o -name '*.aab' \) | head -n 1 > dist-release/artifact.path ;; \
	  *) echo "$(1)-release: TARGET must be ios or android"; exit 1 ;; \
	esac; \
	test -s dist-release/artifact.path || { echo "$(1): no artifact found"; exit 1; }

# ios: TestFlight with the App Store key handed over as a temp file. android: CHANNEL=ota (R2) or play (Play track).
$(call std_verb,$(1),release,release,Release TARGET ios to TestFlight or android to CHANNEL ota on R2 or play on the Play track)
$(1)-release:
	@$$(call std_confirm,production) && $(MAKE) --no-print-directory $(1)-build-release
	@set -euo pipefail; $$(call std_confirm,production); cd $(2); \
	art=$$$$(cat dist-release/artifact.path); \
	case "$(or $(TARGET),ios)" in \
	  ios) \
	    test -n "$($(1)_ASC_KEY_ID)" -a -n "$($(1)_ASC_ISSUER)" || { echo "$(1): set $(1)_ASC_KEY_ID and $(1)_ASC_ISSUER in make/project.mk"; exit 1; }; \
	    $$(call std_confirm,production) && $$($(1)_SEC) with-file appstore-api-key -- sh -c 'd=$$$$(mktemp -d); trap "rm -rf \"$$$$d\"" EXIT; cp "$$$$1" "$$$$d/AuthKey_$($(1)_ASC_KEY_ID).p8"; API_PRIVATE_KEYS_DIR="$$$$d" xcrun altool --upload-app -f "$$$$2" --type ios --apiKey "$($(1)_ASC_KEY_ID)" --apiIssuer "$($(1)_ASC_ISSUER)"' sh {} "$$$$art" ;; \
	  android) \
	    ver=$$$$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' src-tauri/tauri.conf.json | head -n 1); \
	    if [ "$(or $(CHANNEL),ota)" = play ]; then \
	      $$(call std_confirm,production) && $$($(1)_SEC) with-file play-service-account -- fastlane supply --json_key {} --package_name "$($(1)_APP_ID)" --track $(or $(TRACK),internal) --aab "$$$$art"; \
	    else \
	      test -n "$(OTA_BUCKET)" -a -n "$($(1)_OTA_URL)" || { echo "$(1): set OTA_BUCKET and $(1)_OTA_URL in make/project.mk"; exit 1; }; \
	      json=$$$$(mktemp); trap 'rm -f "$$$$json"' EXIT; \
	      printf '{"version":"%s","url":"%s/%s/app.apk"}\n' "$$$$ver" "$($(1)_OTA_URL)" "$$$$ver" > "$$$$json"; \
	      $$(call std_confirm,production) && $$($(1)_SEC) exec --env production -- $$($(1)_EXEC) wrangler r2 object put "$(OTA_BUCKET)/$(1)/$$$$ver/app.apk" --file "$$$$art" --remote; \
	      $$(call std_confirm,production) && $$($(1)_SEC) exec --env production -- $$($(1)_EXEC) wrangler r2 object put "$(OTA_BUCKET)/$(1)/latest.json" --file "$$$$json" --remote --content-type application/json; \
	      echo "$(1): $$$$ver published to the OTA channel"; \
	    fi ;; \
	  *) echo "$(1): release TARGET must be ios or android"; exit 1 ;; \
	esac

$(call std_verb,$(1),logs,dev,Follow the app log on the Android device or the iOS simulator by TARGET)
$(1)-logs:
	@if [ "$(or $(TARGET),host)" = android ]; then adb logcat -s RustStdoutStderr; elif [ "$(or $(TARGET),host)" = ios ]; then xcrun simctl spawn booted log stream --level debug --predicate 'process == "$(notdir $(2))"'; else echo "$(1): host logs stream in the make dev terminal"; fi

$(call std_verb,$(1),version,setup,Print the version in tauri.conf.json)
$(1)-version:
	@sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' $(2)/src-tauri/tauri.conf.json | head -n 1

$(call std_release,$(1),app-tauri,$(2),app_tauri_release_assets,)

$(call std_verb,$(1),clean,dev,Remove the Rust and front end build output)
$(1)-clean:
	@rm -rf "$(2)/dist" "$(2)/dist-release" "$(2)/dist-linux" && cargo clean --manifest-path "$(2)/src-tauri/Cargo.toml" >/dev/null 2>&1 || true

$(call std_verb,$(1),distclean,dev,Remove the build output and the installed packages)
$(1)-distclean: $(1)-clean
	@rm -rf "$(2)/node_modules"
endef
