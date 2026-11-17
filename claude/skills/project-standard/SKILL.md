---
name: project-standard
description: One set of `make` commands per stage of work (setup, dev, test, Cloudflare, secrets, deploy, CI, firmware, hardware, mechanical, apps, release), the same in every project. Use when starting a new project or asked to "set up a project", to "make this project standard", to adopt, update or audit an existing project against the standard, when asked which make command does something, and for secrets, Cloudflare tokens and resources, CI, firmware flashing, KiCad, Altium or FreeCAD workflow questions in a project whose make/common.mk says "project-standard".
---

# Project standard

Every project gets the same commands: `make <verb>` for the whole project, `make <part>-<verb>`
for one part. The full spec (stages, commands, secrets, CI, Cloudflare token permissions, a new
Mac) is `reference/standard.md` in this skill; read the section you need before answering a
question about it. `reference/tools.md` lists every target of every part kind and the tool it runs.
`reference/contract.md` is how the pieces fit together, for changing the skill.

Skill folder: `~/.claude/skills/project-standard` (below: `$SKILL`).

Pick the mode from the request. If a folder is not standard and the user did not ask to adopt it,
offer adopt; never change it silently.

## new: a new project

1. Ask, with options (AskUserQuestion when available):
   - the project name (lowercase, `-` allowed) and the folder (default `~/Projects/<name>`);
   - the GitHub owner of its repository. Offer the user config's `GITHUB_OWNER` (`~/.config/project-standard/config.mk`,
     the default owner), the organizations `gh api user/orgs --jq '.[].login'` lists, and the personal account
     `gh api user --jq .login`. The owner decides the secrets repo: `<owner>/secrets`, checked out at `~/.secrets-<owner>` for
     every owner (`reference/standard.md` 5.1);
   - the parts, each as a name and a kind. Offer the kinds grouped:
     firmware `zephyr`, `espidf`, `pio`, `arm-gcc`, `circuitpython`, `silabs`; hardware `hardware` (KiCad),
     `altium`; mechanical `mechanical` (FreeCAD); cloud `cloud-worker`, `web-pages`; apps `app-flutter`, `app-tauri`,
     `app-xcode`, `app-android`; services `docker`, `go`, `python`. Each part's folder is its kind's folder
     (`firmware/`, `hardware/`, `mechanical/`, `cloud/`, `web/`, `app/`), or, when the project has several parts of that kind,
     `<kind folder>/<part>/` for each, several firmware parts named for their chips (`firmware/nrf9151/`, `firmware/stm32f042/`): `reference/standard.md` section 1. For firmware ask the board (and the MCU family when it
     is not obvious from the board; a SiWx917 is `silabs` on the Simplicity SDK, or `zephyr` with `<part>_ZEPHYR` on
     upstream Zephyr). For a KiCad board ask whether it uses the shared KiCad library or its own (`<part>_LIBRARY :=
     local`). An Altium board takes its parts from the shared Altium library, a git submodule at
     `hardware/altium-library` (`ALTIUM_LIBRARY`, from `ALTIUM_LIBRARY_PROJECT`, default `<owner>/altium-library`): the
     scaffold only documents it, and `make <part>-setup` adds it. For every `cloud-worker` and `web-pages` part ask whether it has a staging
     environment (a push to main deploys it) or is production-only (only its tag deploys): never assume either.
     For every `web-pages` part ask its custom domain (production; staging is `<label>-staging.<zone>`): the site is a
     static-assets Worker on that domain, its only address (no `*.workers.dev`, no preview URLs). Use Cloudflare Pages
     only when the user asks for it (`--pages <part>`); never offer Pages as the default.
2. Run the scaffold (no network, no git):
   ```sh
   $SKILL/scripts/scaffold.sh <dir> --project <name> --part <name>:<kind>[:<dir>] ...
   ```
   Add `--domain <part>=<host>` for each web-pages part (without it the route is a `CHANGE-ME` placeholder the audit
   reports), `--pages <part>` only for a site the user asked to put on Pages, `--port-base N` only if the user wants
   fixed ports, and `--production-only <part>` (repeatable) for a
   cloud-worker or web-pages part that has no staging: its CI gets no deploy-staging job (a push to main deploys
   nothing for it), and a new Worker's `wrangler.jsonc` has no `env.staging`. Every cloud-worker and web-pages part
   deploys production on its tag `<part>-v<version>` (`make <part>-bump`, then `make release-push`, which asks
   first), then gets a GitHub Release with the CHANGELOG notes only; a hotfix by hand is `release.yml` from the
   Actions tab with the part and confirm `production`, or `make <part>-deploy ENV=production CONFIRM=production`.
