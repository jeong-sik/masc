# RFC-0208: Typed Domain Classification — String Convention → Variant

- Status: Draft
- Date: 2026-06-01
- Related: CLAUDE.md §워크어라운드 거부 기준 시그니처 #2 (String/Substring 분류기 보강), PR #19747 (Category A codec 수정)

## 0. 동기

masc `lib/` 전체 `String.starts_with` / `String.ends_with` 사용 100+ 건 중, **도메인 분류를 string convention에 의존하는 3건**을 식별했다 (PR #19747 audit). 이들은 typed variant가 가능함에도 불구하고, agent/human이 작성하는 텍스트의 prefix/suffix로 비즈니스 로직을 판정한다.

새 variant 추가 시 컴파일러가 누락을 잡지 못하고, convention 변경이 조용히 break된다. CLAUDE.md §워크어라운드 시그니처 #2: "컴파일러가 reader 누락을 못 잡음. 새 prefix가 자유롭게 추가됨."

## 1. 대상 3건

| Phase | Module | Current pattern | Consumer 수 |
|-------|--------|-----------------|-------------|
| P1 | `workspace_task_cache_invariant` | broadcast content가 `"[cache_invalidated]"`로 시작하면 signal 분류 | broadcast pipeline |
| P2 | `verification_protocol` | deliverable 텍스트가 `"completed"` / `"<task_id> completed"`로 시작하면 done 판정 | 3 (verification_protocol, tool_workspace ×2) |
| P3 | `workspace_task_receipts` | agent 이름에서 `"keeper-"` prefix + `"-agent"` suffix로 keeper identity 역유추 | 15+ |

## 2. Phase 1: Typed Broadcast Message Types

### 2.1 현재 문제

`workspace_task_cache_invariant.ml:159,173`:
```ocaml
if string_starts_with ~prefix:"[cache_invalidated]" (String.trim content)
```

broadcast `content` 필드(자유 텍스트)의 prefix로 메시지 종류를 분류. `content`에 `"[cache_invalidated]"`가 우연히 포함되면 false positive.

`workspace_broadcast.ml:28`에 이미 typed variant가 있다:
```ocaml
type broadcast_kind = Cache_invalidated | ...
```

하지만 이 kind는 broadcast 메타데이터로 저장되지 않고, content 문자열에서 재추출한다.

### 2.2 제안

`broadcast` 레코드에 `kind: broadcast_kind` 필드를 추가하고, content prefix 기반 분류를 kind 필드 기반으로 교체.

**Wire format 변경**: JSONL에 `"kind": "cache_invalidated"` 필드 추가. 기존 레코드(`kind` 없음)는 content prefix로 fallback (backward compat).

### 2.3 변경 범위

- `workspace_broadcast.ml`: `broadcast` record에 `kind` field 추가, emit 시 kind 설정
- `workspace_task_cache_invariant.ml`: `starts_with "[cache_invalidated]"` → `kind = Cache_invalidated` 체크
- `workspace_broadcast.ml` JSON codec: `kind` field 직렬화/역직렬화

### 2.4 Migration

- Old records (no `kind` field): content prefix fallback 유지 (READ path only)
- New records: `kind` field로 분류 (WRITE + READ path)
- 30일 후 fallback 제거 검토

## 3. Phase 2: Typed Completion Status

### 3.1 현재 문제

`verification_protocol.ml:38-45` / `workspace_status_rendering.ml:143-152`:
```ocaml
let deliverable_claims_completion ~task_id deliverable =
  ... && (String.starts_with ~prefix:"completed" normalized
       || String.starts_with ~prefix:(task_id ^ " completed") normalized)
```

deliverable 텍스트(자유 텍스트)의 prefix로 task 완료 여부 판정. 동일 함수가 두 파일에 중복 정의 (DRY 위반).

### 3.2 제안

`planning` context에 typed completion indicator 추가:

```ocaml
type completion_indication =
  | Explicit_completion of { summary: string }
  | Implicit_in_progress
  | Not_applicable
```

Agent는 deliverable 텍스트와 함께 structured `completion_indication`을 작성. `deliverable_claims_completion`은 이 필드를 우선 확인하고, 필드가 없으면 기존 text convention으로 fallback.

### 3.3 변경 범위

- `planning_eio.ml` 또는 `planning` context type: `completion_indication` field 추가
- `verification_protocol.ml`: `deliverable_claims_completion`이 structured field 우선 확인
- `workspace_status_rendering.ml`: 중복 정의 제거, `verification_protocol`의 것을 사용
- `tool_workspace.ml`: 2 consumer 업데이트
- Agent convention guide: 새 필드 사용 안내

### 3.4 Migration

- Old plans (no `completion_indication`): text prefix fallback 유지
- Agent SDK update: 새 필드 emit
- 60일 후 fallback을 로깅-only로 전환 (경고 후 제거)

## 4. Phase 3: Typed Keeper Identity

### 4.1 현재 문제

`workspace_task_receipts.ml:38-42`:
```ocaml
if String.starts_with ~prefix:"keeper-" trimmed
   && String.ends_with ~suffix:"-agent" trimmed
then Some (String.sub trimmed 7 (String.length trimmed - 13))
```

Agent 이름에서 `"keeper-"` prefix와 `"-agent"` suffix를 strip해서 keeper 이름 역유추. naming convention이 business logic이다.

15+ consumer가 `Keeper_identity.canonical_keeper_name_from_agent_name`을 호출:
- `task_keeper_backend.ml`, `workspace_identity_backend.ml`
- `mcp_server_eio_execute.ml`, `runtime_oas_runner.ml`
- `agent_reputation.ml`, `server_utils.ml`
- `dashboard_goals_types_health.ml`, `server_dashboard_http_delete_actions.ml`
- `mcp_server_eio_caller_identity.ml`

### 4.2 제안

Agent 등록 시 keeper 이름을 **명시적으로 저장**:

```ocaml
(* Agent record에 이미 keeper_name field가 있음 *)
type agent_meta = {
  ...
  keeper_name: string option;  (* 이미 존재 *)
  ...
}
```

`keeper_name_from_agent_name`의 string convention fallback을 `agent_meta.keeper_name` 우선 조회로 교체.

### 4.3 변경 범위

- `keeper_identity.ml`: `canonical_keeper_name_from_agent_name`이 agent record의 `keeper_name` field를 우선 확인
- 15+ consumer: API 변경 없음 (같은 함수, 내부 로직만 변경)
- `workspace_task_receipts.ml`: string convention 추출을 agent record 조회로 교체
- Agent boot protocol: `keeper_name`을 반드시 agent record에 기록

### 4.4 Migration

- Agent boot 시 `keeper_name` 자동 설정 (기존 naming convention에서 추출)
- Old agents (no `keeper_name` in record): string convention fallback
- 모든 agent 재시작 후 fallback 제거 검토

## 5. 공통 원칙

1. **Wire format backward compat**: 모든 phase는 READ path에서 기존 format fallback을 유지한다
2. **Write path 먼저**: 새 필드를 write하는 것을 먼저 배포하고, read 전환은 검증 후
3. **Fallback 제거 타임라인**: 각 phase별로 migration 완료 후 fallback을 warning-only로 전환, 다음 release에서 제거
4. **DRY**: Phase 2에서 `deliverable_claims_completion`의 중복 정의를 제거한다

## 6. 순서 의존성

```
P1 (broadcast kind) ──→ 독립, 가장 작은 범위
P2 (completion status) ──→ 독립, planning context 변경
P3 (keeper identity) ──→ 독립, 15+ consumer, 가장 넓은 영향
```

세 phase는 서로 독립적이다. P1부터 순차 진행.

## 7. 비대상 (의도적 제외)

PR #19747 audit에서 다음은 anti-pattern이 아닌 것으로 판정됨:

- `runtime_evidence.ml`: typed primary path + WORKAROUND fallback (이미 RFC-0071 §3.4.1에서 승인)
- `tool_output.ml`: `Scanf.sscanf` 구조화 파서 + `starts_with`는 wire format guard
- 파일 경로, URL scheme, git config 파싱 등 ~90건: 외부 포맷 protocol detection
