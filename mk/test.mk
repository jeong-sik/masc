.PHONY: test test-unit test-contract test-transport test-webrtc-live-env test-contract-live test-all clean clean-tlc-artifacts coverage coverage-summary coverage-percent coverage-html

# Run tests (alias for test-unit)
test: test-unit

# Unit tests only (no server required)
test-unit: diagnostics-oas-pin
	scripts/ci-run-tests.sh "scripts/dune-local.sh test"

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
	bash scripts/harness/contract/golden_path_1_contract.sh

# All tests: unit + contract + transport
test-all: test-unit test-contract test-transport

# Clean build artifacts
clean:
	dune clean --root .
	bash scripts/cleanup-tlc-artifacts.sh

clean-tlc-artifacts:
	bash scripts/cleanup-tlc-artifacts.sh

# Run tests with coverage instrumentation
coverage:
	rm -rf _coverage
	mkdir -p _coverage
	CI_TEST_HEARTBEAT_SEC=30 scripts/ci-run-tests.sh "BISECT_FILE=$(CURDIR)/_coverage/bisect scripts/dune-local.sh test --instrument-with bisect_ppx --force"

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
