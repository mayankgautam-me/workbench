# project-standard v1.3 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind cloud-worker: a Cloudflare Worker part (wrangler, with D1, KV, R2, Queues bindings).
#
# A part whose wrangler.jsonc has no env.staging is production-only: `make <name>-deploy ENV=production
# CONFIRM=production` deploys it directly (its tag does the same in CI), ENV=staging is refused (by cf.sh, before
# wrangler runs) and promote is for parts with staging. Only D1, KV, R2 and Queues are provisioned, checked and backed up; every other binding
# (Durable Objects, services, AI, send_email, workflows...) goes to wrangler on deploy only.
#
# make/project.mk declares it as   <name>:cloud-worker:<dir>   and may set, per part:
#   <name>_PORT_OFFSET   dev port is PORT_BASE + offset             (default 0)
#   <name>_HEALTH        health path checked by smoke              (default /health)
#   <name>_URL_<env>     public base URL of the Worker in that env (staging, production)
#
# The part's package.json pins wrangler. Every wrangler call (and tsc, vitest, biome, eslint) runs from the part's
# directory through its package manager: `pnpm exec` when the part has pnpm-lock.yaml, else `npx --no-install`
# (<name>_EXEC overrides it; cf.sh makes the same choice). Secrets reach wrangler through the environment of
# `secrets.sh exec` (and only `wrangler dev` also gets CLOUDFLARE_INCLUDE_PROCESS_ENV=true), never through a .dev.vars or .env file.
# The bindings for each environment, local included, are the env.<name> blocks of wrangler.jsonc.
#
# Variables of the kind body are assigned while the kind is evaluated, so recipes refer to them
# with $$(...) (expanded when the recipe runs; shell $ in a recipe is $$$$), and anything from the project is read with $(...).
#
# Releases: <name>-bump sets <dir>/VERSION and tags <name>-v<version>; make release-push sends the tag, and that tag's
# workflow (release.yml) checks, builds and deploys production (make <name>-deploy ENV=production CONFIRM=production:
# the tag push is the deliberate step, CI's CONFIRM), then makes the GitHub Release (<name>-github-release) with the
# CHANGELOG notes only, no files: what a Worker releases is the deploy. A push to main deploys staging when the part
# has env.staging. promote (staging's code to production, from the staging record) stays for a run by hand.

define kind_cloud-worker
$(1)_PORT_OFFSET ?= 0
$(1)_PORT := $(shell expr $(PORT_BASE) + $(or $($(1)_PORT_OFFSET),0))
$(1)_HEALTH ?= /health
$(1)_SEC := $(CURDIR)/$(STD_BIN)/secrets.sh
$(1)_CF := $(CURDIR)/$(STD_BIN)/cf.sh
$(1)_EXEC ?= $$(if $$(wildcard $(2)/pnpm-lock.yaml),pnpm exec,npx --no-install)
$(1)_LINT_CMD := $(if $(wildcard $(2)/biome.json),$$($(1)_EXEC) biome check .,$(if $(wildcard $(2)/eslint.config.*),$$($(1)_EXEC) eslint .,echo "lint skipped (no biome.json or eslint config)"))
.PHONY: $(1)-setup $(1)-doctor $(1)-dev $(1)-stop $(1)-logs $(1)-status $(1)-check $(1)-test $(1)-format $(1)-build $(1)-test-remote $(1)-smoke $(1)-deploy $(1)-preview $(1)-promote $(1)-versions $(1)-rollback $(1)-migrate $(1)-seed $(1)-provision $(1)-secrets $(1)-backup $(1)-wipe $(1)-destroy $(1)-clean $(1)-distclean $(1)-reset

$(call std_verb,$(1),setup,setup,Install the Worker packages with npm ci when there is a lockfile else pnpm install)
$(1)-setup:
	@cd $(2) && $(STD_NODE_SETUP)

# The commands that run the Worker's packages install them first when node_modules is missing or older than
# package.json or the lockfile (std_ready in common.mk).
$(call std_ready,$(1),$(2),std_node_ready,dev logs status check test format build test-remote smoke deploy preview promote versions rollback migrate seed provision secrets backup wipe destroy reset)

$(call std_verb,$(1),doctor,setup,Check the Worker packages and the pinned wrangler read only)
$(1)-doctor:
	@set -euo pipefail; \
	test -f $(2)/package.json || { echo "$(1): no package.json in $(2)"; exit 1; }; \
	grep -q '"wrangler"' $(2)/package.json || { echo "$(1): wrangler is not pinned in $(2)/package.json"; exit 1; }; \
	test -d $(2)/node_modules || { echo "$(1): packages missing, run make $(1)-setup"; exit 1; }; \
	echo "$(1): packages present, wrangler pinned"

