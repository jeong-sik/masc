# RFC: Tool Surface SSOT — 126 Orphaned Tools Disposition

**Status**: Draft v2 (reviewed by GLM-5.1 + self-critique)
**Author**: jeong-sik + Claude
**Date**: 2026-04-03
**Ref**: #4709, #3890 Phase 3

## Problem

271개 등록 도구 중 126개가 orphaned — 어떤 surface에도 속하지 않음.
이 도구들은 `tools/list`에 나타나지 않지만 `tools/call`로는 호출 가능한 상태.

**v1 오류 정정**: 분석 스크립트가 tool_auth.ml, tool_agent.ml 등 combo 파일(스키마+핸들러)을
SCHEMA_FILES로 분류하여 caller 카운트에서 제외함. 126개 전부 실제 dispatch handler를 보유.
제거 대상 0개.

## Principle

**모든 도구는 정확히 하나의 surface에 속해야 한다.**

도구의 상태는 3가지만 존재:
1. **Surface에 등록** — 해당 surface 클라이언트가 사용
2. **Deprecated** — 제거 예정, catalog에 마킹
3. **삭제됨** — 코드에서 완전 제거

## Critical Design Decision: Surface != LLM Exposure

**v1 결함**: surface 등록과 LLM 노출을 동일시했다.
Surface에 올리는 것이 곧 `tools/list`에 노출되는 것은 아니다.

현재 MASC-MCP의 도구 가시성 계층:

```
Surface (소속) → Tier (노출 레벨) → Visibility (tools/list 포함 여부)
```

- **Surface**: 도구가 어디에서 호출될 수 있는지 (Admin, Public, Spawned 등)
- **Tier**: Essential(21) < Standard(56) < Full(all) — 클라이언트 요청 tier에 따라 필터
- **Visibility**: Default/Hidden — tools/list 응답에 포함 여부

126개를 surface에 올려도, tier가 Full이면 Essential/Standard 클라이언트에 미노출.
하지만 이것만으로는 부족하다. 새로운 surface 계층이 필요하다.

## New Surface: System_internal

protocol-level 도구, 시스템 데몬 전용 도구, LLM이 판단해서 호출하면 안 되는 도구를 위한 surface.

| Surface | 용도 | tools/list 노출 | tools/call 허용 |
|---------|------|----------------|----------------|
| Public_mcp | 외부 MCP 클라이언트 | O (tier 기반) | O |
| Spawned_agent | OAS worker agent | O (tier 기반) | O |
| Local_worker | Local runtime worker | O (tier 기반) | O |
| Admin | 관리자/command plane | O (tier 기반) | O |
| Keeper_internal | Keeper 런타임 | O (shard 기반) | O |
| **System_internal** (NEW) | **시스템 전용, LLM 미노출** | **X** | **O** |
| Keeper_denied | 보안 차단 | X | X |

### System_internal 대상 (38개)

LLM이 직접 판단하면 위험하거나, 시스템 내부 루프에서만 의미있는 도구:

| Category | Tools | Count | Reason |
|----------|-------|-------|--------|
| Protocol | mcp_session, suspend, listen, pending_interrupts | 4 | MCP protocol 내부 핸드셰이크 |
| Lifecycle | init, reset, register_capabilities | 3 | 세션 초기화 자동 호출 |
| Governance | governance_set, approve, reject, branch, interrupt | 5 | 거버넌스 파이프라인 자동 실행 |
| Lock | lock, unlock | 2 | 동시성 제어 시스템 전용 |
| Heartbeat | heartbeat_start, heartbeat_stop, heartbeat_list, heartbeat_result | 4 | 시스템 루프 전용 |
| Task internal | cancel_task, claim_task, complete_task, release_task, set_current_task | 5 | SDK 내부 task lifecycle |
| Agent internal | agent_fitness, agent_relations, meta_cognition_snapshot, consolidate_learning, select_agent | 5 | 시스템 평가 루프 |
| Cleanup | cleanup_zombies, gc | 2 | 유지보수 자동화 |
| Infra | cancellation, subscription, feature_flags, compact_context | 4 | 인프라 제어 |
| Misc | autoresearch_status, pause_status, tool_stats, surface_audit | 4 | 내부 모니터링 |

### Remaining Promotions (88개)

