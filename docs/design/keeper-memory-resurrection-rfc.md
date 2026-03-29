# Keeper Memory Resurrection RFC

**Status**: Draft
**Date**: 2026-03-29
**Scope**: MASC Keeper Memory / GC / Naming
**Issues**: #3626 (zombie GC), #3627 (perpetual naming), #3630 (memory dead code)
**One sentence**: keeper memory 시스템의 dead code를 제거하고, 동작하는 최소 메모리 파이프라인을 복원하며, filesystem 전반의 정합성을 확보한다.

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

## Problem Statement

masc-mcp filesystem 진단에서 keeper memory 시스템이 설계는 되어 있으나 동작하지 않음을 발견했다. 23개 keeper가 37턴 이상 대화했지만 `memory.jsonl`이 0개이고, "아까 뭐라고?"에 "기억하지 못합니다"로 응답한다.

근본 원인은 단일 결함이 아니라 **7개 gap의 중첩**이다.

## Gap Analysis

### G1: Memory Bank Write Path — Dead Code (Critical)

`append_memory_notes_from_reply` (`keeper_memory_bank.ml:372`)의 caller가 **0개**.
메모리 저장 경로가 구현만 되고 연결되지 않았다.

```
LLM reply → parse_state_snapshot_from_reply → append_memory_notes_from_reply
                                                    ↑ NEVER CALLED
```

### G2: Memory Bank Read Path — Intentional No-op (Critical)

`Memory_oas_bridge.seed_memory_bank` (`memory_oas_bridge.ml:129-131`)이 의도적 no-op.
memory.jsonl에 데이터가 있어도 LLM prompt에 주입되지 않는다.

```ocaml
let seed_memory_bank ~memory ~agent_name ~limit =
  ignore (memory, agent_name, limit); 0  (* intentional no-op *)
```

### G3: Memory Bank Compaction — Dead Code (High)

`compact_memory_bank_if_needed` (`keeper_memory_bank.ml:204`)의 caller가 **0개**.
profile 기반 dedup, 우선순위 정렬, kind별 cap 로직이 전부 미사용.

### G4: Context Compaction — Unified Path에서 미호출 (High)

`compact_if_needed` (`keeper_exec_context.ml:289`)는 `keeper_coordination.ml`에서 re-export되지만 unified turn path에서 호출되지 않는다. DropLowImportance, SummarizeOld 같은 전략이 쓰이지 않고 OAS의 기본 `Context_reducer` (keep_last_30 + prune + merge)만 동작한다.

### G5: Constitution Prompt 미주입 (High)

`[STATE]` 블록 형식이 `config/prompts/keeper.constitution.md`에 정의되어 있지만, `build_keeper_system_prompt`에서 constitution 전체가 system prompt에 포함되지 않는다. LLM이 `[STATE]`를 출력할 이유가 없다.

### G6: Auto-rules — Evaluate But Don't Act (Medium)

`evaluate_keeper_auto_rules` (`keeper_memory_recall.ml:313-437`)가 compact/reflect/plan 플래그를 반환하지만 unified turn에서 handoff만 실행하고 나머지는 무시된다.

### G7: 대화 저장소 2중 운영 (Medium)

`history.jsonl` (per-trace, `.masc/perpetual/<trace_id>/`)과 `keeper_chat/<name>.jsonl` (per-keeper)이 동일 데이터를 중복 저장. 참조 관계 없음.

## Current Data Flow (As-Is)

