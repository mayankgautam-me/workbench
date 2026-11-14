# workbench

The one repository that sets up my Mac: the apps, the dotfiles, the macOS settings, the
terminal, and my Claude Code setup. On a new or freshly formatted Mac, one clone and one command
bring it back; on this Mac, `bootstrap.sh check` says what has drifted.

It is one person's setup, published as it is used. Take the parts you want; the
[Claude Code part](claude/README.md), with its four mods for the Claude desktop app, is the one
most people will want.

## Set up a Mac

1. Sign in to the App Store, then install Homebrew (it asks for your password):

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

2. Clone the repository to `~/.workbench`:

   ```bash
   git clone https://github.com/mayankgautam-me/workbench.git ~/.workbench
   ```

3. Run every step:

   ```bash
   zsh ~/.workbench/bootstrap.sh all
   ```

4. Log out and in again (key repeat and Dark mode), then check:

   ```bash
   zsh ~/.workbench/bootstrap.sh check
   ```

Every step is safe to re-run. A file a link replaces is moved to `~/.workbench-backup/<time>/`
first, never deleted.

## The steps

| Command | What it does |
| --- | --- |
| `bootstrap.sh apps` | Installs the [Brewfile](Brewfile): formulas, casks and App Store apps. A cask whose app is already in `/Applications` is adopted, not reinstalled. |
| `bootstrap.sh home` | Links every file in `home/` to the same place under `~`, moves a `~/.gitconfig` aside (git reads `~/.config/git/config`), and installs the mise runtimes. |
| `bootstrap.sh macos` | Applies [macos/defaults.sh](macos/defaults.sh) and imports the Tokyo Night Terminal profile. |
| `bootstrap.sh claude` | Links `claude/` into `~/.claude`, installs the Claude Code CLI with Anthropic's installer, then the missing skills and plugins. |
| `bootstrap.sh all` | The four above, in that order. |
| `bootstrap.sh check` | Lists what differs from the repository: missing apps, missing links, macOS settings, the Claude CLI. Exits 1 if anything needs fixing. Notes, which need no fix, cover apps installed outside the Brewfile, `versions.lock` drift and uncommitted changes. |
| `bootstrap.sh lock` | Rewrites `claude/versions.lock` from the installed skills and plugins. |

`bootstrap.sh` also turns on the repository's commit guard (`.githooks/pre-commit`), which
refuses a commit that adds your absolute home path.

## What is in it

**Apps.** The bare minimum: the shell and its tools, git, mise, the tools for the encrypted
secrets repo, and a few apps. Everything a project needs beyond that comes from the project's
own `make setup` ([project standard](claude/skills/project-standard/SKILL.md)). Nothing is
uninstalled; `check` lists what is installed but not in the Brewfile.

**Dotfiles** (`home/`): zsh (`.zshrc`, `.zprofile`), tmux, starship, Neovim, mise's global
runtimes, the ssh config (never keys), and git: one config with a commit email per folder,
through `includeIf` for `~/Projects/Fabrolabs/` and `~/Projects/I2Sage/`.

**macOS** (`macos/`): Dock (auto-hide, no delay, small, no recent apps, bottom-right corner
shows the Desktop), Finder (hidden files and extensions, path and status bars, list view,
folders first, search the current folder), fast key repeat without autocorrect or smart
punctuation, Dark mode, screenshots as PNG into `~/Pictures/Screenshots`, plain-text TextEdit,
and the Tokyo Night profile as Terminal's default, in Maple Mono NF.

**Claude Code** (`claude/`): global instructions, settings, the project-detection hook, the
project-standard skill, the list of third-party skills and four mods.
See [claude/README.md](claude/README.md).

## How the links work

`~/.zshrc` and the other dotfiles, and `~/.claude/CLAUDE.md`, `settings.json`, `mods`, `hooks`
and the two skills, are symlinks into this checkout, so an edit in either place is an edit
to the repository. When an app rewrites `~/.claude/settings.json` it may replace the link with a
plain file; `check` reports that, and `bootstrap.sh claude` copies that file's content into
`claude/settings.json` and links it again, so the change shows up in `git diff` to keep or drop.

## Layout

```
bootstrap.sh       the steps above
Brewfile           formulas, casks, App Store apps
home/              mirrors ~ ; every file is linked into place
macos/             defaults.sh and the Terminal profile
claude/            linked into ~/.claude; its own README
.claude/CLAUDE.md  guide to this repository for Claude, loaded when working in ~/.workbench
.githooks/         the commit guard
PLAN.md            components and tasks, drawn by the project map
docs/              the design of this repository
LICENSE            GNU General Public License, version 3
```

## Licence

Copyright (C) 2026 Mayank Gautam

This program is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License, version 3, as published by the Free Software Foundation. It is
distributed in the hope that it will be useful, but without any warranty; see the
[LICENSE](LICENSE) file for the full text.
