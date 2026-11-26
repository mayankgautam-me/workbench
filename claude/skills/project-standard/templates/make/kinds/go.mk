# project-standard v1.13 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Kind go: a Go module with one main package (a service or a CLI).
#
# make/project.mk declares it as   <name>:go:<dir>   and may set, per part:
#   <name>_PKG          main package to build and run      (default: ./cmd/<name>)
#   <name>_BIN          binary path inside the module      (default: bin/<name>)
#   <name>_PORT_OFFSET  dev port is PORT_BASE + offset     (default 0; exported to the process as PORT)
#   <name>_PLATFORMS    os/arch list release builds        (default: linux and darwin, amd64 and arm64)
#
# The Go toolchain comes from mise.toml (go = "...") through the root setup. dev runs with the local
# secrets in the environment. release cross-compiles static binaries for PLATFORMS into dist/ with a
# sha256 file, named from the VERSION file of the module (which make <name>-bump sets). The GitHub Release
# (<name>-github-release, on the tag <name>-v<version>) attaches those binaries.

# GitHub Release assets: the binaries <part>-release cross-compiles, <part>-<version>-<os>-<arch>.
go_release_assets = set -euo pipefail; $(call std_rel_begin,$(1),go,$(2)) \
  bins=0; for f in "$(CURDIR)/$(2)/dist/$(1)-$$ver-"*-*; do [ -f "$$f" ] || continue; put "$$f"; bins=$$((bins + 1)); done; \
  [ "$$bins" -gt 0 ] || { echo "$(1): no binaries of $$ver in $(2)/dist: run make $(1)-release" >&2; exit 1; }; \
  $(std_rel_end)

define kind_go
$(1)_PKG ?= ./cmd/$(1)
$(1)_PLATFORMS ?= linux/amd64 linux/arm64 darwin/amd64 darwin/arm64
$(1)_BIN ?= bin/$(1)
$(1)_PORT_OFFSET ?= 0
$(1)_SEC := $(CURDIR)/$(STD_BIN)/secrets.sh
.PHONY: $(1)-setup $(1)-dev $(1)-check $(1)-test $(1)-format $(1)-build $(1)-release $(1)-version $(1)-clean

$(call std_verb,$(1),setup,setup,Download the Go modules)
$(1)-setup:
	@cd $(2) && go mod download

$(call std_verb,$(1),dev,dev,Run the service locally with the local secrets in the environment)
$(1)-dev:
	@set -euo pipefail; test "$(ENV)" = local || { echo "$(1)-dev runs locally, drop ENV=$(ENV)"; exit 1; }; \
	cd $(2) && $$($(1)_SEC) exec --env local -- env PORT=$(shell expr $(PORT_BASE) + $(or $($(1)_PORT_OFFSET),0)) go run $$($(1)_PKG)

$(call std_verb,$(1),check,test,gofmt vet and the race-enabled tests)
$(1)-check:
	@set -euo pipefail; cd $(2); \
	unformatted=$$$$(gofmt -l .); \
	test -z "$$$$unformatted" || { echo "$(1): not gofmt-formatted: $$$$unformatted"; exit 1; }; \
	go vet ./...; \
	go test -race ./...

$(call std_verb,$(1),test,test,Race-enabled unit tests with TEST=pattern for one test)
$(1)-test:
	@cd $(2) && go test -race $(if $(TEST),-run '$(TEST)') ./...

$(call std_verb,$(1),format,test,Rewrite the formatting with gofmt)
$(1)-format:
	@cd $(2) && gofmt -w .

$(call std_verb,$(1),build,deploy,Build the binary for this machine into the bin directory)
$(1)-build:
	@cd $(2) && CGO_ENABLED=0 go build -o $$($(1)_BIN) $$($(1)_PKG)

$(call std_verb,$(1),release,release,Cross-compile static binaries for PLATFORMS with checksums into dist)
$(1)-release: $(1)-check
	@set -euo pipefail; cd $(2); \
	ver=$$$$(cat VERSION 2>/dev/null || echo dev); \
	mkdir -p dist; \
	for p in $$($(1)_PLATFORMS); do os=$$$$(dirname "$$$$p"); arch=$$$$(basename "$$$$p"); \
	  CGO_ENABLED=0 GOOS=$$$$os GOARCH=$$$$arch go build -trimpath -ldflags "-s -w -X main.version=$$$$ver" -o dist/$(1)-$$$$ver-$$$$os-$$$$arch $$($(1)_PKG); \
	done; \
	( cd dist && { sha256sum $(1)-$$$$ver-*-* 2>/dev/null || shasum -a 256 $(1)-$$$$ver-*-*; } > $(1)-$$$$ver.sha256 ); \
	ls -1 dist

$(call std_release,$(1),go,$(2),go_release_assets,release)

$(call std_verb,$(1),version,setup,Print the version from the VERSION file)
$(1)-version:
	@cat $(2)/VERSION 2>/dev/null || echo "dev"

$(call std_verb,$(1),clean,dev,Remove the binaries and the release output)
$(1)-clean:
	@rm -rf "$(2)/bin" "$(2)/dist"
endef
