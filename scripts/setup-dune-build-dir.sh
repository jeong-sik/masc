#!/bin/bash
# Source this script in a masc-mcp worktree to set DUNE_BUILD_DIR.
# Prevents lock contention when multiple worktrees run dune concurrently.
export DUNE_BUILD_DIR="${PWD}/_build"
echo "DUNE_BUILD_DIR set to: ${DUNE_BUILD_DIR}"
