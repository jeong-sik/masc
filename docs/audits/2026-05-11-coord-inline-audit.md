# coord_* / inline_* 21 도구 정량 audit

**날짜**: 2026-05-11
**대상**: `lib/tool_schemas/tool_schemas_{coord,coord_core,coord_extra,inline,inline_coord,inline_episodes,inline_infra}.ml`에 정의된 21개 도구
**근거**: 사용자가 plan (`~/me/planning/claude-plans/polished-juggling-galaxy.md`) §1.8 검토 중 "이거 지워도되는거아님??" 의문 제기. Explore agent의 "모두 UNIQUE" verdict가 정량 검증 없이 마무리됐기에 본 audit이 정량 결과를 산출한다.
**관련 PR**: PR-N5 (본 audit) → PR-N5b (DEAD/REDUNDANT 삭제) → PR-N2 (UNIQUE 도구 keeper-internal scope 이동)

## 측정 방법

각 도구 이름에 대해:
```bash
rg -c "\"<tool_name>\"" lib/ -t ocaml | awk -F: '{s+=$2} END {print s}'   # lib_only
rg -c "\"<tool_name>\"" lib/ test/ -t ocaml | ...                            # lib + test
```

lib_only 값은 schema 정의 1건 + dispatch routing + telemetry/test fixture 등을 포함. caller count의 lower bound 근사.

판정 기준 (Copilot 리뷰 정정 반영):
- **DEAD**: `lib_only <= 1` (스키마 정의 1건만 존재, 다른 caller 0). 진짜 DEAD 도구도 schema 정의는 보유하므로 `= 0`은 불가능.
- **REDUNDANT**: 다른 도구로 완전 대체 가능 (description 자체에 "deprecated" / "compatibility wrapper" 명시 또는 동일 책임 다른 도구 존재)
- **PARTIAL_DEPRECATION**: REDUNDANT 후보지만 본체 로직이 phase-dependent 또는 caller chain이 두꺼워 SAFE DELETE 아닌 경우
- **THIN_WRAPPER**: 다른 도구를 1단 호출하고 끝
- **UNIQUE**: 고유 책임, 유지

## 측정 결과

| 도구 | 파일 | lib | lib+test | verdict | 비고 |
|------|------|-----|----------|---------|------|
| `masc_check` | coord_core | 8 | 14 | UNIQUE | room health/sanity check |
| `masc_coordination_fsm_snapshot` | coord_core | 13 | 19 | UNIQUE | FSM debug surface |
| `masc_heartbeat` | coord_core | 33 | 58 | UNIQUE | task lifecycle 필수 |
| `masc_reset` | coord_core | 10 | 16 | UNIQUE | destructive room reset |
| `masc_status` | coord_core | 48 | 317 | UNIQUE | dashboard SSOT, 가장 높은 caller count |
| `masc_workflow_guide` | coord_core | 13 | 16 | UNIQUE | bootstrap onboarding |
| `masc_goal_list` | coord_extra | 11 | 23 | UNIQUE | Goal FSM list |
| `masc_goal_review` | coord_extra | 10 | 13 | **PARTIAL_DEPRECATION** | description은 "Compatibility wrapper" 표명하나 `handle_goal_review` 본체(lib/coord_goals.ml)가 phase-dependent 자체 로직 보유: `Awaiting_verification`/`Awaiting_approval` phase에서만 redirect, 그 외 phase는 자체 처리. caller chain 8 곳 (tool_coord dispatch / tool_catalog_surfaces 4 등록 / tool_name variant / governance_pipeline_risk / test 4) — SAFE DELETE 아님 |
| `masc_goal_transition` | coord_extra | 12 | 32 | UNIQUE | Goal FSM transition |
| `masc_goal_upsert` | coord_extra | 11 | 25 | UNIQUE | Goal FSM create/update |
| `masc_goal_verify` | coord_extra | 12 | 22 | UNIQUE | quorum verification |
| `masc_broadcast` | inline_coord | 34 | 79 | UNIQUE | inter-agent messaging 핵심 |
| `masc_join` | inline_coord | 24 | 79 | UNIQUE | room lifecycle |
| `masc_leave` | inline_coord | 16 | 29 | UNIQUE | room lifecycle |
| `masc_messages` | inline_coord | 17 | 29 | UNIQUE | thread read |
| `masc_start` | inline_coord | 12 | 24 | UNIQUE | session init |
| `masc_who` | inline_coord | 14 | 29 | UNIQUE | room roster |
| `masc_approval_get` | inline_infra | 6 | 12 | UNIQUE | HITL approval read |
| `masc_approval_pending` | inline_infra | 11 | 27 | UNIQUE | HITL approval queue |
| `masc_mcp_session` | inline_infra | 5 | 6 | UNIQUE | session metadata |
| `masc_spawn` | inline_infra | 9 | 13 | UNIQUE | agent lifecycle |

## 집계

| Verdict | 갯수 | 비율 |
|---------|------|------|
| DEAD | 0 | 0% |
| REDUNDANT (SAFE DELETE) | 0 | 0% |
| **PARTIAL_DEPRECATION** | **1** | **5%** |
| THIN_WRAPPER | 0 | 0% |
| UNIQUE | 20 | 95% |

