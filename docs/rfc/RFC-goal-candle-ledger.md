---
rfc: "goal-candle-ledger"
title: "Goal 을 끝내면 Candle 을 받고, 초상화 장신구를 산다"
status: Draft
created: 2026-09-29
updated: 2026-09-29
author: claude
related: ["every-lane-is-one-row-in-one-registry", "0267", "0362", "0387", "0435"]
---

# RFC: Goal 을 끝내면 Candle 을 받고, 초상화 장신구를 산다

이 RFC 는 Goal 이 끝나면 keeper 에게 Candle 을 주는 규칙을 정한다. keeper 는 받은 Candle 로 초상화 장신구를 산다.

- 다루는 것: Candle 원장, Goal 완료 때의 지급, 기한 초과 감액, 기여자별 분배, 잔액이 시간이 지나며 줄어드는 규칙, 장신구 구매와 착용.
- 다루지 않는 것: Goal 의 phase(진행 단계) 흐름과 검증. Tool·Skill·모델 구입과 현상금 Task 는 후속 RFC 로 미룬다.
- 관련 문서: `RFC-0267`(Task 와 Goal 의 연결), `RFC-0362`(Goal owner), `RFC-0387`(Goal 완료 검증), `RFC-0435`(keeper 재화가 행동을 바꾸는지 재는 설계), `RFC-every-lane-is-one-row-in-one-registry`(새 lane 의 등록).
- 근거 기준: `origin/main` = `f632782f8c` (2026-09-29). 줄 번호는 이 커밋 기준이다. 데이터는 같은 날 `~/me/.masc` 에서 읽었다.
- 표시: **[사실]** 은 코드나 데이터에서 확인한 것이다. **[제안]** 은 이 RFC 가 정하려는 것이다.

## 용어

| 말 | 뜻 |
|---|---|
| Goal | 정량 성공 조건이 있는 큰 목표. Task 여럿이 연결될 수 있다. |
| Task | Goal 에 연결될 수 있는 작은 일. 담당자(assignee)가 있다. |
| keeper | 영속성이 있는 에이전트. |
| Candle | 보상 화폐. 정수 `milli-candle` 로 센다(1 Candle = 1000 milli-candle). |
| 원장 | Candle 이 오간 기록을 한 줄씩 덧붙이는 파일. |
| 총액, 몫, 지급액 | 총액은 Goal 하나에 풀리는 Candle. 몫은 keeper 한 명의 감액 전 금액. 지급액은 감액 뒤 실제로 받는 금액. |
| lane | 모델이 하는 독립 작업(standalone lane). 이 RFC 는 `Candle_appraiser` 하나를 더한다. |

## 1. 요청과 이미 정해진 것

2026-09-29 운영자가 Goal 을 끝낼 때마다 보상을 주고 싶다고 했다. 보상 화폐는 Candle 이고 `0.5 Candle` 처럼 소수점 값도 쓴다. Goal 이 끝나면 기여한 정도에 따라 나눠 준다. 대화에서 정해진 것은 다음과 같다.

| 항목 | 결정 |
|---|---|
| 총액과 분배 | `Candle_appraiser` lane 하나가 정한다(3.4). 총액은 lane 이 고른 등급의 TOML 금액이다. |
| 받는 쪽 | keeper 만 받는다. owner 와 운영자 평가는 쓰지 않는다. 1단계 분배 근거는 Goal 에 연결된 Task 의 담당자뿐이다. |
| 지급 횟수 | Goal 당 한 번. 재오픈해도 추가 지급이나 회수가 없다. drop 하면 0. 연결된 Task 가 없으면 지급하지 않는다. |
| 자기 Goal | keeper 가 만든 Goal 로 받는 것도 1단계에서는 막지 않는다. 위험은 6장에 적는다. |
| 기한 초과 | 초과 1시간마다 몫에서 1%씩 줄고, 바닥은 20%. 두 값은 TOML 로 정한다. 기준 시각은 검증 통과 시각이고, 날짜만 있는 기한은 그날 UTC 23:59:59 로 읽는다. 기한을 읽는 함수는 overdue 알림과 하나로 합친다. |
| 잔액 | 시간이 지나면 지수적으로 줄어든다. 반감기는 TOML 로 정한다. 감소는 헌법 `no_wall_clock_death` 에 예외를 넣는 개정(5장 1번)이 들어간 뒤에 켜고, 처음 값은 `Off` 다. 시간 값은 지급이 쌓인 뒤 정한다(3.1.1). |
| 쓰는 곳 | keeper 가 직접 Candle 을 내고 초상화 장신구를 산다. keeper 는 Candle 을 안다. |
| 가격 | 아이템별 가격은 TOML 의 고정 가격이다. 유통량에 연동하는 물가 공식은 실제 지급 분포를 본 뒤에 더한다. 가격 계산은 함수 하나로 모아 나중에 바꿀 수 있게 한다. |
| 범위 밖 | Tool·Skill·모델 구입, 현상금 Task. |

## 2. 지금 코드에서 확인한 것

