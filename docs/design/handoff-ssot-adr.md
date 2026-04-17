---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_memory_policy.ml
  - lib/keeper/keeper_agent_run.ml
  - lib/drift_guard.ml
---

# ADR: Handoff SSOT (D-0)

**Status**: Proposed
**Date**: 2026-03-30
**Refs**: masc-mcp#3825 (Delta-Context Epic), P2-2 (Handoff delta entries)

## Context

Keeper handoff 정보가 3개 경로에 분산 저장되어 있다.
Delta entry 포맷(P2-2)을 도입하려면 "어느 것이 SSOT인가"를 먼저 결정해야 한다.

## 경로 비교

### Path 1: `keeper_state_snapshot`

| 항목 | 값 |
|------|---|
| **정의** | `keeper_memory_policy.ml:282-289` |
| **타입** | OCaml record: `{ goal; progress; next_items; decisions; open_questions; constraints }` |
| **포맷** | Typed (6 fields, `string option` / `string list`) |
| **저장** | In-memory (message history 내 `[STATE]` 블록에서 파싱) |
| **생산자** | LLM이 `[STATE]...[/STATE]` 블록 출력 → `parse_state_snapshot_from_reply` 파싱 |
| **소비자** | `latest_state_snapshot_from_messages` → continuity prompt 구성, memory bank write |
| **내구성** | 세션 내 checkpoint에 보존. 세션 종료 시 checkpoint 파일로 persist |
| **범위** | **intra-session**: 턴 간 상태 추적 |
| **검증** | `Drift_guard.verify_handoff` — jaccard/cosine similarity로 drift 탐지 |

### Path 2: handoff skill (retrospective + session-state)

| 항목 | 값 |
|------|---|
| **정의** | `~/me/skills/handoff/SKILL.md` (me repo, not masc-mcp) |
| **포맷** | Semi-structured markdown (template 기반, 자유 텍스트) |
| **저장** | PostgreSQL (`sb retro save`) + `.claude/session-state.md` |
| **생산자** | Claude Code 세션 종료 시 `/handoff` skill 실행 |
| **소비자** | 다음 세션에서 `.claude/session-state.md` 읽기, retrospective 검색 |
| **내구성** | PG: 영구. session-state.md: 파일 시스템 (덮어쓰기) |
| **범위** | **inter-session**: 세션 간 인계 |
| **내용** | Active work (branch, PR, CI status), blockers, recently completed, learnings, next steps |

### Path 3: local memory handoff files

| 항목 | 값 |
|------|---|
| **정의** | `~/me/memory/handoff-*.md` (me repo, auto-memory) |
| **포맷** | Freetext markdown (frontmatter 포함) |
| **저장** | 파일 시스템 (auto-memory 디렉토리) |
| **생산자** | Claude Code auto-memory 시스템 (MEMORY.md index 참조) |
| **소비자** | 다음 세션 시작 시 MEMORY.md → 관련 memory 로드 |
| **내구성** | 영구 (수동 삭제 전까지) |
| **범위** | **cross-conversation**: 장기 컨텍스트 보존 |
| **내용** | 프로젝트 상태 snapshot, 미완료 작업, 다음 단계 |

## 분석

### 경로별 역할이 다르다

3개 경로는 서로 다른 시간 척도의 컨텍스트를 담당한다:

| 시간 척도 | 경로 | 용도 |
|----------|------|------|
| **턴 단위** (초~분) | keeper_state_snapshot | LLM이 매 턴 출력하는 작업 상태 |
| **세션 단위** (분~시간) | handoff skill | 세션 종료 시 인계 문서 |
| **영구** (일~주) | local memory | 장기 프로젝트 맥락 |

### Delta entry의 대상 시간 척도

P2-2의 "handoff delta entries"는 **세션 간 재개** 시 변경분만 로드하는 것이 목적이다.
따라서 대상 시간 척도는 **세션 단위**이고, Path 2 (handoff skill)의 영역이다.

### Path 1은 보조 데이터 원천

`keeper_state_snapshot`은 delta entry의 **입력 데이터**로 사용될 수 있다:
- 마지막 턴의 `[STATE]` 블록에서 goal/progress/decisions를 추출
- 이를 handoff delta entry의 structured 필드로 변환

하지만 SSOT는 아니다 — keeper_state_snapshot은 LLM 비결정론적 출력에 의존하고,
세션이 끝나면 checkpoint 안에 매몰되어 독립적으로 접근이 어렵다.

### Path 3은 관심사가 다르다

local memory는 Claude Code auto-memory 시스템의 영역이다.
masc-mcp가 직접 관리하는 것이 아니며, 포맷도 user-facing markdown이다.
Delta entry 시스템이 이를 직접 소비하는 것은 경계 위반이다.

## Decision

**Handoff skill (Path 2)을 SSOT로 결정한다.**

근거:
1. **시간 척도 일치**: delta entry는 세션 간 재개 → handoff skill이 정확히 이 경계를 담당
2. **저장소 적절**: PostgreSQL에 영구 저장 → 쿼리/정렬/필터 가능
3. **기존 인프라 활용**: `sb retro save` + retrospective 테이블이 이미 존재
4. **검증 통합**: `Drift_guard.verify_handoff`가 handoff 텍스트 drift를 탐지하는 기존 메커니즘

### keeper_state_snapshot과의 관계

keeper_state_snapshot은 SSOT가 아니라 **delta entry의 입력 데이터 원천** 중 하나로 위치한다:

```
keeper_state_snapshot (턴 상태)  ──extract──> delta entry fields
git diff/log (코드 변경)        ──extract──> evidence_refs, updated_paths
session metadata (trace_id 등)  ──extract──> checkpoint reference
                                              │
                                              v
                                   handoff skill (SSOT)
                                   ├─ PostgreSQL retrospective
                                   └─ .claude/session-state.md
```

### Migration path

1. handoff skill의 retrospective 템플릿에 structured delta fields 추가:
   - `since_checkpoint_id`: delta 기준점
   - `evidence_refs`: 변경 근거 (commit, issue, tool output)
   - `updated_paths`: 변경된 파일/모듈
   - `open_loops`: 미완료 작업
   - `decision_ids`: 이 세션에서 내린 결정
2. `keeper_state_snapshot`에서 자동 추출하여 위 필드 채우기
3. local memory handoff files는 변경하지 않음 (다른 관심사)

## Consequences

### 긍정적
- Delta entry 포맷의 단일 저장 위치 확정
- 기존 PostgreSQL 인프라 재사용
- keeper_state_snapshot의 typed 필드를 활용한 구조화된 delta 생성

### 부정적 / 리스크
- handoff skill이 `~/me` repo에 정의됨 → masc-mcp에서 직접 수정 불가, 인터페이스 합의 필요
- PostgreSQL 의존성 → filesystem-first 원칙(feedback memory)과 긴장
  - 완화: filesystem fallback으로 `session-state.md`에도 delta fields 포함

### 범위 밖
- keeper_state_snapshot 타입 자체의 변경 (별도 작업)
- local memory 포맷 변경 (관심사 분리)
- cross-run temporal delta (D-2 의존, 별도 작업)
