.PHONY: release-evidence release harness-streamable-http-contract harness-run-local-fresh-boot

release-evidence:
	bash scripts/release-evidence.sh _build/default/bin/main_eio.exe artifacts/release-evidence/local-release-evidence.md

# Build release binary
release:
	dune build --root . --release
	@echo "Release binary at _build/default/bin/main_eio.exe"

# MCP streamable transport contract harness (Accept policy + deprecation headers)
harness-streamable-http-contract:
	scripts/harness_streamable_http_contract.sh

# Fresh temp-dir proof: run-local bootstrap -> /health -> initialize -> tools/list
harness-run-local-fresh-boot:
	scripts/harness/contract/run_local_fresh_boot_contract.sh
