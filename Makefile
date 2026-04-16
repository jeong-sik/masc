# masc-mcp Makefile
# Enterprise-ready development commands

.PHONY: build test test-unit test-contract test-contract-live test-transport test-webrtc-live-env test-all clean coverage coverage-summary coverage-html coverage-percent doc install-deps pin-external-deps sync-oas-pin-docs doctor-oas-pin dev-setup fmt fmt-check health ci dashboard dev-dashboard build-all viewer-build viewer-serve harness-game-view-contract harness-streamable-http-contract harness-trpg-session-contract harness-trpg-grimland-smoke viewer-local-e2e-check check-memory-leak

# Default target — OCaml + dashboard
all: build-all

# Build OCaml + dashboard (dashboard rebuilds only when sources changed)
build: doctor-oas-pin
	dune build --root .
	@scripts/build-dashboard-if-needed.sh

# Build dashboard SPA (Vite) — force rebuild
dashboard:
	cd dashboard && pnpm install --frozen-lockfile && pnpm run build

# Dashboard dev server (Vite HMR, proxies /api + /sse to MASC :8935)
dev-dashboard:
	cd dashboard && pnpm dev

# Build everything (alias for build)
build-all: build

# Run tests (alias for test-unit)
test: test-unit

# Unit tests only (no server required)
test-unit: doctor-oas-pin
	scripts/ci-run-tests.sh "opam exec -- dune test --root ."

# Contract harness (self-bootstrapping, hermetic local server)
test-contract:
	bash scripts/harness/contract/run_all.sh

# Transport harness (self-bootstrapping, hermetic local server)
test-transport:
	bash scripts/harness/transport/run_all.sh

# Env-gated browser/STUN/TURN WebRTC interop proof
test-webrtc-live-env:
	bash scripts/harness/transport/verify_webrtc_live_env.sh

# Contract harness against an already running server (default :8935)
test-contract-live:
	bash scripts/harness/contract/streamable_http_contract.sh
	bash scripts/harness/contract/team_session_contract.sh
	bash scripts/harness/contract/golden_path_1_contract.sh

# All tests: unit + contract + transport
test-all: test-unit test-contract test-transport

# Clean build artifacts
clean:
	dune clean --root .

# Run tests with coverage instrumentation
coverage:
	rm -rf _coverage
	mkdir -p _coverage
	CI_TEST_TIMEOUT_SEC=1200 CI_TEST_HEARTBEAT_SEC=30 scripts/ci-run-tests.sh "BISECT_FILE=$(CURDIR)/_coverage/bisect opam exec -- dune test --root . --instrument-with bisect_ppx --force"

# Print coverage summary to stdout
coverage-summary: coverage
	bisect-ppx-report summary --coverage-path _coverage

# Print project coverage percentage as a single float
coverage-percent:
	scripts/coverage_percent.sh

# Generate HTML coverage report
coverage-html: coverage
	bisect-ppx-report html --coverage-path _coverage -o _coverage/html
	@echo "Coverage report: _coverage/html/index.html"

# Generate documentation
doc:
	dune build --root . @doc
	@echo "Documentation generated at _build/default/_doc/_html/index.html"

# Install dependencies
install-deps:
	opam install . --deps-only --with-test -y

# Align first-party opam pins (agent_sdk, grpc-direct, etc.) to repo SSOT.
pin-external-deps:
	bash scripts/opam-pin-external-deps.sh

sync-oas-pin-docs:
	bash scripts/sync-oas-pin-docs.sh

release-evidence:
	bash scripts/release-evidence.sh _build/default/bin/main_eio.exe .release-evidence/local-release-evidence.md

# Fast local-only doctor for OAS/agent_sdk pin drift in the current switch.
doctor-oas-pin:
	bash scripts/check-oas-pin.sh --local-only

# Development setup
dev-setup: pin-external-deps install-deps
	@echo "Development environment ready!"

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

# Build and run a Valgrind-based startup/MCP smoke check for memory leaks
check-memory-leak:
	bash scripts/check-memory-leak.sh

# CI target (for GitHub Actions)
ci: fmt-check test test-contract test-transport
	@echo "CI checks passed!"

# Start the MCP server (local development)
run:
	dune exec --root . masc-mcp -- --port 8933

# Build release binary
release:
	dune build --root . --release
	@echo "Release binary at _build/default/bin/main_eio.exe"

# Build viewer (Bevy + WASM via trunk) with NO_COLOR normalization.
viewer-build:
	scripts/viewer-trunk.sh build

# Serve viewer locally at http://127.0.0.1:8080
viewer-serve:
	scripts/viewer-trunk.sh serve

# GAME-VIEW contract harness (decision/experiment/trpg gate checks)
harness-game-view-contract:
	scripts/harness_game_view_precondition.sh

# MCP streamable transport contract harness (Accept policy + deprecation headers)
harness-streamable-http-contract:
	scripts/harness_streamable_http_contract.sh

# TRPG session bootstrap contract harness (preset/pool/party/session/intervention)
harness-trpg-session-contract:
	scripts/harness_trpg_session_contract.sh

# TRPG Grimland smoke workload (manual/nightly; set RUN_ROUND=1 for keeper rounds)
harness-trpg-grimland-smoke:
	scripts/run_trpg_grimland_smoke.sh

# Local E2E checklist runner (contracts + optional viewer build/smoke)
viewer-local-e2e-check:
	scripts/viewer-local-e2e-check.sh
# Formatting
