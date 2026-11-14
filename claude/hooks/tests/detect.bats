#!/usr/bin/env bats
# Tests for detect-project.sh: each builds a small project folder and checks the profile printed.
#
#   bats ~/.claude/hooks/tests

setup() {
  HOOK="${BATS_TEST_DIRNAME}/../detect-project.sh"
  P="${BATS_TEST_TMPDIR}/project"
  mkdir -p "$P"
}

# put <path> [content]: a file in the project, its folders made as needed.
put() {
  mkdir -p "$P/$(dirname "$1")"
  printf '%s\n' "${2:-}" > "$P/$1"
}

detect() { run "$HOOK" "$P"; }

@test "an empty folder prints nothing" {
  detect
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a folder that does not exist prints nothing" {
  run "$HOOK" "$P/missing"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the home folder itself is never profiled" {
  HOME="$P" run "$HOOK" "$P"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the folder is read from the hook's JSON on standard input" {
  put pubspec.yaml
  run bash -c "printf '{\"cwd\":\"%s\"}' '$P' | '$HOOK'"
  [[ "$output" == *"Flutter app"* ]]
}

@test "a profile starts with where it was detected" {
  put pubspec.yaml
  detect
  [[ "${lines[0]}" == "Project profile, detected from files in $P." ]]
}

@test "Flutter" {
  put pubspec.yaml
  detect
  [[ "$output" == *"multi-platform-apps:flutter-expert"* ]]
}

@test "React Native or Expo, from package.json" {
  put package.json '{"dependencies":{"expo":"~51.0.0"}}'
  detect
  [[ "$output" == *"React Native / Expo app"* ]]
}

@test "a plain package.json is not React Native" {
  put package.json '{"dependencies":{"react":"18"}}'
  detect
  [[ "$output" != *"React Native"* ]]
}

@test "Swift, from an Xcode project or a package" {
  mkdir -p "$P/App.xcodeproj"
  detect
  [[ "$output" == *"multi-platform-apps:ios-developer"* ]]
}

@test "Android with Compose" {
  put app/build.gradle.kts 'plugins { id("com.android.application") }'
  detect
  [[ "$output" == *"ui-design:mobile-android-design"* ]]
}

@test "Tauri, and its Cargo.toml does not also count as a Rust service" {
  mkdir -p "$P/src-tauri"
  put src-tauri/Cargo.toml '[package]'
  detect
  [[ "$output" == *"tauri-development"* ]]
  [[ "$output" != *"- Rust:"* ]]
}

@test "Svelte" {
  put svelte.config.js
  detect
  [[ "$output" == *"svelte-core-bestpractices"* ]]
}

@test "Next.js" {
  put next.config.mjs
  detect
  [[ "$output" == *"nextjs-app-router-patterns"* ]]
}

@test "Zephyr, and not Cortex-M a second time" {
  put west.yml
  put boards/link.ld
  put CMakeLists.txt 'set(CMAKE_C_COMPILER arm-none-eabi-gcc)'
  detect
  [[ "$output" == *"Zephyr firmware"* ]]
  [[ "$output" != *"ARM Cortex-M firmware"* ]]
}

@test "Cortex-M from a CubeMX file" {
  put board.ioc
  detect
  [[ "$output" == *"ARM Cortex-M firmware"* ]]
}

@test "Cortex-M from a linker script with a build file that names the toolchain" {
  put link.ld
  put Makefile 'CC = arm-none-eabi-gcc -mcpu=cortex-m4 -mthumb'
  detect
  [[ "$output" == *"ARM Cortex-M firmware"* ]]
}

@test "a linker script alone is not Cortex-M" {
  put link.ld
  put Makefile 'CC = riscv32-unknown-elf-gcc'
  detect
  [[ "$output" != *"ARM Cortex-M firmware"* ]]
}

@test "ESP-IDF" {
  put sdkconfig.defaults
  detect
  [[ "$output" == *"ESP32 / ESP-IDF firmware"* ]]
}

@test "Arduino or PlatformIO" {
  put platformio.ini '[env:uno]'
  detect
  [[ "$output" == *"systems-programming:cpp-pro"* ]]
}

@test "embedded Rust from Cargo.toml dependencies" {
  put Cargo.toml 'embassy-executor = "0.5"'
  detect
  [[ "$output" == *"Embedded Rust"* ]]
  [[ "$output" != *"- Rust:"* ]]
}

@test "embedded Rust from no_std in the source" {
  put Cargo.toml '[package]'
  put src/main.rs '#![no_std]'
  detect
  [[ "$output" == *"Embedded Rust"* ]]
}

