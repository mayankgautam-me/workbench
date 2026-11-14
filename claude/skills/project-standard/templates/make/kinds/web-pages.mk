# project-standard v1.8 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind web-pages: a static site, a Vite app or a Next.js static export, served by Cloudflare Pages.
#
# make/project.mk declares it as   <name>:web-pages:<dir>   and may set, per part:
#   <name>_PAGES         Pages project name            (default PROJECT-<name>)
#   <name>_OUT           build output, from the root   (default <dir>/out for next, <dir>/dist for vite, <dir> for static)
#   <name>_PORT_OFFSET   dev port is PORT_BASE + offset (default 0)
#   <name>_HEALTH        path checked by smoke         (default /)
#   <name>_URL_<env>     public URL in that env        (staging, production)
#
# The framework comes from the files: next.config.* is next, vite.config.* is vite, anything else is static.
# A wrangler.jsonc without pages_build_output_dir in the part dir makes it a static-assets Worker instead of a Pages project:
# assets.directory is the build output, env.<name> blocks name the Worker of each env, its routes put it on a custom
# domain, and workers_dev: false with preview_urls: false leave that domain its only address (Pages cannot turn off
# *.pages.dev). deploy runs wrangler deploy --env ENV from the part dir; provision has nothing to create.
# The part's package.json pins wrangler. Deploys to ENV=staging go to the Pages preview branch
# "staging"; ENV=production goes to the production branch "main" and needs CONFIRM=production.
# Secrets reach wrangler through `secrets.sh exec` only. Package binaries run through the part's package manager:
# `pnpm exec` when the part has pnpm-lock.yaml, else `npx --no-install` (<name>_EXEC overrides it).

# Releases: <name>-bump sets <dir>/VERSION and tags <name>-v<version>; make release-push sends the tag, and that tag's
# workflow (release.yml) checks, builds and deploys production (make <name>-deploy ENV=production CONFIRM=production),
# then makes the GitHub Release (<name>-github-release) with the CHANGELOG notes only, no files. A push to main deploys
# staging (the Pages preview branch) unless the part is production-only.

define kind_web-pages
$(1)_FRAMEWORK := $(if $(wildcard $(2)/next.config.*),next,$(if $(wildcard $(2)/vite.config.*),vite,static))
$(1)_PAGES ?= $(PROJECT)-$(1)
# pages (wrangler pages deploy to the Pages project) or worker (a static-assets Worker: the part's wrangler.jsonc names it,
# its custom domain, and turns workers.dev and preview URLs off). A wrangler.jsonc without pages_build_output_dir makes it worker.
# A wrangler file that sets pages_build_output_dir (the scaffold writes one) is the Pages project's config: still pages.
$(1)_TARGET ?= $(if $(wildcard $(2)/wrangler.jsonc $(2)/wrangler.json),$(if $(shell grep -l pages_build_output_dir $(wildcard $(2)/wrangler.jsonc $(2)/wrangler.json) 2>/dev/null),pages,worker),pages)
$(1)_OUT ?= $(if $(wildcard $(2)/next.config.*),$(2)/out,$(if $(wildcard $(2)/vite.config.*),$(2)/dist,$(2)))
$(1)_PORT_OFFSET ?= 0
$(1)_PORT := $(shell expr $(PORT_BASE) + $(or $($(1)_PORT_OFFSET),0))
$(1)_HEALTH ?= /
$(1)_SEC := $(CURDIR)/$(STD_BIN)/secrets.sh
$(1)_BRANCH := $(if $(filter production,$(ENV)),main,staging)
$(1)_EXEC ?= $$(if $$(wildcard $(2)/pnpm-lock.yaml),pnpm exec,npx --no-install)
$(1)_LINT_CMD := $(if $(wildcard $(2)/biome.json),$$($(1)_EXEC) biome check .,$(if $(wildcard $(2)/eslint.config.*),$$($(1)_EXEC) eslint .,echo "lint skipped (no biome.json or eslint config)"))
.PHONY: $(1)-setup $(1)-dev $(1)-check $(1)-test $(1)-format $(1)-build $(1)-deploy $(1)-test-remote $(1)-smoke $(1)-provision $(1)-logs $(1)-status $(1)-versions $(1)-clean $(1)-distclean