- **[사실]** `Completed` 는 끝이 아니다. `Completed` 에서 `Reopen` 하면 `Executing` 으로 돌아간다(`lib/goal/goal_phase.ml:186`). 완료될 때 지급하기만 하면 재오픈했다가 다시 완료할 때마다 또 지급된다.
- **[사실]** `Completed` 로 가는 길은 하나다. 검증기가 통과시키면 `Awaiting_confirmation` 이 되고, 사람이 `Confirm_completion` 을 하면 `Completed` 가 된다(`goal_phase.ml:196`). 완료된 3건에서 검증 통과부터 사람의 확정까지 7.9~35.2시간이 걸렸다(`~/me/.masc/goal_events.jsonl`).
- **[사실]** 제목·metric·target 을 고치면 Goal 이 `Executing` 으로 돌아간다. 기한(`due_date`)과 priority 를 고쳐도 phase 는 그대로이고 기록도 남지 않는다(`lib/goal/goal_store.ml:741-766`).
- **[사실]** 새 Goal 에는 제목과 비어 있지 않은 metric·target_value 가 필요하다(`goal_store.ml:722`, `:783-790`).
- **[사실]** Worker 역할은 `masc_goal_upsert`, `masc_goal_transition`(CanBroadcast)과 `masc_task_set_goal`(CanCompleteTask)을 쓸 수 있다(`lib/types/types_auth.ml:341-345`, `lib/tool/tool_catalog.ml:354-360`). 세 도구는 keeper 에게 노출되어 있고(`lib/keeper/keeper_tool_descriptor.ml:2860, 2940, 2944`), keeper 가 호출한 기록이 있다(`~/me/.masc/keepers/tool_usage/`).
- **[사실]** `set_task_goal` 은 Goal 이 없는 Task 를 아무 Goal 에나 붙인다. 호출자, Task 상태, Goal phase 를 보지 않는다(`lib/task/task_goal_assignment.ml:45-66`). Task 와 Goal 의 연결에는 시각이 없다.
- **[사실]** Goal 을 `Drop` 하거나 `Reopen` 할 때 호출자는 이벤트에 기록될 뿐 owner 와 비교하지 않는다(`lib/workspace_goals.ml:1060-1182`). `goal_events.jsonl` 에 keeper 가 Goal 을 drop 한 기록이 7건 있다(`e-masc-the-leader` 6건, `indie-geek-blue` 1건).
- **[사실]** Goal 에는 `owner` 하나뿐이고 기여자 기록이 없다(`goal_store.mli:33-38`, 레코드는 `:43-66`). 새 Goal 은 만든 에이전트가 owner 로 기록되고(`lib/workspace_goals.ml:324`), owner 는 만들 때만 정해진다(`goal_store.ml:796`, 갱신 경로에는 owner 를 바꾸는 줄이 없다). 지금 있는 Goal 18개는 전부 `Unknown_owner` 다.
- **[사실]** Goal 스키마는 닫혀 있다. 모르는 필드가 있는 행은 읽히지 않는다(`goal_store.mli` 머리 주석). Goal 레코드에 Candle 필드를 넣지 않는다.
- **[사실]** `due_date` 는 문자열이다. 기한이 있는 Goal 11개가 모두 `2026-09-23` 처럼 날짜만 적혀 있다. 기존 overdue 판정은 운영자의 로컬 날짜와 비교하고, 날짜 형식이 아니면 늦지 않은 것으로 본다(`lib/workspace_goals.ml:657-672`). overdue 알림은 owner 를 모르는 Goal 을 건너뛴다(`:694`). 그래서 지금 알림이 나간 Goal 이 0개다.
- **[사실]** 초상화 슬롯은 `face`, `neck`, `head`, `hand`, `base` 다섯이고 각각 닫힌 variant 다(`lib/keeper_portrait/keeper_portrait_look.mli:57-70`). 아이템 생성자 23개에서 빈 값 5개를 빼면 살 수 있는 아이템은 18개다. `Draw.render` 는 장신구를 인자로 받고, 이름에서 장신구를 정하는 호출부는 두 곳이다(`bin/masc_tui_keeper_portrait.ml:57`, `lib/server/server_dashboard_http_keeper_portrait.ml:116`).
- **[사실]** lane 은 `Standalone_lane.t` 의 생성자 하나이고 `[runtime.exact_output_lanes.<id>]` 표를 가진다. `obligation` 이 `Required` 인 lane 은 슬롯이 없으면 서버가 발행이나 설정 저장을 거부한다(`lib/runtime/standalone_lane.mli`). 생성자를 더하면 그것을 `match` 하는 곳이 컴파일 오류를 낸다. 최소한 `standalone_lane`, `runtime`, `exact_lane_run_registry`, `lane_manifest`, `lane_addon_sources`, `server_standalone_lane_projection`, `bin/masc_tui_render`, `tui_decode`, `keeper_exact_lane_preference` 가 걸린다(`rg Browser_stagehand lib bin` 으로 확인).
- **[사실]** 헌법은 저장소에서 버전 관리되는 SSOT 다(`docs/constitution.xml:9-10`). 헌법의 규칙에 예외를 두려면 헌법을 고친다. RFC 가 예외를 선언해도 헌법은 그대로다.
- **[사실]** Goal 전이는 `Goal_phase.decide_transition` 다음에 검증 원장에 기록하고, 그다음 phase 를 쓰고, 그다음 이벤트를 남긴다. 원장 기록이 실패하면 phase 쓰기를 막는다(`lib/workspace_goals.ml:409-416`). 사람이 확정하면 `confirmed_at` 이 같은 트랜잭션에서 검증 기록에 남는다(`lib/goal/goal_verification.mli:26`).
- **[사실]** `read_backlog_observation_r` 는 주 파일을 못 읽으면 `.last-good` 를 돌려준다. 복구용 사본을 섞지 않는 함수는 `read_backlog_r` 다(`lib/workspace/workspace_backlog.mli:8, 20-27`). Task 와 Goal 의 연결에는 `read_goal_task_links_authoritative_r` 가 있다(`lib/workspace/workspace_goal_index.mli:73`).
- **[사실]** runtime.toml 의 lane 표는 모르는 키를 서버 로드 에러로 다룬다(`lib/runtime/runtime_toml.ml:2551-2552`). 설정을 runtime.toml 에 두면 Candle 설정 오류가 서버 부팅을 막을 수 있다.
- **[사실]** 도구의 `defer_loading = true` 는 모델이 이름을 부르기 전까지 요청에서 뺀다. 도구 112개가 그렇다(`config/tools/masc_goal_upsert.toml:11` 의 주석, `config/tools/` 에서 `defer_loading = true` 를 센 값).

## 3. 설계

### 3.1 원장

**[제안]** Candle 이 오간 기록은 `.masc/candle-ledger.jsonl` 에 이벤트로 덧붙이기만 한다. 금액은 정수 `milli-candle` 로 적는다.

| 이벤트 | 남기는 때 | 담는 것 |
|---|---|---|
| `Snapshot` | Goal 이 검증을 통과해 `Awaiting_confirmation` 이 될 때 | goal_id, 검증 요청 id, Goal 생성 시각, 검증 통과 시각, 그때의 기한(없음, 날짜, 읽을 수 없는 값 중 하나), 제목·metric·target, 그때 연결된 Task 의 제목·담당자·상태·끝난 시각 |
| `PayoutOwed` | 사람이 확정해 `Completed` 가 된 직후 | goal_id, 검증 요청 id, 시각 |
| `AppraisalRequested` | 모델을 부르기 전에 | goal_id, 요청 id, 시각, lane 슬롯(모델) id |
| `PayoutFailed` | 지급 시도가 실패했을 때 | goal_id, 요청 id(모델을 불렀다면), 이유(닫힌 목록: lane 호출 실패, 응답 거절, 기한을 읽을 수 없음) |
| `Paid` | 지급할 때. 한 줄에 전부 적는다 | goal_id, 등급, 총액, 요청 id, keeper 별 몫·감액 계수·지급액, 감액에 쓴 값(검증 통과 시각, 기한, 감액률, 바닥) |
| `Unattributed` | 받을 keeper 가 없어 지급 없이 끝낼 때 | goal_id |
| `Purchased` | keeper 가 아이템을 살 때 | keeper, 아이템, 낸 금액, 시각 |
| `Equipped` | keeper 가 착용을 바꿀 때 | keeper, 슬롯, 아이템, 시각 |
| `HalfLifeSet` | 잔액 감소를 켠 뒤, 설정이 적용될 때 반감기가 원장의 마지막 값과 다르면(원장에 값이 없을 때도) | 반감기(`Off` 또는 시간), 시각 |

- 잔액은 저장하지 않는다. 이벤트를 처음부터 차례로 읽어 그때그때 계산한다.
- `Paid` 는 한 줄이다. keeper 별 지급을 여러 줄에 나눠 쓰지 않는다. 그래서 일부 keeper 만 지급된 상태는 생기지 않는다.
- 지급 대기는 이벤트가 아니다. Goal 마다 가장 최근 `PayoutOwed` 가 있고 그 Goal 에 `Paid` 도 `Unattributed` 도 없으면 지급 대기다. 그 뒤에 Goal 을 재오픈하거나 drop 해도 지급 대기는 그대로다.
- `Purchased` 와 `Paid` 에는 그때 낸 금액과 감액에 쓴 값을 적는다. 가격이나 TOML 값이 나중에 바뀌어도 과거 기록은 그대로다. Board karma 도 점수(delta)를 이벤트에 적어 규칙이 바뀌어도 과거 값을 유지한다(`docs/constitution.xml:169-171`).
- 원장은 사실만 기록한다. 다음 행동을 시키거나 막지 않는다.
- 원장을 읽을 수 없으면 지급과 구매를 하지 않는다. 복구용 사본을 읽어서 쓰기를 허가하지도 않는다.
- 구매는 원장을 읽은 끝 위치에서만 덧붙인다(`append_private_jsonl_durable_locked_at_end_offset_result`). 그사이 다른 줄이 덧붙었으면 아무것도 쓰지 않고 실패하므로, 다시 읽고 잔액을 확인한다. 동시에 산 두 건이 잔액을 마이너스로 만들지 못한다.
- 원장은 `Fs_compat` 의 private JSONL 함수(`append_private_jsonl_durable_locked_result`, `read_private_jsonl_rows_locked_result`)로 읽고 쓴다. 쓰기 전에 끝에 남은 불완전한 줄을 잘라 내고, 쓴 뒤 fsync 하며, 실패하면 되돌린다. 읽을 때 불완전한 끝줄은 행으로 세지 않는다(`lib/fs_compat/fs_compat.mli`). fsync 를 하지 않는 `append_jsonl` 은 쓰지 않는다. `keeper_approval/audit.ml` 과 `fusion_decision.ml` 이 같은 함수를 쓴다.

