# project-standard v1.4 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind app-android: a native Android app built with Gradle (Kotlin or Java, Compose or Views).
#
# make/project.mk declares it as   <name>:app-android:<dir>   and may set, per part:
#   <name>_APP_ID       application id, used by dev and logs       (required for dev)
#   <name>_OTA_URL      public URL prefix of the R2 OTA objects     (release CHANNEL=ota)
#
# Command line:  BUILD_TYPE=Debug|Release (build, default Debug)   CHANNEL=ota|play (release, default ota)
#                TRACK=internal (play)   TEST=name   DEVICE=<adb serial>   PAIR=host:port (pair)
#
# Signing: the release build reads ANDROID_KEYSTORE_FILE, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS
# and ANDROID_KEY_PASSWORD from the environment, which build.gradle.kts must read. The keystore comes from
# keys/android-keystore through `secrets.sh with-file` (a temp file), the passwords from the production env.
#
# OTA: the signed apk goes to R2 under OTA_BUCKET (make/project.mk) as <name>/<versionName>/app.apk and
# <name>/latest.json is rewritten, both with the production Cloudflare token. Play: fastlane supply with
# keys/play-service-account as a temp file. The module's package.json pins wrangler; the OTA upload runs
# from the app directory with `npx --no-install wrangler`.

