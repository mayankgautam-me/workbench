#!/bin/bash
# macOS settings for this Mac: Dock, Finder, keyboard, look, screenshots, TextEdit, Terminal.
#
#   bash macos/defaults.sh           apply them, then restart Dock, Finder and SystemUIServer
#   bash macos/defaults.sh --check   list each setting that differs; exit 1 if any does
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-apply}"
profile="Tokyo Night"

# domain | key | type | value
settings=(
  # Dock: auto-hide with no delay, small icons, no recent apps, bottom-right corner shows Desktop
  "com.apple.dock|autohide|bool|true"
  "com.apple.dock|autohide-delay|float|0"
  "com.apple.dock|tilesize|float|37"
  "com.apple.dock|show-recents|bool|false"
  "com.apple.dock|wvous-br-corner|int|4"
  "com.apple.dock|wvous-br-modifier|int|0"
  # Finder
  "com.apple.finder|AppleShowAllFiles|bool|true"
  "NSGlobalDomain|AppleShowAllExtensions|bool|true"
  "com.apple.finder|ShowPathbar|bool|true"
  "com.apple.finder|ShowStatusBar|bool|true"
  "com.apple.finder|FXPreferredViewStyle|string|Nlsv"
  "com.apple.finder|_FXSortFoldersFirst|bool|true"
  "com.apple.finder|FXDefaultSearchScope|string|SCcf"
  "com.apple.finder|NewWindowTarget|string|PfHm"
  "com.apple.desktopservices|DSDontWriteNetworkStores|bool|true"
  # Keyboard and typing
  "NSGlobalDomain|KeyRepeat|int|2"
  "NSGlobalDomain|InitialKeyRepeat|int|15"
  "NSGlobalDomain|ApplePressAndHoldEnabled|bool|false"
  "NSGlobalDomain|NSAutomaticSpellingCorrectionEnabled|bool|false"
  "NSGlobalDomain|NSAutomaticQuoteSubstitutionEnabled|bool|false"
  "NSGlobalDomain|NSAutomaticDashSubstitutionEnabled|bool|false"
  # Look and screenshots
  "NSGlobalDomain|AppleInterfaceStyle|string|Dark"
  "com.apple.screencapture|type|string|png"
  "com.apple.screencapture|disable-shadow|bool|true"
  "com.apple.screencapture|location|string|$HOME/Pictures/Screenshots"
  # TextEdit opens plain text
  "com.apple.TextEdit|RichText|bool|false"
  # Terminal profile (imported below when missing)
  "com.apple.Terminal|Default Window Settings|string|$profile"
  "com.apple.Terminal|Startup Window Settings|string|$profile"
)

# What `defaults read` prints for a value of this type.
shown() {
  case "$1|$2" in
    bool\|true) echo 1 ;;
    bool\|false) echo 0 ;;
    *) echo "$2" ;;
  esac
}

if [[ "$mode" == --check ]]; then
  diff=0
  for s in "${settings[@]}"; do
    IFS='|' read -r domain key type value <<<"$s"
    want="$(shown "$type" "$value")"
    have="$(defaults read "$domain" "$key" 2>/dev/null || echo '(unset)')"
    if [[ "$have" != "$want" ]]; then
      printf 'macos: %s %s is %s, want %s\n' "$domain" "$key" "$have" "$want"
      diff=1
    fi
  done
  exit "$diff"
fi

if [[ "$mode" != apply ]]; then
  echo "usage: bash $0 [--check]" >&2
  exit 2
fi

mkdir -p "$HOME/Pictures/Screenshots"

# Opening a .terminal file imports the profile (and opens one window with it).
if ! defaults read com.apple.Terminal "Window Settings" 2>/dev/null | grep -q "\"$profile\" ="; then
  open "$here/$profile.terminal"
  sleep 2
fi

failed=()
for s in "${settings[@]}"; do
  IFS='|' read -r domain key type value <<<"$s"
  defaults write "$domain" "$key" "-$type" "$value" 2>/dev/null || failed+=("$domain $key")
done

killall Dock Finder SystemUIServer 2>/dev/null || true
echo "macOS settings applied. Key repeat and Dark mode take full effect after logging out."

# A sandboxed app's settings (TextEdit's) can only be written by a program macOS lets reach
# other apps' data: run this from Terminal and allow it when asked.
if (( ${#failed[@]} )); then
  echo "Not written (run 'bash macos/defaults.sh' from Terminal and allow access to the app's data):"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