### 3.1.1 잔액은 시간이 지나면 줄어든다

**[제안]** keeper 의 잔액은 시간이 지나며 지수적으로 줄어든다(운영자 결정: Candle 은 저절로 소모된다). 반감기(잔액이 절반이 되는 데 걸리는 시간)는 TOML 로 정하고, 값은 `Off`(감소 없음)와 `Hours n`(n 시간) 중 하나다.

이 규칙은 헌법과 맞지 않는다. 헌법 `no_wall_clock_death` 는 "시간 경과로 상태를 죽이지 않는다"고 한다(`docs/constitution.xml:211`). 헌법은 저장소의 SSOT 라서(`:9-10`) 이 RFC 가 예외를 선언할 수 없다. 잔액이 줄면 살 수 있는 물건도 줄기 때문에 화면에 보이는 값만 바뀌는 것도 아니다. 그래서 순서를 이렇게 한다.

1. 헌법 개정 PR 을 먼저 낸다(5장 1번). 문안은 8.1 에 있다. Candle 을 `domain` 에 넣고 `no_wall_clock_death` 에 잔액 감소 예외를 적는다. 운영자가 문안을 승인한 뒤에 연다.
2. 그 PR 이 들어가기 전에는 잔액 감소 코드를 넣지 않는다. 잔액은 줄지 않는다.
3. 들어간 뒤 잔액 감소 단계(5장 8번)에서 `HalfLifeSet` 과 `Hours n` 을 넣는다. 처음 값은 `Off` 다.

감소를 넣은 뒤의 동작은 다음과 같다.

- 줄어든 양은 원장에 적지 않는다. 잔액을 읽을 때 마지막 이벤트 시각부터 지금까지 줄어든 만큼을 계산해 반영한다. 원장에는 발행·구매 같은 사실만 남는다.
- 처음에는 `Off` 로 시작한다. 지급이 쌓여야 반감기를 정할 수 있고, 지급이 쌓이려면 기능이 켜져 있어야 하기 때문이다. `Off` 는 기본값이 아니다. TOML 에 반드시 적어야 하고, 값이 없으면 Candle 이 `Disabled` 된다(3.9).
- 반감기를 바꾸면 그 사실을 원장에 `HalfLifeSet` 으로 남긴다. 각 구간은 그 구간을 시작한 시점에 유효했던 반감기로 계산한다. 그래서 반감기를 바꿔도 과거 잔액이 다시 계산되지 않고, 이미 한 구매 때문에 잔액이 마이너스가 되는 일이 없다.
- 지수 감소를 고른 이유: 잔액을 지급 시점별로 나눠 각각 깎으면, 구매할 때 어느 지급분부터 쓸지 정해야 한다. 지수 감소는 잔액 하나에만 적용하면 되고 구매 순서가 결과에 영향을 주지 않는다(정수 내림 때문에 이벤트마다 1 milli 이내의 차이는 생긴다). Goal 보상의 감액은 선형이다. 그쪽은 사람이 얼마나 깎였는지 바로 계산할 수 있어야 하기 때문이다.
- 계산은 정수 연산이다. 부동소수 `exp` 를 쓰면 실행 환경마다 잔액이 달라질 수 있다. 고정소수점 자릿수와 내림 규칙은 구현 전에 정한다.
- 효과: 장신구를 다 사도 Candle 이 계속 줄어서 잔액이 끝없이 쌓이지는 않는다. 유통 총량은 지급 속도와 줄어드는 속도가 맞는 지점으로 수렴한다. 3.5 에서 물가를 유통량에 연동하게 되면 이 총량이 그 입력이 된다.
- 부작용: keeper 가 오래 쉬면 잔액이 줄어든다. keeper 는 Candle 을 알고 있으므로 빨리 쓰게 만드는 압박이 생긴다. 살 수 있는 것이 장신구뿐이라 일에는 영향이 없다(3.7).
- 값을 고르는 기준: keeper 한 명이 Candle 을 받는 간격을 Δ, 1회 지급액을 A, 반감기를 T 라고 하자. 오래 지나 잔액이 안정되면 평균 잔액은 A·T ÷ (Δ·ln 2) 이고, 지급 직후의 최고점은 A ÷ (1 − 2^(−Δ/T)) 다. 아이템을 살 수 있는지는 최고점으로 본다. Δ 와 T 가 같으면 최고점은 2A 이고, Δ 가 T 보다 훨씬 길면 최고점이 A 에 가까워서 모을 수 있는 한도가 1회 지급액 정도다. 가장 비싼 아이템 가격이 최고점보다 크면 아무도 못 산다. Δ 는 keeper 전체의 지급 간격이 아니라 한 명이 받는 간격이다(3.8).

### 3.2 지급 시점과 재오픈

**[제안]** 지급은 두 시점에 걸친다. 검증을 통과할 때 입력을 고정하고, 사람이 확정하면 지급 의무를 남기고 지급한다.

- 검증 통과: `Snapshot` 을 검증 원장에 기록하기 전에 `candle-ledger.jsonl` 에 쓴다. 쓰지 못하면 그 전이를 거절한다. Goal 전이가 원장 기록을 phase 쓰기보다 먼저 하고 원장 기록 실패가 phase 쓰기를 막는 기존 순서와 같다(`lib/workspace_goals.ml:409-416`). 이 거절은 Candle 이 켜져 있을 때만 일어난다.
- `Snapshot` 이 읽는 값(Task 목록, Task 와 Goal 의 연결, keeper 목록)은 복구용 사본을 섞지 않는 함수(`read_backlog_r`, `read_goal_task_links_authoritative_r`)로 읽는다. 읽지 못하면 `Snapshot` 을 쓰지 않고 전이를 거절한다. keeper 설정 폴더를 읽지 못한 것과 "keeper 가 아님"은 다른 결과로 다룬다.
- 사람이 확정해 `Completed` 가 되면 곧바로 `PayoutOwed` 를 남기고 지급을 시도한다. 서버가 그 사이에 죽었으면, pulse 점검이 `Completed` 이고 `Snapshot` 이 있는데 `PayoutOwed`·`Paid`·`Unattributed` 가 없는 Goal 에 `PayoutOwed` 를 남긴다. 확정 커밋과 이 줄 사이에 서버가 죽고 다음 점검 전에 그 Goal 이 재오픈되면 이 지급을 놓친다. 이 틈은 받아들인다.
- 지급은 `PayoutOwed` 의 검증 요청 id 와 같은 `Snapshot` 을 쓴다. 그 뒤에 재오픈해서 다시 검증을 통과해도 이미 남은 `PayoutOwed` 가 가리키는 `Snapshot` 이 바뀌지 않는다.
- 같은 Goal 에 두 번 지급하지 않게 하는 키(멱등 키, idempotency key)는 goal_id 다. `Paid` 나 `Unattributed` 가 이미 있으면 다시 하지 않는다.
- 재오픈했다가 다시 완료돼도 추가 지급이나 회수가 없다. 이미 지급된 Goal 이 `Dropped` 가 돼도 회수하지 않는다.
- 지급 대기 중에 재오픈하거나 drop 해도 확정된 지급은 그대로 한다. 확정된 적이 없는 Goal 이 `Dropped` 로 끝나면 지급하지 않는다.
- Candle 이 꺼져 있을 때 검증을 통과한 Goal(`Snapshot` 이 없다)과 원장이 생기기 전에 끝난 Goal 은 대상이 아니다. 그런 Goal 을 재오픈해 다시 검증을 통과하면 새 `Snapshot` 이 생기고, 그때 첫 지급을 받는다. 소급 지급이 아니라 새 검증에 대한 첫 지급이다. `Completed` 인데 `Snapshot` 이 없는 Goal 의 수는 TUI 에 보인다.

