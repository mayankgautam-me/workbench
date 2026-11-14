# project-standard v1.8 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind docker: a container image built with buildx, and optionally a compose stack for local development.
#
# make/project.mk declares it as   <name>:docker:<dir>   and may set, per part:
#   <name>_IMAGE        image name in the registry               (default: the part name)
#   <name>_DOCKERFILE   Dockerfile                               (default: <dir>/Dockerfile)
#   <name>_COMPOSE      compose file for dev, stop, logs         (default: <dir>/compose.yaml; optional)
#   <name>_PLATFORMS    buildx platforms                         (default: linux/amd64,linux/arm64)
#
# Images are pushed as $(DOCKER_REGISTRY)/$(PROJECT)/<image>:<git sha>, plus :<env> for staging and
# production, plus the exact git tag when HEAD has one, plus :<version> when HEAD has the tag <name>-v<version>.
# DOCKER_REGISTRY comes from the user config. The version is <dir>/VERSION (make <name>-bump writes it).
# Compose runs under `secrets.sh exec --env local`, so its ${VARIABLES} come from the environment.
#
# GitHub Release (<name>-github-release, on the tag <name>-v<version>): the release pushes the image (unless
# NOBUILD=1), and the Release carries image.json: registry, image, tag and digest. The image stays in the registry.

docker_release_assets = set -euo pipefail; $(call std_rel_begin,$(1),docker,$(2)) \
  ref="$(DOCKER_REGISTRY)/$(PROJECT)/$($(1)_IMAGE)"; \
  dg=$$(docker buildx imagetools inspect "$$ref:$$ver" --format '{{.Manifest.Digest}}' 2>/dev/null | tr -d '[:space:]' || true); \
  [ -n "$$dg" ] || { echo "$(1): no image $$ref:$$ver in the registry (make $(1)-release pushes it from the tag $(1)-v$$ver)" >&2; exit 1; }; \
  printf '{"registry":"%s","image":"%s","tag":"%s","digest":"%s","platforms":"%s"}\n' "$(DOCKER_REGISTRY)" "$$ref" "$$ver" "$$dg" "$($(1)_PLATFORMS)" > "$$out/image.json"; \
  printf '  asset image.json\n'; \
  $(std_rel_end)

docker_ready = [ -f "$${DOCKER_CONFIG:-$$HOME/.docker}/buildx/instances/project-standard" ]

define kind_docker
$(1)_IMAGE ?= $(1)
$(1)_DOCKERFILE ?= $(2)/Dockerfile
$(1)_COMPOSE ?= $(2)/compose.yaml
$(1)_PLATFORMS ?= linux/amd64,linux/arm64
$(1)_SHA := $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)
$(1)_SEC := $(CURDIR)/$(STD_BIN)/secrets.sh
.PHONY: $(1)-setup $(1)-doctor $(1)-dev $(1)-stop $(1)-logs $(1)-status $(1)-reset $(1)-check $(1)-build $(1)-release $(1)-clean $(1)-distclean

$(call std_verb,$(1),setup,setup,Create the buildx builder used for multi-arch builds)
$(1)-setup:
	@docker buildx inspect project-standard >/dev/null 2>&1 || docker buildx create --name project-standard --use

# The multi-arch build and the push need that builder: they create it first when buildx has no instance of that name
# (std_ready in common.mk; buildx keeps its builders as files under DOCKER_CONFIG, so no docker call is made).
$(call std_ready,$(1),$(2),docker_ready,build release)

$(call std_verb,$(1),doctor,setup,Docker daemon and buildx read only)
$(1)-doctor:
	@docker info >/dev/null && docker buildx version >/dev/null && echo "$(1): docker and buildx are running"

$(call std_verb,$(1),dev,dev,Start the compose stack of this part for local with its secrets in the environment)
$(1)-dev:
	@set -euo pipefail; test "$(ENV)" = local || { echo "$(1)-dev runs locally, drop ENV=$(ENV)"; exit 1; }; \
	test -f $$($(1)_COMPOSE) || { echo "$(1): no compose file at $$($(1)_COMPOSE)"; exit 1; }; \
	$$($(1)_SEC) exec --env local -- docker compose -f $$($(1)_COMPOSE) up -d --build --wait