$(call std_verb,$(1),dev,dev,Run migrations on local D1 then wrangler dev on the part port)
$(1)-dev:
	@set -euo pipefail; \
	test "$(ENV)" = local || { echo "$(1)-dev runs locally only, drop ENV=$(ENV)"; exit 1; }; \
	$$($(1)_CF) migrate --env local --dir $(2); \
	cd $(2) && $$($(1)_SEC) exec --env local -- env CLOUDFLARE_INCLUDE_PROCESS_ENV=true $$($(1)_EXEC) wrangler dev --env local --port $$($(1)_PORT)

$(call std_verb,$(1),stop,dev,Stop the wrangler dev process listening on the part port)
# wrangler dev first (v21): killing only what listens on the port (workerd) left wrangler dev, and the make dev that
# started it, running. Stopping wrangler dev takes workerd down with it; the port's listener is the fallback.
$(1)-stop:
	@if pkill -f "wrangler.* dev --env local --port $$($(1)_PORT)( |$$$$)" 2>/dev/null; then \
	  echo "$(1): stopped wrangler dev on port $$($(1)_PORT)"; sleep 1; fi; \
	pids=$$$$(lsof -ti tcp:$$($(1)_PORT) -sTCP:LISTEN 2>/dev/null || true); \
	if [ -n "$$$$pids" ]; then kill $$$$pids && echo "$(1): stopped port $$($(1)_PORT)"; else echo "$(1): nothing more listening on port $$($(1)_PORT)"; fi

$(call std_verb,$(1),logs,dev,Follow the live logs of the deployed Worker with wrangler tail)
$(1)-logs:
	@set -euo pipefail; \
	if [ "$(ENV)" = local ]; then echo "$(1): local logs stream in the make dev terminal, use ENV=staging or ENV=production"; exit 0; fi; \
	cd $(2) && $$($(1)_SEC) exec --env $(ENV) -- $$($(1)_EXEC) wrangler tail --env $(ENV) --format pretty

$(call std_verb,$(1),status,cloudflare,Declared bindings against what exists in ENV)
$(1)-status:
	@$$($(1)_CF) status --env $(ENV) --dir $(2)

$(call std_verb,$(1),check,test,Typecheck lint and unit tests of the Worker)
$(1)-check:
	@set -euo pipefail; cd $(2); \
	if [ -f tsconfig.json ]; then $$($(1)_EXEC) tsc --noEmit; fi; \
	$$($(1)_LINT_CMD); \
	$$($(1)_EXEC) vitest run --passWithNoTests

$(call std_verb,$(1),test,test,Unit tests with vitest and TEST=pattern for one test)
$(1)-test:
	@cd $(2) && $$($(1)_EXEC) vitest run --passWithNoTests $(if $(TEST),-t '$(TEST)')

$(call std_verb,$(1),format,test,Rewrite formatting with biome when biome is configured)
$(1)-format:
	@cd $(2) && if [ -f biome.json ]; then $$($(1)_EXEC) biome format --write .; else echo "$(1): no biome.json, nothing to format"; fi

$(call std_verb,$(1),build,deploy,Bundle the Worker with wrangler deploy dry run into dist)
$(1)-build:
	@cd $(2) && $$($(1)_EXEC) wrangler deploy --dry-run --outdir dist --env $(ENV)

# Every target that touches ENV=production starts its recipe line with a guard (std_production_guard, or
# std_remote_guard, which also refuses ENV=local). The guard shares the shell line with the action: it is
# never a recipe line of its own or a prerequisite, because `make -i` would skip it.

$(call std_verb,$(1),test-remote,deploy,Run tests/remote against the deployed ENV)
$(1)-test-remote:
	@$$(call std_remote_guard,$(1)) && { set -euo pipefail; \
	base="$($(1)_URL_$(ENV))"; \
	test -n "$$$$base" || { echo "$(1): set $(1)_URL_$(ENV) in make/project.mk"; exit 1; }; \
	test -d $(2)/tests/remote || { echo "$(1): no $(2)/tests/remote"; exit 1; }; \
	cd $(2) && $$($(1)_SEC) exec --env $(ENV) -- env BASE_URL="$$$$base" $$($(1)_EXEC) vitest run tests/remote; }

