# make/local.mk: targets only this project needs. Not managed: the project-standard skill never
# overwrites it. It is included last, so every variable from project.mk and common.mk is available.
#
# Document a target with a `## ` comment after its prerequisites, and `make help` lists it under
# "project":
#
#   .PHONY: render-case
#   render-case: ## Render the enclosure STEP to PNG for the README
#   	@./scripts/render-case.sh
#
# A target here must not reuse a standard name (setup, dev, check, deploy, <part>-<verb>, ...).
