# MASC Mitosis

**Legacy terminology note**: `mitosis` and `DNA` are older internal labels for a two-phase handoff flow. In new user-facing docs, prefer `handoff` and `capsule` where possible.

## Overview

Mitosis는 컨텍스트 한계에 도달하기 전에 handoff를 준비하고 실행하는 2단계 패턴입니다.
코드와 테스트에는 기존 용어가 남아 있지만, 문서 해석은 handoff 중심으로 보는 편이 정확합니다.

```
Single-stage handoff: wait until the limit is near, then transfer
Two-phase handoff:   prepare early, then transfer with buffer
```

## 2-Phase Handoff Pattern

### Phase 1: Prepare (50% threshold)
- DNA 추출 (현재 컨텍스트 압축)
- 상태: `Idle` → `ReadyForHandoff`
- 작업 계속 가능

### Phase 2: Handoff (80% threshold)
- 새 에이전트에게 DNA 전달
- 현재 에이전트 graceful shutdown
- 상태: `Prepared` → `Dividing` → `Apoptotic`

```
Timeline:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  0%      50%              80%              100%
   │       │                │                 │
   │  ┌────▼────┐      ┌────▼────┐           │
   │  │ PREPARE │      │ HANDOFF │           │
   │  │ DNA추출 │      │ 새세션  │           │
   │  └─────────┘      └─────────┘           │
   │                                          │
  idle    ready_for_handoff    dividing    (avoided)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## API Reference

### MCP Tools

#### `masc_mitosis_check`
컨텍스트 비율 기반 분열 상태 확인

```json
{
  "name": "masc_mitosis_check",
  "arguments": {
    "context_ratio": 0.5
  }
}
```

**Response:**
```json
{
  "should_divide": false,
  "should_prepare": true,
  "should_handoff": false,
  "current_phase": "idle",
  "prepare_threshold": 0.5,
  "handoff_threshold": 0.8
}
```

#### `masc_mitosis_prepare`
DNA 추출 및 핸드오프 준비

```json
{
  "name": "masc_mitosis_prepare",
  "arguments": {
    "context_ratio": 0.5,
    "full_context": "...",
    "since_len": 0
  }
}
```

**Response:**
```json
{
  "prepared": true,
  "phase": "ready_for_handoff",
  "dna": "compressed context...",
  "dna_length": 195
}
```

#### `masc_mitosis_handoff` ⭐ (핵심 도구)
2-Phase 자동 실행 - context_ratio만 주면 알아서 처리

```json
{
  "name": "masc_mitosis_handoff",
  "arguments": {
    "context_ratio": 0.5,
    "full_context": "현재까지의 작업 요약...",
    "target_agent": "claude"
  }
}
```

**Response (< 50%):**
```json
{
  "action": "none",
  "context_ratio": 0.3,
  "message": "Context ratio below prepare threshold. Continue working."
}
```

**Response (50-80%):**
```json
{
  "action": "prepared",
  "context_ratio": 0.6,
  "message": "DNA extracted and ready. Continue working until 80% threshold.",
  "phase": "ready_for_handoff",
  "dna_length": 1234
}
```

**Response (> 80%):**
```json
{
  "action": "handoff",
  "success": true,
  "context_ratio": 0.85,
  "message": "Handoff complete! Successor agent spawned.",
  "target_agent": "claude",
  "previous_generation": 0,
  "new_generation": 1,
  "elapsed_ms": 2500
}
```

## Configuration

```ocaml
type mitosis_config = {
  prepare_threshold: float;      (* 0.5 - DNA 준비 시점 *)
  handoff_threshold: float;      (* 0.8 - 핸드오프 시점 *)
  min_context_for_delta: int;    (* 1000 - 최소 컨텍스트 길이 *)
  min_delta_len: int;            (* 100 - 노이즈 필터 *)
  dna_compression_ratio: float;  (* 0.3 - 압축률 *)
}
```

## Quality Controls

### 1. Short Session Exception
- `min_context_for_delta = 1000`
- 짧은 세션은 DNA 추출 스킵

### 2. Delta Noise Filter
- `min_delta_len = 100`
- 너무 작은 변경사항 필터링

### 3. Line-based Deduplication
- `deduplicate_lines` 함수
- 중복 라인 제거 (O(n log n) StringSet)

## Internal State Names

아래 이름은 코드에 남아 있는 내부 상태 이름입니다. 일반 설명에서는 `lifecycle` 또는 `handoff state`로 읽으면 됩니다.

| State | Description |
|-------|-------------|
| `Stem` | 대기 상태, 활성화 준비 |
| `Active` | 작업 중 |
| `Prepared` | DNA 추출 완료, 핸드오프 대기 |
| `Dividing` | 핸드오프 진행 중 |
| `Apoptotic` | Graceful shutdown |

## Usage Example

```bash
# 1. Check at 50%
curl -X POST http://127.0.0.1:8935/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"masc_mitosis_check",
                 "arguments":{"context_ratio":0.5}}}'

# 2. Prepare DNA
curl -X POST http://127.0.0.1:8935/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
       "params":{"name":"masc_mitosis_prepare",
                 "arguments":{"context_ratio":0.5,
                              "full_context":"...",
                              "since_len":0}}}'

# 3. Check at 80% → Handoff
curl -X POST http://127.0.0.1:8935/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call",
       "params":{"name":"masc_mitosis_check",
                 "arguments":{"context_ratio":0.8}}}'
```

## Test Coverage

```
test_mitosis.ml: 22 tests
├── safe_sub: 6 edge cases
├── deduplicate_lines: 4 scenarios
├── compress_to_dna: 2 ratio tests
├── 2-phase mitosis: 5 lifecycle tests
├── extract_delta: 3 quality filters
└── state/phase: 2 conversions
```

## Design Decisions

### Why 2-Phase?
- **Problem**: 단일 시점 핸드오프는 작업 중단 발생
- **Solution**: 50%에서 미리 준비, 80%에서 실행
- **Benefit**: 30% 버퍼 동안 계속 작업 가능

### Why StringSet for Deduplication?
- **Before**: `List.mem` O(n) → O(n²) total
- **After**: `StringSet.mem` O(log n) → O(n log n) total
- **Benefit**: 대용량 컨텍스트에서 성능 보장

### Why safe_sub?
- **Problem**: `String.sub` raises exception on invalid range
- **Solution**: `safe_sub` returns empty string
- **Benefit**: 예외 없는 안전한 문자열 처리

## Future Work

- [x] Handoff 실행 구현 (`masc_mitosis_handoff`) - ✅ 2026-02-01
- [ ] 멀티 에이전트 릴레이
- [ ] DNA 압축 알고리즘 개선
- [ ] 메트릭스 수집 (handoff 횟수, 성공률)

## Changelog

### 2026-02-01
- `masc_mitosis_handoff` MCP 도구 추가 (tool_mitosis.ml)
- 2-phase 자동 실행: context_ratio 기반으로 prepare/handoff 자동 판단
- target_agent 파라미터로 successor 에이전트 선택 가능 (claude/gemini/codex/default)