$(call std_verb,$(1),smoke,deploy,Health check then tests/smoke against the URL of ENV or SMOKE_BASE)
$(1)-smoke:
	@set -euo pipefail; \
	base="$(or $(SMOKE_BASE),$($(1)_URL_$(ENV)))"; \
	test -n "$$$$base" || { echo "$(1): no URL for $(ENV), set $(1)_URL_$(ENV) in make/project.mk"; exit 1; }; \
	$(STD_LIB); smoke_get "$$$$base$$($(1)_HEALTH)"; \
	echo "$(1): health ok at $$$$base$$($(1)_HEALTH)"; \
	if [ -d $(2)/tests/smoke ]; then cd $(2) && BASE_URL="$$$$base" $$($(1)_EXEC) vitest run --passWithNoTests tests/smoke; fi

# Deploy: guard, check, build, migrate, wrangler deploy, smoke. On staging the deployed version id
# and the git commit are written to <dir>/.wrangler/project-standard-staging-version for promote.
$(call std_verb,$(1),deploy,deploy,Check build migrate then wrangler deploy then smoke for ENV staging or production)
$(1)-deploy:
	@$$(call std_remote_guard,$(1)) && $$(MAKE) --no-print-directory $(1)-check && $$(MAKE) --no-print-directory $(1)-build && $$(MAKE) --no-print-directory $(1)-migrate && { set -euo pipefail; \
	log=$$$$(mktemp); trap 'rm -f "$$$$log"' EXIT; \
	( cd $(2) && mkdir -p .wrangler && $$($(1)_SEC) exec --env $(ENV) -- $$($(1)_EXEC) wrangler deploy --env $(ENV) 2>&1 | tee "$$$$log" ); \
	if [ "$(ENV)" = staging ]; then \
	  ver=$$$$(sed -n 's/.*Current Version ID: *\([^ ]*\).*/\1/p' "$$$$log" | tail -n 1); \
	  test -n "$$$$ver" || { echo "$(1): wrangler printed no version id, cannot record the staging version"; exit 1; }; \
	  printf '%s %s\n' "$$$$ver" "$$$$(git rev-parse HEAD 2>/dev/null || echo unknown)" > $(2)/.wrangler/project-standard-staging-version; \
	  echo "$(1): staging version $$$$ver recorded"; \
	fi; \
	$(MAKE) --no-print-directory $(1)-smoke; }

$(call std_verb,$(1),preview,deploy,Upload a version with wrangler versions upload then smoke its preview URL)
$(1)-preview:
	@$$(call std_production_guard) && $$(MAKE) --no-print-directory $(1)-check && { set -euo pipefail; \
	test "$(ENV)" = staging || test "$(ENV)" = production || { echo "$(1)-preview needs ENV=staging or ENV=production"; exit 1; }; \
	log=$$$$(mktemp); trap 'rm -f "$$$$log"' EXIT; \
	( cd $(2) && $$($(1)_SEC) exec --env $(ENV) -- $$($(1)_EXEC) wrangler versions upload --env $(ENV) 2>&1 | tee "$$$$log" ); \
	url=$$$$(sed -n 's/.*Version Preview URL: *\(https:[^ ]*\).*/\1/p' "$$$$log" | tail -n 1); \
	test -n "$$$$url" || { echo "$(1)-preview: no preview URL in wrangler output"; exit 1; }; \
	echo "$(1): preview $$$$url"; \
	$(MAKE) --no-print-directory $(1)-smoke SMOKE_BASE="$$$$url"; }

# Promote: production gets the code that passed staging. Wrangler versions belong to one Worker
# script, and staging and production are separate scripts, so the staging version id cannot be
# deployed as is. The recorded commit must equal HEAD, and the production deploy carries the
# staging version id in its message.
$(call std_verb,$(1),promote,deploy,Deploy to production the code that passed on staging (CONFIRM=production))
$(1)-promote:
	@$$(call std_remote_guard,$(1)) && { set -euo pipefail; \
	test "$(ENV)" = production || { echo "$(1)-promote deploys to production, use ENV=production CONFIRM=production"; exit 1; }; \
	rec=$(2)/.wrangler/project-standard-staging-version; \
	test -f "$$$$rec" || { echo "$(1)-promote: no staging record at $$$$rec, run make $(1)-deploy ENV=staging first (a production-only part, with no env.staging, deploys with make $(1)-deploy ENV=production CONFIRM=production)"; exit 1; }; \
	read -r ver sha < "$$$$rec"; \
	head=$$$$(git rev-parse HEAD 2>/dev/null || echo unknown); \
	test "$$$$sha" = "$$$$head" || { echo "$(1)-promote: staging deployed $$$$sha but HEAD is $$$$head, deploy staging from this commit first"; exit 1; }; \
	( cd $(2) && $$($(1)_SEC) exec --env production -- $$($(1)_EXEC) wrangler deploy --env production --message "promoted from staging version $$$$ver" ); \
	$(MAKE) --no-print-directory $(1)-smoke ENV=production; }

