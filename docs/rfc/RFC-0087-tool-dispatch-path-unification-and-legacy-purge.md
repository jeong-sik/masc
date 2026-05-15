---
rfc: "0087"
title: "Tool Dispatch Path Unification + Legacy Purge"
status: Implemented
created: 2026-05-15
updated: 2026-05-15
author: vincent
supersedes: []
superseded_by: null
related: ["0084", "0056"]
implementation_prs: [15458, 15460, 15461, 15462, 15465, 15466, 15468, 15470, 15471, 15475, 15477, 15480, 15481, 15482, 15483, 15484, 15485, 15486]
---

# RFC-0087 — Tool Dispatch Path Unification + Legacy Purge

## §1 컨텍스트

RFC-0084 sprint (24 PR) 완료 직후 정밀 audit이 3개 root gap을 식별:

1. **외부 MCP 호출 경로에서 typed_post_hooks silent** — `Tool_metrics`, `Tool_usage_log`, `Otel_dispatch_hook`, `Tool_output_validation`, `server_bootstrap_loops` 5개 observer가 `guarded_dispatch` (keeper turn) 경로에서만 발화, MCP `dispatch_by_tag` / `dispatch_internal_keeper_runtime` 경로에서는 미발화.

2. **하드코드 path 9사이트** — `auto_responder.ml` (×2), `server_startup_takeover.ml`, `server_runtime_bootstrap.ml`, `tool_library.ml`, `cdal_runtime/proof_store.ml` 등 production code의 `/tmp/...` 리터럴.

3. **`Env_config_core` vs `Host_config`: 양립 SSOT** — path 결정 책임이 두 모듈에 분산. `legacy_macos_default ()` 함수명 misnomer (62 caller, 실제로는 *current* default 접근자).

추가 인프라 부채:
- `Host_config.t` + `Dispatch_outcome.t` PPX `@@deriving` 미적용
- Regression test가 source-grep 기반 (RFC-0084 sprint 동안 4회 docstring self-trap)

## §2 의도된 결과

- 모든 5 observer가 keeper-turn / 외부 MCP / inline 3개 dispatch path에서 동일 발화
- `Host_config` 가 cred/coreutils/shell/runtime/disclosure + log/run/policy + env-derived 4 (base_path/config_dir/data_dir/personas_dir) + home/assets_dir/base_path_raw = **15 도메인** 통합
- `Env_config_core` 의 path-related public surface (`base_path_opt`, `base_path_raw_opt`, `config_dir_opt`, `personas_dir_opt`, `home_dir_opt`, `assets_dir_opt`) 폭발
- Env-var deprecation 메커니즘 폭발 (7 entries)
- `Host_config.t` + `Dispatch_outcome.t` `@@deriving show, eq` 적용
- AST 기반 regression helper (`test_lib/ast_grep.ml`) 도입
- Underscore-prefix naming bug 박멸 (60+ occurrence)

## §3 비결정 영역 / Out of Scope

- OAS `Agent_sdk.Tool.descriptor` audit — masc-mcp 외부 repo
- `cdal_runtime` sub-library의 `Env_config_core` path caller migration — RFC-OAS-011 격리 보존
- `auth_doctor` / `auth_login` / `config_doctor` `normalize_masc_base_path_input` — generic string utility, path SSOT 아님
- `worker_runtime_docker` `Env_config_core.*_env_key` — string identifier (값 아님)
- `Tool_dispatch_emit.finalize` ↔ `guarded_dispatch` inline mirror — dependency cycle 회피용, 별도 RFC

## §4 구현 PR 인벤토리

18 PR push, 머지 시점 기준 11 MERGED + 7 OPEN (last sync 2026-05-15).

| PR # | Title | Status |
|---|---|---|
| #15458 PR-1 | host_config rename + PPX + AST helper (base) | MERGED |
| #15460 PR-2 | auto_responder log_dir 흡수 | MERGED |
| #15461 PR-3 | server runtime PID + policy (사용자 강화) | MERGED |
| #15462 PR-4 | tool_library + cdal proof_store fallback | MERGED |
| #15465 PR-5 | **MCP typed_post_hooks 통일** (Root Gap 1 close) | MERGED |
| #15466 PR-6 | Host_config.from_env + env-derived 필드 | MERGED |
| #15468 PR-7 | retired_pg_env_keys 폭발 (사용자 식별) | MERGED |
| #15470 PR-8 | config_dir_resolver + tool_code_write migrate | MERGED |
| #15471 PR-9 | base_path_opt + base_path_raw_opt 폭발 (14 caller) | MERGED |
| #15475 PR-10 | home_dir_opt + assets_dir_opt 폭발 | MERGED |
| #15477 PR-11 | env-var deprecation 메커니즘 폭발 (7 entries) | MERGED |
| #15480 PR-12 | _tool_spec_* misleading prefix rename (51 occurrence) | OPEN |
| #15481 PR-13 | underscore audit (1 dead + 8 rename) | OPEN |
| #15482 PR-14 | dispatch chain inline (dispatch + dispatch_structured 폭발) | OPEN |
| #15483 PR-15 | tool_schemas_inline 4 binding rename | OPEN |
| #15484 PR-16 | server_dashboard_http_core 9 binding rename | OPEN |
| #15485 PR-17 | 4 dead function 폭발 (~250 LOC) + 2 rename | OPEN |
| #15486 PR-18 | execution_surfaces + namespace_truth 8 rename | OPEN |

## §5 검증

- `dune build --root . @lib/check` green at every PR commit
- 각 PR에 source-AST regression test (RFC-0085 PR-1 도입 `test_lib/ast_grep.ml`)
- `ci/lint-no-direct-dispatch.sh` green at every PR

## §6 학습 (memory에 저장)

- `feedback_underscore_prefix_audit_must_verify_actual_usage.md` — OCaml `_xxx` prefix는 advisory, 사용처 검증 필수
- `feedback_bsd_sed_word_boundary_collision_pattern.md` — macOS BSD sed `\b` 미지원, prefix-substring collision 반복 발생
- `feedback_continuous_loop_terminate_at_value_positive_threshold.md` — continuous-loop는 *value-positive* iteration에서만 진행
- `feedback_user_polishes_agent_base_sprint_inflight.md` — agent base sprint 진행 중 사용자 plan-너머 강화 패턴

## §7 다음 신호

continuous-loop sprint이 *false-positive ratio 증가*로 진정 단계 도달. 다음 진정한 legacy 신호:

1. **7 OPEN PR 머지 후 main 안정화** — base에서 잔존 audit 재실행
2. **사용자 식별** — PR-3 (`policy_path` 코드 삭제), PR-7 (`retired_pg_env_keys`) 같은 plan-너머 legacy
3. **운영 데이터** — Prometheus telemetry, 사용자 dashboard에서 새 hardcode 패턴
