---
rfc: "keeper-waits-for-its-own-github-run-in-the-same-turn"
title: "Keeper 가 방금 시작한 GitHub run 을 같은 턴에서 기다리는 방법"
status: Draft
created: 2026-11-12
updated: 2026-11-12
author: claude
supersedes: []
superseded_by: null
related: ["keeper-turn-ends-while-waiting-for-a-receipt-state-machine", "keeper-wakes-when-a-pr-check-finishes", "a-keeper-works-while-a-long-execute-runs", "execute-background-through-the-tool-outbox"]
implementation_prs: []
---

# RFC: Keeper 가 방금 시작한 GitHub run 을 같은 턴에서 기다리는 방법

이 문서는 측정과 설계 후보를 적어요. 코드는 쓰지 않았어요.
표시: **[사실]** 은 코드나 장부에서 직접 읽은 것(파일, 명령, 수치)이에요. **[제안]** 은 이 RFC 가 정하려는 것이에요. **[확인 필요]** 는 아직 모르는 것이에요.
시각은 따로 적지 않으면 UTC 예요. 창은 2026-11-09T07:40:23Z ~ 11-12T07:40:23Z(72시간)이고, 11-12 07:40:23Z 는 영수증 대기 스택이 올라간 서버가 시작한 때예요. 이 창의 값은 모두 그 배포 전이에요.

## 0. 요약

- **[사실]** 이 창에서 60초 이상 앞에서 기다린 `Execute` 는 1,168건, 76.8시간이에요. 이 중 `sleep` 이 호출 시간의 절반 이상인 호출이 602건(40.3시간)이에요. `sleep` 과 `gh` 를 함께 쓴 호출이 535건(36.6시간)이고, 그 가운데 Actions run 을 기다린 호출이 315건(23.9시간)이에요(2절).
- **[사실]** 이 대기는 두 Keeper 에 몰려 있어요. `rondo` 223건(14.4시간), `masc-productor-owner` 163건(13.9시간)이 합계의 72%(호출), 77%(시간)예요. 두 Keeper 도 `until_github_run` 이나 `until_github_checks` 를 각각 13번, 22번 이미 걸었어요(3절).
- **[사실]** `rondo` 의 223건 중 216건(97%)은 같은 턴에서 `git push`, `gh workflow run`, `gh pr create|merge|ready` 를 한 뒤에 와요. `sleep` 이 두 번 이상인 턴에서 212건이 나오고, 한 턴에서 가장 많은 것은 40번이에요(3절).
- **[제안]** 이 대기는 「깨워 주세요」가 아니라 「이 턴에서 결과를 보고 이어서 일하겠다」예요. 기존 `until_github_run` 은 깨움이 새 턴으로 오는 모양이라 이 모양에 맞지 않아요. 영수증 이어달리기(`keeper_receipt_wait`)는 같은 작업을 이어받는 길이라 모양이 맞아요(4절).
- **[제안]** 후보는 셋이에요. (가) 지금 있는 길로 푸는 방법: Keeper 가 `Execute` 를 `run_in_background` 로 불러 run 을 기다려요. (나) 서버의 run 감시가 완료를 영수증으로 쓰는 방법. (다) 서버가 한 번 호출에서 run 이 끝날 때까지 기다렸다가 돌려주는 방법. (나)를 정석으로 보고 이유와 대가를 5절에 적었어요.
- **사용자가 정할 것**은 7절에 있어요.

## 1. 이 글이 정하는 것

**정하는 것.**
- 같은 턴에서 자기 run 을 기다리는 Keeper 에게 어떤 길을 줄지(4절, 5절).
- 그 길을 고른 뒤 무엇을 재서 효과를 판정할지(6절).