3. Fill what the scaffold left as a comment: the board settings in `make/project.mk`, and `OTA_BUCKET`
   (the project's own R2 bucket, in its Cloudflare account) when a part releases OTA. With `OTA_BUCKET` set the
   project uses Cloudflare even without a Worker or Pages part: add the `CLOUDFLARE_API_TOKEN` and
   `CLOUDFLARE_ACCOUNT_ID` rows to `secrets.schema` (the scaffold writes them itself when `make/project.mk` already
   sets an OTA bucket, as on adopt, and says so when a kept schema lacks them); `make cf-login` then asks for R2,
   and `make cf-provision ENV=production CONFIRM=production` creates the bucket. Add `OTA_PUBLIC := r2dev` first
   when apps download the images from the bucket's public r2.dev URL: `cf-provision` then turns it on and prints it.
4. The repository, before any secrets: the project's owner comes from its `origin`, and the secrets repo follows it.
   Show the commands and create the GitHub repository only after the user confirms (it is an outward action):
   ```sh
   git init -b main
   gh repo create <owner>/<name> --private --description "<one line: what the project is and its parts>"
   git remote add origin https://github.com/<owner>/<name>.git
   ```
   The description is the README's first sentence: a repository is never left without one (the audit warns). Do not
   commit yet; the first commit follows the Git rules (ask which branch; `main` here is fine only when the user picks
   it). Without a GitHub repository (the user declines), the owner and the secrets repo fall back to the user config's
   until `origin` is added; `make doctor` says so.
5. `make setup` (brew bundle, mise, SDKs, dependencies, hooks, LFS). Long: run it in the background
   and say so.
6. `make secrets-init`: creates `<name>/` in the project's secrets repo from `secrets.schema` and asks the user for
   each missing value in a hidden prompt. If the Mac is not enrolled yet, it says to run
   `make secrets-enroll` first; that and any Touch ID prompt are the user's to answer. For an owner whose secrets repo
   is not on this Mac yet it clones `<owner>/secrets`; when that repo does not exist, ask, then create it empty
   (`gh repo create <owner>/secrets --private --description "Encrypted secrets of <owner>'s projects (sops + age)"`):
   `secrets-init` then starts it with this Mac's and the other Macs' public recipients and the recovery key from
   another `~/.secrets-*` on this Mac, and pushes (`reference/standard.md` 5.2). A Mac that joins later runs `make secrets-enroll` in a
   project of that owner, then `make secrets-add-machine HOST=<mac>` there on an enrolled Mac (5.3).
7. `make doctor`, and report what it says is missing with the command that fixes each item. A `secrets.schema`
   row whose description starts with `optional:` (the app signing and store names, written only for the app kinds
   that read them) is a warning when missing, not a failure.
   CI reads the secrets repo and, with a hardware part, the KiCad library (with an altium part, the Altium library) with
   read-only deploy keys. Once the GitHub
   repository exists, tell the user to run `make ci-setup` (it prints no values): the CI age key (`make secrets-ci`), the
   deploy keys (made in `~/.ssh` when missing, added to the repositories), their repository secrets and the variables
   `SECRETS_REPO`, `KICAD_LIBRARY_REPO` and `ALTIUM_LIBRARY_REPO`. It is safe to run again. Do not run it yourself: it writes repository
   secrets. `make ci-setup-help` prints the same steps as commands to run by hand. A crate or tool that needs a system library in CI gets it from the
   repository variable `STD_APT_PACKAGES` (e.g. `libudev-dev` for hidapi). `make ci-local JOB=<job>` runs a job in Docker
   before pushing (partial: see `reference/standard.md` section 6).
8. `PLAN.md` is already in the map format with a `## <Part> {#id}` component per part and starter
   tasks; mark the scaffold task done and keep it current as work goes.
9. The scaffold wrote the documents, each with its headings and a one-line hint per section (`reference/standard.md`,
   "Documents"): `docs/README.md` (the index), `docs/architecture.md` (a Mermaid node per part: draw the links
   with the user), `docs/operations.md` with a cloud-worker, web-pages or docker part, `docs/references.md` (links
   to the datasheets and manuals, one line each, `- [Title (MPN) — Vendor](URL)`, under `##` headings), and per part
   `<dir>/README.md`, `<dir>/CHANGELOG.md` and the kind's docs in `docs/<part>/`. List them in the report; fill in
   what the user already said (purpose, protocol, board).
10. Report in a few lines: folder, parts, the docs created, the commands to start with (`make dev`, `make check`).

## adopt: bring an existing project onto the standard (on request, one project at a time)

Read-only until the user says yes.

1. Audit:
   ```sh
   $SKILL/scripts/audit.sh <dir>          # human; --json for parsing
   ```
2. Build the migration plan from the findings and show it:
   - **Parts**: a `name:kind[:dir]` per part, from the folders and their files (the
     `project-profile` hook output helps). Ask where the kind is unclear.
   - **Renames** to lowercase folders, parents first. macOS is case-insensitive, so each rename goes
     through a temporary name: `git mv Firmware Firmware.tmp && git mv Firmware.tmp firmware`.
     List what refers to the old paths (CI, scripts, KiCad project paths, Xcode, docs) and fix it in
     the same change.
   - **Old -> new command table** from the "targets today" list: every existing target, the standard
     command that replaces it (`make -C Firmware/Node flash` -> `make firmware-flash`), or
     "kept in make/local.mk" when it has no standard equivalent. Sub-Makefiles are removed once
     their targets are covered, except the Makefile an arm-gcc part builds through (audit leaves it alone).
   - **Owner and secrets repo**: the project's owner is its `origin`'s (`git remote get-url origin`), and its
     secrets repo `<owner>/secrets` at `~/.secrets-<owner>` (`reference/standard.md` 5.1). A pre-1.8 `~/.secrets` is
     moved by the user with the two commands of 5.4 (the secrets commands print them); never move it yourself. Name both in the plan. With no GitHub `origin`, ask the owner (as in new, step 1)
     and plan the repository the same way as new step 4 (confirm, `gh repo create`, `git remote add origin`) before
     any secret moves; a secrets repo the owner does not have yet is created empty and started by `secrets-init`.
   - **Origin not on GitHub** (the audit's `repo` error, for example a GitLab `origin`): the project moves to GitHub
     before any secrets, because its owner, secrets repo and CI follow the GitHub `origin`. Show the user the
     current remote and the steps, and run them only after the user confirms (it is an outward action):
     ```sh
     gh repo create <owner>/<name> --private --description "<one line from the README's first sentence>"
     git lfs fetch --all origin            # every LFS object of every ref, from the old host
     git remote rename origin gitlab       # the old remote stays, under its host's name
     git remote add origin https://github.com/<owner>/<name>.git
     git push origin --all && git push origin --tags
     git lfs push --all origin             # the LFS objects the push did not carry
     ```
     Then check on GitHub that the branches, tags and LFS files are there. Removing the old remote, or archiving the old
     project, is the user's decision.
   - **Altium boards** (kind `altium`): the board folder takes the standard layout (`reference/standard.md` section 1,
     4.10). `make <part>-layout` in the worktree, after the scaffold, prints the `git mv` commands and the
     `DocumentPath=` edits of the `.PrjPcb`; apply them there (the user closes Altium first; the `.PrjPcb` is text,
     the documents are LFS binaries moved as they are), then `make <part>-check` until it passes. Generated
     `outputs/` and `production/` leave the index with `git rm -r --cached`. The BOM is the OutJob's (in `outputs/`,
     1.5): a committed `bom/` folder goes, with the user's go-ahead, once the OutJob writes a BOM CSV.
   - **Secrets**: every tracked or local secret file (`.env*`, `.dev.vars`, `.prod.vars`, `secrets/`,
     `keys/`, `*.pem`, `*.p8`, `*.jks`, ...), which env and name each value moves to in
     `<project>/` of the project's secrets repo, and the `secrets.schema` lines that describe them. Never print a
     value: not in chat, not in a command line, not in a log.
   - **CI swap**: the jobs of the old `.gitlab-ci.yml` and the workflow jobs that replace them (what the scaffold
     generates: `checks.yml` and `release.yml`); a job with no template becomes a job of its own in `checks.yml`.
   - **Staging**: for every `cloud-worker` and `web-pages` part, ask whether it has a staging environment or is
     production-only, even when the old setup had a preview or dev deploy: never assume either (`--production-only <part>`).
   - **Web domain**: for every `web-pages` part, ask its custom domain (`--domain <part>=<host>`). An old Pages site
     becomes a static-assets Worker on that domain (the scaffold writes its `wrangler.jsonc` when the part has none;
     a Pages one with `pages_build_output_dir` must be replaced by hand); it stays on Pages only when the user says so
     (`--pages <part>`). The old Pages project is deleted by the user after the Worker serves the domain.
   - **Existing Cloudflare Workers** (most have production only and resource names that do not follow
     `<project>-<env>`): plan the `wrangler.jsonc` conversion below (the default for a Worker with no staging today is
     production-only; staging can be added later).
   - **Documents**: where each existing doc goes in the layout (`reference/standard.md`, "Documents"), for
     example `docs/HID_PROTOCOL.md` -> `docs/firmware/protocol.md`, a board's bring-up notes ->
     `docs/hardware/bringup.md`, a part's changelog -> `<dir>/CHANGELOG.md` (Keep a Changelog headings). Content
     is kept as it is (`git mv`, then fix the links that pointed at the old path). Committed binary documents
     (PDF, DOCX, XLSX, PPTX ...; the audit's `docs` findings) leave the index with `git rm --cached` and stay in
     history; say which are generated (a release asset from now on), which are datasheets (the shared library),
     and which need a Markdown version.
   - Anything that needs the user's own decision: rotating keys that were in git (they stay in
     history), purging history, tokens to create.
3. Ask which branch the work goes into (stay on the current one, `main`, or a new branch such as
   `adopt-standard`), as the Git rules say. Never pick for the user.
4. Apply in a worktree (an agent with `isolation: "worktree"`, or `git worktree add`), never in the
   user's checkout:
   - renames; the document moves (before the scaffold, so it keeps them and adds only the missing docs);
     `scaffold.sh <worktree> --force --project ... --part ...` (managed files are written, files the project owns
     are kept, missing docs are added: a part folder that exists gets its README and CHANGELOG, never its starter
     code; an existing `.gitignore` gets the standard's missing CI and release lines appended: `.ci/`, the ci-local
     ones, each part's `release/`); merge the old README / CLAUDE.md / .gitignore content by hand (the `.gitignore`
     needs the binary documents block, and `.gitattributes` loses its `*.pdf` / `*.xlsx` LFS lines); `git rm --cached`
     the committed binary documents;
     a part's own `.gitignore` (SvelteKit's `app/.gitignore`, a KiCad folder's) goes into the root one: add the
     lines the root lacks (the scaffold's kind lines: `.svelte-kit/`, `vite.config.*.timestamp-*`,
     `hardware/production/`, ...) and delete the part's file when the root covers it. Generated files already
     tracked (the audit's `hardware` findings for `outputs/` and `production/`) leave the index with
     `git rm -r --cached <path>`;
     write `make/project.mk` and `make/local.mk`; the CI swap. Project-wide CI settings go once under the
     top-level `variables:` (`STD_APT_PACKAGES`, `KICAD_LIBRARY_REPO`), never repeated on each job.
   - LFS: once `.gitattributes` routes step / stp / wrl / fcstd to LFS, files already committed as plain
     blobs show as modified forever (`audit.sh` lists them, area `lfs`). Check that the repository accepts LFS (a push of an LFS object
     succeeds), then `git add --renormalize .` and commit it on its
     own as "Move the binaries already tracked into Git LFS". The old blobs stay in history (purging them is a
     history rewrite: the user's decision).
   - Deploy keys: the secrets repo and, with a hardware part, the KiCad library (with an altium part, the Altium
     library) need a read-only deploy key whose private half is the project's secret. Once the GitHub repository exists and the branch is pushed, the user runs
     `make ci-setup`; Claude does not create keys.
   - KiCad: before touching any `.kicad_*` file or renaming a folder that holds one, check KiCad
     does not have it open (`pgrep -x kicad`, and no `~*.lck` / `*.lck` next to the files). If it
     is open, stop and ask the user to close it. Never change footprints or net names.
   - Altium: the board's parts come from the shared Altium library, a submodule at `ALTIUM_LIBRARY` (default
     `hardware/altium-library`). The scaffold adds no submodule; with the user's go-ahead, `make <part>-setup` adds it
     (commit `.gitmodules` and the submodule on the adopt branch), and `make <part>-lib-check` lists the parts the
     board uses that the library does not have: report them, never rewrite the board's components or its own
     `library/` to fix them. A DbLib or library path the project already uses stays as it is until the user moves it
     to the submodule's `Library.DbLib` in Altium. The audit warns while the submodule is missing.
   - Existing Workers, per cloud-worker part, before the scaffold runs (it reads `wrangler.jsonc` to find
     production-only parts):
     1. Convert `wrangler.toml` to `wrangler.jsonc` (make and `cf.sh` read only jsonc or json); remove the toml.
     2. The top level becomes local: keep `name`, `main`, `compatibility_date`, flags; give the D1 / KV
        bindings placeholder ids (`"database_id": "local"`, KV `"id": "local"`); `cf-migrate` and `cf-seed`
        read the local bindings there. `make dev` runs `wrangler dev --env local`, and wrangler does not
        inherit bindings into an env, so repeat the same bindings (and the local vars) under `env.local`.
     3. Today's production config (bindings, vars, routes, custom domains, crons, Durable Objects and their
        migrations) moves under `env.production`. Set `env.production.name` to the existing Worker's name:
        without it wrangler deploys `<name>-production`, a new Worker, while the custom domains, routes and
        Durable Object data stay bound to the existing one.
     4. Keep the existing resource names and ids as they are: `cf-provision` finds D1, R2 and queues by their
        exact name and keeps a KV binding's filled-in id, so it creates nothing for them.
     5. No `env.staging` makes the part production-only (pass `--production-only <part>` to be explicit).
     6. Before the first deploy, and only with the user's go-ahead for the production unlocks:
        `make cf-login`, `make cf-backup ENV=production`, `make cf-status ENV=production`, and from the part's
        folder `pnpm exec wrangler deploy --env production --dry-run` (`npx --no-install` without pnpm-lock.yaml) under
        `make/bin/secrets.sh exec --env production --`; compare the bindings with the live Worker. The first
        real deploy is the user's `make <part>-deploy ENV=production CONFIRM=production`.
     7. `cf-wipe` and `cf-destroy` stay refused for names without the `<project>-<env>` prefix: that is
        intended for adopted resources, not something to fix by renaming. Durable Object storage is never in
        `cf-backup`.
   - Secrets: values go in through stdin so they never appear, for example
     `while IFS='=' read -r k v; do [ -n "$k" ] && printf '%s' "$v" | make secrets-set NAME="$k" ENV=staging; done < .dev.vars`
     (`secrets-set` reads stdin when it is not a TTY). Key files go to `keys/<name>.sops`, encrypted
     straight from the file with sops in the project's secrets repo (`make secrets-doctor` names it; see "Moving an existing key" in
     `reference/standard.md`). Then `git rm --cached` the files and delete the plain copies only after
     `make secrets-list` shows them.
