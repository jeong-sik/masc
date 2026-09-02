# Keeper 10명이 어디서 앉아서 기다리는가 — 2026-09-02 실측 감사

측정 시각: 2026-09-02 09:00~10:00 KST (UTC 00:00~01:00). 대상은 `<base-path>/.masc` 의
라이브 저장소와 로그, 그리고 `origin/main` `138c84c4a6` 코드다. 이 문서는 "왜
keeper 가 멈춰 있는가" 를 서브시스템별로 재고, 뚫을 순서를 정한다. 수치는 전부
재현 명령과 함께 §6 에 있다.

keeper 8명이 살아 있다 (analyst, code-reviewer, edgar.a.poe, kidsnote-pr-jira-checker,
lane-smith, polisher, rondo, sangsu). taskmaster 와 lab-sangsu 는 09-01 17:43Z 이후
기록이 없다. 2026-09-01 하루 keeper 턴은 4,002회, 이 중 실패 사이클 562회(14%)다.

## 0. 순위

손실은 "keeper 의 작업 줄기가 멈춘 시간" 과 "아무 산출 없이 태운 턴" 두 축으로
쟀다. 뿌리가 코드인지 운영인지도 나눴다.

| # | 병목 | 하루 손실 (실측) | 뿌리 | 뚫는 곳 | 상태 |
|---|---|---|---|---|---|
| 1 | 샌드박스 전멸 — Execute 가 8/8 keeper 에서 실패 | verifier Rejected 93건 중 60건이 sandbox 사유. task-551 이 15회, task-371 이 17회 claim→release 를 돌았다. code-reviewer Execute 오류 20건/7h | 09:00 측정 시점: remote_ssh 3명은 127.0.0.1:2222 리스너 없음, microvm 5명은 게스트 이미지 없음 | 10:25 KST 에 8명 전부 `microvm` 으로 전환, RFC-0400 B(#32516) 뒤 11:52 재기동부터 Execute 가 `exit=0` (§1 끝). 코드 쪽 "샌드박스 상태가 world state 에 없다" 는 남음 | 운영으로 해소. 관측 결손은 미착수 |
| 2 | `web_fetch` 가 Auto Judge 를 거친다 | 319건 판정, 319 승인, 0 거부. 요청→replay 중앙값 173초, p90 447초. 7시간에 5.78시간 대기 | 코드: `keeper_gate_readonly.ml` 관측 집합에서 빠져 있었다 | PR #32470 | main 머지 (582921b8c1, 09-02 01:21Z) |
| 3 | 같은 도구를 3번 부르고 yield, 다음 턴에 또 3번 | kidsnote-pr-jira-checker 259턴/일, lane-smith 136, polisher 84. 컨텍스트가 턴마다 +3.5K 토큰 | 코드: yield 사유가 다음 턴에 안 보인다. 관찰 읽기를 wake 로 바꿀 길이 없다 | RFC observe-by-waking-not-polling (Draft) | 미착수 |
| 4 | Board 글 하나가 keeper 8명에게 판정 8번 | 24시간에 글 292개 → 후보 1,784건 (6.1배). 판정 통과 29% → 511회 wake. rondo 글이 697건, verifier·system 자동 영수증이 429건 | 코드: `Discoverable` 글은 keeper 마다 judge 를 탄다. 자동 영수증도 예외가 없다 | PR #32477 — 주소 없는 `System_post` 는 `Thread_participants` | main 머지 (529e6e0cd0, 09-02 01:27Z). rondo 형 글 697건은 남는다 |
| 5 | 승인이 keeper 에게 도착하는 데 107초 | judge 54초 + 배달 107초 (p50). 배달은 keeper 의 현재 턴이 끝나야 된다 | 구조: 턴 슬롯 하나 | RFC conversation-holds-the-turn-slot (Draft) | 미착수 |
| 6 | analyst·polisher 가 09-01 하루를 deepseek-flash 에서 돌았다 | polisher 148회, analyst 72회 사이클 실패, 그중 폴리셔 126·애널리스트 64회가 deepseek 를 기본 런타임으로 잡은 상태 (`deferred_next_runtime=none`). 사유 `accept_rejected … response_shape=thinking_only` | 설정: keeper 런타임 바인딩. 09-02 재기동 후 둘 다 glm-5.3/minimax-m3 로 돈다 | 운영자 확인 | 재기동으로 해소, 바인딩 위치 미확인 |
| 7 | 빈 자율 wake 가 상태 보고를 낳는다 | scheduled_autonomous 941턴/일. Todo 506건인데 claim 0. lane-smith 가 5분마다 "변하지 않았습니다" 댓글 313개 | 코드: `Task_backlog` 트리거가 "잡을 수 있는가" 를 모른다. 프롬프트: 할 일이 없을 때 글을 쓴다 | #27268, §2.7 | 미착수 |
| 8 | verifier 가 멈추면 제출자도 멈춘다 | Stalled 49건 중 `dns_failure: api.z.ai` 25건. rondo task-1067 5시간 무응답 | 코드: 같은 keeper 는 awaiting 중 새 claim 거부 | §2.8 | 미착수 |
| 9 | Memory OS 스냅샷 깨짐 | 09-01 07:34~10:10Z keeper 5명이 동시에 `invalid current Memory OS snapshot` | 미확인 | 별도 조사 | 미확인 |

1번은 운영 문제지만 2~8번 대부분의 증상을 증폭한다. 샌드박스가 죽으면 backlog 가
전부 "못 잡는 일" 이 되고, keeper 는 할 일이 없으니 글을 쓰고, 글이 판정과 wake 를
낳는다.

## 1. 샌드박스 전멸

### 증상

- analyst, rondo, code-reviewer 는 `sandbox_profile = "remote_ssh"`. 엔드포인트가
  전부 `127.0.0.1:2222` 인데 리스너가 없다. `lsof -nP -iTCP:2222 -sTCP:LISTEN` 결과
  0줄, `docker ps -a` 에 testbed 컨테이너 0개.
- edgar.a.poe, kidsnote-pr-jira-checker, lane-smith, polisher, sangsu 는 `microvm`.
  `microvm_image_missing: masc-keeper-sandbox:local` 과
  `docker.sock: connect: no such file or directory` 가 Board 에 남아 있다.
- 로그 (`masc-server-console-20260902-restart.log`): `Execute` 오류가 analyst 64건,
  code-reviewer 41건, polisher 28건, rondo 19건. 전부 `remote_ssh_endpoint_unreachable`
  또는 이미지 부재.

### 파급

- verifier_exact 영수증 299건 중 Rejected 93건, 그중 60건이 sandbox/checkout/image/daemon 을
  사유로 적었다. 정당한 제출도 sandbox 가 없으면 Rejected 로 남는다.
- task-551 은 code-reviewer 3회, taskmaster 7회, sangsu 2회, analyst·rondo·lane-smith
  각 1회, 합계 15회 claim→release 를 돌았다. 원인은 모두 같다 (checkout 부재).
  task-371 은 17번째 cycle 까지 auto-claim 이 다시 잡았다.
- 그 결과 Todo 506건 중 실제로 잡히는 일이 없다. §7 로 이어진다.

### 코드 쪽에 남는 것

샌드박스가 죽었다는 사실이 world state 에 없다. keeper 는 매 턴 Execute 를 다시
시도하고 (`keeper_sandbox_ssh.ml` 의 preflight 캐시는 같은 턴 안에서만 산다),
taskmaster 는 매시 정각 "N차 재프로브 — 여전히 단절" 글을 13번 올렸다.
`masc_keeper_waiting_inventory` 에도 "sandbox unreachable since T" 행이 없다.

### 09-02 11:52 이후

위 증상은 09:00 측정 시점의 사실이다. 10:25 KST 에 analyst·rondo·code-reviewer 의
`sandbox_profile` 이 `remote_ssh` 에서 `microvm` 으로 바뀌어 8명 전부 microvm 이 됐고,
RFC-0400 B(#32516, 11:4x)가 게스트를 작업 볼륨과 exec shim 을 가진 원격 엔드포인트로
만들었다. microvm 은 Docker 가 아니라 Apple `container`(Virtualization.framework)로 뜬다.
11:52 재기동 로그: 부팅 sweep 이 서버가 사라진 게스트 5개를 지웠고, 그 뒤
`shell_ir dispatch keeper=rondo sandbox=microvm status=exit=0` 2건,
`keeper=code-reviewer … exit=0` 1건. Execute 는 살아 있다. 이 문서의 이전 판과 이 세션이
그 뒤에도 "Docker 가 죽어서 샌드박스가 없다" 고 반복한 것은 10:25 이후 상태를 다시 재지
않은 오류다.

뚫는 방향: 샌드박스 preflight 실패를 typed 관측(`Sandbox_unreachable of { since; detail }`)
으로 world observation 에 싣고, 대기 인벤토리와 프롬프트 Namespace State 에 한 줄로
낸다. Execute 가 필요한 Task 는 그 상태에서 claimable 에서 빠진다. 이건 Gate 가
아니라 관측이다. 해당 Task 를 못 잡는 이유가 keeper 의 추측이 아니라 저장된 사실이
된다.

## 2. web_fetch 판정 게이트 (PR #32470)

`keeper_gate_readonly.ml` 은 `web_search` 만 관측 전용으로 두고 `web_fetch` 는
"주소가 caller 선택이라 judge 가 볼 문제" 라며 뺐다. 그런데 주소 경계는
`tool_misc_web_fetch.ml` 이 이미 결정적으로 막는다 (loopback, link-local, 사설망,
unspecified, localhost — 처음 URL 과 모든 redirect hop). 그 검사도 judge 도 DNS 를
풀지 않는다. judge 가 fetch 보다 더 막을 수 있는 주소가 없다.

| 항목 | 값 |
|---|---|
| 09-01~02 `network_read` 판정 | 319건 승인, 0건 거부 |
| 저장소 전체 (`gate/pending.json` deliveries 2,553건) | web_fetch 344, web_search 4, 전부 승인 |
| 09-02 재기동 후 7시간 web_fetch 98건 요청→replay | p50 173초, p90 447초, max 1,131초, 합계 5.78시간 |
| 같은 기간 tool_execute 11건 | p50 143초, 합계 1.16시간 |

한 번 fetch 할 때마다 keeper 턴은 `awaiting_external_effect` 로 끊기고, 승인은
event queue 에 실려 다음 턴 admission 을 기다린다. code-reviewer 는 6일간 164번
이 길을 걸었다.

PR #32470 은 `web_fetch` 를 관측 집합에 넣는다. Manual 모드는 그대로다.

## 3. 반복 호출 yield 루프

`keeper_agent_run.ml` 은 같은 도구를 같은 인자로 3번 부르면 턴을
`yielded_after_repeated_tool_call` 로 끊는다. 끊긴 턴은 checkpoint 로 저장되고 다음
proactive tick 에 이어진다. 그런데 `checkpoint_reason = Repeated_tool_call` 은
`keeper_heartbeat_loop.ml` 의 batch ack 판단에만 쓰이고 다음 턴 프롬프트에는 나오지
않는다. keeper 는 왜 끊겼는지 모른 채 같은 조회를 다시 3번 한다.

| keeper | 09-01 yield 턴 | 반복한 도구 | 오늘 turn-record |
|---|---|---|---|
| kidsnote-pr-jira-checker | 259 / 361 | `atlassian_searchJiraIssuesUsingJql` | 18턴 중 17턴이 같은 사유. 컨텍스트 78,221 → 92,221 토큰 (5턴) |
| lane-smith | 136 / 342 | `keeper_tasks_list` 99, `masc_board_post_get` 37 | 9턴 중 7턴 |
| polisher | 84 / 424 | `keeper_spawn_read` 41, 반복 텍스트 43 | |

kidsnote-pr-jira-checker 의 지시문은 "명령이 있든 없든 … Epic 위주로 확인해 늘
정리해 보고" 다. 이 keeper 에게 Jira 는 wake 를 줄 수 없는 외부 시스템이라 폴링이
곧 일이다. 문제는 한 턴에 3번 폴링하고, 그 결과가 매 턴 히스토리에 쌓여 컨텍스트
handoff 를 앞당기는 것이다.

RFC observe-by-waking-not-polling 이 "typed 조건을 등록하고 충족되면 깨운다" 로 이
축을 닫는다. 한 주 1,086턴(5.5%) 이 같은 모양이었다. 그 RFC 가 들어오기 전에도 할 수
있는 작은 일이 하나 있다. checkpoint 사유를 다음 턴 world state 에 한 줄로 낸다
("직전 턴은 X 를 같은 인자로 3번 부른 뒤 끊겼다. 결과는 바뀌지 않았다"). 사유는 이미
typed 로 있고, 렌더만 없다.

## 4. Board 알림 fan-out

`keeper_world_observation.ml` 의 board 수집기는 keeper 마다 돈다. 새 글이 오면
`Board_audience.route_for_keeper` 가 `Ignore` 또는 `Judge_discoverable` 을 주고,
`Judge_discoverable` 이면 그 keeper 몫의 후보를 만들어 `board_attention_exact` 레인
(glm-5.3-flash → deepseek-flash) 에 판정을 맡긴다.

| 24시간 (09-01 00:26Z ~ 09-02 00:26Z) | 값 |
|---|---|
| 새 글 | 292 |
| 후보 (keeper 8명 합계) | 1,784 (글당 6.1) |
| 판정 결과 | relevant 511 (29%), not_relevant 1,263 |
| 저자별 후보 | rondo 701, verifier_exact 252, code-reviewer 191, system 185, lane-smith 134, dashboard 122 |
| rondo 글의 판정 | relevant 156, not_relevant 541 |
| verifier_exact + system 자동 영수증의 판정 | relevant 126, not_relevant 303 |

세 가지가 보인다.

1. rondo 의 이슈 트리아지 글 (09-01 03시 한 시간에 53개) 하나하나가 keeper 7명에게
   판정 7번을 만든다. 글은 실제 진척인데 형식이 fan-out 을 부른다.
2. verifier_exact 와 system 의 "Verify: …" 영수증은 제출자 keeper 에게는 이미 typed
   stimulus (`Completion_authority_rejection_pending`) 로 간다. 나머지 7명에게는
   판정 429건이 하루에 생긴다.
3. 통과한 511건은 곧 wake 다. keeper 가 그 글을 읽고 답글을 쓰면 다시 7명에게
   후보가 생긴다. lane-smith 의 5분 주기 "재확인" 댓글 313개, taskmaster 의 15분 안
   동일 본문 8연발이 이 고리에서 나왔다.

뚫는 방향은 판정 앞의 결정적 분기다. `post_kind = System_post | Automation_post`
이고 `meta.type = verification_verdict` 인 글은 제출자 외 keeper 에게 후보를 만들지
않는다 (제출자는 이미 stimulus 를 받는다). 이건 문자열 매칭이 아니라 이미 닫힌
`post_kind` 와 `meta` 의 typed 판별이다. 하루 429건이 빠진다. rondo 형 글은
audience 를 `Thread_participants` 로 쓰게 하는 프롬프트/도구 기본값 문제라 별도로
본다.

## 5. 승인 배달 지연

| 09-02 재기동 후 승인 113건 | p50 | p90 | max |
|---|---|---|---|
| 요청 → 판정 (judge) | 54초 | 78초 | 166초 |
| 판정 → keeper 배달 | 107초 | 398초 | 1,333초 |
| 요청 → 배달 | 158초 | 447초 | 1,398초 |

배달 107초는 keeper 의 "현재 턴" 이 끝나기를 기다린 시간이다. 로그 순서가 그렇다.
`HITL_APPROVAL_RESOLVED` 직후 `hitl resolution committed signal=signaled phase=running`
이 찍히고, keeper 가 다른 일로 시작한 턴이 끝나야 `hitl resolution delivered` 가 온다.
code-reviewer 턴이 150~170초라 잔여 시간이 그대로 배달 지연이다.

이건 RFC conversation-holds-the-turn-slot 이 다루는 "슬롯 하나" 문제의 다른 얼굴이다.
승인 replay 는 턴 안의 도구 경계에서 끼워 넣을 수 있는 종류의 자극이다
(`cooperative_yield_probe` 자리가 이미 있다). §2 가 들어오면 이 지연을 겪는 건수
자체가 98 → 15 로 준다.

## 6. analyst·polisher 가 09-01 하루를 deepseek-flash 에서 돌았다

| 09-01 사이클 실패 | 건수 | 런타임 |
|---|---|---|
| polisher | 145 | `ollama_cloud.ollama-cloud-deepseek-v4-flash-0731` |
| code-reviewer | 89 | `antigravity_subscription.claude-sonnet-4-6-agy` |
| lab-sangsu | 81 | `antigravity_subscription.gpt-oss-120b-medium` |
| edgar.a.poe | 74 | `glm-coding.glm-5.3` |
| analyst | 64 | `ollama_cloud.ollama-cloud-deepseek-v4-flash-0731` |

처음에는 "glm-5.3 이 rate limit 에 걸려 deepseek 로 failover 한다" 로 읽었는데, 실패
행을 `runtime` × `deferred_next_runtime` 으로 나누면 다르다.

| keeper | runtime=deepseek, next=none | runtime=deepseek, next=glm-5.3 | runtime=glm-5.3, next=deepseek | runtime=glm-5.3, next=none |
|---|---|---|---|---|
| polisher | 126 | 22 | 7 | 8 |
| analyst | 64 | 8 | 4 | 2 |

deepseek 가 기본이고 glm-5.3 이 예비였다. 실패 사유는
`accept_rejected … reason_kind=no_usable_progress response_shape=thinking_only`, analyst 는
한 턴이 817초 걸린 뒤 실패했다. 이 모델은 8월 24~25일에도 한 단어를 228,000자 반복하는
붕괴가 86턴 관측됐다.

09-02 00:59Z (polisher) 와 01:25Z (analyst) 에 두 keeper 가 새 trace 로 재기동됐고, 그
뒤 runtime-manifests 에는 `glm-coding.glm-5.3` 과 `ollama_cloud.minimax-m3` 만 남았다
(polisher 141/34, analyst 32/3). 누가 어디서 바인딩을 바꿨는지는 확인하지 못했다 —
keeper TOML 과 `keepers/<name>.json` 에는 런타임 필드가 없다 (§10).

standalone 레인은 아직 같은 모델을 2번 슬롯으로 둔다: `runtime.toml` 의
`verifier_exact` (323행), `hitl_auto_judge` (477행), `board_attention_exact` (655행).
그 레인들이 1번 슬롯(glm-5.3-flash)에서 밀리면 같은 붕괴를 만난다.

## 7. 빈 자율 wake

09-01 turn 4,002회 중 `scheduled_autonomous` 941회. 매 wake 의 사유는
`scheduled_autonomous_turn,task_backlog` 다. `Task_backlog { unclaimed = 506 }` 은
"잡을 수 있는가" 를 모른다. Execute 가 죽어 있으면 506건 전부 못 잡는 일인데
프롬프트에는 "Claimable tasks for this keeper: N" 과 id 10개가 매 턴 나온다.

할 일이 없는 keeper 는 상태 보고를 쓴다.

| keeper | 반복 게시 | 횟수 | 주기 |
|---|---|---|---|
| lane-smith | "HH:MM 재확인: tool errors 가 N 에서 M 로 … 변하지 않았습니다" 댓글 | 313 | 5분, 약 40시간 |
| lane-smith | "seq N→M, errors K 유지, rotation 미확인" 글 | 75 | 5~6분 |
| taskmaster | "N차 재프로브 — 여전히 단절 (Connection refused)" | 13 | 매시 정각 |
| lab-sangsu | "[fleet] X status report 슬롯 확인" | 14 | 2시간 15분 동안 |

Todo 506건의 저자는 codex-mcp-client 287, analyst 109, code-reviewer 35 다. 세션과
keeper 가 만든 일이지 사람이 준 일이 아니다.

#27268 이 같은 축을 "빈 wake 가 해명 문단으로 컨텍스트를 채운다" 로 적었다.
뚫는 방향은 두 층이다. (a) `Task_backlog` 트리거에 `claimable_now : int` 를 같이
싣고, 샌드박스 상태 (§1) 와 skill 요구를 반영해 0 이면 프롬프트에 "잡을 수 있는
일 0건, 이유: sandbox unreachable" 로 낸다. (b) keeper 공통 프롬프트에 "새 관측이
없으면 글을 쓰지 않는다" 를 넣는다. 지금 `config/prompts/keeper.md` 에는 그 문장이
없다.

## 8. verifier 가 멈추면 제출자도 멈춘다

`workspace_task_lifecycle.resolve_claim` 은 `AwaitingVerification` 인 Task 를 어떤
keeper 도 못 잡게 한다. 그건 맞다. 문제는 제출한 keeper 가 새 Task 를 잡는 것도
막힌다는 rondo 의 실측이다 (task-1074 claim 06:02Z 거부, 09-01 05:38Z 글).
verifier_exact Stalled 49건 중 25건이 `dns_failure: api.z.ai` (08-31 10:16Z ~ 09-01
01:00Z) 였고, 그 15시간 동안 제출자들은 직렬로 멈췄다. rondo task-1067 은 5시간 넘게
답이 없었다.

verifier 는 `review_slots = 4`, 재시도 간격은 maintenance pulse 60초다. 횟수 상한이
없어 dns 가 돌아오면 다시 돈다. 그 자체는 헌법 (no_wall_clock_death) 대로다. 뚫을
곳은 "제출자가 awaiting 동안 다른 일을 못 잡는다" 쪽이다. 제출은 소유를 verifier 로
넘긴 것이지 keeper 를 묶은 것이 아니다. 이 규칙이 코드 어디에 있는지는 이번에
확인하지 못했다 (§10).

## 9. Memory OS

09-01 07:34Z ~ 10:10Z 사이 lane-smith, analyst, lab-sangsu, edgar, code-reviewer 가
같은 `invalid current Memory OS snapshot` 을 보고했다. 한 keeper 의 결함이 아니다.
code-reviewer 는 08-29 에 `keeper_memory_search` 의 `total_candidates` 가 write 마다
줄어드는 것(27 → 10 → 7)을 실측했다. 이번 감사 범위 밖이라 원인은 보지 않았다.

## 10. 확인하지 못한 것

- §8 의 "같은 keeper 가 awaiting 중 새 claim 을 못 잡는다" 는 Board 증언이다.
  `workspace_task_claim.ml` 에서 그 분기를 찾지 못했다. 다른 층 (auto-claim 의
  `claim_next`, 또는 keeper 프롬프트) 일 수 있다.
- §6 의 keeper 런타임 바인딩이 어디서 정해지는지 찾지 못했다. `config/keepers/<name>.toml`
  과 `keepers/<name>.json` 에는 런타임 필드가 없고, `runtime.toml` 의 `candidates` 목록은
  route 단위다. 재기동 전후로 바뀐 것만 manifests 로 확인했다.
- `masc_keeper_list` 는 analyst·polisher 를 `status=offline, keepalive_running=false`
  로 내는데 `masc_keeper_waiting_inventory` 는 같은 시각 `fiber_alive=true, is_live=true`
  로 낸다. 두 read model 이 다르다. 어느 쪽이 맞는지 보지 않았다.
- §4 의 `post_kind`/`meta` 분기가 `Board_audience.route_for_keeper` 앞에 들어갈 수
  있는지 코드로 확인하지 않았다.
- chat 저장소 (`keeper_chat/*.jsonl`) 의 정량 분석은 절반만 받았다. Board 와 로그로
  대체했다.

## 11. 이번 세션 조치와 다음 순서

1. PR #32470 — `web_fetch` 관측 전용 (§2). 09-02 01:21Z main 머지. 머지 시점의 CI 는
   main 자체가 Build 에서 깨져 있어 (`test_absolute_turn_sequence_breaks_equal_clock_ties`
   미정의, #32465 이전) 테스트까지 못 갔다. 머지 후 main 내용으로 다시 dispatch 했다.
2. PR #32477 — 주소 없는 `System_post` 는 `Thread_participants` (§4). 09-02 01:27Z main 머지.
   적대적 리뷰가 blocker 를 잡았다. verifier 의 stalled 영수증도 `System_post` 인데 그 글이
   producer 에게 닿는 유일한 경로라 아무에게도 안 갔다. PR #32498 이 `post_kind` 규칙을 걷고
   `Unlisted` visibility("피드 제외, 접근 가능")를 typed 근거로 바꿨다. 검증 요청·판정 글만
   Unlisted, stalled 는 Internal 그대로. 09-02 머지.
3. 이 문서 (#32471) 와 §6 정정 (#32479).
4. PR #32492 — §3 checkpoint 사유의 다음 턴 렌더. `Keeper_turn_checkpoint_reason` 으로 사유를
   빼고 heartbeat loop 가 직전 사유를 다음 턴 프롬프트의 Autonomous Trigger 층에 한 줄로 싣는다.
   09-02 머지. 효과는 배포 뒤 같은 `finish_reason` 집계로 잰다.
5. PR #32499 — §2 의 후속. web_fetch 주소 경계가 `2130706433`, `0x7f000001`, `127.1`,
   `localhost.`, IPv6 zone id, userinfo 를 통과시키던 결함을 막는다. judge 를 뗀 뒤 이 경계가
   유일한 층이라 사람 리뷰가 필요하다 (열림).
6. 다음 (독립): §1 `Sandbox_unreachable` 관측 + §7 `claimable_now`.
7. 다음 (독립): §4 의 남은 절반 — keeper 글의 기본 audience. rondo 트리아지 글 하루 후보 697건.
   approval 판정에 typed wake 를 붙이는 것도 여기 (`Completion_authority_wakeup` 은 rejection 만).
8. §1 의 운영 결손은 microvm 전환(10:25)과 RFC-0400 B 로 해소됐다. §6 은 재기동으로 해소됐고
   standalone 레인 2번 슬롯만 남았다. 남는 것은 코드 쪽 — 샌드박스가 못 뜰 때 그 사실이
   world state 와 대기 인벤토리에 typed 로 실리는 것.

## 12. 재현 명령

```bash
# 런타임 루트. MASC_BASE_PATH 는 서버가 쓰는 base path 와 같은 값으로 둔다.
M="${MASC_BASE_PATH}/.masc"

# 승인 lifecycle 지연 (요청 → 판정 → 배달), 재기동 로그 기준
L="$M/logs/masc-server-console-20260902-restart.log"
rg -o 'HITL_APPROVAL_PENDING: id=appr_[^ ]+ .*tool=[a-z_]+|HITL_APPROVAL_RESOLVED: id=appr_[^ ]+|hitl resolution delivered approval=appr_[^ ]+' "$L"

# 판정 결과 (승인/거부)
rg -o 'HITL_APPROVAL_RESOLVED: id=appr_[^ ]+ keeper=[a-z.-]+ tool=[a-z_]+ decision=[a-z_]+' \
  "$M/logs/system_log_2026-09-01.jsonl" "$L" | sed -E 's/.*tool=([a-z_]+) decision=([a-z_]+)/\1 \2/' | sort | uniq -c

# 승인 저장소 전체의 tool/capability
jq -r '.deliveries[] | "\(.entry.tool_name)/\(.entry.input.capability // "-")\t\(.source)"' "$M/gate/pending.json" | sort | uniq -c

# 턴 종료 사유 (keeper 별, 09-01 UTC)
for k in "$M"/keepers/*/; do f=$k/turn-records/2026-09/01.jsonl; [ -f "$f" ] && \
  jq -r '(.finish_reason // "?") | sub(":[0-9]+"; "") | sub(":[0-9]+$"; "")' "$f" | sort | uniq -c | sort -rn | head -3; done

# 턴 채널 (proactive vs reactive)
rg -o 'keepalive turn scheduled for [a-z.-]+: channel=[a-z_]+' "$M/logs/system_log_2026-09-01.jsonl" | sort | uniq -c

# 사이클 실패 (keeper, runtime)
rg -o '"[a-z.-]+: keeper cycle FAILED runtime=[^ ]+' "$M/logs/system_log_2026-09-01.jsonl" | sort | uniq -c | sort -rn

# Board 후보 fan-out 과 판정
cat "$M"/board_attention_candidates/{analyst,code-reviewer,edgar-a-poe-*,kidsnote-pr-jira-checker,lane-smith,polisher,rondo,sangsu}.jsonl \
  | jq -r 'select(.recorded_at >= 1788220000 and .status.kind=="consumed") | "\(.signal.author)\t\(.status.judgment.verdict.decision)"' | sort | uniq -c

# 샌드박스: 프로필을 먼저 보고, 프로필에 맞는 런타임을 본다
rg -n sandbox_profile "$M"/config/keepers/*.toml
container ls -a            # microvm 게스트 (Apple container CLI)
jq -r '.message' "$M/logs/system_log_$(date +%F).jsonl" | rg 'shell_ir dispatch keeper=.* sandbox=.* status=' | tail -20

# identity_call 판정 통행료: 대기 시간과 결의 주체
jq -r 'select(.tool=="identity_call" and .event != "pending" and .event != "summary_updated") | .event + " " + (.decision_source // "-")' "$M/audit-approvals/$(date +%Y-%m)/$(date +%d).jsonl" | sort | uniq -c

# claude_code 레인: host stop 을 실패로 찍는 WARN 과 usage 누락
jq -r 'select(type=="object") | .message' "$M/logs/system_log_$(date +%F).jsonl" | rg -c 'subscription turn failed \(kind=stopped_by_host\)|usage telemetry missing'
```

## 13. 재기동 이후 측정 (09-02 15:12–15:40 KST)

서버는 15:11:57 에 #32555 빌드(15:09:53, #32521 포함)로 다시 떴다. 그 뒤 28분을 잰 것이다. 하루 측정은 아니다.

### 13.1 고친 것이 라이브에서 보이는가

| 항목 | 판정 | 근거 |
|---|---|---|
| 프롬프트 manifest (#32521) | 동작 | 라이브 `config/prompts/` 66개 = manifest 66개. `previous_turn_stop` 2개와 `tool_failure` 5개가 들어 있다. |
| 샌드박스 microvm (RFC-0400 B) | 동작 | 게스트 5개 running. `shell_ir dispatch … sandbox=microvm status=exit=0` rondo 2, polisher 2, lane-smith 4. |
| web_fetch 판정 통행료 (#32470, #32509) | 동작 | 15:12 재기동 뒤 18:10 까지 `WebFetch` 57건(code-reviewer, pr-updater, analyst), `network_read` 승인 0건. 마지막 `network_read` 승인은 10:35 로 #32470(10:21 머지) 이전 빌드에서 났다. 15:34 에 잰 첫 창은 실제로 0건이었고 첫 호출은 15:40 에 왔다. 짧은 창의 0을 미증명으로 적은 것은 이 문서의 오류였다. |
| Board 수신 규칙 (#32498, #32505) | 부분 | verifier 가 쓴 글이 0건이라 unlisted 경로는 미증명. new-keeper 의 ops 글 1건은 8명 전원에게 판정 후보로 갔다(내부 글 → 발견 가능, 설계대로). rondo 의 hearth 글은 오늘 7명에게 25건 판정을 만들었다. §11 의 개인 hearth 항목은 그대로 열려 있다. |
| previous_turn_stop (#32492, #32501) | 미발동 | 통합 레인에서 `repeated_tool_call` 정지가 0건이라 조각이 렌더될 기회가 없었다. §6 의 kidsnote 72% 는 `ollama_cloud.minimax-m3` 레인 수치였고(어제 258/380), 재기동 후 kidsnote 는 `claude_code.claude-sonnet-5` 레인에서만 돌았다. 두 수치는 비교할 수 없다. |

### 13.2 재기동 후 새로 잰 것

1. **rondo 의 identity_call 판정 통행료.** 오늘 40건, 승인까지 평균 131초, 최대 748초. 33건은 auto_judge 가, 7건은 사람이 TUI 에서 결의했다. 승인 1건마다 HITL 요약 갱신이 4건(160건) 붙는다. 직전 도구는 표본 6건에서 github_issue_read 2, github_issue_write 1, keeper_artifact_read 1. 승인은 durable stimulus 로 도착해 진행 중인 턴을 끊고(`yielded_to_durable_stimulus` 10턴 중 6턴) 다음 턴이 48–64k 토큰으로 다시 들어온다. rondo 는 28분 동안 10턴, 입력 513k 토큰을 썼다. 모양은 §3 의 web_fetch 통행료와 같다. 다만 identity_call 은 사람 OAuth 신원으로 나가는 호출이라 읽기(github_issue_read)와 쓰기를 같은 값으로 볼지는 RFC 판단이 필요하다.
2. **Docker 프로필 keeper 는 태어나서 죽을 때까지 실행 불가.** new-keeper 가 15:16:42 TUI 에서 `sandbox_profile = "docker"` 로 생성됐다. 이 기기엔 Docker daemon 이 없다. Execute 2건이 `docker_container_probe_failed` 로 실패했고 15:27:35 대시보드에서 purge 됐다. 제거 sweep 도 `docker ps` 실패 WARN 2건을 남겼다. 11분. remote_ssh 는 endpoint 가 없으면 생성 시점에 거부되는데(`keeper_meta_contract.ml` Remote_ssh 가드), docker 는 daemon 이 없어도 생성된다.
3. **claude_code 레인은 usage 를 잃고 설계된 정지를 실패로 찍는다.** kidsnote 6턴 전부가 terminal tool(keeper_memory_write 4, keeper_surface_post 1, keeper_webmcp_list 1) 경계에서 host stop 으로 끝났다. `keeper_official_client_host.ml` 의 `host_stop_result` 가 `usage = None` 을 주므로 turn-record `output_tokens = 0`, "usage telemetry missing" 6건. 같은 정지를 `runtime_claude_code.ml:1606` 이 `subscription turn failed (kind=stopped_by_host)` WARN 으로 찍는다(오늘 19건, completed 는 4건). `Repeated_tool_call` 은 `Yielded_after_repeated_tool_call` 로 매핑되므로 previous_turn_stop 은 이 레인에서도 렌더될 수 있다.
4. **provider 실패 4건.** polisher: deepseek `accept_rejected`, glm SSE malformed payload. rondo: glm rate limit, minimax broken pipe. 모두 `deferred_next_runtime` 으로 넘어가 다음 턴이 성공했다. 실패 턴은 turn-record 에 `finish_reason = none, output_tokens = 0` 으로 남는다(rondo 3, polisher 2).
5. **polisher microvm playground(266MB) 의 호스트 git 5초 inspection budget 초과 5건.** 게스트 부팅과 clone 이 겹친 15:14–15:23 에만 났고, 15:40 에 같은 명령은 0.97초다.

### 13.4 두 번째 재기동 (09-02 17:53 KST, #32594 빌드) 뒤 16분

빌드는 17:33 origin/main(ee8841074a). 15:12 이후 25건이 더 들어갔고 microvm 쪽 4건(#32562 계열, RFC-0400 C)이 포함된다. 9명이 autoboot 됐다(pr-updater 추가). 라이브 프롬프트 66개 = manifest 66개. `WebFetch` 는 18:07 부터 analyst 가 다시 부르기 시작했고 승인은 여전히 0건이다.

1. **edgar.a.poe 가 같은 Execute 를 8번 내고 10분 30초를 기다렸다.** 재기동 직전(17:49)에 만든 승인 `appr_01a0614f` 는 auto_judge 가 17:51 에 승인했고, 그 결의 stimulus 는 재기동 전부터 edgar 의 큐에 있었다(18:04:41 전달 시점의 `head_age_sec=807`). 재기동 중 17:54:12 의 `signal=deferred_unregistered` 는 wake 신호 하나가 빠진 것일 뿐 원인이 아니다. 원인은 큐 처리 규칙 둘의 조합이다. (a) intake 는 HITL 결의를 턴당 하나만 들인다(`keeper_heartbeat_stimulus_intake.ml` "One tool bundle carries one exact cycle grant"). (b) `keeper_heartbeat_loop.ml` `batch_disposition_of_cycle_outcome` 이 `Checkpointed{Awaiting_external_effect}` 를 catch-all 로 `Batch_no_action` 처리해, 들여온 stimulus 를 ack 하지도 continuation 영수증을 쓰지도 않는다. 큐 머리에는 재기동 전에 이미 replay 가 끝난 승인 `appr_01a06147` 이 있었고, 그걸 들여온 턴이 Execute 를 Gate 에 넘기고(그 Execute 는 `appr_01a0614f` 에 접혀 "deferred") `awaiting_external_effect` 로 끝나니 ack 가 안 됐다. 다음 wake 에 같은 승인이 다시 머리로 오고 같은 턴이 반복됐다(7번 소비, 재생 `already_recorded` 17건). 18:01:44 에 fs_edit 가 성공해 턴이 `yielded_to_durable_stimulus` 로 끝나자 그제야 ack 가 났고, 그 뒤에 선 결의들이 한 턴에 하나씩 나와 18:04:41 에 `appr_01a0614f` 가 돌았다(exit=0). 그 사이 8턴, 입력 약 62만 토큰. 게스트는 17:54 sweep 뒤 18:01:43 에야 만들어졌는데, 만든 것은 Execute 가 아니라 fs_edit 였다(Execute 는 Gate 에서 멈춰 샌드박스까지 가지 않았다). 수정: #32602.
2. **analyst 는 같은 실패를 9번 반복했다.** 레인은 `[ollama_cloud.deepseek-v4-flash; glm-coding.glm-5.3]` 둘이다(`runtime.toml` 의 keeper 배정 + `[runtime].default` 가 붙는다). `deferred_next_runtime=none` 은 레인이 하나라는 뜻이 아니라 그 실패가 회전 불가로 분류됐다는 뜻이다. 16:42 에 들어간 #32577 이 `accept_no_progress_retry_kind` 첫 arm 에 "stop_reason=MaxTokens 면 전부 `Truncated_no_progress`" 를 두었고, 이 종류는 회전 힌트가 없다. 그 PR 의 이어쓰기(`max_tokens_continuation`)는 실행됐다. analyst 의 `runtime-manifests` 에 9건이 있고(시스템 로그에는 이 문자열이 없어 처음엔 0건으로 잘못 읽었다), 각각 첫 생성 68–116초 뒤 52–88초를 더 쓰고 같은 thinking-only max_tokens 로 끝났다. 이 레인은 reasoning_effort 방언이라 `enable_thinking=false` 가 wire 에 실리지 않아 이어쓰기가 같은 요청의 반복이 된다. 그 결과가 다시 `Truncated_no_progress` 라 회전도 deferral 도 없다. 15:23 polisher 는 #32577 이전 빌드에서 같은 실패로 glm 에 넘어갔다. 첫 `deferred_next_runtime=none` 은 17:39 로 재기동 전이다. 9턴 707초, 출력 0, 사이클 실패 4회, 복구 wake 13회. 수정: #32605(분류). 방언이 thinking 끄기를 조용히 버리는 것은 별도 이슈.
3. **official-client 레인의 토큰 집계는 누적 컨텍스트다.** lane-smith 3턴 입력 3,782만, code-reviewer 8턴 765만. CLI 가 세션 전체를 매 턴 다시 보내는 값이라 agent-core 레인 수치와 더할 수 없다.
4. new-keeper 의 purge 가 재기동 뒤 `shutdown recovery failed … Keeper owner not found` 로 한 번 더 실패했다. 잠금 파일 4개가 `config/keepers/` 에 남아 있다.
5. 다른 세션의 E0 캠페인 서버(pid 51095)가 같은 호스트에서 게스트 4개(4 CPU, 2GB 씩)를 띄워 두고 있다. keeper 게스트가 아니라 sweep 대상이 아니다.

### 13.5 코드 수정과 남은 판단 (09-02 19:00 KST)

| 항목 | 결과 |
|---|---|
| 13.4-1 체크포인트 턴의 ack | #32602. 다섯 checkpoint 사유 전부 `Batch_ack_attention_only`, catch-all 제거, HITL continuation 영수증 가드는 유지. 라이브 판정: 같은 approval 의 `gate replay … already_recorded` 가 2회 이상 나오지 않아야 한다. |
| 13.4-2 max_tokens 분류 | #32605. 내용이 없는 응답(empty, thinking_only)은 stop 과 무관하게 회전 종류를 유지하고, 이어쓰기 시도는 레코드를 읽어 그대로 먼저 한다. 라이브 판정: thinking-only max_tokens 실패에서 `deferred_next_runtime=glm-coding.glm-5.3` 이 찍혀야 한다. 받아들인 비용: 이 방언에서 이어쓰기는 같은 요청을 한 번 더 보낸다(턴당 52–88초). |
| 13.2-1 identity_call 통행료 | 전제가 틀렸다. 81건 전부 `github/issue_write`·`add_issue_comment` 쓰기이고, 읽기는 MCP `readOnlyHint` 로 `keeper_identity_gate.ml` 에서 Gate 전에 통과한다. 판정은 67건 중 1건을 거부했고 그 1건은 직전에 읽은 본문과 모순되는 덮어쓰기였다. 대기 103초 중 98초가 판정 모델 응답이다. 슬롯별 평균 glm-5.3-flash 116초(n=65), deepseek-v4-flash 31초(n=19). `[runtime.exact_output_lanes.hitl_auto_judge].slots` 순서는 09-01 운영자 지정이라 바꾸지 않았다. |
| 13.2-2 docker 프로필 keeper | 미착수. 생성 시점 거부(remote_ssh 의 endpoint 가드와 같은 자리)가 다음 코드 지점이다. |
| WebFetch 로 자기 서버 API | 고칠 코드 없음. `/api/v1/keepers/<k>/file-changes` 는 대시보드 REST(CanAdmin) 에만 있고 keeper 도구가 없다. |

### 13.3 다음 측정

- §12 의 명령을 09-03 15:12 에 한 번 더 돌려 24시간 값을 만든다. 보는 것: `network_read` 승인 0건이면서 `web_fetch` 호출이 있는지, verifier 글의 판정 후보 0건, 통합 레인 `repeated_tool_call` 정지 뒤 다음 턴 `provider-inputs` 에 조각 문장이 있는지.
- 13.2-1 과 13.2-2 는 코드 변경이 필요하다. 시작 전 사용자 선택.
