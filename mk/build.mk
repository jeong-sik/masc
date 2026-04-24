.PHONY: all build dashboard dev-dashboard bonsai-dashboard bonsai-dashboard-if-available dev-bonsai-dashboard clean-bonsai-dashboard bonsai-dashboard-tokens build-all doc install-deps pin-external-deps sync-oas-pin-docs dev-setup run

# Default target — OCaml + dashboard
all: build-all

# Build OCaml + dashboard (dashboard rebuilds only when sources changed)
build: doctor-oas-pin
	scripts/dune-local.sh build
	@scripts/build-dashboard-if-needed.sh

# Build dashboard SPA (Vite) — force rebuild
dashboard:
	cd dashboard && pnpm install --frozen-lockfile && pnpm run build

# Dashboard dev server (Vite HMR, proxies /api + /sse to MASC :8935)
dev-dashboard:
	cd dashboard && pnpm dev

# Build dashboard Bonsai island (js_of_ocaml, OxCaml switch `bonsai-dashboard`).
# See planning/claude-plans/masc-mcp-eventual-parrot.md.
# --root . pins dune to dashboard_bonsai/dune-project — otherwise dune walks
# up the directory tree (out of the worktree, into the real repo root) and
# misresolves the project. Must pair with OPAMSWITCH= so the env loads.
bonsai-dashboard:
	cd dashboard_bonsai && OPAMSWITCH=bonsai-dashboard opam exec -- dune build --root .
	mkdir -p assets/dashboard_bonsai
	rm -f assets/dashboard_bonsai/main.bc.js
	cp dashboard_bonsai/_build/default/bin/main.bc.js assets/dashboard_bonsai/main.bc.js
	# MASC Design System 토큰을 정적 자원으로 함께 배포.
	# 서버는 /dashboard/b/assets/colors_and_type.css로 이 파일을 서빙하고,
	# bonsai_index_html은 이 경로를 <link>로 참조한다. 추후 ppx_css 리터럴
	# 값을 var(--bg-deep) 등으로 점진 교체할 때 :root가 준비되어 있어야 한다.
	cp dashboard_bonsai/static/colors_and_type.css assets/dashboard_bonsai/colors_and_type.css

# Build Bonsai only if the OxCaml switch exists. Used by `build-all` so a
# single `make` run builds both main masc-mcp and the Bonsai island when
# the dev setup includes the extra switch, but does not block CI / first-
# time contributors who have not bootstrapped it.
bonsai-dashboard-if-available:
	@if opam switch list --short 2>/dev/null | grep -qx bonsai-dashboard; then \
	  echo "==> bonsai-dashboard switch detected, building Bonsai island..."; \
	  $(MAKE) bonsai-dashboard; \
	else \
	  echo "==> bonsai-dashboard switch not found — skipping Bonsai island."; \
	  echo "    Run \`opam switch create bonsai-dashboard ocaml-variants.5.2.0+ox\`"; \
	  echo "    (see docs/bonsai-migration/phase-0-report.md) to enable."; \
	fi

# Watch mode for the Bonsai island. Does not copy the artifact — pair with
# a separate tail of main.bc.js or re-run `make bonsai-dashboard` on save.
dev-bonsai-dashboard:
	cd dashboard_bonsai && OPAMSWITCH=bonsai-dashboard opam exec -- dune build --root . --watch

clean-bonsai-dashboard:
	rm -rf dashboard_bonsai/_build assets/dashboard_bonsai

# Deploy only the design-tokens stylesheet. Useful during a DS-only iteration
# where the bundle itself hasn't changed but the :root palette did.
bonsai-dashboard-tokens:
	mkdir -p assets/dashboard_bonsai
	cp dashboard_bonsai/static/colors_and_type.css assets/dashboard_bonsai/colors_and_type.css

# Build everything: main masc-mcp + Preact dashboard + Bonsai (if available).
# Note: `dune build` at the repo root only compiles the main OCaml — the
# Bonsai island lives on a separate OxCaml switch and cannot be driven
# from the same dune invocation. Use `make` for the full build.
build-all: build bonsai-dashboard-if-available

# Generate documentation
doc:
	scripts/dune-local.sh build @doc
	@echo "Documentation generated at _build/default/_doc/_html/index.html"

# Install dependencies
install-deps:
	opam install . --deps-only --with-test -y

# Align first-party opam pins (agent_sdk, grpc-direct, etc.) to repo SSOT.
pin-external-deps:
	bash scripts/opam-pin-external-deps.sh

sync-oas-pin-docs:
	bash scripts/sync-oas-pin-docs.sh

# Development setup
dev-setup: pin-external-deps install-deps
	@echo "Development environment ready!"

# Start the MCP server (local development)
run:
	dune exec --root . masc-mcp -- --port 8933
