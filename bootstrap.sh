#!/bin/zsh
# Sets up this Mac, or a new one, from the workbench repo.
#
#   git clone https://github.com/mayankgautam-me/workbench.git ~/.workbench
#   zsh ~/.workbench/bootstrap.sh all
#
#   all      apps, home, macos and claude, in that order
#   apps     Homebrew formulas, casks and App Store apps from the Brewfile
#   home     link home/ into ~, then install the mise runtimes
#   macos    macOS settings and the Terminal profile
#   claude   link claude/ into ~/.claude, install the Claude Code CLI, skills and plugins
#   check    report what differs from the repo; exits 1 if anything does
#   lock     rewrite claude/versions.lock from what is installed
#
# Every step is safe to re-run. Whatever a link replaces is moved to ~/.workbench-backup/<time>/.
set -euo pipefail

repo="${0:A:h}"
claude_home="$HOME/.claude"
lock="$repo/claude/versions.lock"
backup="$HOME/.workbench-backup/$(date +%Y%m%d-%H%M%S)"
# Written when ~/.claude is linked, so a later plain settings.json is known to be an app's rewrite.
marker="$claude_home/.workbench-linked"

# What claude/ links into ~/.claude.
claude_links=(CLAUDE.md settings.json skills.txt versions.lock mods hooks
              skills/project-profile skills/project-standard)
# Files of the old ~/.claude repo (gitlab: claude-code-setup) that now live only in the workbench.
old_repo_files=(.git .gitignore README.md LICENSE PLAN.md bootstrap.sh docs .claude/CLAUDE.md)

say() { print -r -- "$*"; }
rel() { print -r -- "~/${1#$HOME/}"; }

# Moves PATH into the backup folder, keeping its place under ~.
stash() {
  local p=$1 dest="$backup/${1#$HOME/}"
  mkdir -p "${dest:h}"
  mv "$p" "$dest"
  say "  moved $(rel "$p") to $(rel "$dest")"
}

# link SRC DEST: makes DEST a symlink to SRC, stashing whatever was there.
link() {
  local src=$1 dest=$2
  [[ -L $dest && $(readlink "$dest") == "$src" ]] && return 0
  [[ -e $dest || -L $dest ]] && stash "$dest"
  mkdir -p "${dest:h}"
  ln -s "$src" "$dest"
  say "  linked $(rel "$dest")"
}

home_files() { (cd "$repo/home" && find . -type f ! -name .DS_Store | sed 's|^\./||' | sort); }

hooks_path() { git -C "$repo" config core.hooksPath .githooks; }

# One sorted line per skill, marketplace and enabled plugin. Neither installer can pin a
# commit, so this is how a Mac tells that upstream has moved since the lock was written.
versions() {
  {
    jq -r '.skills | to_entries[] | "skill \(.key) \(.value.skillFolderHash)"' \
      "$HOME/.agents/.skill-lock.json" 2>/dev/null
    git -C "$claude_home/plugins/marketplaces/claude-code-workflows" rev-parse HEAD 2>/dev/null \
      | sed 's/^/marketplace claude-code-workflows /'
    jq -r --slurpfile s "$claude_home/settings.json" '.plugins | to_entries[]
      | select(.key | endswith("@claude-code-workflows"))
      | select($s[0].enabledPlugins[.key] == true)
      | "plugin \(.key) \(.value[0].version)"' \
      "$claude_home/plugins/installed_plugins.json" 2>/dev/null
  } | LC_ALL=C sort
}

step_apps() {
  say "apps"
  if ! command -v brew >/dev/null; then
    say "  Homebrew is missing. Install it yourself (it asks for your password), then re-run:"
    say '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
  fi
  # A cask whose app is already in /Applications (installed by hand) is adopted, not reinstalled.
  local c
  for c in $(brew bundle list --cask --file "$repo/Brewfile"); do
    brew list --cask "$c" >/dev/null 2>&1 || brew install --cask --adopt "$c" || say "  failed: $c"
  done
  brew bundle install --no-upgrade --file "$repo/Brewfile" \
    || say "  some entries failed; App Store apps need you signed in to the App Store"
}

step_home() {
  say "home"
  local f
  for f in ${(f)"$(home_files)"}; do link "$repo/home/$f" "$HOME/$f"; done
  # Git reads ~/.config/git/config; a ~/.gitconfig would override it.
  [[ -f $HOME/.gitconfig && ! -L $HOME/.gitconfig ]] && stash "$HOME/.gitconfig"
  command -v mise >/dev/null && mise install --yes >/dev/null && say "  mise runtimes installed"
  return 0
}

step_macos() {
  say "macos"
  bash "$repo/macos/defaults.sh"
}

