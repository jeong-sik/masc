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
- **[제안]** 후보는 둘이에요. (가) 지금 있는 길로 푸는 방법: Keeper 가 `Execute` 를 `run_in_background` 로 불러 run 을 기다려요. (나) 서버의 run 감시가 완료를 영수증으로 쓰는 방법. (나)를 정석으로 보고 이유와 대가를 5절에 적었어요.
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
- **[사실]** 왜 쓰지 않는지는 장부로 가르지 못해서 Keeper 에게 물었어요(2026-11-12 17:42 KST, Board 글 두 개). `masc-productor-owner` 가 1분 뒤 답했어요(글 `p-45dacfc018a91c4ab3a2eff9cd3e8af2` 의 댓글 `c-6f3a7f167d63cb4ede12b52e891300c9`). `rondo` 도 같은 날 12:21Z 에 답했어요(글 `p-e5fe85dd65a9be6aab87462f35410853` 의 댓글 `c-827445391a18ea0f33b66b17bc5f0498`).
- **[사실]** `masc-productor-owner` 의 답이에요. 기준을 문서로 쓴 적은 없고, 돌아보면 갈린 기준은 둘이에요. `sleep` 은 run 이 몇 분 안에 끝날 것 같고 그 결론이 바로 다음 판정에 필요할 때예요. `until_github_run` 은 수십 분이 걸리거나 기다리는 동안 다른 일을 할 수 있을 때예요. 한 턴에 `sleep` 을 24번 이은 것은 이 기준으로 설명되지 않고, 끝나는 시각을 모른 채 「한 번만 더」 기다린 것이라고 했어요. 163건과 41개 턴은 다시 세지 않았다고 했어요.
- **[사실]** `rondo` 의 답이에요. 기준을 글로 정해 둔 적은 없다고 했어요. `sleep` 은 표적 CI 가 몇 분 안에 끝날 것 같고 결과를 보고 바로 수리를 이어야 할 때, `until_github_run` 은 큐 정체로 수십 분 이상 걸릴 것 같을 때 골랐어요. 큐가 길어질 때도 습관으로 `sleep` 을 이은 경우가 있었고 그때는 일정 감시가 맞았다고 했어요. 216건이 push 뒤 `sleep` 이라는 수치는 맞는 지적이라고 했어요. 앞으로는 push 직후 run 을 한 번 읽어서 queued 이거나 이전 run 이 20분 넘게 걸렸으면 바로 `until_github_run` 을 만들겠다고 했어요. 로컬에서 OCaml 을 빌드할 수 없어 CI 표적 run 이 유일한 관측이라 대기가 잦다는 말도 했어요.
- **[제안]** 스스로 한 말이라 정황이에요. 이 기준에서 `sleep` 은 「결과가 있어야 다음으로 간다」일 때 쓰이고, 영수증 대기는 그 결과를 턴을 붙잡지 않고 받는 길이에요. 같은 경우에 맞아요.
- **[확인 필요]** 질문이 행동을 바꿨어요. 이 Keeper 는 같은 답에서 앞으로의 기준을 정했어요. 첫 `sleep`(약 4분)이 지나도 끝나지 않으면 같은 턴에서 `sleep` 을 더 잇지 않고 `until_github_run` 일정을 만들고, 결과 없이 진행할 수 없을 때만 한 번 더 기다린다는 거예요. 그래서 이 Keeper 의 2026-11-12 08:43Z 이후 값은 배포 전과 같은 조건이 아니에요. 6절에서 따로 적어요.

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
| 위험 | 영수증 형식과 `request_id` 의 의미가 바뀌면 실행 기록 `v3` 에 닿아요. 그러면 fresh state 가 또 필요할 수 있어요(구현 뒤: `v3` 는 바뀌지 않았어요. 아래 [사실]). |

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
| 모양 | 요청 레코드를 대기 시작 때 만든다. `recover_lost_disk_records` 가 「일정 행이 `Scheduled` 인 요청」은 `Lost` 로 바꾸지 않는다. 틱이 끝나면 영수증을 쓰고 요청을 끝낸다(지금 틱은 영수증을 쓰지 않아요. 아래 [사실]) | 원천이 `Request_record` 또는 `Schedule_row` 다. `waitable` 과 sweep 의 `read_record` 가 같은 합타입을 받고, 일정 행이 `Scheduled` 면 `Worker_may_exist`(`keeper_receipt_wait_sweep.ml:10`), 끝났으면 대기를 풀 영수증이 있어야 한다(아래 [사실]). 일정이 만든 대기의 키는 `schedule_id` 이고 영수증의 `call_id` 로 쓴다. 요청 레코드를 만들지 않는다 |
| 장점 | 대기 쪽 상태 기계와 실행 기록 형식이 그대로다 | 한 사실(일정이 끝났는가)을 한 곳에서만 읽어 어긋남이 없다. 정리 규칙에 예외를 두지 않는다 |
| 대가 | 정리 규칙이 생산자별 예외가 된다(지금 예외가 없다). 일정 행과 요청 레코드가 같은 사실이 두 곳에 따로 적혀서 일정은 끝났는데 요청이 `Running` 인 틈이 생긴다 | `receipt_obligation` 의 키 의미가 바뀌어서 실행 기록 `v3` 에 닿고 fresh state 가 또 필요할 수 있다. 영수증 대기 TLA+ 모델의 원천(`WaitingHasSource`)도 넓혀야 한다. 변경이 더 크다(구현 뒤: `v3` 는 바뀌지 않았다. 아래 [사실]) |

