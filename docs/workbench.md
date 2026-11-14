# workbench: design

The one repo that customises this Mac and sets up a new or freshly formatted one. It replaces
this repo (`claude-code-setup`), whose Claude files become one part of it. Agreed 2026-11-14.

## Where and what

- Repo: `github.com/mayankgautam-me/workbench`, public, GPL-3.0. Checked out at `~/.workbench`.
- Fresh start: one initial commit of the new layout. The old history stays only on GitLab
  (`mayankgautam_me/claude-code-setup`) until you delete that project after checking GitHub.

```
~/.workbench/
  bootstrap.sh      all | apps | home | macos | claude | check
  Brewfile
  home/             mirrors ~ ; each file is symlinked into place
    .zshrc  .zprofile  .tmux.conf
    .config/starship.toml  .config/nvim/  .config/mise/config.toml
    .config/git/config  .config/git/fabrolabs  .config/git/i2sage  .config/git/ignore
    .ssh/config     (never keys)
  macos/
    defaults.sh     the settings below
    Tokyo Night.terminal
  claude/           today's tracked ~/.claude files, each symlinked into ~/.claude
    CLAUDE.md  settings.json  mods/  hooks/  README.md  docs/screenshots/
    skills/project-profile/  skills/project-standard/  skills.txt  versions.lock
  PLAN.md  README.md  LICENSE  docs/
```

## Linking

- Our own script, no stow or chezmoi: `bootstrap.sh home` and `claude` symlink every file,
  copying whatever it replaces to `~/.workbench-backup/<date>/` first.
- Everything is linked, `settings.json` included. When Claude Code or an app swaps a link
  for a plain file, `check` reports it and `bootstrap.sh claude` folds the file's changes
  back into the repo copy and relinks it.
- The `local-mods` marketplace stays registered as `~/.claude/mods`, now a link into `claude/mods`, so no plugin is reinstalled.
- A pre-commit hook refuses staged lines containing an absolute home path.

## Apps (Brewfile)

- Formulas: zsh-autosuggestions zsh-syntax-highlighting fzf fzf-tab starship eza bat vivid
  zoxide ripgrep fd jq neovim tmux pam-reattach git gh git-lfs mise sops age age-plugin-se
  shellcheck bats-core mas. Everything else comes from each project's `make setup`.
- Taps: inequitas/tap dropped (performance-monitor not kept); agentasticai/tap removed.
- Casks: claude orbstack font-maple-mono-nf kicad domzilla-caffeine github. (Caffeine is Dominic Rodemer's app, the `domzilla-caffeine` cask; the `caffeine` cask is a different, older app.)
- App Store (mas): Xcode, Telegram, WhatsApp, CleanMyMac, Grammarly for Safari.
- Claude Code CLI: Anthropic's installer, run by `bootstrap.sh claude`, not brew.
- Left out: glab, gitlab-ci-local, rust (rustup is not kept either), Sourcetree, VS Code,
  Chrome, Parallels, Ledger Wallet, NotchNook Pro, and the other formulas and casks of today.
  `bootstrap.sh check` lists installed leaves that are not in the Brewfile; nothing is uninstalled.

## macOS settings (macos/defaults.sh)

- Dock: auto-hide, no delay, icon size 37, no recent apps, bottom-right hot corner shows Desktop.
- Finder: hidden files, all extensions, path bar, status bar, list view, folders first,
  search the current folder, new windows open Home, no .DS_Store on network drives.
- Keyboard: KeyRepeat 2, InitialKeyRepeat 15, no press-and-hold, no autocorrect,
  no smart quotes or dashes.
- Look: Dark mode. Screenshots: PNG, no shadow, into `~/Pictures/Screenshots`.
- TextEdit: plain text by default.

## Terminal and fonts

- `macos/Tokyo Night.terminal` is imported and set as Terminal's Default and Startup profile.
- Maple Mono NF from the `font-maple-mono-nf` cask.

## Git and SSH

- `~/.config/git/config`: name, `me@mayankgautam.me`, git-lfs, gh credential helper,
  `includeIf "gitdir:~/Projects/Fabrolabs/"` and `"gitdir:~/Projects/I2Sage/"` to the tracked
  per-org files with the work emails (Fabrolabs: `mayank.gautam@fabrolabs.com`,
  I2Sage: `mayank.gautam@i2sage.in`). Sourcetree entries, the commit template and absolute
  paths are dropped; `~/.gitconfig` is removed so git reads the XDG file.
- `~/.ssh/config` tracked as it is today, hosts included. No keys.

## Claude settings

- NotchNook's hooks are dropped from `settings.json`.
- The global `CLAUDE.md` sections "Dotfiles" and "This setup is a git repo" are rewritten for
  `~/.workbench`; `.claude/CLAUDE.md` moves to the workbench root.

## Also agreed

- `~/.gitignore_global` becomes `home/.config/git/ignore`.
- Files bootstrap replaces are copied to `~/.workbench-backup/<date>/` first.
- The repo guide moves to `~/.workbench/.claude/CLAUDE.md`.
- Work goes straight to `main`.

## Done when

The repo is on GitHub, `~/.claude`'s files work from it, `bootstrap.sh check` reports a clean
Mac, the README and `CLAUDE.md` match, and the GitLab project is left for you to delete.
