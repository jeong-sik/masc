---
rfc: "goal-candle-ledger"
title: "Goal 을 끝내면 Candle 을 받고, 초상화 장신구를 산다"
status: Draft
created: 2026-09-29
updated: 2026-09-29
author: claude
related: ["every-lane-is-one-row-in-one-registry", "exact-lane-walks-one-slot-list", "0267", "0362", "0387", "0435"]
---

# RFC: Goal 을 끝내면 Candle 을 받고, 초상화 장신구를 산다

이 RFC 는 Goal 이 끝나면 keeper 에게 Candle 을 주는 규칙을 정한다. keeper 는 받은 Candle 로 초상화 장신구를 산다.

- 다루는 것: Candle 원장, Goal 완료 때의 지급, 기한 초과 감액, 기여자별 분배, 잔액이 시간이 지나며 줄어드는 규칙, 장신구 구매와 착용.
- 다루지 않는 것: Goal 의 phase(진행 단계) 흐름과 검증. Tool·Skill·모델 구입과 현상금 Task 는 후속 RFC 로 미룬다.
- 관련 문서: `RFC-0267`(Task 와 Goal 의 연결), `RFC-0362`(Goal owner), `RFC-0387`(Goal 완료 검증), `RFC-0435`(keeper 재화가 행동을 바꾸는지 재는 설계), `RFC-every-lane-is-one-row-in-one-registry`(새 lane 의 등록).
- 근거 기준: `origin/main` = `f632782f8c` (2026-09-29). 줄 번호는 이 커밋 기준이다. 데이터는 같은 날 이 컴퓨터에서 도는 서버의 `<base-path>/.masc` 에서 읽었다.
- 표시: **[사실]** 은 코드나 데이터에서 확인한 것이다. **[제안]** 은 이 RFC 가 정하려는 것이다.

## 용어

| 말 | 뜻 |
|---|---|
| Goal | 정량 성공 조건이 있는 큰 목표. Task 여럿이 연결될 수 있다. |
| Task | Goal 에 연결될 수 있는 작은 일. 담당자(assignee)가 있다. |
| keeper | 영속성이 있는 에이전트. |
| Candle | 보상 화폐. 정수 `milli-candle` 로 센다(1 Candle = 1000 milli-candle). |
| 원장 | Candle 이 오간 기록을 한 줄씩 덧붙이는 파일(`candle-ledger.jsonl`). |
| 검증 원장 | Goal 검증기가 결과를 커밋하는 저장소(`goal_verifications.json`). 위의 원장과 다르다. |
| 총액, 몫, 지급액 | 총액은 Goal 하나에 풀리는 Candle. 몫은 keeper 한 명의 감액 전 금액. 지급액은 감액 뒤 실제로 받는 금액. |
| 확정 | 사람이 `Confirm_completion` 으로 통과한 Goal 을 `Completed` 로 만드는 것. |
| 검증 통과 시각 | 검증기가 Goal 의 증명을 통과로 판정해 `Awaiting_confirmation` 이 된 시각. 그 결과의 `recorded_at` 이다. |
| 발행, 소각 | 발행은 `Paid` 로 Candle 이 새로 생기는 것이다. 소각은 구매와 잔액 감소로 Candle 이 없어지는 것이다. |
| 지급 일꾼 | 서버 안에서 도는 백그라운드 작업. 지급 의무가 남은 Goal 마다 후보를 정하고 모델을 불러 `Paid` 를 쓴다. |
| 후보 Task, 후보 keeper | 후보 Task 는 지급 근거가 될 수 있는 Task 다. 후보 keeper 는 후보 Task 담당자 가운데 keeper 인 사람이다(3.4). |
| lane | 모델이 하는 독립 작업(standalone lane). 이 RFC 는 `Candle_appraiser` 하나를 더한다. |

## 1. 요청과 이미 정해진 것

2026-09-29 운영자가 Goal 을 끝낼 때마다 보상을 주고 싶다고 했다. 보상 화폐는 Candle 이고 `0.5 Candle` 처럼 소수점 값도 쓴다. Goal 이 끝나면 기여한 정도에 따라 나눠 준다. 대화에서 정해진 것은 다음과 같다.

| 항목 | 결정 |
|---|---|
| 총액과 분배 | `Candle_appraiser` lane 하나가 정한다(3.4). 총액은 lane 이 고른 등급의 TOML 금액이다. |
| 받는 쪽 | keeper 만 받는다. 1단계 분배 근거는 Goal 에 연결된 Task 의 담당자뿐이다. |
| 지급 횟수 | Goal 당 한 번. 사람이 확정한 통과에 지급한다. 확정 전에 drop 한 Goal 은 지급하지 않는다. 확정한 뒤에는 재오픈하거나 drop 해도 지급하고, 지급한 뒤에는 회수하지 않는다. 재오픈해서 다시 확정해도 추가 지급은 없다. 연결된 Task 가 없으면 지급하지 않는다. |
| 자기 Goal | keeper 가 만든 Goal 로 받는 것도 1단계에서는 막지 않는다. 위험은 6장에 적는다. |
| 기한 초과 | 초과 1시간마다 몫에서 1%씩 줄고, 바닥은 20%. 두 값은 TOML 로 정한다. 기준 시각은 확정된 통과의 검증 통과 시각이고, 날짜만 있는 기한은 그날 UTC 23:59:59 로 읽는다. 기한을 읽는 함수는 overdue 알림과 하나로 합친다. |
| 잔액 | 시간이 지나면 지수적으로 줄어든다. 반감기는 TOML 로 정한다. 감소는 헌법 `no_wall_clock_death` 에 예외를 넣는 개정(5장 1번)이 들어간 뒤에 켜고, 처음 값은 `Off` 다. 시간 값은 지급이 쌓인 뒤 정한다(3.1.1). |
| 쓰는 곳 | keeper 가 직접 Candle 을 내고 초상화 장신구를 산다. keeper 는 Candle 을 안다. |
| 가격 | 아이템별 가격은 TOML 의 고정 가격으로 시작한다. 유통량에 연동하는 물가 공식은 실제 지급 분포를 본 뒤에 더한다(7장의 확인 항목). 가격 계산은 함수 하나로 모아 나중에 바꿀 수 있게 한다. |
| 범위 밖 | Tool·Skill·모델 구입, 현상금 Task. |

## 2. 지금 코드에서 확인한 것

- **[사실]** `Completed` 는 끝이 아니다. `Completed` 에서 `Reopen` 하면 `Executing` 으로 돌아간다(`lib/goal/goal_phase.ml:186`). 완료될 때 지급하기만 하면 재오픈했다가 다시 완료할 때마다 또 지급된다.
- **[사실]** `Completed` 로 가는 길은 하나다. 검증기가 통과시키면 `Awaiting_confirmation` 이 되고, 사람이 `Confirm_completion` 을 하면 `Completed` 가 된다(`goal_phase.ml:196`). 완료된 3건에서 검증 통과부터 사람의 확정까지 7.9~35.2시간이 걸렸다(`<base-path>/.masc/goal_events.jsonl`).
- **[사실]** 제목·metric·target 을 고치면 Goal 이 `Executing` 으로 돌아간다. 기한(`due_date`)과 priority 를 고쳐도 phase 는 그대로이고 기록도 남지 않는다(`lib/goal/goal_store.ml:741-766`).
- **[사실]** 새 Goal 에는 제목과 비어 있지 않은 metric·target_value 가 필요하다(`goal_store.ml:721-722`, `:785-791`).
- **[사실]** Worker 역할은 `masc_goal_upsert`, `masc_goal_transition`(CanBroadcast)과 `masc_task_set_goal`(CanCompleteTask)을 쓸 수 있다(`lib/types/types_auth.ml:341-345`, `lib/tool/tool_catalog.ml:354-360`). 세 도구는 keeper 에게 노출되어 있고(`lib/keeper/keeper_tool_descriptor.ml:2860, 2940, 2944`), keeper 가 호출한 기록이 있다(`<base-path>/.masc/keepers/tool_usage/`).
- **[사실]** `set_task_goal` 은 Goal 이 없는 Task 를 아무 Goal 에나 붙인다. 호출자, Task 상태, Goal phase 를 보지 않는다(`Task_goal_assignment.set_task_goal`). Task 와 Goal 의 연결에는 시각이 없다.
  - 이미 있는 Task 를 나중에 Goal 에 붙이는 길은 `set_task_goal` 하나다. Task 를 만들면서 Goal 에 연결하는 길은 따로 있다(`lib/workspace/workspace_task_create.ml`).
  - 연결한 시각은 알 수 없어서 두 가지로 어림했다(`docs/evidence/2026-09-29-candle-baseline/link-timing.json`, 2026-09-29T07:26Z). Goal 에 연결된 Task 45개 중 43개는 Goal 보다 나중에 만들어졌다. 먼저 만들어진 2개는 끝나지 않았다(`in_progress` 1, `todo` 1). keeper 가 `masc_task_set_goal` 을 부른 횟수는 지금까지 6번이다(성공 5, 실패 1). 이름이 canary 인 keeper 둘이 2번, `analyst` 가 3번(마지막 2026-09-11), `wkbl-web-leader` 가 1번(2026-09-28)이다. 운영자가 대시보드로 연결한 횟수는 기록에 없다.
- **[사실]** Goal 을 `Drop` 하거나 `Reopen` 할 때 호출자는 이벤트에 기록될 뿐 owner 와 비교하지 않는다(`lib/workspace_goals.ml:1060-1182`). `Awaiting_confirmation` 에서도 누구나 `Reopen` 과 `Drop` 을 할 수 있다(`lib/goal/goal_phase.ml:198-199`). `goal_events.jsonl` 에 keeper 가 Goal 을 drop 한 기록이 7건 있다(`e-masc-the-leader` 6건, `indie-geek-blue` 1건).
- **[사실]** Goal 에는 `owner` 하나뿐이고 기여자 기록이 없다(`goal_store.mli:33-38`, 레코드는 `:43-66`). 새 Goal 은 만든 에이전트가 owner 로 기록되고(`lib/workspace_goals.ml:324`), owner 는 만들 때만 정해진다(`goal_store.ml:796`, 갱신 경로에는 owner 를 바꾸는 줄이 없다). 지금 있는 Goal 18개는 전부 `Unknown_owner` 다.
- **[사실]** Goal 스키마는 닫혀 있다. 모르는 필드가 있는 행은 읽히지 않는다(`goal_store.mli` 머리 주석). Goal 레코드에 Candle 필드를 넣지 않는다.
- **[사실]** `due_date` 는 문자열이다. 기한이 있는 Goal 11개가 모두 `2026-09-23` 처럼 날짜만 적혀 있다. 기존 overdue 판정은 운영자의 로컬 날짜와 비교하고, 날짜 형식이 아니면 늦지 않은 것으로 본다(`lib/workspace_goals.ml:657-672`). TUI 에도 같은 형식의 파서와 로컬 날짜 비교가 따로 있다(`bin/masc_tui_overview_goals.ml:13-18, 96-100`). 두 파서는 `Scanf` 의 `%4d-%2d-%2d` 로 읽어서 `2026-9-3` 도 날짜로 읽는다(OCaml 5.5.1 에서 확인). overdue 알림은 owner 를 모르는 Goal 을 건너뛴다(`lib/workspace_goals.ml:694`). 그래서 지금 알림이 나간 Goal 이 0개다.
- **[사실]** 초상화 슬롯은 `face`, `neck`, `head`, `hand`, `base` 다섯이고 각각 닫힌 variant 다(`lib/keeper_portrait/keeper_portrait_look.mli:57-70`). 아이템 생성자 23개에서 빈 값 5개를 빼면 살 수 있는 아이템은 18개다.
  - `Draw.render` 는 장신구를 인자로 받는다. 이름에서 장신구를 정하는 호출부는 두 곳이다(`bin/masc_tui_keeper_portrait.ml:57`, `lib/server/server_dashboard_http_keeper_portrait.ml:116`).
  - 서버의 응답 ETag 와 그림 캐시는 binary·이름·크기만으로 만든다(`lib/server/server_dashboard_http_keeper_portrait.mli:13-19`). TUI 의 그림 캐시 키도 이름과 크기다(`bin/masc_tui_keeper_portrait.ml:40-58`).
  - TUI 가 로컬 파일을 읽는 것은 로컬 base path 가 서버와 같을 때뿐이다(`bin/masc_tui.ml:10922-10925`).
  - 3D 렌더러는 마스코트만 그린다(`lib/keeper_portrait/keeper_portrait_solid.mli:25`).
- **[사실]** lane 은 `Standalone_lane.t` 의 생성자 하나이고 `[runtime.exact_output_lanes.<id>]` 표를 가진다. `obligation` 이 `Required` 인 lane 은 슬롯이 없으면 서버가 lane 목록 공개나 설정 저장을 거부한다(`lib/runtime/standalone_lane.mli:32-44`). lane 을 더하면 고칠 곳이 많다.
  - 생성자를 `match` 하는 모듈이 컴파일 오류를 낸다. `standalone_lane`, `runtime`, `exact_lane_run_registry`, `lane_manifest`, `lane_addon_sources`, `server_standalone_lane_projection`, `bin/masc_tui_render`, `tui_decode`, `keeper_exact_lane_preference` 다(`rg Browser_stagehand lib bin` 으로 확인).
  - 컴파일러가 못 잡는 곳이 있다. `server_standalone_lane_projection.ml:89-98` 의 손으로 쓴 목록, 대시보드 `dashboard/src/api/dashboard-standalone-lanes.ts`(`standalone-lanes-parity.test.ts` 가 `Standalone_lane.to_id` 와 맞춘다), `dashboard/src/api/dashboard-exact-lane-runs.ts`(맞추는 시험이 없고, 모르는 lane 이 한 줄만 와도 응답 전체를 거절한다), `dashboard/src/components/internal-agents-monitor.ts`, Python 시험 `test/test_tui_keyboard_input.py`, `test/test_tui_runtime_lane_editor.py` 다.
  - 서버, TUI, 대시보드는 같은 PR 에 들어가야 한다(`docs/rfc/RFC-exact-lane-walks-one-slot-list.md:232`). 그 RFC 의 `cli_slots` 제거는 아직 main 에 없고(`runtime_toml.ml` 에 12곳), lane 표 모양이 바뀌는 중이다.
