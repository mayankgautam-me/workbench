# workbench

My Mac setup: apps, dotfiles, macOS settings, and my Claude Code setup in `claude/`
(instructions, settings, a project-detection hook, skills and plugins, four local mods).

## Global instructions {#instructions}
tech: CLAUDE.md, skill routing
files: [claude/CLAUDE.md, .claude/CLAUDE.md]
- [x] Machine, dotfiles, preferences, git and security sections {#instructions-base}
- [x] Skill routing for the seven kinds of work {#instructions-routing}
- [x] Routes agree with the session-start hook {#instructions-aligned}
- [x] Routes for mod work and settings changes {#instructions-setup}
- [x] Rule: Claude marks PLAN.md tasks as it starts and finishes them {#instructions-plan-marks}
- [x] Rule: Claude keeps each PLAN.md in the format the map reads and true to the project {#instructions-plan-format}
- [x] Rule: an approved /plan is written into PLAN.md as components and tasks {#instructions-plan-mode}
- [x] Rule: PLAN.md is updated before the work starts and marked as it goes {#instructions-plan-first}
- [x] Rule: no task is left marked in progress when the work on it has stopped {#instructions-no-stale-marks}
- [x] One source for the routes: the hook prints the lines of CLAUDE.md marked `<!--route:…-->` {#instructions-single-source}
- [x] Repo guide in .claude/CLAUDE.md: commands and architecture of this repo, loaded only here {#instructions-repo-guide}
- [x] Agents first: the main session plans, delegates to agents and checks their work, instead of doing everything in one session {#instructions-agents-first}
- [x] Branch: before the first change of a piece of work in a project, ask which branch to work on and whether to commit to main {#instructions-ask-branch}

## Settings and permissions {#settings}
tech: settings.json
files: [claude/settings.json]
- [x] SessionStart hook registered {#settings-hook}
- [x] sudo denied for Claude's shell {#settings-sudo}
- [x] Allow rules narrowed: shell rc edits and brew installs prompt {#settings-allow}
- [x] Disabled plugins uninstalled {#settings-plugins}
- [x] Worktrees: a new worktree starts from the current HEAD, and an agent that writes in a git repository works in its own worktree {#settings-worktrees}

## Project detection {#detect}
tech: bash SessionStart hook, project-profile skill
files: [claude/hooks/**, claude/skills/project-profile/**]
needs: [settings, instructions]
- [x] Detect app, web, firmware, hardware, backend, AI and data projects {#detect-types}
- [x] Embedded Rust from Cargo.toml dependencies; a linker script alone is not Cortex-M {#detect-precision}
- [x] shellcheck clean {#detect-lint}
- [x] Routes read from CLAUDE.md by marker, with tests that the two agree {#detect-routes}
- [x] bats tests in place of the ad hoc sample folders: `bats hooks/tests` {#detect-tests}

## Skills and plugins {#skills}
tech: skills CLI, wshobson/agents marketplace
files: [claude/skills.txt, claude/versions.lock]
needs: [settings]
- [x] skills.txt lists every third-party skill {#skills-list}
- [x] versions.lock records skill hashes, the marketplace commit and plugin versions {#skills-lock}
- [!] Pin skills and plugins to a commit: neither installer can {#skills-pin}

## Bootstrap {#bootstrap}
tech: zsh
files: [bootstrap.sh, README.md, LICENSE, .gitignore, .githooks/**, PLAN.md, docs/**, claude/README.md, claude/docs/**]
needs: [skills, settings]
- [x] Turn ~/.claude into the repo, keeping a copy of replaced files {#bootstrap-move}
- [x] Install missing command-line tools and warn about missing dotfiles {#bootstrap-tools}
- [x] Warn when an install differs from versions.lock {#bootstrap-drift}
- [x] Document the repository for other people: what it is, what each part does, how to install all or one part, how to adapt it; a README per mod {#docs-public}
- [x] Checked the tracked files and the whole history for secrets: none; personal details are the home path, the private remote's address and the commit email {#docs-public-check}
- [x] GPL-3.0 licence file, named in the README and tracked {#public-licence}
- [x] No home path or private remote address in the tracked files; the mods' marketplace is registered by bootstrap, not named in settings.json {#public-generalise}
- [x] A branch `public` with one fresh commit to publish from, so the old history and its email stay private {#public-fresh-history}
- [x] Create the public project `mayankgautam_me/claude-code-setup`, push the fresh commit to it as `main`, and make it this checkout's `origin` {#public-push}
- [x] Images of each mod in the READMEs, kept in `docs/screenshots`: generated from the mods' own output with demo content, by `docs/screenshots/make/make.sh` {#docs-screenshots}
- [ ] Run it end to end on a second machine: waits on you, there is no second machine here {#bootstrap-second-machine}

## Status band {#status-band}
tech: hooks module, band above the prompt
files: [claude/mods/status-band/**, claude/mods/.claude-plugin/**]
needs: [settings]
- [x] Context, plan limits and session cost, live {#band-gauges}
- [x] Rows for agents and background tasks {#band-agents}
- [x] Folds to one row {#band-fold}
- [x] Carries the map toggle {#band-map}
- [x] Carries the git graph toggle {#band-graph}
- [x] Git graph toggle at the right end of the band, away from the map's {#band-graph-right}
- [x] The band follows its width: shorter detail when medium, two rows of two with short labels when narrow {#band-responsive}
- [x] The folded band follows its width too: short labels, then no bars, then figures that wrap instead of being cut {#band-folded-responsive}
- [x] The same gap as the git graph and the map: two cells across, one row down, between the band's cells, rows and toggles, also where they wrap {#band-even-gaps}
- [x] Toggle test passes again: its press mock returned `{}`, which the engine now refuses; the engine runs the press itself {#band-test-press}

## Session tint {#session-tint}
tech: hooks module, Tokyo Night palette
files: [claude/mods/session-tint/**]
needs: [settings]
links: [status-band]
- [x] A colour per session on the rule, prompts and spinner {#tint-colour}
- [x] /tint changes it {#tint-command}
- [x] Its rule carries the map and git graph toggles {#tint-toggles}
- [x] Git graph toggle at the right end of the rule {#tint-graph-right}

## Project map {#agent-map}
tech: hooks module, one SVG drawing
files: [claude/mods/agent-map/**]
needs: [settings]
links: [status-band, session-tint]
- [x] PLAN.md components as cards with dependency arrows {#map-cards}
- [x] Top-to-bottom rows, each card under what it needs {#map-rows}
- [x] Tasks listed inside each card {#map-tasks}
- [x] Agent marks and the live call on the card being worked on {#map-agents}
- [x] Panel and toggles only where there is a PLAN.md {#map-plan-only}
- [x] Re-read PLAN.md as soon as it is edited, so a ticked task shows at once {#map-reread}
- [x] Check PLAN.md mechanically after each edit and on /map check; problems go back to Claude {#map-lint}
- [x] /map init asks Claude to write PLAN.md from the project {#map-init}
- [x] Try /map init in the running app, in a project with no PLAN.md: it wrote a PLAN.md in the map's format, three components covering every file {#map-init-verify}
- [x] Check the map in the running app {#map-verify}
- [x] Confirm the band's map button shows and hides the panel without typing /map: you saw it work in the app {#map-toggle-verify}
- [x] An in-progress task's dot pulses only while an agent is working; at rest it is still {#map-still-at-rest}
- [x] Type-check the mod with tsc from npx against the engine's types {#map-types}
- [x] Confirm the dashes on live arrows move {#map-animation}
- [x] Rows fill the panel's width; a wide card lists its tasks in columns {#map-full-width}
- [x] Session card on top: every working agent and what it is doing {#map-session-card}
- [x] On each card: a row per agent at work, the files last touched, a breathing edge and a spinner {#map-live-card}
- [x] Live arrows on top of the others, each with its own colour and track {#map-live-arrows}
- [x] Arrows from one card share a trunk; gaps grow to fit their tracks; ports line up; rows are ordered for short arrows {#map-arrow-routing}
- [x] An agent's trail keeps to the gaps at right angles, and its mark runs along it {#map-trail-routing}
- [x] A card's edge is lit only while someone works in it; trails show only while their agent works, under the arrows {#map-quiet-at-rest}
- [x] Links between two cards of one row run under the row at right angles, never across a card {#map-link-routing}
- [x] `links:` are no longer drawn: only `needs:` arrows {#map-no-links}
- [x] An agent thinking or running a command keeps its card lit and animated; the session card breathes while anything works {#map-always-moving}
- [x] A shell command lights the card of the component whose files it names {#map-command-card}
- [x] A card lists all of its tasks, not ten and "N more" {#map-all-tasks}
- [x] The panel never opens by itself at session start: only the band shows {#map-no-autoopen}
- [x] A card's tasks grouped by status, each group folded to one line by default {#map-task-groups}
- [x] A slim row above the map unfolds a status on every card, or every group of one card {#map-task-unfold}
- [x] Tasks in progress are always listed with their amber dots; only the other groups fold {#map-working-shown}
- [x] The tasks row offers only the statuses the plan has tasks in, and no card picker {#map-task-row-trim}
- [x] Re-read PLAN.md after a shell command changes it, not only after the Edit tool does {#map-reread-shell}
- [x] Only an agent's move animates, with an arrowhead where it went; dependency arrows stay still and grey {#map-arrows-clear}
- [x] Each file on a card says edited or read in words beside its square {#map-file-words}
- [x] A tall map is steadier to scroll: the drawing keeps its size while it is replaced, is unchanged between redraws at rest, and is redrawn less often {#map-scroll-steady}
- [x] Check the scrolling in the running app, full screen: you saw it work {#map-scroll-verify}
- [x] No empty space above the first card when the panel is narrow: the image's height is no longer fixed, and the drawing sits at the top of its box {#map-narrow-top-gap}
- [x] Check the narrow panel in the running app: you saw it work {#map-narrow-verify}
- [x] The same gap as the git graph, about 19 px on every side: round the drawing, between cards, inside a card, and in the tasks row above the map {#map-even-gaps}
- [x] In a narrow, one-column map an agent's move line keeps the same 16 px from the cards as everywhere else, not 4 {#map-narrow-move-line}
- [x] Several agents on the move never share a line: each has its own track, 12 px from the next, in a gap, in the left margin and along a card's edge; gaps and the margin grow to fit {#map-move-tracks}
- [x] An agent's dot leaves the foot of its card when the agent ends, and the session's when the turn ends {#map-no-resting-dots}
- [x] A card is only as tall as what it shows: no empty row kept at its foot for an agent that is not there {#map-shrink-empty}
- [x] An agent whose file a component now claims moves to that component even while other files stay unplanned; a plan reload that moves nothing redraws nothing {#map-rehome-agent}
- [x] Look at several agents moving in the running app, wide and narrow: seen working {#map-move-tracks-verify}
- [x] The mod tells Claude, in every project with a PLAN.md, to put work into the plan before doing it, and reminds it when files are edited with no task in progress {#map-plan-first}
- [x] Every line keeps 16 px from a card it runs beside and 12 px from a line it runs beside; gaps and margins grow to fit {#map-line-spacing}
- [x] Watch the new motion in the running app: glide, pulses, session card {#map-motion-verify}
- [x] Background tasks on the map: a background shell, monitor or workflow is a row on the session card, and on the component its command names, with how long it has run and how it ended {#map-background-tasks}
- [x] Look at background tasks on the map in the running app, with a real background command: seen working {#map-background-verify}
- [x] /map refresh: read PLAN.md and the project again and redraw the map, without showing or hiding it {#map-refresh}
- [x] /map test passes again: its prompt.submit mock returned `{}`; it now returns the prompt as `{ text }` {#map-test-prompt}

## Git graph {#git-graph}
tech: hooks module, one SVG cell per commit row
files: [claude/mods/git-graph/**]
needs: [settings]
links: [status-band, session-tint]
- [x] Commits as a graph in lanes, with branch and tag labels {#graph-lanes}
- [x] Branch filter, remotes and tags toggles, find box, load more {#graph-view}
- [x] A row for uncommitted changes, listing the changed files {#graph-changes}
- [x] Git actions on a commit, branch, tag, working tree and repository, each shown as its command and confirmed {#graph-actions}
- [x] /graph and a toggle in the status band and on the session rule, only inside a repository {#graph-toggle}
- [x] Re-read after a git command the model runs and at the end of each turn {#graph-live}
- [x] Graph cells were missing in the app: each row's cell now has a fixed width so it is drawn {#graph-cells-shown}
- [x] Column headings {#graph-headings}
- [x] Toolbar in labelled groups with the app's own buttons, on/off marks for remotes and tags {#graph-toolbar}
- [x] Column width presets: compact, normal, wide, remembered {#graph-columns}
- [x] The selected commit's panel as a bordered card with grouped buttons {#graph-card}
- [x] Toolbar tightened: no blank lines between caption and controls, Refresh with the remote buttons, no cut-off graph heading {#graph-toolbar-tight}
- [x] The panel never opens by itself at session start {#graph-no-autoopen}
- [x] The table follows the panel's width: columns drop out as it narrows, description always keeps room {#graph-responsive}
- [x] Seen in the running app: the rows' graph cells join without gaps {#graph-verify}
- [x] Every action run against real git on scratch repositories, by `scripts/real-git-actions.mts`; pulling a diverged remote branch failed and is fixed {#graph-actions-verify}
- [x] Commit details: full message and changed files with line counts {#graph-details}
- [x] Stashes on the graph, and comparing two commits {#graph-stashes}
- [x] Every button pressed through the panel in the test kit, and every offered command run against real git in six repository states by `scripts/all-buttons.mts`: 155 of 682 failed, now none {#graph-buttons-test}
- [x] An action git would refuse is not offered: what is behind HEAD is not picked, merged or rebased onto, a merge is picked or reverted against its first parent, pull and push follow the upstream {#graph-offer-only-working}
- [x] A merge, cherry-pick, revert or rebase that stopped half way shows a bar to continue or abort it {#graph-operation}
- [x] Info, warnings and errors as a toast above the prompt, not a line in the panel: same gap on every side, as wide as its words {#graph-toasts}
- [x] One gap everywhere in the panel: two cells across, one row down, between toolbar groups, buttons, columns and blocks, also where they wrap; the find box takes the width that is left {#graph-even-gaps}
- [x] The toast inside the git graph panel, at its foot, not above the prompt; the panel scrolls to show it {#graph-toast-in-panel}
- [x] The toast pinned to the bottom centre of the panel's visible part, the content scrolling behind it {#graph-toast-sticky}
- [x] Look at the toast and the buttons in the running app: seen right in 0.11.0 {#graph-toast-verify}
- [x] A repository with many commits showed the app's "nothing to show yet": the drawing went over the 100,000 characters a panel may hold; one page of rows is drawn now, older and newer a press away {#graph-size-bound}
- [x] A control character in what git hands over (a tab or carriage return in a message, a remote's progress lines) made the app refuse the whole panel: stripped before drawing {#graph-plain-text}
- [x] Paging on a long history seen working in the running app {#graph-paging-verify}
- [x] Session worktrees on the graph: each worktree named on the commit it has checked out, with its folder and branch in the commit's card, and a toggle beside remotes and tags {#graph-worktrees}
- [x] Ahead and behind counts on the Push and Pull buttons: how many commits the branch has that its upstream lacks, and the other way {#graph-ahead-behind}
- [x] The whole commit tree scrolls on its own while the toolbar stays in place, with no pages {#graph-scroll}
- [x] Look at the scrolling list in the running app: it did not scroll at all on the desktop; the probe showed why, fixed in 0.9.0 and 0.9.2, and the last look is the task below {#graph-scroll-verify}
- [x] A fixed toolbar that works on the desktop: the probe showed the app hands the panel its wheel only while the drawing is taller than the window, so it is drawn one row taller {#graph-scroll-fixed}
- [x] Both ways reach the list in 0.9.2, seen in the app; each tick redraws twice, which glitches {#graph-scroll-check}
- [x] Three ways to get the wheel, `/graph scroll park|drift|edge`, to compare in one build {#graph-scroll-modes}
- [x] Compared in the running app: park was smoothest, edge got no wheel; park kept as the only way and the probe removed in 0.11.0 {#graph-scroll-pick}

## Project standard {#project-standard}
tech: skill, make fragments for GNU make 3.81+, bash, sops + age (Secure Enclave), GitHub reusable workflows (ci-templates)
files: [claude/skills/project-standard/**]
needs: [instructions, detect, bootstrap]
- [x] Contract: macro names, part registration, secrets wrapper, guards {#std-contract}
- [x] common.mk: help, ENV and CONFIRM guards, stage fan-out, secrets loading {#std-common}
- [x] secrets.sh: init, set, edit, list, check, keygen, rotate, ci, enroll, add and remove machine {#std-secrets}
- [x] cf.sh: login, logout, whoami, token-check, provision, status, backup, wipe, destroy {#std-cf}
- [x] Part kinds: zephyr, espidf, pio, arm-gcc, circuitpython, hardware, cloud-worker, web-pages, app-flutter, app-tauri, app-xcode, app-android, docker, go, python {#std-kinds}
- [x] Templates: Makefile, project.mk, Brewfile, mise.toml, secrets.schema, ignores, docs skeletons {#std-templates}
- [x] CI templates for fabrolabs/ci-templates {#std-ci}
- [x] scaffold.sh and audit.sh {#std-scaffold-audit}
- [x] SKILL.md and reference/standard.md {#std-skill-doc}
- [x] bats tests for scaffold, audit, guards and secrets {#std-tests}
- [x] Hook prints the project-standard line; CLAUDE.md route and section; README; bootstrap enrol step {#std-wiring}
- [x] Demo project end to end in the scratchpad; help colours checked from a capture of the real output, Terminal.app would not open a window from the session {#std-verify}
- [x] Independent security review of secrets, guards and Cloudflare destroy; all 24 findings fixed with tests {#std-security-review}
- [x] fabrolabs/secrets and fabrolabs/ci-templates created private; templates pushed and tagged v1; this Mac enrolled and ~/.secrets pushed {#std-remotes}
- [x] Offline recovery key command, and enroll no longer asks the first Mac to run add-machine {#std-recovery}
- [x] Create the recovery key in your own terminal and write it down: created and written down {#std-recovery-key}
- [x] Analysis of the skill: 247 tests pass; app releases unguarded, most CI release jobs miss SECRETS_DIR, secrets sync hides a failed pull; write-up in project-standard-analysis.md, untracked {#std-analysis}
- [x] Standard v2: version, headers and CI ref bumped, the hook recognised at any version, fabrolabs/ci-templates tagged v2 with v1 left as it was; 257 tests pass {#std-v2}
- [x] Fit check for the Fabrolabs projects: 12 of 14 fit, fabloq and kicad-library do not; write-up in fabrolabs-adoption.md, untracked {#std-fabrolabs-fit}
- [x] Standard v3: one Cloudflare token per project for every environment, stored in the staging and production files {#std-v3-token}
- [x] Standard v3: production-only Workers, a manual tag deploy in CI with no staging or promote {#std-v3-prod-only}
- [x] Standard v3: provision a queue's dead-letter queue; docs say Durable Object data is not backed up {#std-v3-dlq}
- [x] Publish ci-templates v3 to fabrolabs/ci-templates: tagged v3, v1 and v2 left as they were {#std-v3-publish}
- [x] Standard v4: pio flash, erase, monitor and debug refuse when more than one env would run; .npmrc is a secret only when it holds an auth token {#std-v4-pio-one-env}
- [x] Publish ci-templates v4 to fabrolabs/ci-templates: tagged v4 {#std-v4-publish}
- [x] command-deck on the standard v5: branch project-standard (merged into main and pushed), audit clean, make check passes {#std-adopt-command-deck}
- [x] command-deck: GitLab pipeline green on the standard templates (all six jobs), after fixes for uv, the KiCad library, clippy, libudev and xdg-utils {#cd-first-pipeline}
- [x] command-deck on GitLab cleaned: failed pipelines, old wrl_files package and artifacts deleted; history rewritten without the old binaries (backup in ~/Backups/command-deck) {#cd-cleanup}
- [x] command-deck: 15 old pipelines deleted and prune requested on GitLab (you ran them) {#cd-cleanup-prune}
- [x] command-deck on v6: generated hardware outputs, unused tests/ and app/.gitignore removed; all six CI jobs passed locally first {#cd-v6}
- [x] command-deck: GitLab pipeline on v6 green, first try after the local run {#cd-v6-pipeline}
- [x] Skill: scaffold sets KICAD_LIBRARY_REPO on hardware jobs from the user config, and adopt says to add the project to kicad-library's job-token allowlist {#std-kicad-lib-ci}
- [x] Skill: scaffold pins Rust with clippy and rustfmt components (mise installs minimal Rust, so CI app-check had no clippy) {#std-rust-components}
- [x] Skill: CI templates take extra apt packages per project (a variable), so a project like command-deck (libudev-dev for hidapi) need not copy the template's before_script; and app-tauri-build itself needs xdg-utils for the AppImage {#std-ci-apt}
- [x] Skill: base.yml .std-part change filter leaves out .gitlab-ci.yml, so a CI-only commit starts no pipeline {#std-ci-changes}
- [x] Skill: make ci-local JOB= runs a CI job locally with gitlab-ci-local (Docker) before it uses GitLab runner minutes; Brewfile and doctor include it, and .gitignore ignores .gitlab-ci-local/ {#std-ci-local}
- [x] command-deck: the 19 binaries committed before LFS converted to LFS on the branch {#cd-lfs}
- [x] Adopt mode: handle binaries already tracked outside LFS (renormalize or exempt) instead of leaving them modified {#std-adopt-lfs}
- [x] Skill fixes found adopting command-deck (v5): scaffold writes firmware_ENV for firmware_PIO_ENV, adds brew platformio while mise pins it; app-tauri check needs svelte-kit sync first and runs npx in a pnpm project {#std-fixes-command-deck}
- [x] Publish ci-templates v5 to fabrolabs/ci-templates: tagged v5 {#std-v5-publish}
- [x] app-tauri linux build in Docker runs npm ci and npx, which fails in a pnpm project {#std-tauri-linux-pnpm}
- [x] v6: make help lists only the root targets a project's parts use; ALL=1 lists all {#std-help-relevant}
- [x] v6: KICAD_LIBRARY_DIR falls back to KiCad's own <PREFIX>_LIB_DIR {#std-kicad-dir-fallback}
- [x] v6: OTA_BUCKET is a project setting in make/project.mk, not per user {#std-ota-per-project}
- [x] v6: scaffold makes tests/smoke and tests/remote only for deployable parts; .gitignore ignores the hardware production/ folder and SvelteKit's .svelte-kit/ {#std-v6-cleanup-gaps}
- [x] Publish ci-templates v6 to fabrolabs/ci-templates: tagged v6 {#std-v6-publish}
- [ ] Skill: the root tests/ is never run by any kind (they use the part's tests/), and the smoke README describes SMOKE_URL executables while kinds run vitest with BASE_URL {#std-tests-root}
- [x] v7 docs: project docs (docs/README.md, architecture, decisions/, operations when deployable) and per part README + CHANGELOG in the part folder, kind docs in docs/<part>/; Markdown only, pdf/docx/xlsx/pptx ignored; audit checks them {#std-v7-docs}
- [x] v7 releases: make <part>-bump sets the version, moves the changelog and tags; a <part>-v<ver> tag builds the assets, uploads them to the package registry with SHA256SUMS and creates a GitLab Release with the changelog notes; publishing to stores, OTA or production stays manual {#std-v7-releases}
- [x] v7: test on command-deck locally, publish ci-templates v7, move command-deck to v7 {#std-v7-ship}
- [x] Skill: on a <part>-v tag pipeline run only that part's check, build and release jobs (today every part's check and build jobs run, spending runner minutes) {#std-tag-part-only} (done in v9: release.yml runs only the tagged part)
- [ ] Skill: bump has no way to release the version a part already has (first release of an existing project); command-deck needed a placeholder version file. Add RELEASE_CURRENT=1 or allow VERSION= equal when no tag exists {#std-bump-current}
- [x] v8 app releases: macOS universal from the Mac; Linux amd64 and arm64 and Windows x64 and arm64 (.msi and .exe) from tag pipeline runners into the same Release; per-platform SHA256SUMS; safe when jobs create the Release at once {#std-v8-app-matrix}
- [x] v8 mobile releases: Android .apk attached (aab and mapping.txt in the registry, not linked); iOS dSYMs attached and the TestFlight build in the notes, no ipa {#std-v8-mobile}
- [x] v8 signing: macOS Developer ID and notarisation, Windows code signing, used when the secrets exist, a warning otherwise {#std-v8-signing}
- [x] v8: tests, docs, publish ci-templates v8 {#std-v8-ship}
- [x] Windows CI job fixes (MinGit has no bash, npm PATH, arm64 NSIS only, VS ARM64 tools): x64 proven on the hosted runner, arm64 untested; GitLab minutes ran out, the user is moving to GitHub {#std-win-fix} (carried into v9 to v12 on GitHub; Windows arm64 proven in the app 1.0.0 release)
- [x] v9 GitHub only: CI as reusable workflows in fabrolabs-innovations/ci-templates on GitHub (hosted runners: ubuntu amd64 and arm64, windows x64 and arm64, macOS), release.sh through gh (assets on the Release, no package registry), secrets repo and kicad-library through a deploy key, private repos: macOS still built on the Mac to save minutes; GitLab frozen at v8 {#std-v9-github}
- [x] Move command-deck to GitHub (fabrolabs-innovations/command-deck, private, history and LFS) with ci-templates, the secrets repo and kicad-library, then v9 and every release tag on one commit {#std-github-command-deck}
- [x] command-deck: you run the CI setup (make secrets-ci, two deploy keys); then push main, hardware-rev3 and the tags firmware-v2.0.0, hardware-v4.0, app-v1.0.0 (one commit) and hardware-v3.0 (rev 3 branch); macOS app from the Mac {#std-github-first-releases}
- [x] Skill: scaffold --force on an existing project does not add .ci/ to .gitignore (command-deck needed it by hand); audit should flag it {#std-v9-gitignore-ci}
- [x] Skill: GitHub starts no workflow when more than 3 tags are pushed at once; bump and the docs should say to push release tags one at a time (or a make release-push that does) {#std-v9-tag-push}
- [x] bootstrap.sh installs gh {#std-bootstrap-gh}
- [x] v14: docs/decisions is no longer part of the standard (scaffold, audit, docs index, templates, tests) {#std-v14-no-decisions}
- [x] v15: app-tauri bump also sets the version in src-tauri/Cargo.toml and package.json; manufacturing.md template says the stackup is in the .kicad_pcb {#std-v15-bump-sync}
- [x] v16: ci.yml is checks.yml; make latest per part (GitHub has one Latest per repo); macOS tauri build retries once (flaky DMG step) {#std-v16-checks-latest}
- [x] v17: make teardown (a project's installs, plus shared tool versions and SDKs no other standard project records; CONFIRM=teardown) and make prune (machine-wide, caches too; CONFIRM=prune); setup records what each project uses {#std-v17-teardown}
- [x] v18: teardown also lists and removes a pio part's project-local .platformio (core_dir) and every part's release/ (hardware production/) {#std-v18-teardown-dirs}
- [x] v19: the pre-commit size check skips KiCad design files (.kicad_pcb, .kicad_sch, .kicad_pro: text, kept in plain git) {#std-v19-kicad-hook}
- [x] v20: a `latest` Release holds the newest files of every part (stable names, per-part SHA256SUMS) and carries the Latest badge; release.sh latest-sync, <part>-release-latest, a latest job in release.yml {#std-v20-latest-release}
- [x] Layout rule: one part of a kind sits in the kind's folder (firmware/, hardware/, cloud/, web/, app/); several get one subfolder each, named for the part {#std-layout-kind-folders}
- [x] scaffold.sh puts a part in its kind's folder by default (<kind folder>/<part>/ when several); audit.sh warns about parts outside it {#std-layout-tools}
- [x] v21: the zephyr check uses -DEXTRA_CFLAGS=-Werror (TF-M kept out); cloud-stop stops wrangler dev itself; the layout rule in scaffold and audit {#std-v21}
- [x] v22: the zephyr and espidf check jobs install make and mise like their build jobs (cryptoguard's first CI run: make missing in the NCS container) {#std-v22-check-setup}
- [x] v23: the workflow setup steps install only the missing make, git and curl, without upgrading the image's packages (curl broke in the NCS container) {#std-v23-apt-missing}
- [x] v24: the zephyr kind sets up inside the nRF Connect SDK CI container (its python and west, a cached NCS workspace, a curl wrapper) {#std-v24-zephyr-ci}
- [x] v24: make cf-login opens the Cloudflare token page pre-filled with the project's name and the permissions its wrangler.jsonc needs {#std-v24-cf-login-template}
- [x] v24: the Worker and site starters write a pnpm-workspace.yaml that allows wrangler's install scripts (esbuild, sharp, workerd) {#std-v24-pnpm-builds}
- [x] v24: every GitHub repo gets a description from the README's first sentence; the audit warns about one without (gh, github.com remote) {#std-v24-repo-description}
- [x] Worker names <project>-<env>-<part> like the resources (scaffold, standard.md naming table) {#std-worker-name-order}
- [x] v25: a part's commands run its setup first when a cheap ready check fails (node_modules, NCS workspace, toolchain), names unchanged {#std-v25-chain-setup}
- [x] v25: cf-login finds the account from the token when Enter is pressed, tells to pick Specific zone, Workers Tail per the log test; audit accepts the arm-gcc part Makefile {#std-v25-cf-login-audit}
- [x] v25: the cloud-worker and web-pages workflows skip deploy-staging for a production-only part (cryptoguard's main push failed on it) {#std-v25-prod-only-staging}
- [x] v26: a cloud part's release tag deploys production; the GitHub Release keeps the notes, no attached files; a push to main deploys staging only where the part has it {#std-v26-cloud-tag-deploys}
- [x] v27: every workflow's setup step installs jq when missing (cf.sh reads wrangler.jsonc with it; the cloud deploy failed without) {#std-v27-ci-jq}
- [x] v28: make ci-setup runs the whole CI setup (age key, deploy keys, repo secrets and variables) in one go; adopt and new ask whether each cloud part has staging {#std-v28-ci-setup}
- [x] v29: the secrets check counts gitleaks findings only in files git does not ignore (Next.js .next/ caches were flagged); cf-token-check checks the one token against every Worker and Pages part {#std-v29-gitleaks-ignored}
- [x] v30: CF_TOKEN_PERMS in make/project.mk adds token permissions no binding shows (realtime for a TURN app): cf-login names them, cf-token-check probes them {#std-v30-token-perms}
- [x] v31: web-pages part with web_TARGET := worker: a static-assets Worker on its custom domain only (no workers.dev, no preview URLs) {#std-v31-web-worker}
- [x] v32: the audit accepts a go or python part under firmware/ (code that runs on a device, such as an agent on a Linux board) {#std-v32-device-go}
- [x] v33: a web-pages part is a Worker only when its wrangler.jsonc has no pages_build_output_dir (the scaffold writes a Pages one); the audit keeps CubeMX folder names next to a .ioc {#std-v33-pages-detect}
- [x] v34: a web part is a static-assets Worker on its custom domain by default (--domain); Pages only on request (--pages); new and adopt ask the domain {#std-v34-web-worker-default}
- [x] v35: circuitpython build opens build/ to the image user, so CI (Linux) can write the images (orphea release failed) {#std-v35-cpy-out-perms}
- [x] v36: CF_TOKEN_PERMS := access puts Access: Apps and Policies Edit in the one project token (cf-login names it, token-check probes it) {#std-v36-access-perm}
- [x] v37: CF_TOKEN_PERMS := access also asks for Access: Service Tokens Edit, so a project can create its Access app and service token from make {#std-v37-access-tokens}
- [x] v38: CF_TOKEN_PERMS := access also asks for Access: Organizations, Identity Providers, and Groups Read (the team domain for ACCESS_CERTS) {#std-v38-access-org}
- [x] v39: cf-secrets skips the key-file rows of secrets.schema (env keys, names with -) instead of refusing them {#std-v39-cf-secrets-keys}
- [x] v40: smoke falls back to public DNS (DoH) when this machine cannot resolve a just-attached custom domain {#std-v40-smoke-dns}
- [x] 1.0: the standard restarts at version 1.0 (skill, headers, make/VERSION, @v1.0); ci-templates is one commit tagged v1.0 {#std-1-0}
- [x] 1.1: LFS only for 3D and CAD models (step, stp, wrl, fcstd); images, video, zip and hex in plain git; a big file goes to LFS by name {#std-1-1-lfs}
- [x] 1.2: secrets.schema app signing lines only for the app kinds in PARTS; Cloudflare lines and token check for an OTA-only project; doctor warns (not errors) on optional secrets {#std-1-2-secrets-fit}
- [x] 1.3: runs-on from vars.STD_RUNNER (Linux) and vars.STD_RUNNER_WINDOWS (app-tauri Windows), so CI can run on self-hosted runners on this Mac {#std-1-3-runner-var}
- [x] 1.4: macOS jobs on vars.STD_RUNNER_MACOS and linux-arm64 jobs on vars.STD_RUNNER_LINUX_ARM, so every job can run on this Mac {#std-1-4-runner-all}
- [x] 1.5: cf-backup, cf-wipe and cf-destroy reach a D1 by name through --env, so an adopted Worker with a local placeholder id backs up {#std-1-5-d1-env}
- [x] 1.6: cf-provision creates the OTA bucket (OTA_BUCKET, <part>_OTA_BUCKET), also in a project whose only Cloudflare resource it is; OTA_PUBLIC turns on its r2.dev URL {#std-1-6-ota-provision}
- [x] 1.7: CI_TEMPLATES_REPO names the reusable workflows' repo apart from the project owner (default mayankgautam-me/ci-templates, public) {#std-1-7-ci-templates-repo}
- [x] 1.8: a project can name its own secrets repo (SECRETS_DIR, SECRETS_REMOTE in make/project.mk); secrets-init starts a new one with this Mac's and the recovery recipients {#std-1-8-secrets-per-owner}
- [ ] Adopt the 12 Fabrolabs projects, simple ones first, one branch each: command-deck done; next waits on you {#std-fabrolabs-adopt}
- [x] Every firmware build signs with the real key (Touch ID on each build), not only release: your choice {#std-signing-choice}
- [x] App release recipes (android, flutter, tauri, xcode) need CONFIRM=production before publishing {#std-release-guard}
- [x] CI release jobs extend .std-secrets so SECRETS_DIR is set {#std-ci-secrets-dir}
- [x] bats: lint for unguarded publishing lines, CI .std-secrets extends, app release refused without CONFIRM; 257 pass; ci-templates need re-publishing to fabrolabs/ci-templates {#std-release-tests}
- [x] tools.md and SKILL.md: release confirmation, and CONFIRM=erase / CONFIRM=fuse {#std-release-docs}
- [x] 1.1: silabs firmware kind (Simplicity SDK + WiseConnect, slc, Commander) and upstream Zephyr in the zephyr kind {#std-1-1-silabs}
- [x] 1.1: <part>-power firmware target (SiLabs AEM, PPK2, Joulescope) {#std-1-1-power}
- [x] 1.1: altium kind: LFS-locked Altium files, ignore lines, OutJob-based release, CI check {#std-1-1-altium}
- [x] 1.1: mechanical kind (FreeCAD): check, STEP/STL export, release assets {#std-1-1-mechanical}
- [x] 1.1: docker/GHCR: registry follows origin's owner, OCI source labels, ghcr login in setup, write:packages check {#std-1-1-ghcr}
- [x] 1.1: references manifest docs/references.md and make refs-fetch {#std-1-1-refs}
- [x] 1.1: project-local KiCad library (hardware_LIBRARY := local) and per-project KICAD_LIBRARY_PROJECT {#std-1-1-local-lib}
- [x] 1.1: audit.sh quotes paths with spaces, better slugs, reports folders with dots and underscores {#std-1-1-audit-fixes}
- [x] 1.1: adopt from a GitLab origin: create the GitHub repo, mirror branches and LFS, switch origin {#std-1-1-gitlab-move}
- [x] 1.1: scaffold, standard.md, tools.md, contract.md, SKILL.md, version 1.1, tests {#std-1-1-integrate}
- [x] 1.1: publish ci-templates v1.1 tag {#std-1-1-publish}
- [x] Adopt i2sage-technologies/corelink on adopt-standard (Altium board, silabs firmware not started, FreeCAD case); merge into main waits on you {#std-corelink-adopt}
- [x] 1.2: docs/references.md is a list of links only; refs-fetch, refs-check, refs.sh and references/ removed {#std-1-2-refs-links}
- [x] 1.2: audit asks for the *.wrl LFS line only with a KiCad hardware part {#std-1-2-wrl}
- [x] 1.2: scaffold writes project.mk comments on their own line (no trailing spaces in values) {#std-1-2-projectmk-comments}
- [x] 1.2: altium: *.PrjPcb and *.OutJob -text, *.PrjPcbVariants in lockable LFS {#std-1-2-altium-text}
- [x] 1.2: silabs kind: pinned WiseConnect in setup, sdk_version and slt Java lookups, slc --overwrite-all, board stripped, pinned GCC, test verb, Commander needed for the .rps {#std-1-2-silabs}
- [x] 1.2: publish ci-templates v1.2 tag {#std-1-2-publish}
- [x] 1.3: audit accepts a silabs part's tests/Makefile (the test verb's), like arm-gcc's Makefile {#std-1-3-silabs-tests-makefile}
- [x] 1.3: silabs .rps: find what makes the post-build (slcp component, Commander), fix the kind's message and release path {#std-1-3-silabs-rps}
- [x] 1.3: silabs: note the slc toolchain exclusivity warning (toolchain_gcc vs wiseconnect_toolchain_gcc_standard) and the slcp fix {#std-1-3-silabs-toolchain}
- [x] 1.3: scaffold --force on an existing repo does not suggest git init {#std-1-3-scaffold-hint}
- [x] 1.3: audit warns on trailing comments after := in an existing make/project.mk {#std-1-3-audit-projectmk-comments}
- [x] 1.3: publish ci-templates v1.3 tag and update CoreLink {#std-1-3-publish}
- [x] 1.9: app-flutter CI installs the project's Flutter (flutter_version from <part>_FLUTTER_VERSION, subosito/flutter-action on the runner; no 3.44 image) {#std-1-9-flutter-ci}
- [x] 1.9: app-flutter check/format only the part's own Dart files, never build/ or .dart_tool/ {#std-1-9-flutter-format}
- [x] 1.9: tests, publish ci-templates v1.9 tag {#std-1-9-publish}

## Workbench {#workbench}
tech: zsh, Brewfile, defaults, symlinks
files: [Brewfile, home/**, macos/**]
needs: [bootstrap, instructions, settings]
- [x] Design agreed with you: layout, name, apps, macOS settings, Terminal, git, SSH, history {#workbench-design}
- [x] Work emails for the Fabrolabs and I2Sage git files {#workbench-emails}
- [x] Create ~/.workbench with the new layout and a fresh initial commit {#workbench-repo}
- [x] Brewfile with the agreed formulas, casks and App Store apps {#workbench-brewfile}
- [x] home/: dotfiles, XDG git config with includeIf, ssh config {#workbench-home}
- [x] macos/: defaults.sh and the Terminal profile import {#workbench-macos}
- [x] claude/: move the tracked ~/.claude files, link them back, re-add the mods marketplace {#workbench-claude}
- [x] Drop NotchNook's hooks from settings.json {#workbench-notchnook}
- [x] bootstrap.sh all | apps | home | macos | claude | check, and a pre-commit home-path guard {#workbench-bootstrap}
- [x] README and the CLAUDE.md sections "Dotfiles" and "This setup is a git repo" rewritten {#workbench-docs}
- [x] Push to github.com/mayankgautam-me/workbench; `check` reports a clean Mac but for TextEdit {#workbench-publish}
- [x] The GitLab project is deleted {#workbench-gitlab}
- [ ] TextEdit plain text: run `bash ~/.workbench/macos/defaults.sh` from Terminal (Claude's shell cannot write TextEdit's sandboxed settings) {#workbench-textedit}

## decisions
- 2026-11-07: every firmware build is signed with the real key, so the image tested is the image shipped; it costs a Touch ID per build
- 2026-11-07: one command set per stage of work for every project, from the project-standard skill; secrets live encrypted in one private repo, unlocked by a Secure Enclave key
- 2026-10-11: versions are recorded and checked, not pinned, because the installers cannot pin
- 2026-10-11: the map is drawn only for a project with a PLAN.md; the folder grid was removed
- 2026-10-11: Tokyo Night with amber for what is being worked on now
- 2026-10-11: the map runs top to bottom at every width; a left-to-right flow had to be scaled down and a mod's drawing cannot zoom
- 2026-10-11: the panel is the map alone, tasks inside the cards: no header, agent list or file tree
- 2026-10-11: the map is also the live view: a session card and per-card agent rows and files came back, as map elements
- 2026-10-11: a row's cards share the full width, so cards no longer sit in fixed columns under what they need
- 2026-10-11: `links:` stay in the format but are not drawn; their dotted lines read like agent trails
- 2026-10-11: the git graph is native rows with one small SVG graph cell each, so a row can be pressed; a single drawing cannot take clicks
- 2026-10-11: every git action in the graph shows its exact command and waits for Run; nothing runs on one press
- 2026-10-11: task groups are unfolded from a row above the map, not by pressing a card: the map is one drawing and cannot take presses
- 2026-10-11: the git graph's messages are its own toast above the prompt; the app's own toast sits at the top right and cannot be styled
- 2026-10-11: merge, rebase and pull from the graph take uncommitted changes along with `--autostash`, and pull always merges
- 2026-10-11: published as gitlab.com/mayankgautam_me/claude-code-setup under GPL-3.0, from one fresh commit; the earlier history stays in the private project
- 2026-10-11: the README images are generated from demo content, not captured: a capture would show a real session, and the app's window cannot be captured from here
- 2026-11-14: the setup became workbench (github.com/mayankgautam-me/workbench, at ~/.workbench), the whole Mac and not only ~/.claude, from one fresh commit; the earlier history stays on GitLab until that project is deleted
- 2026-11-14: ~/.claude's files are symlinks into claude/, settings.json included; an app that replaces the link is caught by `check` and folded back by `bootstrap.sh claude`
- 2026-11-14: the Brewfile is the bare minimum; a project's tools come from its own `make setup`
