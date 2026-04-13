# RFC-MASC-001: Keeper Checkpoint Boundary Migration

**Status**: Draft
**Date**: 2026-04-13
**Scope**: `lib/keeper/`, `lib/board_core_payload.ml`, `lib/tool_board.ml`, `docs/OAS-MASC-BOUNDARY.md`
**One sentence**: keeper `working_context` 중복 래퍼를 제거하고 `[STATE]...[/STATE]` text marker를 OAS Checkpoint 구조체로 치환하여, MASC-OAS 경계 violation의 P1(runtime state 이중 소유)과 P2(text marker 누출)를 해소한다.

**Implementation**: 이 RFC의 구현은 **독립 세션/PR로 완전 격리**한다. 다른 RFC와 코드 공유 없음.

## Related Documents

- `docs/OAS-MASC-BOUNDARY.md` — violation 목록: P1(working_context 이중 소유), P2([STATE] text marker 누출)
- `lib/keeper/keeper_context_core.ml` — `working_context` 타입, checkpoint 생성/복원
- `lib/keeper/keeper_types.ml` — `working_context = { system_prompt; messages; max_tokens; context }`
- `lib/board_core_payload.ml` (lines 8-39) — `[STATE]...[/STATE]` 블록 추출
- `lib/tool_board.ml` (lines 14-41) — `strip_state_blocks_text`
- OAS `lib/checkpoint.ml` — Checkpoint.t (v4, 23+ fields), delta operations
- OAS `lib/agent/agent.mli` — `Agent.resume`, `Agent.checkpoint`
- `feedback_context-identity-on-resume.md` — Agent.resume에 shared_context 전달 필수
- `feedback_masc-must-use-oas-agent-run.md` — 에이전트 생명주기 자체 재구현 금지
- `feedback_no-lifecycle-invasion-from-masc.md` — OAS lifecycle/retry/budget/state machine 재구현 금지
- `feedback_use-oas-context-injector.md` — OAS context_injector 파이프라인 사용 필수

## Problem Statement

### P1: working_context 이중 소유 (Boundary Violation)

MASC keeper는 OAS `Context.t`와 `Checkpoint.t`를 직접 사용하면서도, **자체 `working_context` 래퍼**로 이를 감싸고 있다:

```ocaml
type working_context = {
  system_prompt : string;         (* OAS Context.t에도 존재 *)
  messages : Agent_sdk.Types.message list; (* OAS Checkpoint.t에도 존재 *)
  max_tokens : int;               (* OAS agent_config에도 존재 *)
  context : Agent_sdk.Context.t;  (* OAS의 것을 그대로 보유 *)
}
```

이 래퍼가 14개 파일(35곳)에서 참조된다. 문제:

1. **상태 불일치**: `working_context.messages`와 `Checkpoint.t.messages`가 동기화되지 않을 수 있다. `sync_oas_context`를 호출해야 하지만 호출 누락 시 silent drift.
2. **OAS API 회피**: `working_context.system_prompt`를 직접 수정하면 OAS hook chain이 bypass됨.
3. **Checkpoint 이중 직렬화**: keeper가 자체 checkpoint를 만들면서 OAS checkpoint도 별도로 생성. 디스크에 동일 데이터가 두 번 저장.

### P2: [STATE] Text Marker 누출

keeper는 turn 간 continuity를 위해 `[STATE]...[/STATE]` 텍스트 블록을 LLM 응답에 삽입/추출한다:

```
[STATE]
keeper_phase: working
current_task: PK-12345
memory_summary: ...
[/STATE]
```

이 marker가 12개 파일(35곳)에 분포:

| 파일 | 용도 |
|------|------|
| `board_core_payload.ml` | board post에서 [STATE] 추출 후 metadata 저장 |
| `keeper_context_core.ml` | checkpoint 패칭 시 [STATE] 블록 삽입 |
| `keeper_agent_run.ml` | [STATE] 합성 + checkpoint 패칭 |
| `keeper_unified_prompt.ml` | prompt 구성 시 [STATE] 규칙 명시 |
| `keeper_turn.ml` | output guard에서 [STATE] 규칙 |
| `keeper_text_processing.ml` | 블록 추출 헬퍼 |
| `tool_board.ml` | board 저장 전 [STATE] strip |
| `keeper_exec_memory.ml` | [STATE] 블록 핸들링 |
| `keeper_handoff_delta.ml` | 핸드오프 시 [STATE] 스냅샷 문서 |
| `keeper_memory_policy.ml` | 정책 마커 |
| `keeper_prompt.ml` | prompt emission 규칙 |
| `keeper_schema.ml` | 스키마 문서 |

문제:

1. **LLM context 오염**: [STATE] 블록이 LLM에게 보이면 LLM이 이를 모방하거나 조작할 수 있다.
2. **Board 데이터 오염**: strip하지 않으면 board post에 [STATE]가 노출.
3. **구조화되지 않은 데이터**: 텍스트 파싱에 의존하므로 포맷 변경 시 파서 깨짐. OAS Checkpoint의 structured field로 대체하면 타입 안전.

## Design

### Principle: OAS Checkpoint is the Single Source of Truth

keeper의 turn-to-turn state는 **OAS `Checkpoint.t`의 구조화된 필드에만** 저장한다. `working_context` 래퍼와 `[STATE]` 텍스트는 제거한다.

### Part A: working_context 제거

```
[현재]
keeper_context_core.ml
  └── working_context { system_prompt, messages, max_tokens, context }
        ↕ sync_oas_context()
        OAS Context.t / Checkpoint.t

[목표]
keeper가 OAS Checkpoint.t / Context.t를 직접 사용
  - system_prompt → Agent.config.system_prompt
  - messages → Checkpoint.t.messages
  - max_tokens → Agent.config.max_tokens
  - context → Context.t (직접 참조)
```

Migration:
1. `working_context` 타입을 thin wrapper로 축소: `{ checkpoint: Checkpoint.t; context: Context.t }`
2. 14개 파일에서 `wc.system_prompt` → `Checkpoint.system_prompt wc.checkpoint` 등으로 전환
3. 최종적으로 thin wrapper도 제거하고 직접 참조

### Part B: [STATE] → Checkpoint.working_context (structured)

OAS `Checkpoint.t`에는 이미 `working_context: Yojson.Safe.t` 필드가 있다 (line 38). 현재 keeper가 이 필드에 텍스트 블록을 저장하는 대신, **structured JSON**을 저장한다:

```ocaml
(* 현재: text marker *)
"[STATE]\nkeeper_phase: working\ncurrent_task: PK-12345\n[/STATE]"

(* 목표: structured JSON in Checkpoint.working_context *)
{
  "keeper_phase": "working",
  "current_task": "PK-12345",
  "memory_summary_hash": "abc123",
  "continuity_hints": ["last_tool: git_commit", "pending: review"]
}
```

이렇게 하면:
- LLM에게 [STATE] 텍스트가 보이지 않음
- 타입 안전한 파싱 (JSON schema)
- Board post에서 strip 불필요 (텍스트가 아니므로)

### Part C: Board Payload Migration

`board_core_payload.ml`의 [STATE] 추출 로직:

```ocaml
(* 현재: 텍스트에서 [STATE] 블록을 regex로 추출 *)
let extract_state_block text = ...

(* 목표: Checkpoint.working_context에서 직접 읽기 *)
let extract_state checkpoint =
  checkpoint.Checkpoint.working_context
  |> Option.bind (fun wc -> Yojson.Safe.Util.member "keeper_phase" wc)
```

### Part D: Prompt 규칙 변경

`keeper_unified_prompt.ml`에서 "[STATE] 블록으로 상태를 보고하세요" 규칙을 제거하고, 대신 structured tool call이나 OAS hook을 통해 상태를 수집한다.

LLM이 자유텍스트로 상태를 보고하는 것 자체를 폐지하고, keeper의 상태는 **코드 로직으로만** 결정한다 (deterministic boundary).

**주의**: 현재 11-state lifecycle의 일부 전이가 `[STATE]` 블록 내용에 의존하는지 Phase 1 전에 반드시 확인해야 한다. 만약 LLM이 `[STATE]` 블록으로 `keeper_phase`를 보고하고 이것이 state transition trigger로 사용된다면, 해당 전이 경로를 코드 기반(tool call result, turn outcome, 외부 이벤트)으로 먼저 전환해야 한다. 이 경우 Phase 0(전이 경로 감사)을 추가한다.

## Verification

### 완료 기준

```bash
# 1. [STATE] marker 완전 제거
rg '\[STATE\]' lib/ | wc -l
# Expected: 0

# 2. working_context 래퍼 제거 (thin wrapper 이후 최종)
rg 'type working_context' lib/keeper/ | wc -l
# Expected: 0

# 3. Checkpoint.working_context structured 사용 확인
rg 'working_context.*Yojson\|working_context.*json' lib/keeper/ | wc -l
# Expected: >= 3

# 4. OAS-MASC-BOUNDARY.md P1, P2 해소
rg 'VIOLATION\|Partial complete.*working_context\|text marker' docs/OAS-MASC-BOUNDARY.md
# Expected: "Resolved" 또는 해당 항목 제거

# 5. Keeper resume 후 identity 일관성
# Integration test: checkpoint save → resume → session_id equality
```

### 테스트

