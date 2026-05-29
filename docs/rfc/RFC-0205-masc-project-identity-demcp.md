# RFC-0205 Project identity is "masc", not "masc-mcp"

| | |
|---|---|
| Status | Draft |
| Author | jeong-sik (yousleepwhen) |
| Created | 2026-05-29 |
| Related | RFC-0165 (MCP server client-agnostic — merged #18203), RFC-0166 (MCP-client coupling closeout — draft), `docs/MCP-SURFACE-AUDIT.md` |
| Scope | Project/product identity tokens (`masc-mcp` / `masc_mcp` / `MASC-MCP`) across opam package, dune public_names, server handshake, agent-card, docs, launcher/service files, deploy artifacts, dashboard repo-coupled identifiers. **Not** the MCP protocol surface. |
| Repos | masc-mcp |

## 0. Decision log

- **2026-05-29:** Author chose **Option B** (full namespace — `Masc_mcp` → `Masc`, 766-file atomic codemod) as the end state (§4). Phase 1 (identity convergence on the handshake/health/discovery labels) lands **now**, alongside this RFC, as a Draft PR. Phases 4–5 remain gated on the §7 answers (repo rename, Railway service, release-asset policy, in-flight `lib/` coordination).

## 1. Problem

The project presents itself under two different names depending on which surface you read:

- **`masc` (the product):** `lib/auth_login.ml:131,170` (`server_name = "masc"`), `lib/cascade/cascade_transport.ml:278` (`allowed_server_names = ["masc"]`), `cascade_transport_authorization.ml:76`, and the seven `masc-*` auxiliary binaries in `bin/dune` (`masc-cost`, `masc-tui`, …) all already emit the bare `masc` brand.
- **`masc-mcp` / `MASC-MCP` (the product + a transport):** the public MCP `initialize` handshake (`lib/mcp_server.ml:97`, `serverInfo.name = "masc-mcp"`), the HTTP `/agent-card` (`lib/server/server_routes_http_runtime.ml:97`, `name = "MASC-MCP"`), the opam package (`dune-project:5,24`, `masc_mcp`), the README H1, the launcher script, and the systemd/launchd units.

This is an ungoverned split-brain. The Model Context Protocol is **one interface among several** (cascade transport, HTTP, CLI, stdio); it is not the product. Yet the most visible client-facing surface — the MCP handshake — advertises the transport as if it were the product name. The author's decision (2026-05-29): the product is **MASC**; MCP terminology is retained only where it honestly names the protocol.

This is a **new axis** not covered by prior RFCs. RFC-0165/0166 govern *protocol/client coupling* (whether the server knows its clients). This RFC governs *server self-identity* (what the product calls itself). The two are orthogonal; this RFC must not re-introduce client coupling or rename protocol tokens.

### Scale (measured 2026-05-29)

| Metric | Count | Source |
|---|---:|---|
| Tracked files containing `mcp` (any case) | 2,126 | `git grep -lI -i mcp` |
| Total `mcp` occurrences | 14,759 | `git grep -I -i -c mcp` |
| Tracked filenames containing `mcp` | 115 | `git ls-files \| rg -i mcp` |
| …of which carry the **brand** token `masc-mcp`/`masc_mcp` | **7** | classifier pass |
| …of which carry a **bare protocol** stem (`mcp_server`, `mcp_session`, …) | **108** | classifier pass |
| `.ml`/`.mli` files referencing module `Masc_mcp` | **766** | `262 open Masc_mcp + ~504 qualified` |

The headline: of 14,759 occurrences, the overwhelming majority is the protocol (`mcp_*`) or the internal OCaml namespace (`Masc_mcp`), neither of which is a user-facing surface. The actual **identity** surface is small.

## 2. Decision — the disambiguation rule

A single token disambiguates rename from retain:

- **RENAME (identity):** the *compound brand stem* `masc-mcp` / `masc_mcp` / `MASC-MCP`. This is the product naming itself. → `masc` / `MASC`.
- **RETAIN (protocol):** a *bare* `mcp` stem (`mcp_server.ml`, `/mcp`, `mcp_session`, `Mcp-Session-Id`, `protocolVersion`, JSON-RPC methods, "MCP server/tools/resources" prose). This honestly names the Model Context Protocol. Renaming it would be a false statement and/or a protocol break.

Convergence, not invention: `masc` is the name `auth_login` and `cascade_transport` *already* emit. This RFC moves the lagging handshake/agent-card/package onto it.

## 3. RETAIN set (protocol — explicitly stays `mcp`)

| Item | Why it stays |
|---|---|
| 108 of 115 `*mcp*` filenames | Implement/test/document the protocol: `lib/mcp_server*`, `lib/mcp_session/*`, `lib/mcp_transport_protocol/*`, `lib/server/server_mcp_*`, `lib/cascade/cascade_transport_*mcp*`, `lib/keeper/*_mcp_*`, `dashboard/src/api/mcp.ts`, `viewer/.../mcp_rpc.rs`, `docs/MCP-*.md`, `RFC-016x-mcp-*.md`, `test/test_mcp_*`. |
| `Mcp-Session-Id` HTTP header | Literal MCP spec header. Renaming breaks clients. |
| `protocolVersion` + `Mcp_protocol.Version` | Spec handshake field, validated against external opam dep. |
| JSON-RPC methods + `/mcp` route | `tools/list`, `tools/call`, `resources/list`, `prompts/list`, `initialize`; the wire surface. |
| external opam dep `mcp_protocol (>= 1.3.0)` | Third-party package; not ours to rename. |
| `MCP_*` / `MASC_MCP_*` env vars | **Client-owned config contract per RFC-0165.** `MASC_MCP_PORT/HTTP/VERSION/PREFIX/REPO`, dashboard `MCP_*_TIMEOUT_MS`. A prefix migration needs a deprecation alias, not an inline rename. |
| "MCP server / MCP tools / MCP resources" prose | Literal-true-statement rule. README tagline `MCP 서버` (line 10), `serverInfo.description`, `agent_card.description`, nav "Registered MCP tools", `MCP-SURFACE-AUDIT.md` (20+). |
| `auth_login` + cascade `server_name = "masc"` | **Already the target.** Proof the rename direction is convergence, not invention. |
| dashboard protocol identifiers | `callMcpTool`, `mcpHeaders`, `transport:'mcp_http'`, `public_mcp`/`spawned_agent_mcp` enum values, `McpCallResponse` types. Must match backend JSON contract. |
| `mcp_sdk_adapter_masc.*` | The file *is* the MCP SDK adapter; protocol-dominant. (`masc` suffix is already the target brand.) |

## 4. The central decision — OCaml namespace depth (Option A vs B)

dune separates `(name)` (the internal wrapped module) from `(public_name)` (the installed/dependency name). The 766 `Masc_mcp.X` / `open Masc_mcp` references are bound to the main library's `(name masc_mcp)` (`lib/dune:3`); the `(libraries masc_mcp.<sub>)` dependency lines are bound to `(public_name)`. Sub-libraries already use mcp-free internal names (`lib/config/dune` → `(name masc_config)`, `(public_name masc_mcp.config)`).

This yields two genuinely different scopes for the same stated goal ("opam/repo = masc"):

| | **Option A — external identity only (recommended)** | **Option B — full namespace** |
|---|---|---|
| opam package | `masc_mcp` → `masc` ✅ | `masc_mcp` → `masc` ✅ |
| main lib `(public_name)` | `masc_mcp` → `masc` | `masc_mcp` → `masc` |
| main lib `(name)` / module | **keep `masc_mcp` / `Masc_mcp`** | `masc_mcp` → `masc` / `Masc` |
| sub-lib `(public_name)` | `masc_mcp.<sub>` → `masc.<sub>` | same |
| `(libraries masc_mcp.X)` lines | → `masc.X` | same |
| **`.ml`/`.mli` changes** | **0** | **766 files (atomic)** |
| blast radius | ~50 dune files, no compile-order risk | tree-wide codemod; nothing compiles until all 766 change atomically |
| revert | dune-file-only revert | single-commit revert of an 800-file PR |
| conflict risk | low | **high** — 10+ in-flight worktrees observed; this repo has a recorded 2-strikes CI-gate-skip main-breakage pattern (MEMORY 2026-05-28) |

**Recommendation: Option A — but the author chose Option B (see §0); the trade-off below stands as the record of what B costs.** The user's stated target is *surface*. The opam package, every binary, the repo, and the MCP handshake all become `masc` under Option A — that is what every external consumer (opam, MCP clients, operators, docs readers) sees. The internal module name `Masc_mcp` is invisible to all of them; it is a protocol-era artifact, not a surface lie. Option B buys cosmetic internal purity at the cost of an 800-file atomic codemod with main-breakage risk that the in-flight branch landscape makes acute.

If Option B is chosen, it must use an AST-aware module rename (`ocamlmig` or a scripted dune-module codemod), **never global `sed`** — `sed` would wrongly collapse `mcp_session` / `mcp_transport_protocol` / `mcp_protocol`.

## 5. RENAME set (identity)

Phase tags refer to §6.

| Item | From → To | Blast | Phase |
|---|---|---|---|
| `serverInfo.name` | `masc-mcp` → `masc` | 1 line `lib/mcp_server.ml:97` | 1 |
| `serverInfo.websiteUrl` | `…/yousleepwhen/masc-mcp` → `…/jeong-sik/masc` | 1 line `:103`; **also fixes a pre-existing owner mismatch** (dune-project says `jeong-sik`) | 1 |
| `agent_card.name` | `MASC-MCP` → `MASC` | 1 line `server_routes_http_runtime.ml:97` | 1 |
| README H1 + arch box label | `masc-mcp` / `MASC-MCP` → `MASC` | `README.md:1,44` (keep edge label `:42` `MCP (JSON-RPC …)`) | 2 |
| `llms.txt` / `llms-full.txt` titles + project tokens | `MASC-MCP`/`masc-mcp` → `MASC`/`masc` | titles + `:3` (keep "Public MCP surface") | 2 |
| ROADMAP / CONTRIBUTING / spec prose | `masc-mcp` → `masc` | backticked project tokens only (keep "MCP server"/"MCP JSON-RPC") | 2 |
| opam package (SSOT) | `(name masc_mcp)`/`(package (name masc_mcp))` → `masc` | `dune-project:5,24`; regenerates `masc.opam` (+ `.locked`, currently stale 0.18.13 vs 0.19.35) | 5 |
| main lib `(public_name)` | `masc_mcp` → `masc` | `lib/dune:4` | 5 |
| sub-lib `(public_name)` + `(libraries …)` | `masc_mcp.<sub>` → `masc.<sub>` | ~50 dune files + consumer lines | 5 |
| main lib `(name)` / module *(Option B only)* | `masc_mcp` → `masc` / `Masc` | **766 `.ml`/`.mli`** | 5 |
| internal sub-lib names *(Option B only)* | `masc_mcp_<sub>` → `masc_<sub>` | ~18 (keep trailing `_session`/`_transport_protocol`) | 5 |
| server executables | `masc-mcp`/`masc-mcp-stdio` → `masc`/`masc-stdio` | `bin/dune:6,13` + all deploy refs | 5 |
| deploy artifacts/image/container/paths | `masc-mcp*` → `masc*` | Dockerfile, railway.toml, compose, release.yml, install.sh, `/opt/masc`, `/var/lib/masc` | 5 |
| launcher script | `start-masc-mcp.sh` → `start-masc.sh` + banners | git-mv + ~11 echoes + callers (plist, run-local.sh, test) | 4 |
| launchd plist (dev+prod) | `com.jeong-sik.masc-mcp` → `com.jeong-sik.masc` | filename + Label + `LAUNCHD_LABEL` in deploy.sh/stop-prod.sh | 4 |
| systemd unit | `masc-mcp.service` → `masc.service` + Description + paths | `infrastructure/systemd/*` (5 units) | 4 |
| build-script opam-path refs | `masc_mcp.opam` → `masc.opam` | 18 refs incl. `ci.yml:264` change-detection regex | 5 |
| `monitor-system-health.sh:206` pgrep | `pgrep -f 'masc-mcp\|keeper'` → `'masc\|keeper'` | **behaviorally load-bearing** — health check silently misses the process if not updated with the binary | 5 |
| dashboard repo-coupled | `jeong-sik/masc-mcp` (UPSTREAM_REPO + 6 URLs), `repository.id==='masc-mcp'`, `'masc-mcp doctor'` strings, comments | lockstep with `repositories.toml`, CLI binary, GitHub repo | 2 (comments) / 5 (coupled) |
| dashboard prometheus prefix | `'masc_mcp_'` → `'masc_'` | `prometheus-metrics.ts:116` — **TRAP:** narrowing over-matches `masc_agent_`/`masc_sse_`/`masc_tool_`; must keep the exact prefix the exporter emits | 5 |
| launcher-script test files | `test_start_masc_mcp_script.ml/.inc` → `…masc…` | + `test/dune` include | 4/5 |

## 6. Migration phases

Ordered so build-passing low-risk identity lands first and the high-risk codemod is a single atomic PR, last.

- **Phase 1 — Handshake/health/discovery identity labels (string literals).** Converge *all* server self-identity labels, not just the handshake, so no new split-brain is introduced. Producers (8): `lib/mcp_server.ml` `serverInfo.name` (`masc-mcp`→`masc`), `.title` (`MASC MCP Server`→`MASC Server`), `.websiteUrl` (**owner-fix only**: `yousleepwhen`→`jeong-sik`; slug stays `masc-mcp` until the repo renames in Phase 5, else it 404s); `agent_card.name` in **both** producers `lib/server/server_routes_http_runtime.ml:97` **and** `lib/tool_agent.ml:363` (`MASC-MCP`→`MASC`); health-JSON `("server", …)` ×2 (`server_routes_http_runtime.ml:157,320`, `masc-mcp`→`masc`); HTTP/2 root response body `lib/server/server_h2_gateway.ml:291` (`MASC MCP Server (HTTP/2)`→`MASC Server (HTTP/2)`). Consumers updated (3): `test/test_tool_agent_coverage.ml`, `test/test_operator_mcp_e2e.ml` (assert `MASC`), `test/test_ci_hardening_source.ml` (HTTP/2 identity source-text guard). KEEP `serverInfo.description`/`agent_card.description` prose ("MCP server"), `schema masc.agent_card.v1`. No compile impact (string + test only). *Verify:* `dune build .`; `test_ci_hardening_source` (source-text, no MASC-init dep) PASS; `test_tool_agent_coverage`/`test_operator_mcp_e2e` are init-gated in standalone exec (17 baseline failures on origin/main, delta 0 — assertion verified by CI harness). *Rollback:* revert one commit. *Scope note:* the enumerated Phase-1 scope expanded from 4 to 8 producer edits after an impact scan found a 2nd `agent_card.name` producer (`tool_agent.ml`), 2 health labels, and the HTTP/2 root response; partial convergence would itself be a split-brain. **Deferred** (recorded, not in this change): the `"MASC MCP Server"` *banner* cluster — startup logs (`http_server_h2.ml:270`, `mcp_server_eio_protocol.ml:827`, `server_bootstrap_http.ml:45`+`.mli:40`), CLI `--help` doc strings (`bin/main_eio.ml`, `bin/main_stdio_eio.ml`), `Dockerfile`/`start-masc-mcp.sh`/`docs/design` mentions — because the startup-log banner is **behaviorally coupled** to `scripts/release-binary-smoke.sh:52` (`grep 'MASC MCP Server listening'`, breaks the smoke gate if changed alone) and the CLI/deploy mentions belong to Phases 4–5. They travel with their phases, not here. **Adversarial-review follow-ups (2026-05-29, same PR):** +2 producers — dashboard Bonsai page HTML `<title>` (`lib/server/server_routes_http_pages.ml:316`, `masc-mcp · Bonsai`→`masc · Bonsai`; a client-facing HTTP response label, same class as the HTTP/2 root, and a sibling page already emits `MASC GraphQL Playground`) and the latent dead-code SDK handler name (`lib/mcp_sdk_adapter_masc.ml:198`, `masc-mcp`→`masc`; not on the live dispatch path, converged for hygiene to prevent a future split-brain). +1 consumer — `scripts/harness/contract/run_local_fresh_boot_contract.sh:130` asserted `serverInfo.name == "masc-mcp"` (a release-gate path via `mk/release.mk`, **not** in the default `run_all.sh` rotation, so PR CI stayed green despite the unpaired assertion) → bumped to `masc`.
- **Phase 2 — Docs + source comments.** README/llms/ROADMAP/CONTRIBUTING/spec prose, two dashboard comments. Split AMBIGUOUS sentences: rename only backticked project tokens, keep "MCP …" clauses and `docs/MCP-*.md` links/filenames. CHANGELOG: new entries only, leave history. Defer repo-URL literals to Phase 5. *Verify:* `scripts/check-doc-truth.sh`; `rg 'masc-mcp|masc_mcp|MASC-MCP'` shows only protocol/URL tokens. *Rollback:* revert; doc-only.
- **Phase 3 — DECISION GATE (no code).** User answers §7. Specifically: Option A vs B; whether the GitHub repo dir+remote actually renames; Railway `--service` window; in-flight `lib/` branch coordination. Phases 4–5 are blocked here. *Verify:* answers recorded in this RFC; `gh pr list` shows no broad in-flight `lib/` refactor before scheduling Phase 5.
- **Phase 4 — Service/launcher identity (filenames + labels, no opam/module rename).** git-mv launcher + plist + systemd + their callers + launcher test. Update `monitor-system-health.sh` pgrep here. No OCaml breakage. *Verify:* `shellcheck`; `dune build @runtest` (launcher test finds renamed script); `rg 'start-masc-mcp.sh'` → 0; host: reload launchd/systemd. *Rollback:* revert + git-mv back + reload prior unit files.
- **Phase 5 — opam + namespace + executables + deploy (atomic).** Single PR/commit. `dune-project` package rename; regenerate `.opam`(+`.locked`); public_name rename (A) or full module codemod (B); executables; 18 build-script paths + `ci.yml` regex; Dockerfile/railway/compose/release/install.sh/Makefile; dashboard repo-coupled + prometheus prefix; docs repo-URLs + CI-runner paths; git repo dir+remote rename+redirect; Railway service rename. *Verify:* `dune build .` (**default target, not just `@check`** — expr-level type errors only fire on default, per MEMORY), full `@runtest`, `opam lint masc.opam`, **force-run Build-and-Test** (do not let Detect-Changed-Surfaces SKIP it — known 2-strikes breakage), container smoke (`initialize` → `serverInfo.name=masc`), `railway up --service masc` smoke, `install.sh` against new asset, dashboard repo-link 200, `rg 'Masc_mcp|masc_mcp|masc-mcp'` returns only intentional KEEP. *Rollback:* one `git revert <merge>` + rename remote/dir back (GitHub redirect keeps both live) + revert Railway name. **Do not split across PRs — partial state is unbuildable.**

## 7. Open questions (gate Phase 3)

1. **Namespace depth (the headline):** ~~Option A or B?~~ **ANSWERED 2026-05-29 — Option B** (full namespace, 766-file atomic codemod). Phase 5 must use an AST-aware module rename (`ocamlmig` or scripted dune-module codemod), never global `sed`.
2. **GitHub repo rename:** `gh repo rename masc-mcp → masc` with redirect verified? All repo-URL literals are blocked on this (404 if edited first). GitHub auto-redirects, so order matters but it is reversible.
3. **Railway service:** rename the externally-configured Railway service `masc-mcp → masc` in the same window, or keep `deploy-railway.yml --service` pinned to the existing service name regardless of brand?
4. **Release assets:** `masc-mcp-linux-x64` / `-macos-arm64` are downloaded by exact name in `install.sh` and prior releases keep old names forever. Rename only on a clean version bump (document new asset name) or keep old asset names for backward-compatible installs?
5. **In-flight coordination:** schedule Phase 5 only when no broad `lib/` PR is open (the repo is currently on `refactor/ssot-…`; 10+ worktrees exist).
6. **`serverInfo.title`:** `MASC Server` (drop brand "MCP") or `MASC (MCP Server)` (keep honest protocol descriptor)? Recommend the former; the latter is defensible.
7. **Dashboard Korean strings** (`MCP 연결이 차단되었습니다`, `공개 MCP`): KEEP as protocol-accurate (recommended), or product-copy decision to deacronymize (`서버 연결이 차단되었습니다`, `공개 도구`) — *not* substitute `MASC`. Out of pure-rename scope; flag for product copy.

## 8. Cross-references

- **RFC-0165** (`mcp-server-client-agnostic`, merged #18203): establishes `MASC_MCP_*` env vars and `/mcp` as client-owned/server-agnostic. This RFC defers to it — env prefixes stay (§3); a future prefix migration needs a deprecation alias.
- **RFC-0166** (`mcp-client-coupling-closeout`, draft): protocol/client coupling closeout. This RFC must not re-introduce coupling by renaming protocol tokens.
- **`docs/MCP-SURFACE-AUDIT.md`:** canonical inventory of the public MCP protocol surface. Filename + protocol prose are KEEP; the single backticked `masc-mcp` project mention (line 12) is an intra-sentence split (rename brand token, keep "MCP exposure/surface").
- **New orthogonal axis:** server self-identity, not previously governed. The split-brain (cascade+auth emit `masc`; handshake+agent-card emit `masc-mcp`/`MASC-MCP`) is the evidence.

## 9. Adversarial-pass corrections to the source inventory

Recorded so future readers trust the numbers:

1. `Masc_mcp` references measured at **766** files (262 `open`, ~504 qualified) — higher than a first pass's 726; reinforces Phase-5-only/atomic for Option B.
2. `masc_mcp.opam.locked` is **stale** (`name masc_mcp`, version 0.18.13 vs dune-project 0.19.35) — regenerate regardless of this RFC.
3. `serverInfo.websiteUrl` owner is `yousleepwhen` while `dune-project` github is `jeong-sik` — pre-existing owner bug, fix in Phase 1.
4. `MASC_MCP_*` env vars were initially RENAME-leaning; **reclassified KEEP** per RFC-0165 (config contract wins over embedded brand).
5. `mcp_sdk_adapter_masc.*` correctly KEEP (protocol-dominant despite carrying both tokens).
