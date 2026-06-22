# RFC-0279 Caller Context

Owner request, 2026-06-22 (dashboard v2 humanize Phase 2):

- 라이브 대시보드가 keeper reason을 raw로 노출하는 문제를 다루던 중, owner(Vincent)가
  "Quick Win 보다 제대로 작업 하거라" 로 명시 — FE 한 군데만 잇는 quick win을 거부하고
  근본 해결을 지시.
- composite 토큰(`completion_contract_result:*`)을 닫힌 타입으로 변환하는 경계 위치를
  AskUserQuestion으로 제시했고, owner가 **Option A (backend 구조화 emit 먼저)** 를 선택.
  문자열 결합(`"prefix:" ^ x`)을 backend에서 제거하는 root contract fix.

근거 (grounding):

- 3개 병렬 에이전트가 backend emit 사이트 / FE 소비자 / 재사용 typed 인프라를 전수 매핑
  (workflow wvc9evgnq). 핵심 발견: composite가 `runtime_attention.reason` 뿐 아니라
  `attention_reason`(trust snapshot `receipt_contract_attention_reason`,
  keeper_runtime_trust_snapshot.ml:109-134) 로도 흘러들어 #22059 와 #22062 가 분리 불가.
- 직접 검증(rg/Read): stop-cause.ts:10 `replace(/[:._-]+/g,' ')` prettifier,
  keeper-composite.test.ts:223 bare `'passive_only'` 픽스처 갭, operator_control_snapshot_trust.ml:60-64
  reason passthrough(RFC-gate 트리거).

설계 제약:

- composite를 reason 문자열에 섞지 않고 **전용 nullable typed 필드 `completion_contract`** 로 분리
  (Parse, don't validate; 두 개념을 같은 string 타입에 압축한 결함 해소).
- FE `keeper-reason.ts` 신규 — 닫힌 `CompletionContractResult` union + `Record<Union,string>`
  exhaustive 라벨 + backend-set drift guard(`Exclude<>` extends `never`, runtime-blocker-class.ts:74-77 mirror).
- conveyor-safe phasing: P0 parallel emit → P1 FE typed read → P2 backend cutover(콜론 중단) → P3 cleanup.
  각 PR 독립 green.

검증 기대:

- 로컬 rfc-enforcer R1–R5(이 caller-context 포함) 통과.
- `keeper-reason.test.ts` 가 union exhaustiveness + drift guard + parse table 증명.
- 회귀 테스트: #22062(composite → 한국어 라벨), #22059(overview attention_reason → 한국어 라벨).

거버넌스 플래그:

- RFC-0150(attention envelope) 이 `status: Implemented` 이나 실측 미구현(`attention_signal` 부재,
  `ATTENTION_PAIR_DUPLICATES` live). 본 RFC §7 에 기록, status 정정은 별도 추적.

RFC-gated 영역: `lib/operator/operator_control_snapshot_trust.ml` (reason passthrough) 가
agent_delegation 목록(`lib/operator/operator_control*`) 에 해당 → 본 RFC 가 그 게이트를 충족.
