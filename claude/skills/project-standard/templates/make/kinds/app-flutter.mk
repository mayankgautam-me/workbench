# project-standard v1.6 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind app-flutter: a Flutter application (iOS, Android, and desktop or web targets).
#
# make/project.mk declares it as   <name>:app-flutter:<dir>   and may set, per part:
#   <name>_APP_ID           Android application id and iOS bundle id, used by release and logs
#   <name>_ASC_KEY_ID       App Store Connect API key id (ios release)
#   <name>_ASC_ISSUER       App Store Connect issuer id (ios release)
#
# Command line:  TARGET=apk|appbundle|ios|macos|linux|web   (build, dev, release; default apk, release default appbundle)
#                DEVICE=<id>  TRACK=<play track, default internal>  TEST=<name>  FLUTTER_ARGS='...'
#
# Flutter comes from .fvm/flutter_sdk when that exists, else from mise when mise.toml names flutter,
# else from PATH. Signing keys come from the central secrets: the App Store API key (keys/appstore-api-key)
# and the Play service account (keys/play-service-account) are handed over as a mode-600 temp file
# through `secrets.sh with-file`, so their values never appear in a command line or on disk.

# Prefix in front of flutter and dart for the part at $(1): the fvm SDK, mise, or nothing.
app_flutter_prefix = $(if $(wildcard $(1)/.fvm/flutter_sdk/bin/flutter),$(CURDIR)/$(1)/.fvm/flutter_sdk/bin/,$(if $(shell grep -qs flutter $(1)/mise.toml && echo yes),mise exec -- ,))

# GitHub Release assets, one set per PLATFORM (since v8; reference/standard.md 4.12). Each platform is built on its own host:
#   android (a Mac, or Linux with the SDK)      the apk as <name>-<version>-android.apk; the aab and the R8 mapping are
#                                               kept as workflow artifacts, not linked from the Release
#   ios (a Mac)                                 the dSYMs of the archive as <name>-<version>-ios-dSYMs.zip, and the TestFlight
#                                               build number in the Release notes; no ipa in the Release
#   macos (a Mac)                               universal by default: <name>-<version>-macos-universal.zip
#   linux-amd64, linux-arm64 (a Linux runner)   the release bundle as <name>-<version>-<platform>.tar.gz (no deb yet)
#   windows (Git Bash on a Windows runner)      the x64 runner output as <name>-<version>-windows-x64.zip. Flutter builds
#                                               Windows arm64 only on an arm64 Windows host; the SaaS Windows runner is amd64,
#                                               so there is no arm64 Windows file (not built, see distribution.md)
# NOBUILD=1 collects what is already built. Signing: the store signing is the release target's; these files are unsigned
# unless the project's own Gradle or Xcode settings sign them.
app_flutter_release_assets = set -euo pipefail; $(call std_rel_begin,$(1),app-flutter,$(2)) cd "$(CURDIR)/$(2)"; \
  case "$$plat" in \
    android) \
      $(if $(NOBUILD),,$($(1)_FL) build apk --release; $($(1)_FL) build appbundle --release;) \
      need "build/app/outputs/flutter-apk/app-release.apk" "$(1)-$$ver-android.apk"; \
      opt "build/app/outputs/bundle/release/app-release.aab" "$(1)-$$ver.aab"; \
      opt "build/app/outputs/mapping/release/mapping.txt" "$(1)-$$ver-android-mapping.txt" ;; \
    ios) \
      [ "$$(uname -s)" = Darwin ] || { echo "$(1): PLATFORM=ios is built on a Mac" >&2; exit 1; }; \
      $(if $(NOBUILD),,$(call std_secret_prefix,production) $($(1)_FL) build ipa --release --export-options-plist=ios/ExportOptions.plist;) \
      arch=$$(ls -d build/ios/archive/*.xcarchive 2>/dev/null | head -n 1); \
      [ -n "$$arch" ] || { echo "$(1): no archive in build/ios/archive: run make $(1)-build TARGET=ios" >&2; exit 1; }; \
      zipdir "$$arch/dSYMs" "$(1)-$$ver-ios-dSYMs.zip"; \
      bn=$$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$$arch/Info.plist"); \
      printf 'ios: TestFlight build %s (version %s)\n' "$$bn" "$$ver" >"$(CURDIR)/$(2)/release/$$ver.build-note" ;; \
    macos) \
      [ "$$(uname -s)" = Darwin ] || { echo "$(1): PLATFORM=macos is built on a Mac" >&2; exit 1; }; \
      $(if $(NOBUILD),,$($(1)_FL) build macos --release;) \
      app=$$(ls -d build/macos/Build/Products/Release/*.app 2>/dev/null | head -n 1); \
      [ -n "$$app" ] || { echo "$(1): no macOS app in build/macos/Build/Products/Release: run make $(1)-build TARGET=macos" >&2; exit 1; }; \
      ditto -c -k --keepParent "$$app" "$$out/$(1)-$$ver-macos-universal.zip"; printf '  asset %s\n' "$(1)-$$ver-macos-universal.zip" ;; \
    linux-amd64 | linux-arm64) \
      [ "$$(uname -s)" = Linux ] || { echo "$(1): PLATFORM=$$plat is built on a Linux runner (its CI job)" >&2; exit 1; }; \
      $(if $(NOBUILD),,$($(1)_FL) build linux --release;) \
      bd=$$(ls -d build/linux/*/release/bundle 2>/dev/null | head -n 1); \
      [ -n "$$bd" ] || { echo "$(1): no linux bundle under build/linux: run make $(1)-build TARGET=linux" >&2; exit 1; }; \
      tar -C "$$bd" -czf "$$out/$(1)-$$ver-$$plat.tar.gz" . ; printf '  asset %s\n' "$(1)-$$ver-$$plat.tar.gz" ;; \
    windows) \
      case "$$(uname -s)" in MINGW* | MSYS* | CYGWIN*) ;; *) echo "$(1): PLATFORM=windows is built under Git Bash on Windows" >&2; exit 1 ;; esac; \
      $(if $(NOBUILD),,$($(1)_FL) build windows --release;) \
      rd=build/windows/x64/runner/Release; \
      [ -d "$$rd" ] || { echo "$(1): no $$rd: run make $(1)-build TARGET=windows" >&2; exit 1; }; \
      zipdir "$$rd" "$(1)-$$ver-windows-x64.zip" ;; \
    *) echo "$(1): PLATFORM=$$plat is not one of android ios macos linux-amd64 linux-arm64 windows" >&2; exit 1 ;; \
  esac; \
  $(std_rel_end_plat)

