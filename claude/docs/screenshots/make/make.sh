#!/bin/zsh
# Regenerates the images in docs/screenshots from the mods' own output, fed with demo content:
#   zsh docs/screenshots/make/make.sh
# Nothing is captured from the screen. Each mod draws the demo content in the test kit, the
# drawing is laid out as a page with the same cell sizes the app uses, and WebKit renders the
# page to a PNG. The project map is the mod's own SVG. Buttons, inputs and fonts are stand-ins
# for the app's own, so spacing and content are true to the mods and the widgets are not.
# Needs: macOS, Xcode command-line tools (swiftc), Node 22+, the claude CLI.
set -euo pipefail
here="${0:A:h}"
repo="${here:h:h:h}"
out="${here:h}"
work="$(mktemp -d)"
trap 'rm -rf "$work"; rm -f "$repo"/mods/*/tests/zz-demo.test.tsx(N)' EXIT

# 1. What each mod draws for the demo content. The demo tests only live in the mods while this runs.
for mod in git-graph status-band session-tint; do
  cp "$here/$mod.demo.test.tsx" "$repo/mods/$mod/tests/zz-demo.test.tsx"
  claude plugin test "$repo/mods/$mod" > "$work/$mod.out" 2>&1 || true
  rm -f "$repo/mods/$mod/tests/zz-demo.test.tsx"
  grep -q '^DEMO ' "$work/$mod.out" || { echo "no drawing from $mod"; tail -5 "$work/$mod.out"; exit 1; }
done

# 2. The pages. The map's drawing code is copied so Node can import it by file name.
mkdir -p "$work/hooks" "$work/types"
cp "$repo/mods/agent-map/hooks/core.ts" "$repo/mods/agent-map/hooks/draw.ts" "$work/hooks/"
cp "$repo/mods/agent-map/types/index.d.ts" "$work/types/"
sed -i '' "s|from './core'|from './core.ts'|" "$work/hooks/draw.ts"
cp "$here/build.mts" "$here/demo-plan.md" "$work/"
(cd "$work" && node --experimental-strip-types build.mts 2>/dev/null) > "$work/pages.txt"

# 3. The images, at twice the page's size and then scaled to 1600 px wide at most.
swiftc -O "$here/html2png.swift" -o "$work/html2png" 2>/dev/null
while read -r name width; do
  "$work/html2png" "$work/$name.html" "$work/$name.png" "$width" > /dev/null
  if (( $(sips -g pixelWidth "$work/$name.png" | awk '/pixelWidth/ {print $2}') > 1600 )); then
    sips --resampleWidth 1600 "$work/$name.png" --out "$out/$name.png" > /dev/null
  else
    cp "$work/$name.png" "$out/$name.png"
  fi
  echo "$name.png"
done < "$work/pages.txt"
