.PHONY: doctor-oas-pin doctor-disk-hygiene fix-disk-hygiene fix-disk-hygiene-hard doctor-oas-drift dashboard-drift-check dashboard-drift-regen fmt fmt-check health ocaml-health check-memory-leak check-silent check-ssot check-variants ci

# Fast local-only doctor for OAS/agent_sdk pin drift in the current switch.
doctor-oas-pin:
	bash scripts/check-oas-pin.sh --local-only

# Disk hygiene snapshot for TLC artefacts, Dune cache drift, isolated builds, worktree fan-out.
doctor-disk-hygiene:
	bash scripts/disk-hygiene.sh

# Safe fixes only: TLC artefact cleanup + Dune cache trim.
fix-disk-hygiene:
	bash scripts/disk-hygiene.sh --fix

# Hard reset path for cache drift: also reset ~/.cache/dune and remove stray _build_* dirs.
fix-disk-hygiene-hard:
	bash scripts/disk-hygiene.sh --fix --reset-dune-cache --clean-extra-build-dirs

# Check OAS API surface (Event_bus variants, HttpError variants, Metrics fields)
# against scripts/oas-api-surface.json fingerprint. Catches upstream variant/field
# additions before they surface as scattered non-exhaustive warnings in consumer
# modules. Regenerate with: bash scripts/oas-drift-check.sh --regenerate
doctor-oas-drift:
	bash scripts/oas-drift-check.sh

# Dashboard styling-drift ratchet gate — fail if forbidden Tailwind patterns
# (bg-white/N, border-white/N, rounded-[Npx], text-zinc-*, text-[9px], ...)
# increase above the committed baseline. Regenerate baseline with the -regen
# target after an intentional bulk-migration.
dashboard-drift-check:
	bash scripts/dashboard-drift-check.sh

dashboard-drift-regen:
	bash scripts/dashboard-drift-check.sh --regenerate

# Format code (if ocamlformat is installed)
fmt:
	dune fmt --root . || true

# Check formatting
fmt-check:
	dune fmt --root . --preview || true

# Health snapshot (typecheck + anti-fake + unsafe pattern counts)
health:
	@mkdir -p .health
	bash scripts/health_snapshot.sh --json-out .health/health-snapshot.json
	@echo "Health snapshot: .health/health-snapshot.json"

# Warn-only OCaml north-star snapshot. This reports risk-pattern counts without
# changing CI policy or the public OAS/MCP/task semantics.
ocaml-health:
	@mkdir -p .health
	bash scripts/ocaml-north-star-health.sh --json-out .health/ocaml-north-star-health.json
	@echo "OCaml north-star snapshot: .health/ocaml-north-star-health.json"

# Build and run a Valgrind-based startup/MCP smoke check for memory leaks
check-memory-leak:
	bash scripts/check-memory-leak.sh

# Silent failure gate — wildcard fallback + default value pattern grep.
# Runs all three complementary lints as hard-fail checks:
#   1. scripts/check_silent_failure.sh --strict  — try/ignore + Result.iter_error swallows
#   2. scripts/ci/check-silent-failure-patterns.sh — try/ignore, wildcard->(), Hashtbl.find, Option.get
#   3. scripts/lint/no-unknown-permissive-default.sh — string-parsing match `| _ -> ConcreteDefault`
# Meta-issue: #9517
check-silent:
	@echo "=== check-silent: noisy-by-default contract sweep ==="
	bash scripts/check_silent_failure.sh --strict
	bash scripts/ci/check-silent-failure-patterns.sh
	bash scripts/lint/no-unknown-permissive-default.sh
	@echo "=== check-silent: PASS ==="

# SSOT fingerprint diff + orphan spec validation.
# Runs all three SSOT gate scripts:
#   1. scripts/check-ssot.sh          — ratchet-based bypass checks (R1–R5)
#   2. scripts/ci/check-ssot-spawn-drift.sh — Provider_adapter ↔ Spawn symmetry
#   3. scripts/check-spec-truth.sh    — TLA+ Mirrors: orphan spec validator
# Meta-issue: #9516
check-ssot:
	@echo "=== SSOT gate: ratchet bypass checks ==="
	bash scripts/check-ssot.sh
	@echo ""
	@echo "=== SSOT gate: spawn adapter drift ==="
	bash scripts/ci/check-ssot-spawn-drift.sh
	@echo ""
	@echo "=== SSOT gate: spec truth (orphan spec validator) ==="
	bash scripts/check-spec-truth.sh

# Cross-language variant sync: OCaml all_phases / all_X lists vs TypeScript
# union types vs TLA+ domain literals. Fails on drift. Run before any PR that
# adds/removes a variant/enum constructor.
check-variants:
	bash scripts/check-variants.sh

# CI target (for GitHub Actions)
ci: fmt-check test test-contract test-transport
	@echo "CI checks passed!"
