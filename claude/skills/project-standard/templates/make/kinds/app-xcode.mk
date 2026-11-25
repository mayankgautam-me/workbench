# project-standard v1.11 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind app-xcode: a native Swift or SwiftUI app built with xcodebuild (iOS, iPadOS or macOS).
# Needs a Mac with Xcode, not only the command line tools. Its CI jobs need a macOS runner.
#
# make/project.mk declares it as   <name>:app-xcode:<dir>   and may set, per part:
#   <name>_SCHEME       the shared scheme to build           (default: the part name)
#   <name>_SIM          simulator device name                (default: iPhone 17 Pro)
#   <name>_ASC_KEY_ID   App Store Connect API key id         (release)
#   <name>_ASC_ISSUER   App Store Connect issuer id          (release)
#
# Command line:  TARGET=ios|macos (build, default ios)
#
# The workspace or project is found in <dir>. Export options are read from <dir>/ExportOptions.plist.
# The App Store API key comes from keys/appstore-api-key through `secrets.sh with-file` as a temp file.

# GitHub Release assets, built on a Mac (since v8; reference/standard.md 4.12). The archive is ios unless PLATFORM is given
# on the command line or in the environment (PLATFORM=macos for a macOS app). The debug symbols of the archive go in as <name>-<version>-<platform>-dSYMs.zip;
# for ios the TestFlight build number goes to the Release notes. No ipa in the Release (TestFlight is make <name>-release).
# The archive runs first unless NOBUILD=1.
app_xcode_release_assets = set -euo pipefail; $(call std_rel_begin,$(1),app-xcode,$(2)) plat=$(if $(filter file,$(origin PLATFORM)),ios,$(PLATFORM)); cd "$(CURDIR)/$(2)"; \
  case "$$plat" in \
    ios | macos) \
      [ "$$(uname -s)" = Darwin ] || { echo "$(1): PLATFORM=$$plat is built on a Mac" >&2; exit 1; }; \
      $(if $(NOBUILD),,$(MAKE) -C "$(CURDIR)" --no-print-directory $(1)-archive TARGET=$$plat;) \
      arch="$(CURDIR)/$(2)/build/$(1).xcarchive"; \
      [ -d "$$arch/dSYMs" ] || { echo "$(1): no $$arch/dSYMs: run make $(1)-archive" >&2; exit 1; }; \
      zipdir "$$arch/dSYMs" "$(1)-$$ver-$$plat-dSYMs.zip"; \
      if [ "$$plat" = ios ]; then \
        bn=$$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$$arch/Info.plist"); \
        printf 'ios: TestFlight build %s (version %s)\n' "$$bn" "$$ver" >"$(CURDIR)/$(2)/release/$$ver.build-note"; \
      fi ;; \
    *) echo "$(1): PLATFORM=$$plat is not ios or macos" >&2; exit 1 ;; \
  esac; \
  $(std_rel_end_plat)

