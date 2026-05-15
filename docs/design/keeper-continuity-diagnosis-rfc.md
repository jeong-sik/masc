# Keeper Continuity Diagnosis & Filesystem Cleanup RFC

**Status**: Draft v3 (post-review, 7 rounds)
**Date**: 2026-03-29
**Scope**: MASC Keeper Checkpoint Continuity / GC / Naming
**Issues**: #3626 (zombie GC), #3627 (perpetual naming), #3630 (memory dead code)
**One sentence**: keeper가 이전 대화를 기억 못하는 원인을 OAS checkpoint 경로 진단으로 확정하고, 진단 중 발견된 filesystem 부채(dead code, naming, GC)를 정리한다.

## Related Documents

- `./oas-masc-state-boundary.md`
- `./cross-run-loader-and-window-spec.md`
- `../spec/05-keeper-agent.md`
- `../spec/12-memory-systems.md`
- `../spec/13-oas-integration.md`
- `../KEEPER-CONTINUITY-VALIDATION.md`
- `./keeper-continuity-product-rfc.md`
- `../KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md`
- `config/prompts/keeper.constitution.md`

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| v1 | 2026-03-29 | Initial draft: "memory resurrection" framing |
| v2 | 2026-03-29 | 6건 리뷰 반영: Phase 1A root cause 정정, history recall 대안, 스키마 정합성, GC 위치, rename scope, keeper_chat surface |
| v3 | 2026-03-29 | 20건 리뷰 통합: 제목/서사 재편, OAS checkpoint 1순위 진단, G1-G7을 cleanup backlog로 재분류, recall helper ceiling 명시, H3 비교 실험 harness 분리 |

## Problem Statement

masc-mcp filesystem 진단에서 keeper memory 시스템의 여러 gap을 발견했다. 대표 증상: 23개 keeper가 37턴 이상 대화했지만 "아까 뭐라고?"에 "기억하지 못합니다"로 응답.

**원인은 미확정이다.** 진단 중 7개 gap(G1-G7)을 발견했으나, 이들이 증상의 직접 원인인지는 런타임 재현으로 확인해야 한다.

## Symptom vs Available Fix Mismatch

| | 증상 | recall helper 실제 커버리지 |
|---|------|---------------------------|
| **대상** | assistant의 이전 응답 | user 메시지만 |
| **시나리오** | "아까 뭐라고?" (2턴째) | keep_last_30 초과 user 메시지 |
| **범위** | same session | current trace only (generation rollover 불가) |

`recall_candidates_with_history`는 원래 증상을 해결하지 않는다. 증상 해결의 1순위는 OAS checkpoint를 통한 대화 이력(assistant 응답 포함) 복원이다.

## Hypothesis Table (OAS Checkpoint First)

| 가설 | 진단 대상 (OAS 경로 우선) | 확인 방법 | Fix |
|------|--------------------------|----------|-----|
| H1: OAS checkpoint 미저장 | `keeper_agent_run.ml:221` → `keeper_checkpoint_store.ml:128` (`save_oas_checkpoint`) | `Keeper_checkpoint_store.load_oas` 반환값 확인 (source of truth). raw 파일 경로는 `Fs_compat`/`Agent_sdk.Checkpoint_store` 경유 여부에 따라 다르므로 구현 세부사항으로만 참조. | OAS checkpoint build/save 수정 |
| H2: OAS checkpoint messages 비어있음 | `keeper_checkpoint_store.ml:150` (`load_oas_checkpoint`) → `keeper_exec_context.ml:242` (restore) → `keeper_exec_context.ml:61` (역직렬화) | load_oas 결과의 messages 배열 확인 | OAS checkpoint 직렬화/역직렬화 수정 |
| H3: LLM이 context를 무시 | model quality | 동일 `run_turn` 경로에서 모델/max_context/temperature/max_tokens 4개 값을 명시적으로 고정한 비교. `cascade_name` 변경은 4개 값을 모두 재resolve하므로, cascade swap 시 각 값을 동일하게 오버라이드. **`masc_keeper_msg` 사용자 도구로는 수행 불가 — 내부 harness/테스트 경로로 수행.** | 모델 교체 또는 prompt 강화 |
| H4: prompt assembly 문제 | `keeper_agent_run.ml:147-200` | debug log: `initial_messages` 길이 + 첫/마지막 메시지 + `turn_system_prompt` 길이/hash | prompt assembly 수정 |