**정하지 않는 것.**
- 도구 이름과 도구 설명 문장. Keeper 프롬프트 문장.
- 폴링 간격, 횟수 상한, cooldown 같은 상수. 새 상수를 더하지 않아요.
- `Execute` 가 명령 글자를 보고 감시를 자동으로 거는 일. `Execute` 는 명령을 해석하지 않아요(`config/tools/tool_execute.toml:6`).
- check 를 기다리는 길. `keeper-wakes-when-a-pr-check-finishes` 가 다뤄요. 이 글은 Actions run 하나를 기다리는 모양만 다뤄요.
- 영수증을 기다리며 턴이 끝나는 상태 기계. `keeper-turn-ends-while-waiting-for-a-receipt-state-machine` 이 정했고 그 스택이 11-12 16:40 KST 에 올라갔어요.

## 2. 앞에서 오래 기다린 시간이 어디에 쓰였나

출처는 `~/me/.masc/tool_calls` 장부이고, 스크립트와 결과는 `docs/evidence/tool-efficiency-1112-2026-11/` 에 있어요(`sleep_waits.py`, 시험 22개). 모양은 명령 글자로 가르는데, 세는 데만 쓰고 제품 규칙이 아니에요.

| 모양 | 호출 | 시간 |
|---|---:|---:|
| 60초 이상 앞에서 기다린 `Execute`(`run_in_background` 가 아닌 것) | 1,168 | 76.8 h |
| 리터럴 `sleep` 합이 호출 시간의 절반 이상 | 602 | 40.3 h |
| ... `sleep` 과 `gh` | 535 | 36.6 h |
| ... `sleep` 과 자기 background 작업 | 45 | 2.3 h |
| ... `sleep` 만 | 22 | 1.4 h |
| `sleep` 이 있으나 리터럴 합이 절반 미만(반복문 안의 `sleep` 으로 추정) | 276 | 24.6 h |

`sleep` 과 `gh` 535건이 읽은 것은 다음과 같아요.

| 읽은 것 | 호출 | 시간 |
|---|---:|---:|
| Actions run(`gh run`, `/actions/runs`) | 315 | 23.9 h |
| check run, `gh pr checks`, status | 147 | 8.7 h |
| 리뷰, 댓글 | 35 | 2.2 h |
| PR 상태 | 23 | 0.8 h |
| 그 밖의 `gh` | 15 | 0.9 h |

- **[사실]** 같은 창에서 `Execute` 는 84,068건이고 `run_in_background` 는 109건(0.13%)이에요. 그 109건은 `wkbl-data` 47, `ocaml-agent-ic` 19, `goo-yang-bong` 12, `code-reviewer-father` 8 등에 몰려 있어요. 60초 이상 앞에서 기다린 호출 중 `run_in_background` 인 것은 정의상 없어요.
- **[사실]** 리터럴 `sleep` 합은 `rondo` 의 호출마다 중앙값 240초(p10 120초, p90 300초), `masc-productor-owner` 는 중앙값 290초(p10 105초, p90 480초)예요.
- **[사실]** `keeper-wakes-when-a-pr-check-finishes` §1 은 창 A(11-08T05:40Z~11-11T05:40Z)의 `pr_checks`·`commit_checks` 를 308건, 18.946시간으로 셌어요. 이 글의 Actions run 315건과 check 147건은 창과 분류 규칙이 달라서 합치지 않아요. 같은 장부의 서로 다른 72시간이에요.
- **[확인 필요]** 반복문 안의 `sleep` 276건(24.6시간)은 횟수를 몰라서 위 「절반 이상」에 들지 못했어요. 그 안에 `gh` 읽기가 얼마나 있는지 이 글은 가르지 않았어요.

## 3. 누가 어떤 모양으로 기다렸나

`keeper_turn_id` 는 Keeper 마다 따로 매겨져서 두 Keeper 의 턴이 합쳐지지 않아요(`rondo` 의 163개 id 중 상위는 9328, 9337, 9344).

