---
rfc: "0279"
title: "Typed completion-contract reason — structured backend emit replacing colon-composite string"
status: Draft
created: 2026-06-22
updated: 2026-06-22
author: vincent
supersedes: []
superseded_by: null
related: ["0150", "0140", "0089", "0062", "0135", "0174"]
implementation_prs: []
---

# RFC-0279: Typed completion-contract reason

## §0 한 줄 요약

backend가 `"completion_contract_result:" ^ reason` 콜론 합성 문자열을 만들어 3개 reason wire field(`runtime_attention.reason`, `attention_reason`, `disposition_reason`)에 실어 보내고, dashboard가 이를 닫힌 union으로 파싱하지 않고 raw 또는 `replace(/[:._-]+/g,' ')` prettifier로 표출한다. 콜론 합성을 backend 측에서 **전용 typed 필드 `completion_contract`(닫힌 result union)**로 구조화 emit하고, reason 문자열 필드에서 composite를 제거한다. GitHub #22059 + #22062의 단일 근본 해결.

## §1 문제 (grounded)

### §1.1 두 누출, 하나의 근본 결함

- **#22059 (overview)**: `dashboard/src/components/overview/overview.ts:93,99,115,121` 가 `attention ?? blockerLabel` 으로 raw `attention_reason`(open string)을 typed `blockerLabel`보다 **우선** 표출 → `overview.ts:1082` 에서 DOM에 verbatim 렌더.
- **#22062 (composite colon)**: `runtime_attention.reason` (FE schema `dashboard/src/api/schemas/keeper-composite.ts:170` `reason: nullable(string())`) 가 `lib/server/server_dashboard_http_composite_claims.ml:544` 에서 `cra_reason` 로부터 나오며, `:480-501` 에서 `"completion_contract_result:" ^ reason` (`:320,:344,:355` 에서 합성) 일 수 있다. FE 소비자 `keeper-blocker-reason.ts:60` (`deriveBlockerReason`) 와 `keeper-operational-state.ts:354` (`deriveKeeperDisplayReason`) 는 provenance만 태깅하고 **humanize하지 않아** 콜론 문자열이 DOM에 도달. `stop-cause.ts:10` `humanize()` 를 통과하면 `replace(/[:._-]+/g,' ')` 로 `"completion contract result passive only"` 가 된다 (CLAUDE.md 워크어라운드 시그니처 #2 — 가짜 humanize).

두 누출의 공통 근본: **닫힌 union으로 파싱하지 않은 open wire string을 렌더하며, typed 라벨이 존재해도 fallback이지 winner가 아니다.**

### §1.2 Entanglement — 같은 composite가 두 경로로 흐름

콜론 합성은 두 producer family에서 생성된다:

1. **`composite_claims.ml`** (`runtime_attention.reason` 경로): `composite_execution_completion_unsatisfied_reason` (`:339`), `composite_execution_budget_unsatisfied_reason` (`:349`), `composite_execution_contract_blocker_reason` (`:309`).
2. **`keeper_runtime_trust_snapshot.ml`** (`attention_reason` / `disposition_reason` 경로): `receipt_contract_attention_reason` (`:109-134`) 가 동일 `"completion_contract_result:" ^ reason` 를 만들어 `:342` 에서 attention 경로로 주입. disposition 경로는 `:79-84`.

`operator_control_snapshot_trust.ml:60,62,64` 가 `disposition_reason` / `operator_disposition_reason` / `attention_reason` 를 그대로 passthrough re-emit → composite가 operator control plane으로도 전파.

→ #22059 와 #22062 는 **분리 불가**. 한 경로만 막으면 다른 경로로 샌다. 단일 RFC가 producer 레벨에서 닫아야 한다.

### §1.3 result value는 이미 닫힌 OCaml variant

콜론 suffix 집합은 세 producer arm에서 닫혀 있다 (match arm 직접 확인):

```
composite_claims.ml:319-320  { surface_mismatch, no_capable_provider }
composite_claims.ml:342-344  { violated, claim_only_after_owned_task, needs_execution_progress, passive_only }
composite_claims.ml:352-355  { unknown, not_dispatched, violated, surface_mismatch, no_capable_provider,
                               claim_only_after_owned_task, needs_execution_progress, passive_only }
keeper_runtime_trust_snapshot.ml:123-133  위 집합의 부분집합
```

합집합 (8) = `{ violated, claim_only_after_owned_task, needs_execution_progress, passive_only, surface_mismatch, no_capable_provider, unknown, not_dispatched }`.

이미 닫힌 variant인데 wire에서 `"prefix:" ^ x` 문자열로 평탄화되어 FE가 타입 정보를 잃는다.

## §2 기존 RFC 관계 (발견·인용)