## 사용자 직감 verdict

사용자: "coord_* / inline_* 협조 도구 ~30개 — 이거 지워도되는거아님??"

**검증 결과: PARTIAL (5%)**
- 21개 중 0개 DEAD — 모두 active caller 존재 (lib_only ≥ 5).
- 21개 중 1개 (`masc_goal_review`) PARTIAL_DEPRECATION — 자기 description에 "Use masc_goal_transition / masc_goal_verify" 명시이나 handle_goal_review 본체에 phase-dependent 로직 + caller chain 8곳 → SAFE DELETE 아님. Goal FSM consolidation 별도 RFC carry.
- 나머지 20개 모두 UNIQUE — 책임 분리 명확 (status / heartbeat / room lifecycle / Goal FSM / messaging / HITL approval / session).

사용자 직감의 본질은 "이 카테고리 자체가 너무 비대하다"가 아니라 "naming/structure가 모호하다" — 본 audit이 21개 모두 active임을 확인. 단 PARTIAL_DEPRECATION 1건은 실재.

## 권장 액션

### PR-N5b — 범위 재정의 또는 skip 권장

audit 1차에서 `masc_goal_review`를 SAFE-DELETE REDUNDANT로 분류했으나, `handle_goal_review` 본체 (`lib/coord_goals.ml`) 분석 결과 phase-dependent 자체 로직이 발견됨:

- `Awaiting_verification` / `Awaiting_approval` phase에서만 redirect ("ambiguous" + "use masc_goal_transition / masc_goal_verify")
- 그 외 phase는 자체 처리 (validation + handle_goal_transition 위임 + 추가 핸들링)

caller chain 8곳 (tool_coord dispatch / tool_catalog_surfaces 4 surface 등록 / tool_name `Goal_review` variant / governance_pipeline_risk High / test 4건) 정리 + phase-dependent behavior consolidation은 별도 RFC scope.

**권장 결정**: PR-N5b 본 plan에서 skip. 별도 RFC (Goal FSM consolidation)로 분리. 단기 액션:
1. (선택) description text 강화 — `[DEPRECATED, REMOVAL TARGET: <RFC#>]` prefix 추가
2. governance_pipeline_risk = High 유지 (변경 없음)
3. follow-up RFC 작성: "masc_goal_review의 phase-dependent 로직을 masc_goal_transition / masc_goal_verify로 통합하고 도구 제거"

### PR-N2 (Stage 2 surface trim) — 21개 분류 (Copilot 카운트 정정 반영)

| 분류 | 갯수 | 도구 |
|------|------|------|
| **PARTIAL_DEPRECATION** (surface 유지, Goal FSM consolidation RFC 대기) | 1 | `masc_goal_review` |
| **Surface 유지** (사용자 확정 surface 정의: goal/board/task/broadcast/lifecycle admin/HITL) | 15 | `masc_status`, `masc_heartbeat`, `masc_join`, `masc_leave`, `masc_start`, `masc_who`, `masc_broadcast`, `masc_messages`, `masc_goal_list`, `masc_goal_upsert`, `masc_goal_transition`, `masc_goal_verify`, `masc_approval_get`, `masc_approval_pending`, `masc_spawn` |
| **Keeper-internal 이동** (admin observability / internal) | 5 | `masc_check`, `masc_coordination_fsm_snapshot`, `masc_reset`, `masc_workflow_guide`, `masc_mcp_session` |
| **합계** | **21** | — |

PR-N2가 `Tool_scope.keeper_internal_list`에 추가할 5개 — `Config.surface_tool_schemas ()` 카운트 -5. (admin observability 또는 internal)

### naming / structure 별도 정리
- `inline_*` prefix의 의미가 schema 디렉토리 구조에만 존재 (도구 이름엔 `masc_*`). 별도 refactor 필요 없음 — 단 `tool_schemas_inline_*.ml` 파일 분리 자체는 책임 묶음으로 정당화됨.
- `coord_*` / `inline_*` 파일 분리는 dispatch 모듈 (`tool_coord.ml`, `tool_inline_dispatch.ml`)과 1:1 매핑되어 있어 유지.

## 다음 단계

1. 본 audit를 PR-N5 (docs-only PR)로 머지.
2. PR-N5b: `masc_goal_review` 삭제 + dispatch routing 정리.
3. PR-N2: 7개 도구 (`masc_check`, `masc_coordination_fsm_snapshot`, `masc_reset`, `masc_workflow_guide`, `masc_mcp_session`)를 scope=Keeper_internal로 이동. 14 도구는 surface 유지.

## Plan 정정사항

- `~/me/planning/claude-plans/polished-juggling-galaxy.md` §1.3 schema 파일 경로 정정: `lib/tool_schemas_*.ml` → `lib/tool_schemas/tool_schemas_*.ml` (디렉토리)
- §1.3 파일 개수 정정: 10 → 14 (`tool_schemas_coord.ml`, `tool_schemas_inline.ml`, `tool_schemas_inline_episodes.ml` 추가 발견)
- §1.8 keeper-internal 이동 대상 정정: coord_*/inline_* 21개 통째로가 아니라 7개만. 나머지 14개는 사용자 surface 정의에 부합하여 surface 유지.
