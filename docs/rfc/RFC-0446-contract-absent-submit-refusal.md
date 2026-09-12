---
rfc: "0446"
title: "계약 없는 제출은 검증에 들어가지 않는다"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: claude
supersedes: []
superseded_by: null
related: ["0401", "0387", "0362", "0417"]
implementation_prs: []
---

# RFC-0446: 계약 없는 제출은 검증에 들어가지 않는다 (contract-absent-submit-refusal)

## 0. Summary

`submit_for_verification` 은 Task 에 완료 계약(`task.contract`)이 없으면 typed 오류로 거절한다.
거절은 상태 전이 앞에서 일어난다. Task 파일, 검증 요청 파일, Board 글 중 아무것도 쓰지 않는다.
계약이 있는 요청은 계약의 revision 해시를 싣고, 판정을 확정하는 순간 그 해시를 다시 대조한다.
빈 계약을 판정자에게 조용히 넘기던 경로(`criteria = []`, `contract_section … -> Ok ""`)는 지운다.
마이그레이션은 없다. 이미 계약 없이 대기 중인 요청은 판정하지 않고 재제출을 요구한다.

2026-09-12 결정 3(memory `masc-runtime-decisions-2026-09-12`)과 Codex 검토 `decision_critiques[2]` 를 따른다.

관련 RFC 와의 관계:

- **RFC-0401 을 확장한다.** 0401 의 1겹은 "제출 경계는 parse 사실만 거절한다" 이다. 이 RFC 는 parse 사실 하나를 더한다 — 계약이 있는가. 개수 하한은 여전히 두지 않는다. 계약이 좋은지는 판정 레인의 몫이다.
- **RFC-0387 B1 의 Task 판이다.** 0387 은 Goal 생성 시 성공조건을 요구한다. 이 RFC 는 Task 의 완료 제출 시 계약을 요구한다. 생성 시점이 아니라 제출 시점인 이유는 §5 에 있다.
- **RFC-0362 와 이어진다.** 0362 는 Goal 이 Task 로 내려오는 intake 계약이다. 이 RFC 는 Task 가 Done 으로 올라가는 exit 쪽 계약이다.
- **RFC-0417 을 건드리지 않는다.** 취소 심사는 완료 계약이 아니라 진술된 사유를 본다. §2.2 에서 경계를 명시한다.

## 1. 배경 (실측)

09-08..09-12 UTC 로그(`system_log_2026-09-08..12.jsonl`)를 세면 이렇다(적대 감사 S2, 검증자 재도출 일치).

- `[verification-submit] task=… has no contract` WARN 33줄(일별 2/6/5/19/1), 09-08T11:12Z..09-12T01:21Z, 서로 다른 task 24개.
- 창 안에서 판정이 확정된 task 46개. 그중 23개가 계약 없는 task. 8개는 REJECT 만, 8개는 APPROVE 만, 7개는 둘 다. 최소 한 번 APPROVE 를 받은 계약 없는 task 는 15개.
- 창 전체 판정 줄은 APPROVE 29 / REJECT 52.
- task-1538(polisher): 23:35:23Z 계약 없음 WARN → 23:48:06Z `LLM approved … reason=모든 계약 항목을 조회 도구로 직접 확인했다…` → `task task-1538 done by polisher`. 판정문이 존재하지 않는 계약을 확인했다고 적었다.

코드가 이렇게 만든다.

- `lib/verification_protocol.ml:submit_request_spec` — `task.contract = None` 이면 `criteria = []`.
- `lib/verification_protocol.ml:warn_contract_gap` — WARN 한 줄. 주석에 "No behavior change".
- `lib/completion_authority_agent.ml:verdict_question_of_request` — `criteria = []` 를 `completion_contract = None` 으로.
- `lib/task/anti_rationalization.ml:contract_section` — `None | Some [] -> Ok ""`. 판정자 프롬프트에서 `<verification_contract>` 블록이 통째로 빠진다. "계약이 없다" 는 문장은 어디에도 없다(`rg 'no contract|계약이 없' config/prompts lib/task` 0건).
- `lib/verification.ml:verification_request` — 계약 부재를 적을 필드가 없다.
- `dashboard/src/components/verification-requests-panel.ts:VerificationRow` — `hasContract = row.completion_contract.length > 0`. 리스트 길이로 파생한 값이라 계약을 대조한 APPROVE 와 대조할 것이 없던 APPROVE 가 같은 행으로 보인다.

결정은 결정론 코드가 조용히 내리고, 판정은 LLM 이 모른 채 한다. 이 RFC 는 그 결정을 typed 로 만들고 제출 앞으로 옮긴다.