# GitHub Release assets (since v8; reference/standard.md 4.12). The kind has one platform, android, whatever PLATFORM says
# (its sums are SHA256SUMS-android), built on a Mac or a Linux host with the SDK: the release apk as
# <name>-<version>-android.apk (one apk: ABI splits are refused), the aab and the R8 mapping are kept as workflow artifacts
# (not linked from the Release). Signed with keys/android-keystore when the secrets hold it (the same wrapper as
# the release target), else unsigned and the helper says so. NOBUILD=1 collects what is already built.
app_android_release_assets = set -euo pipefail; $(call std_rel_begin,$(1),app-android,$(2)) plat=android; cd "$(CURDIR)/$(2)"; \
  o="$(CURDIR)/$(2)/app/build/outputs"; \
  $(if $(wildcard $(SECRETS_DIR)/$(PROJECT)/keys/android-keystore.sops),,echo "$(1): no keys/android-keystore in the secrets: the release build is unsigned" >&2;) \
  $(if $(NOBUILD),,$(if $(wildcard $(SECRETS_DIR)/$(PROJECT)/keys/android-keystore.sops),bash $(CURDIR)/$(STD_BIN)/secrets.sh exec --env production -- bash $(CURDIR)/$(STD_BIN)/secrets.sh with-file android-keystore -- sh -c 'ANDROID_KEYSTORE_FILE="$$1" exec ./gradlew assembleRelease bundleRelease' sh {},./gradlew assembleRelease bundleRelease);) \
  apks=$$(ls "$$o"/apk/release/*.apk 2>/dev/null || true); \
  [ "$$(printf '%s\n' "$$apks" | grep -c .)" = 1 ] || { echo "$(1): expected one release apk in $$o/apk/release (ABI splits: set one universal apk)" >&2; exit 1; }; \
  need "$$apks" "$(1)-$$ver-android.apk"; \
  aab=$$(ls "$$o"/bundle/release/*.aab 2>/dev/null | head -n 1 || true); \
  if [ -n "$$aab" ]; then need "$$aab" "$(1)-$$ver.aab"; else echo "  skip  aab (not built)"; fi; \
  opt "$$o/mapping/release/mapping.txt" "$(1)-$$ver-android-mapping.txt"; \
  $(std_rel_end_plat)

define kind_app-android
$(1)_SEC := $(CURDIR)/$(STD_BIN)/secrets.sh
.PHONY: $(1)-setup $(1)-devices $(1)-pair $(1)-dev $(1)-check $(1)-test $(1)-build $(1)-release $(1)-logs $(1)-version $(1)-clean $(1)-distclean

$(call std_verb,$(1),setup,setup,Check the Gradle wrapper and fetch the Gradle dependencies)
$(1)-setup:
	@cd $(2) && ./gradlew --version >/dev/null && ./gradlew help --quiet

$(call std_verb,$(1),dev,dev,Install the debug build on DEVICE or the running emulator and launch it)
$(1)-dev:
	@set -euo pipefail; cd $(2); \
	test -n "$($(1)_APP_ID)" || { echo "$(1): set $(1)_APP_ID in make/project.mk"; exit 1; }; \
	./gradlew installDebug; \
	adb $(if $(DEVICE),-s $(DEVICE)) shell monkey -p "$($(1)_APP_ID)" -c android.intent.category.LAUNCHER 1 >/dev/null

$(call std_verb,$(1),check,test,Gradle lint for the build type)
$(1)-check:
	@cd $(2) && ./gradlew lint

$(call std_verb,$(1),test,test,Local unit tests with TEST=name for one class or method)
$(1)-test:
	@cd $(2) && ./gradlew test$(or $(BUILD_TYPE),Debug)UnitTest $(if $(TEST),--tests '$(TEST)')

$(call std_verb,$(1),build,app,Assemble the APK for BUILD_TYPE Debug or Release unsigned for release)
$(1)-build:
	@cd $(2) && ./gradlew assemble$(or $(BUILD_TYPE),Debug)

# Signed release built with the keystore from the central secrets, then published to CHANNEL.
$(call std_verb,$(1),release,release,Build the signed release and publish it to the OTA channel on R2 or to Play)
$(1)-release:
	@set -euo pipefail; cd $(2); \
	$$(call std_confirm,production) && $$($(1)_SEC) exec --env production -- $$($(1)_SEC) with-file android-keystore -- sh -c 'ANDROID_KEYSTORE_FILE="$$$$1" exec ./gradlew $(if $(filter play,$(CHANNEL)),bundleRelease,assembleRelease)' sh {}; \
	art=$$$$(find app/build/outputs -path '*release*' \( -name '*.apk' -o -name '*.aab' \) | head -n 1); \
	test -n "$$$$art" || { echo "$(1): no release artifact found"; exit 1; }; \
	if [ "$(or $(CHANNEL),ota)" = play ]; then \
	  test -n "$($(1)_APP_ID)" || { echo "$(1): set $(1)_APP_ID in make/project.mk"; exit 1; }; \
	  $$(call std_confirm,production) && $$($(1)_SEC) with-file play-service-account -- fastlane supply --json_key {} --package_name "$($(1)_APP_ID)" --track $(or $(TRACK),internal) --aab "$$$$art"; \
	else \
	  test -n "$(OTA_BUCKET)" -a -n "$($(1)_OTA_URL)" || { echo "$(1): set OTA_BUCKET and $(1)_OTA_URL in make/project.mk"; exit 1; }; \
	  ver=$$$$(sed -n 's/.*versionName *= *"\([^"]*\)".*/\1/p' app/build.gradle.kts | head -n 1); \
	  test -n "$$$$ver" || { echo "$(1): no versionName in app/build.gradle.kts"; exit 1; }; \
	  json=$$$$(mktemp); trap 'rm -f "$$$$json"' EXIT; \
	  printf '{"version":"%s","url":"%s/%s/app.apk"}\n' "$$$$ver" "$($(1)_OTA_URL)" "$$$$ver" > "$$$$json"; \
	  $$(call std_confirm,production) && $$($(1)_SEC) exec --env production -- npx --no-install wrangler r2 object put "$(OTA_BUCKET)/$(1)/$$$$ver/app.apk" --file "$$$$art" --remote; \
	  $$(call std_confirm,production) && $$($(1)_SEC) exec --env production -- npx --no-install wrangler r2 object put "$(OTA_BUCKET)/$(1)/latest.json" --file "$$$$json" --remote --content-type application/json; \
	  echo "$(1): $$$$ver published to the OTA channel"; \
	fi

$(call std_extra,$(1),devices,dev,List the attached Android devices and running emulators)
$(1)-devices:
	@adb devices -l

$(call std_extra,$(1),pair,setup,Pair a phone over wireless debugging with PAIR=host:port then type the code)
$(1)-pair:
	@test -n "$(PAIR)" || { echo "$(1)-pair needs PAIR=host:port from the phone"; exit 1; }
	@adb pair $(PAIR)

$(call std_verb,$(1),logs,dev,Follow the app log on the device by its application id)
$(1)-logs:
	@test -n "$($(1)_APP_ID)" || { echo "$(1): set $(1)_APP_ID in make/project.mk"; exit 1; }
	@adb $(if $(DEVICE),-s $(DEVICE)) logcat --pid="$$$$(adb $(if $(DEVICE),-s $(DEVICE)) shell pidof -s $($(1)_APP_ID))"

$(call std_verb,$(1),version,setup,Print the versionName from app/build.gradle.kts)
$(1)-version:
	@sed -n 's/.*versionName *= *"\([^"]*\)".*/\1/p' $(2)/app/build.gradle.kts | head -n 1

$(call std_release,$(1),app-android,$(2),app_android_release_assets,)

$(call std_verb,$(1),clean,dev,Run Gradle clean and remove the build output)
$(1)-clean:
	@cd $(2) && ./gradlew clean --quiet

$(call std_verb,$(1),distclean,dev,Remove the build output and the Gradle caches of the project)
$(1)-distclean: $(1)-clean
	@rm -rf "$(2)/.gradle" "$(2)/app/build"
endef
