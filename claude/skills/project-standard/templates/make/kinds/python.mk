# project-standard v1.9 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind python: a Python project managed by uv (pyproject.toml, uv.lock), with ruff and pytest.
#
# make/project.mk declares it as   <name>:python:<dir>   and may set, per part:
#   <name>_MODULE       importable module run by dev          (default: the part name with - replaced by _)
#   <name>_PORT_OFFSET  dev port is PORT_BASE + offset        (default 0; exported to the process as PORT)
#
# Python comes from mise.toml and uv from the same file or Homebrew. Dependencies are locked in uv.lock.
# release builds the sdist and wheel into dist/ with checksums. It publishes only with PUBLISH=1 and
# CONFIRM=production, using the production env of the central secrets (UV_PUBLISH_TOKEN). The GitHub Release
# (<name>-github-release, on the tag <name>-v<version> that make <name>-bump makes) attaches the wheel and the sdist.

# GitHub Release assets: the wheel and the sdist of the current version from dist/ (<part>-build makes them).
python_release_assets = set -euo pipefail; $(call std_rel_begin,$(1),python,$(2)) \
  dists=0; for f in "$(CURDIR)/$(2)/dist/"*"-$$ver-"*.whl "$(CURDIR)/$(2)/dist/"*"-$$ver.tar.gz"; do [ -f "$$f" ] || continue; put "$$f"; dists=$$((dists + 1)); done; \
  [ "$$dists" -gt 0 ] || { echo "$(1): no wheel or sdist of $$ver in $(2)/dist: run make $(1)-build" >&2; exit 1; }; \
  $(std_rel_end)

define kind_python
$(1)_MODULE ?= $(subst -,_,$(1))
$(1)_PORT_OFFSET ?= 0
$(1)_SEC := $(CURDIR)/$(STD_BIN)/secrets.sh
.PHONY: $(1)-setup $(1)-dev $(1)-check $(1)-test $(1)-format $(1)-build $(1)-release $(1)-version $(1)-clean $(1)-distclean

$(call std_verb,$(1),setup,setup,Create the virtual environment from uv.lock)
$(1)-setup:
	@cd $(2) && uv sync

$(call std_verb,$(1),dev,dev,Run the module locally with the local secrets in the environment)
$(1)-dev:
	@set -euo pipefail; test "$(ENV)" = local || { echo "$(1)-dev runs locally, drop ENV=$(ENV)"; exit 1; }; \
	cd $(2) && $$($(1)_SEC) exec --env local -- env PORT=$(shell expr $(PORT_BASE) + $(or $($(1)_PORT_OFFSET),0)) uv run python -m $$($(1)_MODULE)

# pytest exits 5 when no test is collected. That is not a failure here.
$(call std_verb,$(1),check,test,ruff format and lint then the tests)
$(1)-check:
	@set -euo pipefail; cd $(2); \
	uv run ruff format --check .; \
	uv run ruff check .; \
	rc=0; uv run pytest -q || rc=$$$$?; test "$$$$rc" -eq 0 -o "$$$$rc" -eq 5

$(call std_verb,$(1),test,test,Pytest with TEST=expression to select tests)
$(1)-test:
	@set -euo pipefail; cd $(2); \
	rc=0; uv run pytest -q $(if $(TEST),-k '$(TEST)') || rc=$$$$?; test "$$$$rc" -eq 0 -o "$$$$rc" -eq 5

$(call std_verb,$(1),format,test,Rewrite the formatting with ruff format and fix the lint that ruff can fix)
$(1)-format:
	@cd $(2) && uv run ruff format . && uv run ruff check --fix .

$(call std_verb,$(1),build,deploy,Build the sdist and the wheel into dist)
$(1)-build:
	@cd $(2) && uv build --out-dir dist

$(call std_verb,$(1),release,release,Check build and checksum the artifacts and publish only with PUBLISH=1 and CONFIRM=production)
$(1)-release: $(1)-check $(1)-build
	@set -euo pipefail; cd $(2); (cd dist && sha256sum * > SHA256SUMS); cat dist/SHA256SUMS; \
	if [ "$(PUBLISH)" = 1 ]; then $$(call std_confirm,production) && $$($(1)_SEC) exec --env production -- sh -c 'uv publish dist/*'; fi

$(call std_verb,$(1),version,setup,Print the version from pyproject.toml)
$(1)-version:
	@sed -n 's/^version *= *"\(.*\)"/\1/p' $(2)/pyproject.toml | head -n 1

$(call std_release,$(1),python,$(2),python_release_assets,build)

$(call std_verb,$(1),clean,dev,Remove the build output and the caches)
$(1)-clean:
	@rm -rf "$(2)/dist" "$(2)/build" "$(2)/.pytest_cache" "$(2)/.ruff_cache"

$(call std_verb,$(1),distclean,dev,Clean and remove the virtual environment)
$(1)-distclean: $(1)-clean
	@rm -rf "$(2)/.venv"
endef