## 2. 설계

### 2.1 계약의 parse — 닫힌 합

```ocaml
(* lib/task/task_contract_parse.ml — 새 모듈 *)
type contract_revision = Contract_revision of string
  (* task_contract 의 canonical JSON 을 SHA-256 한 hex. 같은 계약은 같은 값 *)

type present_contract =
  { criteria : string list          (* trim 후 비어 있지 않은 항목, 1개 이상 *)
  ; required_evidence : string list
  ; revision : contract_revision }

type contract_defect =
  | No_criteria                     (* completion_contract 가 [] *)
  | All_criteria_blank of int       (* n개 있으나 trim 하면 전부 "" *)

type contract_parse =
  | Absent                          (* task.contract = None *)
  | Invalid of contract_defect      (* Some c, 그러나 판정할 항목이 없다 *)
  | Present of present_contract

val parse : Masc_domain.task_contract option -> contract_parse
```

`Present` 의 조건은 "trim 한 뒤 비어 있지 않은 `completion_contract` 항목이 하나 이상" 하나다.
`required_evidence` 는 비어 있어도 `Present` 다. 증거를 얼마나 요구할지는 계약 작성자의 결정이고, 그 충분함은 판정자가 본다.
`strict`, `inspect_gate_evidence`, `verify_gate_evidence` 는 parse 에 영향을 주지 않는다.
`Invalid` 는 `Absent` 로 접지 않는다. 둘은 다른 원인이고 다른 조치가 따른다(§2.5).

생성 경계도 같은 parse 를 쓴다. `masc_add_task` 가 `contract` 객체를 주는데 parse 가 `Invalid` 면 생성을 거절한다. `contract` 를 생략하면 `Absent` 로 생성된다. 그래서 정상 운영에서 `Invalid` 는 사람이 `tasks.json` 을 손으로 고쳤을 때만 나온다.

### 2.2 어느 intent 가 계약을 요구하는가

게이트는 `AwaitingVerification` 상태가 아니라 producer 가 내미는 claim 의 생성자에 건다.

| claim (`Masc_domain.verification_claim`) | 요구하는 것 | 이 RFC 의 게이트 |
|---|---|---|
| `Completion_evidence { evidence_refs }` | `contract_parse = Present` | 건다 |
| `Cancellation_reason { reason }` | 비어 있지 않은 `reason` (이미 `workspace_task_transitions.ml` 에서 거절) | 걸지 않는다 |

취소 심사는 사유 문장을 보는 별개의 계약이다(RFC-0417). 계약 없는 Task 도 취소는 지금처럼 제출된다.

### 2.3 producer → store → consumer → caller

```
producer   masc_transition(submit_for_verification)  또는 keeper 의 tool_task
  │  Workspace_task_transitions.transition_task_outcome_r
  │    new_status = AwaitingVerification { intent = Complete_task }
  │    ── 여기서 parse ──  Absent | Invalid  → Error (Task Contract_required …)
  │                       Present p         → pending_verification (claim, p.revision)
  │    notes/summary 검사(기존)와 같은 자리, commit 앞
store      Verification.create_request  — 요청 파일에 contract_revision 을 쓴다
           Workspace 커밋 — Task 상태 전이
consumer   Completion_authority_agent.verdict_question_of_request
             completion_contract : string list   (option 이 아니다)
           Anti_rationalization.contract_section  — 항상 블록을 렌더한다
           commit_verdict  — parse(task.contract) 의 revision 과 request.contract_revision 대조
caller     MCP tool 결과 · 로그 · dashboard · TUI · Board
```

거절 시 쓰는 것이 없다. Task 의 `assignee`, `started_at`, `version`, 이전 handoff 가 그대로다.
제출자가 넘긴 `evidence_refs` 는 tool 결과에 되돌려 준다. 보상(`delete_verification_request`)이 필요 없다. 아무것도 만들지 않았기 때문이다.

### 2.4 typed 오류와 각 표면

```ocaml
(* lib/types/masc_error.ml Task_error.t 에 추가 *)
| Contract_required of
    { task_id : string
    ; parse : contract_refusal
    ; submitted_evidence_refs : string list }
and contract_refusal = Refused_absent | Refused_invalid of contract_defect

(* lib/workspace 판정 확정 오류 *)
| Stale_contract_revision of
    { task_id : string
    ; verification_id : string
    ; submitted : contract_revision
    ; current : contract_parse }
```