| RFC | status | 관계 |
|---|---|---|
| **RFC-0150** keeper-attention-signal-typed-envelope | `Implemented` (실측: **미구현**) | `attention_reason`/`next_human_action`/`latest_next_action` 를 typed envelope로 통합 제안. **그러나 코드에 `attention_signal` envelope 부재**(backend 0, FE schema 0), §3 P2가 삭제 명시한 `ATTENTION_PAIR_DUPLICATES`(`alert-strip.ts:174,250`) **여전히 live**. status가 잘못 마킹됨(§7 거버넌스 플래그). §4가 `completion_contract_result`/`disposition`/`stop_cause` 를 **명시적 out-of-scope**로 둠 → 본 RFC가 그 갭을 덮음. |
| **RFC-0140** dashboard-wire-codec-layer | Implemented | 구조화 emit이 올라탈 ATD/codegen wire 인프라. |
| **RFC-0089** (backend string-classifier→typed) | — | Option A의 backend 측 선례 (`String.starts_with` 215+ 사이트 typed 전환). |
| **RFC-0062** typed-tool-result-and-blocker-class | Implemented | `runtime_blocker_class` 닫힌 sum (`keeper-runtime-display.ts:421` `satisfies Record`) — 이미 typed, 재사용. |
| **RFC-0135** dashboard-keeper-operational-ssot | Implemented | dashboard read-side SSOT. |
| **RFC-0174** dashboard-substring-classifier-to-typed | Draft | 같은 정신(FE 분류기→typed)이나 **다른 8 사이트**(reason/composite 미포함). 본 RFC와 비중복. |

**결론**: composite `completion_contract_result` 의 typed contract를 덮는 기존 RFC 없음 → 새 RFC 정당. RFC-0150 attention envelope 부활은 별도 작업(§6 out-of-scope).

## §3 제안 설계

### §3.1 전용 typed 필드 (경계 정확히 구분)

콜론 composite를 reason 문자열에 섞지 않고 **전용 nullable 필드**로 분리:

```ocaml
(* 닫힌 result variant — composite_claims.ml + trust_snapshot 의 SSOT *)
type completion_contract_result =
  | Violated | Claim_only_after_owned_task | Needs_execution_progress
  | Passive_only | Surface_mismatch | No_capable_provider | Unknown | Not_dispatched

(* wire: 콜론 합성 대신 구조화 *)
"completion_contract", `Assoc [ "result", `String (result_to_string r) ]   (* nullable *)
```

- composite를 만들던 producer는 `"completion_contract_result:" ^ reason` 대신 이 전용 필드를 emit.
- `runtime_attention.reason` / `attention_reason` / `disposition_reason` 문자열 필드는 **composite를 더 이상 싣지 않는다** → 각자 닫힌 attention/disposition 토큰(또는 null)만 carry → 필드 동질성 회복.

근거: composite는 reason을 *대체*하지 *추가*하지 않는다(producer 확인 — composite가 곧 전체 `cra_reason` / attention_reason). 따라서 전용 필드 분리가 두 개념을 같은 string 타입에 압축한 결함(CLAUDE.md "Fallback Resolution" root)을 정확히 해소한다.

### §3.2 FE: 닫힌 union + exhaustive 라벨 (humanize SSOT)

신규 `dashboard/src/lib/keeper-reason.ts` (component가 아닌 lib — alert-strip이 component 안에 패턴을 가둔 결함 해소):

```ts
export const COMPLETION_CONTRACT_RESULTS = [
  'violated','claim_only_after_owned_task','needs_execution_progress',
  'passive_only','surface_mismatch','no_capable_provider','unknown','not_dispatched',
] as const
export type CompletionContractResult = typeof COMPLETION_CONTRACT_RESULTS[number]

const COMPLETION_CONTRACT_LABELS: Record<CompletionContractResult, string> = {
  violated: '완료 계약 위반',
  claim_only_after_owned_task: '소유 태스크 이후에만 클레임 가능',
  needs_execution_progress: '실행 진행 필요',
  passive_only: '관찰만 수행됨',
  surface_mismatch: '도구 표면 불일치',
  no_capable_provider: '가용 Provider 없음',
  unknown: '미식별 완료 계약 결과',
  not_dispatched: '미디스패치',
}
```

- `Record<CompletionContractResult,string>` 가 새 backend 토큰 추가 시 **컴파일 에러** 강제(이미 입증된 메커니즘: `alert-strip.ts:75`, `keeper-runtime-display.ts:421`, `runtime-blocker-class.ts:74-77`).
- backend↔FE drift guard: `runtime-blocker-class.ts:74-77` 의 `Exclude<>` extends `never` 패턴을 mirror해 FE union이 OCaml producer 집합과 어긋나면 빌드 실패.
- 동시에 `keeper-detail-alert-strip.ts:62-207` 의 attention/next-action 닫힌 union + 라벨 맵 + parser를 이 모듈로 factor-out(behavior-preserving) → reason humanize의 단일 SSOT.

### §3.3 제거되는 것 (GOAL, 워크어라운드 아님)

- `stop-cause.ts:9-14 humanize()` `replace(/[:._-]+/g,' ')` — reason 경로에서 제거, terminal-reason code 전용으로 축소.
- `overview.ts:92` `blockerClass?.replace(/_/g,' ')` — `keeperRuntimeBlockerLabel(...) ?? <unknown literal>` 로 교체.
- composite가 사라지면 `keeper-blocker-reason.ts` 가 raw로 반환하던 콜론 문자열 소멸.

## §4 Phasing (conveyor-safe, 각 PR 독립 green)

RFC-0150 P0/P1/P2 + RFC-0140 wire-codec phasing 답습.

| Phase | Backend | Dashboard | Cutover |
|-------|---------|-----------|---------|
| **P0** | `completion_contract` 전용 필드 **parallel emit** (콜론 문자열 3필드도 그대로 유지) | 변경 없음 | none |
| **P1** | 변경 없음 | `keeper-reason.ts` 신규(union+라벨+parser+drift guard) + FE schema가 `completion_contract` read, typed 라벨로 humanize; 콜론 문자열은 fallback parse | dashboard가 신규 필드 우선 |
| **P2** | producer가 콜론 합성 중단 — composite 시 reason 문자열 필드는 null, `completion_contract` 만 emit | 콜론 fallback parse 제거 | backend가 legacy 합성 중단 |
| **P3** | — | overview precedence 역전(#22059) + stop-cause prettifier 제거 정리 | cleanup |

P1 은 FE-only(green), P0/P2 는 backend(structured emit/cutover). P0→P1→P2 순서 의존, P3 독립.

**Anti-stale invariant**: P2 cutover 시 FE 콜론 fallback parser와 `stop-cause` reason-path prettifier가 *함께* 삭제되어야 한다(잔존 시 dead workaround).

## §5 Test plan

- **닫힌 union exhaustiveness**: `keeper-reason.test.ts` — `COMPLETION_CONTRACT_RESULTS` 전 멤버가 `COMPLETION_CONTRACT_LABELS` 키를 가짐(런타임 루프) + `Record<Union,string>` 컴파일 타임.
- **drift guard**: `Exclude<BackendCompletionContractResult, CompletionContractResult>` extends `never` (OCaml producer 집합 mirror). 새 backend 토큰 → 빌드 실패.
- **parse table**: structured `{result:'passive_only'}` → `'관찰만 수행됨'`; unknown result → explicit unknown(warn+raw, prettify 금지).
- **회귀(#22062)**: `keeper-composite.test.ts:223` 가 bare `'passive_only'` 단언 — 실제 backend는 prefix 형태(이 픽스처 갭이 #22062 누출 원인). P1에서 structured 필드 케이스로 교정.
- **회귀(#22059)**: overview에서 `attention_reason='runtime_blocked'` → 한국어 라벨, raw 아님.
- **backend**: producer가 structured 필드 emit하고 콜론 문자열 미생성(P2) 단위 테스트.

## §6 Out of scope

- **RFC-0150 attention envelope 부활** — `attention_reason`/`next_human_action`/`latest_next_action` 3필드 통합은 별도. 본 RFC는 composite를 그 필드들에서 *제거*해 부활을 단순화할 뿐.
- `runtime_blocker_summary` — genuinely free-form prose(`keeper_status_bridge.ml:205` verbatim detail + Printf 템플릿). 닫힌 union 금지. precedence(typed `runtime_blocker_class` 우선)만 조정.
- RFC-0174 의 8 FE 분류기 사이트.

## §7 거버넌스 플래그 — RFC-0150 false `Implemented`

RFC-0150 frontmatter `status: Implemented` + `implementation_prs: []` 이나, 핵심 backend cutover(P1/P2) 미수행 — `attention_signal` envelope 부재(backend 0, FE schema 0), 삭제 예정 `ATTENTION_PAIR_DUPLICATES` live. FE 라벨 봉인(PR #16908)만 되고 "Implemented" 마킹된 premature status로 추정.

권고: RFC-0150 을 `Draft`(또는 `Partially-implemented`)로 정정하는 별도 docs 변경. 본 RFC PR 범위 밖이나 추적 필요(메모리 [[reference-masc-env-knob-catalog-drift-merged-to-main-latent]] 류 false-state 패턴).

## §8 Open questions

1. composite 시 reason 문자열 필드를 **null** 로 둘지(권장) vs canonical plain 토큰(예: `runtime_blocked`)으로 둘지 — P2 cutover 정책. null 권장(동질성).
2. `completion_contract` 를 어느 레벨에 nest할지 — `runtime_attention` 안 vs top-level keeper. producer가 양 경로(composite_claims / trust_snapshot)에서 모두 접근 가능한 위치 확정 필요.
3. operator control plane(`operator_control_snapshot_trust.ml`) 소비자가 콜론 문자열을 직접 파싱하는가? cutover 전 `rg` 확인(RFC-gate 영역).
4. external client(다른 dashboard/스크립트)가 콜론 reason을 직접 읽는가? P2 backwards-compat.