```
                           WRITE PATHS
                           ===========

[Keeper LLM Reply]
    |
    +--[STATE] block in reply text
    |   |
    |   v
    |   parse_state_snapshot_from_reply()  --> keeper_state_snapshot
    |   |
    |   +-> append_memory_notes_from_reply()  --> .memory.jsonl
    |   |   *** DEAD CODE: NEVER CALLED ***
    |   |
    |   +-> latest_state_snapshot_from_messages() --> continuity injection (ACTIVE)
    |
    +--persist_message() --> .masc/perpetual/<trace_id>/history.jsonl (ACTIVE)
    |
    +--OAS Checkpoint save --> .masc/perpetual/<trace_id>/<trace_id>.json (ACTIVE)
    |
    +--Memory_oas_bridge.flush_all() (ACTIVE)
        +-> flush_episodes() --> institution episodes JSONL
        +-> flush_procedures() --> procedural_memory JSONL

                           READ PATHS
                           ==========

[Pre-turn Memory Loading]
    |
    +--load_context_from_checkpoint() --> messages from checkpoint (ACTIVE)
    |
    +--Memory_oas_bridge.create_memory() + seed_* (ACTIVE)
    |   +-> seed_institution --> Long_term tier
    |   +-> seed_procedures (global, limit:5) --> Long_term tier
    |   +-> seed_memory_bank --> *** NO-OP (returns 0) ***
    |   +-> seed_episodes (limit:30) --> Episodic tier
    |   +-> seed_procedures_as_oas (limit:10) --> Procedural tier
    |
    +--Continuity snapshot from messages or meta.continuity_summary (ACTIVE)
    |
    +--read_keeper_memory_summary() --> status display only (NOT injected)

                           COMPACTION PATHS
                           ================

[OAS Context_reducer] (ACTIVE -- runs inside Agent.run())
    +-> keep_last 30 messages
    +-> Prune_tool_outputs (max 500 chars)
    +-> Merge_contiguous

[compact_if_needed] (keeper_exec_context.ml:289) -- *** NOT CALLED in unified path ***
[compact_memory_bank_if_needed] (keeper_memory_bank.ml:204) -- *** DEAD CODE ***

[maybe_rollover_oas_handoff] (ACTIVE -- runs after unified turns)
    +-> New trace_id + generation when context_ratio >= 0.85
```

## Non-Goals

- Neo4j 기반 agent learning 시스템 구현 (AGENT-MEMORY-SYSTEM.md 범위)
- OAS Memory.t의 5-tier 구조 변경
- Keeper의 실행 모델 변경 (Agent.run 기반 유지)

## Design Principles

1. **Dead code를 살리지 않는다.** 연결 안 된 코드를 연결하는 게 아니라, 동작하는 최소 경로를 설계한다.
2. **LLM 출력 형식에 의존하지 않는다.** `[STATE]` 파싱은 보너스일 뿐 메모리 저장의 필수 조건이 아니어야 한다.
3. **Filesystem backend의 강점을 활용한다.** 서버 프로세스 없이도 읽기/정리가 가능해야 한다.
4. **OAS Memory bridge를 통한 단일 경로.** keeper 전용 JSONL과 OAS Memory의 이중 경로를 통합한다.

## Proposed Architecture

### Phase 1: Minimum Viable Memory (1-2 days)

목표: keeper가 이전 대화를 기억하는 최소 상태 달성.

#### 1A. Conversation History 복원 검증

현재 `keeper_agent_run.ml:200`에서 `initial_messages:ctx_work.messages`로 checkpoint 기반 대화 이력을 전달하고 있다. 이 경로가 실제로 동작하는지 검증한다.

**의심 지점**: unified turn path (`keeper_unified_turn.ml:237`)에서 `~base_system_prompt:_ ~messages:_`로 caller 인자를 **무시**한다. checkpoint에서 복원한 messages가 버려지고 새 메시지만 전달될 가능성이 높다.

검증 방법:
1. `keeper_unified_turn.ml:237`의 `build_turn_prompt` callback 시그니처 확인
2. messages가 실제로 `Agent.run()`까지 전달되는지 trace

수정: `~messages:_` 무시를 제거하고, checkpoint messages를 base로 사용한 뒤 unified prompt를 append.

#### 1B. Auto-save Memory (LLM 형식 비의존)

매 턴 완료 후, LLM 응답과 무관하게 다음을 자동 저장:

```jsonl
{"ts":"...","turn":N,"role":"user","content":"...","trace_id":"..."}
{"ts":"...","turn":N,"role":"assistant","content":"...","trace_id":"..."}
```

`[STATE]` 파싱 성공 시 structured note를 추가 저장하되, 실패해도 기본 저장은 보장.