@test "a Rust service" {
  put Cargo.toml 'tokio = "1"'
  put src/main.rs 'fn main() {}'
  detect
  [[ "$output" == *"- Rust: Rust services: the \`systems-programming:rust-pro\` agent"* ]]
  [[ "$output" != *"Embedded Rust"* ]]
}

@test "KiCad" {
  put board/board.kicad_pcb
  detect
  [[ "$output" == *"KiCad design"* ]]
}

@test "Go" {
  put go.mod 'module example.com/x'
  detect
  [[ "$output" == *"systems-programming:golang-pro"* ]]
}

@test "an LLM pipeline, from Python requirements" {
  put requirements.txt 'anthropic>=0.40'
  detect
  [[ "$output" == *"llm-application-dev:ai-engineer"* ]]
}

@test "ML training" {
  put pyproject.toml 'dependencies = ["torch>=2"]'
  detect
  [[ "$output" == *"machine-learning-ops:ml-pipeline"* ]]
}

@test "a data pipeline" {
  put dbt_project.yml
  detect
  [[ "$output" == *"data-engineering:data-pipeline"* ]]
}

@test "MQTT" {
  put docker-compose.yml 'image: eclipse-mosquitto'
  detect
  [[ "$output" == *"mqtt-development"* ]]
}

@test "a project of several kinds lists each" {
  put pubspec.yaml
  put go.mod
  put hw/board.kicad_sch
  detect
  [ "$(printf '%s\n' "$output" | grep -c '^- ')" -eq 3 ]
}

@test "firmware of any kind also gets the routes common to all firmware" {
  put board.ioc
  detect
  [[ "$output" == *"- Any firmware:"*"embedded-systems"*"openocd-jtag"* ]]
}

@test "a route of several lines in CLAUDE.md is printed as one" {
  put board/board.kicad_pcb
  detect
  [[ "$output" == *"- KiCad design: "*"\`kicad\`"*"\`bom\`"*"Never edit a board"* ]]
  [[ "$output" != *"<!--"* ]]
}

@test "every route the hook names is marked in CLAUDE.md" {
  for name in $(grep -oE '^[[:space:]]*(has|contains|\[|add|firmware).*add "[^"]+" [a-z-]+|add "[^"]+" [a-z-]+' "$HOOK" | grep -oE '[a-z-]+$' | sort -u); do
    grep -qF -- "<!--route:$name-->" "${BATS_TEST_DIRNAME}/../../CLAUDE.md" || { echo "no line marked <!--route:$name-->"; return 1; }
  done
}

@test "every route marked in CLAUDE.md is one the hook can print" {
  for name in $(grep -oE '<!--route:[a-z-]+-->' "${BATS_TEST_DIRNAME}/../../CLAUDE.md" | sed -e 's/<!--route://' -e 's/-->//' | sort -u); do
    grep -qE "add \"[^\"]+\" $name\$" "$HOOK" || { echo "the hook never prints route $name"; return 1; }
  done
}

@test "a route missing from the file says so instead of printing nothing" {
  put pubspec.yaml
  CLAUDE_ROUTES="$P/none.md" run "$HOOK" "$P"
  [[ "$output" == *"- Flutter app: no line of CLAUDE.md is marked <!--route:flutter-->."* ]]
}

@test "files inside node_modules and build folders are not looked at" {
  put node_modules/x/pubspec.yaml
  put build/go.mod
  detect
  [ -z "$output" ]
}

@test "a project made by project-standard is named with its version" {
  put make/common.mk '# project-standard v1 (managed: refresh with the project-standard skill, put project changes in make/local.mk)'
  put Makefile 'include make/common.mk'
  detect
  [[ "$output" == *"- Project standard v1: "*"project-standard"* ]]
  [[ "$output" != *"Not on the project standard"* ]]
}

@test "a git repository or Makefile not on the standard is flagged" {
  put Makefile 'all:'
  detect
  [[ "$output" == *"- Not on the project standard: "* ]]
  rm "$P/Makefile"
  mkdir "$P/.git"
  detect
  [[ "$output" == *"- Not on the project standard: "* ]]
}

@test "a folder with neither git nor a Makefile gets no standard line" {
  put pubspec.yaml
  detect
  [[ "$output" != *"project standard"* ]]
  [[ "$output" != *"Project standard"* ]]
}

@test "the hook is clean under shellcheck" {
  command -v shellcheck >/dev/null || skip "shellcheck is not installed"
  run shellcheck "$HOOK"
  [ "$status" -eq 0 ]
}