**OAS `<trace_id>.json`이 primary checkpoint.** legacy `ckpt-*.json`은 fallback. `load_context_from_checkpoint`는 OAS를 우선 시도.

## Gap Classification

진단 중 발견된 7개 gap. **이들은 증상의 원인이 아니라 별도 cleanup backlog다.**

| Gap | 분류 | 요약 |
|-----|------|------|
| G1: memory bank write dead code | Cleanup backlog | `append_memory_notes_from_reply` caller 0개 |
| G2: seed_memory_bank no-op | Cleanup backlog | 의도적 no-op, 테스트 계약으로 고정 |
| G3: compaction dead code | Cleanup backlog | `compact_memory_bank_if_needed` caller 0개 |
| G4: compact_if_needed 미호출 | Cleanup backlog | unified path에서 미사용 |
| G5: constitution 미주입 | Cleanup backlog | `[STATE]` 형식이 system prompt에 미포함 |
| G6: auto-rules act 안 함 | Cleanup backlog | evaluate하지만 compact/reflect/plan 미실행 |
| G7: keeper_chat 2중 운영 | Cleanup backlog | 활성 surface (streaming HTTP + dashboard), 통합 비용 높음 |

## Non-Goals

- Dead memory bank 부활 (G1-G3, G5-G6은 cleanup backlog)
- recall_candidates_with_history의 generation 횡단 확장
- keeper_chat 저장소 통합 (UI/API 소비자 재설계 필요)
- OAS Memory.t 5-tier 구조 변경

## Phase 1: OAS Checkpoint Diagnosis (GATE)

Phase 1은 구현이 아니라 **진단**이다.

### 진단 절차

1. keeper 기동 (deterministic-purist)
2. 1턴 메시지 전송: "나는 Vincent"
3. OAS checkpoint 확인: `Keeper_checkpoint_store.load_oas` 반환값 확인
4. messages 배열 길이/내용 확인 (비어있으면 H2)
5. 2턴 메시지 전송: "아까 내 이름이 뭐라고 했지?"
6. 응답 확인

### Debug Log (Phase 1의 유일한 코드 변경)

`keeper_agent_run.ml`의 Agent.run 호출 직전(line ~195):

```ocaml
Log.debug "initial_messages: len=%d first=%s last=%s"
  (List.length ctx_work.messages)
  (first_msg_preview) (last_msg_preview);
Log.debug "turn_system_prompt: len=%d hash=%s"
  (String.length turn_system_prompt)
  (Digest.string turn_system_prompt |> Digest.to_hex |> fun s -> String.sub s 0 8)
```

첫 번째 로그는 H1/H2 판별, 두 번째는 H4 분리에 사용.

H3 비교 실험은 내부 harness/테스트 경로로 별도 수행 — debug log와는 다른 작업.

### 경로 분기

| Phase 1 결과 | Phase 2 경로 |
|-------------|------------|
| H1/H2 확인 | OAS checkpoint save/load/restore 수정 |
| H3 확인 | 모델 문제 — 코드 수정 불필요 또는 prompt 강화 |
| H4 확인 | prompt assembly 수정 |

## Phase 2: Fix (가설 의존)

Phase 1 결과에 따라 결정. 미리 설계하지 않는다.

### recall_candidates_with_history 연결 판단 기준

| 조건 | 판단 |
|------|------|
| checkpoint fix로 2턴 회상 동작 | 연결 불필요 (keep_last_30으로 충분) |
| keep_last_30 초과, current-trace user 메시지 recall 필요 | 연결 |
| assistant 응답 recall 필요 | helper 수정 필요 (scope 외) |
| generation rollover 횡단 recall 필요 | helper 수정 필요 (scope 외) |

## Phase 3: GC (기존 도구 재위치)

`masc_gc`(`tool_schemas_misc.ml:120`), `masc_cleanup_zombies`(`tool_schemas_misc.ml:136`) — 이미 schema/handler/test 완비. 새 도구 추가 없음.

