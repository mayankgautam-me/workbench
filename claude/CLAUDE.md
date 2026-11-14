# Global instructions

## This machine

- Apple Silicon Mac, zsh, Homebrew at `/opt/homebrew`.
- Install software with Homebrew (`brew install`, `brew install --cask`) rather than downloading installers.
- Node and Python are managed by mise, not Homebrew. Use `mise use <tool>@<version>` inside a project for a project-specific version and `mise use -g` for the global default. Never use `sudo` with `npm` or `pip`.
- `ls`, `cat` and `vim` are aliased to `eza`, `bat` and `nvim` in interactive shells. In scripts and when parsing output, call `/bin/ls` and `/bin/cat`.
- Also installed: `rg`, `fd`, `fzf`, `zoxide`, `jq`, `tmux`, Neovim.

## Dotfiles

- Shell: `~/.zshrc`. Prompt: `~/.config/starship.toml`. tmux: `~/.tmux.conf`. Neovim: `~/.config/nvim/init.lua`.
- Also `~/.zprofile`, git at `~/.config/git/` (one config, a commit email per folder through `includeIf`), mise at `~/.config/mise/config.toml`, ssh at `~/.ssh/config`.
- Terminal is Apple's Terminal.app with a profile named "Tokyo Night" and the Maple Mono NF font. The profile is kept at `~/.workbench/macos/Tokyo Night.terminal`.
- Every one of these is a symlink into `~/.workbench/home/` (see "This setup is a git repo"). Edit them in place and keep their existing structure and comments; that edits the repo. Verify a shell change with `zsh -ic exit` before reporting it done.

## Preferences

- Visual style: minimal but detailed. Plain coloured text, no boxes, pills, heavy borders or decorative backgrounds. Tokyo Night colours.
- For anything visual (terminal, prompt, UI), look at the real result with a screenshot before saying it looks right. Do not judge appearance from config alone.
- When a choice is a matter of taste (fonts, themes, layouts), ask with a few concrete options instead of guessing.
- Keep replies short and lead with the result.

## Git

