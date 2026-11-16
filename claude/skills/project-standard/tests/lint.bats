#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Static lint of the make fragments: every shell line of a recipe that publishes or decrypts production
# secrets starts with a guard. A guard protects only the shell line it is on (see the comment above
# std_confirm in common.mk), so the check works on shell lines: recipe lines joined across their
# backslash continuations, and the guard must come before the action on that line.

MAKE_DIR="$BATS_TEST_DIRNAME/../templates/make"

# unguarded FILE...   print file:line: text for every shell line with a publishing action and no guard before it.
unguarded() {
  awk '
    function check(s, ln,   n, i, pats, p, g, gp, k) {
      # a dry run publishes nothing
      gsub(/wrangler deploy --dry-run/, "wrangler dry-run", s)
      g = 0
      split("std_confirm std_production_guard std_remote_guard", guards, " ")
      for (k in guards) { gp = index(s, guards[k]); if (gp && (!g || gp < g)) g = gp }
      n = split("--env production|r2 object put|altool --upload|fastlane supply|uv publish|wrangler deploy", pats, "|")
      for (i = 1; i <= n; i++) {
        p = index(s, pats[i])
        if (p && (!g || g > p)) { printf "%s:%d: %s (no guard before \"%s\")\n", FILENAME, ln, substr(s, 1, 160), pats[i]; return }
      }
    }
    FNR == 1 { if (buf != "") check(buf, start); buf = ""; cont = 0 }
    {
      if (cont) { buf = buf " " $0 }
      else if ($0 ~ /^\t/ && $0 !~ /^\t[ \t]*#/) { buf = $0; start = FNR }
      else { buf = ""; next }
      if ($0 ~ /\\$/) { cont = 1 } else { cont = 0; check(buf, start); buf = "" }
    }
    END { if (buf != "") check(buf, start) }
  ' "$@"
}

@test "lint: every recipe line that publishes or decrypts production secrets has a guard before the action" {
  run unguarded "$MAKE_DIR/common.mk" "$MAKE_DIR"/kinds/*.mk
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "$output"
    return 1
  fi
}

@test "lint: the publishing kinds are among the files checked" {
  for k in app-android app-flutter app-tauri app-xcode python cloud-worker silabs zephyr; do
    [ -f "$MAKE_DIR/kinds/$k.mk" ]
  done
  run grep -c 'std_confirm,production) &&' "$MAKE_DIR"/kinds/app-android.mk
  [ "$output" -ge 4 ]
}

@test "lint: catches an unguarded upload, a guard after the action, and a guard on a line of its own" {
  f="$BATS_TEST_TMPDIR/bad.mk"
  printf 'x-release:\n\t@cd app && fastlane supply --aab a.aab\n' >"$f"
  run unguarded "$f"
  [[ "$output" == *'bad.mk:2:'*'fastlane supply'* ]]

  printf 'x-release:\n\t@set -e; \\\n\tnpx wrangler r2 object put b/latest.json; \\\n\t$$(call std_confirm,production)\n' >"$f"
  run unguarded "$f"
  [[ "$output" == *'bad.mk:2:'*'r2 object put'* ]]

  printf 'x-release:\n\t@$$(call std_confirm,production)\n\t@sec exec --env production -- uv publish\n' >"$f"
  run unguarded "$f"
  [[ "$output" == *'bad.mk:3:'* ]]
}

@test "lint: passes a guard that starts a continued shell line, and a dry run" {
  f="$BATS_TEST_TMPDIR/ok.mk"
  printf 'x-deploy:\n\t@$$(call std_remote_guard,x) && { set -e; \\\n\tsec exec --env production -- npx wrangler deploy; }\nx-build:\n\t@npx wrangler deploy --dry-run --outdir dist\n' >"$f"
  run unguarded "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lint: every managed file and CI template names the version in templates/project/make/VERSION, and no other" {
  local skill v f bad=''
  skill="$BATS_TEST_DIRNAME/.."
  v=$(tr -d '[:space:]' <"$skill/templates/project/make/VERSION")
  [[ $v =~ ^[0-9]+\.[0-9]+$ ]]
  for f in "$MAKE_DIR/common.mk" "$MAKE_DIR"/kinds/*.mk "$MAKE_DIR"/bin/*.sh "$skill/templates/project/Makefile"; do
    head -n 2 "$f" | grep -Fq "# project-standard v$v (managed:" || bad="$bad $(basename "$f")"
  done
  for f in "$skill"/ci-templates/.github/workflows/*.yml; do
    sed -n 1p "$f" | grep -Fq "# project-standard ci-templates v$v: " || bad="$bad $(basename "$f")"
    grep -Fq "/.github/workflows/$(basename "$f")@v$v" "$f" || bad="$bad $(basename "$f")@"
  done
  grep -Fq "readonly STD_VERSION=$v" "$skill/scripts/scaffold.sh" || bad="$bad scaffold.sh"
  # nothing managed still says another version
  others=$(grep -rhoE 'project-standard (ci-templates )?v[0-9]+\.[0-9]+' "$MAKE_DIR" "$skill/templates/project" "$skill/ci-templates/.github" |
    sed -E 's/.* v//' | sort -u | grep -vx "$v" || true)
  [ -z "$others" ] || bad="$bad other-versions:$others"
  if [ -n "$bad" ]; then
    echo "not on v$v:$bad"
    return 1
  fi
}