5. Read the worktree's whole diff, run `make help`, `make doctor` and `make check` there, and
   `audit.sh` again: it should be clean, or every remaining finding explained.
6. Bring the work into the branch the user picked, remove the worktree, update `PLAN.md`, and
   give the GitHub repository a description (`gh repo create ... --description`, or `gh repo edit <owner>/<name>
   --description` for one that exists; one line from the README's first sentence). Then
   report: what changed, the command table, what still waits on the user (key rotation, history,
   the Cloudflare token: one per project, `make cf-login` opens the pre-filled dashboard form and stores it,
   `make secrets-ci`).

## update: refresh a standard project to the skill's current version

1. `audit.sh <dir>`; the `outdated` findings are what changes.
2. Ask which branch, then work in a worktree as in adopt.
3. Re-copy the managed files from `$SKILL/templates`: `Makefile`, `make/common.mk`, `make/bin/*.sh`,
   `make/kinds/<kind>.mk` for the kinds in `PARTS`, `make/VERSION`. Never touch `make/project.mk` or
   `make/local.mk`. If a managed file was edited by hand (the diff shows project-specific lines),
   move those lines into `make/local.mk` first and say so.
4. In the workflows, set each `uses:` line to `<CI_TEMPLATES_REPO>/.github/workflows/<kind>.yml@v<n>`: the
   repository the audit names (`CI_TEMPLATES_REPO`, default `mayankgautam-me/ci-templates`, independent of
   `GITHUB_OWNER`; a line on the pre-1.7 `<owner>/ci-templates` is reported outdated) and the current version tag
   (`v` + `make/VERSION`); and add jobs for kinds that were added.
   From v1.5 to v1.6: re-copy the managed files and set every `uses:` line to `@v1.6`. A cloud-worker or web-pages
   part behind Cloudflare Access whose `secrets.schema` declares `CF_ACCESS_CLIENT_ID` now passes its smoke with it.
   From v1.4 to v1.5: re-copy the managed files and set every `uses:` line to `@v1.5`. An altium part's BOM is now
   the one its OutJob writes (`<dir>/outputs/**/*BOM*.csv`, plus `.xlsx`), not `bom/<Board>_BOM.csv`: check that the
   OutJob has a CSV Bill of Materials output (`BOM` in its name) and `make <part>-build` passes after it ran, then,
   with the user's go-ahead, `git rm -r <dir>/bom` and commit. Until then check, doctor and the audit only warn.
   From v1.3 to v1.4: re-copy the managed files and set every `uses:` line to `@v1.4`. For an altium part, add
   `ALTIUM_LIBRARY_DEPLOY_KEY: ${{ secrets.ALTIUM_LIBRARY_DEPLOY_KEY }}` to its job's `secrets:` in `checks.yml`, run
   `scaffold.sh <worktree> --force` (it writes `docs/<part>/library.md` and adds `.venv/` to `.gitignore`), then, with the
   user's go-ahead, `make <part>-setup` adds the Altium library submodule (commit `.gitmodules` and it), and the user
   runs `make ci-setup` again for its deploy key and `ALTIUM_LIBRARY_REPO`.
   From v1.2 to v1.3: re-copy the managed files and set every `uses:` line to `@v1.3`. A silabs part gets the 1.3
   kind: `slc generate` without `--toolchain gcc` (it made WiseConnect's and the SDK's `toolchain_gcc` clash), and
   `POST_BUILD_EXE=<commander>` for the `.slcp`'s post-build. If the part publishes the `.rps` (an OTA bucket, or the
   release attaches it), add the two top-level lines `post_build:` and `  profile: wiseconnect_soc` to its `.slcp`
   (WiseConnect's own `.rps` step; it is not a component); ask before adding them to a project that does not publish
   one, since the build then needs Commander. 1.3 setup installs Simplicity Commander through slt
   (`commander/<part>_COMMANDER`, `1.25.0`): re-run `make <part>-setup` on each Mac (and the runners get it from their
   setup) to get it; a `<part>_SLT_INSTALL` in `make/project.mk` overrides the default, so add
   `commander/$(<part>_COMMANDER)` to it or remove it if it only repeats the old default.
   Remove a `<part>_SLC_ARGS := --toolchain gcc`, or a `POST_BUILD_EXE` in `make/local.mk`, that only worked around
   1.2. A `<dir>/tests/Makefile` (or `test/`) of a silabs part is no longer a sub-Makefile finding. Then run the audit:
   every `make` finding is a `make/project.mk` or `make/local.mk` assignment with a trailing `# comment`; list them and,
   with the user's go-ahead (both files are the project's, step 3), move each comment onto its own line above.
   From v1.1 to v1.2: re-copy the managed files, delete `make/bin/refs.sh` (a managed file 1.2 removed; `make
   refs-fetch` and `refs-check` are gone) and set every `uses:` line to `@v1.2`. Convert a `docs/references.md` table
   to links: one line per row, `- [Title (MPN) — Vendor](URL)`, under `##` headings (datasheets by category, then per
   vendor or module), keeping Title, Vendor and URL and dropping File and SHA256; remove the `references/` line (and
   its comment) from `.gitignore`, and delete a local `references/` folder only when the user says so.
   `scaffold.sh <worktree> --force` with the project's parts then adds what 1.2 needs and changes nothing else:
   `*.wrl` in `.gitattributes` with a hardware part, and with an altium part `*.PrjPcbVariants` (LFS, lockable),
   `*.PrjPcb -text` and `*.OutJob -text`. A project with no KiCad board may drop its `*.wrl` line. A `.PrjPcbVariants`
   already committed as a plain blob moves to LFS with `git add --renormalize .`, as in adopt; a `.PrjPcb` or `.OutJob`
   whose line ends git changed is put back from the Windows copy Altium saved.
   A silabs part gets the 1.2 fixes with its refreshed `make/kinds/silabs.mk`: in `make/project.mk` remove a
   `<part>_SLT_INSTALL := slc-cli wiseconnect/<ver>` and a `<part>_SLC_ARGS := --overwrite-all` that worked around them
   (both are now the defaults; keep any other SLC_ARGS), and pin `<part>_GCC` only when the SDK brings another GNU Arm
   toolchain than `12.2.rel1`. A `<part>-test` target in `make/local.mk` now clashes with the kind's: move its compile
   and run lines into `<dir>/tests/Makefile` (CC and BUILD_DIR come from the kind; outputs under `$(BUILD_DIR)` so
   `make <part>-clean` removes them), then delete the local target. (1.2 said Simplicity Commander was needed to build;
   1.3 corrects it: only a `.slcp` with a `post_build` needs it.)
   From v1.0 to v1.1: re-copy the managed files (the bin folder gains `refs.sh`, removed again in 1.2, and `ghcr.sh`) and set every `uses:`
   line to `@v1.1`. `scaffold.sh <worktree> --force` with the project's parts adds what 1.1 needs and changes nothing
   else (the 1.2 scaffold no longer adds `references/` to `.gitignore`): `docs/references.md`, `*.FCStd` (with a mechanical part) and Altium's LFS lines
   (with an altium part) in `.gitattributes`, and the missing docs of the new kinds. Add `library: local` by hand to the
   jobs of a hardware part that sets `<part>_LIBRARY := local` (an existing workflow is kept). A FreeCAD model already
   committed under `*.FCStd` was routed to LFS only on a Mac: `git add --renormalize .` after the new line, as in adopt.
   A docker part's images now go to `ghcr.io/<owner>` of the project's owner unless `make/project.mk` sets
   `DOCKER_REGISTRY`: say so when the old value came from the user config of another owner.
   From v6 to v7: add the documents (`scaffold.sh <worktree> --force` with the project's parts writes only the
   missing ones; move existing docs into the layout first, as in adopt), add the binary documents block to
   `.gitignore`, drop `*.pdf` and `*.xlsx` from `.gitattributes`, `git rm --cached` committed binary documents,
   and give the part components in `PLAN.md` their `docs/<part>/**` glob (the root component: `docs/*.md,
   docs/decisions/**, docs/images/**` instead of `docs/**`).
   From v7 to v8: nothing to rewrite for a v7 pipeline: its `<part>-gitlab-release` names of app-tauri, app-flutter, app-xcode and
   app-android still extend the hidden aliases the v8 templates keep. Update `ref:` to `v8` and the managed files as above. For
   the app parts, add the platform jobs with `scaffold.sh <worktree> --force` (it writes only the missing jobs), or copy the
   `<part>-gitlab-release-linux-amd64` / `-linux-arm64` (and `-windows` for Tauri) jobs by hand; then the Mac publishes macos,
   ios and android with `make <part>-gitlab-release FORCE=1 PLATFORM=...`. `audit.sh` reports a job that extends a name the
   templates removed as an error: fix that name first.
   From v8 to v9 (GitLab -> GitHub): `.gitlab-ci.yml` is replaced by `.github/workflows/checks.yml` and `release.yml`.
   `scaffold.sh <worktree> --force` writes the two workflows when they are missing; an existing one is kept, so move an
   old one aside first to regenerate it. Then the user runs, not Claude: `make ci-setup` (the CI age key, the deploy keys, and the
   repository variables `SECRETS_REPO`, `KICAD_LIBRARY_REPO` and, with an altium part, `ALTIUM_LIBRARY_REPO`); other variables with `gh variable set` (`STD_APT_PACKAGES` when needed, `MACOS_CI=true` only when macOS jobs should
   run); only for a private `CI_TEMPLATES_REPO`, access from the project's repositories on it (Settings > Actions >
   General > Access; the public default needs none); and, once the
   workflows are committed, `git rm .gitlab-ci.yml`. After that a tag runs `release.yml` and the GitHub Release. Old
   GitLab Releases and package registry files stay where they are. The `<part>-gitlab-release` alias is gone: rename it to `<part>-github-release` in every script and CI file.
   Releases (also v6 to v7): in `.gitlab-ci.yml` add a `<part>-gitlab-release` job per part (extends
   `.<kind>-gitlab-release`, `rules: [{ if: '$CI_COMMIT_TAG =~ /^<part>-v/' }]`), give every existing tag job of
   the part the same rule (`when: manual` kept on the publishing jobs), rename a hardware part's
   `<part>-release` job to `<part>-gitlab-release` and drop a docker part's `<part>-release` job (its GitLab
   Release job pushes the image); add `<dir>/release/` per part to `.gitignore`. A part with no version source yet
   gets its first with `make <part>-bump VERSION=x.y.z` when it is released.
   From v13 to v14: `docs/decisions/` is no longer part of the standard. An existing one can stay as the project's own
   docs (keep its line in `docs/README.md` and its glob in `PLAN.md`) or be removed; nothing else changes.
   From v15 to v16: `.github/workflows/ci.yml` is now `checks.yml` (the push and pull-request checks). Rename it with
     `git mv .github/workflows/ci.yml .github/workflows/checks.yml` and set its `name:` to `checks` (and its concurrency group to
     `checks-${{ github.ref }}`); `release.yml` keeps its name. `scaffold.sh --force` never writes a second one next to `ci.yml`.