$(call std_verb,$(1),versions,deploy,List the deployed versions of ENV)
$(1)-versions:
	@cd $(2) && $$($(1)_SEC) exec --env $(ENV) -- $$($(1)_EXEC) wrangler versions list --env $(ENV)

$(call std_verb,$(1),rollback,deploy,Roll ENV back to the previous version (CONFIRM=production for production))
$(1)-rollback:
	@$$(call std_remote_guard,$(1)) && cd $(2) && $$($(1)_SEC) exec --env $(ENV) -- $$($(1)_EXEC) wrangler rollback --env $(ENV) --message "project-standard rollback" --yes

$(call std_extra,$(1),migrate,cloudflare,Apply D1 migrations to ENV local or remote)
$(1)-migrate:
	@$$(call std_production_guard) && $$($(1)_CF) migrate --env $(ENV) --dir $(2)

$(call std_extra,$(1),seed,cloudflare,Load seed sql into local or staging production refused)
$(1)-seed:
	@test "$(ENV)" != production || { echo "$(1)-seed refuses production"; exit 1; }; $$($(1)_CF) seed --env $(ENV) --dir $(2)

$(call std_extra,$(1),provision,cloudflare,Create the missing D1 KV R2 and Queues (dead-letter queues too) of ENV and write their ids back)
$(1)-provision:
	@$$(call std_production_guard) && $$($(1)_CF) provision --env $(ENV) --dir $(2)

$(call std_extra,$(1),secrets,cloudflare,Push the secrets the schema marks for cf to ENV and ROTATE=NAME to replace one)
$(1)-secrets:
	@$$(call std_production_guard) && $$($(1)_CF) secrets --env $(ENV) --dir $(2) $(if $(ROTATE),--rotate "$$$$ROTATE")

$(call std_extra,$(1),backup,cloudflare,Export D1 and every KV value of ENV into an encrypted archive outside the repo (R2 info only; Durable Objects not backed up))
$(1)-backup:
	@$$($(1)_CF) backup --env $(ENV) --dir $(2)

$(call std_extra,$(1),wipe,cloudflare,Back up then delete the data of ENV and keep its resources needs CONFIRM=ENV)
$(1)-wipe:
	@$$(call std_confirm,$(ENV)) && $$($(1)_CF) wipe --env $(ENV) --dir $(2) $(STD_R2_FLAG)

$(call std_extra,$(1),destroy,cloudflare,Back up then delete the Worker and resources of ENV needs CONFIRM=ENV)
$(1)-destroy:
	@$$(call std_confirm,$(ENV)) && $$($(1)_CF) destroy --env $(ENV) --dir $(2) $(STD_R2_FLAG)

$(call std_verb,$(1),reset,dev,Wipe the local D1 and KV state then migrate and seed local again needs CONFIRM=local)
$(1)-reset:
	@test "$(ENV)" = local || { echo "$(1)-reset is for ENV=local only"; exit 1; }; $$(call std_confirm,local) && { set -euo pipefail; \
	rm -rf "$(2)/.wrangler/state"; \
	$$($(1)_CF) migrate --env local --dir $(2); \
	if [ -d $(2)/seed ]; then $$($(1)_CF) seed --env local --dir $(2); fi; }

$(call std_verb,$(1),version,release,Worker version from $(2)/VERSION)
$(1)-version:
	@printf '%s %s\n' "$(1)" "$$$$($$(STD_RELEASE) version --part $(1) --kind cloud-worker --part-dir $(2) 2>/dev/null || echo 'none yet (make $(1)-bump sets it)')"

$(call std_release,$(1),cloud-worker,$(2),,)

$(call std_verb,$(1),clean,dev,Remove the build output of the Worker)
$(1)-clean:
	@rm -rf "$(2)/dist"

$(call std_verb,$(1),distclean,dev,Remove the build output and the installed packages of the Worker)
$(1)-distclean: $(1)-clean
	@rm -rf "$(2)/node_modules"
endef
