# Keeper Memory Resurrection RFC

**Status**: Draft v2 (post-review)
**Date**: 2026-03-29
**Scope**: MASC Keeper Memory / GC / Naming
**Issues**: #3626 (zombie GC), #3627 (perpetual naming), #3630 (memory dead code)
**One sentence**: keeper memory 시스템의 dead code를 정리하고, 기존 history recall 경로를 연결하여 최소 기억 능력을 복원하며, filesystem 정합성을 확보한다.

## Related Documents

- `./oas-masc-state-boundary.md`
- `./cross-run-loader-and-window-spec.md`
- `../spec/05-keeper-agent.md`
- `../spec/12-memory-systems.md`
- `../spec/13-oas-integration.md`
- `../ADR-001-MITOSIS-VS-COMPACTION.md`
- `../AGENT-MEMORY-SYSTEM.md`
- `../KEEPER-CONTINUITY-VALIDATION.md`
- `config/prompts/keeper.constitution.md`

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| v1 | 2026-03-29 | Initial draft |
| v2 | 2026-03-29 | 6건 리뷰 반영: Phase 1A root cause 정정, history recall 대안 비교, memory.jsonl 스키마 정합성, GC 구현 위치/읽기쓰기 경계, rename scope 재산정, keeper_chat surface 비용 추가 |

## Problem Statement

masc-mcp filesystem 진단에서 keeper memory 시스템이 설계는 되어 있으나 동작하지 않음을 발견했다. 23개 keeper가 37턴 이상 대화했지만 `memory.jsonl`이 0개이고, "아까 뭐라고?"에 "기억하지 못합니다"로 응답한다.

근본 원인은 단일 결함이 아니라 **7개 gap의 중첩**이다.

## Gap Analysis

### G1: Memory Bank Write Path — Dead Code (Critical)

`append_memory_notes_from_reply` (`keeper_memory_bank.ml:372`)의 caller가 **0개**.
메모리 저장 경로가 구현만 되고 연결되지 않았다.

### G2: Memory Bank Read Path — Intentional No-op (Critical)

`Memory_oas_bridge.seed_memory_bank` (`memory_oas_bridge.ml:129`)이 의도적 no-op.
테스트(`test_memory_oas_5tier.ml:383`)가 `returns 0`을 명시적으로 assert한다.
memory.jsonl에 데이터가 있어도 LLM prompt에 주입되지 않는다.

**주의**: no-op 해제는 단순 연결이 아니라 **기존 테스트 계약 변경**이다.

### G3: Memory Bank Compaction — Dead Code (High)

`compact_memory_bank_if_needed` (`keeper_memory_bank.ml:204`)의 caller가 **0개**.

### G4: Context Compaction — Unified Path에서 미호출 (High)

`compact_if_needed` (`keeper_exec_context.ml:289`)는 re-export되지만 unified turn에서 호출되지 않는다. OAS 기본 `Context_reducer` (keep_last_30 + prune + merge)만 동작.

### G5: Constitution Prompt 미주입 (High)

`[STATE]` 블록 형식이 `config/prompts/keeper.constitution.md`에 정의되어 있지만, `build_keeper_system_prompt`에서 system prompt에 포함되지 않는다.

### G6: Auto-rules — Evaluate But Don't Act (Medium)

`evaluate_keeper_auto_rules`가 compact/reflect/plan 플래그를 반환하지만 unified turn에서 handoff만 실행.

### G7: 대화 저장소 2중 운영 (Medium)

`history.jsonl` (per-trace)과 `keeper_chat/<name>.jsonl` (per-keeper)이 공존.

**주의**: keeper_chat은 단순 dead file이 아니다:
- **쓰기**: `server_routes_http_keeper_stream.ml:513` (스트리밍 HTTP 경로)
- **읽기**: `server_routes_http_routes_dashboard.ml:328` (대시보드 chat-history API)

통합하려면 history.jsonl로의 저장소 교체 + UI/API 소비자에서 trace→keeper 매핑 + internal/system message 필터링 재설계가 필요하다. 단순 삭제가 아님.

## Conversation History: Clarification (v1 오류 정정)

v1에서 "checkpoint messages가 unified turn에서 버려진다"고 분석했으나 이는 **오진**이었다.

실제 흐름:

```
keeper_unified_turn.ml:237
  build_turn_prompt ~base_system_prompt:_ ~messages:_ = system_prompt
    ↑ 이 callback은 "프롬프트 조립에 messages를 안 쓴다"는 뜻

keeper_agent_run.ml:147-151
  turn_system_prompt = build_turn_prompt ~base_system_prompt ~messages:ctx_work.messages
    ↑ callback이 messages를 무시해도 turn_system_prompt만 결정됨

keeper_agent_run.ml:195-200
  Oas_worker.run_named ~initial_messages:ctx_work.messages
    ↑ ctx_work.messages는 checkpoint에서 복원된 전체 대화 이력
    ↑ Agent.run()에 그대로 전달됨
```

**결론**: 대화 이력은 Agent.run()에 전달된다. `~messages:_` 무시는 프롬프트 조립 callback 한정이며, `initial_messages`는 별도 경로로 전달된다.

이것은 "아까 뭐라고?" 실패의 원인이 **대화 이력 미전달이 아님**을 의미한다. 실제 원인 후보:

1. checkpoint가 존재하지 않아 messages가 비어있을 수 있음
2. `keep_last 30` reducer로 오래된 메시지가 잘림
3. 로컬 모델(qwen3.5-9b)의 instruction following 한계
4. 아직 미확인된 경로 문제

**이 원인을 런타임 재현으로 확인하는 것이 Phase 1의 전제 조건이다.**

## Alternative Analysis: History Recall vs Memory Bank

v1은 memory bank 부활을 먼저 택했으나, **history.jsonl 기반 recall 연결이 더 저렴한 대안**이다.

### 비교

| 경로 | 구현 상태 | 연결 비용 | 커버리지 |
|------|----------|----------|----------|
| **A) history.jsonl recall** | `recall_candidates_with_history` 구현 완료 + 테스트 있음 (`test_keeper_memory.ml:190`). `is_memory_recall_query`로 한국어/영어 키워드 탐지 가능. caller 0개 (production 미연결). | 낮음: caller 1개 연결 | 동일 trace + cross-generation recall |
| **B) memory bank 부활** | write/read/compact 3개 함수 구현됨. 모두 dead code. `seed_memory_bank` no-op 해제는 테스트 계약 변경. 스키마: `kind/text/priority/ts_unix`. | 높음: 3개 함수 연결 + 테스트 변경 + [STATE] prompt 주입 | structured 메모리 (kind별 분류, priority) |

### 판정

**"아까 뭐라고?" 증상 해결**에는 경로 A가 충분하다. history.jsonl은 이미 매 턴 저장되고 있고(`persist_message`), recall helper도 테스트까지 되어 있다. 연결만 하면 된다.

경로 B (memory bank)는 structured memory가 필요한 시점 — 예: soul profile 기반 우선순위, kind별 retention policy — 에서 추가한다. 지금은 premature.

## Non-Goals

- Neo4j 기반 agent learning 시스템 구현
- OAS Memory.t의 5-tier 구조 변경
- Keeper의 실행 모델 변경
- keeper_chat/ 저장소 통합 (별도 이슈로 분리 — UI/API 소비자 재설계 필요)

## Design Principles

1. **기존 경로를 연결한다.** 새 코드보다 미연결된 기존 구현을 먼저 연결.
2. **LLM 출력 형식에 의존하지 않는다.** `[STATE]` 파싱은 나중에.
3. **Filesystem backend의 강점을 활용한다.** 서버 프로세스 없이도 읽기/정리 가능.
4. **계약 변경은 명시적으로.** no-op 해제, 테스트 변경은 별도 단계.
5. **읽기/쓰기 경계를 지킨다.** read API에 mutation side effect를 섞지 않는다.

## Proposed Architecture

### Phase 1: History Recall 연결 + 런타임 검증 (1 day)

목표: "아까 뭐라고?" 증상 해결의 실제 원인 확인 + 최소 recall 동작.

#### 1A. 런타임 재현 및 원인 확정

keeper에게 2턴 대화 후 recall 질문을 보내 다음을 확인:

1. checkpoint 존재 여부 (`.masc/perpetual/<trace_id>/` 내부)
2. `ctx_work.messages` 길이 (0이면 checkpoint 미복원)
3. `initial_messages`가 Agent.run()에 도달하는지

