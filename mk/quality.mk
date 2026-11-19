.PHONY: diagnostics-disk-hygiene fix-disk-hygiene fix-disk-hygiene-hard fmt fmt-check check-memory-leak ci

# Disk hygiene snapshot for TLC artefacts, Dune cache drift, isolated builds, worktree fan-out.
diagnostics-disk-hygiene:
	bash scripts/disk-hygiene.sh

# Safe fixes only: TLC artefact cleanup + Dune cache trim.
fix-disk-hygiene:
	bash scripts/disk-hygiene.sh --fix

# Hard reset path for cache drift: also reset ~/.cache/dune and remove stray _build_* dirs.
fix-disk-hygiene-hard:
	bash scripts/disk-hygiene.sh --fix --reset-dune-cache --clean-extra-build-dirs

# Format code (if ocamlformat is installed)
fmt:
	dune fmt --root . || true

# Check formatting
fmt-check:
	dune fmt --root . --preview || true

# Build and run a Valgrind-based startup/MCP smoke check for memory leaks
check-memory-leak:
	bash scripts/check-memory-leak.sh

# CI target (for GitHub Actions)
ci: fmt-check test test-contract test-transport
	@echo "CI checks passed!"