define kind_app-xcode
$(1)_SCHEME ?= $(1)
$(1)_SEC := $(CURDIR)/$(STD_BIN)/secrets.sh
$(1)_XREF := $(if $(wildcard $(2)/*.xcworkspace),-workspace $(firstword $(wildcard $(2)/*.xcworkspace)),-project $(firstword $(wildcard $(2)/*.xcodeproj)))
$(1)_DEST := platform=iOS Simulator,name=$(or $($(1)_SIM),iPhone 17 Pro)
$(1)_BUILD_DEST := $(if $(filter macos,$(TARGET)),platform=macOS,generic/platform=iOS)
.PHONY: $(1)-setup $(1)-dev $(1)-check $(1)-test $(1)-build $(1)-archive $(1)-release $(1)-logs $(1)-version $(1)-clean

$(call std_verb,$(1),setup,setup,Resolve the Swift package dependencies)
$(1)-setup:
	@xcodebuild -resolvePackageDependencies $$($(1)_XREF) -scheme $$($(1)_SCHEME)

$(call std_verb,$(1),dev,dev,Build for the simulator then install and launch it)
$(1)-dev:
	@set -euo pipefail; \
	xcrun simctl boot '$(or $($(1)_SIM),iPhone 17 Pro)' 2>/dev/null || true; \
	open -a Simulator; \
	xcodebuild build $$($(1)_XREF) -scheme $$($(1)_SCHEME) -destination '$$($(1)_DEST)' -derivedDataPath $(2)/build/dd; \
	app=$(2)/build/dd/Build/Products/Debug-iphonesimulator/$$($(1)_SCHEME).app; \
	xcrun simctl install booted "$$$$app"; \
	id=$$$$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$$$$app/Info.plist"); \
	xcrun simctl launch booted "$$$$id"

$(call std_verb,$(1),check,test,SwiftLint strict when a config and swiftlint exist then a compile check)
$(1)-check:
	@set -euo pipefail; \
	if [ -f $(2)/.swiftlint.yml ] && command -v swiftlint >/dev/null 2>&1; then swiftlint lint --strict $(2); else echo "$(1): no swiftlint config or swiftlint, skipped"; fi; \
	xcodebuild build $$($(1)_XREF) -scheme $$($(1)_SCHEME) -destination '$$($(1)_DEST)' -derivedDataPath $(2)/build/dd -quiet

$(call std_verb,$(1),test,test,Run the unit and UI tests on the simulator)
$(1)-test:
	@xcodebuild test $$($(1)_XREF) -scheme $$($(1)_SCHEME) -destination '$$($(1)_DEST)' -derivedDataPath $(2)/build/dd -quiet

$(call std_verb,$(1),build,app,Compile in Release for TARGET ios or macos without signing)
$(1)-build:
	@xcodebuild build $$($(1)_XREF) -scheme $$($(1)_SCHEME) -configuration Release -destination '$$($(1)_BUILD_DEST)' -derivedDataPath $(2)/build/dd CODE_SIGNING_ALLOWED=NO -quiet

$(call std_extra,$(1),archive,release,Archive the Release build into build/ for the store)
$(1)-archive:
	@xcodebuild archive $$($(1)_XREF) -scheme $$($(1)_SCHEME) -configuration Release -destination '$$($(1)_BUILD_DEST)' -archivePath $(2)/build/$(1).xcarchive -quiet

# Export the archive, then upload it to TestFlight with the App Store key handed over as a temp file.
$(call std_verb,$(1),release,release,Archive export and upload to TestFlight with the App Store key)
$(1)-release:
	@$$(call std_confirm,production) && $(MAKE) --no-print-directory $(1)-archive
	@set -euo pipefail; $$(call std_confirm,production); \
	test -n "$($(1)_ASC_KEY_ID)" -a -n "$($(1)_ASC_ISSUER)" || { echo "$(1): set $(1)_ASC_KEY_ID and $(1)_ASC_ISSUER in make/project.mk"; exit 1; }; \
	test -f $(2)/ExportOptions.plist || { echo "$(1): $(2)/ExportOptions.plist is missing"; exit 1; }; \
	xcodebuild -exportArchive -archivePath $(2)/build/$(1).xcarchive -exportPath $(2)/build/export -exportOptionsPlist $(2)/ExportOptions.plist -quiet; \
	ipa=$$$$(ls $(2)/build/export/*.ipa | sed -n 1p); \
	test -f "$$$$ipa" || { echo "$(1): no ipa was exported"; exit 1; }; \
	$$(call std_confirm,production) && $$($(1)_SEC) with-file appstore-api-key -- sh -c 'd=$$$$(mktemp -d); trap "rm -rf \"$$$$d\"" EXIT; cp "$$$$1" "$$$$d/AuthKey_$($(1)_ASC_KEY_ID).p8"; API_PRIVATE_KEYS_DIR="$$$$d" xcrun altool --upload-app -f "$$$$2" --type $(if $(filter macos,$(TARGET)),osx,ios) --apiKey "$($(1)_ASC_KEY_ID)" --apiIssuer "$($(1)_ASC_ISSUER)"' sh {} "$$$$ipa"

$(call std_verb,$(1),logs,dev,Stream the log of the app from the booted simulator)
$(1)-logs:
	@xcrun simctl spawn booted log stream --level debug --predicate 'process == "$$($(1)_SCHEME)"'

$(call std_verb,$(1),version,setup,Print the marketing version from the project)
$(1)-version:
	@cd $(2) && xcrun agvtool what-marketing-version -terse1

$(call std_release,$(1),app-xcode,$(2),app_xcode_release_assets,)

$(call std_verb,$(1),clean,dev,Clean the Xcode build and remove build output)
$(1)-clean:
	@xcodebuild clean $$($(1)_XREF) -scheme $$($(1)_SCHEME) -quiet >/dev/null 2>&1 || true; rm -rf "$(2)/build"
endef
