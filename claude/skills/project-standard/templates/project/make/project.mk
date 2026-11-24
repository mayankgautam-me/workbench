# make/project.mk: this project's own settings. The project-standard skill writes it once and never
# overwrites it; edit it freely.
#
# PROJECT    the project's name: its folder in the secrets repo (<PROJECT>/ in it), the prefix of
#            its CI variables and image names. Lowercase letters, digits and '-'.
# PORT_BASE  dev ports are PORT_BASE + an offset per part, so two projects can run `make dev` at once.
# PARTS      one entry per part, `name:kind[:dir]`; dir defaults to name. Every part gets the stage
#            commands of its kind as `make <name>-<verb>`, and the root `make <verb>` runs them all.
#            Kinds: zephyr espidf pio arm-gcc circuitpython silabs hardware altium mechanical
#                   cloud-worker web-pages app-flutter app-tauri app-xcode app-android docker go python
# CI_TEMPLATES_REPO  optional: owner/name of the reusable CI workflows, over the user config's (default
#            mayankgautam-me/ci-templates); scaffold the workflows again after changing it.
# The secrets repo follows the project's GitHub owner, the owner of its git remote origin: <owner>/secrets, checked
# out at ~/.secrets-<owner> (make secrets-doctor names it). Only to use another secrets repo, set both here, with
# ?= so CI's own SECRETS_DIR still wins:
#   SECRETS_DIR    ?= $(HOME)/.secrets-<name>
#   SECRETS_REMOTE ?= https://github.com/<owner>/<repo>.git
#
# Per-part settings are `<part>_<VAR> := value`, for example:
#   firmware_BOARD := nrf9151dk/nrf9151/ns
#   firmware_NCS   := v3.2.1
# A value given on the command line wins: `make firmware-build BOARD=...`.
#
# A firmware part (espidf, pio, zephyr, arm-gcc, silabs) can be built for an environment: C preprocessor defines for
# ENV=local, staging or production, each env optional, NAME=value words (a double-quoted value stays a C string):
#   firmware_ENV_DEFINES_staging    := CLOUD_URL="wss://api-staging.example.com/d/ws" LOG_LEVEL=3
#   firmware_ENV_DEFINES_production := CLOUD_URL="wss://api.example.com/d/ws"
# `make firmware-build ENV=staging` (and flash and release, which build first) compiles with them; with no line for
# ENV the code's own defaults apply. A flash or release with NOBUILD=1 refuses a build made for other defines. espidf
# needs a block in its CMakeLists.txt and an arm-gcc Makefile needs STD_ENV_CFLAGS (the part's README, make audit).

PROJECT   := @@PROJECT@@
PORT_BASE := @@PORT_BASE@@

PARTS := \
@@PARTS@@

# Per-part settings
@@SETTINGS@@