### 수정 범위

- `set_room`/`join` 시 해당 room에서 `cleanup_zombies` 1회 호출
  - 구현 위치: `tool_inline_dispatch_room.ml:185` (set_room), `:226` (join)
  - **주의**: `set_room` 핸들러는 중간에 `state.Mcp_server.room_config`를 교체. `cleanup_zombies` 호출은 **새로 resolve된 config**로. 교체 전 `ctx.config`로 호출하면 이전 room에서 GC 실행.
- multi-room gap 증명 필요: gap이 없으면 "set_room 시 1회 cleanup" 연결만으로 종결.

## Phase 4: Naming Cleanup

### Consumer Inventory

Source files (functional 변경): 9 files, 19 occurrences + TUI.

| File | Context |
|------|---------|
| `server_runtime_bootstrap.ml:156,172,173,178` | dir creation, prune |
| `keeper_types_profile.ml:501,508` | `keeper_dir` return |
| `keeper_types_support.ml:23,24,28` | path helpers |
| `room_gc.ml:295` | orphan cleanup |
| `tool_housekeep.ml:18,21,171` | path classification |
| `keeper_schema.ml` | API descriptions |
| `bin/masc_tui.ml:990+` | TUI display |
| `keeper_agent_run.ml:102`, `env_config_runtime.ml:269` | comments |

Documentation: 13 files, 26 occurrences.

### Directory Rename

```
.masc/perpetual/          → .masc/traces/
.masc/keepers/  → .masc/keepers/
.masc/resident-keepers/   → .masc/keepers/ (병합 후 삭제)
```

### Migration: 재귀 merge + file-level quarantine

```
migrate_recursive old_dir new_dir:
  for each entry in old_dir:
    if directory:
      if same dir in new_dir → recurse (재귀 merge)
      else → move to new_dir
    if file:
      if same file in new_dir → move to .masc/_quarantine/<relative_path>
      else → move to new_dir
  if old_dir empty → rmdir
  else → log warning
```

자동 부팅 migration에서 데이터 삭제는 절대 안 함. `.masc/_quarantine/`은 수동 검토 대상.

## Cleanup Backlog (별도 이슈, RFC scope 외)

이 항목들은 증상의 원인이 아니라 진단 중 발견된 부채다.

| 항목 | 설명 |
|------|------|
| G1: `append_memory_notes_from_reply` | 삭제 또는 memory bank 활성화 시 연결 |
| G2: `seed_memory_bank` no-op | 테스트 계약 변경 포함 |
| G3: `compact_memory_bank_if_needed` | 삭제 후보 |
| G5: constitution `[STATE]` 미주입 | 별도 prompt 설계 |
| G6: auto-rules act 미연결 | compact/reflect/plan |
| Recall observability | `evaluate_memory_recall`, `memory_eval_to_json`, `work_kind_of_eval`, `memory_check_default_json` 실제 값 교체 |

## Open Questions

1. **Phase 1 진단 결과**: checkpoint messages가 비어있는가? OAS checkpoint save/load가 정상인가?
2. **H3 harness**: 내부 harness 경로를 어떻게 구성하는가? 기존 test 인프라 활용 가능한가?
3. **recall helper ceiling 밖 요구**: assistant 응답 recall, generation 횡단이 필요한 시점은?

## Risk

| Risk | Mitigation |
|------|------------|
| Phase 1 진단 결과에 따라 Phase 2 경로 변경 | Phase 1을 gate로, fix는 결과 후 설계 |
| Phase 4 rename으로 기존 데이터 유실 | 재귀 merge + file-level quarantine, 자동 삭제 없음 |
| seed_memory_bank no-op 해제 시 테스트 깨짐 | Cleanup backlog로 분리, 별도 단계 |

## Execution Order

```
Phase 1 (OAS checkpoint 진단 — GATE, debug log 2개만 코드 변경)
  → Phase 2 (진단 결과에 따른 fix)
    → Phase 3 (GC: set_room/join 시 cleanup 연결)
      → Phase 4 (naming: full inventory + 재귀 migration)
```
