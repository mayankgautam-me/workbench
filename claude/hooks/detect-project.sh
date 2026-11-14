#!/bin/bash
# SessionStart hook: looks at the project's files, works out what kind of
# project it is and prints which agents and skills to use for the session.
# Prints nothing when no known project type is found.
#
# Manual run: ~/.claude/hooks/detect-project.sh [dir]

dir="$1"
if [ -z "$dir" ] && [ ! -t 0 ]; then
  dir=$(jq -r '.cwd // empty' 2>/dev/null)
fi
dir=${dir:-${CLAUDE_PROJECT_DIR:-$PWD}}
[ -d "$dir" ] || exit 0
[ "$dir" = "$HOME" ] && exit 0

files=$(find "$dir" -maxdepth 3 \
  \( -name node_modules -o -name .git -o -name build -o -name target -o -name dist \
     -o -name .venv -o -name venv -o -name Pods -o -name .dart_tool -o -name .pio \) -prune \
  -o -print 2>/dev/null | head -8000)

# has <path regex>: some file or directory matches.
has() { printf '%s\n' "$files" | grep -Eq "$1"; }
# contains <path regex> <content regex>: some matching file contains the text.
contains() {
  printf '%s\n' "$files" | grep -E "$1" | head -200 | tr '\n' '\0' \
    | xargs -0 grep -lEi "$2" 2>/dev/null | grep -q .
}

# The routes themselves are not written here: each is the line, or lines, of
# CLAUDE.md that end in a <!--route:name--> marker, so there is one place to
# change a route. CLAUDE_ROUTES names another file, for the tests.
routes="${CLAUDE_ROUTES:-$(dirname "$0")/../CLAUDE.md}"
# route <name>: the marked lines as one sentence, without bullet or marker.
route() {
  grep -F -- "<!--route:$1-->" "$routes" 2>/dev/null |
    sed -e 's/ *<!--route:[^>]*-->[[:space:]]*$//' -e 's/^[[:space:]]*- //' | paste -sd' ' -
}

out=""
# add <what was detected> <route name>
add() {
  local text
  text=$(route "$2")
  out="${out}- $1: ${text:-no line of CLAUDE.md is marked <!--route:$2-->.}"$'\n'
}

# Apps
has '/pubspec\.yaml$' && add "Flutter app" flutter
contains '/package\.json$' '"(react-native|expo)"' && add "React Native / Expo app" react-native
has '\.xcodeproj$|/Package\.swift$' && add "Swift / SwiftUI app" swift
contains '/build\.gradle(\.kts)?$' 'compose|com\.android' && add "Android (Kotlin / Compose) app" android
has '/src-tauri$' && add "Tauri app" tauri

# Web
has '/svelte\.config\.(js|ts|mjs)$' && add "Svelte / SvelteKit" svelte
has '/next\.config\.(js|ts|mjs)$' && add "Next.js" nextjs

# Firmware
firmware=0
zephyr=0
if has '/west\.yml$|/prj\.conf$'; then
  zephyr=1
  firmware=1
  add "Zephyr firmware" zephyr
fi
# A linker script alone is not enough (ESP-IDF and RISC-V projects have them
# too): it counts only when a build file names a Cortex-M toolchain.
if [ $zephyr = 0 ] && { has '\.ioc$' || contains '/\.cargo/config(\.toml)?$' 'thumbv' ||
    { has '\.ld$' && contains '/(Makefile|CMakeLists\.txt|platformio\.ini|[^/]*\.(mk|cmake))$' 'cortex-m|mthumb|arm-none-eabi'; }; }; then
  firmware=1
  add "ARM Cortex-M firmware" cortex-m
fi
if has '/sdkconfig(\.defaults)?$|/idf_component\.yml$'; then
  firmware=1
  add "ESP32 / ESP-IDF firmware" esp-idf
fi
if has '/platformio\.ini$|\.ino$'; then
  firmware=1
  add "Arduino / PlatformIO firmware" platformio
fi
if contains '/Cargo\.toml$' 'cortex-m|embassy|embedded-hal|esp-hal|riscv-rt|defmt' ||
    contains '/(main|lib)\.rs$' '#!\[no_std\]' || contains '\.rs$' '#!\[no_std\]'; then
  firmware=1
  add "Embedded Rust" embedded-rust
elif has '/Cargo\.toml$' && ! has '/src-tauri$'; then
  add "Rust" rust
fi
[ $firmware = 1 ] && add "Any firmware" firmware

# Hardware
has '\.kicad_(pro|sch|pcb)$' && add "KiCad design" kicad

# Backend, AI and data
has '/go\.mod$' && add "Go service" go
contains '/(pyproject\.toml|requirements[^/]*\.txt|package\.json)$' 'anthropic|langchain|langgraph|llama[-_]index|openai|transformers|sentence-transformers' &&
  add "AI / LLM pipeline" ai
contains '/(pyproject\.toml|requirements[^/]*\.txt)$' '(^|[^a-z])(torch|tensorflow|scikit-learn|xgboost|mlflow)' &&
  add "ML training" ml
has '/dbt_project\.yml$|/dags$' && add "Data pipeline" data
contains '/(docker-compose|compose)\.ya?ml$|/package\.json$|/pyproject\.toml$|/requirements[^/]*\.txt$|/go\.mod$' 'mqtt|mosquitto|emqx' &&
  add "MQTT in use" mqtt

# The project standard: a project made or adopted by the project-standard skill
# carries "project-standard v<N>" in the first lines of make/common.mk.
standard=$(head -n 2 "$dir/make/common.mk" 2>/dev/null | grep -oE 'project-standard v[0-9]+' | head -n 1)
if [ -n "$standard" ]; then
  add "Project standard ${standard#project-standard }" standard
elif [ -e "$dir/.git" ] || [ -f "$dir/Makefile" ]; then
  add "Not on the project standard" standard
fi

[ -z "$out" ] && exit 0

printf 'Project profile, detected from files in %s.\n' "$dir"
printf 'Use these agents and skills by default in this session; anything I name in a request wins.\n'
printf '%s' "$out"