| Target Surface | Tools | Count |
|----------------|-------|-------|
| Admin | command plane 31 + operator 2 + collaboration 2 + keeper_create_from_persona 1 | 36 |
| Public_mcp | verify 5 + episode 2 + board 2 + recall_search + bounded_run | 11 |
| Spawned_agent | code 5 + plan 3 + portal_close + error 2 + workflow_guide + update_priority + deliver | 14 |
| Local_worker | improve_loop 5 + library 5 + relay 2 | 12 |
| Keeper_internal | keeper_unified 1 | 1 |
| Session_min | (없음) | 0 |

**검증**: 38 + 36 + 11 + 18 + 12 + 1 = 116. 나머지 10개:
- auth 6개 (disable, enable, list, refresh, revoke, status) → **Admin**
- tool_list, tool_stats → tool_stats는 System_internal, tool_list는 **Admin**
- get_metrics → **System_internal** (위에 포함)
- verify_handoff → **Spawned_agent**
- team_session_prove → **Spawned_agent**

최종: 38 + 88 = 126.

## Implementation Plan (순서 수정)

v1 결함: surface 등록 전에 tier 분류가 선행되어야 함.

| Phase | Action | PR | Blocking |
|-------|--------|-----|---------|
| **0** | ~~Dead code 제거~~ (Round 1 완료: 61개, -5.6K lines) | #4782 | - |
| **1** | System_internal surface 타입 추가 | 별도 PR | Phase 2 blocks |
| **2** | 126개 도구 surface 등록 (SSOT 일괄) | 별도 PR | Phase 1 blocks |
| **3** | Tier 재분류: 88개 신규 surface 도구의 tier 결정 | 동시 or 후속 PR | Phase 2 blocks |
| **4** | CI Validation: orphan = 0 강제 | 동시 PR | Phase 2 blocks |
| **5** | 텔레메트리 기반 deprecation (6개월 후) | 추적 이슈 | Phase 4 blocks |

## Validation Rule (강화)

```ocaml
(* Rule 1: 모든 등록 도구는 최소 1개 surface에 속해야 함 *)
let orphaned = List.filter (fun schema ->
  not (List.exists (fun surface ->
    Tool_catalog_surfaces.is_on_surface surface schema.name
  ) Tool_catalog_surfaces.all_surfaces))
  Config.raw_all_tool_schemas
in
assert (orphaned = []);

(* Rule 2: Public_mcp surface의 도구 수 상한 *)
let public_count = List.length
  (Tool_catalog_surfaces.tools_for_surface Public_mcp) in
assert (public_count <= 80);  (* 현재 ~48 + 11 = ~59 *)

(* Rule 3: System_internal 도구는 tools/list에 절대 미포함 *)
let system_tools = Tool_catalog_surfaces.tools_for_surface System_internal in
List.iter (fun name ->
  assert (not (Tool_catalog.is_visible name))
) system_tools
```

## Trade-offs

| Decision | Risk | Mitigation |
|----------|------|-----------|
| System_internal surface 신설 | 복잡도 증가 | 기존 Hidden 메커니즘과 통합 |
| 88개 surface 승격 | LLM 도구 선택 정확도 하락 | Tier 필터링으로 Essential/Standard만 노출 |
| 0개 제거 | 사문 코드 잔존 | Phase 5 텔레메트리로 6개월 후 정리 |
| Public_mcp 상한 80 | 유연성 제한 | 상한은 조정 가능, CI에서 경고 수준 |

## Review Log

### v1 → v2 변경사항

| # | v1 결함 | v2 수정 | 출처 |
|---|--------|---------|------|
| 1 | REMOVE 7개 오판 (handler 존재) | REMOVE 0개, 전부 PROMOTE | 자체 비판 |
| 2 | C2 REMOVE 8개 오판 (handler 존재) | 동일 | 자체 비판 |
| 3 | Surface 등록 = LLM 노출 혼동 | System_internal surface 신설 | GLM-5.1 |
| 4 | Phase 순서: Surface → Tier → Validation | Tier 선행, Validation 동시 | GLM-5.1 |
| 5 | C1/C2 분류 기준 불일관 | Caller identity 기반 재분류 | GLM-5.1 |
| 6 | Validation이 소속만 체크 | Public_mcp 상한 + System_internal 미노출 체크 추가 | GLM-5.1 |
