.PHONY: all build dashboard dev-dashboard build-all doc install install-deps pin-external-deps dev-setup run

# Default target — OCaml + dashboard
all: build-all

# Build OCaml + dashboard (dashboard rebuilds only when sources changed)
build:
	scripts/dune-local.sh build
	@scripts/build-dashboard-if-needed.sh

# Build dashboard SPA (Vite) — force rebuild
dashboard:
	cd dashboard && pnpm install --frozen-lockfile && pnpm run build

# Dashboard dev server (Vite HMR, proxies /api + /sse to MASC :8935)
dev-dashboard:
	cd dashboard && pnpm dev

# Build everything: main masc + Preact dashboard.
build-all: build

# Build and install local binaries into ~/.local/bin (or PREFIX) and refresh registered browser-lane native hosts.
# Needs a workspace to check first: MASC_BASE_PATH, or run the script with --base-path.
install:
	bash scripts/install-local-build.sh $(if $(PREFIX),--prefix "$(PREFIX)")

# Generate documentation
doc:
	scripts/dune-local.sh build @doc
	@echo "Documentation generated at _build/default/_doc/_html/index.html"

# Install dependencies
install-deps:
	opam install ./masc.opam --deps-only --with-test -y

# Align external opam pins to repo SSOT.
pin-external-deps:
	bash scripts/opam-pin-external-deps.sh

# Development setup (installs pinned external packages + opam deps)
dev-setup:
	bash scripts/opam-pin-external-deps.sh --install
	$(MAKE) install-deps
	@echo "Development environment ready!"

# Start the MCP server (local development, standard port 8935)
run:
	dune exec --root . masc -- start --port 8935