| 표면 | 보이는 것 |
|---|---|
| MCP tool 결과 | `error.kind = "contract_required"`, `parse = "absent" \| "invalid"`, `defect`, `task_id`, 되돌린 `evidence_refs`. 다음 행동: `contract` 를 먼저 쓰고 다시 제출 |
| 로그 | WARN 한 템플릿 `[verification-submit] refused task=%s contract=%s` (absent/invalid). `warn_contract_gap` 의 두 템플릿은 삭제. 확정 시 불일치는 ERROR `[verification-commit] stale contract task=%s vrf=%s` |
| dashboard verify 큐 | 행의 `contract` 가 `{ revision; criteria[] }` 로 필수 필드. `hasContract` 삭제. 큐에 계약 없는 행은 존재할 수 없다 |
| dashboard task 상세 | `InProgress` 이고 `Absent` 면 "계약 없음 — 제출은 거절된다" 를 상태 옆에 표시 |
| TUI task 상세 | `done-when` 줄이 없을 때 빈칸 대신 `contract absent — submit will refuse` 한 줄 |
| Board | 거절은 글을 만들지 않는다. 검증 요청 글의 `meta_json` 에 `contract_revision` 추가 |
| 판정자 프롬프트 | `<verification_contract>` 블록이 항상 있다. 블록 없이 판정하는 경로는 타입상 없다 |

### 2.5 revision 묶기와 재제출

- 요청 파일의 `contract_revision` 은 필수 필드다. 없는 파일은 `Verification.list_requests` 의 `unreadable` 로 분류된다(기존 경로, 판정되지 않고 목록에 남는다).
- `commit_verdict` 는 `parse (task.contract)` 를 다시 계산한다. `Present { revision }` 이 요청의 값과 같을 때만 확정한다. 다르거나 `Absent`/`Invalid` 면 `Stale_contract_revision` 으로 거절하고 요청 파일을 남긴다.
- `task_contract` 는 코드 안에 생성 뒤 쓰는 곳이 없다(`rg "contract = " lib/workspace lib/task` 는 생성 시 normalize 와 읽기뿐). 이 묶기는 손으로 편집된 `tasks.json` 을 막는다.
- 재제출을 위해 `Absent → Present` 한 번의 쓰기를 허용한다. 소유자가 `InProgress` 상태에서 `masc_transition(action = set_contract, contract = {…})` 로 쓴다. `Present` 를 다시 쓰는 것은 거절한다. 계약은 여전히 한 번만 쓰인다 — 그 한 번이 생성 시점이 아니어도 된다. `Invalid` 는 이 경로로 고치지 않는다. 취소하고 다시 만든다.
- 이미 `AwaitingVerification` 인 계약 없는 Task: 판정 레인은 `Skipped_contract_absent` 로 건너뛰고(Deferred 가 아니다, 재시도하지 않는다), 로그 한 줄과 dashboard 행에 "판정 불가 — 계약 없음, 재제출 필요" 를 적는다. 운영자 verdict REJECT 가 Task 를 `InProgress` 로 돌리면 소유자가 `set_contract` 뒤 재제출한다. 시스템이 계약을 지어내지 않는다.
- 과거 15건의 APPROVE 와 그 Done 은 그대로 둔다. 판정 원장 줄에 `contract_revision` 이 없다는 사실이 그 자체로 이 RFC 이전 판정임을 말한다. 재판정하지 않고 다시 라벨을 붙이지도 않는다.

## 3. 판정 기준

각 항목은 테스트 하나 또는 grep 하나로 확인한다.

- **P1** `contract = None` 인 `InProgress` Task 에 `submit_for_verification` → 결과 `contract_required/absent`. 호출 전후 `tasks.json` 의 그 Task 바이트가 같다. 요청 디렉터리에 새 파일 0. Board 새 글 0. 로그에 `[verification-submit] refused task=… contract=absent` 정확히 1줄.
- **P2** `contract = Some { completion_contract = ["  "]; … }` 로 손편집된 Task 에 같은 호출 → `contract_required/invalid`, `defect = all_criteria_blank 1`. 나머지는 P1 과 같다.
- **P3** 계약 없는 Task 에 `cancel` + `reason` → `AwaitingVerification { intent = Cancel_task }`, 요청 파일 1개, 계약 관련 로그 0줄.
- **P4** `masc_add_task` 에 `contract = { completion_contract = [] }` → 생성 거절. `contract` 생략 → 생성 성공, `Absent`.
- **P5** `rg -n "has no contract|warn_contract_gap" lib/` 0건. `rg -n 'None \| Some \[\] -> Ok ""' lib/task/anti_rationalization.ml` 0건. `rg -n "hasContract" dashboard/src` 0건.
- **P6** 커밋 뒤 만들어진 요청 파일 전부에 `contract_revision` 이 있다. 필드를 지운 파일 하나를 넣고 `list_requests` 를 부르면 `unreadable` 에 1건, `readable` 은 나머지 전부.
- **P7** 대기 중 `tasks.json` 의 계약 항목을 바꾼 뒤 판정 확정 → `Stale_contract_revision`, 요청 파일 유지, Task 상태 그대로, ERROR 1줄.
- **P8** 하루치 로그에서 `completion authority committed … verdict=APPROVE` 줄의 task 중 그 시각에 `contract_revision` 없는 요청으로 판정된 것 0건. 감사의 집계 스크립트를 `scripts/` 에 넣어 같은 질문을 되묻는다.
- **P9** `Absent` Task 에 `set_contract` 1회 성공, 2회째 거절. `Present` Task 에 `set_contract` 거절.