$(call std_verb,$(1),setup,setup,Install the site packages with npm ci when there is a lockfile else pnpm install)
$(1)-setup:
	@if [ -f $(2)/package.json ]; then cd $(2) && $(STD_NODE_SETUP); else echo "$(1): no package.json, nothing to install"; fi

# The commands that run the site's packages install them first when node_modules is missing or older than
# package.json or the lockfile (std_ready in common.mk). A site without package.json is always ready.
$(call std_ready,$(1),$(2),std_node_ready,dev check test format build deploy smoke test-remote provision status versions logs)

$(call std_verb,$(1),dev,dev,Run the framework dev server or wrangler pages dev on the part port)
$(1)-dev:
	@set -euo pipefail; \
	test "$(ENV)" = local || { echo "$(1)-dev runs locally, drop ENV=$(ENV)"; exit 1; }; \
	fw="$$($(1)_FRAMEWORK)"; \
	case "$$$$fw" in \
	  next) cd $(2) && $$($(1)_EXEC) next dev --port $$($(1)_PORT) ;; \
	  vite) cd $(2) && $$($(1)_EXEC) vite --port $$($(1)_PORT) --strictPort ;; \
	  *) $(2)/node_modules/.bin/wrangler pages dev $$($(1)_OUT) --port $$($(1)_PORT) ;; \
	esac

$(call std_verb,$(1),check,test,Lint typecheck and unit tests of the site)
$(1)-check:
	@set -euo pipefail; cd $(2); \
	if [ -f tsconfig.json ]; then $$($(1)_EXEC) tsc --noEmit; fi; \
	$$($(1)_LINT_CMD); \
	if ls vitest.config.* >/dev/null 2>&1; then $$($(1)_EXEC) vitest run --passWithNoTests; fi

$(call std_verb,$(1),test,test,Unit tests with vitest when a vitest config exists and TEST=pattern for one test)
$(1)-test:
	@if ls $(2)/vitest.config.* >/dev/null 2>&1; then cd $(2) && $$($(1)_EXEC) vitest run --passWithNoTests $(if $(TEST),-t '$(TEST)'); else echo "$(1): no vitest config, no unit tests"; fi

$(call std_verb,$(1),format,test,Rewrite formatting with biome when biome is configured)
$(1)-format:
	@cd $(2) && if [ -f biome.json ]; then $$($(1)_EXEC) biome format --write .; else echo "$(1): no biome.json, nothing to format"; fi

$(call std_verb,$(1),build,deploy,Build the site with the framework or copy the static files into OUT)
$(1)-build:
	@set -euo pipefail; \
	fw="$$($(1)_FRAMEWORK)"; \
	case "$$$$fw" in \
	  next) cd $(2) && $$($(1)_EXEC) next build ;; \
	  vite) cd $(2) && $$($(1)_EXEC) vite build ;; \
	  *) echo "$(1): static site, nothing to build" ;; \
	esac

# Every target that touches ENV=production starts its recipe line with a guard that shares the shell line
# with the action (never a recipe line of its own or a prerequisite: `make -i` would skip those).

$(call std_verb,$(1),deploy,deploy,Check build then deploy to ENV (Pages or the static-assets Worker) then smoke)
$(1)-deploy:
	@$$(call std_remote_guard,$(1)) && $$(MAKE) --no-print-directory $(1)-check && $$(MAKE) --no-print-directory $(1)-build && { set -euo pipefail; \
	if [ "$$($(1)_TARGET)" = worker ]; then \
	  ( cd $(2) && $$($(1)_SEC) exec --env $(ENV) -- node_modules/.bin/wrangler deploy --env $(ENV) ); \
	else \
	  $$($(1)_SEC) exec --env $(ENV) -- $(2)/node_modules/.bin/wrangler pages deploy $$($(1)_OUT) --project-name $$($(1)_PAGES) --branch $$($(1)_BRANCH) --commit-hash "$$$$(git rev-parse HEAD 2>/dev/null || echo unknown)"; \
	fi; \
	$(MAKE) --no-print-directory $(1)-smoke; }

