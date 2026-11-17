---
rfc: "a-goal-states-its-measure-as-a-typed-value"
title: "Goal 의 성공 조건을 타입 있는 측정으로 적고, 목록과 상세가 그 값을 읽는다"
status: Draft
created: 2026-11-17
updated: 2026-11-17
author: claude
related: ["0387", "0267", "0444", "0362", "goal-candle-ledger", "tui-one-screen-grammar"]
---

# Goal 의 성공 조건을 타입 있는 측정으로 적고, 목록과 상세가 그 값을 읽는다

- 상태: 초안. 구현은 이 RFC 가 병합된 뒤 스택으로 한다(§9).
- 코드 좌표는 `origin/main` `a4089fa98494` 에서 읽었다.
- 화면 관찰은 같은 날 15:12 KST, main `95b27116b73b` 로 빌드한 TUI 를 120열로 띄워 찍었다(§1).

## 0. 결정

1. Goal 의 성공 조건은 닫힌 합타입 `measure` 다. 종류는 셋이다: 셀 수 있는 것(`Count`),
   잴 수 있는 양(`Quantity`), 되거나 안 되거나(`Done_when`).
2. 측정값은 Goal 의 `measure` 와 같은 모양으로만 기록된다. 모양이 다르면 쓰기가 거절된다.
3. 검증 판정은 판정자가 잰 값을 같은 모양으로 함께 남긴다. 이유 글은 그 값에 덧붙는 설명이다.
4. `last_review_note` 를 지운다. 판정 이유는 검증 원장에, 중단·재개 사유는 Goal 이벤트에 있다.
5. TUI 목록은 Goal 마다 진척(`1/14 층`)과 판정 종류를 같은 꼴로 보인다. 이유 글은 상세에서만 보인다.
6. 저장소는 hard cut 이다. 지금 Goal 넷(goals, measurements, verifications, criterion reviews)은
   새 스키마를 읽지 못하는 행을 `Schema_rejected` 로 알리고 지운 뒤 새로 쓴다(RFC-0444 §2.7).
   Candle 원장도 같은 배포에서 새로 시작하고, Snapshot 은 타입 있는 값을 담는다(§6).

완료 판정은 바뀌지 않는다. Verifier 가 증명하고 사람이 확인해야 완료다(RFC-0387 B3, constitution
goal). 측정값이 목표에 닿았다는 계산은 화면 표시에만 쓰고, phase 를 움직이지 않는다.

## 1. 원인 — 지금 무엇이 보이나

120열 TUI 의 `작업 › 목표` 목록(32개)에서 본 것:

```
 │ › 다계정 OIDC·Runtime 권한 1단계(A2 → … → S1, 14개 층)가 main에 … │
 │   진행 중 · 열린 작업 1개 · 지난 검증 거절: 측정값은 존재하고 직… │
 │   결과 모름으로 멈춘 Goal 검증이 사람 손 없이 새 시도로 다시 판 … │
 │   진행 중 · 기한 지남 · 작업 1개 진행 중 · 지난 검증 거절: metri… │
 │   C TUI: 첫 실행과 작은 화면에서 상태를 읽고 요청을 실행한다      │
 │   진행 중 · 기한 지남 · 열린 작업 1개 · 지난 검증 거절: REJECT —… │
```

- 31개가 `진행 중` 으로 시작한다. 둘째 줄이 Goal 마다 거의 같아서 무엇이 얼마나 왔는지 가려지지 않는다.
- 판정 이유는 첫 몇 낱말만 남는다. 시작이 `REJECT —`, `metric이…`, `측정값은…`, `Read the full decla…` 로
  제각각이라 거절의 종류를 읽을 수 없다.
- 첫 Goal 의 진척 `1/14` 는 판정 글 안(`reported_measurement(1/14)`)에만 있다. 화면이 꺼낼 칸이 없다.
- 상세의 판정 글은 줄이 들쭉날쭉하고 `[` 하나가 한 줄을 차지한다(§5.3 의 이중 줄바꿈).

원인은 화면 앞에 있다. 성공 조건과 측정값과 판정 이유가 모두 문자열이다.