## 4. 단계

각 PR 은 관측 가능한 변화 하나다.

- **PR-1 parse 와 revision.** `lib/task/task_contract_parse.ml` (`contract_parse`, `parse`, `revision`). `masc_add_task` 가 `Invalid` 를 거절한다. 단위 테스트: Absent/Invalid 두 defect/Present, 같은 계약 → 같은 revision, 순서만 다른 JSON → 같은 revision. 판정: P4.
- **PR-2 제출 경계.** `Task_error.Contract_required`, `transition_task_outcome_r` 의 `Complete_task` 가지에서 parse, MCP tool 결과 매핑, 로그 템플릿 1개. `warn_contract_gap` 과 그 호출 삭제. 판정: P1, P2, P3, P5 앞 두 줄.
- **PR-3 요청 묶기와 판정자.** `verification_request.contract_revision` 필수. `verdict_question_of_request` 의 `completion_contract` 를 `string list` 로. `contract_section` 이 항상 렌더. `commit_verdict` 의 revision 대조와 `Stale_contract_revision`. 판정: P6, P7.
- **PR-4 표면.** dashboard 큐 행 타입 · task 상세 표시 · TUI 한 줄 · Board meta. `set_contract` 액션. 판정: P5 셋째 줄, P9.
- **PR-5 대기 요청 처분과 되묻기.** 판정 레인의 `Skipped_contract_absent`, 부팅 시 대기 중 계약 없는 요청 목록 로그, PR 본문에 운영자 절차(REJECT → set_contract → 재제출). 감사 집계 스크립트 추가. 판정: P8.

PR-2 가 들어가면 그 순간부터 새 계약 없는 제출은 0이다. PR-3 이 들어가기 전까지 이미 대기 중인 요청은 옛 reader 가 읽는다. 그 사이 판정이 나면 §2.5 마지막 항목대로 그대로 둔다.

## 5. 반론과 답

**"비어 있지 않은 리스트도 무의미한 계약일 수 있다"** (Codex, 가장 강한 반론).
맞다. 그리고 이 RFC 는 그것을 막지 않는다. 경계가 거절하는 것은 parse 사실 하나 — 판정할 항목이 없다는 것 — 뿐이다(RFC-0401 1겹). "적당한 계약인가" 를 코드가 재기 시작하면 제목에서 계약을 지어내던 것과 같은 자리로 돌아간다(`workspace_task_classify.ml:normalize_task_contract` 주석이 그 실패를 적어 두었다). 대신 판정자는 이제 계약 블록을 항상 받는다. "모든 계약 항목을 확인했다" 는 문장이 빈 섹션 위에 쓰일 수는 없다. 계약이 형편없으면 판정문이 그 항목을 인용하며 REJECT 하고, 그 인용이 계약 작성자에게 돌아간다.

**"취소 심사가 깨진다"** (Codex).
게이트를 상태(`AwaitingVerification`)가 아니라 claim 생성자에 걸어서 답한다(§2.2). `Cancellation_reason` 은 자기 필수 필드(`reason`)를 이미 갖고 있고, 그 검사는 그대로다.

**"생성 시 요구하면 더 단순하다"** (RFC-0387 B1 처럼).
Task 는 Goal 과 달리 생성 뒤 범위가 정해지는 경우가 많다. 결정 3 은 제출 시점 거절이다. 대신 `Absent → Present` 한 번의 쓰기를 열어(§2.5) 재제출이 실제로 가능하게 한다. 생성 시 `Invalid` 만은 거절한다 — 그건 "없음" 이 아니라 "잘못 씀" 이다.