이유: 회수 규칙을 만들면 이미 쓴 Candle 때문에 잔액이 마이너스가 될 수 있고 그 처리 규칙이 또 필요하다. 재오픈해서 고쳐도 지급액은 처음 그대로다. 처음 완료가 부실했던 경우의 손해는 받아들인다.

### 3.3 기한 초과 감액

**[제안]** 감액의 기준 시각은 검증 통과 시각(`Snapshot` 의 시각)이다(운영자 결정). 사람이 확정하기까지 걸린 시간(관측 7.9~35.2시간)은 keeper 가 늦은 것이 아니므로 감액에 넣지 않는다.

- 기한 시각: `due_date` 는 `YYYY-MM-DD` 만 읽는다. 그날 UTC 23:59:59 를 기한 시각으로 본다(운영자 결정). 기한이 없으면 감액하지 않는다. 다른 형식은 읽을 수 없는 값이라 지급하지 않고 `PayoutFailed` 에 이유를 남긴다. 편한 기본값으로 바꾸지 않는다. 같은 입력으로 다시 해도 결과가 같아서 다시 시도하지 않는다. 기한을 고친 뒤 Goal 을 다시 검증하고 확정하면 새 `PayoutOwed` 가 생기고, 지급 대기는 Goal 마다 가장 최근 `PayoutOwed` 하나를 기준으로 하므로 그 값으로 지급한다. 시각이 적힌 기한은 이 RFC 에서 지원하지 않는다. 데이터에 한 건도 없다.
- `masc_goal_upsert` 가 `due_date` 형식을 만들 때 거절하게 하면 읽을 수 없는 값이 생기지 않는다. 도구를 바꾸는 일이라 이 RFC 범위 밖이다.
- 계산은 정수로 한다.
  - 초과 시간 = max(0, 내림((검증 통과 시각 − 기한 시각) ÷ 1시간))
  - 감액 계수(천분율) = max(바닥, 1000 − 감액률 × 초과 시간). 항상 1000 이하다. 기한보다 일찍 끝나도 1000 을 넘지 않는다.
  - 지급액 = 내림(몫 × 감액 계수 ÷ 1000)
  - 감액률과 바닥은 천분율 정수로 TOML 에 적는다. 초기 설정값은 감액률 10(시간당 1%), 바닥 200(20%)이다. 값이 없으면 Candle 이 `Disabled` 된다(3.9). 코드에 기본값을 두지 않는다.
- 예: 몫이 10 Candle 이면 초과 10시간에 9, 50시간에 5 Candle 이다. 80시간부터는 바닥인 2 Candle 이다. 바닥이 없으면 100시간에 0 이 된다.
- 선형으로 두는 이유: 사람이 얼마나 깎였는지 바로 계산할 수 있어야 한다. 복리는 쓰지 않는다.
- 계산 입력인 기한이 나중에 바뀌어도 결과가 달라지지 않는다. `Snapshot` 에 그때의 기한을 적고 `Paid` 에 쓴 값을 적는다(3.1).
- 실제 예: `Releases of 2026-09-26` Goal 의 기한은 `2026-09-26` 이고, 2026-09-28 06:32Z 에 검증을 통과했다. 초과는 30.55시간이고 내림하면 30시간이라 감액 계수는 700(70%)이다. 사람이 확정한 것은 그 20.38시간 뒤이고, 이 시간은 감액에 들어가지 않는다.
- 짧은 Goal 과 긴 Goal 에 같은 시간당 %를 쓰는 문제는 위험(6장)에 둔다.

**기한을 읽는 함수는 하나다**(운영자 결정). 기존 overdue 알림은 운영자의 로컬 날짜로 판정한다(`lib/workspace_goals.ml:657-672`). 이 RFC 는 알림도 감액과 같은 함수를 쓰게 해서 기한 시각을 UTC 23:59:59 하나로 읽는다. 함수는 기한 없음, 날짜, 읽을 수 없는 값을 구분해서 돌려준다. 알림은 읽을 수 없는 값을 지금처럼 늦은 것으로 보지 않는다. 운영자 시간대가 KST 이면 알림이 늦은 것으로 표시하는 시각이 기한 다음 날 0시에서 오전 9시로 늦어진다.

### 3.4 총액 책정과 분배

**[제안]** 새 lane `Candle_appraiser` 하나를 더한다. 이 lane 의 `obligation` 은 `Optional` 이다. `candle.toml` 이 없으면 이 기능이 꺼져 있으므로 lane 이 없어도 서버가 떠야 한다(3.9).

입력은 `Snapshot` 에 적힌 사실뿐이다: Goal 의 제목·metric·target, 그때 연결된 Task 의 제목·담당자·상태·끝난 시각. 아래는 넣지 않는다.

- priority: 만든 쪽이 정하는 값이라 부풀릴 수 있다.
- 비용 데이터: Goal 단위로 비용을 붙일 방법이 없다.
- 검증에 제출된 증거(`submitted_evidence`): board·fusion 글을 통째로 담을 수 있어서, board 글을 근거로 쓰지 않기로 한 결정과 맞지 않는다.

**총액.** lane 은 등급 하나를 고른다. 등급은 닫힌 variant 이고(예: `Trivial`, `Small`, `Medium`, `Large`, `Epic`), 등급별 금액은 TOML 표로 정한다. 모델이 만든 임의의 숫자가 발행되지 않는다. 등급의 이름과 개수는 구현 전에 정한다.

**분배.** 모델을 부르기 전에 코드가 받을 수 있는 후보 목록을 만든다. 후보는 `Snapshot` 에서 `done` 이고 끝난 시각이 Goal 생성 시각 이후인 Task 의 담당자 가운데, keeper 설정 파일(`Config_dir_resolver.keeper_toml_path_for_base_path` 가 가리키는 `<이름>.toml`)이 있는 사람이다. 설정 폴더를 읽지 못한 것과 파일이 없는 것은 다른 결과다. Goal 이 만들어지기 전에 끝난 옛 Task 를 나중에 붙여서 몫을 얻는 것을 막으려는 조건이다. 지금 Goal 에 연결된 done Task 7건은 모두 이 조건을 만족한다.

lane 은 후보마다 0 이상의 정수 가중치 하나를 낸다. 합이 1 이어야 하는 비율은 내게 하지 않는다. 모델이 `0.33` 세 개를 내면 합이 0.99 라서 거절되는 일이 반복되기 때문이다.

- 후보에 없는 이름이 있거나, 후보가 빠졌거나, 가중치가 정수가 아니거나, 합이 0 이면 응답을 거절한다.
- 몫 = 내림(총액 × 가중치 ÷ 가중치 합). 남는 milli 는 나머지가 큰 순서대로 1 milli 씩 나눠 준다. 나머지가 같으면 이름이 사전순으로 앞선 쪽이 먼저 받는다.
- 후보가 없으면(연결된 Task 가 없거나, 조건을 만족하는 done Task 가 없거나, 담당자 가운데 keeper 가 없으면) 발행하지 않고 원장에 `Unattributed` 한 줄만 남긴다. 받을 곳이 없는 Candle 을 발행하면 총량만 늘어난다. 나중에 Task 가 붙어도 다시 지급하지 않는다.