| Keeper | 호출 | 시간 | 턴 | 같은 턴에서 push·run 시작 뒤 | `sleep`+`gh` 가 2번 이상인 턴의 호출 | 한 턴 최대 | `until_github_*` 를 건 횟수 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `rondo` | 223 | 14.4 h | 31 | 216 | 212 | 40 | 13 |
| `masc-productor-owner` | 163 | 13.9 h | 41 | 25 | 145 | 24 | 22 |
| `wkbl-data` | 78 | 4.6 h | 21 | 55 | 72 | 11 | 10 |
| 그 밖 14명 | 71 | 3.7 h | | | | | |

- **[사실]** 합계로는 17명 중 12명이 창 안에서 `until_github_run` 이나 `until_github_checks` 를 한 번은 걸었어요. 걸린 일정은 모두 262건이에요. `sleep` 과 `gh` 로 기다린 호출은 535건이에요.
- **[사실]** `rondo` 의 가장 긴 턴(id 9328)은 `sleep`+`gh` 호출이 40번이고, 첫 호출부터 마지막 호출까지 3.97시간이에요. 호출 시간의 합은 2.47시간이에요.
- **[사실]** `tool_execute.toml` 설명이 이미 「`sleep` 루프는 대기 내내 턴을 붙잡는다. Actions run 은 `masc_schedule_create` 의 `until_github_run` 으로 기다린다」를 적고 있어요(`config/tools/tool_execute.toml`). `masc_schedule_create` 와 `masc_schedule_update` 는 `defer_loading = true` 예요(`config/tools/masc_schedule_create.toml:27`).
- **[제안]** 이 값은 「도구가 있는지 몰라서」가 원인이 아니라는 것을 보여요. 두 주인은 도구를 알고 쓰는데도 이 모양에서는 쓰지 않아요.
- **[확인 필요]** 왜 쓰지 않는지는 장부로 가르지 못했어요. 후보는 4절에 있고, 확인하려면 Keeper 에게 일반 메시지로 묻는 길이 있어요(7절 4).

## 4. 왜 이 모양에는 지금 길이 맞지 않나

**[사실]** `until_github_run` 의 길은 이래요(`lib/schedule_run_watch.mli:1-10`, `lib/server/server_schedule_run_watch.ml`). Keeper 가 `masc_schedule_create` 로 일정을 만들면, 서버가 30초마다(`poll_interval_sec = 30.0`) 걸린 run 을 읽고, 끝나면 일정의 시각을 지금으로 당겨 일반 wake 로 Keeper 를 깨워요. 같은 run 을 기다리는 일정이 여럿이어도 한 번만 읽어요(`reads_once`).

이 길이 「같은 턴에서 이어 쓰기」에 맞지 않는 이유는 모양에 있어요.
1. 일정을 만든 턴은 끝나야 해요. 깨움은 새 턴으로 와요. 같은 작업의 이어달리기가 아니고, 그 사이 큐에 다른 작업이 들어와 있을 수 있어요.
2. 깨움 메시지는 일정을 만들 때 쓴 `message` 이고 그 이상을 싣지 않아요(`settle_payload`). run 의 결과를 Keeper 가 다시 `gh` 로 읽어야 해요.
3. 일정은 정해진 `due` 를 요구해요. `rondo` 의 한 호출 중앙값(리터럴 `sleep` 합 240초)처럼 「몇 분 안」으로 끝나는 run 에도 마감 시각을 골라야 해요.

**[제안]** 후보 근거. 영수증 이어달리기(`keeper_receipt_wait`)는 이 모양에 맞아요. 모델이 영수증 하나를 기다리겠다고 부르면 턴이 끝나고, 영수증이 오면 같은 작업이 체크포인트에서 이어가요. 영수증 한 장은 `receipt = {thread_id; turn_id; call_id; tool_name; arguments; response}` 이고 `request_id` 는 `Execute` 의 `run_in_background` 가 돌려준 것만 받아요(`config/tools/keeper_receipt_wait.toml`, `lib/keeper/keeper_client_tool_outbox.mli:13-19`).

