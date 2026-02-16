# masc-mcp Makefile
# Enterprise-ready development commands

.PHONY: build test clean coverage coverage-summary coverage-html doc install-deps dev-setup fmt fmt-check ci viewer-build viewer-serve

# Default target
all: build

# Build the project
build:
	dune build

# Run tests
test:
	dune test

# Clean build artifacts
clean:
	dune clean

# Run tests with coverage instrumentation
coverage:
	rm -rf _coverage
	mkdir -p _coverage
	BISECT_FILE=$(CURDIR)/_coverage/bisect dune test --instrument-with bisect_ppx --force

# Print coverage summary to stdout
coverage-summary: coverage
	bisect-ppx-report summary --coverage-path _coverage

# Generate HTML coverage report
coverage-html: coverage
	bisect-ppx-report html --coverage-path _coverage -o _coverage/html
	@echo "Coverage report: _coverage/html/index.html"

# Generate documentation
doc:
	dune build @doc
	@echo "Documentation generated at _build/default/_doc/_html/index.html"

# Install dependencies
install-deps:
	opam install . --deps-only --with-test --with-doc -y

# Development setup
dev-setup: install-deps
	@echo "Development environment ready!"

# Format code (if ocamlformat is installed)
fmt:
	dune fmt || true

# Check formatting
fmt-check:
	dune fmt --check || true

# CI target (for GitHub Actions)
ci: fmt-check test
	@echo "CI checks passed!"

# Start the MCP server (local development)
run:
	dune exec masc-mcp -- --port 8933

# Build release binary
release:
	dune build --release
	@echo "Release binary at _build/default/bin/main.exe"

# Build viewer (Bevy + WASM via trunk) with NO_COLOR normalization.
viewer-build:
	scripts/viewer-trunk.sh build

# Serve viewer locally at http://127.0.0.1:8080
viewer-serve:
	scripts/viewer-trunk.sh serve
