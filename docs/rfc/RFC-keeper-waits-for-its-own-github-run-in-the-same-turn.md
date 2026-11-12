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
| 대가 | `keeper_receipt_wait` 가 `Execute` 가 돌려준 `request_id` 만 받는 계약을 넓혀야 해요. 영수증의 `tool_name`·`arguments` 와 요청 레코드(`Keeper_msg_async.entry`)가 Execute 전용인지 확인이 필요해요(아래). 일정 쪽은 `due` 를 여전히 요구해요(5.3 참고). |
| 위험 | 영수증 형식과 `request_id` 의 의미가 바뀌면 실행 기록 `v3` 에 닿아요. 그러면 fresh state 가 또 필요할 수 있어요. |

**[확인 필요]** `Keeper_msg_async.entry` 는 「producer」 개념을 갖고 있어요(`lib/keeper/keeper_msg_async.mli:52, 318, 369`). Execute 이외의 생산자가 이 레코드를 만들 수 있는지, `request_arguments`(`lib/keeper/keeper_execute_background.mli:63`)가 Execute 만 읽는지는 읽지 않았어요. 이 확인이 (나)의 변경 범위를 정해요.

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

## 7. 사용자가 정할 것

1. **먼저 (가)의 채택을 볼까요.** 영수증 이어달리기가 올라간 지금 `run_in_background` 비율이 오르는지 11-13 16:47 KST 중간 확인에서 읽고, 오르지 않을 때만 (나)로 가요. 대가는 하루를 더 기다리는 것이에요. 추천이에요.
2. **(나)를 정석으로 볼까요.** 영수증 쓰기 쪽을 넓히는 일이라 `Keeper_msg_async` 의 생산자 계약을 먼저 읽어야 해요(5.2). 그 확인을 이 RFC 의 다음 갱신으로 받을지 결정해 주세요.
3. **(다)를 지울까요.** 큐 대기를 줄이지 못하는 후보예요. 이 글에서 닫으면 이후 논의에서 빼요.
4. **Keeper 에게 이유를 물을까요.** `rondo`, `masc-productor-owner` 에게 「어떤 대기는 일정으로, 어떤 대기는 `sleep` 으로 하는 이유」를 Board 로 한 번 묻는 길이에요. 프롬프트가 아니라 일반 메시지이고 Keeper 에게 보내는 일이라 사용자 허락이 필요해요. 이 글은 이유를 모르는 채로 쓰였어요.

## 8. 확인하지 못한 것

- 두 주인이 왜 이 모양에서 일정을 쓰지 않는지. 3절은 정황이에요.
- `Keeper_msg_async.entry` 가 Execute 이외의 생산자를 받는지(5.2).
- 반복문 안의 `sleep` 276건(24.6시간) 중 GitHub 읽기가 차지하는 몫.
- `rondo` 가 run id 를 어디서 얻는지. 같은 턴의 `git push` 뒤라는 것만 알아요.
- 분류는 정규식이에요(`push`·`gh workflow run` 등 명령 목록, 리터럴 `sleep` 합). 셸 변수로 감춘 명령, 반복문의 `sleep` 은 놓쳐요.
- 이 창은 영수증 대기 스택 배포 전이에요. 배포 뒤 Keeper 가 달라졌는지 모르고, 24시간 값은 11-13 16:47 KST 에 읽어요.
- GitHub 읽기가 줄어드는 양은 재지 않았어요. 읽기 한도는 계정당 5,000건/시간이고 여러 에이전트가 같이 써요(`server_schedule_run_watch.ml` 머리 주석).