구현 위치: `keeper_agent_run.ml` post-run 단계 (line ~260, `persist_message` 호출 직후)

#### 1C. seed_memory_bank No-op 해제

`Memory_oas_bridge.seed_memory_bank`의 no-op을 해제하고, memory.jsonl의 recent N entries를 OAS Episodic tier로 주입한다.

```ocaml
let seed_memory_bank ~memory ~agent_name ~limit =
  let path = keeper_memory_bank_path config agent_name in
  let summary = read_keeper_memory_summary config ~name:agent_name
    ~max_bytes:32768 ~max_lines:limit ~recent_limit:limit in
  List.iter (fun note ->
    Memory.add memory ~tier:Episodic
      ~key:(Printf.sprintf "bank:%s" note.kind)
      ~value:(Yojson.Safe.to_string (`String note.text))
  ) summary.recent_notes;
  List.length summary.recent_notes
```

### Phase 2: GC Decoupling (1 day)

목표: 어떤 room에서든 접근 시 zombie agent가 정리되는 상태.

#### 2A. Passive GC

`masc_status`와 `masc_agents` 호출 시 inline stale check를 실행.

```
read_agents(room) → for each agent:
  if status = "active" && now - last_seen > threshold:
    mark_inactive(agent)
→ return filtered list
```

구현 위치: `room_lifecycle.ml`의 agents 조회 함수에 stale check 추가.
서버 Pulse GC는 유지하되, passive GC가 multi-room을 커버한다.

#### 2B. PID Lockfile (선택)

agent join 시 `.masc/agents/<name>.pid`에 PID 기록.
passive GC에서 `kill -0 <pid>`로 프로세스 생존 확인.
같은 머신 전제 (filesystem backend와 일치).

### Phase 3: Naming Cleanup (0.5 day)

목표: deprecated "perpetual" 용어를 현재 의미에 맞게 정리.

#### 3A. 디렉토리 Rename

```
.masc/perpetual/          → .masc/traces/
.masc/perpetual-keepers/  → .masc/keepers/
.masc/resident-keepers/   → 삭제 (1개 파일 → .masc/keepers/로 병합)
```

#### 3B. 코드 경로 변경

Functional 변경 (8개 path string in 6 files):

| File | Lines | Change |
|------|-------|--------|
| `server_runtime_bootstrap.ml` | 156,172,173,178 | dir creation paths |
| `keeper_types_profile.ml` | 501,508 | `keeper_dir` return value |
| `keeper_types_support.ml` | 24,28 | path helpers |
| `room_gc.ml` | 295 | cleanup path |
| `tool_housekeep.ml` | 21,171 | path pattern matching |
| `keeper_schema.ml` | 2 locations | API parameter descriptions |

Module rename:
- `Log.Perpetual` → `Log.Trace`
- `Pulse.Perpetual` variant은 lifecycle 의미이므로 유지

Documentation: 13 files, 26 occurrences.

#### 3C. Migration Shim

```ocaml
let migrate_legacy_dirs base =
  let rename old_name new_name =
    let old_p = Filename.concat base old_name in
    let new_p = Filename.concat base new_name in
    if Sys.file_exists old_p && not (Sys.file_exists new_p) then
      Sys.rename old_p new_p
  in
  rename "perpetual-keepers" "keepers";
  rename "perpetual" "traces"