step_claude() {
  say "claude"
  mkdir -p "$claude_home"

  # Retire the old ~/.claude repo once: its files now live here.
  if [[ -d $claude_home/.git ]]; then
    local f
    for f in $old_repo_files; do
      [[ -e $claude_home/$f ]] && stash "$claude_home/$f"
    done
  fi

  # An app replaced the settings.json link with a file: keep its changes, then relink.
  local s="$claude_home/settings.json"
  if [[ -f $marker && -f $s && ! -L $s ]]; then
    cp "$s" "$repo/claude/settings.json"
    say "  settings.json had been replaced by a plain file; its content is now claude/settings.json"
    say "  (review it with: git -C $(rel "$repo") diff claude/settings.json)"
    rm "$s"
  fi

  local l
  for l in $claude_links; do link "$repo/claude/$l" "$claude_home/$l"; done
  print -r -- "$repo" > "$marker"

  # The Claude Code CLI, from Anthropic's installer (it updates itself).
  if ! command -v claude >/dev/null && [[ ! -x $HOME/.local/bin/claude ]]; then
    curl -fsSL https://claude.ai/install.sh | bash
  fi
  path=("$HOME/.local/bin" $path)

  # Third-party skills that are not installed yet.
  local sk
  grep -vE '^\s*(#|$)' "$repo/claude/skills.txt" | while read -r sk; do
    [[ -e $claude_home/skills/${sk##*@} ]] && continue
    say "  skill: $sk"
    mise exec node -- npx -y skills add "$sk" -g -y -a claude-code >/dev/null || say "  failed: $sk"
  done

  # Marketplaces, then every enabled plugin that is not installed. The mods' marketplace is the
  # ~/.claude/mods link, so its path is the same on every Mac and is not kept in settings.json.
  claude plugin marketplace list 2>/dev/null | grep -q claude-code-workflows \
    || claude plugin marketplace add wshobson/agents || true
  claude plugin marketplace list 2>/dev/null | grep -q local-mods \
    || claude plugin marketplace add "$claude_home/mods" || true
  local p installed
  installed=$(jq -r '.plugins | keys[]' "$claude_home/plugins/installed_plugins.json" 2>/dev/null || true)
  jq -r '.enabledPlugins | to_entries[] | select(.value) | .key' "$repo/claude/settings.json" \
    | grep -v '@builtin$' | while read -r p; do
    grep -qxF "$p" <<<"$installed" && continue
    say "  plugin: $p"
    claude plugin install "$p" >/dev/null || say "  failed: $p"
  done

  if [[ ! -d $HOME/.secrets/.git ]]; then
    say "  secrets: this Mac is not enrolled. When ready, run:"
    say "  bash ~/.claude/skills/project-standard/templates/make/bin/secrets.sh enroll"
  fi
}

step_check() {
  local issues=() out f l
  # Apps
  if command -v brew >/dev/null; then
    out=$(brew bundle check --no-upgrade --verbose --file "$repo/Brewfile" 2>/dev/null | grep '^→' || true)
    [[ -n $out ]] && issues+=("apps missing:"$'\n'"${out//→/ }")
    # What was installed on purpose (leaves and casks) but is not in the Brewfile.
    out=$(comm -23 <({ brew leaves; brew list --cask; } | LC_ALL=C sort) \
                   <({ brew bundle list --formula --file "$repo/Brewfile"; brew bundle list --cask --file "$repo/Brewfile"; } \
                      | sed 's|.*/||' | LC_ALL=C sort) | tr '\n' ' ')
    [[ -n $out ]] && say "note: installed but not in the Brewfile (kept; nothing is uninstalled): $out"
  else
    issues+=("Homebrew is not installed")
  fi
  # Links
  for f in ${(f)"$(home_files)"}; do
    [[ -L $HOME/$f && $(readlink "$HOME/$f") == "$repo/home/$f" ]] || issues+=("not linked: ~/$f")
  done
  [[ -e $HOME/.gitconfig ]] && issues+=("~/.gitconfig exists and overrides ~/.config/git/config")
  for l in $claude_links; do
    [[ -L $claude_home/$l && $(readlink "$claude_home/$l") == "$repo/claude/$l" ]] && continue
    if [[ $l == settings.json && -f $claude_home/$l ]]; then
      issues+=("~/.claude/settings.json was replaced by a plain file (an app wrote it); bootstrap.sh claude keeps its changes and relinks it")
    else
      issues+=("not linked: ~/.claude/$l")
    fi
  done
  # macOS
  out=$(bash "$repo/macos/defaults.sh" --check 2>&1) || issues+=("$out")
  # Claude
  command -v claude >/dev/null || [[ -x $HOME/.local/bin/claude ]] || issues+=("the claude CLI is missing")
  if [[ -f $lock ]]; then
    out=$(comm -23 "$lock" <(versions))
    [[ -n $out ]] && say "note: claude/versions.lock differs from what is installed (upstream moved, or an install failed):"$'\n'"$out"
  fi
  # Repo
  out=$(git -C "$repo" status --short)
  [[ -n $out ]] && say "note: uncommitted changes in $(rel "$repo"):"$'\n'"$out"
  [[ $(git -C "$repo" config core.hooksPath) == .githooks ]] || issues+=("the home-path commit guard is off: run bootstrap.sh")

  if (( ${#issues} )); then
    say "check: ${#issues} to fix"
    for f in $issues; do say "- $f"; done
    return 1
  fi
  say "check: clean"
}

cmd="${1:-}"
case $cmd in
  all)    hooks_path; step_apps; step_home; step_macos; step_claude; say "done. Start a new Claude session, and log out and in for the keyboard settings." ;;
  apps)   step_apps ;;
  home)   hooks_path; step_home ;;
  macos)  step_macos ;;
  claude) hooks_path; step_claude ;;
  check)  step_check ;;
  lock)   versions > "$lock"; say "wrote $(rel "$lock") ($(wc -l < "$lock" | tr -d ' ') entries)" ;;
  *)      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