- **[제안]** (나-1b)를 정석으로 봐요. 근거는 이 저장소의 원칙(닫힌 합타입, 예외가 아니라 타입으로, 한 사실은 한 곳)이에요. 대가는 위 표의 마지막 줄이고, 영수증 대기 스택이 올라간 지 하루도 안 된 지금 `v3` 를 다시 건드리는 일이에요(구현해 보니 `v3` 는 바뀌지 않았어요. 아래 [사실]).
**[사실]** 일정 틱은 영수증을 쓰지 않아요. 끝난 run 을 읽으면 일정 행의 due time 을 지금으로 당기고 payload 의 메시지를 `wake_message` 로 바꿀 뿐이고, 일정 러너가 평소 due 일정처럼 Keeper 를 깨워요(`lib/schedule_run_watch.mli` 의 `tick` 설명, `lib/server/server_schedule_run_watch.ml` 의 `run_pass`). 대기는 outbox 에 `call_id = request_id` 인 영수증이 도착해야 풀려요(`keeper_receipt_wait_sweep.ml` 의 `lost_arguments` 가 `Outbox.contains_call` 로 봐요). 그래서 (나-1a)와 (나-1b) 모두 「일정이 끝났다」와 「대기를 풀 영수증」 사이가 비어 있어요.

**[사실]** (나-1b)는 두 층으로 구현했어요. 첫째 층(#51663)이 영수증을 쓰고, 둘째 층(#51673)이 `keeper_receipt_wait` 에서 그 영수증을 기다려요. 구현 전에 정하지 못했던 것은 이렇게 정했어요.

- **누가 영수증을 쓰나.** 일정 consumer(`Server_schedule_consumers.dispatch_keeper_receipt`)가 due 가 된 일정의 영수증을 `Outbox.retain` 으로 쓰고 `Keeper_client_tool_outbox_wake.notify` 로 Keeper 를 깨워요. 한 번만 깨우는 것은 아니에요(아래 [미해결] 2). 대기를 푸는 일은 writer 가 하지 않아요. 대기를 건 턴의 끝(`lib/keeper/keeper_turn.ml` 에서 `Keeper_receipt_wait_sweep.after_wait` 를 부르는 자리)과 maintenance pass 가 `Keeper_receipt_wait_sweep.after_wait` 를 불러서 outbox 를 읽고 풀어요.
- **깨움이 두 번 가지 않게.** 새 일정 kind 를 더하지 않고 `masc.keeper_wake` 본문에 `delivery`(`queue` 가 기본, `receipt`)를 더했어요. 값은 닫힌 합타입(`Keeper_wake_to_queue | Keeper_wake_to_receipt`)이고 `receipt` 는 큐 메시지를 넣지 않고 영수증만 써요. 새 kind 는 대상 Keeper 확인, Keeper 가 내려갈 때 일정 취소, 참여자, 결과 전달, run 감시 틱이 모두 갈래를 더해야 해서, 같은 일을 본문 필드로 하는 쪽이 변경 범위가 작았어요. `receipt` 는 `urgency` 와 같이 줄 수 없고 `one_shot` 만 받아요.
- **키는 `schedule_id`.** 처음 이 글은 `schedule_instance_id` 를 키로 적었는데 틀렸어요. run 감시가 끝나면 틱이 일정 행을 새 `schedule_instance_id` 로 다시 써서(`make_due` → `Schedule_service.update`), Keeper 가 `masc_schedule_create` 결과로 받은 id 와 영수증의 id 가 어긋나요. `schedule_id` 는 수정과 감시 정산을 거쳐도 그대로예요.
- **`tool_name` 은 `masc_schedule_create`, `arguments` 는 `Unknown`.** 감시가 끝나면 일정 payload 에서 감시가 지워지고 메시지가 바뀌어서, 부른 도구의 인자가 남아 있지 않아요.
- **실행 기록 `v3` 는 바뀌지 않았어요.** 대기 항목의 키가 이미 평범한 문자열(`request_id`)이라 일정 id 가 같은 자리에 들어가요. TLA+ `WaitingHasSource` 는 그대로이고, 영수증 없이 끝난 원천을 나타내는 `EndWithoutReceipt` 동작을 더했어요(`specs/bug-models/KeeperReceiptWait.tla`).
- **읽는 순서.** sweep 은 일정 행을 영수증(outbox)보다 먼저 읽어요. consumer 가 영수증을 쓴 뒤에 일정을 끝난 것으로 적기 때문에, 끝난 행인데 영수증이 없으면 정말 안 쓰인 거예요. 요청 레코드가 없고 일정 저장소를 읽을 수 없으면 대기는 풀리지 않고 다음 pass 로 가요. 읽지 못한 채 「잃었다」고 쓰면 아직 기다리는 일정에 거짓 영수증이 가요.
- **Keeper 가 고르는 `schedule_id`.** 요청 id 에는 `[A-Za-z0-9_.-]` 만 쓸 수 있는데 일정 id 는 공백이나 한글도 돼요. 요청 저장소가 그런 id 를 `Invalid_request_id` 로 거절하면 일정의 id 로 읽어요.

**[사실]** 시험은 한 번도 돌리지 않았어요(PR CI 는 `type-check` 만 돌려요). #51663·#51673 은 2026-11-12 12:01Z(21:01 KST)에 병합됐어요(`7ae0ee9530b0`, `8cc7dba8005c`). 같은 날 22:41 KST 에 `/health` 가 알린 실행 중 build `778e441d5df1` 는 둘 다 담고 있지 않아요(`git merge-base --is-ancestor` 가 둘 다 거짓). 그래서 아직 배포 전이에요. 효과는 6절의 지표로 새 build 를 배포한 뒤에 재요.

**[사실]** 일정 행을 지우는 `Schedule_service.prune`(`Schedule_store.prune_completed`)은 `Succeeded`·`Failed`·`Cancelled`·`Expired` 행만 지우고 `Scheduled`·`Due`·`Running` 행은 남겨요. 대기 중인 일정은 지워지지 않아요. 영수증 없이 끝난 일정이 sweep 보다 먼저 지워지면 `read_record` 가 행을 못 찾아요(`No_row`). 이때 요청 id 로 쓸 수 있는 글자만 든 id 는 요청 레코드가 `Absent` 라서 run 용 `Unknown` 영수증을 받고(문구가 run 기준이에요), 요청 id 로 쓸 수 없는 글자가 든 id 는 일정의 id 일 수밖에 없어서 일정용 `unfinished` 영수증을 받아요. 일정 id 와 같은 문자열의 요청 레코드가 있으면 요청 레코드를 먼저 읽어요(`read_record` 의 `Found`).

**[미해결]** 아래 둘은 #51663·#51673 에 그대로 들어 있어요. 독립 리뷰가 짚었고 코드로 확인했어요. 시험도 TLA+ 모델도 이 둘을 보지 않아요(모델은 영수증을 쓰는 생산자와 키를 두지 않아요).
1. **영수증 키가 일정 한 번(occurrence)의 유일한 이름이 아니에요.** `Keeper_schedule_receipt.retain_once` 는 outbox 에 같은 `call_id` 가 이미 있으면 쓰지 않아요(`Outbox.contains_call`). 이 비교는 `thread_id`(생산자)를 보지 않아요. `schedule_id` 는 Keeper 가 줄 수 있고(`Schedule_service.create ?schedule_id`), 행이 없으면 같은 id 로 만들 수 있어요(`insert_request` 는 행이 있을 때만 `Schedule_already_exists` 로 거절해요). 그래서 두 일이 생겨요. (a) 읽지 않은 영수증 A 가 outbox 에 남은 채 A 의 일정이 `prune` 으로 지워지고 같은 id 로 B 를 만들면, B 의 영수증은 쓰이지 않고 B 를 기다리는 대기가 A 의 옛 결과로 풀려요. (b) Keeper 가 Execute 요청 id 와 같은 문자열을 `schedule_id` 로 주면, sweep 은 그 id 를 run 으로 읽고 대기는 그 run 의 영수증으로 풀려요. 위 「끝난 행인데 영수증이 없으면 정말 안 쓰인 거예요」는 이 둘 사이에서는 맞지 않아요. **수리는 #51737 이에요(Ready, 병합 전).** 일정 본문에 `receipt_key` 를 두고 영수증의 `call_id` 와 대기의 이름으로 써요.
2. **ACK 뒤에 acceptance 가 실패하거나 서버가 재시작하면 영수증과 깨움이 반복돼요.** consumer 는 `commit_acceptance` 전에 `retain` 과 `notify` 를 해요. Keeper 가 영수증을 읽고 ACK 하면 파일이 지워지는데, 그 occurrence 가 `Due` 로 돌아오면 `retain_once` 는 이미 전달했다는 기록을 볼 수 없어서 같은 영수증을 다시 쓰고 다시 깨워요.

**[결정]** (사용자, 2026-11-13) 1 은 배포 전에 고치고, 키는 일정 본문에 둬요(#51737). 키는 일정을 쓸 때 한 번 뽑고, 수정과 감시 정산이 그대로 두어요. 실행 기록 `v3` 는 바뀌지 않아요. 키가 없는 영수증 일정은 due 가 되면 거절돼요. 2 는 닫지 않고 한계로 둬요. 이 저장소의 규칙이 근거예요. 새 상태는 없으면 durable truth 가 깨질 때만 더해요. 2 의 해는 같은 영수증을 한 번 더 읽는 소음이에요. #51737 이 병합되면 키가 일정마다 유일해서, 다시 쓰인 영수증이 다른 대기를 풀지는 않아요. 전달 기록을 일정 행에 더하면 상태가 하나 늘고, 그 상태가 막는 것은 이 소음뿐이에요. 1 의 시험(생산자 사이 충돌, prune 뒤 재생성)은 #51737 이 더했어요. PR CI 는 `type-check` 만 돌려서 시험은 돌려 보지 않았어요. ACK 뒤 재시작 시험은 없어요.

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
- **[제안]** `masc-productor-owner` 는 2026-11-12 08:43Z 에 스스로 기준을 바꿨어요(3절). 그 뒤의 값에는 영수증 대기 스택의 효과와 이 Keeper 의 자기 변경이 섞여요. 합계 표에는 이 Keeper 를 뺀 값을 같이 적고, 이 Keeper 는 `sleep_waits.py turns` 의 한 턴 최대 값으로 약속(첫 `sleep` 뒤 같은 턴에서 더 잇지 않기)이 지켜지는지만 따로 봐요.
- **[제안]** `rondo` 는 11-12 03:00Z 쯤부터 Claude Code 7일 한도로 거의 돌지 못했고, 런타임을 한도와 무관한 lane 으로 옮겼어요(`runtime.toml`, 서버가 읽으면 재개). 배포 전 창(72시간)은 거의 내내 돌았고 배포 뒤 창은 쉰 시간이 섞여서, 합계에는 Keeper 별 활동 시간을 같이 적어요.

## 7. 사용자가 정한 것과 정할 것

1. **결정(사용자, 2026-11-12): (가)를 건너뛰고 바로 (나)로 가요.** 이 글이 추천한 「(가)를 하루 먼저 본다」는 받아들여지지 않았어요. 11-13 16:47 의 `run_in_background` 비율은 (가)의 판정이 아니라 배포 뒤 기준선으로만 읽어요.
2. **결정(사용자, 2026-11-12): (나-1)을 정석으로 봐요.** 이 글이 (나-1)을 추천한 근거는 「막는 곳이 한 곳이라 변경 범위가 작다」였는데, 5.2 의 읽기에서 막는 곳이 둘이고 재시작 정리와 부딪친다는 것으로 바뀌었어요. 비용이 추천 때보다 커요. **결정(사용자, 2026-11-12): 추천대로 (나-1b)로 가요.** 구현은 이 RFC 가 병합된 뒤에 시작해요(사용자, 2026-11-12). 이 RFC(#51606)는 09:43Z 에 병합됐고 구현 PR #51663 은 09:55Z 에 열렸어요. 구현해 보니 실행 기록 `v3` 는 바뀌지 않았어요(5.2).
3. **결정(사용자, 2026-11-12): 예, 두 Keeper 에게 각자 한 번 물어요.** 2026-11-12 17:42 KST 에 Board 글 두 개로 보냈어요. `masc-productor-owner` 는 1분 뒤 답했어요(3절). 글 번호는 `rondo` 가 `p-e5fe85dd65a9be6aab87462f35410853`, `masc-productor-owner` 가 `p-45dacfc018a91c4ab3a2eff9cd3e8af2` 예요. 답은 글의 댓글에 와요. `rondo` 도 같은 날 12:21Z 에 답했어요(3절).
4. **결정(사용자, 2026-11-13): 영수증 키는 배포 전에 고치고 일정 본문에 둬요. ACK 뒤 재전달은 닫지 않고 한계로 문서화해요.** 5.2 [미해결] 1 은 #51737 이 고쳐요. 2 는 위 5.2 의 [결정]대로 둬요.

## 8. 확인하지 못한 것

- 두 Keeper 가 왜 이 모양에서 일정을 쓰지 않았는지. 둘의 답은 스스로 한 말이고 장부와 맞춰 보지 않았어요(3절). `rondo` 가 말한 「push 직후 run 을 한 번 읽고 queued 면 일정을 만든다」가 지켜지는지는 배포 뒤 창(6절)으로 봐요.
- (나-2)의 읽기를 일정 틱과 나누는 구조의 크기(5.2).
- 5.2 [미해결] 2(ACK 뒤 재전달)가 얼마나 자주 일어나는지. 재 보지 않았어요.
- 반복문 안의 `sleep` 276건(24.6시간) 중 GitHub 읽기가 차지하는 몫.
- `rondo` 가 run id 를 어디서 얻는지. 같은 턴의 `git push` 뒤라는 것만 알아요.
- 분류는 정규식이에요(`push`·`gh workflow run` 등 명령 목록, 리터럴 `sleep` 합). 셸 변수로 감춘 명령, 반복문의 `sleep` 은 놓쳐요.
- 이 창은 영수증 대기 스택 배포 전이에요. 배포 뒤 Keeper 가 달라졌는지 모르고, 24시간 값은 11-13 16:47 KST 에 읽어요.
- GitHub 읽기가 줄어드는 양은 재지 않았어요. 읽기 한도는 계정당 5,000건/시간이고 여러 에이전트가 같이 써요(`server_schedule_run_watch.ml` 머리 주석).