- **Checkpoint round-trip**: structured working_context를 checkpoint에 저장 → resume → 동일 값 복원
- **Board 클린**: board post에 [STATE] 잔재 없음 (기존 strip 로직 제거 후에도)
- **LLM context 클린**: LLM에게 전달되는 messages에 [STATE] 없음
- **Regression**: 기존 keeper 시나리오에서 turn continuity 동등성
- **OAS identity**: `Agent.resume` 후 `checkpoint.session_id` identity equality (`feedback_context-identity-on-resume.md`)

## Implementation Phases

**모든 Phase는 독립 세션에서 수행. `keeper_agent_run.ml` 수정이 RFC-MASC-004와 겹치므로 merge 순서 조율 필요.**

### Phase 0: 전이 경로 감사 (코드 아님, 1일)
- `rg 'keeper_phase\|state.*transition\|[STATE].*phase' lib/keeper/` 전수 확인
- 11-state lifecycle 중 [STATE] 텍스트에 의존하는 전이 경로 목록 작성
- 의존하는 경로가 있으면 code-based trigger 전환 방안 추가 (Phase 1 전제 조건)

### Phase 1: Structured working_context (1 PR)
- Checkpoint.working_context에 structured JSON 저장하는 경로 추가
- [STATE] 텍스트 → JSON 변환 함수
- 기존 [STATE] 경로와 병행 (feature flag `MASC_STRUCTURED_STATE=true`)

### Phase 2: [STATE] 제거 — prompt/text_processing (1 PR)
- `keeper_unified_prompt.ml`에서 [STATE] 규칙 제거
- `keeper_text_processing.ml`에서 블록 추출 헬퍼 deprecate
- `keeper_turn.ml` output guard 규칙 변경

### Phase 3: [STATE] 제거 — board/context (1 PR)
- `board_core_payload.ml` [STATE] 추출 → Checkpoint.working_context 직접 읽기
- `tool_board.ml` `strip_state_blocks_text` 제거
- `keeper_context_core.ml` [STATE] 패칭 제거

### Phase 4: working_context 래퍼 축소 (1 PR)
- `working_context` → thin wrapper `{ checkpoint; context }`
- 14개 파일에서 접근 패턴 변경
- `sync_oas_context` 제거 (직접 참조이므로 sync 불필요)

### Phase 5: Thin Wrapper 제거 + 정리 (1 PR)
- `working_context` 타입 자체 삭제
- Checkpoint.t / Context.t 직접 사용
- `docs/OAS-MASC-BOUNDARY.md` P1, P2 "Resolved" 업데이트
- Feature flag 제거

## Risks

| Risk | Mitigation |
|------|------------|
| 14개 파일 동시 수정으로 blast radius 큼 | 5 Phase로 분할. 각 Phase는 1 PR, 독립 테스트 |
| [STATE] 제거 후 keeper continuity 품질 저하 | Phase 1에서 structured JSON이 [STATE]와 동등한 정보를 담는지 검증 후 Phase 2 진행 |
| OAS Checkpoint.working_context 필드가 변경되면 | OAS Issue #484 Epic과 조율. Checkpoint v4 → v5 migration 필요 시 같이 처리 |
| Board 기존 데이터에 [STATE]가 남아있음 | 읽기 시 [STATE] 텍스트와 structured JSON 둘 다 파싱 (하위호환) |
| LLM이 [STATE] 없이 상태를 유지하지 못함 | 상태를 LLM에게 의존하지 않는 설계 (deterministic boundary). keeper 코드가 상태 관리 |
| [STATE] 제거 시 11-state lifecycle 전이가 깨짐 | Phase 0에서 전이 경로 감사. LLM 텍스트 기반 전이가 있으면 code-based trigger로 먼저 전환 |
| Concurrent keeper가 같은 Checkpoint.working_context에 쓰면 last-writer-wins | Checkpoint는 session 단위로 격리(session_id별 파일). 동일 session에 복수 keeper가 쓰는 경우는 MASC task claim CAS로 방지. 추가 보호: checkpoint write 시 base_hash 검증(OAS delta protocol) |
| Phase 1 dual-source (텍스트+JSON) 충돌 | Feature flag ON 시 structured JSON이 primary, [STATE] 텍스트는 read-only fallback. 쓰기는 JSON만 |

## Scope Exclusion

- Memory bridge hook-first (RFC-MASC-004 범위)
- OAS Checkpoint 타입 변경 (OAS 측 변경은 최소화, `working_context: Yojson.Safe.t` 이미 존재)
- Team-session bridge fidelity (OAS-MASC-BOUNDARY P3, 별도 RFC)
- Dashboard eval 표출 (RFC-MASC-005 범위)
- Keeper 11-state lifecycle 변경 (이 RFC는 state 저장 방식만 변경, lifecycle 자체는 건드리지 않음)