| 값 | 타입 | 좌표 |
|---|---|---|
| 측정 대상 | `metric : string option` | `lib/goal/goal_document.mli:7` |
| 목표값 | `target_value : string option` | `lib/goal/goal_document.mli:8` |
| 측정값 | `observed_value : string` | `lib/goal/goal_measurement.ml:7` |
| 거절 이유 | `Refuted of { reason : string }` | `lib/goal/goal_verification.mli` (`verdict_outcome`) |
| 마지막 메모 | `last_review_note : string option` | `lib/goal/goal_document.mli:12` |

저장소는 두 값이 비었는지만 본다(`goal_store.ml:959-963`, `:868-874`). 숫자인지, 단위가 맞는지,
측정값이 목표와 같은 것을 재는지는 아무도 모른다. 그래서 화면은 글을 자르는 일밖에 할 수 없다.

`last_review_note` 는 뜻이 넷이다. 검증 거절 이유(`workspace_goals.ml:700-712`), 중단 사유(`:1102`),
전이 메모(`:1173-1176`), 다시 열기 메모(`goal_verification.ml:620-625`)가 같은 칸에 들어간다.
화면이 보여 주는 `지난 검증 거절: …` 은 이 칸이 아니라 원장의 `verdict.evidence` 인데, 거절일 때
`evidence` 에는 이유 글이 그대로 들어간다(`goal_verifier_host.ml:207-216`). 같은 글이 두 곳에 있고
이름이 다르다.

## 2. 측정의 모양

```ocaml
(* lib/goal/goal_measure.mli *)
type unit_label = private string
(** 화면에 붙는 단위 낱말: "층", "ms", "%", "건". 비어 있지 않은 한 줄. 비교에 쓰지 않는다. *)

type direction = At_least | At_most

type t =
  | Count of { noun : unit_label; total : int }
      (** [total] 개 가운데 몇 개가 됐나. 다계정 1단계 14개 층. total >= 1 *)
  | Quantity of { unit : unit_label; direction : direction; target : float }
      (** 잴 수 있는 양과 그 한계. p99 <= 100 ms, 적중률 >= 90 %. target 은 유한한 수 *)
  | Done_when of { condition : string }
      (** 셀 수도 잴 수도 없는 것. 한 문장으로 적은 조건 *)

type observed =
  | Counted of { done_ : int }            (** 0 <= done_ <= total *)
  | Quantified of { value : float }       (** 유한한 수 *)
  | Decided of bool

val observed_fits : t -> observed -> bool
(** 모양이 맞나만 본다. Count 에는 Counted, Quantity 에는 Quantified, Done_when 에는 Decided. *)

type reach = Reached | Short_of of { gap : string }
val reach : t -> observed -> reach
(** 화면 표시용. phase 를 움직이는 곳에서 부르지 않는다. *)
```