# Ready for std_ready: the packages were fetched after the last change to pubspec.yaml and pubspec.lock (the stamp setup
# leaves, or the package_config.json that pub get writes), and the pods are installed where a Podfile and pod exist.
app_flutter_ready = if [ -f "$(2)/ios/Podfile" ] && command -v pod >/dev/null 2>&1; then [ -f "$(2)/ios/Pods/Manifest.lock" ] || exit 1; fi; \
  $(call std_fresh,$(2),.dart_tool/.std-setup .dart_tool/package_config.json,pubspec.yaml pubspec.lock)

define kind_app-flutter
$(1)_FL := $(call app_flutter_prefix,$(2))flutter
$(1)_DT := $(call app_flutter_prefix,$(2))dart
$(1)_SEC := $(CURDIR)/$(STD_BIN)/secrets.sh
.PHONY: $(1)-setup $(1)-doctor $(1)-dev $(1)-check $(1)-test $(1)-format $(1)-build $(1)-release $(1)-logs $(1)-version $(1)-clean $(1)-distclean

$(call std_verb,$(1),setup,setup,Fetch the Flutter packages and the iOS pods when a Podfile and pod exist)
$(1)-setup:
	@set -euo pipefail; cd $(2); \
	$$($(1)_FL) pub get; \
	mkdir -p .dart_tool && touch .dart_tool/.std-setup; \
	if [ -f ios/Podfile ] && command -v pod >/dev/null 2>&1; then cd ios && pod install; fi

# The commands that need the packages fetch them first when .dart_tool is missing or older than pubspec.yaml or
# pubspec.lock, or the pods are missing where a Podfile and pod exist (std_ready in common.mk).
$(call std_ready,$(1),$(2),app_flutter_ready,dev check test build release)
# release-assets builds too, unless NOBUILD=1 (then it only collects what is built)
$(1)-release-assets: $$(if $$(NOBUILD),,$(1)-ready)

$(call std_verb,$(1),doctor,setup,Flutter doctor read only)
$(1)-doctor:
	@$$($(1)_FL) doctor -v