**헌법 forbidden 과의 대조.**
- `magic_number`: 경계 값은 "항목 0개 vs 1개 이상" 뿐이다. 1 위의 임계값은 없다.
- `string_matching`: parse 는 리스트 길이와 trim 뒤 빈 문자열 여부만 본다. 문구를 읽지 않는다. wire 의 `"absent"/"invalid"` 는 닫힌 합의 직렬화이고, 소비자는 다시 합으로 디코드한다.
- `budget_gate`: 누적 수치 게이트가 없다. 재시도·타임아웃도 추가하지 않는다.
- `greedy_shortcut`: `Ok ""` 로 섹션을 비우던 경로를 지운다. 빈 문자열로 통과시키는 자리가 사라진다.
- `hardcoded_path`: 요청 디렉터리는 기존대로 `config.base_path` 에서 파생한다.
- `env_var_sprawl`: 환경변수 없음. 설정 키도 없다. 켜고 끄는 스위치가 없다.
- `legacy_residue`: `warn_contract_gap` 과 그 주석("No behavior change")을 지운다. 옛 요청 파일용 reader 를 만들지 않는다. 필드 없는 파일은 이미 있는 `unreadable` 경로로 간다.

**헌법 invariant.**
- `closed_sum_over_string`: `contract_parse`, `contract_refusal`, `Stale_contract_revision` 전부 variant. `hasContract` 같은 파생 bool 을 없앤다.
- `strict_parse_no_default`: `Invalid` 를 `Absent` 로 누르지 않는다. `contract_revision` 없는 요청은 기본값으로 읽지 않고 `unreadable` 이다.
- `failure_keeps_evidence`: 거절은 아무것도 소비하지 않는다. `Stale_contract_revision` 은 요청 파일을 남긴다. 과거 판정 원장은 손대지 않는다.

## 6. 근거

- 적대 감사 S2(confirmed high): `/Users/dancer/me/.masc/evidence/audit-adversarial-20260912/merged.md` "## S2". 수치: WARN 33줄(2/6/5/19/1), 09-08T11:12Z..09-12T01:21Z, task 24개. 판정된 task 46 중 계약 없음 23 (REJECT 만 8, APPROVE 만 8, 둘 다 7 → APPROVE 포함 15). 창 전체 APPROVE 29 / REJECT 52. task-1538: 23:35:23Z → 23:48:06Z → done.
- 종합: 같은 디렉터리 `synthesis-adversarial.md` §2 S, §4 표 2행("contract 없는 task 판정 — 결정론: Absent 를 typed 로"), §5 "RFC 필요: S2 contract Absent 타입".
- Codex 검토: 같은 디렉터리 `codex-roadmap.json` `decision_critiques[2]` (critique 와 `rfc_must_pin_down` 5항목 — §2.1, §2.2, §2.3, §2.5 가 각각 답한다), `g1_revisions[2]` ("nonempty, explicit Task acceptance contract bound to its revision at submission and checked again before verdict settlement"), `rfc_order[2]` (세 번째, G1 authoritative 검증 실행 전), `missing[7]` ("contract edits" 는 §2.5 revision 묶기로).
- 결정 메모: `~/.claude/projects/-Users-dancer-me-workspace-yousleepwhen-masc/memory/masc-runtime-decisions-2026-09-12.md` 3항.
- 코드(main e763050689): `lib/verification_protocol.ml:submit_request_spec` (`criteria = []`), `:warn_contract_gap`, `:create_submit_request`; `lib/task/anti_rationalization.ml:contract_section`; `lib/completion_authority_agent.ml:verdict_question_of_request`, `:commit_verdict`; `lib/verification.ml:verification_request`, `:request_scan`; `lib/workspace/workspace_task_transitions.ml:transition_task_outcome_r` (notes 검사 자리, `superseded_verification_id`); `lib/types/types_core.ml:task_contract` ("Written once … never rewritten"), `:verification_claim`; `lib/types/masc_error.ml:Task_error`; `lib/workspace/workspace_task_classify.ml:normalize_task_contract`; `lib/task/tool_task_args.ml:parse_task_contract`; `dashboard/src/components/verification-requests-panel.ts:VerificationRow`; `dashboard/src/api/dashboard-misc.ts:VerificationRequest`; `bin/masc_tui_render.ml` task 상세 `done-when`; `config/prompts/verification.md` `### contract`.
- 관련 RFC: `RFC-0401-typed-probes-verdicts-and-harness-facts.md` §0 1겹, `RFC-0387-goal-verifier-gate.md` B1, `RFC-0362-goal-owner-and-intake-contract.md`, RFC-0417(취소 판정의 주인).