## 5. 후보

### 5.1 (가) 지금 있는 길

Keeper 가 `Execute` 를 `run_in_background` 로 불러 `gh run watch <id>` 나 `sleep; gh api` 루프를 서버에서 돌리게 하고, 그 `request_id` 를 `keeper_receipt_wait` 에 넘겨요.

| | |
|---|---|
| 장점 | 새 코드가 없어요. 영수증 이어달리기가 11-12 16:40 KST 부터 서버에 있어요. |
| 대가 | 서버가 Keeper 마다 `gh` 폴링 프로세스를 따로 돌려요. 같은 run 을 기다리는 여럿이 읽기를 나누지 못해요(`until_github_run` 은 한 번만 읽어요). 샌드박스에서 `gh` 가 돌 수 있어야 해요(권한은 `Execute` 의 `intent` 와 Gate 가 정해요). |
| 한계 | 이 글의 창에서 `run_in_background` 비율은 0.13% 예요. 배포 뒤 이 비율이 오르는지가 먼저 보여야 해요(6절). 오르지 않으면 이 후보는 쓰이지 않는 거예요. |

### 5.2 (나) run 감시가 완료를 영수증으로 쓰는 방법 — 추천

`until_github_run` 의 서버 틱이 run 이 끝났을 때, 일정을 당기는 것과 같은 자리에서 그 Keeper 의 outbox 에 영수증을 쓰고 Keeper 를 `Tool_result_ready` 로 깨워요. 영수증을 쓰는 쪽(생산자)이 `Execute` 의 background 와 한 가지가 늘어나요.

| | |
|---|---|
| 장점 | 읽기는 지금 틱이 하는 것 그대로예요(같은 run 은 한 번). 새 폴링이 없어요. 영수증 이어달리기와 이어받는 길, 소유, 재시작 처리를 그대로 써요. |
| 대가 | 막는 곳이 둘이에요(아래). 일정 행에는 요청 레코드가 없는데 대기는 레코드가 있어야 해서, 요청 레코드를 대기를 시작할 때부터 누가 갖는지 정해야 해요. 서버가 재시작하면 끝나지 않은 요청에 영수증을 써 주는 길(`deliver_unfinished_runs`)과 레코드를 정리하는 길도 생산자마다 따로 있어요. |
| 위험 | 영수증 형식과 `request_id` 의 의미가 바뀌면 실행 기록 `v3` 에 닿아요. 그러면 fresh state 가 또 필요할 수 있어요. |

**[사실]** `Keeper_msg_async` 는 Execute 전용이 아니에요. 요청 레코드가 생산자의 맥락(`request_context`)을 들고(`lib/keeper/keeper_msg_async.mli:51-53`), `lib/fusion/fusion_tool.ml:226` 이 `submit_with_request_id` 로 Execute 이외의 생산자로 이미 쓰고 있어요. `poll` 과 `cancel` 은 무엇이 요청을 만들었는지 보지 않아요(`lib/keeper/keeper_execute_background.ml:76-78` 주석).

**[사실]** 막는 곳은 둘이에요.
1. `lib/keeper/keeper_tool_receipt_wait.ml:45-49` 의 `waitable` 이 요청 레코드에서 `Keeper_execute_background.request_arguments` 를 읽어 `None` 이면 「This request is not a background Execute run.」으로 거절해요. 레코드가 아예 없으면(`Absent`) 「No background run of this Keeper has this request_id.」예요.
2. `lib/keeper/keeper_receipt_wait_sweep.ml:13-23` 의 `read_record` 가 `Absent` 와 Execute 가 아닌 요청을 `Ended Unknown`(끝났고 인자를 모름)으로 읽고, 그 요청의 영수증이 outbox 에 없으면 `settle_lost` 가 `unfinished` 영수증을 써서 대기를 끝내요. 그래서 요청 레코드 없이 기다리면 다음 pass 에서 잃은 것으로 처리돼요. 그 영수증을 쓰는 `retain_source_lost_receipt` 도 Execute 모듈에 있어서 `thread_id` 가 `execute_background`, `tool_name` 이 `tool_execute` 예요.