$(call std_verb,$(1),stop,dev,Stop the compose stack of this part and keep its volumes)
$(1)-stop:
	@test -f $$($(1)_COMPOSE) && docker compose -f $$($(1)_COMPOSE) down || echo "$(1): no compose file, nothing to stop"

$(call std_verb,$(1),logs,dev,Follow the logs of the compose stack of this part)
$(1)-logs:
	@docker compose -f $$($(1)_COMPOSE) logs -f --tail 200

$(call std_verb,$(1),status,dev,Show the compose services of this part)
$(1)-status:
	@docker compose -f $$($(1)_COMPOSE) ps

$(call std_verb,$(1),reset,dev,Remove the compose volumes of this part so the next dev starts empty needs CONFIRM=local)
$(1)-reset:
	@test "$(ENV)" = local || { echo "$(1)-reset is for ENV=local only"; exit 1; }; $$(call std_confirm,local) && docker compose -f $$($(1)_COMPOSE) down -v

$(call std_verb,$(1),check,test,Lint the Dockerfile with hadolint when installed and validate the compose file)
$(1)-check:
	@set -euo pipefail; \
	if command -v hadolint >/dev/null 2>&1; then hadolint $$($(1)_DOCKERFILE); else echo "$(1): hadolint not installed, Dockerfile lint skipped"; fi; \
	if [ -f $$($(1)_COMPOSE) ]; then docker compose -f $$($(1)_COMPOSE) config -q; fi

# Multi-arch build, nothing loaded or pushed: proves that every platform builds.
$(call std_verb,$(1),build,deploy,Build the image for every platform in PLATFORMS without pushing)
$(1)-build:
	@docker buildx build --platform $$($(1)_PLATFORMS) -f $$($(1)_DOCKERFILE) $(2)

$(call std_verb,$(1),release,release,Build every platform and push the image tagged with the git sha and the env)
$(1)-release:
	@$$(std_production_guard) && { set -euo pipefail; \
	test -n "$(DOCKER_REGISTRY)" || { echo "$(1): set DOCKER_REGISTRY in the user config"; exit 1; }; \
	ref="$(DOCKER_REGISTRY)/$(PROJECT)/$$($(1)_IMAGE)"; \
	tags="-t $$$$ref:$$($(1)_SHA)"; \
	if [ "$(ENV)" != local ]; then tags="$$$$tags -t $$$$ref:$(ENV)"; fi; \
	if tag=$$$$(git describe --tags --exact-match 2>/dev/null); then tags="$$$$tags -t $$$$ref:$$$$tag"; fi; \
	for t in $$$$(git tag --points-at HEAD 2>/dev/null); do case "$$$$t" in $(1)-v*) tags="$$$$tags -t $$$$ref:$$$$(printf '%s' "$$$$t" | sed 's/^$(1)-v//')" ;; esac; done; \
	docker buildx build --platform $$($(1)_PLATFORMS) -f $$($(1)_DOCKERFILE) $$$$tags --push $(2); }

$(call std_verb,$(1),version,release,Image version from $(2)/VERSION)
$(1)-version:
	@printf '%s %s\n' "$(1)" "$$$$($$(STD_RELEASE) version --part $(1) --kind docker --part-dir $(2) 2>/dev/null || echo 'none yet (make $(1)-bump sets it)')"

$(call std_release,$(1),docker,$(2),docker_release_assets,release)

$(call std_verb,$(1),clean,dev,Stop the compose stack of this part and remove the local image)
$(1)-clean:
	@if [ -f $$($(1)_COMPOSE) ]; then docker compose -f $$($(1)_COMPOSE) down --remove-orphans; fi

$(call std_verb,$(1),distclean,dev,Clean and also remove the local image tags built for this part)
$(1)-distclean: $(1)-clean
	@docker image rm -f $(DOCKER_REGISTRY)/$(PROJECT)/$$($(1)_IMAGE):$$($(1)_SHA) >/dev/null 2>&1 || true
endef