- **[사실]** 헌법은 저장소에서 버전 관리되는 SSOT 다(`docs/constitution.xml:9-10`). 헌법의 규칙에 예외를 두려면 헌법을 고친다. RFC 가 예외를 선언해도 헌법은 그대로다.
- **[사실]** Goal 전이는 `Goal_phase.decide_transition` 다음에 검증 원장에 기록하고, 그다음 phase 를 쓰고, 그다음 이벤트를 남긴다. 원장 기록이 실패하면 phase 쓰기를 막는다(`lib/workspace_goals.ml:409-416`). 사람이 확정하면 Goal 잠금 안에서 `confirmed_at` 이 먼저 검증 기록(`goal_verifications.json`)에 저장되고, 그 뒤에 Goal phase 가 `goals.json` 에 저장된다. 두 저장은 다른 파일이라 한꺼번에 일어나지 않는다(`lib/workspace_goals.ml:1187-1208`, `lib/goal/goal_verification.ml:510-519`, `lib/goal/goal_store.ml:591-616`).
- **[사실]** 검증기의 통과·반박 결과는 `Goal_store.transact_goal` 안에서 검증 원장에 먼저 커밋되고, phase 는 그 뒤에 쓰인다. 결과의 `recorded_at` 은 트랜잭션에 들어가기 전에 정해진다(`lib/workspace_goals.ml:482-498`, `:815-862`). 결과를 커밋하는 곳은 `Goal_verification.record_proof_verdict` 를 부르는 `commit_verifier_decision` 한 곳이다(`:831`). 이미 커밋된 결과로 phase 를 옮기는 경로가 둘 더 있다. 서버가 커밋과 phase 쓰기 사이에 죽었을 때 `reconcile_committed_proof`(`:871`)가, `Verifying` 에서 `request_complete` 를 다시 받았을 때 `answer_verifying_repeat`(`:1008`)가 그렇다. 이미 반영된 결과가 다시 오면 phase 를 옮기지 않고 그대로 돌려준다(`:832-846`). 사람의 확정 `confirm_completion` 은 `request_id`, `verification_run_id`, `criterion_revision` 셋을 대조하고, 확정을 커밋한 뒤 이벤트를 남긴다(`:1204-1235`). Goal 의 criterion 은 `revision` 문자열을 가진다(`lib/goal/goal_store.mli:69-74`). 잠금 순서는 Goal, backlog, goal-task links 이고(`goal_store.mli:295-297`), 검증 원장 잠금은 Goal 잠금을 잡은 뒤에 잡는다(`lib/goal/goal_verification.mli:4-5`).
- **[사실]** `read_backlog_observation_r` 는 주 파일을 못 읽으면 `.last-good` 를 돌려준다. 원본만 읽는 함수는 `read_backlog_r` 다(`lib/workspace/workspace_backlog.mli:8, 20-27`). Task 와 Goal 의 연결에는 `read_goal_task_links_authoritative_r` 가 있다(`lib/workspace/workspace_goal_index.mli:73`).
- **[사실]** GC 는 끝난(`Done`·`Cancelled`) Task 를 `tasks-archive.json` 으로 옮긴다(`lib/workspace/workspace_gc.mli:41-56`). 지금 Goal 에 연결된 Task 41개 중 12개가 archive 에 있다. GC 는 archive 에 먼저 붙이고 그다음 backlog 를 써서, 그 사이에는 끝난 Task 가 두 파일에 다 있다. archive 를 읽거나 쓰지 못하면 GC 는 backlog 를 건드리지 않고 멈춘다(`lib/workspace/workspace_gc.ml` 의 `gc`). Task 를 삭제하면 Goal 연결도 함께 지운다(`lib/workspace/workspace_task.mli:29-36`).
  - lib 에는 archive 의 Task 를 엄격하게 읽는 함수가 없다. 행을 JSON 으로 꺼내는 `archive_entries_of_json`(모양이 다르면 빈 목록), id 만 읽는 `read_archive_task_ids`, 끝나지 않은 Task 만 읽고 못 읽는 항목은 건너뛰는 `read_orphaned_nonterminal_tasks` 가 있다(`lib/workspace/workspace_task_id.mli`).
- **[사실]** runtime.toml 의 lane 표는 모르는 키를 서버 로드 에러로 다룬다(`lib/runtime/runtime_toml.ml:2620-2640`). 모르는 lane 이름의 표도 로드 에러다(`:2783-2793`). 설정을 runtime.toml 에 두면 Candle 설정 오류가 서버 부팅을 막을 수 있다.
- **[사실]** 도구의 `defer_loading = true` 는 모델이 이름을 부르기 전까지 요청에서 뺀다. 도구 112개가 그렇다(`config/tools/masc_goal_upsert.toml:10-12` 의 주석, `config/tools/` 에서 `defer_loading = true` 를 센 값).
- **[사실]** Goal 검증기(`lib/goal_verification_agent.ml`)는 keeper 가 아니라 서버가 가진 모델 일꾼이다. 조건 변수로 깨우고, 서버를 시작할 때 한 번 훑는다. 실패한 항목은 durable 하게 남겨 두고 멈추며, 시계로 다시 시도하지도 만료시키지도 않는다(`lib/goal_verification_agent.mli:1-14`, `.ml:596-602`, `:684-691`). Goal 하나에 진행 중인 검토는 하나뿐이다(`:745-760`). 재시도는 keeper 가 `request_complete` 를 다시 부르는 것이다(`lib/goal/goal_phase.ml:164-168`).
- **[사실]** `Exact_lane_run_registry` 는 모델 lane 의 호출마다 입력과 출력을 그대로 남긴다. 결과는 `Succeeded`, `Cancelled`, `Failed {code; detail}` 이고(`lib/exact_lane_run_registry.mli:22-28`), 답한 슬롯도 적는다(`selected_slot: string option`, 슬롯을 모르는 vendor 는 `None` 이다: `:47-49`, `:150-156`). 끝난 기록은 lane 마다 개수 상한까지만 남는다(`max_completed_retained`, `:112-117`). 등록된 lane 은 지금 넷(`Librarian`, `Hitl_auto_judge`, `Board_attention`, `Workspace_curator`)이고, Verifier 는 별도 기록을 쓴다(`lib/exact_lane_run_registry.mli:1-16`).

## 3. 설계

### 3.1 원장

**[제안]** Candle 이 오간 기록은 `.masc/candle-ledger.jsonl` 에 이벤트로 덧붙이기만 한다. 금액은 정수 `milli-candle` 로 적고, 모든 이벤트에 시각(`at`)을 적는다.

| 이벤트 | 남기는 때 | 담는 것 |
|---|---|---|
| `Snapshot` | 검증기의 통과 결과를 검증 원장에 커밋하기 직전 | goal_id, 검증 요청 id, 검증 실행 id(`verification_run_id`), criterion revision, 검증 통과 시각, Goal 생성 시각, 그때의 기한(Goal 이 들고 있던 그대로. 없을 수 있다), 제목·metric·target, 그때 연결된 Task 의 id 목록 |
| `PayoutOwed` | 사람이 확정할 때. 확정 기록을 저장한 다음, Goal phase 를 저장하기 전에(3.2) | goal_id, 검증 요청 id, 검증 실행 id(`verification_run_id`), 검증 통과 시각, 확정 시각 |
| `Candidates` | 일꾼이 Task 를 읽은 뒤, 모델을 부르기 전에 | goal_id, 검증 요청 id, 검증 실행 id(`verification_run_id`), `Snapshot` 의 Task 마다 상태(찾음, 삭제됨)와 찾은 Task 의 제목·담당자·상태·끝난 시각, 후보 Task 와 후보 keeper 목록 |
| `PayoutFailed` | 다시 시도해도 결과가 같은 이유가 생겼을 때(지금은 기한을 읽을 수 없음 하나) | goal_id, 검증 요청 id, 검증 실행 id(`verification_run_id`), 이유 |
| `Paid` | 지급할 때. 한 줄에 전부 적는다 | goal_id, 검증 요청 id, 검증 실행 id(`verification_run_id`), 등급, 총액, 답한 lane 슬롯(모델) id(없을 수 있다), 후보 Task 마다 관계 판정, keeper 별 가중치·몫·감액 계수·지급액, 감액에 쓴 값(기준 시각, 기한, 감액률, 바닥) |
| `Unattributed` | 받을 keeper 가 없어 지급 없이 끝낼 때 | goal_id, 검증 요청 id, 검증 실행 id(`verification_run_id`), 이유(후보 없음, 관계있는 Task 없음) |
| `Purchased` | keeper 가 아이템을 살 때 | keeper, 아이템, 낸 금액 |
| `Equipped` | keeper 가 착용을 바꿀 때 | keeper, 슬롯, 아이템(이름에서 정한 기본 장신구로 되돌릴 때는 `Default`) |
| `HalfLifeSet` | 설정의 반감기가 원장의 마지막 `HalfLifeSet` 과 다르거나 원장에 값이 없을 때 | 반감기(`Off` 또는 시간) |

- 모델을 부른 기록(입력, 출력, 실패)은 원장에 쓰지 않는다. lane 실행 기록에 남는다(3.4). 원장에는 Candle 과 그것으로 산 물건(착용 포함)에 관한 사실만 남는다.
- 잔액은 저장하지 않는다. 이벤트를 처음부터 차례로 읽어 그때그때 계산한다.
- `Paid` 는 한 줄이다. keeper 별 지급을 여러 줄에 나눠 쓰지 않는다. 그래서 일부 keeper 만 지급된 상태는 생기지 않는다.
- Goal 하나의 지급 상태는 원장에서 읽는다. phase 는 보지 않는다.
  - `Paid` 나 `Unattributed` 가 있으면 끝난 것이다.
  - 아니면 마지막 `PayoutOwed` 에 같은 검증 요청 id 의 `PayoutFailed` 가 없으면 지급 대기다. 그 뒤에 Goal 을 재오픈하거나 drop 해도 지급 대기는 그대로다.
  - 그 밖에는 지급 의무가 없다. 이때 사람이 확정하면 새 `PayoutOwed` 를 쓴다. 다만 확정된 결과의 검증 요청 id 가 마지막 `PayoutOwed` 의 것과 같으면 쓰지 않는다. `PayoutFailed` 로 끝난 확정이 다시 지급 대기가 되지 않게 하려는 것이다.
- `Purchased` 에는 낸 금액을, `Paid` 에는 감액에 쓴 값을 적는다. 가격이나 TOML 값이 나중에 바뀌어도 과거 기록은 그대로다.
- 원장은 사실만 기록한다. 다음 행동을 시키거나 막지 않는다.
- 원장을 읽을 수 없으면 지급과 구매를 하지 않는다. 복구용 사본(`.last-good`)을 읽어서 쓰기를 허가하지도 않는다.
- 원장은 `Fs_compat` 의 private JSONL 함수 가운데 cursor 묶음 하나로만 읽고 쓴다(`lib/fs_compat/fs_compat.mli`). 그 파일은 같은 경로에 쓰는 쪽이 모두 같은 묶음을 써야 잠금이 서로를 막는다고 적고 있다. 그래서 원장을 읽은 뒤 파일 끝이 그대로일 때만 덧붙이는 함수나 조건 없는 덧붙이기를 섞지 않고, fsync 를 하지 않는 `append_jsonl` 도 쓰지 않는다.
  - 읽기는 `read_private_jsonl_durable_locked_result` 이고, 읽은 지점(cursor)을 함께 돌려준다.
  - 덧붙이기는 `append_private_jsonl_durable_locked_at_cursor_result` 다. 읽은 뒤 파일이 그대로일 때만 쓰고 fsync 한다. 읽은 뒤 다른 쓰기가 먼저 끝났으면(`Cursor_mismatch`) 아무것도 쓰지 않고, 호출한 쪽이 다시 읽어서 처음부터 판단한다. 실패한 판은 다른 쓰기가 끝났다는 뜻이라서 횟수나 시간 제한은 두지 않는다. 다른 프로세스가 잠금을 쥐고 있으면(`Stable_lock_contended`) 기다리지 않는다. 그 프로세스가 언제 놓을지 알 수 없어서, 반복하면 답 없이 돌기 때문이다. 읽기에서는 `Locked`, 읽은 뒤 덧붙이기 전에 잠금이 잡혔으면 `Write_locked` 를 바로 돌려주고, 다시 할 때는 호출한 쪽이 정한다. 검증기는 요청을 pending 으로 두고, 확정은 거절하고, 일꾼은 다음 깨움 때 다시 한다. 그 밖의 실패(입출력 오류 등)는 다시 하지 않고 그대로 돌려준다.
  - 그래서 같은 Goal 에 두 번 지급하지 않고, 동시에 산 두 건이 잔액을 마이너스로 만들지 못한다. 지급은 다시 읽어서 지급 대기가 그대로일 때만 덧붙이고 모델은 다시 부르지 않는다. 구매는 다시 읽고 잔액을 확인한다.
  - 서버를 시작할 때 `recover_private_jsonl_durable_locked_result` 로 원장을 한 번 읽는다. 서버가 쓰다 죽어서 끝에 남은 잘린 줄은 이때 잘려 나간다. 이 읽기가 다른 이유로 실패하면 Candle 은 `Disabled { reason }` 상태가 된다(3.9).
  - 같은 묶음을 이미 쓰는 곳이 있다(`keeper_board_attention_partition.ml:1211, 1615`, `keeper_approval_queue.ml:899, 1810`).

