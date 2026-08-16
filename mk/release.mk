.PHONY: release-evidence release viewer-build viewer-serve harness-streamable-http-contract harness-run-local-fresh-boot viewer-local-e2e-check

release-evidence:
	bash scripts/release-evidence.sh _build/default/bin/main_eio.exe .release-evidence/local-release-evidence.md

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

# MCP streamable transport contract harness (Accept policy + deprecation headers)
harness-streamable-http-contract:
	scripts/harness_streamable_http_contract.sh

# Fresh temp-dir proof: run-local bootstrap -> /health -> initialize -> tools/list
harness-run-local-fresh-boot:
	scripts/harness/contract/run_local_fresh_boot_contract.sh

# Local E2E checklist runner (contracts + optional viewer build/smoke)
viewer-local-e2e-check:
	scripts/viewer-local-e2e-check.sh