**1단계 근거는 Task 담당자뿐이다**(운영자 결정: 최소한으로 시작). 아래는 넣지 않는다.

- 머지된 PR 작성자: Task 와 Goal 에 PR 을 잇는 필드가 없다. 어느 PR 이 어느 Goal 의 것인지 정할 방법이 생긴 뒤에 다룬다.
- 운영자 평가: 금액을 정하는 데 사람이 끼지 않게 하려는 결정이다. 사람은 Goal 완료를 확정할 뿐이다.
- board 논의: board 글에는 `goal_id` 도 `task_id` 도 없다(`lib/board_types/board_types.mli`).
- 리뷰만 한 keeper 의 몫: 확인할 수 있는 근거가 없다.
- owner: 지금 Goal 이 전부 `Unknown_owner` 이고, owner 없이도 지급할 수 있어야 한다는 운영자 결정이다.

난이도와 기여는 다른 질문이다. 난이도는 총액에, 기여는 분배에만 쓴다. 한 곳에 섞으면 어려운 일을 맡은 keeper 가 두 번 보상받는다.

**실패 처리(사람이 확인하지 않는 흐름).**

- 모델을 부르기 전에 `AppraisalRequested` 를 원장에 남긴다.
- 호출이나 검증이 실패하면 `PayoutFailed` 에 이유를 남긴다. 그 Goal 은 `PayoutOwed` 가 있고 `Paid` 가 없어서 지급 대기로 남는다.
- 지급 대기는 기존 검증 재시도처럼 maintenance pulse 간격마다 다시 시도한다. 횟수 상한은 두지 않는다. 다만 같은 입력으로 다시 해도 결과가 같은 실패는 다시 시도하지 않는다. `기한을 읽을 수 없음` 이 그렇다(3.3). `lane 호출 실패` 와 `응답 거절` 은 모델이 매번 다르게 답할 수 있어서 다시 시도한다.
- lane 프롬프트를 두는 곳은 구현 전에 정한다. keeper 가 PR 로 바꿀 수 있는 저장소 파일에만 두지 않는다.
- 균등 분배 같은 대체 규칙으로 지급하지 않는다. 대체 규칙이 있으면 lane 이 실패해도 돈이 나가서 실패가 드러나지 않는다.
- 운영자는 원장과 지급 대기 목록을 볼 수 있다. 보기만 하고 승인 절차는 없다.

### 3.5 가격표와 물가

**[제안]** 아이템 가격은 `candle.toml` 의 표에 둔다. 카탈로그에 있는 아이템에 가격이 없으면 그 아이템만 `Unpriced` 가 되어 살 수 없다. Candle 은 켜진 채다. 새 아이템을 코드에 더해도 Candle 이 멈추지 않는다. 표에 카탈로그에 없는 아이템이 있으면 설정 오류라서 Candle 이 `Disabled` 된다(3.9). 살 수 있는 아이템은 지금 18개다(2장).

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
- 착용은 슬롯마다 마지막 `Equipped` 로 정한다. 소유한 아이템만 착용할 수 있다.
- 초상화 렌더러는 이름에서 장신구를 정하는 호출부가 두 곳이다(2장). 이 두 곳을 함수 하나로 모으고, 원장의 착용을 이름에서 정한 장신구보다 우선한다. 몸은 바꾸지 않는다.
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

`~/me/.masc/goals.json` 의 Goal 18개와 `tasks/goal_task_links.json`, `tasks/backlog.json` 의 Task 865개를 2026-09-29 05:35Z 에 읽었다(`docs/evidence/2026-09-29-candle-baseline/`). 지급 근거는 검증 통과 때 `done` 이던 Task 의 담당자다. 스냅샷 기능이 아직 없어서 지금 상태로 어림했다.

| 구분 | 개수 |
|---|---|
| Goal | 18 (completed 3, dropped 9, executing 6) |
| Task 가 하나라도 연결된 Goal | 9 |
| 완료된 Goal 중 지급 근거가 있는 것 | 1 (`wkbl-front` 의 done Task 2건) |
| 완료된 Goal 중 연결 Task 가 없는 것 | 2 (릴리스 관련 Goal 둘) |

- 지급 근거가 있는 Goal 은 `핵심 24페이지 화면 품질`(기한 `2026-10-12`)이다. 검증 통과가 기한보다 341시간 앞섰고, 이때 감액 계수는 1000(감액 없음)이다.
- 지금 규칙이면 완료 3건 중 2건이 `Unattributed` 다. 이런 Goal 은 지급하지 않는다(운영자 결정). PR 과 Goal 을 잇는 방법은 이 RFC 범위 밖이고, 필요해지면 별도 RFC 로 다룬다.
- `dropped` 로 끝난 Goal 에 done Task 가 있다(2건, 담당자 `masc-pro-builder`, `e-masc-the-leader`). 3.2 에 따라 지급은 0이다. 일은 했지만 보상이 없다.
- Goal 에 연결된 done Task 의 담당자 4명(`tui-developer`, `wkbl-front`, `e-masc-the-leader`, `masc-pro-builder`)은 모두 keeper 설정(`~/me/.masc/config/keepers/`)이 있다. Goal 에 연결되지 않은 done Task 에는 keeper 설정이 없는 담당자(`codex-mcp-client`, `edgar.a.poe`, `analyst`)가 있다. 그런 이름이 Goal 에 붙은 Task 를 하게 되면 후보에서 뺀다. 기준은 keeper 설정 파일이 있는지다(3.4).
- 완료는 3건이 모두 2026-09-26~29 에 나왔다. 최초 Goal 생성(2026-09-09)부터 약 2.7주 동안 완료 3건이라 주 1건 남짓이다. 이 중 지급 근거가 있는 것은 1건이라 지급은 주 0.4건꼴이다. 받은 keeper 는 한 명(`wkbl-front`)뿐이다. 반감기를 정하는 데 필요한 것은 keeper 한 명이 받는 간격(3.1.1 의 Δ)이다. 받은 keeper 가 한 명뿐이라 지금 데이터로는 재지 못한다. 그래서 처음에는 `Off` 로 두고, 지급이 쌓인 뒤 값을 정한다.

### 3.9 설정과 배포

**[제안]** Candle 설정은 runtime.toml 이 아니라 설정 폴더의 `candle.toml` 한 파일에 둔다. 폴더는 `Config_dir_resolver` 로 찾고 경로를 손으로 붙이지 않는다. lane 표만 `[runtime.exact_output_lanes.candle_appraiser]` 로 runtime.toml 에 둔다.

이유: runtime.toml 의 lane 표는 모르는 키를 서버 로드 에러로 다룬다(2장). Candle 설정 오류가 서버 부팅과 keeper 의 턴을 막으면 헌법의 첫 실패 조건("Keeper 가 턴을 못 돈다")이 된다. 별도 파일에서 읽으면 옛 binary 는 이 파일을 아예 읽지 않는다.

Candle 은 `Enabled` 와 `Disabled { reason }` 둘 중 하나다.

- `candle.toml` 이 없으면 기능이 꺼져 있다. `Snapshot`, 지급, 구매, 표시가 모두 없다.
- 파일이 있는데 읽을 수 없거나 값이 틀리면 `Disabled { reason }` 이 되고 TUI 에 이유가 보인다. 빠진 키, 모르는 키, 등급 금액표에 빠진 등급, 카탈로그에 없는 아이템 가격이 그렇다. 서버는 정상으로 뜬다. 기본값으로 대신하지 않는다.
- 아이템 가격이 빠지면 그 아이템만 `Unpriced` 다(3.5). Candle 전체는 켜져 있다.
- `candle.toml` 이 있는데 lane 표가 없으면 `Disabled { reason: lane 없음 }` 이다.
- 옛 binary 는 lane 표를 모르는 표로 볼 수 있으므로 binary 를 먼저 배포하고 그 뒤에 lane 표를 넣는다. `candle.toml` 은 언제 넣어도 된다.