**[사실]** 영수증 한 장의 `thread_id` 는 생산자 이름(`execute_background`), `tool_name` 은 `tool_execute` 예요(`keeper_execute_background.ml:9`, `:67-71`). 새 생산자는 자기 이름을 가져야 해요.

**[사실]** 일정 행(`until_github_run`)은 `Keeper_msg_async` 요청이 아니에요. `lib/schedule_run_watch.mli:1-10` 은 이 모듈이 상태를 따로 갖지 않고 일정 행이 유일한 기록이라고 적어요. 그래서 일정 틱이 영수증만 쓰면 `waitable` 이 `Absent` 로 거절해요.

**[제안]** 그래서 (나)는 두 모양이에요.
- (나-1) 일정 틱이 run 읽기를 이어서 맡아요. 처음 그린 모양은 (나-1a)예요. `masc_schedule_create` 가 `until_github_run` 을 받으면 일정 행과 함께 요청 레코드를 대기 시작 때 만들고(`Running`), 응답에 `request_id` 를 실어요. 요청 레코드를 만들지 않고 대기의 원천을 넓히는 (나-1b)는 아래에 있어요. 일정 틱은 지금처럼 run 을 한 번만 읽고, 끝나면 영수증을 쓰고 요청을 끝내요. 일정 응답은 `schedule_request_to_yojson` 에 파생 필드를 붙인 객체라 `schedule_id`·`schedule_instance_id` 가 들어 있고 `request_id` 는 없어요(`lib/schedule/schedule_domain.ml:894-897`, `lib/tool_schedule.ml:583-`).
- (나-2) 새 생산자가 `Keeper_msg_async` 요청을 만들고 그 worker 가 서버의 run 읽기 결과를 기다려요. 요청·소유·재시작은 지금 길 그대로지만, 읽기를 일정 틱과 나누는 구조가 새로 필요해요. 나누지 못하면 서버 안의 폴링이 Keeper 마다 늘어서 (가)와 같은 대가가 돼요.
**[사실]** 서버가 시작할 때 `Keeper_msg_async.recover_lost_disk_records` 가 worker 없이 디스크에 남은 `Queued`·`Running` 요청을 모두 `Lost` 로 바꾸고, 생산자별 예외가 없어요(`lib/keeper/keeper_msg_async.mli:486-495`). 그 앞에서 Execute 의 `deliver_unfinished_runs` 만 돌아요(`lib/server/server_bootstrap_maintenance.ml:375-376`). 대기 항목 `receipt_obligation` 은 `request_id : string` 하나로 키를 갖고 「background-run request」라고 문서화돼 있어요(`lib/keeper_chat_operations/keeper_semantic_execution.mli:45-47`).

**[제안]** 그래서 (나-1)은 두 갈래예요. 일정 행은 재시작 뒤에도 살아서 틱이 이어가는데 요청 레코드는 `Lost` 로 끝나는 어긋남을 어떻게 막느냐가 달라요.