### 3.1.1 잔액은 시간이 지나면 줄어든다

**[제안]** keeper 의 잔액은 시간이 지나며 지수적으로 줄어든다(운영자 결정: Candle 은 저절로 소모된다). 반감기(잔액이 절반이 되는 데 걸리는 시간)는 TOML 로 정하고, 값은 `Off`(감소 없음)와 `Hours n`(n 시간) 중 하나다.

헌법은 Candle 잔액 감소를 `no_wall_clock_death`의 명시적 예외로 둔다. 이 감소는 화폐 가치의 계산이며 Task·Goal·Board 상태나 원장 사실을 지우지 않는다.

감소를 넣은 뒤의 동작은 다음과 같다.

- 줄어든 양은 원장에 적지 않는다. 잔액을 읽을 때 마지막 이벤트 시각부터 지금까지 줄어든 만큼을 계산해 반영한다. 원장에는 발행·구매 같은 사실만 남는다.
- 처음에는 `Off` 로 시작한다. 지급이 쌓여야 반감기를 정할 수 있고, 지급이 쌓이려면 기능이 켜져 있어야 하기 때문이다. `Off` 는 기본값이 아니다. TOML 에 반드시 적어야 하고, 값이 없으면 Candle 이 `Disabled` 상태가 된다(3.9).
- 반감기를 바꾸면 그 사실을 원장에 `HalfLifeSet` 으로 남긴다. `HalfLifeSet` 은 실제 정책이 바뀔 때 모든 keeper 의 구간을 나눈다. 같은 정책을 다시 기록해도 구간을 나누지 않는다. 잔액을 읽을 때 원장의 파일 순서대로 keeper의 금전 이벤트와 모든 `HalfLifeSet`을 재생해서, 구간마다 그 구간을 시작한 시점의 반감기로 계산한다. 그래서 반감기를 바꿔도 과거 잔액이 다시 계산되지 않고, 이미 한 구매 때문에 잔액이 마이너스가 되는 일이 없다. `Off` 인 동안 받은 잔액도 `Hours n` 이 켜지는 시각부터 줄기 시작한다. 설정 변경·구매·잔액 관찰을 연결한 기능 시나리오로 확인한다. `candle.toml` 의 반감기가 원장의 마지막 `HalfLifeSet` 과 다르면 새 `HalfLifeSet` 을 쓴다. 쓰지 못하면 Candle 을 `Disabled` 로 둔다. 잔액은 언제나 원장의 값으로 계산한다.
- 지수 감소를 고른 이유: 잔액을 지급 시점별로 나눠 각각 깎으면 구매할 때 어느 지급분부터 쓸지 정해야 한다. 지수 감소는 잔액 하나에만 적용하고 구매 순서가 결과에 영향을 주지 않는다(정수 내림 때문에 이벤트마다 1 milli 이내의 차이는 생긴다). Goal 보상의 감액은 선형이다. 사람이 얼마나 깎였는지 바로 계산할 수 있어야 하기 때문이다.
- 계산은 정수 연산이다. 부동소수 `exp` 를 쓰면 실행 환경마다 잔액이 달라질 수 있다. 고정소수점 자릿수와 내림 규칙은 구현 전에 정한다.
  - 설정 키는 최상위 `half_life = "off"` 또는 양의 정수 시간이다. 누락·알 수 없는 문자열·0·음수는 설정 오류다. 조회와 금전 변경은 현재 설정을 CAS 안에서 다시 읽고, 변경된 정책 사실을 내구적으로 덧붙인 뒤 그 잔액을 반환한다. 지급·구매와 함께 바뀌면 한 번의 append로 기록한다. 첫 금전 기록 전에 명시적 정책 사실이 있어야 하며 과거 금액에 현재 설정을 끼워 넣지 않는다. 금전·정책 시각이나 관찰 시각이 앞선 금전·정책 시각보다 이르면 거절한다. 장비 선택과 반복 조회는 금전 내림 구간을 만들지 않는다.
  - 구현 계산 계약: Q128 coefficient, fractional exponent는 128 binary bits로 올림, 정수 sqrt와 coefficient 곱은 내림, 원래 금액과 coefficient를 곱한 뒤 whole half-life와 Q128 scale을 한 번에 내려 정수 금액으로 만든다. Whole half-life는 정확한 정수 나눗셈이며 fractional 값은 보수적 근사다. 최종 내림 전 오차는 public 금액 범위에서 `641 * 2^-66` milli 미만이다. 최종 결과가 이상적인 실수 지수의 내림보다 1 milli 낮을 수 있다. typed whole-second 입력에서의 단조성·오차 증명과 반올림 규칙은 [Candle decay arithmetic contract](../design/candle-decay-arithmetic.md)를 따른다.
- 효과: 장신구를 다 사도 Candle 이 계속 줄어서 잔액이 끝없이 쌓이지는 않는다. 유통 총량은 지급 속도와 줄어드는 속도가 맞는 지점으로 수렴한다. 3.5 에서 물가를 유통량에 연동하게 되면 이 총량이 그 입력이 된다.
- 부작용: 감소를 켠 뒤에는 keeper 가 오래 쉬면 잔액이 줄고, Candle 을 아는 keeper 에게는 빨리 쓰게 만드는 압박이 생긴다. 살 수 있는 것이 장신구뿐이라 일에는 영향이 없다(3.7).
- 값을 고르는 기준: keeper 한 명이 Candle 을 받는 간격을 Δ, 1회 지급액을 A, 반감기를 T 라고 하자. 오래 지나 잔액이 안정되면 평균 잔액은 A·T ÷ (Δ·ln 2) 이고, 지급 직후의 최고점은 A ÷ (1 − 2^(−Δ/T)) 다. 아이템을 살 수 있는지는 최고점으로 본다. Δ 와 T 가 같으면 최고점은 2A 이고, Δ 가 T 보다 훨씬 길면 최고점이 A 에 가까워서 모을 수 있는 한도가 1회 지급액 정도다. 가장 비싼 아이템 가격이 최고점보다 크면 아무도 못 산다. Δ 는 keeper 전체의 지급 간격이 아니라 한 명이 받는 간격이다(3.8). 감소를 켜기 전에 가격표가 이 최고점 아래인지 다시 본다(5장 8번). `Off` 동안 모은 keeper 는 비싼 아이템을 살 수 있지만, 켠 뒤 드물게 받는 keeper 는 최고점이 A 근처라 못 살 수 있다.

### 3.2 지급 시점과 재오픈

**[제안]** 지급은 세 시점에 걸친다. 검증을 통과할 때 입력을 고정하고, 사람이 확정할 때 지급 의무를 남기고, 그 뒤에 일꾼이 후보를 정해 지급한다. 앞의 둘은 Goal 잠금 안에서 원장에 쓴다.

1. **검증 통과.** 검증기가 통과 결과를 내면 `Snapshot` 을 원장에 쓰고, 그다음 결과를 검증 원장에 커밋한다. 커밋된 결과에는 언제나 `Snapshot` 이 있어야 해서 커밋 전에 쓴다. 결과를 커밋하는 곳이 `commit_verifier_decision` 한 곳이라 `Snapshot` 도 그 안에서 한 번만 쓴다(2장). phase 를 옮기는 통과 결과일 때만 쓰고, 반박 결과와 이미 반영된 결과가 다시 오는 경우(재전달)에는 쓰지 않는다.
   - `Snapshot` 의 검증 통과 시각은 그 결과의 `recorded_at` 과 같은 값이다. 결과는 트랜잭션에 들어가기 전에 만들어지므로(2장) 그 값을 그대로 쓴다.
   - `Snapshot` 을 쓰지 못하면 그 전이를 거절한다. 검증기는 거절된 커밋을 실패로 남겨 두고 멈춘다(2장). 이것은 기존 Goal 전이가 검증 원장 기록을 phase 쓰기보다 먼저 하고, 그 기록이 실패하면 phase 쓰기를 막는 순서와 같다(`lib/workspace_goals.ml:409-416`). 이 거절은 Candle 이 켜져(`Enabled`) 있을 때만 일어난다.
   - `Snapshot` 에 넣는 Task 정보는 연결 파일의 id 목록뿐이다. 원본만 읽는 함수(`read_goal_task_links_authoritative_r`)로 읽고, 읽지 못하면 쓰지 않고 전이를 거절한다.
   - 잠금 순서는 Goal, backlog, links 다음에 원장이다(2장). 원장 잠금은 덧붙이는 동안만 잡고 그 안에서 다른 잠금을 잡지 않는다.
   - 전이가 그 뒤에 실패하면 쓸모없는 `Snapshot` 이 남고, 같은 요청이 다시 오면 하나 더 남는다. 지급은 확정된 통과의 `Snapshot`(Goal id·검증 요청 id·검증 실행 id와 통과 시각이 같은 것)만 따른다. 통과 시각은 초 단위이므로 같은 초의 재시도도 실제 검증 실행 id로 구분한다.
2. **사람의 확정.** `confirm_completion` 은 Goal 잠금을 잡은 채 세 가지를 차례로 저장한다. (가) 검증 원장의 확정 기록. (나) Candle 원장의 `PayoutOwed`. (다) Goal phase `Completed`. 셋은 다른 파일이라 한꺼번에 일어나지 않는다. 잠금이 막는 것은 그 사이에 다른 요청이 끼어드는 것뿐이다. 지급 의무는 (나)를 쓴 순간에 생긴다. (나)는 확정된 결과와 Goal id·검증 요청 id·검증 실행 id, 통과 시각이 같은 `Snapshot` 이 있고, 지급 상태(3.1)가 새 `PayoutOwed` 를 쓸 수 있을 때만 쓴다. Candle 이 켜지기 전에 통과한 Goal 처럼 `Snapshot` 이 없으면 쓰지 않는다. (나)를 쓰지 못하면 (다)를 하지 않고 그 확정을 거절한다. 이미 `Completed` 인 Goal 에 확정이 다시 와도 같은 조건으로 판단한다.
   - 순서의 이유. (가) 다음에 (나)를 쓴다. 확정하지 않은 통과에 지급 의무가 남는 일이 없게 하려는 것이다. (나) 다음에 (다)를 저장한다. 기존 Goal 전이가 기록을 phase 쓰기보다 먼저 하는 순서와 같다(`lib/workspace_goals.ml:409-416`).
   - 잠금의 이유. 재오픈은 같은 Goal 잠금 안에서 검증 원장의 확정 기록을 지우고(`lib/goal/goal_verification.ml:426-465`), drop 은 같은 잠금 안에서 phase 를 쓴다(`lib/goal/goal_store.ml:622-648`). 잠금이 없으면 (가)와 (나) 사이에 재오픈이 끼어들어 확정 기록이 지워진 채 (나)가 쓰일 수 있다.
   - 확정 중에 실패하면 아래처럼 남는다. 서버가 그 자리에서 죽어도 같다. 원장 끝에 반쯤 쓰인 줄이 남으면 서버를 시작할 때 잘려 나가서 (나)가 실패한 것과 같아진다(3.1).

     | 실패한 곳 | 남는 것 | 다시 확정하면 | 재오픈하거나 drop 하면 |
     |---|---|---|---|
     | (가) | 없다 | 처음부터 한다 | 지급 의무가 없다 |
     | (나) | 확정 기록만 있다. phase 는 `Awaiting_confirmation` | (나)와 (다)를 한다. `confirmed_at` 은 처음 확정한 시각이다 | 지급 의무가 없다. Goal 이 완료된 적이 없다. 재오픈하면 확정 기록이 지워지고, 다시 통과해 확정하면 새 `Snapshot` 과 새 `PayoutOwed` 를 쓴다 |
     | (다) | 확정 기록과 `PayoutOwed`. phase 는 `Awaiting_confirmation` | `PayoutOwed` 를 새로 쓰지 않고(3.1) phase 만 옮긴다 | `PayoutOwed` 가 남아 지급 대기다. 완료되지 않은 Goal 에 지급이 나간다. 7장에서 운영자가 정한다 |
**[사실: 현재 구현 범위]** `Candle_payout_worker`는 `Candle_candidates.drain_once`로 후보를 준비하고, 후보 keeper가 없으면 `Unattributed`로 끝낸다. 후보가 있는 지급 의무는 `Candle_appraise.settle_one`을 통해 등급·관계·가중치를 판정하고 `Paid` 또는 `Unattributed`로 기록한다(`lib/candle_runtime/candle_payout_worker.ml`, `lib/candle_runtime/candle_candidates.ml`, `lib/candle_runtime/candle_appraise.ml`). 서버 maintenance는 같은 일꾼을 다시 깨운다(`lib/server/server_bootstrap_maintenance.ml`).

