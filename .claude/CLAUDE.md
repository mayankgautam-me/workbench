# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This repository is `~/.workbench`: the user's Mac setup (apps, dotfiles, macOS settings) and their Claude Code setup in `claude/`. `claude/CLAUDE.md` is the user's global instructions, linked to `~/.claude/CLAUDE.md` and loaded in every project, so it is not the place for notes about this repo; they live here. The global file's "This setup is a git repo" rules (publish nothing private, commit and push to `main`, README in the same commit, bump and update a mod) apply on top of this.

## Links

`bootstrap.sh home` links each file in `home/` to the same path under `~`; `bootstrap.sh claude` links `CLAUDE.md`, `settings.json`, `skills.txt`, `versions.lock`, `mods`, `hooks`, `skills/project-profile` and `skills/project-standard` from `claude/` into `~/.claude`. Editing `~/.zshrc` or `~/.claude/settings.json` edits this repo. A new dotfile goes into `home/` at its path under `~` and is linked by re-running `bootstrap.sh home`; a new file in `~/.claude` that should be tracked needs an entry in `claude_links` in `bootstrap.sh`. Update the README's "Layout" (and `claude/README.md`'s) with either.

`.githooks/pre-commit` refuses staged lines containing this Mac's `$HOME` path; `bootstrap.sh` sets `core.hooksPath`. Write `~` or `$HOME`.

## Commands

```bash
zsh bootstrap.sh check               # what differs from the repo: apps, links, macOS settings, Claude CLI; exit 1 to fix
zsh bootstrap.sh <step>              # apps | home | macos | claude | all; each is safe to re-run
zsh bootstrap.sh lock                # rewrite claude/versions.lock after a skill or plugin change
bash macos/defaults.sh --check       # only the macOS settings
shellcheck macos/defaults.sh .githooks/pre-commit
```

From `claude/`:

```bash
claude plugin test mods/<mod>        # every *.test.ts(x) in the mod, each in its own process; no single-file option
claude plugin validate mods/<mod>    # what the engine would refuse: manifest, hooks, $.state keys against types/
tsc -p mods/<mod> --noEmit           # type-check; without --noEmit tsc writes .js files next to the sources
claude plugin update <mod>@local-mods   # after bumping plugin.json's version; the app loads the installed copy
bats hooks/tests                     # detect-project.sh tests, including route markers and shellcheck
bats skills/project-standard/tests   # the project-standard skill's tests
zsh docs/screenshots/make/make.sh    # regenerate the README images after a visual change to a mod
```

`tsc` needs `mods/<mod>/.claude-plugin/types/`, which the engine writes once it has loaded the mod; it is not tracked. git-graph also has `node --experimental-strip-types mods/git-graph/scripts/all-buttons.mts` and `.../real-git-actions.mts`.

## Architecture

**bootstrap.sh** (zsh): `apps` installs the `Brewfile` (adopting casks whose app is already in `/Applications`), `home` links dotfiles and runs `mise install`, `macos` runs `macos/defaults.sh`, `claude` links `claude/` into `~/.claude`, installs the Claude CLI with Anthropic's installer and the missing skills and plugins. A file a link replaces is moved to `~/.workbench-backup/<time>/`. When `~/.claude/.workbench-linked` exists and `settings.json` is a plain file, an app replaced the link: `claude` copies it into `claude/settings.json` and relinks.

**macos/defaults.sh** (bash): one table of `domain|key|type|value`; `--check` compares, no argument applies and restarts Dock and Finder. A sandboxed app's domain (TextEdit) cannot be written from Claude's shell; it is reported for the user to run from Terminal.

**Mods** (`claude/mods/`): four Claude Code plugins drawn in the app: `status-band`, `session-tint`, `agent-map`, `git-graph`. They are installed from the `local-mods` marketplace, `mods/.claude-plugin/marketplace.json`, registered as `~/.claude/mods` (the link) by `bootstrap.sh`; it is deliberately absent from `settings.json`. Each mod has the same shape:

- `hooks/core.ts`: pure logic that never touches `$`, the engine interface; most tests target it.
- `hooks/register.tsx`: `export const register: Register = on => { ... }`, the hooks, `ui.render` trees and state updates. agent-map splits drawing into `hooks/draw.ts`.
- `types/index.d.ts`: the mod's `$.state` contract, named in `plugin.json`'s `"types"`.
- `tests/*.test.ts(x)`: import `test`/`expect` from `'claude-code/testing'` and mock the engine with `on(...)` hooks.

Colours are Tokyo Night hex constants (`const C = { ... }`) in each mod; they are not configurable. Use the `plugin-authoring` skill for mod work: its types file is the API reference.

**Project detection** (`claude/hooks/detect-project.sh`): the SessionStart hook wired in `settings.json`. It recognises the project type from files up to three levels deep and prints a "Project profile". It has no route text of its own: it greps `../CLAUDE.md` for lines ending in `<!--route:NAME-->` (override the file with `CLAUDE_ROUTES`). The bats tests check that routes in the script and markers in `CLAUDE.md` match both ways, so changing either means running `bats hooks/tests`.

**Skills**: `claude/skills/project-profile/` re-runs detection; `claude/skills/project-standard/` is the make-based project layout, with its own bats tests. Third-party skills are not tracked: `claude/skills.txt` lists them as `owner/repo@skill`, and `bootstrap.sh claude` installs the missing ones with `npx skills add`.

**Screenshots** (`claude/docs/screenshots/make/`): `make.sh` copies each `<mod>.demo.test.tsx` into the mod as a temporary test, collects the `DEMO <name> <json>` trees it prints, renders them to HTML with `build.mts` and to PNG with `html2png.swift` (WebKit). It needs macOS, `swiftc` and Node 22+.

**PLAN.md**: this repo's components and tasks, in the format the agent-map mod parses (`claude/mods/agent-map/hooks/core.ts`). There is no worktree for agents here: the app loads mods and the user's shell loads dotfiles from this checkout.
