# project-standard v1.5 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
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
# DOCKER_REGISTRY follows the project's owner (common.mk): ghcr.io/<owner, lowercase>, unless make/project.mk sets it
# (the user config's applies only to its own owner's projects). The version is <dir>/VERSION (make <name>-bump writes it).
# Compose runs under `secrets.sh exec --env local`, so its ${VARIABLES} come from the environment.
#
# Every build and push carries the OCI labels (and, when buildx can, the same annotations on the pushed index) that
# make ghcr.io link the package to its repository and inherit its access: org.opencontainers.image.source
# (DOCKER_IMAGE_SOURCE: https://github.com/<GITHUB_REPOSITORY> in CI, else the origin's), .revision (the full git sha),
# .version (on the tag <name>-v<version>) and .created. On ghcr.io, setup logs docker in with gh's token (make/bin/ghcr.sh);
# <name>-prune-images lists the old untagged and sha-only versions and deletes them with CONFIRM=prune.
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

# The image's repository for the source label: CI's GITHUB_REPOSITORY, else the GitHub origin (common.mk reads it once).
DOCKER_IMAGE_SOURCE ?= $(if $(GITHUB_REPOSITORY),https://github.com/$(GITHUB_REPOSITORY),$(if $(STD_ORIGIN_REPO),https://github.com/$(STD_ORIGIN_OWNER)/$(STD_ORIGIN_REPO)))

# docker_oci part,push : shell text that sets the bash array oci to the --label (and with push, --annotation index:)
# arguments of buildx. Annotations only when this buildx has --annotation (0.12 and later).
docker_oci = oci_rev=$$(git rev-parse HEAD 2>/dev/null || true); oci_ver=; \
  for oci_t in $$(git tag --points-at HEAD 2>/dev/null); do case "$$oci_t" in $(1)-v*) oci_ver="$${oci_t\#$(1)-v}";; esac; done; \
  oci_ann=; if [ "$(2)" = push ] && docker buildx build --help 2>/dev/null | grep -q -- '--annotation'; then oci_ann=1; fi; \
  oci=(); oci_add() { oci+=(--label "org.opencontainers.image.$$1=$$2"); if [ -n "$$oci_ann" ]; then oci+=(--annotation "index:org.opencontainers.image.$$1=$$2"); fi; }; \
  if [ -n "$(DOCKER_IMAGE_SOURCE)" ]; then oci_add source "$(DOCKER_IMAGE_SOURCE)"; fi; \
  if [ -n "$$oci_rev" ]; then oci_add revision "$$oci_rev"; fi; \
  if [ -n "$$oci_ver" ]; then oci_add version "$$oci_ver"; fi; \
  oci_add created "$$(date -u +%Y-%m-%dT%H:%M:%SZ)";

STD_GHCR = bash $(CURDIR)/$(STD_BIN)/ghcr.sh

docker_ready = [ -f "$${DOCKER_CONFIG:-$$HOME/.docker}/buildx/instances/project-standard" ]

define kind_docker
$(1)_IMAGE ?= $(1)
$(1)_DOCKERFILE ?= $(2)/Dockerfile
$(1)_COMPOSE ?= $(2)/compose.yaml
$(1)_PLATFORMS ?= linux/amd64,linux/arm64
$(1)_SHA := $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)
$(1)_SEC := $(CURDIR)/$(STD_BIN)/secrets.sh
.PHONY: $(1)-setup $(1)-doctor $(1)-dev $(1)-stop $(1)-logs $(1)-status $(1)-reset $(1)-check $(1)-build $(1)-release $(1)-clean $(1)-distclean $(1)-prune-images

$(call std_verb,$(1),setup,setup,Create the buildx builder used for multi-arch builds and log docker in to ghcr.io with the gh token)
$(1)-setup:
	@docker buildx inspect project-standard >/dev/null 2>&1 || docker buildx create --name project-standard --use
	@$$(STD_GHCR) login --registry "$$(DOCKER_REGISTRY)"

# The multi-arch build and the push need that builder: they create it first when buildx has no instance of that name
# (std_ready in common.mk; buildx keeps its builders as files under DOCKER_CONFIG, so no docker call is made).
$(call std_ready,$(1),$(2),docker_ready,build release)

$(call std_verb,$(1),doctor,setup,Docker daemon and buildx and the registry login and the write:packages scope of gh read only)
$(1)-doctor:
	@docker info >/dev/null && docker buildx version >/dev/null && echo "$(1): docker and buildx are running"
	@echo "$(1): registry $$(or $$(DOCKER_REGISTRY),none: add the GitHub remote origin or set DOCKER_REGISTRY in make/project.mk)$$(if $$(STD_DOCKER_REGISTRY_FROM), (from $$(STD_DOCKER_REGISTRY_FROM)))"; $$(STD_GHCR) doctor --registry "$$(DOCKER_REGISTRY)"

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
	@set -euo pipefail; $$(call docker_oci,$(1),) docker buildx build --platform $$($(1)_PLATFORMS) "$$$${oci[@]}" -f $$($(1)_DOCKERFILE) $(2)

$(call std_verb,$(1),release,release,Build every platform and push the image tagged with the git sha and the env)
$(1)-release:
	@$$(std_production_guard) && { set -euo pipefail; \
	test -n "$(DOCKER_REGISTRY)" || { echo "$(1): no DOCKER_REGISTRY: add the GitHub remote origin (ghcr.io/<owner> follows it) or set DOCKER_REGISTRY in make/project.mk"; exit 1; }; \
	ref="$(DOCKER_REGISTRY)/$(PROJECT)/$$($(1)_IMAGE)"; \
	tags="-t $$$$ref:$$($(1)_SHA)"; \
	if [ "$(ENV)" != local ]; then tags="$$$$tags -t $$$$ref:$(ENV)"; fi; \
	if tag=$$$$(git describe --tags --exact-match 2>/dev/null); then tags="$$$$tags -t $$$$ref:$$$$tag"; fi; \
	for t in $$$$(git tag --points-at HEAD 2>/dev/null); do case "$$$$t" in $(1)-v*) tags="$$$$tags -t $$$$ref:$$$$(printf '%s' "$$$$t" | sed 's/^$(1)-v//')" ;; esac; done; \
	$$(call docker_oci,$(1),push) \
	docker buildx build --platform $$($(1)_PLATFORMS) "$$$${oci[@]}" -f $$($(1)_DOCKERFILE) $$$$tags --push $(2); }

# Old versions in ghcr.io: listed (read only) unless CONFIRM=prune is on the command line, which deletes them.
$(call std_extra,$(1),prune-images,release,List the untagged and sha-only versions of the image in ghcr.io older than KEEP_DAYS (30) and CONFIRM=prune deletes them)
$(1)-prune-images:
	@$$(if $$(CONFIRM),$$(call std_confirm,prune) && CONFIRM=prune )$$(STD_GHCR) prune --image "$$(DOCKER_REGISTRY)/$$(PROJECT)/$$($(1)_IMAGE)" --keep-days "$$(or $$(KEEP_DAYS),30)"$$(if $$(CONFIRM), --remove)

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