5. `make help`, `make doctor`, `make check`, `audit.sh`; read the diff; bring it in; report.

## audit: read-only report

Run `audit.sh <dir>` and report the findings grouped by area with their fixes, plus the targets list
for an unstandard project. Change nothing. Exit code 0 means standard and current.

## teardown and prune: undo setup, reclaim space

`make teardown` is the opposite of `make setup` for one project, `make prune` is the machine-wide sweep (details:
`reference/standard.md` 4.1). Both only **list** what they would remove, with sizes and a total. They remove with
`CONFIRM=teardown` / `CONFIRM=prune`, which only the user adds, after reading the list: show the list, ask, never type
the `CONFIRM`. What goes: the project's build and dependency folders and usage record, and shared mise versions, SDKs under
`~/.toolchains` and rustup targets that the standard installed (its ledger) and no other standard project records.
Homebrew packages are never removed; the reminder lists the Brewfile's. A tool version the user installed themselves is never
in the ledger. A project that is not on the standard has no record, so it could lose a version the standard installed:
mention that when the list holds one. `make setup` puts back what a teardown removed.

## Using a standard project

- Always use the make commands, from the project root. `make help` lists them by stage and by
  part; `make <part>-<verb>` addresses one part; `PART=<name>` restricts a root verb.
- `ENV` is `local` (default), `staging` or `production`. Anything that touches production (deploys,
  promote, and every app `<part>-release` to TestFlight, Play or the OTA bucket), and every destroy,
  wipe or reset, refuses to run unless `CONFIRM=<env>` is on the command line; app releases need
  `CONFIRM=production`. Chip erase and recover need `CONFIRM=erase`, eFuse burns `CONFIRM=fuse`.
  Claude asks the user before such a command and never adds `CONFIRM` on its own.