이 결과에 따라 fix 대상이 달라진다:
- messages 비어있음 → checkpoint 저장/복원 경로 수정
- messages 있지만 LLM이 못 답함 → 모델 한계 또는 context 크기 문제

#### 1B. recall_candidates_with_history 연결

`recall_candidates_with_history` (`keeper_memory_recall.ml:560`)를 keeper turn 경로에 연결한다.

연결 지점 후보:
- `keeper_turn.ml`의 `handle_keeper_msg`에서 `is_memory_recall_query` 탐지 → recall candidates를 system prompt에 주입
- 또는 `keeper_agent_run.ml` pre-run 단계에서 history recall을 OAS Episodic tier에 seed

스키마 호환성: history.jsonl의 `role/content/ts` 형식을 그대로 읽는다 (`load_history_user_messages`가 이미 처리).

### Phase 2: GC 개선 (1 day)

목표: multi-room에서 zombie agent 정리.

#### 2A. 설계 판단: read API vs mutation

현재 `masc_status`/`masc_agents`는 read API다. stale check을 inline으로 넣으면 read에 mutation side effect가 섞인다.

대안 비교:

| 방식 | 장점 | 단점 |
|------|------|------|
| A) read에 inline mutation | 접근 즉시 정리 | read/write 경계 위반, 예상치 못한 상태 변경 |
| B) 별도 `masc_gc` 도구 | 명시적, 예측 가능 | 사용자가 수동 호출해야 함 |
| C) room 진입 시 1회 GC | 자연스러운 트리거, read API 오염 없음 | `set_room` 호출 시만 실행 |

**권장**: C) `masc_set_room` 또는 `masc_join` 시점에 해당 room의 zombie cleanup을 1회 실행. read API는 깨끗하게 유지.

#### 2B. 구현 위치

`room_query.ml:79`(`load_agents_from_dir`)가 agent 조회의 실제 위치. `room_lifecycle.ml`은 join/leave 전용.

GC trigger 위치: `room_lifecycle.ml`의 `join` 또는 `set_room` 핸들러에서 `Room_gc.cleanup_zombies` 호출.

#### 2C. PID 중복 확인

agent meta에 이미 PID 정보가 있다 (`types_core.ml:144`의 meta 필드). PID lockfile은 불필요.

### Phase 3: Naming Cleanup (1-2 days)

목표: deprecated "perpetual" 용어를 현재 의미에 맞게 정리.

#### 3A. 완전한 Consumer Inventory

v1에서 "8개 path string in 6 files"로 축소했으나 실제 범위는 더 넓다.

**Source files** (functional 변경 필요):

| File | Occurrences | Context |
|------|-------------|---------|
| `server_runtime_bootstrap.ml:156,172,173,178` | 4 | dir creation, prune logic |
| `keeper_types_profile.ml:501,508` | 2 | `keeper_dir` return value |
| `keeper_types_support.ml:23,24,28` | 3 | path helpers, comments |
| `room_gc.ml:295` | 1 | orphan cleanup path |
| `tool_housekeep.ml:18,21,171` | 3 | path pattern matching, classification |
| `keeper_schema.ml` | 2 | API parameter descriptions |
| `keeper_agent_run.ml:102` | 1 | comment |
| `bin/masc_tui.ml:990+` | 2+ | TUI keeper status display |
| `env_config_runtime.ml:269` | 1 | comment |

**Documentation** (13 files, 26 occurrences): `spec/05-keeper-agent.md`(6), `KEEPER-USER-MANUAL.md`(6), `spec/14-configuration.md`(3), etc.

**Type variant**: `pulse.mli:44`의 `Perpetual` variant은 lifecycle 의미 (not naming). 유지.

합계: source ~19 occurrences in ~9 files + docs 26 occurrences in 13 files.

#### 3B. 디렉토리 Rename

```
.masc/perpetual/          → .masc/traces/
.masc/perpetual-keepers/  → .masc/keepers/
.masc/resident-keepers/   → .masc/keepers/로 병합 후 삭제
```

#### 3C. Migration Shim (mixed-state 대응)

v1의 shim은 "new가 이미 있으면 old를 남겨두는" 방식이라 legacy 데이터가 고립된다.

수정안:

```ocaml
let migrate_legacy_dirs base =
  let migrate old_name new_name =
    let old_p = Filename.concat base old_name in
    let new_p = Filename.concat base new_name in
    if Sys.file_exists old_p then begin
      if not (Sys.file_exists new_p) then
        (* Clean rename: old exists, new doesn't *)
        Sys.rename old_p new_p
      else begin
        (* Mixed state: both exist — merge old into new *)
        let entries = Sys.readdir old_p in
        Array.iter (fun entry ->
          let src = Filename.concat old_p entry in
          let dst = Filename.concat new_p entry in
          if not (Sys.file_exists dst) then
            Sys.rename src dst
          (* else: new-side wins, old-side file is orphaned *)
        ) entries;
        (* Remove old dir if empty *)
        if Array.length (Sys.readdir old_p) = 0 then
          Sys.rmdir old_p
        else
          Log.warn "Legacy dir %s still has files after migration" old_p
      end
    end
  in
  migrate "perpetual-keepers" "keepers";
  migrate "perpetual" "traces"
```

### Phase 4: Dead Code Audit (0.5 day)

Production code에서 caller 0개인 함수의 처리 방침:

| Function | Test caller | Production caller | Action |
|----------|------------|-------------------|--------|
| `append_memory_notes_from_reply` | 0 | 0 | 삭제 후보. Phase 1에서 memory bank 경로 채택 시 연결. |
| `compact_memory_bank_if_needed` | 0 | 0 | memory bank 활성화 전까지 삭제 후보. |
| `recall_candidates_with_history` | 1 (test) | 0 | **Phase 1B에서 연결.** |
| `is_memory_recall_query` | 0 | 0 | Phase 1B에서 recall trigger로 연결 또는 삭제. |
| `compact_if_needed` (keeper-level) | 불명 | 0 (unified path) | auto-rules act 연결 시 활성화. 별도 이슈. |

## Verification Plan

### Phase 1 검증

```bash
# 1A. 런타임 재현
masc_keeper_msg deterministic-purist "안녕, 나는 Vincent"
# → checkpoint 생성 확인
ls .masc/perpetual/<trace_id>/

masc_keeper_msg deterministic-purist "아까 내 이름이 뭐라고 했지?"
# → checkpoint messages 비어있는지 로그 확인

# 1B. recall 연결 후
# 예상: "Vincent"를 포함한 응답
```

### Phase 2 검증

```bash
# keeper 종료 후 set_room 시 GC 실행 확인
masc_set_room /path/to/masc-mcp
masc_status
# 예상: stale keeper들이 inactive로 전환

# read API (masc_agents)가 side effect 없이 상태 표시만 하는지 확인
```

### Phase 3 검증

```bash
# 디렉토리 확인
ls .masc/keepers/          # perpetual-keepers/ 대신
ls .masc/traces/           # perpetual/ 대신

# 서버 정상 부팅
dune exec masc_mcp -- --help

# 기존 데이터 보존
cat .masc/keepers/deterministic-purist.json | jq .name

# mixed-state migration: 양쪽 디렉토리 존재 시 merge 확인
```

## Open Questions

1. **런타임 재현 결과**: checkpoint messages가 실제로 채워져 있는가? 비어있다면 원인은 무엇인가?
2. **history recall vs memory bank**: structured memory (kind/priority)가 필요한 시점은 언제인가? MVP 이후 어떤 signal이 memory bank 활성화를 정당화하는가?
3. **keeper_chat 통합 비용**: UI/API 소비자 (streaming HTTP, dashboard chat-history)의 trace→keeper 매핑 재설계 범위는?
4. **auto-rules act 연결**: compact/reflect/plan 중 어떤 것을 먼저 unified turn에 연결하는가?

## Risk

| Risk | Mitigation |
|------|------------|
| Phase 1A 런타임 재현 결과에 따라 설계 변경 필요 | Phase 1A를 gate로 두고 결과에 따라 1B 조정 |
| Phase 3 rename으로 기존 데이터 유실 | mixed-state migration shim + 부팅 시 merge |
| seed_memory_bank no-op 해제는 테스트 계약 변경 | 별도 단계로 분리, 테스트 업데이트 포함 |
| keeper_chat 삭제 시 dashboard 장애 | Non-goal로 분리, 별도 이슈 |

## Execution Order

```
Phase 1A (런타임 재현 — GATE)
  → 1B (history recall 연결)
    → Phase 2 (GC: set_room 시점 trigger)
      → Phase 3 (naming: full inventory + migration)
        → Phase 4 (dead code audit)
```