$(call std_verb,$(1),smoke,deploy,Fetch the health path and tests/smoke against the URL of ENV or SMOKE_BASE)
$(1)-smoke:
	@set -euo pipefail; \
	base="$(or $(SMOKE_BASE),$($(1)_URL_$(ENV)))"; \
	test -n "$$$$base" || { echo "$(1): no URL for $(ENV), set $(1)_URL_$(ENV) in make/project.mk"; exit 1; }; \
	$(STD_LIB); smoke_get "$$$$base$$($(1)_HEALTH)"; \
	echo "$(1): health ok at $$$$base$$($(1)_HEALTH)"; \
	if [ -d $(2)/tests/smoke ]; then cd $(2) && BASE_URL="$$$$base" $$($(1)_EXEC) vitest run --passWithNoTests tests/smoke; fi

$(call std_verb,$(1),test-remote,deploy,Run tests/remote against the deployed ENV)
$(1)-test-remote:
	@$$(call std_remote_guard,$(1)) && { set -euo pipefail; \
	base="$($(1)_URL_$(ENV))"; \
	test -n "$$$$base" || { echo "$(1): set $(1)_URL_$(ENV) in make/project.mk"; exit 1; }; \
	test -d $(2)/tests/remote || { echo "$(1): no $(2)/tests/remote"; exit 1; }; \
	cd $(2) && $$($(1)_SEC) exec --env $(ENV) -- env BASE_URL="$$$$base" $$($(1)_EXEC) vitest run tests/remote; }

$(call std_extra,$(1),provision,cloudflare,Create the Pages project of this site in ENV when it is missing (a Worker site needs none))
$(1)-provision:
	@$$(call std_production_guard) && { set -euo pipefail; \
	if [ "$$($(1)_TARGET)" = worker ]; then echo "$(1): a static-assets Worker, nothing to provision: make $(1)-deploy creates it"; exit 0; fi; \
	out=$$$$($$($(1)_SEC) exec --env $(ENV) -- $(2)/node_modules/.bin/wrangler pages project create $$($(1)_PAGES) --production-branch main 2>&1) || { printf '%s\n' "$$$$out" | grep -qi 'already exists' || { printf '%s\n' "$$$$out"; exit 1; }; }; \
	echo "$(1): Pages project $$($(1)_PAGES) is ready"; }

$(call std_verb,$(1),status,cloudflare,Show the Pages project or the Worker deployments of this site in ENV)
$(1)-status:
	@if [ "$$($(1)_TARGET)" = worker ]; then cd $(2) && $$($(1)_SEC) exec --env $(ENV) -- node_modules/.bin/wrangler versions list --env $(ENV); \
	else $$($(1)_SEC) exec --env $(ENV) -- $(2)/node_modules/.bin/wrangler pages project list; fi

$(call std_verb,$(1),versions,deploy,List the recent Pages deployments of ENV)
$(1)-versions:
	@if [ "$$($(1)_TARGET)" = worker ]; then cd $(2) && $$($(1)_SEC) exec --env $(ENV) -- node_modules/.bin/wrangler versions list --env $(ENV); \
	else $$($(1)_SEC) exec --env $(ENV) -- $(2)/node_modules/.bin/wrangler pages deployment list --project-name $$($(1)_PAGES); fi

$(call std_verb,$(1),logs,dev,Follow the Pages function logs of ENV)
$(1)-logs:
	@test "$(ENV)" != local || { echo "$(1): local logs stream in the make dev terminal, use ENV=staging or ENV=production"; exit 0; }
	@if [ "$$($(1)_TARGET)" = worker ]; then cd $(2) && $$($(1)_SEC) exec --env $(ENV) -- node_modules/.bin/wrangler tail --env $(ENV) --format pretty; \
	else $$($(1)_SEC) exec --env $(ENV) -- $(2)/node_modules/.bin/wrangler pages deployment tail --project-name $$($(1)_PAGES); fi

$(call std_verb,$(1),version,release,Site version from $(2)/VERSION)
$(1)-version:
	@printf '%s %s\n' "$(1)" "$$$$($$(STD_RELEASE) version --part $(1) --kind web-pages --part-dir $(2) 2>/dev/null || echo 'none yet (make $(1)-bump sets it)')"

$(call std_release,$(1),web-pages,$(2),,)

$(call std_verb,$(1),clean,dev,Remove the build output of the site)
$(1)-clean:
	@rm -rf "$(2)/dist" "$(2)/out" "$(2)/.next"

$(call std_verb,$(1),distclean,dev,Remove the build output and the installed packages of the site)
$(1)-distclean: $(1)-clean
	@rm -rf "$(2)/node_modules"
endef