- Secrets are never written into the project: values reach a command through its environment only.
  New secret: a line in `secrets.schema`, then `make secrets-set NAME= ENV=` (the user types it).
  Staging and production secrets need Touch ID; local ones do not.
- Project-only targets go in `make/local.mk` with a `## ` description; managed files are changed
  only through update.
- Docs are Markdown in git (`docs/README.md` indexes them): a line under `## [Unreleased]` in the part's
  `CHANGELOG.md` for each user-visible change, `docs/<part>/` updated with the interfaces it describes. Never commit
  a PDF, Word, Excel or PowerPoint file.
- `make help` lists only what the parts use; `make help ALL=1` lists every command.
- Releasing a part (since v7, `reference/standard.md` 4.12): its changes under `## [Unreleased]` in its `CHANGELOG.md`, then
  `make <part>-bump LEVEL=patch|minor|major` (or `VERSION=x.y.z`): the kind's version file, the CHANGELOG moved under the
  version, a commit `<part>: release <version>` and the tag `<part>-v<version>`; nothing pushed. The user pushes the branch
  and the tags with `make release-push` (ask first): the branch, then each new release tag in its own push, because GitHub
  starts no workflow for the tags of a push that carries more than three. GitHub marks only one Release of the repository
  Latest: since v20 that is the Release `latest`, which holds the newest files of every part under names without the
  version (`release.yml`'s `latest` job runs `make <part>-release-latest`; `reference/standard.md` 4.12), and
  `make latest` lists each part's newest Release. The tag starts `release.yml`, whose release
  job runs `<part>-github-release`: the release files (`<part>-release-assets`, into `<dir>/release/<version>/` with
  `SHA256SUMS`) are attached to the GitHub Release `<part> <version>` with the CHANGELOG notes. Publishing to the OTA
  bucket, a store or production stays a manual `confirm` run of `release.yml` (`confirm` = `production`). From a Mac,
  `make <part>-github-release FORCE=1` (gh) makes a Release. Since v8 an app part's release is per platform: the Linux and
  Windows jobs of the tag add their files, and the Mac adds macos, ios and android with `PLATFORM=<x> FORCE=1`
  (`reference/standard.md` 4.12). Each platform writes its own `SHA256SUMS-<platform>`, and a Release created twice at once
  is updated, not refused.
- `OTA_BUCKET` lives in `make/project.mk` (since v6), not in the user config: update mode moves a value from
  `~/.config/project-standard/config.mk` into the project that uses it (config.mk's value is ignored, with a
  warning).
- Never run `wrangler login`. A project has one Cloudflare API token for all its environments:
  `make cf-login` (no `ENV`) opens the dashboard's token form pre-filled with the project name and the
  permissions its `wrangler.jsonc` files and its OTA bucket need and prints the zones to pick in it ("Specific zone"), verifies
  the pasted token (an account-owned token too, its account looked up when none is given), stores it for staging and production (never
  `common`), `make cf-logout` removes both, `make cf-whoami` shows it and says when the two copies differ.
  Token permissions: `reference/standard.md` section 7.
- `cf-*` commands provision, check and back up D1, KV, R2 and Queues (dead-letter queues included) only;
  Durable Objects and other bindings go to wrangler on deploy, and Durable Object storage is not backed up.