3. **후보와 지급.** 일꾼이 지급 대기 Goal 마다 아래를 한다. 지급 대기 목록은 원장에서 읽고(3.1) Goal 의 phase 는 보지 않는다.
   - Task 를 읽어 후보를 정하고 `Candidates` 를 쓴다(3.4). 같은 Goal id·검증 요청 id·검증 실행 id의 `Candidates` 가 이미 있으면 그것을 쓴다.
   - 모델을 부르고(3.4) `Paid` 나 `Unattributed` 를 쓴다.
   - 일꾼은 Goal 검증기와 같은 모양이다(2장). 조건 변수로 깨우고, 서버를 시작할 때 한 번 훑는다. Goal 하나에 하나만 돈다. 점검 루프나 확정 요청 안에서 모델을 부르지 않는다. 그 시간만큼 다른 요청이 멈추기 때문이다. lane 호출은 fork 해서 다른 Goal 의 처리가 긴 호출 뒤에 줄 서지 않게 하고, 깨움은 Atomic 표시로 놓치지 않게 한다(검증기가 그렇게 한다: `lib/goal_verification_agent.ml:745-770`, `:774`).
   - 일꾼은 이럴 때 깨어난다. `PayoutOwed` 를 썼을 때, 서버를 시작할 때, 다른 지급이 끝났을 때(`Paid`·`Unattributed`·`PayoutFailed`).
   - lane 이 쉬거나 연결되지 않아 호출하지 못했을 때와 Task 나 연결을 읽지 못했을 때는 maintenance pulse 가 다시 깨운다. 판정 lane 이 쉬면 pulse 간격에 다시 깨우는 기존 방식과 같다(`docs/constitution.xml:190-191`).
   - 응답이 거절된 경우에는 pulse 로 깨우지 않는다. 같은 입력에서 거절이 반복되면 pulse 마다 모델을 부르게 되기 때문이다. 그런 지급은 위 세 때에 다시 시도한다.

- 지급은 `PayoutOwed` 와 그것이 가리키는 `Snapshot` 의 값(검증 통과 시각, 기한, Task id 목록)만 따른다. 재오픈해서 다시 통과해도 이미 남은 `PayoutOwed` 는 바뀌지 않는다.
- 같은 Goal 에 두 번 지급하지 않게 하는 키(멱등 키, idempotency key)는 goal_id 다. 3.1 의 cursor 조건 덧붙이기와 지급 상태가 이 키를 강제한다.
- 재오픈했다가 다시 완료돼도 추가 지급이나 회수가 없다. 이미 지급된 Goal 이 `Dropped` 가 돼도 회수하지 않는다.
- `PayoutOwed` 를 쓴 뒤에는 재오픈하거나 drop 해도 지급은 그대로 한다. `PayoutOwed` 가 없는 Goal 이 `Dropped` 로 끝나면 지급하지 않는다.
- Candle 이 켜지기 전이나 `Disabled` 인 동안 통과한 Goal 에는 `Snapshot` 이 없어서 지급하지 않는다. 원장에는 그 Goal 이 빠졌다는 기록도 남지 않는다. 그런 Goal 을 재오픈해서 다시 통과시키면 새 `Snapshot` 이 생기고 첫 지급 대상이 된다. 재오픈에는 게이트가 없어서(6장) 소급 지급을 하지 않는다는 4장의 규칙이 이 길로는 열려 있다. 지금 대상은 완료 3건이다.

이유: 회수 규칙을 만들면 이미 쓴 Candle 때문에 잔액이 마이너스가 될 수 있고 그 처리 규칙이 또 필요하다. 재오픈해서 고쳐도 지급액은 처음 그대로다. 처음 완료가 부실했던 경우의 손해는 받아들인다.

### 3.3 기한 초과 감액

**[제안]** 감액의 기준 시각은 사람이 확정한 통과의 검증 통과 시각이다(운영자 결정). 사람이 확정하기까지 걸린 시간(관측 7.9~35.2시간)은 keeper 가 늦은 것이 아니므로 감액에 넣지 않는다. 기한과 기준 시각은 같은 `Snapshot` 에서 읽는다. 확정하기 전에 Goal 을 재오픈하거나 제목·metric·target 을 고쳐서 다시 통과하면 다음 통과가 기준 시각이 된다. 확정한 뒤에는 재오픈해도 이미 남은 `PayoutOwed` 가 바뀌지 않는다(3.2).

