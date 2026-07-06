---
rfc: "0311"
title: "Typed evidence gate — retire the substring incantation, judgment to the LLM boundary"
status: Draft
created: 2026-07-06
updated: 2026-07-06
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0088", "0189", "0310"]
implementation_prs: []
---

# RFC-0311: Typed evidence gate — retire the substring incantation, judgment to the LLM boundary

Tracking issues: #18840 (잔존 안티패턴 스코프), #21074 (fake-done 대량 사고). 흡수 대상: p-2bfba5f2 Layer 2 board 논의, open draft PR #23330. 에스컬레이션 근거: PR #23279 리뷰 (2026-07-06 감사).

## 1. Problem

done 판정의 결정론 층이 substring 주문(incantation)으로 구현되어 있고, #23279가 이를 **전 done 경로의 우회 불가 하드 불변식으로 승격**했다:

- [근거] `lib/cdal_evidence_gate.ml` — `notes_are_substantive`: 20자 길이 임계값 + `placeholder_note_bodies` 문자열 리스트; `evidence_entry_satisfied`: `required_evidence` 항목의 case-insensitive verbatim substring 매칭. 확인 2026-07-06, Confidence High.
- [근거] `lib/workspace/workspace_task_classify.ml:200` — `default_verification_evidence_refs = ["completion_notes"; "reviewable_evidence_ref"]`: 모든 기본 task에 부여 → 사실상 "done 노트에 이 두 토큰을 verbatim으로 써라"는 프로토콜.
- [근거] `scripts/harness/contract/golden_path_1_contract.sh:152`, `public_tool_live_sweep.sh:329` — #23279 자신이 하네스에 통과용 토큰을 하드코딩. **gate가 게이밍 가능함의 자기 증명**이며, keeper가 이 문자열 조합을 학습하면 gate는 검증이 아니라 주문이 된다 (#21074의 재발 조건).
- [근거] #23279는 `force=true`도 gate를 우회하지 못하게 고정 — 같은 경로의 LLM anti-rationalization 리뷰어(RFC-0189)는 우회 가능한 채로. **"판단은 LLM 경계에" 원칙의 역전**: 판단력 없는 문자열 층이 최상위, 판단하는 층이 우회 가능.

방향(면제 경로를 닫음)은 맞다. 잘못된 것은 판정의 **재료**(substring)와 **층위**(문자열 층 > operator > LLM)다.

## 2. Non-goals

- evidence gate 자체의 제거 — done 무검증 통과로 돌아가지 않는다
- LLM 판정의 동기 블러킹화 — keeper lane은 어떤 경우에도 대기하지 않는다
- CDAL 계약(strict contract task)의 completion_contract 의미론 변경

## 3. Design — 3층 재배치

### 3.1 Layer 1 (결정론): typed evidence_refs — parse, don't validate

- `masc_transition done`에 구조화된 `evidence_refs` 필드를 받는다. 기존 `Evidence_ref` 파서(`Pr | Commit | Url | Trace_ref | ...`)로 **write-time 파싱** — 실패는 typed 에러로 즉시 반환.
- 결정론 층이 검사하는 것: typed ref의 존재와 형상(shape)뿐. free-text substring 검색, 길이 임계값, placeholder 리스트를 모두 제거한다.
- no-contract task: **#23330의 방향을 흡수** — `handoff_context.evidence_refs` 최소 1건 존재를 요구하되, 문자열 존재가 아니라 typed 파싱 통과 기준으로.
- `default_verification_evidence_refs` incantation 토큰 계약 제거. `required_evidence`는 typed ref kind 요구로 전환 (예: `requires: [Pr; Trace_ref]`).

### 3.2 Layer 2 (판단): LLM 리뷰어가 substantiveness를 소유 — fail-closed

- "이 evidence가 이 task의 완료를 실제로 뒷받침하는가"는 판단이므로 기존 anti-rationalization LLM 리뷰어(RFC-0189)가 소유한다. 프롬프트에 typed evidence_refs + 노트 + task 계약을 전달.
- **LLM unavailable 시 fail-open(자동 통과) 금지**: done은 `AwaitingVerification`에 머물고 HITL 큐로 nomination — keeper는 블러킹 없이 다음 활동으로 (release/다른 task). RFC-0305(fail-closed default)와 정합.
- 리뷰 결과는 typed verdict + model_run_id provenance로 영속화.

### 3.3 Layer 3 (operator): force의 의미론 복원

- `force=true`는 **감사 이벤트를 남기는 명시적 operator override**로 재정의: Layer 2(판단)를 우회하되 Layer 1(typed parse)은 우회하지 않는다.
- 모든 force에 `Done_forced { actor; reason; at }` 이벤트 영속화 + 대시보드 표면. actor 없는 force 거부.
- 현행(#23279)의 "substring 검사가 operator force보다 상위" 상태를 해소한다.

## 4. Harness migration

- `golden_path_1_contract.sh` / `public_tool_live_sweep.sh`의 매직 토큰 문자열을 typed `evidence_refs` 인자로 교체 — 하네스가 게이밍 선례가 아니라 계약 사용 예시가 되도록.
- keeper 프롬프트의 done 가이드에서 토큰 나열 대신 typed ref 작성 지시로 갱신.

## 5. Observability

- gate 판정마다 typed 사유(`Rejected_unparseable_ref | Rejected_missing_required_kind | Judged_insufficient of { model_run_id } | Forced of { actor }`)를 이벤트로 — 문자열 사유 스니핑 불가하게.
- 판정 분포(승인/거부/force 비율) 대시보드 카운터는 관측 목적으로만 (counter-as-fix 아님 — 행동 변화가 본 RFC의 본체).

## 6. Verification

- Alcotest: (a) unparseable ref 거부, (b) required kind 미충족 거부, (c) LLM unavailable 시 AwaitingVerification 유지 + HITL nomination (자동 통과 없음), (d) force가 감사 이벤트 없이는 거부, (e) 기존 #23279 회귀 테스트의 의도(우회 불가) 보존 확인.
- 게이밍 회귀 케이스: 노트에 토큰 문자열만 나열한 done이 **통과하지 못함**을 고정하는 테스트 (현행과 정반대 방향의 tripwire).

## 7. Rollout / Removal targets

- Phase 1: `evidence_refs` typed 필드 추가 + 이중 수용 (typed 또는 legacy substring 통과 — 전환 기간, WARN 관측).
- Phase 2: LLM fail-closed 배선 + force 감사 이벤트.
- Phase 3 (removal): `placeholder_note_bodies`, 20자 임계값, `evidence_entry_satisfied` substring 매처, `default_verification_evidence_refs`, 하네스 매직 토큰. — #18840이 스코프한 잔존 안티패턴의 청산 지점.