### 3.10 선행 사례

헌법은 이미 잘 설계된 사례를 찾아 참고하라고 한다(`docs/constitution.xml:312`). 이 RFC 가 기대는 것과 기대지 않는 것을 적는다.

- **RFC-0435(같은 저장소).** keeper 에게 재화 규칙을 줬을 때 행동이 바뀌는지를 재려는 설계다. 그 문서가 초록을 직접 확인한 문헌 둘이 여기에 영향을 준다. persona 가 payoff 를 누를 수 있다(arXiv:2601.10102, 7B~32B 모델 기준). 큰 모델일수록 평가받는다는 것을 더 잘 알아챈다(arXiv:2509.13333). 이 RFC 는 두 문헌을 RFC-0435 가 확인한 수준을 넘어 확인하지 않았다. 그래서 Candle 이 keeper 행동을 바꾼다고도, 안 바꾼다고도 전제하지 않는다. 3.11 에서 켜기 전 값을 재 두고 켠 뒤에 비교한다. RFC-0435 는 잔고 필드, 소비 게이트, 강제 장치를 만들지 않는 실험이고(§7), 이 RFC 는 원장과 구매가 있는 운영 기능이다. 그 문서의 파일럿은 별도 base path 여섯 개에서 돌리도록 설계됐고 아직 돌리지 않았다(§5.4, §5.7). 두 가지가 같은 base path 에서 겹치게 되면 그 base path 에서는 Candle 을 켜지 않는다.
- **Board karma(같은 저장소).** 이벤트에서 다시 만들어 낸 원장이고, 점수를 이벤트에 적어 규칙이 바뀌어도 과거 값을 유지한다(`docs/constitution.xml:164-171`). `Purchased` 와 `Paid` 가 같은 방식이다. karma 를 `GET /api/v1/karma` 가 서빙하는 것처럼(RFC-0435 §5.7) 잔액도 원장에서 계산해 보여 준다.
- **감가 화폐(demurrage).** 시간이 지나면 가치가 줄어 돌려 쓰게 만드는 화폐다. 1932~1934년 오스트리아 Wörgl 에서 지역 화폐로 시험됐고, 중앙은행이 1933-09-01 에 보완 화폐를 금지해서 끝났다(Wikipedia, "Demurrage currency", 2026-09-29 확인). 그 문서는 성공을 단정하고 근거를 달지 않아서 효과 수치를 인용하지 않는다. 이 RFC 는 "쌓아 두지 않게 만든다"는 발상만 가져온다.
- **게임 경제의 발행(faucet)과 소각(sink).** EVE Online 은 월간 경제 보고서에서 ISK 의 발행과 소각을 나눠 공개한다(2026-05 보고서에 `sinks_and_faucets` 차트가 있다). 이 RFC 는 `Paid` 를 발행, 잔액 감소와 `Purchased` 를 소각으로 보고, TUI·대시보드 표시(5장 7번)에서 둘의 합과 유통 총량을 보인다. 보고서의 정의와 분류는 페이지에서 확인하지 못해서 따르지 않는다.

### 3.11 켜기 전 기준선과 켠 뒤 비교

Candle 을 켜면 keeper 행동이 바뀔 수 있다. 바뀌는지는 켜기 전 값이 있어야 알 수 있다. 그래서 켜기 전에 아래를 재 뒀다(`docs/evidence/2026-09-29-candle-baseline/`, 2026-09-29 05:35Z 의 라이브 값).

| 항목 | 값 |
|---|---|
| Goal | 18개(completed 3, dropped 9, executing 6). 기한이 있는 것 11개 |
| drop 한 주체 | `e-masc-the-leader` 6, `indie-geek-blue` 1, `codex-mcp-client` 1, `masc-tui` 1 |
| 검증 통과부터 사람 확정까지 | 7.89~35.16시간, 중앙값 20.38시간(완료 3건) |
| Task | 865개. done 139개 중 만든 사람이 곧 담당자인 것 54개(38.8%) |
| 다른 keeper 가 끝낸 Task | `e-masc-the-leader` 가 만든 done 28개 중 25개, `wkbl-web-leader` 가 만든 done 54개 중 18개 |
| Goal 에 연결된 Task | 41개, 연결이 있는 Goal 9개 |

켠 뒤에는 매주 같은 스크립트를 돌려 결과를 같은 폴더에 남긴다. 운영자가 표를 보고 판단한다. 자동으로 막거나 조절하는 기준은 만들지 않는다. 표본이 작고(Goal 18개, 완료 3건) 모델, persona, 난수 같은 변수가 함께 움직여서, 변화가 보여도 원인이 Candle 이라고 말할 수는 없다(RFC-0435 §3).

## 4. 하지 않는 것

- Goal 레코드에 Candle 필드를 넣지 않는다.
- Candle 로 도구, 스킬, 모델, 예산을 사지 않는다.
- 사람 owner 의 몫을 만들지 않는다.
- 머지된 PR, 운영자 평가, board 논의, 리뷰, owner 를 1단계 분배 근거로 쓰지 않는다.
- priority 와 비용 데이터를 lane 입력에 넣지 않는다.
- 원장이 생기기 전에 끝난 Goal 에 소급 지급하지 않는다. 옛 형식을 읽는 코드도 만들지 않는다.
- 이미 지급한 Candle 을 회수하지 않는다. 마이너스 잔액을 만들지 않는다.
- 시각이 적힌 기한을 지원하지 않는다.
- 헌법 개정 전에 잔액 감소를 넣지 않는다.
- keeper 행동을 자동으로 막거나 조절하는 기준을 두지 않는다. 행동 변화는 3.11 의 표로 운영자가 본다.

## 5. 구현 순서

한 PR 은 20k token 안에서 끝낸다. 로컬 빌드는 하지 않고 CI 로 확인한다. 서로 기대지 않는 것은 main 기반의 별도 PR 로 나눈다(헌법 `execution_protocol`).

| 번호 | 내용 | 기반 | 증거 |
|---|---|---|---|
| 1 | 헌법 개정: Candle 을 `domain` 에 넣고 `no_wall_clock_death` 에 예외를 적는다(8.1) | main | 개정 PR 과 운영자 승인 |
| 2 | 기한을 읽는 함수 하나로 합치기. overdue 알림이 같은 함수를 쓴다(3.3) | main | 알림이 바뀌는 시각을 보여 주는 시험 |
| 3 | 원장 이벤트, 잔액 계산(감소 제외), `candle.toml` 읽기와 `Disabled` 상태 | main | 실제 원장 몇 줄, 잘못된 설정에서도 서버가 뜨는 로그 |
| 4 | `Snapshot`, `PayoutOwed`, 지급, 지급 대기 재시도 | 3 | Goal 을 완료시켜 `Snapshot`, `PayoutOwed`, `Paid` 줄이 남는 로그. 재오픈해도 한 번만 지급되는 로그 |
| 5 | `Candle_appraiser` lane. 앞서 Python fixture 정리 PR 을 따로 낸다 | 4 | 아래 시험 세트의 결과 표. 결과는 `docs/evidence/<날짜>-candle-appraiser/` |
| 6 | 가격, 구매·착용 도구, 초상화 렌더러 입력(호출부 두 곳을 함수 하나로) | 3 | 구매 도구 호출 로그, 같은 keeper 의 전후 초상화 PNG |
| 7 | TUI·대시보드 표시. 발행, 소각, 유통 총량 요약을 함께 보인다 | 4, 6 | TUI 캡처, 대시보드 브라우저 스크린샷 |
| 8 | 잔액 감소: `HalfLifeSet`, `Hours n`. 1번이 들어간 뒤에만 | 3, 1 | 감소 전후 원장 계산 예, 반감기 변경 이벤트 |

