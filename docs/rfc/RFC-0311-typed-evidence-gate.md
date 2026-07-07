---
rfc: "0311"
title: "Typed evidence gate — retire the substring incantation, judgment to the LLM boundary"
status: Accepted
created: 2026-07-06
updated: 2026-07-07
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0088", "0109", "0189", "0199", "0310"]
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

## 8. 구현 착수 (2026-07-07): 진단 확정 + 운영자 결정

4-agent read-only 진단 워크플로(over-block / leak / current-gate 트랙 + spec)로 §1 문제를 실측 검증했다. Draft → Accepted.

### 8.1 진단 확정 — 과잉차단과 누수는 같은 한 줄

- [근거] `keepers/*.decisions.jsonl` error_preview 142건 중 **142/142가 contracted 경로**(`required_evidence` n_unsat 2/3/4), #23330 no-contract 규칙(`contract_required:false`)은 **0/142**. 원래 지목된 no-contract typed-ref 규칙은 실측 거부가 0건 — 지배적 과잉차단 원인이 아니다.
- [근거] 모든 task는 생성 시 무조건 계약을 받는다: `workspace_task_create.ml:161` → `ensure_task_contract_for_verification`. 계약 없이 생성해도 `required_evidence` 기본값이 `["completion_notes"; "reviewable_evidence_ref"]`(`workspace_task_classify.ml:200`) 두 메타 토큰으로 채워진다.
- [근거] 이 기본 토큰을 만족하는 유일한 방법은 리터럴 문자열을 notes에 붙여넣는 substring 매칭(`task_completion_gate.ml:40-56`)이다. trusted-ref 대안은 `evidence_ref_is_gate_trusted ref_ && r = entry_lower`(`:74-78`)로 ref 문자열이 메타 필드명과 **정확히 일치**해야 하는데 어떤 실제 `Evidence_ref`도 그 이름이 될 수 없다. 따라서 한 줄이 동시에 **누수**(라벨 붙여넣기 = fake-done)이자 **과잉차단**(토큰을 모르는 키퍼는 결정론적 거부: nick0cave task-1831 4회 거부 후 포기, sangsu 트레이스 "required_evidence 항목을 verbatim으로 다 써야 하는데 그게 뭔지 모른다").
- [근거] non-code task의 구조적 블로커: trusted 형태(Url/Trace_ref)를 원리상 생산할 수 있어도 제출 채널 `handoff_context.evidence_refs`가 `action='release'` 전용(`tool_task_schemas.ml:256`, `tool_task_args.ml:143-145`)이라 keeper가 "keeper_task_done 스키마에 노출 안 됨"으로 제출 불가.

### 8.2 운영자 결정 (2026-07-07 ratified)

**제약(최우선)**: 어떤 계약 모델이든 **keeper가 완료 경로에서 멈추면 안 된다**. 이 제약이 아래 설계를 결정한다 — 판단은 task를 붙잡되(AwaitingVerification) keeper lane은 붙잡지 않는다(§3.2).

1. **계약 부여**: 생성 시 필수(마찰↑, 예측 불가)나 분류기(CLAUDE.md/RFC-0042 금지 안티패턴)가 아니라, **항상 부여 + 기본값을 universal typed-ref 요구**(`{Pr, Commit, Url, Trace_ref} 중 임의 trusted ref ≥1`)로. 모든 turn이 산출하는 Trace_ref로 default 충족 가능 → Layer 1 항상 통과 가능(anti-stall). 생성/클레임 시 더 엄격한 kind로 정제 가능(`tool_task_handlers.ml:266`이 이미 typed 계약 인자 수용).
2. **non-code trusted evidence**: `Url`(발행 링크) + `Trace_ref`(turn:/trace:/receipt:) + 작성 산출물용 `Artifact_exists` 클레임(RFC-0199, `file_bytes` probe로 결정론 검증). raw `File_path`/`File_uri`는 비신뢰 유지(base-path 미해결 = 검토 불가; `task_completion_gate.ml:32-37`의 fail-closed 근거 타당).
3. **제출 채널 enabler(필수)**: `evidence_refs`를 Done/Submit 경로에 직접 수용 — release 전용 non-empty-summary 결합에서 분리. §8.1의 구조적 블로커 해소.

### 8.3 구현 순서

- **PR-A (본 PR, behavior-preserving decap)**: 게이트 모듈 리네임 `Cdal_evidence_gate` → `Task_completion_gate`(`lib/task_completion_gate.{ml,mli}`), Atomic `cdal_evidence_gate_decide_fn` → `task_completion_gate_decide_fn`, 로그 문자열. rule_id `"cdal_evidence_incomplete"`는 PR-B에서 §5 typed reason으로 교체될 때까지 유지. 행동 변화 0. CDAL 브랜드가 게이트에서 사라지는 지점(생산자 측 `lib/cdal/`·`lib/cdal_runtime/`는 라이브이므로 무관, 별도 정리).
- **PR-B (behavioral Phase 1+3)**: §3.1 Layer 1 typed 충족 + §8.2 결정 1·2·3. `default_verification_evidence_refs` 매직 토큰 → universal typed-ref, `ref==entry` 동등성 → typed-kind 매칭, enabler, substring 매처 제거(§7 Phase 3), 하네스 매직 토큰 마이그레이션(§4). tripwire 테스트(§6).
- **PR-C (Phase 2)**: §3.2 LLM fail-closed 판단 + §3.3 force 감사.
- 영속 계약 마이그레이션: `required_evidence : string list`(문자열 SSOT) → typed kind. 레거시 문자열 계약은 compat read 필요(`types_core.ml:519-540` 주석이 이미 "legacy 문자열 파싱 migration" 경로를 지시).