| | (나-1a) 재시작 정리가 일정에 걸린 요청을 건너뛴다 | (나-1b) 대기의 원천을 닫힌 합타입으로 넓힌다 |
|---|---|---|
| 모양 | 요청 레코드를 대기 시작 때 만든다. `recover_lost_disk_records` 가 「일정 행이 `Scheduled` 인 요청」은 `Lost` 로 바꾸지 않는다. 틱이 끝나면 영수증을 쓰고 요청을 끝낸다(지금 틱은 영수증을 쓰지 않아요. 아래 [사실]) | 원천이 `Request_record` 또는 `Schedule_row` 다. `waitable` 과 sweep 의 `read_record` 가 같은 합타입을 받고, 일정 행이 `Scheduled` 면 `Worker_may_exist`(`keeper_receipt_wait_sweep.ml:10`), 끝났으면 대기를 풀 영수증이 있어야 한다(아래 [사실]). 일정이 만든 대기의 키는 `schedule_instance_id` 이고 영수증의 `call_id` 로 쓴다. 요청 레코드를 만들지 않는다 |
| 장점 | 대기 쪽 상태 기계와 실행 기록 형식이 그대로다 | 한 사실(일정이 끝났는가)을 한 곳에서만 읽어 어긋남이 없다. 정리 규칙에 예외를 두지 않는다 |
| 대가 | 정리 규칙이 생산자별 예외가 된다(지금 예외가 없다). 일정 행과 요청 레코드가 같은 사실이 두 곳에 따로 적혀서 일정은 끝났는데 요청이 `Running` 인 틈이 생긴다 | `receipt_obligation` 의 키 의미가 바뀌어서 실행 기록 `v3` 에 닿고 fresh state 가 또 필요할 수 있다. 영수증 대기 TLA+ 모델의 원천(`WaitingHasSource`)도 넓혀야 한다. 변경이 더 크다 |

- **[제안]** (나-1b)를 정석으로 봐요. 근거는 이 저장소의 원칙(닫힌 합타입, 예외가 아니라 타입으로, 한 사실은 한 곳)이에요. 대가는 위 표의 마지막 줄이고, 영수증 대기 스택이 올라간 지 하루도 안 된 지금 `v3` 를 다시 건드리는 일이에요.
**[사실]** 일정 틱은 영수증을 쓰지 않아요. 끝난 run 을 읽으면 일정 행의 due time 을 지금으로 당기고 payload 의 메시지를 `wake_message` 로 바꿀 뿐이고, 일정 러너가 평소 due 일정처럼 Keeper 를 깨워요(`lib/schedule_run_watch.mli` 의 `tick` 설명, `lib/server/server_schedule_run_watch.ml:119-133`). 대기는 outbox 에 `call_id = request_id` 인 영수증이 도착해야 풀려요(`keeper_receipt_wait_sweep.ml:46`). 그래서 (나-1a)와 (나-1b) 모두 「일정이 끝났다」와 「대기를 풀 영수증」 사이가 비어 있어요.

**[확인 필요]** (나-1b)를 구현하기 전에 정할 것이 둘이에요. 두 가지 모두 읽지 않았고, (나-1b)의 크기는 여기에 달려 있어요.
- 누가 영수증을 쓰는가. 후보는 일정 러너가 일정을 깨울 때 `call_id = schedule_instance_id` 영수증을 쓰는 것이에요. 새 writer 가 하나 생기고, `response` 는 `wake_message` 와 같은 글이에요.
- 깨움이 두 번 가지 않게 하는 방법. 일정 러너의 깨움은 Keeper 를 깨우고, 대기 중인 실행은 영수증으로 이어가요. 대기가 걸린 일정의 깨움을 영수증 하나로 합치지 못하면 Keeper 가 같은 결과를 두 번 받아요. 깨움이 대기 중인 실행에 어떻게 닿는지는 읽지 않았어요.

**[사실]** 일정에는 payload kind 가 둘 있어요: `masc.keeper_wake`, `masc.lane_act`(`lib/schedule/schedule_supported_kinds.ml`). kind 를 더하려면 그 파일의 목록, `Tool_schedule.validate_known_payload_request` 의 검증 갈래, `server_schedule_consumers.ml` 의 dispatch 가 모두 필요해요(같은 파일 머리말). 일정 틱은 Keeper wake 본문의 `until_github_run` 만 스캔해요(`watch_of_payload` 는 Keeper wake 가 아닌 payload 에 `Ok None`).