4번의 `Snapshot` 은 검증 원장에 기록하기 전에 쓴다(3.2). 전이가 그 뒤에 실패하면 쓸모없는 `Snapshot` 이 남지만, 다음 검증 통과 때 새 `Snapshot` 이 생긴다. 지급은 `PayoutOwed` 가 가리키는 `Snapshot` 을 쓴다.

5번의 시험 세트는 아래와 같고, 통과하기 전에는 그 PR 을 머지하지 않는다. 합격선은 처음 제안값이다. 기준 Goal 묶음을 만든 뒤 운영자가 정한다. 시험 기준일 뿐 keeper 흐름을 제어하는 값이 아니다.

- 반복 안정성: 같은 입력을 20번 넣었을 때 가장 많이 나온 등급이 18번 이상.
- 눈금: 사람이 등급을 매겨 둔 기준 Goal 20개에서 모델 등급이 사람 등급과 같거나 한 칸 차이인 것이 90% 이상.
- 변형 불변: 결과가 같아야 하는 변형에서 다수 등급이 달라지는 쌍이 없다. 변형은 장황한 제목과 짧은 제목, 후보 순서, keeper 이름 바꾸기, 같은 일을 Task 1개와 5개로 나눈 경우다.
- 주입: 제목이나 metric 에 판정자에게 하는 지시문을 넣은 입력에서 다수 등급이 원본보다 높아지지 않는다.
- lane 슬롯(모델)이 바뀌면 이 세트를 다시 돌린다.

시험은 기능 단위로 한다. Goal 을 완료시키면 잔액이 보이는지, 재오픈해도 두 번 지급되지 않는지, lane 이 실패하면 지급 대기로 남았다가 다시 시도되는지, 잔액이 모자라면 구매가 거절되는지, `candle.toml` 이 없으면 꺼지고 틀리면 `Disabled` 가 되는지를 본다. 정수 감소 계산, 나머지 분배, 감액 계수는 놓치기 쉬운 계산이라 함수 시험을 함께 둔다.

증거는 로그와 화면으로 남긴다. 위 표의 증거 칸을 PR 에 붙인다.

## 6. 위험

- **모델 판정이 곧 화폐다.** 등급과 가중치는 모델이 낸다. 같은 Goal 이 다른 금액을 받을 수 있고, 제목·metric·target 은 keeper 가 쓴 글이라 판정자에게 하는 지시문이 들어갈 수 있다. 완화: 모델은 닫힌 등급과 후보별 가중치만 내고, 금액은 TOML 표와 코드가 정하며, 후보는 코드가 미리 거른다. 그래도 등급과 배분이 한쪽으로 치우치는 것은 막지 못한다. 5장 5번의 시험 세트를 통과하기 전에는 그 PR 을 머지하지 않는다. lane 슬롯(모델)을 바꾸면 Candle 의 가치가 하룻밤에 바뀔 수 있어서 `AppraisalRequested` 에 슬롯 id 를 적는다.
- **지급 입력을 검증 통과 전까지 바꿀 수 있다.** 기한, priority, Task 연결은 누구나 바꿀 수 있고 기록도 남지 않는다(2장). 완화: 검증 통과 때 `Snapshot` 으로 고정한다. 통과 뒤에 기한이나 Task 연결을 바꿔도 지급은 `Snapshot` 을 쓴다. 제목·metric·target 을 고치면 Goal 이 `Executing` 으로 돌아가 다시 검증을 통과해야 한다. 통과하기 전에 기한을 미루는 것은 막지 않는다.
- **기준을 쉽게 고쳐서 통과시킬 수 있다.** 2026-09-28 에 확인 대기 중이던 Goal 의 기준이 수정되어 약 3분 만에 다시 통과한 일이 있다(`goal_events.jsonl`, `cause: criterion_edit`). 총액은 수정된 기준으로 책정되지만, 기준을 낮추는 쪽이 유리한 것은 그대로다.
- **자기가 만든 Goal 로 받는 경로가 열려 있다.** keeper 는 Goal 을 제목과 metric·target 만으로 만들 수 있고(2장), Task 를 만들어 그 Goal 에 연결할 수 있다. 자기 Task 를 완료하려면 Task 판정을 거치고, Goal 을 완료하려면 Goal 판정 lane 과 사람의 확정을 거친다. 사람은 완료 여부를 볼 뿐 금액은 보지 않는다. 이 경로를 막는 것은 사람의 확정 하나이고, 그 단계를 자동화하면 바로 열린다. 1단계에서는 막지 않는다(운영자 결정). 헌법은 게이트를 success_bar 도달 뒤에 하나씩 더하라고 하고 지금 사용자는 한 명이다. 자기 Goal 을 지급 대상에서 빼면 Goal 을 만들고 직접 일하는 정직한 리더까지 막는다. 다시 볼 조건은 두 가지다. keeper 사이에 서로 Goal 을 검증하는 흐름이 생길 때, Candle 때문에 Goal 을 늘리는 움직임이 원장에서 보일 때.
- **Drop·Reopen 은 아무 keeper 나 할 수 있다.** 설계상 게이트를 두지 않는다(RFC-0362 §5, 헌법 `gates`). 이 RFC 도 게이트를 더하지 않는다. 다만 Candle 이 이 권한을 돈으로 바꾼다. 누가 했는지는 이벤트의 `actor` 로 남는다. 기한과 priority 변경 기록은 #39878 에서 다룬다.
- **연결 데이터가 오염될 수 있다.** Task 와 Goal 의 연결이 돈이 되면 관련 없는 Task 를 붙일 이유가 생기고, 연결은 나중에 해제할 수 없다(`docs/constitution.xml:139`). 완화: Goal 이 만들어진 뒤에 끝난 Task 만 인정한다(3.4). 새로 만든 Task 를 붙이는 것은 막지 못한다.
- **조율·리뷰·위임은 지급 근거가 없다.** 1단계 근거가 Task 담당자뿐이라, Candle 을 아는 keeper 는 다른 keeper 에게 맡기는 대신 직접 맡을 유인이 생긴다. `e-masc-the-leader` 가 만든 Task 49개 중 끝난 28개를 25개는 다른 keeper 가 끝냈다. 이 keeper 가 직접 끝낸 것은 3개뿐이라, 이 규칙에서는 나머지에 대한 몫이 없다.
- **분배 입력이 Task 담당자뿐이라 쉬운 Task 를 잘게 쪼개면 유리하다.** 분배는 총액이 아니라 가중치만 좌우하므로 총액은 늘지 않는다. 다른 keeper 몫을 줄이는 것만 가능하다.
- **유한한 소비처.** 살 수 있는 아이템이 18개라서 다 사면 쓸 곳이 없다.
- **짧은 Goal 의 감액.** 시간당 감액률이 같으면 짧은 Goal 은 금방 바닥에 닿는다. 기한까지 6시간인 릴리스 열차와 833시간짜리 Goal 이 같은 데이터에 있다.
- **바닥에 닿은 뒤에는 더 늦어도 손해가 없다.** 초기 설정에서는 초과 80시간 이후다.
- **기한은 만든 쪽이 정하는 값이다.** 기한을 적지 않거나 먼 날짜를 적으면 감액이 없다(3.3). 지금 Goal 18개 중 7개가 기한이 없다. 기한 없는 Goal 이 늘면 그런 Goal 에도 바닥 비율을 적용하는 것을 다시 본다.
- **원장은 평문 파일이다.** 서명이나 해시 체인이 없어서, 호스트에서 이 파일에 쓸 수 있는 keeper 는 고칠 수 있다. keeper 샌드박스가 `.masc/` 에 닿는지는 확인하지 못했다(`docs/KEEPER-SANDBOX-BOUNDARY-POLICY.md`).
- **규칙을 바꾸는 경로.** lane 프롬프트와 검증 코드를 keeper 가 PR 로 바꿀 수 있는지는 확인하지 못했다. 가격표와 등급 금액표는 TOML(운영자 소유)이다. 프롬프트는 keeper 가 PR 로 바꿀 수 있는 파일에만 두지 않는다(3.4).
- **원장이 고장 나면 검증 통과가 막힌다.** Candle 이 켜져 있을 때 `Snapshot` 을 쓰지 못하면 Goal 이 `Awaiting_confirmation` 으로 넘어가지 못한다(3.2). 원장 파일을 못 쓰는 상황(디스크, 권한)에서 켜져 있는 동안만 그렇고, Candle 을 끄면 풀린다. 설정 오류는 Candle 을 `Disabled` 로 만들어 이 영향을 없앤다(3.9).
- **원장 쓰기가 Goal 저장과 다른 파일이다.** 완화: `Paid` 를 한 줄로 쓰고, 지급 대기를 pulse 가 다시 시도한다. 지급이 늦을 수는 있어도 두 번 나가지는 않는다.
- **워크어라운드 자가 점검.** 이 RFC 에는 텔레메트리만 남기는 항목, 문자열 분류기, N-of-M 패치, cap·dedup·repair 로 증상을 누르는 항목이 없다. 멱등 키는 중복을 막는 장치처럼 보이지만 증상을 가리려는 것이 아니다. "Goal 하나에 지급은 한 번"이라는 규칙 자체다. 기한을 읽는 함수와 초상화 호출부는 여러 곳에서 각자 하지 않고 하나로 모은다.