$(call std_verb,$(1),dev,dev,Run the app on DEVICE or the default device with hot reload)
$(1)-dev:
	@cd $(2) && $$($(1)_FL) run $(if $(DEVICE),-d $(DEVICE)) $(FLUTTER_ARGS)

$(call std_verb,$(1),check,test,Format check analyze and tests of the app)
$(1)-check:
	@set -euo pipefail; cd $(2); \
	$$($(1)_DT) format --output=none --set-exit-if-changed .; \
	$$($(1)_FL) analyze; \
	if [ -d test ]; then $$($(1)_FL) test; fi

$(call std_verb,$(1),test,test,Flutter unit and widget tests with TEST=name for one test)
$(1)-test:
	@cd $(2) && if [ -d test ]; then $$($(1)_FL) test $(if $(TEST),--name '$(TEST)'); else echo "$(1): no test directory"; fi

$(call std_verb,$(1),format,test,Rewrite the formatting of the Dart code)
$(1)-format:
	@cd $(2) && $$($(1)_DT) format .

$(call std_verb,$(1),build,app,Build TARGET apk appbundle ios macos linux or web in release mode without signing for ios)
$(1)-build:
	@cd $(2) && $$($(1)_FL) build $(or $(TARGET),apk) --release $(if $(filter ios,$(TARGET)),--no-codesign)

$(call std_verb,$(1),release,release,Build and upload TARGET ios to TestFlight or appbundle to the Play track TRACK)
$(1)-release:
	@set -euo pipefail; $$(call std_confirm,production); cd $(2); \
	case "$(or $(TARGET),appbundle)" in \
	  ios) \
	    test -n "$($(1)_ASC_KEY_ID)" -a -n "$($(1)_ASC_ISSUER)" || { echo "$(1): set $(1)_ASC_KEY_ID and $(1)_ASC_ISSUER in make/project.mk"; exit 1; }; \
	    $$($(1)_FL) build ipa --release --export-options-plist=ios/ExportOptions.plist; \
	    ipa=$$$$(ls build/ios/ipa/*.ipa | head -n 1); \
	    test -f "$$$$ipa" || { echo "$(1): no ipa was built"; exit 1; }; \
	    $$(call std_confirm,production) && $$($(1)_SEC) with-file appstore-api-key -- sh -c 'd=$$$$(mktemp -d); trap "rm -rf \"$$$$d\"" EXIT; cp "$$$$1" "$$$$d/AuthKey_$($(1)_ASC_KEY_ID).p8"; API_PRIVATE_KEYS_DIR="$$$$d" xcrun altool --upload-app -f "$$$$2" --type ios --apiKey "$($(1)_ASC_KEY_ID)" --apiIssuer "$($(1)_ASC_ISSUER)"' sh {} "$$$$ipa" ;; \
	  appbundle) \
	    test -n "$($(1)_APP_ID)" || { echo "$(1): set $(1)_APP_ID in make/project.mk"; exit 1; }; \
	    $$($(1)_FL) build appbundle --release; \
	    aab=build/app/outputs/bundle/release/app-release.aab; \
	    test -f "$$$$aab" || { echo "$(1): no aab was built"; exit 1; }; \
	    $$(call std_confirm,production) && $$($(1)_SEC) with-file play-service-account -- fastlane supply --json_key {} --package_name "$($(1)_APP_ID)" --track $(or $(TRACK),internal) --aab "$$$$aab" ;; \
	  *) echo "$(1): release TARGET must be ios or appbundle"; exit 1 ;; \
	esac

$(call std_verb,$(1),logs,dev,Follow the app log on the Android device or the iOS simulator by TARGET)
$(1)-logs:
	@if [ "$(or $(TARGET),android)" = ios ]; then xcrun simctl spawn booted log stream --level debug --predicate 'process == "Runner"'; else adb logcat -s flutter; fi

$(call std_verb,$(1),version,setup,Print the version and build number from pubspec.yaml)
$(1)-version:
	@sed -n 's/^version: *//p' $(2)/pubspec.yaml

$(call std_release,$(1),app-flutter,$(2),app_flutter_release_assets,)

$(call std_verb,$(1),clean,dev,Remove the Flutter build output)
$(1)-clean:
	@cd $(2) && $$($(1)_FL) clean

$(call std_verb,$(1),distclean,dev,Remove the build output and the Dart tool cache)
$(1)-distclean: $(1)-clean
	@rm -rf "$(2)/.dart_tool" "$(2)/build"
endef