**[제안]** 위 두 가지를 한 번에 푸는 후보는 kind 를 하나 더하는 거예요(`masc.keeper_receipt`, 이름은 정하지 않았어요). 이 kind 의 consumer 는 일정이 due 가 되면 Keeper 를 깨우지 않고 outbox 에 `call_id = schedule_instance_id` 영수증을 쓰고 Owner 에게 알려요(`keeper_receipt_wait_resolution.ml` 의 `tell_owner`). 깨움이 없으니 같은 결과를 두 번 받지 않고, 영수증을 쓰는 자리가 consumer 한 곳이에요. 대가는 세 가지예요. 일정 틱이 새 kind 도 스캔하게 넓혀야 하고, `keeper_receipt_wait` 의 `waitable` 이 `schedule_instance_id` 를 받아야 하고, 5.2 의 합타입에 일정 행을 읽는 갈래가 들어가요.
- **[사실]** 쓸 수 있어요. `Outbox.retain ~base_path ~keeper_name receipt` 는 실행 scope 나 producer 없이 평범한 레코드를 받아요. 서버 쪽 writer 인 Execute 배경 실행은 이미 `thread_id = producer_label`, `turn_id = call_id = request_id` 로 채우고(`lib/keeper/keeper_execute_background.ml:66-73`), 영수증을 쓴 뒤 `Keeper_client_tool_outbox_wake.notify` 로 Keeper 를 한 번 깨워요(같은 파일 `deliver`). 새 kind 의 consumer 도 `thread_id = "schedule_run_watch"`, `turn_id = call_id = schedule_instance_id` 로 같은 길을 쓰면 돼요. 깨움은 영수증 길의 한 번뿐이에요.
- **[확인 필요]** 일정 consumer 에서 대기 Owner 를 풀고(`tell_owner`) 영수증이 아직 안 읽혔는데 Keeper 를 깨우는 순서가 `deliver` 와 같은지, 영수증의 `tool_name` 을 무엇으로 둘지는 읽지 않았어요.
- **[확인 필요]** (나-2)에서 읽기를 일정 틱과 나누는 구조의 크기는 읽지 않았어요.

### 5.3 (다) 서버가 한 번 호출에서 끝까지 기다렸다가 돌려주는 방법

도구 하나를 새로 두어 Keeper 가 run URL 과 최대 시간을 주면, 서버가 그 호출 안에서 기다리다가 끝나면 결과를 돌려줘요.

| | |
|---|---|
| 장점 | Keeper 가 부르는 모양이 `sleep; gh` 와 같아서 쓰기 쉬워요. 호출 수는 40번에서 1번으로 줄어요. |
| 대가 | 그 호출이 열려 있는 동안 Keeper 의 턴과 큐가 막혀요. 지금 `sleep` 루프가 막는 것과 같은 비용이에요. 줄어드는 것은 모델 요청과 GitHub 읽기이고, 큐 대기(이 RFC 가 줄이려는 시간)는 그대로예요. 영수증 대기 RFC 가 이 모양을 「호스트가 도는 턴을 붙잡는다」로 물리쳤어요. |
| 판단 | 모양이 지금과 같아서 큐 대기를 줄이지 못해요. 후보로 남기되 추천하지 않아요. |

## 6. 재는 것

**[제안]** 후보를 고르기 전에 이미 있는 영수증 이어달리기가 이 모양을 흡수하는지부터 재요. 판정은 사용자가 정한 대로 11-15 16:47 KST 의 72시간 측정과 같은 창을 써요.

