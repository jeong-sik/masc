---
rfc: "0318"
title: "Operator-overlay LLM approval resolver for non-critical keeper HITL"
status: Draft
created: 2026-07-08
updated: 2026-07-08
author: vincent
supersedes: []
superseded_by: null
related: ["0199", "0254", "0304"]
implementation_prs: []
---

# Operator-overlay LLM approval resolver for non-critical keeper HITL

## 1. Problem

keeper HITL 승인 큐가 운영자 승인 대기로 정체된다. 2026-07-07 라이브 로그 실측: `base` 24건 + `nick0cave` 21건 = **45건**의 keeper가 운영자 클릭을 기다리며 멈춰 있다. 이 세션에서 강화한 승인 게이트(gh gating, evidence gate)가 큐 유입을 늘렸고, 운영자가 상시 대기하지 않으므로 keeper가 진행하지 못한다.

현재 LLM은 이미 각 승인 요청에 **판단을 제시**한다 — `hitl_summary_worker`가 "neutral forensic analyst"로서 approve/reject 옵션 + rationale + risk delta를 생성(`lib/keeper/hitl_summary_worker.ml:19-28`). 그러나 이 판단은 **대시보드에 표시만 되고**(`approvals-surface.ts:169-200`, 클릭 바인딩 없음), 사람이 읽고 손으로 클릭해야 한다. LLM이 이미 판단하는데 그 판단이 실행에 닿지 못하는 구조다.

운영자 요구: 비-critical 승인은 LLM 판단으로 자동 승인/에스컬레이션하여 큐 정체를 해소한다. 단, **안전 floor는 절대 낮추지 않는다.**

## 2. Non-goals

