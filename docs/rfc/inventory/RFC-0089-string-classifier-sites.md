# RFC-0089 inventory — `String.starts_with ~prefix:"..."` sites in `lib/`

수집 시점: 2026-05-15 (origin/main HEAD `6e6c502549`).
원본 명령: `rg -n 'String\.starts_with ~prefix:"' lib/`.
합계: **215 site, 56 파일**.

본 인벤토리는 *raw scan*이다. scope-in / scope-out 분류는 RFC-0089 §3에 inline
sample 만 둔다. 도메인별 migration PR이 자기 파일을 닫을 때 본 인벤토리도 같은
PR에서 줄여나간다.

## 파일별 분포 (15+ → 1 site)

| count | file |
|---|---|
| 15 | `lib/exec/output_parse.ml` |
| 11 | `lib/worker_dev_tools.ml` |
| 9 | `lib/server/server_routes_http_routes_workspace.ml` |
| 9 | `lib/server/server_dashboard_http_link_preview.ml` |
| 9 | `lib/keeper/keeper_gh_shared.ml` |
| 7 | `lib/tool_help_registry.ml` |
| 7 | `lib/server/server_auth.ml` |
| 6 | `lib/keeper/keeper_gh_env.ml` |
| 6 | `lib/gh_command_validation.ml` |
| 5 | `lib/graphql_endpoint.ml` |
| 4 | `lib/tool_local_runtime_bench.ml` |
| 4 | `lib/repo_manager/keeper_repo_mapping.ml` |
| 4 | `lib/keeper/keeper_checkpoint_store.ml` |
| 4 | `lib/keeper_skill_routing/keeper_skill_routing.ml` |
| 4 | `lib/ide/ide_region_tracker.ml` |
| 4 | `lib/cascade/cascade_declarative_adapter.ml` |
| 4 | `lib/cascade/cascade_config.ml` |
| 3 | `lib/server/server_h2_gateway.ml` |
| 3 | `lib/server/server_dashboard_http_runtime_info.ml` |
| 3 | `lib/mcp_server_eio_protocol.ml` |
| 3 | `lib/keeper/keeper_shell_bash.ml` |
| 3 | `lib/keeper/keeper_execution_receipt.ml` |
| 3 | `lib/board_votes.ml` |
| 3 | `lib/board_core_classify.ml` |
| 3 | `lib/audit_log.ml` |
| 2 | (잔여 ~30 파일, 도메인별로 mop-up) |
| 1 | (잔여 ~25 파일, mop-up) |

## 도메인 그룹 (잠정)

본 그룹은 RFC-0089 §4 우선순위 결정용. PR 분할은 도메인 단위.

### G1 — Tool family classifier (scope-in, 우선순위 1)

- `lib/tool_help_registry.ml` (7 site, prefix 6종: `masc_operation_`, `masc_dispatch_`, `masc_unit_`, `masc_policy_`, `masc_observe_`, `masc_detachment_`, `masc_keeper_`)
- 같은 prefix 패턴이 등장하는 외부 파일은 PR 단계에서 합산.

### G2 — Board author / kind classifier (scope-in, 우선순위 3)

- `lib/board_core_classify.ml` (3 site)
- `lib/board_votes.ml` (3 site, 일부는 boundary 가능 — PR 단계에서 분리)

### G3 — Audit action kind (scope-in)

- `lib/audit_log.ml` (3 site)

### G4 — Checkpoint store ENOENT 분류 (scope-in, 우선순위 2)

- `lib/keeper/keeper_checkpoint_store.ml` (4 site, exception-string 비교)

### G5 — Skill routing protocol marker (scope-in)

- `lib/keeper_skill_routing/keeper_skill_routing.ml` (4 site)

### G6 — Anti-rationalization decision parser (scope 모호, RFC-0089 §10 Q3)

- `lib/anti_rationalization.ml` (RFC inline에서만 언급, raw scan에서는 다른
  match path로 잡힐 가능성 — PR 단계 정밀 확인)

### G7 — Cascade config / declarative adapter (scope 미확정)

- `lib/cascade/cascade_config.ml` (4 site)
- `lib/cascade/cascade_declarative_adapter.ml` (4 site)
- 일부는 사용자 정의 YAML key matching → boundary 가능. PR 단계에서 in/out 분리.

### G-boundary — scope-out (외부 protocol / storage, 본 RFC 범위 밖)

- `lib/exec/output_parse.ml` (15 site, OCaml test runner stdout)
- `lib/keeper/keeper_gh_shared.ml` (9 site, CLI argv tokenizer)
- `lib/server/server_routes_http_routes_workspace.ml` (9 site, git porcelain + diff)
- `lib/server/server_dashboard_http_link_preview.ml` (9 site, HTML/URL parsing)
- `lib/server/server_auth.ml` (7 site, HTTP path routing)
- `lib/gh_command_validation.ml` (6 site, gh CLI argv)
- `lib/keeper/keeper_gh_env.ml` (6 site, env var name)
- `lib/graphql_endpoint.ml` (5 site, GraphQL string protocol)
- `lib/repo_manager/keeper_repo_mapping.ml` (4 site, repo URL prefix)
- ...

scope-out 추정 합계 ~80 site. scope-in 후보 ~135 site. 외삽치는 §3.3 추정에만
사용하며 acceptance에는 포함하지 않는다.

## 진행 추적

PR이 머지될 때마다 본 표의 해당 파일을 strikethrough 또는 삭제한다. 본 RFC
acceptance는 *본 인벤토리의 scope-in 그룹 0 site* 도달 시 만족.