```

`server_runtime_bootstrap.ml` 부팅 시 1회 실행.

### Phase 4: Dead Code Cleanup (0.5 day)

| Code | Action |
|------|--------|
| `append_memory_notes_from_reply` | Phase 1B auto-save로 대체. [STATE] 파싱은 보너스 경로로 유지. 미사용 시 삭제. |
| `compact_memory_bank_if_needed` | Phase 1B가 memory.jsonl을 채우면 compaction 필요. caller 연결 또는 OAS 레벨로 통합. |
| `compact_if_needed` (keeper-level) | unified turn에서 auto-rules 결과에 따라 호출 연결. OAS `Context_reducer`와 중복 검토. |
| `keeper_chat/<name>.jsonl` | `history.jsonl`과 통합. 하나만 유지. |

## File Impact Matrix

| Phase | File | Change |
|-------|------|--------|
| 1A | `lib/keeper/keeper_unified_turn.ml:237` | messages 무시 제거, checkpoint messages 활용 |
| 1A | `lib/keeper/keeper_agent_run.ml:134-146` | checkpoint → messages 복원 경로 검증 |
| 1B | `lib/keeper/keeper_agent_run.ml:~260` | post-run auto-save 추가 |
| 1B | `lib/keeper/keeper_memory_bank.ml` | auto-save 함수 추가 또는 기존 함수 연결 |
| 1C | `lib/memory_oas_bridge.ml:129-131` | no-op 해제, 실제 구현 |
| 2A | `lib/room/room_lifecycle.ml` | inline stale check 추가 |
| 3A | `lib/server/server_runtime_bootstrap.ml` | 디렉토리 경로 변경 + migration shim |
| 3B | 9 source files, 13 doc files | path string + docs 변경 |
| 4 | 여러 파일 | dead code 제거/연결 |

## Verification Plan

### Phase 1 검증

```bash
# 1. keeper 기동 후 대화
masc_keeper_msg deterministic-purist "안녕, 나는 Vincent"
masc_keeper_msg deterministic-purist "아까 내 이름이 뭐라고 했지?"
# 예상: "Vincent"라고 답해야 함

# 2. memory.jsonl 생성 확인
ls .masc/keepers/deterministic-purist.memory.jsonl
cat .masc/keepers/deterministic-purist.memory.jsonl | tail -3

# 3. OAS Memory에 bank 데이터 주입 확인
# keeper 로그에서 seed_memory_bank 반환값 > 0 확인
```

### Phase 2 검증

```bash
# 1. keeper 여러 개 기동 후 전부 종료 (kill -9)
# 2. threshold 경과 후 다른 room에서 접근
masc_set_room /path/to/masc-mcp
masc_status
# 예상: 종료된 keeper가 inactive로 표시

# 3. filesystem 직접 확인
python3 -c "
import json, glob
agents = [json.load(open(f)) for f in glob.glob('.masc/agents/*.json')]
active = [a for a in agents if a.get('status') == 'active']
print(f'active: {len(active)}')
"
```

### Phase 3 검증

```bash
# 1. 디렉토리 rename 확인
ls .masc/keepers/          # perpetual-keepers/ 대신
ls .masc/traces/           # perpetual/ 대신

# 2. 서버 정상 부팅 확인
dune exec masc_mcp -- --help

# 3. 기존 keeper 데이터 보존 확인
cat .masc/keepers/deterministic-purist.json | jq .name
```

## Open Questions

1. **checkpoint messages 복원이 실제로 동작하는가?** unified turn의 `~messages:_` 무시가 원인이면 Phase 1A가 핵심 fix. 이 확인이 전체 설계를 좌우한다.
2. **`[STATE]` 파싱을 유지할 가치가 있는가?** auto-save로 대체하면 파서 코드 500줄+가 dead code 후보.
3. **keeper_chat/ 저장소의 사용처가 있는가?** history.jsonl과 통합 시 영향 범위 확인 필요.
4. **OAS Memory 5-tier 중 어떤 tier에 keeper bank를 매핑하는가?** Episodic vs Long_term.

## Risk

| Risk | Mitigation |
|------|------------|
| Phase 1B auto-save로 memory.jsonl이 빠르게 커짐 | Phase 4에서 compaction 연결 |
| Phase 3 rename으로 기존 데이터 유실 | migration shim + 부팅 시 자동 rename |
| Checkpoint messages 복원 수정 시 regression | 기존 unified turn 테스트 확인 |

## Execution Order

```
Phase 1A (checkpoint 검증) → 1B (auto-save) → 1C (seed 해제)
  → Phase 2A (passive GC)
    → Phase 3A/3B/3C (naming)
      → Phase 4 (dead code)
```

Phase 1A가 가장 중요하다. checkpoint에서 messages가 실제로 복원되는지 여부가 전체 설계를 좌우한다.