- **Critical/파괴적 작업의 자동 판단은 범위 밖.** RFC-0304 `NoAutoDecision`: Critical은 자동 Approve도 자동 Reject도 안 되며 가시성 목적 에스컬레이션만 허용(#22971 timeout-Reject 기각). 본 RFC는 이 경계를 건드리지 않는다.
- **결정론으로 측정 가능한 완료 승인은 RFC-0199가 담당.** task-completion처럼 typed evidence(`PR_merged`/`CI_pass`/…)로 검증 가능한 전이는 결정론 evaluator가 우선한다. LLM 경로는 결정론으로 검증 불가능한 **tool-approval** 요청에만 적용한다.
- **catastrophic floor 우회 불가.** RFC-0254 §5.3: 파괴적 git / write-escape / mkfs는 모든 overlay·trust·kill-switch와 무관하게 Deny. LLM verdict가 여기 닿을 수 없다.
- RFC-0254 §6은 "auxiliary-LLM smart resolver"를 해당 RFC의 non-goal로 명시하되, §5.5에서 **operator-overlay resolver를 의도적으로 미구현으로 남김**("the resolver must exist before this overlay is used"). 본 RFC가 바로 그 예고된 resolver다.

## 3. Current state (검증됨, HEAD 대조)

세 조각이 존재하나 **의도적으로 미연결**이다.

1. **LLM 제안 (표시 전용).** `hitl_summary_worker`가 `suggested_option = { label:string; rationale:string; estimated_risk_delta:risk_level option }`(`keeper_approval_queue_rules_types.mli:9-13`)를 생성 → SSE로 대시보드에 표시 + `model_run_id` 감사. Medium/High/Critical만 생성(Low 스킵). fire-and-forget, 실행에 닿지 않음.

2. **결정론 auto-approve hook (LLM 무관).** `to_oas_approval_callback`(`lib/governance_pipeline.ml`)에서 두 비-사람 경로가 `Approve`로 해소:
   - `always_approve` 운영자 플래그 → line 494-514 (`auto_approved_always`).
   - `find_matching_rule` 지문 매치(입력 SHA256 정규화 exact-equality, `risk_level <= rule.max_risk`) → line 516-537 (`auto_approved_rule_match`).
   - 매치 없음 → `None -> submit_and_await`(line 538): 운영자 해소 또는 timeout→Reject까지 fiber suspend. **LLM 요약은 이 miss 경로 안에서만 생성** — 즉 LLM 판단은 auto-approve 결정 시점에 아직 존재하지 않는다.

3. **2-tier 안전 floor.**
   - HARD: `auto_approval_hard_forbidden ~risk meta = (risk = Critical) || runtime_auto_approval_blocked meta`(`governance_pipeline.ml:104-106`), line 400-408에서 **가장 먼저** 검사 → `reject_hard_forbidden`(큐 진입 전 Reject). Critical은 `governance_pipeline_risk.ml`이 파괴적 catalog·`rm -rf`/`drop table`/`git push --force`·keeper `Execute`·delete/force/reset/drop/kill-named tool·empty-overwrite write에 부여. `runtime_auto_approval_blocked`는 manual-decision/uncertainty blocker에 latch(`keeper_meta_contract.ml:307-320`, exhaustive match).
   - SOFT: 파괴적 shell/git(non-Critical). rule-tier는 이를 좁은 remembered rule로 우회 가능(설계됨, 주석 490-493) — 그러나 이는 대시보드 문구 `governance.ts:610`("destructive shell/git… never auto-approved even when a rule exists")과 **모순**. 아래 §5 갭 3 참조.

## 4. The gap

배선 자체는 작다: `None ->` 분기(line 538)에 새 consumer를 두어 `submit_and_await` 폴백 전에 LLM judge를 호출, 확신 있는 non-critical Approve이면 `Approve`(감사 `auto_approved_llm`) 반환, 아니면 기존 사람 대기로 폴백. floor 상속은 **consumer가 line 408 하류에 위치할 때만** 무료로 얻어진다 — 이것이 유일한 구조적 요구.

그러나 배선이 아닌 안전 봉투가 실제 작업량이다:

1. **`label`은 자유 문자열이지 결정이 아니다.** substring 매칭으로 `Approve`를 유도하면 CLAUDE.md가 거부하는 "String/Substring 분류기" 안티패턴. parse-don't-validate typed 결정 variant 필요.
2. **`estimated_risk_delta`가 optional.** `None` risk는 fail-closed로 에스컬레이션, 절대 approve 금지.
3. **soft floor가 auto-approve 분기에 재적용되지 않음(기존 구멍).** `rule_match` 분기(516-537)는 `auto_approval_forbidden`을 재검사하지 않아 soft-forbidden 작업을 rule로 승인 가능. LLM tier를 같은 자리에 두면 이 느슨함을 **상속**한다. LLM 분기는 `auto_approval_soft_forbidden ~tool_name ~input`을 명시 재적용해 이 구멍을 (복제가 아니라) **닫아야** 한다.
4. **RFC-0199 Phase C 미구현.** task-completion flavor는 아직 전이 사이트가 없음. tool-approval flavor(governance hook, line 538)만 사이트 존재 → LLM judge 타겟은 **tool-approval callback**이지 RFC-0199 task 경로가 아니다.

## 5. Design

### 5.1 Typed decision (parse-don't-validate)

LLM 출력을 machine-actionable 결정으로 파싱:

```ocaml
type llm_verdict =
  | Auto_approve of { confidence : float; risk : risk_level }
  | Escalate of { reason : string }
  (* Reject는 없음: LLM이 거부하고 싶다는 것은 불확실성 신호이므로
     사람에게 넘긴다 (RFC-0304 timeout-Reject 실수 회피). *)

val parse_llm_verdict : suggested_option -> llm_verdict
(* label을 substring-match하지 않는다. 구조화된 결정 필드를 요구하고,
   해석 불가·risk=None·confidence<threshold이면 Escalate로 fail-close. *)
```

`Auto_approve`는 (a) `confidence >= threshold`, (b) `risk`가 `Some`이고 non-Critical, (c) `auto_approval_soft_forbidden`을 통과할 때만 산출. 그 외 전부 `Escalate` → `submit_and_await`.

### 5.2 삽입점

`governance_pipeline.ml` line 408(`reject_hard_forbidden`) **엄격히 하류**, line 538(`None ->`) 직전. 구조적 배치를 테스트로 강제(§7).

### 5.3 삽입 로직 (의사코드)

```
match find_matching_rule ... with
| Some matched -> auto_approved_rule_match   (* 기존 *)
| None ->
    if auto_approval_soft_forbidden ~tool_name ~input then submit_and_await
    else match llm_kill_switch () with
      | Disabled -> submit_and_await         (* kill switch: 즉시 사람-전용 *)
      | Enabled mode ->
        match parse_llm_verdict (judge ~timeout ...) with
        | Auto_approve v when mode = Enforce ->
            audit `auto_approved_llm; Approve
        | Auto_approve v (* mode = Shadow *) ->
            audit `auto_approved_llm_shadow; submit_and_await
        | Escalate _ | exception _ -> submit_and_await   (* fail-closed *)
```

judge의 자체 timeout은 HITL 큐 timeout보다 **짧아야** 한다 — 느린 judge는 사람으로 degrade하지 auto-Reject로 가지 않는다.

## 6. Safety invariants (비협상)

각 항목은 코드 또는 active RFC에 소급 추적된다.

1. **hard-forbidden 절대 승인 안 함.** `governance_pipeline.ml:400` 하류. `risk = Critical` 또는 auto-approval-blocking blocker이면 Approve 불가. (`:104-106`, `keeper_meta_contract.ml:307-320`)
2. **soft floor 재적용 — rule-tier 느슨함 상속 금지.** LLM 분기가 `auto_approval_soft_forbidden` 호출, 파괴적 shell/git 거부(기존 구멍 동시 수정 + `governance.ts:610` 문구 정합).
3. **Unknown은 절대 permissive 아님.** 자유 `label`·`risk=None`·confidence 미달 → fail-closed 사람. (RFC-0199 probe 불변식 `keeper_deterministic_evidence_probe.mli:22-26`, software-development.md "Unknown → Permissive Default")
4. **Critical 승인은 영구 운영자 소유.** RFC-0304 `NoAutoDecision`.
5. **catastrophic floor는 LLM-unoverridable.** RFC-0254 §5.3(불변식 1로 이미 보장 — Critical 붕괴).
6. **judge error/abstain/timeout에서 fail-closed.** 모든 LLM 오류 → `submit_and_await`.
7. **`pending` 제거는 promise resolve와 페어**(`keeper_approval_queue_rules.ml:36-43`). LLM Approve는 pending 진입 없이 동기 반환하므로 불변식 무영향 — enqueue-then-async-approve 경로를 추가하지 않는다.

## 7. Phased rollout (하네스 우선)

**Shadow mode를 기본값이자 출시 유일 모드로 한다.** judge가 verdict를 계산·감사(`auto_approved_llm_shadow`)하되 요청은 `submit_and_await`로 진행 — 사람이 결정하고, 사람 결정이 LLM verdict 옆에 기록된다. Enforce mode는 별도 운영자 플래그로, **soft band에서 사람과 일치 + 파괴적 작업 false-Approve 0건**을 N주 shadow 데이터로 확인한 뒤에만 flip. "좋은 에이전트는 좋은 하네스에서" — autonomy 전 eval harness와 동일 규율.

| Phase | 산출물 | 통과 조건 |
|---|---|---|
| P0 | typed verdict + parser + shadow 삽입 + 감사 이벤트 | LLM 분기가 Critical/soft-forbidden에 도달 불가(테스트) |
| P1 | shadow 일치율 대시보드 | soft band 일치율 + false-Approve 카운트 관측 |
| P2 | enforce 플래그 (기본 off) | N주 shadow: 파괴적 false-Approve 0 |

## 8. 필수 가드레일 (같은 RFC에 동시 착지)

1. **Kill switch (운영자 소유, LLM 독립).** 단일 플래그로 LLM 분기 전체 비활성화 → 사람-전용, 재배포 없이 즉시. 결정 시점 검사(캐시 금지).
2. **전체 감사 추적.** `auto_approved:true` + `model_run_id` + verdict rationale, 기존 `audit_approval_event` 재사용 → trust timeline(`keeper_runtime_trust_timeline.ml`)이 픽업. 모든 LLM auto-approve는 재구성 가능(입력 지문·risk·judge 출력·적용 threshold).
3. **사후 veto escape hatch.** RFC-0199 §193 모델 보존: verifier/운영자가 LLM-auto-approved 가역 작업을 사후 거부 가능. 비가역(대부분 Critical, 이미 floor out)은 애초에 LLM 분기에 닿지 않는다.

## 9. Alternatives

| 안 | 기각 이유 |
|---|---|
| RFC-0199 확장 | RFC-0199 논지는 판단을 결정론 evaluator로 *대체*(§46-50) + 자체 workaround gate가 string 분류기 금지(§231-237). LLM-judging은 문서와 모순. 또한 task-completion 타겟(tool-approval 아님). |
| 순수 결정론 (LLM 없음) | 측정 가능 승인은 RFC-0199가 이미 담당. 결정론 검증 불가능한 tool-approval에는 무력 → 45건 정체 미해소. |
| status quo (표시만) | 45건 정체 지속. LLM 판단이 실행에 닿지 못함. |
| always_approve 확대 | 안전 floor 무시. rule-tier 구멍 확대. |

## 10. Testing

- LLM 분기가 Critical·soft-forbidden 입력에 **도달 불가**함을 property 테스트로 증명(삽입점이 line 408 하류임을 구조적으로 강제).
- `parse_llm_verdict`: label 자유 문자열·`risk=None`·confidence 미달 → 전부 `Escalate`(fail-closed).
- judge timeout > HITL timeout이면 컴파일/설정 검사 실패.
- shadow-mode 일치 harness: 동일 승인 요청에 LLM verdict와 사람 결정을 페어 기록, 불일치·false-Approve 집계.
- TLA+ (선택): `LlmApproveCriticalAbsorbed` action + `CriticalNeverLlmApproved` invariant로 삽입점 회귀 방지(software-development.md TLA+ bug model).

## 11. 근거

- 스코핑 워크플로(2026-07-08, 5-agent, 모든 file:line HEAD 대조 검증).
- 정체 실측: 라이브 로그 base 24 + nick0cave 21 = 45건.
- 삽입점·floor·기존 구멍: `lib/governance_pipeline.ml:104-106,400-408,494-538`, `keeper_meta_contract.ml:307-320`, `keeper_approval_queue_rules.ml:36-43`, `governance.ts:610`.