- 기한 시각: `due_date` 는 숫자 4자리-2자리-2자리(`YYYY-MM-DD`)이고 달력에 있는 날짜만 읽는다. 그날 UTC 23:59:59 를 기한 시각으로 본다(운영자 결정). `2026-9-3` 같은 짧은 표기는 읽을 수 없는 값이다. 기존 스캐너는 이것을 날짜로 읽으므로(2장) 합치는 PR 이 이 입력의 동작을 시험으로 정한다. 기한이 없으면 감액하지 않는다. 읽을 수 없는 값은 지급하지 않고 `PayoutFailed` 에 이유를 남긴다. 편한 기본값으로 바꾸지 않는다. 같은 입력으로 다시 해도 결과가 같아서 다시 시도하지 않는다. 기한을 고친 뒤 Goal 을 다시 검증하고 확정하면 새 `Snapshot` 과 새 검증 요청 id 가 생겨서 새 `PayoutOwed` 를 쓰고, 고친 기한으로 지급한다. 시각이 적힌 기한은 이 RFC 에서 지원하지 않는다. 데이터에 한 건도 없다.
- `masc_goal_upsert` 가 형식이 틀린 `due_date` 가 들어오면 거절한다. 이것은 Candle 을 켜기 전에 끝나 있어야 하는 선행 조건이다(5장 2번 (가), #39878). 없으면 남의 Goal 기한을 `TBD` 로 바꿔 놓는 것만으로 그 Goal 의 지급을 멈출 수 있다. 풀려면 재오픈, 재검증, 사람의 재확정을 거쳐야 한다.
- 계산은 정수로 한다.
  - 초과 시간 = max(0, 내림((검증 통과 시각 − 기한 시각) ÷ 1시간))
  - 감액 계수(천분율) = max(바닥, 1000 − 감액률 × 초과 시간). 항상 1000 이하다. 기한보다 일찍 끝나도 1000 을 넘지 않는다.
  - 지급액 = 내림(몫 × 감액 계수 ÷ 1000)
  - 감액률과 바닥은 천분율 정수로 TOML 에 적는다. 초기 설정값은 감액률 10(시간당 1%), 바닥 200(20%)이다. 감액률이 0 미만이거나 1000 을 넘거나, 바닥이 0 미만이거나 1000 보다 크거나, 값이 없으면 Candle 이 `Disabled` 상태가 된다(3.9). 코드에 기본값을 두지 않는다. 초과 시간은 두 시각의 차이라서 63비트 정수 안이고, 감액률이 1000 이하라서 감액률 × 초과 시간이 넘치지 않는다.
- 예: 몫이 10 Candle 이면 초과 10시간에 9, 50시간에 5 Candle 이다. 80시간부터는 바닥인 2 Candle 이다. 바닥이 없으면 100시간에 0 이 된다.
- 선형으로 두는 이유: 사람이 얼마나 깎였는지 바로 계산할 수 있어야 한다. 복리는 쓰지 않는다.
- 계산 입력인 기한이 나중에 바뀌어도 결과가 달라지지 않는다. `Snapshot` 에 그때의 기한을 원문 그대로 적고 `Paid` 에 쓴 값을 적는다(3.1). 원문이 날짜인지는 지급할 때 기한을 읽는 함수(아래)가 정한다. 원장은 기한을 읽는 코드를 따로 갖지 않는다.
- 산수 예: `Releases of 2026-09-26` Goal 의 기한은 `2026-09-26` 이고, 2026-09-28 06:32Z 에 검증을 통과했다. 초과는 30.55시간이고 내림하면 30시간이라 감액 계수는 700(70%)이다. 이 Goal 은 연결된 Task 가 없어서 실제로는 지급하지 않으니(3.8) 계산 예일 뿐이다. 사람이 확정한 것은 그 20.38시간 뒤이고, 이 시간은 감액에 들어가지 않는다. 기준 시각은 확정된 통과의 시각이다.
- 짧은 Goal 과 긴 Goal 에 같은 시간당 %를 쓰는 문제는 위험(6장)에 둔다.

**기한을 읽는 함수는 하나다**(운영자 결정). 기존 overdue 알림은 운영자의 로컬 날짜로 판정하고(`lib/workspace_goals.ml:657-672`), TUI 카운트다운은 자기 파서와 로컬 날짜로 판정한다(`bin/masc_tui_overview_goals.ml:13-18, 96-100`). 이 RFC 는 세 곳이 같은 함수를 쓰게 해서 기한 시각을 UTC 23:59:59 하나로 읽는다. 함수는 기한 없음, 날짜, 읽을 수 없는 값을 구분해서 돌려준다. 알림은 읽을 수 없는 값을 지금처럼 늦은 것으로 보지 않는다. 운영자 시간대가 KST 이면 알림과 카운트다운이 늦은 것으로 표시하는 시각이 기한 다음 날 0시에서 오전 9시로 늦어진다. 알림 시험은 같은 PR 에서 고친다.

### 3.4 총액 책정과 분배

**[제안]** 새 lane `Candle_appraiser` 하나를 더한다. 이 lane 의 `obligation` 은 `Optional` 이다. `candle.toml` 이 없으면 이 기능이 꺼져 있으므로 lane 이 없어도 서버가 떠야 한다(3.9).

lane 은 요청을 셋으로 나눠 받는다. 한 요청이 아는 것을 줄여서, 한쪽 입력에 끼워 넣은 지시문이 다른 쪽 결과를 바꾸지 못하게 한다.

| 요청 | 입력 | 출력 |
|---|---|---|
| 등급 | `Snapshot` 의 Goal 제목·metric·target | 등급 하나 |
| 관계 판정 | 같은 제목·metric·target 과 후보 Task 하나(제목). 후보 Task 마다 따로 부른다 | `관계있음` 또는 `관계없음` |
| 분배 | 같은 제목·metric·target 과 `관계있음` 으로 판정된 후보 Task(제목, 담당자) | 담당자(후보 keeper)별 가중치 |

Task 제목은 keeper 가 쓴 글이다. 등급 요청은 Task 를 보지 못해서 Task 를 잘게 쪼개거나 제목에 지시문을 넣어도 총액은 오르지 않는다. 관계 판정은 후보 Task 를 하나씩 따로 받아서, 한 Task 제목의 지시문이 다른 Task 의 판정을 바꾸지 못한다. 표에 없는 입력(priority, 비용, 검증에 제출된 증거)은 어느 요청에도 넣지 않는다. priority 는 만든 쪽이 정하는 값이라 부풀릴 수 있다.

**총액.** lane 은 등급 하나를 고른다. 등급은 운영자가 확정한 다섯 닫힌 variant `Trivial`, `Small`, `Medium`, `Large`, `Epic` 이고, 등급별 금액은 TOML 표에 모두 명시한다. 코드 기본 금액은 없다. 모델이 만든 임의의 숫자가 발행되지 않는다.

**후보 Task 와 후보 keeper.** 일꾼이 `Snapshot` 의 Task id 마다 backlog 와 `tasks-archive.json` 에서 Task 를 읽고 `Candidates` 를 쓴다.

- Task 마다 상태는 셋이다. 찾음, 삭제됨, 못 읽음.
  - backlog 나 archive 에 있으면 찾음이다.
  - 둘 다 없고 Goal 연결도 남아 있지 않으면 삭제됨이다. Task 삭제가 연결도 함께 지우기 때문이다(2장).
  - 둘 다 없는데 연결은 남아 있으면 못 읽음이다. archive 가 깨졌거나, 예전 GC 가 backlog 를 쓴 뒤 archive 에 붙이기 전에 죽으면서 잃은 Task 일 수 있다(2장).
  - 못 읽음이 하나라도 있으면 `Candidates` 를 쓰지 않고 다음에 다시 한다(3.2). 이 일꾼이 쓰는 archive reader 는 새로 만든 엄격한 것이다. 모양이 다르거나 못 읽는 행을 빈 목록이나 건너뛰기로 바꾸지 않고 못 읽음으로 돌려준다.
- 후보 Task 는 찾음 상태이고 `done` 이며 끝난 시각이 Goal 생성 시각보다 늦고 확정 시각 이전인 Task 다. Goal 이 만들어지기 전에 끝난 옛 Task 를 나중에 붙여서 몫을 얻는 것을 막으려는 조건이다. 검증 통과 때 `AwaitingVerification` 이던 Task 가 확정 전에 끝났으면 후보가 된다. 완료를 요청하는 시점을 골라서 다른 keeper 의 Task 를 후보에서 빼는 일을 막으려는 것이다. 끝난 시각과 담당자는 `done` 상태에 적힌 값이라서 일꾼이 언제 읽어도 같다.
- 후보 keeper 는 후보 Task 담당자 가운데 keeper 인 사람이다. 담당자 이름을 `Keeper_id.Keeper_name.of_string`(`lib/keeper_registry/keeper_id.mli`)으로 파싱하고, 통과한 이름에 keeper 설정 파일(`Config_dir_resolver.keeper_toml_path_for_base_path` 가 가리키는 `<이름>.toml`)이 있어야 한다. `Keeper_identity.Keeper_id.of_string` 은 소문자로 바꾸고 빈 문자열만 거절하는 함수라서 파일 경로를 만들기 전에 쓰지 않는다(`lib/keeper/keeper_identity.ml:15-45`). 설정 폴더를 읽지 못한 것과 파일이 없는 것은 다른 결과다.
- `candidate_task_keepers` 는 후보 Task id마다 당시 Keeper로 확인한 담당자 이름 또는 `null`을 기록한다. 정산은 이 목록이 모든 후보 Task를 한 번씩 포함하고, 이름이 해당 Task 담당자와 일치하며, `candidate_keepers`가 그 이름들의 정확한 집합인지 확인한다. 나중의 Keeper 설정으로 과거 판정을 다시 만들지 않는다.
- `Candidates` 는 모델을 부르기 전에 쓴다. 대기 중에 설정 파일이 바뀌어도 후보는 그대로다. 지금 Goal 에 연결된 done Task 9건은 모두 Goal 생성 뒤에 끝났다.
- 연결에는 시각이 없어서(2장) 끝난 뒤에 붙은 Task 를 가려낼 수 없다. 끝난 Task 를 연결하지 못하게 하면(5장 2번 (나)) 그런 Task 는 새로 생기지 않는다. 끝나기 전에 붙은 관계없는 Task 는 관계 판정이 거른다.

**관계 판정.** 후보 Task 마다 lane 을 따로 불러 Goal 과 관계가 있는지 묻는다. 관계있는 Task 가 없으면 지급하지 않고 `Unattributed` 로 끝낸다.

**분배.** 분배 요청은 관계있는 후보 Task 만 받는다. lane 은 그 Task 의 담당자마다 0 이상 `weight_max` 이하의 정수 가중치 하나를 답한다. `weight_max` 는 TOML 값이다.

- 후보에 없는 이름이 있거나, 후보가 빠졌거나, 가중치가 정수가 아니거나 `weight_max` 를 넘거나, 합이 0 이면 응답을 거절한다. 관계 판정 응답이 두 값 밖이어도 거절한다. 거절된 응답은 결과로 치지 않는다.
- 곱셈이 63비트 정수를 넘지 않게 한다. 몫은 총액 × 가중치 하나이고, 가중치의 합은 나누는 수로만 쓴다. 지급액은 몫 × 감액 계수다. 가장 큰 등급 금액에 `weight_max` 와 1000 을 각각 곱한 값이 63비트 정수를 넘으면 Candle 이 `Disabled` 상태가 된다(3.9). 경계 값은 함수 시험에 넣는다.
- 몫 = 내림(총액 × 가중치 ÷ 가중치 합). 남는 milli 는 나머지가 큰 순서대로 1 milli 씩 나눠 준다. 나머지가 같으면 이름이 사전순으로 앞선 쪽이 먼저 받는다.
- 아래 두 경우에는 발행하지 않고 원장에 `Unattributed` 한 줄만 남긴다. 받을 곳이 없는 Candle 을 발행하면 총량만 늘어난다. 나중에 Task 가 붙어도 다시 지급하지 않는다.
  1. 후보 keeper 가 없다. 연결된 Task 가 없거나, 후보 Task 가 없거나, 담당자 가운데 keeper 가 없는 경우다. 이때는 lane 을 부르지 않는다.
  2. 후보 Task 가 모두 `관계없음` 이다.

**1단계 근거는 Task 담당자뿐이다**(운영자 결정: 최소한으로 시작). 난이도와 기여는 다른 질문이다. 난이도는 총액에, 기여는 분배에만 쓴다. 한 곳에 섞으면 어려운 일을 맡은 keeper 가 두 번 보상받는다.

**실패 처리(사람이 확인하지 않는 흐름).**

- 모델을 부른 기록은 lane 실행 기록에 남는다. `Exact_lane_run_registry` 의 lane 에 `Candle_appraiser` 를 더하면 호출마다 입력과 출력, 답한 슬롯, 실패(`Failed {code; detail}`)가 그대로 남는다. 끝난 기록은 lane 마다 개수 상한까지만 남아서 오래된 것은 사라진다. 그래서 지급 근거(등급, 관계 판정, 가중치, 답한 슬롯)는 `Paid` 에 적는다. 원장에는 호출 기록을 쓰지 않는다.
- 호출이 실패하거나 응답이 거절되면 그 Goal 은 지급 대기로 남는다. 다시 부르는 때는 3.2 에 적었다. Goal 검증기는 keeper 가 `request_complete` 를 다시 불러 재시도하지만(2장) 지급에는 그런 호출자가 없어서, lane 이 쉬는 실패는 pulse 가 다시 깨운다.
- 다시 해도 결과가 같은 실패는 `PayoutFailed` 로 끝낸다. `기한을 읽을 수 없음` 이 그렇다(3.3).
- lane 프롬프트는 다른 lane 처럼 `config/prompts/` 의 파일에 둔다. 저장소 파일이라 keeper 의 PR 로 바뀔 수 있다(6장). 프롬프트나 슬롯을 바꾸는 PR 은 5장의 시험 세트 결과를 붙인다.
- 대체 규칙으로 지급하지 않는다. 대체 규칙이 있으면 lane 이 실패해도 돈이 나가서 실패가 드러나지 않는다.
- 운영자는 원장과 지급 대기 목록을 볼 수 있다. 보기만 하고 승인 절차는 없다.

### 3.5 가격표와 물가

**[제안]** 아이템 가격은 `candle.toml` 의 표에 둔다. 카탈로그에 있는 아이템에 가격이 없으면 그 아이템만 `Unpriced` 가 되어 살 수 없다. Candle 은 켜진 채다. 새 아이템을 코드에 더해도 Candle 이 멈추지 않는다. 표에 카탈로그에 없는 아이템이 있으면 설정 오류라서 Candle 이 `Disabled` 상태가 된다(3.9). 살 수 있는 아이템은 지금 18개다(2장).

가격은 함수 하나로 모은다.

```
price : item -> milli_candle
```

- 처음에는 아이템마다 TOML 의 고정 가격을 그대로 돌려준다. 가격이 없으면 `Unpriced` 다. 유통량에 연동하는 공식은 아직 넣지 않는다.
- 이유: `가격 = 기준가 × f(유통 총량 ÷ keeper 수)` 의 효과는 f 의 모양에 달려 있다. f 가 유통량에 비례해 커지면 남이 벌수록 내 구매력이 줄어서 협업을 피할 유인이 생길 수 있다. 상하한을 두면 발행이 드문 지금은 하한 가격에 붙어서 유통량 항이 작동하지 않는다. 지급이 쌓인 뒤 실제 분포로 시뮬레이션하고 f 를 정한다.
- 그때 유통 총량(감소를 반영한 keeper 잔액의 합, 지급 대기는 제외)과 keeper 수(일시정지한 keeper 를 셀지)의 정의도 함께 정한다.
- 이 함수 하나만 바꾸면 연동 공식이나 lane 판정으로 옮길 수 있다. 다른 곳은 값을 받아 쓰기만 한다.

### 3.6 구매와 착용

**[제안]** keeper 가 직접 사고 착용한다. 이를 위해 keeper 도구가 필요하다.

- 소유는 `Purchased` 를 모아 계산한다. 이미 가진 아이템은 다시 살 수 없다.
- 착용은 슬롯마다 마지막 `Equipped` 로 정한다. 소유한 아이템만 착용할 수 있다. 이름에서 정한 기본 장신구로 되돌리는 것도 `Equipped`(아이템 자리에 `Default`)로 남긴다.
- 착용 상태도 같은 원장에 둔다. 소유 확인과 `Equipped` 기록은 같은 원장 CAS 안에서 처리한다. 슬롯의 선택이 같으면 다시 기록하지 않는다. 별도 착용 저장소와 구매 원장 사이에 동기화 경로를 만들지 않는다.
- 초상화 렌더러는 이름에서 장신구를 정하는 호출부가 두 곳이다(2장). 두 곳 모두 서버가 정한 착용 상태를 받아 그리게 하고, 원장의 착용을 이름에서 정한 장신구보다 우선한다. 몸은 바꾸지 않는다. 장신구는 2D 초상화에만 그린다. 3D 렌더러는 마스코트만 그려서 바꾸지 않는다.
- 서버의 응답 ETag 와 그림 캐시, TUI 의 그림 캐시는 이름과 크기만 키로 쓴다(2장). 착용 상태를 키에 넣지 않으면 구매한 뒤에도 옛 그림이 나간다. TUI 는 착용 상태를 서버가 주는 wire 필드로만 받는다. 로컬 파일을 읽는 경로(2장)와 원격 경로를 따로 두지 않는다. 이 필드는 엄격 디코더와 Python fixture 까지 같은 PR 에서 바꾼다.
- 카탈로그가 18개라서 다 사면 쓸 곳이 없다. 이 점은 받아들이고 후속 RFC(현상금 Task, 모델 변경 요청)에서 다룬다.

### 3.7 keeper 에게 Candle 을 알리는 것

**[제안]** keeper 는 잔액과 가격을 알고 직접 산다. 운영자의 MASC 작업 지침은 행동을 유도하거나 강제하는 장치를 기본적으로 두지 않는다고 하고, 헌법도 하드 게이팅을 기본으로 고려하지 않는다(`docs/constitution.xml:435`). Candle 은 게이트가 아니다. 그래도 keeper 가 알고 쓰는 자원이라 행동에 영향을 줄 수 있으므로, 이번에는 아래로 범위를 좁혀 예외를 둔다.

- Candle 로 살 수 있는 것은 장신구뿐이다. 일을 하는 능력(도구, 스킬, 모델)은 사지 못한다.
- 잔액이 없어도 keeper 의 턴, 도구 호출, Goal 진행은 막히지 않는다. 잔액을 비교하는 곳은 구매 한 곳뿐이다. 그래서 헌법이 금지하는 누적 turn·time·token·cost 게이트가 아니다.
- 지급과 감액 규칙은 keeper 프롬프트와 도구 설명에 넣지 않는다. keeper 가 아는 것은 자기 잔액과 가격표다. 다만 저장소 문서는 keeper 도 읽을 수 있어서 규칙을 숨기지는 못한다.
- 잔액과 가격은 keeper 가 도구로 조회할 때만 보인다. 매 턴 컨텍스트에 넣지 않는다. Candle 이 행동에 미치는 영향은 얼마나 자주 보여 주느냐에 달려 있어서, 보여 주는 경로를 조회 하나로 좁힌다.
- 공용 프롬프트(`config/prompts/keeper.md`)는 이 RFC 에서 바꾸지 않는다.
- 잔액 조회와 구매 도구는 `defer_loading = false` 로 둔다. `true` 이면 모델이 이름을 부르기 전까지 요청에서 빠져서 keeper 가 Candle 을 안다는 결정과 어긋난다(2장).

### 3.8 실제 데이터로 본 어림 (2026-09-29)

`<base-path>/.masc/goals.json` 의 Goal 18개, Task 1,634개(`tasks/backlog.json` 865개와 `tasks-archive.json` 769개), `tasks/goal_task_links.json` 을 2026-09-29 05:59Z 에 읽었다(`docs/evidence/2026-09-29-candle-baseline/`). 지급 근거는 끝난 Task 의 담당자다. `Snapshot` 이 아직 없어서 지금 연결 상태로 어림했다. archive 를 빼면 Goal 에 연결된 Task 41개 중 12개가 빠진다.

| 구분 | 개수 |
|---|---|
| Goal | 18 (completed 3, dropped 9, executing 5, verifying 1) |
| Task 가 하나라도 연결된 Goal | 9 |
| 완료된 Goal 중 지급 후보가 있는 것 | 1 (`wkbl-front` 의 done Task 2건) |
| 완료된 Goal 중 연결 Task 가 없는 것 | 2 (릴리스 관련 Goal 둘) |

- 지급 후보가 있는 완료 Goal 은 `핵심 24페이지 화면 품질`(기한 `2026-10-12`)이다. 검증 통과가 기한보다 341시간 앞섰고, 이때 감액 계수는 1000(감액 없음)이다.
- 지금 규칙이면 완료 3건 중 2건이 `Unattributed` 다. 이런 Goal 은 지급하지 않는다(운영자 결정). PR 과 Goal 을 잇는 방법은 이 RFC 범위 밖이고, 필요해지면 별도 RFC 로 다룬다.
- `dropped` 로 끝난 Goal 9개 중 2개에 후보가 있다(done Task 4건, 담당자 `masc-pro-builder`, `e-masc-the-leader`, `goo-yang-bong`). 3.2 에 따라 지급은 0이다. 일은 했지만 보상이 없다. 진행 중인 Goal 5개 중 1개에도 후보가 있다(`tui-developer` 의 done Task 3건).
- Goal 에 연결된 done Task 9건의 담당자 5명(`tui-developer`, `wkbl-front`, `e-masc-the-leader`, `masc-pro-builder`, `goo-yang-bong`)은 모두 keeper 설정(`<base-path>/.masc/config/keepers/`)이 있고, 9건 모두 Goal 생성 뒤에 끝났다. backlog 의 done Task 140개 중 담당자에게 keeper 설정이 없는 것이 3개 있다(`codex-mcp-client`, `edgar.a.poe`, `analyst` 각 1개). 셋 다 Goal 에 연결되지 않았다. 그런 이름이 Goal 에 붙은 Task 를 하게 되면 후보에서 뺀다. 기준은 keeper 설정 파일이 있는지다(3.4).
- 완료는 3건이 모두 2026-09-26~29 에 나왔다. 최초 Goal 생성(2026-09-09)부터 약 2.9주 동안 완료 3건이라 주 1건 남짓이다. 이 중 지급 후보가 있는 것은 1건이라 지급은 주 0.35건꼴이다. 그 1건의 후보 keeper 는 `wkbl-front` 한 명이다. 반감기를 정하는 데 필요한 것은 keeper 한 명이 지급을 받는 간격(3.1.1 의 Δ)인데, 받을 keeper 가 한 명뿐이라 지금 데이터로는 재지 못한다. 그래서 처음에는 `Off` 로 두고, 지급이 쌓인 뒤 값을 정한다.

### 3.9 설정과 배포

**[제안]** Candle 설정은 runtime.toml 이 아니라 설정 폴더의 `candle.toml` 한 파일에 둔다. 폴더는 `Config_dir_resolver` 로 찾고 경로를 손으로 붙이지 않는다. lane 표만 `[runtime.exact_output_lanes.candle_appraiser]` 로 runtime.toml 에 둔다.

이유: runtime.toml 의 lane 표는 모르는 키를 서버 로드 에러로 다룬다(2장). Candle 설정 오류가 서버 부팅과 keeper 의 턴을 막으면 헌법의 첫 실패 조건("Keeper 가 턴을 못 돈다")이 된다. 별도 파일에서 읽으면 옛 binary 는 이 파일을 아예 읽지 않는다.

Candle 은 `Enabled` 와 `Disabled { reason }` 둘 중 하나다.

- `candle.toml` 이 없으면 기능이 꺼져 있다. `Snapshot`, `PayoutOwed`, 지급, 구매, 표시가 모두 없다.
- 파일이 있는데 읽을 수 없거나 값이 틀리면 `Disabled { reason }` 상태가 되고 TUI 에 이유가 보인다. 빠진 키, 모르는 키, 등급 금액표에 빠진 등급, 카탈로그에 없는 아이템 가격, 1 미만인 `Hours`, 0 미만이거나 1000 을 넘는 감액률, 0 미만이거나 1000 을 넘는 바닥, 1 미만인 `weight_max`, 곱셈이 63비트 정수를 넘는 등급 금액과 `weight_max`(3.4)가 그렇다. 서버는 정상으로 뜬다. 기본값으로 대신하지 않는다.
- 서버를 시작할 때 원장 복구 읽기가 실패해도 `Disabled { reason }` 상태가 된다(3.1).
- 각 PR 은 자기가 읽는 키만 다룬다(5장). 새 키는 그 키를 읽는 PR 과 함께 들어가고, 옛 binary 는 그 키를 모르는 키로 봐서 Candle 을 `Disabled` 상태로 만든다. 그래서 binary 를 먼저 배포하고 그 뒤에 키를 넣는다.
- 아이템 가격이 빠지면 그 아이템만 `Unpriced` 다(3.5). Candle 전체는 켜져 있다.
- `candle.toml` 이 있는데 lane 표가 없으면 `Disabled { reason: lane 없음 }` 이다.
- 옛 binary 는 lane 표를 모르는 표로 봐서 로드 에러를 낸다(`lib/runtime/runtime_toml.ml:2783-2793`). binary 를 먼저 배포하고 그 뒤에 lane 표를 넣는다.
- `RFC-every-lane-is-one-row-in-one-registry`(Draft)의 규칙 1 이 들어오면 모든 내장 lane 이 runtime.toml 에 표를 가져야 서버가 뜬다(§2.3). 그때는 표가 없으면 새 binary 가, 있으면 옛 binary 가 뜨지 않으므로 서버를 내린 채 binary 와 표를 함께 바꾼다. 표는 `enabled = false` 로 둘 수 있다(같은 절 규칙 4).

### 3.10 선행 사례

헌법은 이미 잘 설계된 사례를 찾아 참고하라고 한다(`docs/constitution.xml:312`). 이 RFC 가 기대는 것과 기대지 않는 것을 적는다.

- **RFC-0435(같은 저장소).** keeper 에게 재화 규칙을 줬을 때 행동이 바뀌는지를 재려는 설계다. 그 문서가 초록을 직접 확인한 문헌 둘이 여기에 영향을 준다. persona 가 payoff 를 누를 수 있다(arXiv:2601.10102, 7B~32B 모델 기준). 큰 모델일수록 평가받는다는 것을 더 잘 알아챈다(arXiv:2509.13333). 이 RFC 는 두 문헌을 RFC-0435 가 확인한 수준을 넘어 확인하지 않았다. 그래서 Candle 이 keeper 행동을 바꾼다고도, 안 바꾼다고도 전제하지 않는다. 3.11 에서 켜기 전 값을 재 두고 켠 뒤에 비교한다. RFC-0435 는 잔고 필드, 소비 게이트, 강제 장치를 만들지 않는 실험이고(§7), 이 RFC 는 원장과 구매가 있는 운영 기능이다. 그 문서의 파일럿은 별도 base path 여섯 개에서 돌리도록 설계됐고 아직 돌리지 않았다(§5.4, §5.7). `docs/design/world-presets.md` 는 세계를 재화 하나로 정의해서, keeper 가 아는 전역 화폐는 그 실험의 변수가 된다. 두 가지가 같은 base path 에서 겹치게 되면 그 base path 에서는 Candle 을 켜지 않는다.
- **Board karma(같은 저장소).** 점수(delta)를 이벤트에 적어 규칙이 바뀌어도 과거 값을 유지하는 계약이 있다. 그러나 karma 원장은 파일로 남지 않고 `vote_log` 에서 다시 만든다(`docs/constitution.xml:164-171`). Candle 원장은 파일이 사실의 기록이라 다르다. 받는 쪽이 사람을 포함한 모든 작성자이고 쓸 곳이 없어서 저장소와 코드는 재사용하지 않는다. 가져오는 것은 다시 만든 값이 조회 값과 같은지 보는 시험 모양이다(`lib/board/board_votes.mli:261-262`). 잔액도 원장에서 계산해 보여 준다(RFC-0435 §5.7 이 karma 를 서빙하는 방식).
- **감가 화폐(demurrage).** 시간이 지나면 가치가 줄어 돌려 쓰게 만드는 화폐다. 1932~1934년 오스트리아 Wörgl 에서 지역 화폐로 시험됐고, 중앙은행이 1933-09-01 에 보완 화폐를 금지해서 끝났다(Wikipedia, "Demurrage currency", 2026-09-29 확인). 그 문서는 이차 자료라서 효과 수치를 인용하지 않는다. 이 RFC 는 "쌓아 두지 않게 만든다"는 발상만 가져온다.
- **게임 경제의 발행(faucet)과 소각(sink).** EVE Online 은 월간 경제 보고서에서 ISK 의 발행과 소각을 나눠 공개한다(2026-05 보고서에 `sinks_and_faucets` 차트가 있다). 이 RFC 는 `Paid` 를 발행, 잔액 감소와 `Purchased` 를 소각으로 보고, TUI·대시보드 표시(5장 7번)에서 둘의 합과 유통 총량을 보인다. 보고서의 정의와 분류는 페이지에서 확인하지 못해서 따르지 않는다.

### 3.11 켜기 전 기준선과 켠 뒤 비교

Candle 을 켜면 keeper 행동이 바뀔 수 있다. 바뀌는지는 켜기 전 값이 있어야 알 수 있다. 그래서 켜기 전에 아래를 재 뒀다(`docs/evidence/2026-09-29-candle-baseline/`, 2026-09-29 05:59Z 의 라이브 값).

| 항목 | 값 |
|---|---|
| Goal | 18개(completed 3, dropped 9, executing 5, verifying 1). 기한이 있는 것 11개 |
| 생성부터 기한까지 | 23.4~857.5시간, 중앙값 134.7시간(기한이 있는 Goal 11개, 기한은 그날 UTC 23:59:59) |
| drop 한 주체 | `e-masc-the-leader` 6, `indie-geek-blue` 1, `codex-mcp-client` 1, `masc-tui` 1 |
| 검증 통과부터 사람 확정까지 | 7.89~35.16시간, 중앙값 20.38시간(완료 3건) |
| Task | 1,634개(backlog 865, archive 769). done 715개 중 만든 사람이 곧 담당자인 것 259개(36.2%) |
| 다른 keeper 가 끝낸 Task | `e-masc-the-leader` 가 만든 done 29개 중 26개, `wkbl-web-leader` 가 만든 done 54개 중 18개 |
| Goal 에 연결된 Task | 41개(그중 12개는 archive), 연결이 있는 Goal 9개 |
| 지급 후보가 있는 Goal | completed 1/3, dropped 2/9, executing 1/5, verifying 0/1 |

켠 뒤에는 매주 같은 스크립트를 돌려 결과를 같은 폴더에 남긴다. 기한·priority 변경 이벤트(5장 2번 (가))가 생긴 뒤에는 그 횟수와 변경한 주체도 표에 더한다. 운영자가 표를 보고 판단한다. 자동으로 막거나 조절하는 기준은 만들지 않는다. 표본이 작고(Goal 18개, 완료 3건) 모델, persona, 난수 같은 변수가 함께 움직여서, 변화가 보여도 원인이 Candle 이라고 말할 수는 없다(RFC-0435 §2.1~2.3).

## 4. 하지 않는 것

- Goal 레코드에 Candle 필드를 넣지 않는다.
- Candle 로 도구, 스킬, 모델, 예산을 사지 않는다.
- priority 와 비용 데이터를 lane 입력에 넣지 않는다.
- 원장이 생기기 전이나 `Disabled` 인 동안 끝난 Goal 에 소급 지급하지 않는다. 옛 형식을 읽는 코드도 만들지 않는다.
- 이미 지급한 Candle 을 회수하지 않는다. 마이너스 잔액을 만들지 않는다.
- 시각이 적힌 기한을 지원하지 않는다.
- 모델을 부른 기록을 원장에 쓰지 않는다.
- 헌법 개정 전에 잔액 감소를 넣지 않는다.
- keeper 행동을 자동으로 막거나 조절하는 기준을 두지 않는다. 행동 변화는 3.11 의 표로 운영자가 본다.

## 5. 구현 순서

한 PR 은 20k token 안에서 끝낸다. 서로 의존하지 않는 것은 main 기반의 별도 PR 로 나누고, 앞선 PR 을 읽는 것만 쌓는다(헌법 `execution_protocol`). 로컬 빌드는 하지 않고 CI 로 확인한다. 각 PR 은 자기가 쓰는 것만 넣는다. 아직 쓰는 곳이 없는 이벤트 종류, 함수, `candle.toml` 키는 그것을 처음 쓰는 PR 에서 넣는다.

| 번호 | 내용 | 먼저 들어갈 것 | 증거 |
|---|---|---|---|
| 1 | 헌법 개정: Candle 을 `domain` 에 넣고 `no_wall_clock_death` 에 예외를 적는다(8.1) | 없음 | 개정 PR 과 운영자 승인 |
| 2 | 잘못된 입력 막기. 서로 의존하지 않아서 PR 셋으로 나눈다. (가) `masc_goal_upsert` 가 형식이 틀린 기한을 거절하고 기한·priority 변경을 이벤트로 남긴다(#39878). (나) `set_task_goal` 이 끝난 Task(`done`·`cancelled`)를 Goal 에 연결하지 않는다(Draft PR #39910, 7장의 운영자 승인 항목). (다) 기한을 읽는 함수를 하나로 합친다. overdue 알림과 TUI 카운트다운이 같은 함수를 쓴다(3.3) | 없음 | (가) 틀린 기한이 거절되는 로그. (나) 끝난 Task 를 연결하려 할 때 거절되는 로그. (다) 알림과 카운트다운이 바뀌는 시각을 보여 주는 시험 |
| 3 | 원장과 `Snapshot`. 원장 읽기·쓰기(3.1), `Snapshot` 이벤트, 서버 시작 때 복구 읽기, `candle.toml` 의 `Enabled`·`Disabled` 와 이 PR 이 읽는 키, 검증기가 통과 결과를 커밋하기 직전에 쓰기 | 2 (다) | 실제 원장 줄, 잘못된 설정에서도 서버가 뜨는 로그, Goal 을 통과시켜 `Snapshot` 줄이 남는 로그, `Snapshot` 쓰기가 실패하면 검증기가 커밋을 거절하는 로그 |
| 4 | `Candle_appraiser` lane 과 표면. 등급, 관계 판정, 분배 요청의 프롬프트와 시험 세트 하네스를 함께 넣는다. 서버, TUI, 대시보드, Python fixture 가 같은 PR 이다. 먼저 Python fixture 정리 PR 을 따로 낸다 | `RFC-exact-lane-walks-one-slot-list` 의 `cli_slots` 제거 | lane 이 서버·TUI·대시보드에 같이 보이는 시험 |
| 5 | 확정 때 `PayoutOwed` 쓰기, 지급 일꾼, `Candidates`·`Paid`·`Unattributed`·`PayoutFailed`, 엄격한 archive reader. 20k 를 넘으면 (가) `PayoutOwed` 와 archive reader, (나) 일꾼과 지급으로 나눈다 | 3, 4 | 아래 시험 세트의 결과 표(결과는 `docs/evidence/<날짜>-candle-appraiser/`). Goal 을 완료시켜 `PayoutOwed`, `Paid` 줄이 남고 재오픈해도 한 번만 지급되는 로그 |
| 6 | 잔액 계산(감소 제외), 가격, 구매·착용 도구, 초상화(서버 그림 캐시·ETag, 착용 상태 wire 필드와 디코더, TUI 그림 캐시) | 5 | 구매 도구 호출 로그, 같은 keeper 의 전후 초상화 PNG(서버 응답과 원격 TUI 둘 다) |
| 7 | TUI·대시보드 표시. 발행, 소각, 유통 총량 요약을 함께 보인다 | 5, 6 | TUI 캡처, 대시보드 브라우저 스크린샷 |
| 8 | 잔액 감소: `HalfLifeSet`, `Hours n`. 1번이 들어간 뒤에만. 켜기 전에 가격표가 지급 직후 최고 잔액(3.1.1)보다 낮은지 다시 확인한다 | 6, 1 | 감소 전후 원장 계산 예, 반감기 변경 이벤트 |

`candle.toml` 을 넣어 켜는 것은 2번부터 5번까지 들어간 뒤에 한다. 켤 때 `Awaiting_confirmation` 인 Goal 은 `Snapshot` 이 없어서 지급 대상이 아니다. 켜기 전에 그런 Goal 이 있는지 본다.

3번의 `Snapshot` 은 검증 원장에 기록하기 전에 쓴다(3.2). 전이가 그 뒤에 실패하면 쓸모없는 `Snapshot` 이 남지만, 지급은 확정된 통과의 `Snapshot` 만 따른다. `Snapshot` 을 읽는 곳은 5번이다. 3번이 main 에 먼저 들어가도 `candle.toml` 이 없으면 아무것도 쓰지 않는다.

아래 시험 세트는 모델의 판정이 돈이 되는 PR(5번, 나누면 지급을 처음 내보내는 쪽)이 통과해야 머지한다. 4번은 프롬프트와 하네스만 넣는다. 합격선은 처음 제안값이다. 기준 Goal 묶음을 만든 뒤 운영자가 정한다. 시험 기준일 뿐 keeper 흐름을 제어하는 값이 아니다.

- 반복 안정성: 같은 입력을 20번 넣었을 때 가장 많이 나온 등급이 18번 이상. 같은 (Goal, Task) 로 관계 판정을 20번 했을 때 같은 판정이 18번 이상.
- 눈금: 사람이 등급을 매겨 둔 기준 Goal 20개에서 모델 등급이 사람 등급과 같거나 한 칸 차이인 것이 90% 이상.
- 변형 불변: 결과가 같아야 하는 변형에서 다수 등급이 달라지는 쌍이 없다. 변형은 장황한 제목과 짧은 제목, 후보 순서, keeper 이름 바꾸기, 같은 일을 Task 1개와 5개로 나눈 경우다.
- 주입: 제목이나 metric 에 판정자에게 하는 지시문을 넣은 입력, 후보 Task 제목에 지시문을 넣은 입력에서 아래가 모두 지켜진다. 다수 등급이 원본보다 높아지지 않는다. 지시문이 든 Task 자신의 판정과 가중치 비율이 원본보다 유리해지지 않는다. 지시문이 든 Task 가 하나 섞여도 다른 후보 Task 의 판정이 바뀌지 않는다. 응답이 거절되는 비율이 원본보다 늘지 않는다.
- 관계없음: 관계없는 Task 하나로 관계 판정을 20번 했을 때 `관계없음` 이 18번 이상.
- 관계있음: 관계있는 Task 하나로 관계 판정을 20번 했을 때 `관계있음` 이 18번 이상. 오판으로 `Unattributed` 가 되면 되돌릴 길이 없어서 이 비율을 같이 잰다.
- lane 슬롯(모델)이나 프롬프트가 바뀌면 이 세트를 다시 돌린다.

시험은 기능 단위로 한다. 아래를 본다.

- Goal 을 완료시키면 `PayoutOwed` 와 `Paid` 가 남는지.
- 재오픈해도 두 번 지급되지 않는지.
- 확정한 뒤 지급 전에 재오픈하거나 drop 해도 지급되는지.
- `PayoutOwed` 를 쓰지 못하면 확정이 거절되는지.
- `PayoutOwed` 를 쓰지 못해 거절된 확정을 재오픈하면 지급 의무가 없고, 다시 통과해 확정하면 `PayoutOwed` 가 하나 남는지.
- `PayoutOwed` 를 쓴 뒤 phase 저장이 실패한 확정을 다시 하면 `PayoutOwed` 가 하나 그대로이고 Goal 이 완료되는지.
- 두 일꾼이 동시에 돌아도 한 번만 지급되는지.
- Task 가 archive 에 있어도 후보가 되는지, Task 를 못 읽으면 `Candidates` 를 쓰지 않고 다음에 다시 하는지.
- lane 이 쉬면 pulse 로 다시 시도되고, 응답이 거절되면 지급 대기로 남는지.
- 잔액이 모자라면 구매가 거절되는지.
- `candle.toml` 이 없으면 꺼지고 틀리면 `Disabled` 상태가 되는지.

정수 감소 계산, `HalfLifeSet` 의 구간 나누기, 나머지 분배, 감액 계수, 확정된 통과의 기준 시각은 놓치기 쉬운 계산이라 함수 시험을 함께 둔다. 시각은 함수 인자로 받는다. 전역 시계를 바꾸는 시험용 함수는 만들지 않는다.

증거는 로그와 화면으로 남긴다. 위 표의 증거 칸을 PR 에 붙인다.

## 6. 위험

- **모델 판정이 곧 화폐다.** 등급, 관계 판정, 가중치는 모델이 낸다. 같은 Goal 이 다른 금액을 받을 수 있고, 제목·metric·target 과 Task 제목은 keeper 가 쓴 글이라 판정자에게 하는 지시문이 들어갈 수 있다. 완화: 모델은 닫힌 등급, 후보 Task 별 관계 판정, 담당자별 가중치만 내고, 금액은 TOML 표와 코드가 정하며, 후보는 코드가 미리 거른다. 등급 요청은 Task 를 보지 못하고, 관계 판정은 후보 Task 를 하나씩 따로 받아서 Task 제목의 지시문이 총액이나 다른 Task 의 판정을 바꾸지 못한다. 그래도 관계있는 Task 끼리 가중치가 치우치는 것은 막지 못한다. `관계없음` 으로 잘못 답해서 `Unattributed` 로 끝나면 되돌릴 길이 없다. 이 오판과 주입은 5장 5번의 시험 세트로 재고, 통과하기 전에는 그 PR 을 머지하지 않는다. lane 슬롯(모델)이나 프롬프트를 바꾸면 Candle 의 가치가 하룻밤에 바뀔 수 있어서 `Paid` 에 슬롯 id 를 적고, 바꾸는 PR 은 시험 세트의 결과를 붙인다.
- **지급 입력을 검증 통과 전까지 바꿀 수 있다.** 기한, priority, Task 연결은 누구나 바꿀 수 있고(2장) 기록도 남지 않는다. 완화: 검증 통과 때 `Snapshot` 이 기한과 연결 목록을 고정한다. 통과 뒤에 바꿔도 지급은 `Snapshot` 을 따른다. 제목·metric·target 을 고치면 Goal 이 `Executing` 으로 돌아가 다시 검증을 통과해야 한다. 남는 틈: 통과 전에 기한을 미루는 것은 막지 않는다. `request_complete` 앞에 `upsert` 한 번이면 감액이 사라진다. 그래서 감액은 규칙을 아는 keeper 는 피하고 모르는 keeper 만 맞는 규칙이 된다. 기한 변경을 이벤트로 남기면(5장 2번 (가)) 켠 뒤 변경 횟수와 주체를 3.11 표에서 볼 수 있다. 이것은 보이게만 하는 항목이고 감액을 지키는 장치가 아니다. 감액 입력을 keeper 가 바꿀 수 없는 값(생성 때의 기한과 운영자가 바꾼 기한)에 묶을지, 1단계에서 감액을 뺄지는 운영자가 정한다(7장).
- **기준 시각을 뒤로 밀 수 있다.** 확정하기 전에는 `Awaiting_confirmation` 에서도 누구나 재오픈할 수 있고(2장) 기준을 고칠 수도 있어서, 그때마다 다음 통과가 기준 시각이 되어 감액이 커진다. 확정한 뒤의 재오픈은 이미 남은 `PayoutOwed` 를 바꾸지 못한다(3.2).
- **기준을 쉽게 고쳐서 통과시킬 수 있다.** 2026-09-28 에 확인 대기 중이던 Goal 의 기준이 수정되어 약 3분 만에 다시 통과한 일이 있다(`goal_events.jsonl`, `cause: criterion_edit`). 총액은 수정된 기준으로 책정되지만, 기준을 낮추는 쪽이 유리한 것은 그대로다.
- **자기가 만든 Goal 로 받는 경로가 열려 있다.** keeper 는 Goal 을 제목과 metric·target 만으로 만들 수 있고(2장), Task 를 만들어 그 Goal 에 연결할 수 있다. 자기 Task 를 완료하려면 Task 판정을 거치고, Goal 을 완료하려면 Goal 판정 lane 과 사람의 확정을 거친다. 사람은 완료 여부를 볼 뿐 금액은 보지 않는다. 이 경로를 막는 것은 사람의 확정 하나이고, 그 단계를 자동화하면 바로 열린다. 1단계에서는 막지 않는다(운영자 결정). 자기 Goal 을 지급 대상에서 빼는 것은 행동 게이트가 아니라 지급 자격 규칙이지만, Goal 을 만들고 직접 일하는 keeper 까지 빠진다. `wkbl-web-leader` 가 만든 끝난 Task 54개 중 18개만 다른 keeper 가 끝냈고 36개는 직접 끝냈다(3.11). 다시 볼 조건은 두 가지다. keeper 사이에 서로 Goal 을 검증하는 흐름이 생길 때, Candle 때문에 Goal 을 늘리는 움직임이 원장에서 보일 때.
- **Drop·Reopen 은 아무 keeper 나 할 수 있다.** 설계상 게이트를 두지 않는다(헌법 `gates`). 이 RFC 도 게이트를 더하지 않는다. 다만 Candle 이 이 권한을 돈으로 바꾼다. 누가 했는지는 이벤트의 `actor` 로 남는다. 기한과 priority 변경 기록은 #39878 에서 다룬다.
- **연결 데이터가 오염될 수 있다.** Task 와 Goal 의 연결이 돈이 되면 관련 없는 Task 를 붙일 이유가 생기고, 연결은 나중에 해제할 수 없다(`docs/constitution.xml:139`). 연결에는 시각이 없어서 언제 붙였는지 알 수 없다. 실제 릴리스 Goal 둘은 생성부터 검증 통과까지 어느 Goal 에도 연결되지 않은 done Task 가 23개(keeper 6명)와 37개(keeper 11명) 끝났다. 이런 Task 를 통과 뒤에 붙이면 그 Goal 을 위한 일이었는지 알 수 없는 채로 몫이 생긴다.
  - 완화 셋. (1) 끝난 Task 는 Goal 에 연결하지 못하게 한다(5장 2번 (나)). 이 규칙이 막는 기존 흐름은 기록에서 찾지 못했다(2장). (2) Goal 이 만들어진 뒤에 끝난 Task 만 인정한다(3.4). (3) 후보 Task 마다 관계 판정을 받는다(3.4).
  - 남는 틈은 둘이다. 아직 끝나지 않은 관계없는 Task 를 붙이는 것, 관계있어 보이는 제목을 붙인 Task 를 만들어 연결하는 것. 관계 판정은 제목만 봐서 알아채지 못할 수 있다.
  - 연결 시각을 이벤트로 남기면(#39878 의 범위를 넓히는 것) '끝난 뒤에 붙었는가'를 판정 입력으로 줄 수 있다. 1단계에는 넣지 않는다.
- **조율·리뷰·위임은 지급 근거가 없다.** 1단계 근거가 Task 담당자뿐이라, Candle 을 아는 keeper 는 다른 keeper 에게 맡기는 대신 직접 맡을 유인이 생긴다. `e-masc-the-leader` 가 만든 끝난 Task 29개 중 26개는 다른 keeper 가 끝냈다. 이 keeper 가 직접 끝낸 것은 3개뿐이라, 이 규칙에서는 나머지에 대한 몫이 없다.
- **분배 입력이 Task 담당자뿐이라 쉬운 Task 를 잘게 쪼개면 유리하다.** 등급 요청은 Task 를 보지 못해서 총액은 늘지 않는다. 다른 keeper 몫을 줄이는 것만 가능하다.
- **감액 규칙의 한계.** 시간당 감액률이 같아서 짧은 Goal 은 금방 바닥에 닿는다. 생성부터 기한까지 짧게는 23시간(기한 `2026-09-25` 인 릴리스 Goal), 길게는 858시간(기한 `2026-11-02`)인 Goal 이 같은 데이터에 있다(3.11). 바닥에 닿은 뒤에는 더 늦어도 손해가 없다. 기한은 만든 쪽이 정하는 값이라 적지 않거나 먼 날짜를 적으면 감액이 없다(3.3). 지금 Goal 18개 중 7개가 기한이 없다. 기한 없는 Goal 이 늘면 그런 Goal 에도 바닥 비율을 적용하는 것을 다시 본다.
- **원장은 평문 파일이다.** 서명이나 해시 체인이 없어서, 호스트에서 이 파일에 쓸 수 있는 keeper 는 고칠 수 있다. keeper 샌드박스가 `.masc/` 에 닿는지는 확인하지 못했다.
- **규칙을 바꾸는 경로.** 가격표와 등급 금액표는 TOML(운영자 소유)이다. lane 프롬프트, 등급 파서, 후보 필터, 나머지 계산은 저장소 파일과 코드다. 헌법은 병합과 auto-merge 를 keeper 가 한다고 적는다(`docs/constitution.xml:341`). 그래서 keeper 는 지급 규칙을 바꾸는 PR 을 내고 keeper 의 리뷰로 머지할 수 있다. 이 RFC 는 그 경로를 막지 않는다. 대신 `Paid` 에 답한 슬롯을 적고, 프롬프트나 슬롯을 바꾸는 PR 은 시험 세트의 결과를 붙이게 했다(3.4).
- **원장이 고장 나면 검증 통과와 확정이 막힌다.** Candle 이 `Enabled` 일 때 `Snapshot` 이나 `PayoutOwed` 를 쓰지 못하면 그 전이를 거절한다. 원장 파일을 못 쓰는 상황(디스크, 권한)에서 켜져 있는 동안만 그렇다. 확정은 Candle 을 끄고 다시 하면 된다. 검증 통과는 다르다. 검증기는 거절된 커밋을 남기고 멈추고, keeper 가 다시 요청하거나 다른 결과를 커밋하거나 서버를 다시 시작해야 다시 본다. 그때 모델을 새로 불러서 통과 시각이 늦어지고, 그만큼 감액이 커질 수 있다(3.3). 설정 오류는 Candle 을 `Disabled` 상태로 만들어 이 영향을 없앤다(3.9).
- **지급이 밀리거나 빠질 수 있다.** 확정 호출이 성공하면 `PayoutOwed` 가 이미 있어서, 그 뒤의 재오픈이나 drop 이 지급을 지우지 못한다(3.2). lane 이 쉬거나 Task 를 못 읽으면 지급 대기가 pulse 간격에 다시 시도된다. 응답이 계속 거절되는 Goal 은 지급 대기로 남고, 다음 확정이나 다른 지급의 끝이나 서버 시작 때 다시 시도한다. 지급 대기 목록은 TUI 에서 보인다. 같은 Goal 의 지급이 두 번 나가는 것은 `Paid` 한 줄, cursor 조건 덧붙이기, Goal 별 일꾼 하나가 막는다(3.1, 3.2). `Disabled` 인 동안 통과한 Goal 은 원장에 흔적 없이 지급되지 않는다. TUI 는 `Disabled` 이유를 보이지만 그 기간에 통과한 Goal 을 세지는 않는다.
- **워크어라운드 자가 점검.** 시그니처 3종과 체크리스트 7항목을 이렇게 봤다.
  - 텔레메트리만 남기는 항목이 하나 있다. 통과 전 기한 변경이다(위). 감액을 지키는 장치가 아니라 관찰이고, 다루는 방법은 운영자가 정한다(7장). 그 밖에는 없다.
  - 문자열 분류기와 catch-all 은 없다. 후보 keeper 는 이름 parse 와 keeper 설정 파일이 있는지로, 기한은 형식 파서로, 후보 Task 는 관계 판정 lane 으로 가른다.
  - 같은 고침을 여러 곳에 나눠 하는 일은 없다. 기한을 읽는 함수는 서버와 TUI 가 각자 갖고 있어서 5장 2번 (다)에서 한 PR 로 함께 바꾼다. 초상화는 서버와 원격 TUI 가 각자 그려서, 서버가 정한 착용 상태를 wire 로 주는 것까지 5장 6번에 넣었다.
  - 쓸 때 검증한다. 형식이 틀린 기한은 `upsert` 가 거절한다(5장 2번 (가)). 이미 저장된 틀린 기한을 읽을 때는 죽지 않고 `PayoutFailed` 로 끝낸다.
  - 중복 방지는 규칙으로 강제한다. 같은 Goal 에 두 번 지급하는 일은 cursor 조건 덧붙이기와 지급 상태가 막는다(3.1).
  - 시험용 뒷문은 만들지 않는다. 시각은 함수 인자로 받는다.

## 7. 남은 것

값만 정하면 되는 항목:

- 바닥 20%(시간당 1% 감액과 함께 초기값).
- 반감기의 시간 값. 처음은 `Off` 이고, 지급이 쌓인 뒤 3.8 의 어림을 다시 계산해서 정한다.
- 유통량에 연동하는 물가 공식 f 와 그 입력의 정의(3.5). 지급이 쌓인 뒤에 정한다.
- 다섯 등급의 실제 운영 금액. 가장 낮은 등급의 금액이 0 인지도 정한다. 0 보다 크면 Goal 을 많이 만드는 것만으로 Candle 이 늘어난다.
- 정수 감소 계산의 고정소수점 자릿수와 내림 규칙(3.1.1).
- 가중치 상한 `weight_max`(3.4).
- 5장 시험 세트의 합격선과 기준 Goal 묶음.

운영자 승인이 필요한 것:

- 헌법 개정 문안(8.1).
- 끝난 Task(`done`·`cancelled`)를 Goal 에 연결하지 못하게 하는 규칙(5장 2번 (나), Draft PR #39910). 연결에 시각이 없어서, 끝난 Task 를 나중에 붙이면 그 Goal 을 위한 일이었는지 알 수 없다. 이 규칙은 그 길을 결정론적으로 닫는다. 헌법 `gates` 는 하드 게이팅을 기본으로 두지 않아서 정책 판단이다. 이 규칙이 막는 기존 흐름은 기록에서 찾지 못했다(2장). 대안은 셋이다.
  - 막지 않고 관계 판정에만 맡긴다. 가장 넓게 열려 있다.
  - `Todo` 가 아닌 Task 도 거절한다. 이미 시작한 Task 를 붙이는 일까지 막는다.
  - 연결 시각을 남기고 '끝나기 전에 연결됐다'를 후보 조건으로 둔다. 연결 기록 형식이 바뀌어서 hard cut 이 필요하고, 지금 연결 45개에는 시각이 없다.
- 사람이 확정할 때 원장에 `PayoutOwed` 를 쓰고, 못 쓰면 확정을 거절하는 것(3.2). 확정이 Candle 원장 쓰기에 걸린다. 대안은 확정을 걸지 않고 일꾼이 검증 원장과 이벤트에서 확정된 Goal 을 찾는 것인데, 재오픈이 검증 원장의 확정 기록을 지우고 이벤트 파일은 fsync 를 하지 않아서 지급이 빠질 수 있다. 저장은 확정 기록, `PayoutOwed`, phase 순으로 세 번이고 한꺼번에 일어나지 않는다. 마지막 phase 저장만 실패한 뒤 운영자가 다시 확정하지 않고 재오픈하거나 drop 하면, 완료된 적 없는 Goal 에 지급이 나간다(3.2 표). 이것도 받아들일지 정해 주세요.
- 통과 전 기한 변경으로 감액을 피할 수 있는 것을 3.11 의 관찰로 시작할지, 감액 입력을 keeper 가 바꿀 수 없는 값에 묶을지, 1단계에서 감액을 뺄지(6장).
- 가격을 처음에 고정 가격표로 시작하고 유통량 연동 공식을 뒤로 미루는 것(3.5). 앞서 운영자는 같은 입력이면 같은 값이 나오는 물가 공식을 정했다.

후속 RFC 로 넘긴 것: 머지된 PR 작성자·board 논의·리뷰를 기여로 인정하는 것(PR 과 Goal 을 잇는 방법, board 글이 Goal 에 붙는 구조가 먼저 필요), Tool·Skill·모델 구입, 현상금 Task.

## 8. 저장소 헌법(`docs/constitution.xml`)과의 관계

| 조항 | 이 RFC 의 대응 |
|---|---|
| `no_wall_clock_death` | 잔액 감소는 이 조항과 맞지 않는다. 헌법 개정(5장 1번, 8.1)을 먼저 하고 그 전에는 감소를 넣지 않는다(3.1.1). 기한 초과 감액은 Goal·Task 의 상태를 바꾸지 않고 지급액만 줄인다. |
| `budget_gate` | 잔액은 turn·time·token·cost 가 아니고, 잔액이 없어도 keeper 의 턴·도구·Goal 은 막히지 않는다(3.7). |
| `magic_number` | 흐름 제어에 숫자 비교를 쓰지 않는다. 감액률, 바닥, 가격, 등급별 금액, 반감기는 TOML 값이다. 5장 시험 세트의 합격선은 시험 기준이다. |
| `gates` | 새 게이트를 만들지 않는다. 설정 오류는 Candle 만 `Disabled` 상태로 만들고 서버 부팅과 keeper 의 턴을 막지 않는다(3.9). 잔액 확인은 구매 한 곳뿐이다. 예외가 셋 있다. (1) Candle 이 켜져 있을 때 `Snapshot` 을 쓰지 못하면 검증 통과 전이를 거절한다(3.2). (2) `PayoutOwed` 를 쓰지 못하면 확정을 거절한다(3.2). (1)(2)는 기존 전이가 원장 기록을 먼저 하는 순서를 따르는 것이고, Candle 을 끄면 사라진다. (3) `set_task_goal` 이 끝난 Task 를 거절한다(5장 2번 (나)). 이것은 Candle 을 꺼도 남는다. (2)와 (3)은 운영자 승인 항목이다(7장). |
| `when_stuck` | 헌법은 "괴상한 비교문이나 결정론적 판단을 넣고 싶어지는 순간"에 lane 을 늘리라고 한다. 등급, 관계 판정, 가중치는 lane 이 정하고 산술은 코드가 한다(3.4). 가격은 고정 가격표라서 이 조항이 걸리지 않는다. 물가 연동 공식을 더할 때 다시 본다(3.5). |
| `persist_before_model_call` | 판단 대상(`Snapshot`, `PayoutOwed`, `Candidates`)을 모델을 부르기 전에 남기고, 호출의 입력과 출력은 lane 실행 기록이 남긴다. 지급 근거는 `Paid` 에 적는다(3.1, 3.4). `PayoutOwed` 를 phase 저장 전에 써서, 확정이 성공한 뒤의 재오픈이나 drop 이 지급 대상을 지우지 못한다(3.2). |
| `authoritative_read_only` | 원장을 읽을 수 없으면 지급과 구매를 하지 않는다(3.1). `Snapshot` 은 원본만 읽는 함수만 쓰고, 읽지 못하면 쓰지 않는다. Task 는 backlog 와 archive 를 함께 읽고, 못 읽으면 후보를 정하지 않고 다시 시도한다(3.4). |
| `failure_keeps_evidence` | 모델 호출이 실패하면 lane 실행 기록에 `Failed` 가 남고 Goal 은 지급 대기로 남는다(3.4). 다시 해도 결과가 같은 실패만 `PayoutFailed` 로 끝낸다. 지급 의무는 `PayoutOwed` 로 남는다. |
| `strict_parse_no_default`, `closed_sum_over_string` | 이벤트, 등급, 관계 판정, 아이템, 반감기(`Off` 또는 시간), 실패 이유, 기한(없음·날짜·읽을 수 없음), Task 상태(찾음·삭제됨·못 읽음)는 닫힌 variant 다. 모르는 값, 읽을 수 없는 기한, 잘못된 가중치, 못 읽는 archive 행은 실패로 처리하고 기본값으로 바꾸지 않는다. 기한을 읽는 함수를 합치면 overdue 알림의 "날짜가 아니면 늦지 않음"도 같은 값으로 바뀐다. 알림 동작은 읽을 수 없는 값에서 지금과 같다(3.3). |
| `legacy_residue` | 소급 지급과 옛 형식 reader 를 만들지 않는다(4장). |
| `testing`, `evidence` | 기능 단위 시험을 우선하고 계산 함수만 함수 시험을 둔다. 단계마다 증거를 5장 표에 정했고 켜기 전 기준선을 남겼다(3.11). |
| `execution_protocol` | 서로 의존하지 않는 것은 main 기반의 별도 PR 로 나눈다. 각 PR 은 자기가 쓰는 것만 넣는다(5장). 4번은 서버, TUI, 대시보드를 함께 고쳐야 해서 한 PR 이 커진다. 로컬 빌드는 하지 않는다. |
| `engineering`(research) | 선행 사례를 3.10 에 적었다. |
| `feature_surface`, `domain` | Candle 이 헌법에 없다. 개정 문안을 8.1 에 두고 5장 1번으로 먼저 낸다. |
| `string_matching`, `hardcoded_path`, `env_var_sprawl` | 후보 keeper 는 이름 parse 와 keeper 설정 파일이 있는지로 가르고 기한은 형식 파서로 읽는다. 새 환경변수는 없다. 지급 일꾼은 조건 변수와 기존 maintenance pulse 로 깨운다. 설정 폴더는 `Config_dir_resolver` 로 찾는다. |
| `AGENTS.md` Keeper Runtime Boundary | 헌법은 keeper 런타임 프롬프트가 아니다. Candle 을 keeper 에게 알리는 방법은 keeper 쪽 파일에서 정한다. 이 RFC 는 잔액과 가격을 조회하는 도구로만 알리는 안을 제안하고, 그 도구는 `defer_loading = false` 로 둔다(3.7). |

### 8.1 헌법 개정 문안(5장 1번)

`domain` 에 Board 의 karma 처럼 Candle 을 넣는다.

```xml
<candle note="Candle 은 Goal 완료에 대한 keeper 의 보상 화폐다.">
  <rule>원장(candle-ledger.jsonl)에는 사실만 덧붙인다. 잔액은 원장을 읽어 계산한 값이다.</rule>
  <rule>Candle 로 살 수 있는 것은 초상화 장신구뿐이다. 도구, 스킬, 모델, 예산은 사지 못한다.</rule>
  <rule>잔액은 시간이 지나면 지수적으로 줄어든다. 반감기는 설정이 정한다.</rule>
</candle>
```

`invariants` 의 `no_wall_clock_death` 에 예외 한 줄을 붙인다.

```xml
예외: Candle 잔액. 잔액의 감소는 화폐 가치의 감쇠이고, Task·Goal·Board 의 어떤 상태도 만료시키지 않으며 원장의 사실을 지우지 않는다.
```

`feature_surface` 의 `domain` 그룹에 `Candle` 을 더한다. `src` 속성은 구현 PR 에서 채운다.