- 측정 방법은 따로 둔다: `procedure : string`. 어디를 어떻게 읽어 이 값을 얻는지 적는 글이다.
  지금 `metric` 칸에 들어 있는 긴 글(이슈 #46477 본문을 읽고…)이 여기로 간다. 판정자와 Keeper 가
  읽는 지시문이고, 코드는 이 글로 분기하지 않는다.
- `criterion` 은 `{ revision; title; measure; procedure }` 다. `metric`, `target_value` 칸은 없어진다.
- 백분율은 `Quantity { unit = "%"; … }` 다. 종류를 따로 두지 않는다.
- 줄어드는 목표(오류 0건)는 `Quantity { direction = At_most; target = 0. }` 다.
- 종류가 셋인 이유: OKR 도구들이 쓰는 핵심 결과 종류(수, 백분율, 늘림·줄임·유지, 이정표·예/아니오)를
  세 모양으로 접으면 이 셋이 된다(§10). 늘림과 줄임은 방향 하나로 충분하다. `유지` 는
  `At_least`/`At_most` 한 쪽으로 적힌다. 시작값(baseline)은 넣지 않는다. 지금 Goal 32개 가운데
  시작값을 쓰는 화면이 없고, 넣을 소비자가 생기면 그때 넣는다(RFC-0362 §3).

### 2.1 바깥에서 들어오는 모양

`masc_goal_upsert` 는 `metric`·`target_value` 대신 `measure` 객체와 `procedure` 를 받는다.

```json
{ "measure": { "kind": "count", "noun": "층", "total": 14 },
  "procedure": "이슈 #46477 본문의 1단계 14개 줄이 [x] 이고 줄마다 병합된 PR 이 있는지 센다." }
{ "measure": { "kind": "quantity", "unit": "ms", "direction": "at_most", "target": 100 },
  "procedure": "..." }
{ "measure": { "kind": "done_when", "condition": "TUI 가 첫 실행에서 키퍼 목록을 그린다" },
  "procedure": "..." }
```

- 모르는 `kind`, 빠진 칸, 남는 칸은 거절이다(constitution strict_parse_no_default). 기본값으로 채우지 않는다.
- 생성에는 `measure` 와 `procedure` 가 둘 다 있어야 한다(RFC-0387 B1 이 그대로 이 두 칸으로 옮겨 간다).
- `criterion_revision` 은 title·measure·procedure 가운데 하나가 바뀌면 새로 뽑는다. 지금처럼
  무작위 값이고(`goal_store.ml:965`), 바뀌면 진행 중인 증명이 Executing 으로 돌아간다(`:876-878`).

### 2.2 측정값

`masc_goal_measure` 는 `observed_value` 문자열 대신 `observed` 객체를 받는다:
`{ "kind": "counted", "done": 1 }`, `{ "kind": "quantified", "value": 140 }`, `{ "kind": "decided", "value": false }`.
`Goal_measurement.record` 는 `observed_fits` 가 거짓이면 `Conflict` 로 거절한다. `evidence` 와
`criterion_revision` 규칙은 그대로다(`goal_measurement.ml:220-294`). 측정은 지금처럼
`completion_effect=unchanged` 다.

## 3. 판정의 모양

```ocaml
(* lib/goal/goal_verification.mli *)
type measured =
  | Measured of Goal_measure.observed
  | Not_measured of { why : string }   (** 판정자가 값을 얻지 못했다. 읽기 실패, 원문 없음 *)

type verdict_outcome =
  | Proven of { measured : Goal_measure.observed }
  | Refuted of { measured : measured; reason : string }
```

- 판정자 출력 계약(`config/prompts/goal_verification.md`, `verifier_review_original.ml:50-54`)에
  잰 값을 넣는다. 판정자는 `procedure` 를 따라 직접 읽은 값을 Goal 의 `measure` 모양으로 낸다.
- 통과에는 잰 값이 있어야 한다. 값이 없는 통과는 지금 이유가 빈 판정과 같은 길로 간다
  (`goal_verifier_host.ml:214`, `Invalid_original "Goal judgment has no stated reason"`).
- 거절의 종류는 이유 글이 아니라 잰 값에서 나온다:
  - `Refuted { measured = Measured o; _ }` 이고 `reach measure o = Short_of _` → `측정 미달`
  - `Refuted { measured = Measured o; _ }` 이고 `Reached` → `측정은 닿음 · 다른 이유`
  - `Refuted { measured = Not_measured _; _ }` → `측정 못 함`
  화면은 이 셋을 낱말로, 이유 글은 상세에서 보인다. 이유 글을 읽어 종류를 고르는 코드는 없다
  (constitution forbidden#string_matching).
- 판정이 `evidence` 칸에 이유를 다시 적던 것(`goal_verifier_host.ml:207-216`)은 없어진다.
  `evidence` 는 판정자가 읽은 근거의 좌표만 담는다.

## 4. `last_review_note` 를 지운다

- 검증 거절 이유: 검증 원장의 `Refuted.reason` 에만 있다.
- 중단·전이·다시 열기 메모: `goal_events.jsonl` 의 Phase 이벤트에 `note` 로 남는다. 지금 이 메모들이
  이벤트에도 실리는지, Goal 칸에만 있는지는 구현 첫 층에서 `goal_store.ml` 의 이벤트 payload 로
  확인한다. 이벤트에 없으면 이벤트에 넣고 칸을 지운다.
- 소비자(§7)는 칸 대신 원장과 이벤트를 읽는다. 화면에는 `마지막 메모` 가 아니라 출처가 붙은 줄이
  보인다: `중단 사유`, `다시 연 이유`, `판정 이유`.

## 5. 화면 모델

화면 문법은 RFC-tui-one-screen-grammar 를 따른다. 이 RFC 는 Goal 이 넘겨주는 값을 정한다.

### 5.1 목록

```
       목표                                                        진척       판정            작업
 ▾ ◐ 진행 중 31
 ▌ 다계정 OIDC·Runtime 권한 1단계가 main 에 병합된다                 1/14 층   ✕ 측정 미달      ◐ 1
   결과 모름으로 멈춘 Goal 검증이 새 시도로 다시 판정된다             ○ 미측정   ✕ 측정 못 함     ○ 1   ▲ 기한
   Keeper 300명일 때 읽기 API p99                                   140 / ≤100 ms ✕ 측정 미달   ○ 2
   C TUI: 첫 실행과 작은 화면에서 상태를 읽고 요청을 실행한다         아직      ✕ 측정 못 함     ○ 1   ▲ 기한
 ▾ ◆ 확인 대기 1
   …
```

- phase 는 그룹 머리로 올린다(그 RFC §5.1 "모든 줄이 같은 글자로 시작하면 그룹 머리로").
- 진척 칸은 `Goal_measure` 의 표시 함수 하나가 만든다: `Count` 는 `done/total noun`,
  `Quantity` 는 `값 / ≤목표 unit`, `Done_when` 은 `됨`/`아직`. 측정이 없으면 `○ 미측정`.
- 판정 칸은 §3 의 세 낱말과 `◐ 판정 중`, `● 통과`, `▲ 기준 바뀜` 이다. 이유 글은 목록에 없다.
- 작업 칸은 연결된 작업 수를 상태 기호와 적는다. 셈은 지금 `planning_open_note`
  (`bin/masc_tui_render_work.ml:685-720`)의 우선순위를 그대로 쓴다(검증 대기 > 진행 중 > 열린 작업).
- 기한 지남은 맨 오른쪽 `▲ 기한` 이다.
- 한 줄로 끝난다. 지금은 Goal 하나가 두 줄을 써서 32개 가운데 16개만 보인다.

### 5.2 상세

```
 ── 목표 ──────────────────────────────
 제목    다계정 OIDC·Runtime 권한 1단계(A2 → … → S1, 14개 층)가 main 에 병합된다
 측정    층 14개 가운데 병합된 수
 지금    1/14 층 · 11-09 측정 · code-reviewer-father
 기한    지남(11-12)

 ── 측정 방법 ──────────────────────────
 이슈 #46477 본문의 1단계 14개 줄이 [x] 이고 …   (procedure, 96칸에서 한 번 꺾음)

 ── 판정 ──────────────────────────────
 ✕ 측정 미달 · 1/14 층 · 11-09
 판정 이유   측정값은 존재하고 직접 확인했다. …   (reason, 한 번 꺾음)

 ── 작업 1 ────────────────────────────
 ◐ 진행 중  B3 층 PR 올리기   code-reviewer

 ── 다음 ──────────────────────────────
 판정 이유를 보고 고친 뒤 c 로 다시 제출
```

- 작업 구역은 연결된 작업을 줄마다 상태·제목·담당으로 보인다. 지금 상세는 작업 수만 말한다.
- 작업 상세는 거꾸로 자기 Goal 의 제목과 진척 한 줄을 보인다(`목표  다계정 … · 1/14 층`).
  연결 원장(`tasks/goal_task_links.json`, RFC-0267)을 읽으니 새 저장은 없다.

### 5.3 줄바꿈은 한 곳에서

지금 판정 글은 두 번 꺾인다. `Planning_detail.wrapped_indent` 가 `width` 에서 한 번
(`bin/masc_tui_planning_detail.ml:39-46`), `planning_proof_rows` 가 `width - 4` 에서 다시 한 번
(`bin/masc_tui_render_work.ml:1030-1038`) 꺾는다. 첫 번째로 `width` 에 가깝게 찬 줄이 두 번째에서
다시 갈려 한두 낱말짜리 줄이 생긴다. `planning_proof_rows` 의 주석(`:1023-1029`)은 꺾이지 않은 글이
들어온다고 적고 있다.

`Planning_detail` 은 꺾지 않은 문단을 돌려주고, 그리는 쪽이 한 번만 꺾는다. 이 수리는 측정 타입과
무관하므로 스택 맨 아래 층으로 먼저 넣는다(§9 L0).

## 6. 저장소 — hard cut

- constitution forbidden#legacy_residue("미출시 제품이라 내부 마이그레이션도 불필요")와 RFC-0352 에 따라
  옛 행을 바꿔 읽는 reader·converter 를 만들지 않는다.
- RFC-0444 §2.7 이 schema hard cut 에 요구하는 것을 같은 PR 에 싣는다: `Schema_rejected` 와
  `reset_step`, 파일 넷마다의 효과, 바뀌는 소비자, CHANGELOG 의 "Fresh state required" 줄, 모든 phase 를
  덮는 fixture, 두 번 부팅 digest 시험.
- 지금 열린 Goal 32개는 새로 등록해야 한다. 지우는 일은 배포한 사람이 `reset_step` 으로 한다. 다시
  등록은 Goal 을 만든 Keeper 들에게 요청한다. 32개의 원문은 지우기 전에 `masc_goal_list` 출력으로
  운영 저장소 밖에 남긴다(복원용이 아니라 다시 쓸 때 읽을 원문).
- Candle 원장도 같은 배포에서 hard cut 한다. `Snapshot` 이벤트(`lib/candle/candle_event.ml:50-61`)는
  `metric`·`target_value` 문자열 대신 `criterion` 의 `measure`·`procedure` 와 통과 판정의 `measured`
  값을 담는다. Candle 감정(`candle_appraisal.ml`)과 지급(`candle_payout.ml`)은 이 값을 읽는다.
- 원장은 옛 행을 바꿔 읽지 않는다. 배포 때 원장에 접근하는 모든 writer 를 멈추고 원장을 새로 시작한다
  (RFC-goal-candle-ledger 의 "혼합 버전 금지"를 지우고 새로 쓰는 쪽으로 지킨다). 잔액은 원장에서
  계산하는 값이라(constitution candle) Keeper 잔액과 산 장신구 기록도 0 에서 다시 시작한다.

## 7. 바뀌는 소비자

| 소비자 | 지금 읽는 것 | 바뀐 뒤 |
|---|---|---|
| `masc_goal_upsert` 스키마 `config/tools/masc_goal_upsert.toml` | metric, target_value 문자열 | measure 객체, procedure |
| `masc_goal_measure` 스키마 | observed_value 문자열 | observed 객체 |
| `Workspace_goals.handle_goal_upsert_validated` (`lib/workspace_goals.ml:408-501`) | 문자열 두 개 | `Goal_measure.of_yojson` |
| 기준 심사 `Goal_criterion_agent` (`lib/goal_criterion_agent.ml`, `config/prompts/goal_criterion_review.md`) | 문자열 | measure 표시 + procedure |
| 판정자 프롬프트·출력 (`config/prompts/goal_verification.md`, `lib/keeper/goal_verifier_original.ml:22-41`) | 문자열, APPROVE/REJECT | measure + procedure, 잰 값 |
| `goal_verifier_host.ml:207-216` | Reject reason → evidence | `Refuted { measured; reason }` |
| `/api/v1/dashboard/planning` (`lib/server/server_dashboard_http.ml:625-715`), `/goals`, `/goals/detail`, `masc_goal_list` | goal_to_yojson | measure, 최신 observed, 판정 |
| TUI 디코드 `lib/tui_decode.ml:1467-1520`, `:3127` | 문자열 | measure, observed, measured |
| TUI 그리기 `bin/masc_tui_render_work.ml` 목록·상세 | 문자열 자르기 | §5 |
| Keeper 프롬프트 `lib/keeper/keeper_unified_prompt.ml:251-256`, `:331-350` | criterion JSON, review note | measure 표시, 진척, 판정 종류 |
| 대시보드 `dashboard/src/components/goals/goal-create-state.ts`, `goal-tree.ts`, `components/work.ts`, `api/dashboard-goals.ts` | 문자열 | 같은 세 모양 |
| Candle `candle_event.ml`, `candle_snapshot.ml`, `candle_payout.ml`, `candle_appraisal.ml` | 문자열 | measure, procedure, measured(§6) |
| 스크립트 `scripts/harness/contract/golden_path_1_contract.sh`, `public_tool_live_sweep.sh`, `scripts/verify-goal-confirmation-runtime.py` | 문자열 | measure 객체 |

시험은 feature_surface 의 Goal 기능을 본다: 모양이 다른 측정값을 거절하는가, 판정이 잰 값을
남기는가, hard cut 이 옛 행을 `Schema_rejected` 로 알리는가. TUI 는 화면 글이 아니라 디코드한 값과
보낸 요청만 본다(constitution build_and_ci).

## 8. 하지 않는 것

- 측정값이 목표에 닿으면 자동으로 완료 요청을 보내는 것. 완료는 Verifier 증명과 사람 확인이다.
- 측정 이력(시계열). 측정 저장소는 Goal 마다 최신 한 행이다(`goal_measurement.ml:256-262`).
  진척 그래프가 필요하면 소비자를 먼저 세운다.
- 단위 변환과 단위 비교. `unit_label` 은 붙여 보이는 낱말이다.
- Goal 아래 Goal(Initiative). Task 연결 규칙(RFC-0267)은 그대로다.

## 9. 넣는 순서(구현 스택)

| 층 | 내용 | 확인 |
|---|---|---|
| L0 | 판정 글 이중 줄바꿈 수리(§5.3) | 전후 캡처, 디코드 값 그대로 |
| L1 | `Goal_measure` 모듈, criterion·goal 이 measure·procedure 를 갖는다, store hard cut(§6), upsert 스키마 | store 시험, 두 번 부팅 digest |
| L2 | 측정값 observed, 모양 검사 | 모양 다른 기록 거절 시험 |
| L3 | 판정 출력에 잰 값, 원장 verdict 모양, evidence 정리 | 판정 결과 원장 시험 |
| L4 | `last_review_note` 삭제, 메모를 Phase 이벤트로 | 이벤트 시험 |
| L5 | TUI 목록·상세(§5), 작업 상세의 Goal 줄 | 120·60열 캡처 |
| L6 | Candle Snapshot 모양과 원장 hard cut, 감정·지급 입력 | 원장 시험 |
| L7 | 대시보드, Keeper 프롬프트, 스크립트 | 브라우저 캡처 |

L1 부터 L7 까지는 한 배포로 나간다. L1 만 배포되면 판정자와 화면이 없는 칸을 읽는다.

## 10. 앞선 사례

- OKR 도구들은 핵심 결과를 수(시작·현재·목표), 백분율, 이정표·예/아니오로 나눈다. 이름과 개수는
  도구마다 다르다. 이정표만으로 된 결과는 사실상 작업이라는 비판이 있다(Simple OKR, Agile Tools,
  Perdoo 도움말). 이 RFC 의 `Done_when` 이 그 자리다. 셀 수 있는 것이면 `Count` 로 쓰기를 권한다.
  출처: https://docs.simpleokr.com/simple-okr-manual/objectives-and-key-results/key-result-metric-types ,
  https://agiletools.crunch.help/en/concepts/key-result-types ,
  https://www.perdoo.com/resources/blog/different-types-of-key-results-and-when-to-use-them
- Linear 는 마일스톤·프로젝트 진척을 사이드 패널과 로드맵에 숫자로 보인다. 계산식(닫힌 이슈 / 전체)은
  공식 문서에서 확인하지 못했고 제3자 글에만 있다(https://linear.app/docs/project-milestones).
  MASC 는 진척을 작업 수에서 계산하지 않는다. 작업 수는 Goal 의 성공 조건이 아니기 때문이다.

## 11. 정한 것(사용자, 2026-11-17)

- **D1. hard cut.** Goal 저장소 넷을 지우고 Goal 32개는 다시 등록한다. 옛 글에서 수와 단위를 뽑는
  변환기는 문자열 추측이라 만들지 않는다(constitution legacy_residue, RFC-0352).
- **D2. Candle 도 다시 설계한다.** Snapshot 이 타입 있는 measure·procedure·measured 를 담고, 원장은
  같은 배포에서 새로 시작한다(§6). 잔액과 장신구 기록도 0 에서 다시 시작한다.
- **D3. 통과 판정에도 잰 값을 꼭 받는다.** 값 없는 통과는 이유 없는 판정과 같은 길로 간다(§3).
