.PHONY: diagnostics-disk-hygiene fix-disk-hygiene fix-disk-hygiene-hard fmt fmt-check health ocaml-health check-memory-leak ci

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

# Health snapshot (typecheck + unsafe pattern counts)
health:
	@mkdir -p .health
	bash scripts/health_snapshot.sh --json-out .health/health-snapshot.json
	@echo "Health snapshot: .health/health-snapshot.json"

# Warn-only OCaml north-star snapshot. This reports risk-pattern counts without
# changing CI policy or the public AGENT_CORE/MCP/task semantics.
ocaml-health:
	@mkdir -p .health
	bash scripts/ocaml-north-star-health.sh --json-out .health/ocaml-north-star-health.json
	@echo "OCaml north-star snapshot: .health/ocaml-north-star-health.json"

# Build and run a Valgrind-based startup/MCP smoke check for memory leaks
check-memory-leak:
	bash scripts/check-memory-leak.sh

# CI target (for GitHub Actions)
ci: fmt-check test test-contract test-transport
	@echo "CI checks passed!"
