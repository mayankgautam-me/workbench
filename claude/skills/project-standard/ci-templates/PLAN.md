# ci-templates

Components and tasks of this repository, drawn as the project map. A component is `## Name {#id}` with
`tech:`, `files:` and `kind:` lines; tasks are `- [ ]` (todo), `- [~]` (in progress), `- [x]` (done)
or `- [!]` (blocked).

## Firmware workflows {#firmware}
tech: GitHub Actions reusable workflows; Zephyr, ESP-IDF, PlatformIO, arm-gcc, CircuitPython
files: [.github/workflows/zephyr.yml, .github/workflows/espidf.yml, .github/workflows/pio.yml, .github/workflows/arm-gcc.yml, .github/workflows/circuitpython.yml]
kind: ci
- [x] One workflow per firmware kind: check, build and the tag release through make {#firmware-kinds}

## Hardware workflow {#hardware}
tech: GitHub Actions reusable workflow; KiCad (kicad-cli), the shared KiCad library through a deploy key
files: [.github/workflows/hardware.yml]
kind: ci
- [x] ERC, DRC and fabrication files through make, released on a hardware tag {#hardware-kind}

## Cloud and service workflows {#cloud}
tech: GitHub Actions reusable workflows; Cloudflare Workers, static sites, Docker, Go, Python
files: [.github/workflows/cloud-worker.yml, .github/workflows/web-pages.yml, .github/workflows/docker.yml, .github/workflows/go.yml, .github/workflows/python.yml]
kind: ci
- [x] Check, build, staging deploy on main and production deploy on a part tag {#cloud-kinds}

## App workflows {#apps}
tech: GitHub Actions reusable workflows; Tauri, Flutter, Xcode, Android
files: [.github/workflows/app-tauri.yml, .github/workflows/app-flutter.yml, .github/workflows/app-xcode.yml, .github/workflows/app-android.yml]
kind: ci
- [x] Check and build per platform; macOS jobs only when MACOS_CI is true {#app-kinds}

## Docs {#docs}
tech: Markdown
files: [README.md, CLAUDE.md, PLAN.md]
kind: docs
- [x] README with the calls, CLAUDE.md with where to change things and how to publish {#docs-readme}
