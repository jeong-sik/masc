# masc-mcp Makefile
# Compose development targets from feature-specific fragments.

# Isolate build directory per worktree to prevent dune lock contention
# when multiple worktrees run concurrent builds.
export DUNE_BUILD_DIR ?= $(CURDIR)/_build

MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
.DEFAULT_GOAL := all

include $(MAKEFILE_DIR)mk/build.mk
include $(MAKEFILE_DIR)mk/test.mk
include $(MAKEFILE_DIR)mk/quality.mk
include $(MAKEFILE_DIR)mk/release.mk
