# RFC-0089 inventory — `String.starts_with ~prefix:"..."` sites in `lib/`

수집 시점: 2026-05-17 (re-scan after Accepted promotion, PR #15775).
원본 명령: `rg -n 'String\.starts_with ~prefix:"' lib/`.
합계: **217 site, 86 파일**.

이전 baseline (2026-05-15): 215 site, 56 파일. 7 implementation PRs (#15520, #15523,
#15524, #15684, #15699, #15703, #15704) 머지 후 site count는 net +2, 파일 분포는
+30 (각 파일 1-2 site로 spread). 즉 *큰 file의 hotspot이 제거*되고 *잔존이 sparse
single-site로 흩어진* 양상 — 본 RFC가 목표한 typed-variant 도입 효과.

본 인벤토리는 *raw scan*이다. scope-in / scope-out 분류는 RFC-0089 §3에 inline
sample 만 둔다. 도메인별 migration PR이 자기 파일을 닫을 때 본 인벤토리도 같은
PR에서 줄여나간다.

## 파일별 분포 (15+ → 1 site, 2026-05-17 main HEAD)

| count | file | classification |
|---|---|---|
| 16 | `lib/worker_dev_tools.ml` | **scope-out (RFC-0091 PR-2 delete target)** |
| 15 | `lib/exec/output_parse.ml` | scope-out (LLM/exec stdout parser) |
| 9 | `lib/server/server_routes_http_routes_workspace.ml` | scope-out (git porcelain + diff) |
| 9 | `lib/server/server_dashboard_http_link_preview.ml` | scope-out (HTML/URL parsing) |
| 9 | `lib/keeper/keeper_gh_shared.ml` | scope-out (CLI argv tokenizer) |
| 7 | `lib/server/server_auth.ml` | scope-out (HTTP path routing) |
| 6 | `lib/keeper/keeper_shell_docker.ml` | scope-out (docker CLI argv) |
| 6 | `lib/keeper/keeper_gh_env.ml` | scope-out (env var name) |
| 6 | `lib/gh_command_validation.ml` | scope-out (gh CLI argv) |
| 5 | `lib/graphql_endpoint.ml` | scope-out (URL scheme + GraphQL protocol) |
| 4 | `lib/tool_local_runtime_bench.ml` | scope-out (benchmark output parser) |
| 4 | `lib/repo_manager/keeper_repo_mapping.ml` | scope-out (repo URL prefix) |
| 4 | `lib/keeper_skill_routing/keeper_skill_routing.ml` | **scope-in (G5 pending)** |
| 4 | `lib/ide/ide_region_tracker.ml` | scope-out (file path classifier) |
| 4 | `lib/cascade/cascade_declarative_adapter.ml` | scope-out (TOML key matching) |
| 4 | `lib/cascade/cascade_config.ml` | scope-out (TOML key matching) |
| 4 | `lib/board_core_classify.ml` | scope-out (round-trip `*_to_string`/`*_of_string`) |
| 3 | `lib/server/server_h2_gateway.ml` | scope-out (HTTP/2 protocol) |
| 3 | `lib/server/server_dashboard_http_runtime_info.ml` | scope-out (header matching) |
| 3 | `lib/mcp_server_eio_protocol.ml` | scope-out (MCP protocol marker) |
| 3 | `lib/keeper/keeper_shell_bash.ml` | scope-out (shell command parser; RFC-0091 territory) |
| 3 | `lib/keeper/keeper_execution_receipt.ml` | scope-out (round-trip) |
| 3 | `lib/board_votes.ml` | scope-out (round-trip) |
| 3 | `lib/audit_log.ml` | scope-out (round-trip `action_to_string`/`string_to_action`) |

## §3.2 boundary classification — 2026-05-17 audit

| Pattern | Files | Count | Rationale |
|---|---|---|---|
| Round-trip serialization (`*_to_string` + `*_of_string` in same file) | audit_log, board_votes, board_core_classify, keeper_execution_receipt, transport, tool_misc_web_search, keeper_unified_metrics, keeper_meta_tool_access, keeper_context_core, activity_graph_types | ~19 | typed variant already exists; string is wire format |
| LLM / exec stdout parser | output_parse | 15 | producer is external (compiler/cargo/dune output); string is the protocol |
| CLI argv tokenizer | keeper_gh_shared, gh_command_validation, keeper_shell_docker | 21 | producer is gh/docker CLI; flag prefix `-`/`--` is shell convention |
| URL scheme + HTTP path classifier | server_auth, server_dashboard_http_link_preview, graphql_endpoint, repo_manager/keeper_repo_mapping | 25 | producer is HTTP request; scheme/path is protocol literal |
| Git porcelain output | server_routes_http_routes_workspace | 9 | producer is `git status --porcelain`; format is git stable wire |
| TOML key matching | cascade_config, cascade_declarative_adapter | 8 | user-authored config; key string is the protocol |
| Env var name prefix | keeper_gh_env | 6 | OS env namespace |
| HTTP/2 + MCP protocol marker | server_h2_gateway, mcp_server_eio_protocol, server_dashboard_http_runtime_info | 9 | wire protocol literals |
| Worker dev tools shell parser | worker_dev_tools, keeper_shell_bash | 19 | shell command string parser; deleted by **RFC-0091 PR-2** |
| Benchmark / file path classifier | tool_local_runtime_bench, ide/ide_region_tracker | 8 | output parser + path filter |

**Subtotal scope-out: ~139 sites across the top 24 files.**

## §3.1 scope-in residual — 2026-05-17

| Domain | File(s) | Count | Status |
|---|---|---|---|
| G5 skill routing protocol marker | `lib/keeper_skill_routing/keeper_skill_routing.ml` | 4 | **pending PR** |
| G6 anti-rationalization LLM output | `lib/anti_rationalization.ml` | 0 in raw scan, RFC inline only | **needs domain audit** (may live in different module) |
| Long-tail (2-site files × ~30, 1-site files × ~25) | various | ~55 | per-domain mop-up |

**Active scope-in cluster: ~4-10 sites in two domains (G5 + G6).** Long-tail
residual (~55 sites across single-site files) is dominated by URL/path/CLI
classifiers — boundary by inspection but not bulk-audited here.

## Close-condition check (Meta issue #9521)

Last close criterion: "잔여 §3.1 3 도메인 완료 *또는* sites <30 임계치 미만".

- Path A (residual domain): G3 (audit_log) re-classified to **scope-out** in
  this update. 잔여 §3.1 = **2 domains** (G5 skill_routing + G6
  anti_rationalization). Smaller than the previous "3 domains" estimate.
- Path B (sites <30): Active scope-in cluster (G5 + G6) = **~4-10 sites**.
  Long-tail (~55 single/dual-site files) is unaudited but pattern-wise
  boundary-heavy. Strict <30 threshold for *audited scope-in* is satisfied;
  long-tail requires single-file confirmation.

The threshold definition was left explicitly fuzzy ("예: <30"). Maintainer
judgment call.

## 진행 추적 (2026-05-17)

| PR | Domain | Sites closed | Status |
|---|---|---|---|
| #15520 | G1 tool_help_registry | 7 → 0 | merged |
| #15523 | G4 keeper_checkpoint_store ENOENT | 4 → 0 | merged |
| #15524 | G2 board author_kind/voter_kind | partial | merged |
| #15684 | post-RFC: keeper_path_check_error | n/a | merged |
| #15699 | post-RFC: shadow-gate parse_outcome_kind | n/a | merged |
| #15703 | post-RFC: eval gate destructive-pattern SSOT | n/a | merged |
| #15704 | post-RFC: eval_gate evasion_kind | n/a | merged |

본 인벤토리는 *enforcement evidence*이지 acceptance gate가 아니다. 본 RFC
acceptance는 도메인별 독립 도달 (RFC-0089 §7) — 각 §3.1 도메인이 자신의 PR에서
0 site에 도달해야 한다. *Inventory의 raw count가 0 도달*은 acceptance 조건이
아닌 *side effect*.