| 지표 | 정의 | 배포 전(이 글의 창) | 판정 |
|---|---|---:|---|
| `Execute` 중 `run_in_background` 비율 | `sleep_waits.py share` | 0.13% | 이 비율이 의미 있게 오르지 않으면 (가)는 쓰이지 않아요 |
| 60초 이상 앞에서 기다린 호출 | `sleep_waits.py shapes` | 1,168건, 76.8 h | 배포 뒤 같은 정의로 비교해요 |
| `sleep`+`gh` 호출, 그중 Actions run | `sleep_waits.py shapes` | 535건 36.6 h, 315건 23.9 h | (나)를 고르면 줄어들어야 해요 |
| 한 턴의 `sleep`+`gh` 호출 최대·2번 이상인 턴의 호출 | `sleep_waits.py turns` | 40, 212(`rondo`) | 같은 턴 폴링이 줄었는지 |
| `until_github_*` 일정 수와 `sleep`+`gh` 의 비 | `sleep_waits.py turns` | 262 대 535 | |

- **[제안]** 정량 기준은 새로 정하지 않아요. 위 값을 같은 정의로 다시 읽고, 줄지 않으면 해당 후보를 지우는 쪽으로 보고해요.
- **[제안]** 이 글의 값은 모두 배포 전이에요. 배포 뒤 값은 영수증 대기 RFC 의 72시간 측정(11-15 16:47 KST)에서 같은 스크립트로 읽어요.

## 7. 사용자가 정한 것과 정할 것

1. **결정(사용자, 2026-11-12): (가)를 건너뛰고 바로 (나)로 가요.** 이 글이 추천한 「(가)를 하루 먼저 본다」는 받아들여지지 않았어요. 11-13 16:47 의 `run_in_background` 비율은 (가)의 판정이 아니라 배포 뒤 기준선으로만 읽어요.
2. **결정(사용자, 2026-11-12): (나-1)을 정석으로 봐요.** 이 글이 (나-1)을 추천한 근거는 「막는 곳이 한 곳이라 변경 범위가 작다」였는데, 5.2 의 읽기에서 막는 곳이 둘이고 재시작 정리와 부딪친다는 것으로 바뀌었어요. 비용이 추천 때보다 커요. **결정(사용자, 2026-11-12): 추천대로 (나-1b)로 가요.** 대가는 실행 기록 `v3` 를 다시 건드리는 것이에요. 5.2 의 두 가지(누가 영수증을 쓰는가, 깨움 합치기)를 정한 뒤에 구현해요.
3. **(다)를 지울까요.** 사용자가 되물었어요(11-12): (다)가 무엇인지 설명을 기다려요. 결정 전이에요. 이 글은 닫기를 추천해요. 호출 수는 40번에서 1번으로 줄지만, 호출이 열려 있는 동안 Keeper 의 턴과 큐가 막히는 것은 지금 `sleep` 루프와 같아서 줄이려는 큐 대기(15.519 h)가 그대로예요.
4. **결정(사용자, 2026-11-12): 예, 두 Keeper 에게 각자 한 번 물어요.** 이 글을 쓴 세션에서는 `mcp__masc__*` 도구가 연결되지 않아 아직 보내지 못했어요. 보낸 뒤 답은 Board 글의 댓글에 와요.

## 8. 확인하지 못한 것

- 두 주인이 왜 이 모양에서 일정을 쓰지 않는지. 3절은 정황이에요.
- (나-2)의 읽기를 일정 틱과 나누는 구조의 크기(5.2).
- 반복문 안의 `sleep` 276건(24.6시간) 중 GitHub 읽기가 차지하는 몫.
- `rondo` 가 run id 를 어디서 얻는지. 같은 턴의 `git push` 뒤라는 것만 알아요.
- 분류는 정규식이에요(`push`·`gh workflow run` 등 명령 목록, 리터럴 `sleep` 합). 셸 변수로 감춘 명령, 반복문의 `sleep` 은 놓쳐요.
- 이 창은 영수증 대기 스택 배포 전이에요. 배포 뒤 Keeper 가 달라졌는지 모르고, 24시간 값은 11-13 16:47 KST 에 읽어요.
- GitHub 읽기가 줄어드는 양은 재지 않았어요. 읽기 한도는 계정당 5,000건/시간이고 여러 에이전트가 같이 써요(`server_schedule_run_watch.ml` 머리 주석).