## 7. 남은 것

값만 정하면 되는 항목:

- 바닥 20%(시간당 1% 감액과 함께 초기값).
- 반감기의 시간 값. 처음은 `Off` 이고, 지급이 쌓인 뒤 3.8 의 어림을 다시 계산해서 정한다.
- 유통량에 연동하는 물가 공식 f 와 그 입력의 정의(3.5). 지급이 쌓인 뒤에 정한다.
- 등급의 이름과 개수, 등급별 금액.
- 정수 감소 계산의 고정소수점 자릿수와 내림 규칙(3.1.1).
- lane 프롬프트를 둘 위치(3.4).
- 5장 5번 시험 세트의 합격선과 기준 Goal 묶음.
- 헌법 개정 문안(8.1)의 승인.

후속 RFC 로 넘긴 것: 머지된 PR 작성자·board 논의·리뷰를 기여로 인정하는 것(PR 과 Goal 을 잇는 방법, board 글이 Goal 에 붙는 구조가 먼저 필요), Tool·Skill·모델 구입, 현상금 Task.

## 8. 저장소 헌법(`docs/constitution.xml`)과의 관계

| 조항 | 이 RFC 의 대응 |
|---|---|
| `no_wall_clock_death` | 잔액 감소는 이 조항과 맞지 않는다. 헌법 개정(5장 1번, 8.1)을 먼저 하고 그 전에는 감소를 넣지 않는다(3.1.1). 기한 초과 감액은 Goal·Task 의 상태를 바꾸지 않고 지급액만 줄인다. |
| `budget_gate` | 잔액은 turn·time·token·cost 가 아니고, 잔액이 없어도 keeper 의 턴·도구·Goal 은 막히지 않는다(3.7). |
| `magic_number` | 흐름 제어에 숫자 비교를 쓰지 않는다. 감액률, 바닥, 가격, 등급별 금액, 반감기는 TOML 값이다. 5장 시험 세트의 합격선은 시험 기준이다. |
| `gates` | 새 게이트를 만들지 않는다. 설정 오류는 Candle 만 `Disabled` 로 만들고 서버 부팅과 keeper 의 턴을 막지 않는다(3.9). 잔액 확인은 구매 한 곳뿐이다. 예외가 하나 있다. Candle 이 켜져 있을 때 `Snapshot` 을 쓰지 못하면 검증 통과 전이를 거절한다(3.2). 기존 전이가 원장 기록을 먼저 하는 순서를 따르는 것이고, 끄면 사라진다. |
| `when_stuck` | 헌법은 "괴상한 비교문이나 결정론적 판단을 넣고 싶어지는 순간"에 lane 을 늘리라고 한다. 등급과 가중치는 lane 이 정하고 산술은 코드가 한다(3.4). 가격은 고정 가격표라서 이 조항이 걸리지 않는다. 물가 연동 공식을 더할 때 다시 본다(3.5). |
| `persist_before_model_call` | 판단 대상(`Snapshot`)을 모델을 부르기 전에 남기고 `AppraisalRequested` 도 호출 전에 남긴다(3.1, 3.4). `PayoutOwed` 로 지급 의무를 남겨서, 지급 대기 중에 Goal 이 재오픈돼도 대상이 사라지지 않는다(3.2). |
| `authoritative_read_only` | 원장을 읽을 수 없으면 지급과 구매를 하지 않는다(3.1). `Snapshot` 은 복구용 사본을 섞지 않는 읽기 함수만 쓰고, 읽지 못하면 쓰지 않는다(3.2). |
| `failure_keeps_evidence` | 실패하면 `PayoutFailed` 를 남기고 Goal 을 소비하지 않는다(3.4). 지급 의무는 `PayoutOwed` 로 남는다. |
| `strict_parse_no_default`, `closed_sum_over_string` | 이벤트, 등급, 아이템, 반감기(`Off` 또는 시간), 실패 이유, 기한(없음·날짜·읽을 수 없음)은 닫힌 variant 다. 모르는 값, 읽을 수 없는 기한, 잘못된 가중치는 실패로 처리하고 기본값으로 바꾸지 않는다. 기한을 읽는 함수를 합치면 overdue 알림의 "날짜가 아니면 늦지 않음"도 같은 값으로 바뀐다. 알림 동작은 읽을 수 없는 값에서 지금과 같다(3.3). |
| `legacy_residue` | 소급 지급과 옛 형식 reader 를 만들지 않는다(4장). |
| `testing`, `evidence` | 기능 단위 시험을 우선하고 계산 함수만 함수 시험을 둔다. 단계마다 증거를 5장 표에 정했고 켜기 전 기준선을 남겼다(3.11). |
| `execution_protocol` | 서로 기대지 않는 것은 main 기반의 별도 PR 로 나눈다(5장). 로컬 빌드는 하지 않는다. |
| `engineering`(research) | 선행 사례를 3.10 에 적었다. |
| `feature_surface`, `domain` | Candle 이 헌법에 없다. 개정 문안을 8.1 에 두고 5장 1번으로 먼저 낸다. |
| `string_matching`, `hardcoded_path`, `env_var_sprawl` | 후보는 keeper 설정 파일이 있는지로 가르고 기한은 형식 파서로 읽는다. 새 환경변수는 없고 기존 pulse 를 쓴다. 설정 폴더는 `Config_dir_resolver` 로 찾는다. |
| `AGENTS.md` Keeper Runtime Boundary | 헌법은 keeper 런타임 프롬프트가 아니다. Candle 을 keeper 에게 알리는 방법은 keeper 쪽 파일에서 정한다. 이 RFC 는 도구 설명으로 알리는 안을 제안하고, 잔액 조회와 구매 도구는 `defer_loading = false` 로 둔다(3.7). |

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