- Do not add a `Co-Authored-By` line or any other Claude attribution to commit messages.
- Do not add a "Generated with Claude Code" line or any other Claude attribution to pull request descriptions.
- Always ask me which branch to work on. In a project's git repository, before the first change of a piece of work, say which branch is checked out and ask, with these as options: stay on it, commit to `main`, or a new branch (suggest a name). Never choose for me, and never commit to `main` unless I picked it for this piece of work.
  - Ask once for a piece of work, not before each commit, and again when I start something new or the branch changes under us.
  - Agents work in worktrees on branches of their own; the question is which branch their work is brought into.
  - An answer in one project or session does not carry to another.
  - The one exception is `~/.workbench` (which holds `~/.claude`'s files), committed and pushed to `main` as said below.

## Security settings

- I run commands that need `sudo` or change security settings myself. Give me the exact command in a code block and say what it does and how to undo it. `settings.json` denies `Bash(sudo *)` to enforce this.
- Touch ID is enabled for `sudo`, including inside tmux (`/etc/pam.d/sudo_local`).

## This setup is a git repo

- `~/.workbench` is the git repo that sets up this Mac and a new one, and it is public: github.com/mayankgautam-me/workbench. `bootstrap.sh` there has the steps (`all | apps | home | macos | claude | check | lock`); `zsh ~/.workbench/bootstrap.sh check` lists what has drifted. Its own guide for Claude is `~/.workbench/.claude/CLAUDE.md`.
- It holds the `Brewfile` (the bare minimum: a project's tools come from its own `make setup`), `home/` (dotfiles, each linked to the same path under `~`), `macos/` (`defaults.sh` and the Terminal profile) and `claude/`, linked into `~/.claude`: this `CLAUDE.md`, `settings.json`, `mods/`, `hooks/`, `skills/project-profile/`, `skills/project-standard/`, `skills.txt`, `versions.lock`. Editing any of those files through `~` or `~/.claude` edits the repo.
- A new app goes into the `Brewfile`, a new dotfile into `home/` (then `bootstrap.sh home` links it), a new macOS setting into `macos/defaults.sh`'s table.
- The images in `claude/docs/screenshots` are generated from the mods' own output with demo content. After changing how a mod looks, run `zsh ~/.workbench/claude/docs/screenshots/make/make.sh` and commit the new images.
- Everything committed here is published. Never commit a secret, a token, an absolute path under my home folder, or the address of a private remote; use `~` or `$HOME`. The repo's pre-commit hook refuses home paths.
- After changing what a mod does, a command, or how something is installed, update the README that describes it in the same commit (`README.md`, or `claude/README.md` for the Claude part).
- After changing any tracked file, commit it in `~/.workbench` with a short message and push to `origin main` without asking. Stage files by name: other sessions may be editing the same checkout.
- After installing or removing a skill in `~/.claude/skills`, update `claude/skills.txt` (`owner/repo@skill`, one per line) in the same commit.
- After installing, removing or updating a skill or a `claude-code-workflows` plugin, run `zsh ~/.workbench/bootstrap.sh lock` and commit `claude/versions.lock` in the same commit. It records the versions in use so another machine can tell when upstream has moved.
- After changing a mod in `~/.workbench/claude/mods`, bump its version in `plugin.json` and run `claude plugin update <mod>@local-mods`. Without that the app keeps loading the older installed copy, and `/reload-plugins` alone does not pick the change up.
- An app that rewrites `~/.claude/settings.json` can replace the link with a plain file; `bootstrap.sh claude` copies its content into the repo and relinks it. Review that diff before committing.

## Agents first

- Delegate by default. The main session plans the work, hands it to agents, checks what they return and reports to me. It does the work itself only when the work is small: a question, a lookup whose place is already known, an edit to one or two files, a handful of tool calls.
- Hand to an agent:
  - Finding out: mapping unfamiliar code, a search across many files, reading docs, research. `Explore` for code, the `research` skill's background agent for the web.
  - Building: where a route below names an agent (backend, firmware, Go, Rust, Flutter, iOS, AI), that agent does the work with the route's skills. Do not load the skill and do it in the main session instead.
  - Independent parts of one task (backend and frontend, firmware and app, several modules): one agent each, started in the same message so they run in parallel, in the background, while the main session carries on with what does not depend on them.
  - Tests for code just written, and review of finished work: an agent that did not write it.
  - Debugging with several plausible causes: one agent per cause.
- An agent that writes files in a git repository works in its own worktree (`isolation: "worktree"` on the Agent call), whether or not another agent is running, so my checkout stays as I left it until its work is checked. An agent that only reads needs none. `settings.json` starts a worktree from the current `HEAD`, so it has my unpushed commits; commit what the agent needs before starting it, since uncommitted changes do not come along.
- When the agent is done, the main session reads the worktree's diff, runs the tests there, then brings the work into the branch I am on and removes the worktree. Do not leave finished worktrees behind, and never remove one with work that is not merged without asking me.
- No worktree where it cannot work: a folder that is not a git repository, `~/.workbench` (the app loads mods and the shell loads dotfiles from this checkout), and KiCad board or schematic files.
- Two agents never write the same files. Split the work by files, or run the agents one after the other.
- Brief an agent as someone who has seen none of the conversation: the goal, the files or area, what is already ruled out, what done looks like, and what to send back.
- An agent's report is a claim, not a result. Read the diff or run the tests before telling me something is done, and tell me what was not checked.
- The main session keeps `PLAN.md`: it writes the tasks before agents start, marks them as their work comes back, and agents do not edit the file.
- Say in one line which agents were started and what each is doing, so I can follow them on the project map.
- This is about subagents. Agent teams and multi-agent workflows spend far more and stay on request, as under "Rarely used".

## Skill routing

A session-start hook (`~/.claude/hooks/detect-project.sh`) prints a "Project profile" naming the agents and skills for the current project. Follow it; `project-profile` re-runs it. The hook has no route text of its own: it prints the lines below that end in a marker such as `<!--route:flutter-->`, read from this file. Change a route here only, keep its marker on the line, and run `bats ~/.workbench/claude/hooks/tests` afterwards.

Load the listed skill, or hand off to the listed agent, before starting the matching task. A skill or style I name in the request always wins. Where two installed skills do the same job, use the one listed here. Sections 1 to 7 are my main kinds of work; the rest apply across all of them.

### 1. Analysing an existing project

- Read first and report; change nothing until I ask.
- Mapping an unfamiliar codebase: the `Explore` agent, then `code-documentation:code-explain` for the parts that need explaining.
- Architecture assessment: the `comprehensive-review:comprehensive-review-architect-review` agent.
- Tech debt inventory: `code-refactoring:tech-debt`. Outdated or risky dependencies: `security-scanning:security-dependencies`.
- Security posture, only when I ask for it: `security-audit`.
- Significant design decisions found or made during analysis: record them with `documentation-generation:architecture-decision-records`, only when I ask for a write-up.
- If the project has no `CLAUDE.md`, offer `init` at the end.

### 2. Backend, frontend and database

- New backend feature end to end: `backend-development:feature-development`. Across frontend, backend and database: `full-stack-orchestration:full-stack-feature`.
- API design: `backend-development:api-design-principles`, then `documentation-generation:openapi-spec-generation` for the spec. Service boundaries: `backend-development:architecture-patterns`, `backend-development:microservices-patterns`.
- Event sourcing / CQRS: `backend-development:event-store-design`, `backend-development:cqrs-implementation`, `backend-development:projection-patterns`, `backend-development:saga-orchestration`.
- Temporal and durable workflows: `backend-development:workflow-orchestration-patterns`.
- Schema design and migrations: the `backend-development:backend-development-backend-architect` agent. Slow SQL and indexing: `developer-essentials:sql-optimization-patterns`.
- Auth, sessions, OAuth: `developer-essentials:auth-implementation-patterns`. Error handling design: `developer-essentials:error-handling-patterns`.
- Next.js App Router: `frontend-mobile-development:nextjs-app-router-patterns`. <!--route:nextjs-->
- React state: `frontend-mobile-development:react-state-management`. Tailwind: `frontend-mobile-development:tailwind-design-system`.
- Scaffolding a React component with tests: `frontend-mobile-development:component-scaffold`.
- Svelte / SvelteKit: `svelte-core-bestpractices` and `svelte-code-writer`.
- Go services: the `systems-programming:golang-pro` agent with `systems-programming:go-concurrency-patterns`. <!--route:go-->
- Rust services: the `systems-programming:rust-pro` agent with `systems-programming:rust-async-patterns`; new Rust project: `systems-programming:rust-project`. <!--route:rust-->

### 3. Hardware: KiCad, firmware and debugging

- Pick the firmware route from the project files, and ask me which MCU family when they don't make it clear:
  - `*.ioc`, a linker script, or a `thumbv*` target (STM32, nRF52, SAMD, Teensy): the `arm-cortex-microcontrollers:arm-cortex-expert` agent. <!--route:cortex-m-->
  - `west.yml` or `prj.conf` (Zephyr): the `arm-cortex-microcontrollers:arm-cortex-expert` agent when the SoC is Cortex-M, such as nRF91. <!--route:zephyr-->
  - `sdkconfig` or `idf_component.yml` (ESP32 / ESP-IDF): the `systems-programming:c-pro` agent with `systems-programming:memory-safety-patterns`. <!--route:esp-idf-->
  - `platformio.ini` or `*.ino` (Arduino / PlatformIO): the `systems-programming:cpp-pro` agent, plus the Cortex-M agent when the board is Cortex-M. <!--route:platformio-->
  - `Cargo.toml` with `no_std` (embedded Rust): the `systems-programming:rust-pro` agent with `embedded-rust`, and `systems-programming:rust-async-patterns` for Embassy. <!--route:embedded-rust-->
- Firmware bugs: `developer-essentials:debugging-strategies`.
- Firmware images, binaries and dumps: the `reverse-engineering:firmware-analyst` agent, `reverse-engineering:binary-analysis-patterns`, `reverse-engineering:memory-forensics`.
- Unknown wire or radio protocols: `reverse-engineering:protocol-reverse-engineering`.
- Any firmware work, on top of the agent above: `embedded-systems` (RTOS, peripherals, interrupts, DMA, power). <!--route:firmware-->
- Embedded Rust tooling (probe-rs, defmt, RTIC, `cortex-m-rt`): `embedded-rust`. Install its tools with Homebrew, not the `curl | sh` installers it suggests.
- Flashing and on-chip debugging over JTAG / SWD, GDB to a bare-metal target: `openocd-jtag`. <!--route:firmware-->
- Reviewing or debugging a KiCad schematic, PCB layout, Gerbers or a PDF schematic: `kicad`. It analyses and reviews; it does not draw boards. <!--route:kicad-->
- Component sourcing, pricing and BOM export: `bom`. Fabrication and assembly: `jlcpcb` by default, `pcbway` for turnkey assembly or parts not on LCSC. <!--route:kicad-->
- Never edit a board or schematic file while KiCad has it open, and ask before changing footprints or net names. <!--route:kicad-->

### 4. Research

- Research that belongs with a project (docs, API facts, library choices): `research`. It runs in a background agent, works from primary sources and saves a Markdown file in the repo.
- Research outside a project: use web search, give a link for every factual claim, and keep findings separate from inference.
- Deliver anything longer than a screen as a document, not chat. Charts: `dataviz`.
- Research on a codebase rather than the web goes through section 1.

### 5. AI pipelines

- LLM application work in general: the `llm-application-dev:ai-engineer` agent. <!--route:ai-->
- Anything calling the Claude API: `claude-api`. <!--route:ai-->
- RAG: `llm-application-dev:rag-implementation`. Embeddings and vector search: `llm-application-dev:embedding-strategies`, `llm-application-dev:similarity-search-patterns`, `llm-application-dev:vector-index-tuning`.
- Prompts: `llm-application-dev:prompt-optimize`. Evals: `llm-application-dev:llm-evaluation`. Agents on LangGraph: `llm-application-dev:langchain-agent`.
- Fine-tuning: `llm-finetuning:finetune` (eval harness first). Re-gating a checkpoint: `llm-finetuning:promote-checkpoint`.
- ML training and deployment pipelines: `machine-learning-ops:ml-pipeline`. <!--route:ml-->
- Data pipelines: `data-engineering:data-pipeline`. dbt, Airflow, Spark: `data-engineering:dbt-transformation-patterns`, `data-engineering:airflow-dag-patterns`, `data-engineering:spark-optimization`. Data checks: `data-engineering:data-quality-frameworks`. <!--route:data-->

### 6. IoT devices, platform and applications

- Device firmware follows section 3; companion apps follow section 7; the cloud side follows section 2.
- Device-to-cloud architecture (ingest, device registry, OTA, commands): `backend-development:architecture-patterns`, with `backend-development:saga-orchestration` for multi-step flows such as OTA rollout.
- Telemetry ingest and storage: `data-engineering:data-pipeline`.
- Device identity, provisioning and tokens: `developer-essentials:auth-implementation-patterns`.
- Threat model for any new device or platform design: `security-scanning:stride-analysis-patterns`, then `security-scanning:threat-mitigation-mapping`.
- MQTT topics, QoS, retained messages, broker setup: `mqtt-development`. <!--route:mqtt-->
- Platforms that store personal or customer data (GDPR, SOC 2, HIPAA): `security-compliance:compliance-check`.
- Debugging traffic between device and cloud: `reverse-engineering:protocol-reverse-engineering`.

### 7. Multiplatform apps (web, Android, iOS, iPadOS, macOS, tablets)

- Pick the route from the project files. For a new app with no stack chosen, ask me which stack.
  - `pubspec.yaml` (Flutter): the `multi-platform-apps:flutter-expert` agent. <!--route:flutter-->
  - Expo or `react-native` in `package.json`: the `multi-platform-apps:multi-platform-apps-mobile-developer` agent, `frontend-mobile-development:react-native-architecture`, `ui-design:react-native-design`. <!--route:react-native-->
  - `*.xcodeproj` or `Package.swift` (Swift / SwiftUI): the `multi-platform-apps:ios-developer` agent and `ui-design:mobile-ios-design`. Check the result in the iOS Simulator. <!--route:swift-->
  - Gradle with Compose (Kotlin): the `multi-platform-apps:multi-platform-apps-mobile-developer` agent and `ui-design:mobile-android-design`. <!--route:android-->
  - `src-tauri/` (Tauri): `tauri-development`, with the `systems-programming:rust-pro` agent for the Rust side. The skill assumes a React front end; when the project uses Svelte, take only its Tauri and Rust guidance. <!--route:tauri-->
  - `svelte.config.js` or any `.svelte` file (Svelte / SvelteKit): `svelte-core-bestpractices`, and `svelte-code-writer` to look up docs and run the autofixer before finishing a component. <!--route:svelte-->
- Phone, tablet and desktop layouts from one codebase: `ui-design:responsive-design`.
- One feature shipped across several platforms at once: `multi-platform-apps:multi-platform`.

### Design and UI

- New frontend or UI work where I haven't named a style: ask me which design skill to use before writing any code, then load only that one. Offer these four:
  - `minimalist-ui`: warm off-white, serif headlines, flat, hairline borders.
  - `design-taste-frontend`: neutral sans, one accent colour, working mini-components, light and dark.
  - `high-end-visual-design`: dark, glass, glow, bezelled cards, heavier motion.
  - `industrial-brutalist-ui`: paper and ink with hazard red, huge uppercase type, mono body, visible grid.
- Ask once per project, not per component; reuse the answer for later UI work in the same project.
- Redesigning or upgrading an existing site or app: `redesign-existing-projects` (audit first, keep functionality).
- Logos, brand kits, identity boards: `brandkit`.
- Google Stitch work or a `DESIGN.md` file: `stitch-design-taste`.
- Design tokens or a new design system: `ui-design:design-system-setup`. A single component: `ui-design:create-component`.
- Reviewing existing UI: `ui-design:design-review`. Accessibility / WCAG: `ui-design:accessibility-audit`.

### Security

- Full audit or pen test of a codebase: `security-audit`.
- Security check of pending changes on a branch: `security-review`.
- Static analysis: `security-scanning:security-sast`. Dependency vulnerabilities: `security-scanning:security-dependencies`. Hardening pass: `security-scanning:security-hardening`.
- XSS in frontend code, only when I ask: `frontend-mobile-security:xss-scan`.
- Compliance (GDPR, SOC 2, HIPAA): `security-compliance:compliance-check`.

### Review, refactoring and debugging

- Reviewing a diff or PR: `code-review`. Multi-dimension review of a whole change: `comprehensive-review:full-review`.
- PR description and checklist: `comprehensive-review:pr-enhance`.
- Cleanup of code I just changed: `simplify`. Larger refactor: `code-refactoring:refactor-clean`.
- Errors and stack traces: `error-debugging:error-analysis`. Bugs with several plausible causes: `developer-essentials:debugging-strategies`.
- Adding logging, alerts, error tracking: `error-debugging:error-trace`.

### Testing

- Unit tests: `unit-testing:test-generate`. End-to-end: `developer-essentials:e2e-testing-patterns`. Shell scripts: `shell-scripting:bats-testing-patterns`.

### Shell, Git, monorepos and docs

- Shell scripts: `shell-scripting:bash-defensive-patterns`, and lint with `shell-scripting:shellcheck-configuration`.
- Rebase, bisect, worktrees, history surgery: `developer-essentials:git-advanced-workflows`.
- Monorepos: `developer-essentials:monorepo-management`, plus `developer-essentials:nx-workspace-patterns`, `developer-essentials:turborepo-caching` or `developer-essentials:bazel-build-optimization` for the tool in use.
- Generating docs: `code-documentation:doc-generate`.
- ADRs: `documentation-generation:architecture-decision-records`. Changelogs: `documentation-generation:changelog-automation`. OpenAPI specs: `documentation-generation:openapi-spec-generation`.

### This setup

- Making, changing or debugging a mod in `~/.workbench/claude/mods`: `plugin-authoring`.
- Changing `settings.json`, permissions or hooks: `update-config`.

### Project standard

- Every project uses the `project-standard` skill's layout and `make` commands, one set per stage of work (setup, dev, test, Cloudflare, secrets, deploy, CI, firmware, hardware, release). In a standard project, run its `make` commands (`make help` lists them) instead of calling wrangler, west, idf.py, pio, kicad-cli, flutter or gradle directly, and keep every secret in the encrypted secrets repo through `make secrets-*`, never in the project. A new project starts from the skill's `new` mode. A project not on the standard: say so once and offer the skill's `adopt` mode; change nothing until I ask. <!--route:standard-->
- `ENV=local|staging|production`; anything touching production, and every destroy, wipe, reset or erase, needs `CONFIRM=<env>` from me. Never add `CONFIRM` on my behalf.

### Projects with a PLAN.md

- A `PLAN.md` at the project root lists the project's components and their tasks; the `agent-map` mod draws it as the project map and re-reads it whenever it is edited.
- `PLAN.md` comes first, without my asking. Before writing any code or files for a piece of work, put the work into `PLAN.md`: its tasks as `- [ ]` under the right component, a new component with its `files:` globs where the work is a new part of the project, and globs for any new files. Only then start, so the project map shows the work while it happens.
- Then mark as the work goes: `- [~]` on the task being worked on right now, `- [x]` the moment it is finished and checked, one task at a time. Not all at the end.
- `- [~]` means being worked on now, by me or by you in this turn. Before ending a turn, look at every `- [~]` in the file: one whose work is finished becomes `- [x]`, one that is waiting on me or put aside goes back to `- [ ]` (say what it waits on in the task line), and only work that really continues in the next turn stays `- [~]`. The map shows these as in progress, so a stale one reads as work that is not happening.
- A change is not finished until `PLAN.md` matches it: work that grew beyond the tasks written first gets its tasks added as soon as that is clear.
- If a task cannot be done, mark it `- [!]` and say why in the task line.
- Change only the marks of the tasks being worked on. Add a task or a component only when the work is not covered by an existing one, and ask before removing any.
- Keep the file in the format the map reads. Anything else is ignored by the map, so a component written another way silently disappears from it:
  - A component is a heading `## Name {#id}`, the id made of letters, digits, `-` and `_` and unique in the file. A `##` heading without `{#id}`, such as `## decisions`, is not drawn.
  - Under it, one per line and not as list items: `tech: ...`, `files: [glob, glob]`, `needs: [id, id]` (drawn as arrows from what it depends on), `links: [id]` (a looser relation, kept in the file but not drawn), `kind: ...`.
  - Tasks are list items directly under the component: `- [ ] text {#task-id}`, with `[~]` in progress, `[x]` done, `[!]` blocked.
  - `files:` globs are relative to the project root, `**` for any depth. The first component that claims a file gets it; a file no component claims shows on an "Unplanned files" card.
- Keep it true to the project while working, in the same change as the work:
  - A new file or folder that no glob covers: add it to the right component's `files:`, or add a component for it.
  - A file or folder renamed, moved or deleted: fix the globs that named it.
  - A component added, renamed or removed: fix every `needs:` and `links:` that names its id, and never leave one pointing at an id that does not exist.
  - A new dependency between components: add it to `needs:`.
- When I ask for a `PLAN.md` in a project that has none, or run `/map init` (which sends that request with the format spelled out), write it in this format from the project's real structure: one component per part I would name when describing the project, usually 4 to 12, each with globs that together cover the tracked files.
- The `agent-map` mod checks the file mechanically after every edit to it and adds what the map cannot read to the edit's result, as `PLAN.md:<line>: error: ...` or `note: ...`. Fix every error before moving on; a note (a glob that matches no file, a component with no `files:`) needs a look and a fix only if it is stale. `/map check` runs the same check on demand.
- If a `PLAN.md` exists but is not in this format, say so and ask before rewriting it.
- Plan mode (`/plan`) feeds the file. Once I approve a plan, the first step of carrying it out is to put it in `PLAN.md`:
  - Where the project has one: add the plan's steps as `- [ ]` tasks under the components they touch, a new component only where none fits, and new files' globs as above.
  - Where it has none: create it in this format from the project's real structure, with the approved plan's steps as the tasks.
  - Then work through those tasks, marking them as above. The plan-mode write-up itself stays where plan mode keeps it; `PLAN.md` holds the components and tasks, not the prose.

### Rarely used

- Agent teams, only when I ask for a team or parallel agents: `agent-teams:team-feature`, `agent-teams:team-review`, `agent-teams:team-debug`.
- Finding a skill I don't have yet: `find-skills`.
