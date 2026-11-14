---
rfc: "replayed-tool-results-carry-their-time"
title: "새 세션에 다시 넣는 도구 결과는 받은 시각과 나이를 같이 싣는다"
status: Draft
created: 2026-11-15
updated: 2026-11-15
author: claude
supersedes: []
superseded_by: null
related: ["tool-results-age-out-of-context", "official-client-conversation-in-masc", "0473"]
---

# RFC: 새 세션에 다시 넣는 도구 결과는 받은 시각과 나이를 같이 싣는다

- 상태: 초안.
- 이슈: #52055.
- 먼저 있는 결정: `RFC-tool-results-age-out-of-context` 가 끝난 턴의 2,048 B 이상 결과를 새 세션 씨앗에서 마커로 보낸다(#51657). 이 RFC 는 마커가 되지 않는 결과와, 마커가 되어도 남는 「언제 본 것인가」를 다룬다.
- 코드 좌표는 `origin/main` `31b563a05e9b` 에서 읽었다.
- 운영 기록은 `~/me/.masc` 의 11-14 파일에서 읽었다. 기록 본문(사용자 맥락)은 옮기지 않는다.

## 0. 요약

2026-11-14 12:06:58Z 에 `code-reviewer-uncle` 이 Board 글에 「방금 `keeper_lane_status` 로 다시 확인했는데 레인이 죽어 있다」고 댓글을 달았다. 그 세션은 그때까지 `keeper_lane_status` 를 부르지 않았다. 근거는 새 세션을 열 때 MASC 가 다시 넣은 지난 대화 속 결과였다. 그 결과는 4시간 전(08:06:49Z)에 받은 것이다. 그때는 레인이 실제로 죽어 있었고, 09:17Z 서버 재시작 뒤 살아났다. 12:07:12Z 에 uncle 이 직접 부르자 레인은 정상으로 나왔다.

다시 넣는 결과에는 받은 시각이 없다. 정본 히스토리에도 없다. 모델은 옛 결과와 이번 턴의 결과를 가를 수 없다.

이 RFC 는 네 가지를 정한다.

1. Agent Core 가 도구 결과를 히스토리에 붙이는 순간, 그 메시지에 붙인 시각을 남긴다.
2. 공식 클라이언트로 보내는 인코딩이 그 시각을 정해진 필드로 싣는다. 시각이 없으면 없다고 싣는다.
3. 새 세션 씨앗에는 서버가 계산한 나이(세션 시작 시각 − 붙인 시각)를 같이 싣는다. 나이는 세션 digest 에 들어가지 않는다.
4. 고치기 전과 뒤를 같은 고정 시험으로 잰다. 판정은 도구 호출 순서로만 한다.

## 1. 결정

### D1. 붙인 시각은 Agent Core 가 소유한 metadata 키 하나로 남긴다

- Agent Core 에 `Tool_results_appended_at` 모듈을 둔다. `Input_speaker`(`packages/agent_core/lib/llm_provider/types.mli:424`)와 같은 모양이다. 모듈이 키를 소유하고, 값은 초 단위 float 하나다. 읽는 쪽은 `classify : metadata -> Absent | Present of float | Duplicate` 로만 읽는다.
- 뜻은 「이 Tool 메시지의 결과가 대화에 붙은 시각」이다. 실시간 턴에서는 묶음(batch)의 모든 결과가 끝난 뒤다.
- 붙이는 함수는 하나다. `~appended_at` 을 필수 인자로 받는다. 지금 실행 결과를 히스토리에 붙이는 production 자리는 둘이다.
  - `packages/agent_core/lib/pipeline/pipeline.ml:572` (`stage_execute`): 파이프라인 시계(`Pipeline_common.timestamp_now ?clock`)로 찍는다.
  - `packages/agent_core/lib/pipeline/pipeline_terminal_resume.ml:22`: 일지(journal)에 남은 결과를 다시 붙이는 자리다. `Agent_tools.tool_execution_result`(`agent_tools.mli:116-125`)에는 완료 시각이 없다. 다시 붙이는 시각을 쓰면 결과가 실제보다 젊어 보인다. 그래서 이 자리는 찍지 않고 `Absent` 로 둔다.
- Agent Core 가 provider 로 보내는 요청에는 이 키를 싣지 않는다. L2 시험이 이를 고정한다.

### D2. 공식 클라이언트 인코딩은 시각을 정해진 필드로 싣는다 (v4 → v5)

- `Keeper_official_client_context_codec` 은 지금 metadata 를 그대로 싣고 `Input_speaker` 만 뺀다(`keeper_official_client_context_codec.ml:82`). 새 키를 그대로 실으면 모델은 또 unix 초 숫자를 받는다. 11-14 결과에도 `at_unix` 가 이미 들어 있었고, 모델은 쓰지 않았다.
- v5 는 raw 키를 빼고 Tool 메시지에 필드 하나를 둔다.
  - 시각이 있으면 `"result_time": {"state": "recorded", "appended_at": "2026-11-14T08:06:49Z"}` 다.
  - 없으면 `"result_time": {"state": "unrecorded"}` 다.
- 시각이 없는 경우를 턴 경계나 도구 호출 원장으로 짐작해 채우지 않는다. 배포 전에 쌓인 메시지, 일지에서 다시 붙인 결과가 `unrecorded` 다.
- 1.0 전이라 하드컷으로 바꾼다. 저장 상태를 바꾸는 것이 아니라 클라이언트로 보내는 글의 형식이 바뀐다.

### D3. 나이는 새 세션 씨앗에만 싣고 digest 에는 넣지 않는다

- 코덱이 렌더링을 타입으로 가른다. `type rendering = Canonical_source | Session_start of { started_at : float }` 이다.
- `canonical_source_sha256`(`keeper_official_client_context_codec.ml:104`)은 `Canonical_source` 로 인코딩한다. 나이가 없으므로 같은 히스토리는 언제 Start 해도 같은 digest 다. Muse(`keeper_muse_runtime.ml:1083`)와 Antigravity(`keeper_antigravity_runtime.ml:600`)가 저장한 세션을 이 digest 로 견준다. 나이가 digest 에 들어가면 모든 세션이 매번 바뀐 것으로 읽혀 이어 쓰지 못한다.
- `Session_start` 는 `result_time` 에 `"age_at_session_start": "4h00m"` 과 `"age_seconds": 14399` 를 더한다. `started_at` 은 Start 프롬프트를 만드는 시각이다.
- 코덱을 부르는 모든 자리는 둘 중 하나를 골라야 컴파일된다. Start 경로 넷(Claude Code·Codex·Muse·Antigravity)이 `Session_start` 를 고른다. 손으로 넷을 찾아 고치지 않고 컴파일러가 빠진 곳을 찾는다.
- Claude Code 씨앗 봉투는 `masc.claude-code.initial-turn.v1` → `v2` 로 바꾸고 `session_started_at` 을 맨 위에 둔다(`keeper_claude_code_runtime.ml:30-55`).

### D4. 고정 시험을 먼저 만들고, 고치기 전 값을 잰 뒤 고친다

§6 에 적는다. 시험 정의와 판정 스크립트는 고치는 층보다 먼저 들어간다. 고치는 층은 그 정의를 바꾸지 않는다.

## 2. 지금 모습 (11-14 사례)

시간 순서다. 모두 UTC 다.

| 시각 | 사건 | 근거 |
|---|---|---|
| 08:00:58 | uncle 턴 2183 시작 (Agent Core, GLM) | `traces/trace-1793027880185-00004/history.jsonl` 의 `#2183` 줄 |
| 08:06:49 | 턴 2183 이 `keeper_lane_status` 를 부름. 결과 1,001 B, 레인 실패 | `tool_calls/2026-11/14.001.jsonl`, `tool_use_id` `call_fade51e88afd4eb894e863b8`, `runtime_profile` `reviewer-pool-then-muse-glm` |
| 08:06:52 | 서버 로그의 마지막 `No user exists for uid 502` | `logs/system_log_2026-11-14.jsonl` |
| 09:07:56 | 다음 턴 경계 줄은 턴 2184 의 것. 턴 2183 은 `turn_ended` 줄이 없다 | `keepers/code-reviewer-uncle/turn-boundaries.jsonl` (#2182 07:56:20 → #2184 09:07:56) |
| 09:17:01 | masc 서버 재시작. 레인 회복 | `masc-start-*.log` 파일 이름 |
| 12:06:48 | Claude Code 새 세션 시작. 씨앗 history 는 메시지 3개(지시 444 B, 도구 호출 1,666 B, 도구 결과 1,334 B) | uncle 의 Claude Code 기록 `01a1d9f3-….jsonl` |
| 12:06:58 | Board 댓글: 「12:06Z 에 다시 확인했는데 레인이 죽어 있다」 | Board `p-3c7dcd17` 댓글 `c-21497a1e` |
| 12:07:12 | 이 세션의 첫 `keeper_lane_status`. 레인 정상 | 같은 기록 |

읽은 것:

- 씨앗의 도구 결과에는 시각 필드가 없다. metadata 도 비어 있다. 지시 메시지에는 `masc.model_input_tail_window.v1`, 도구 호출 메시지에는 `agent_core.reasoning_source.v2`(`glm-5.3-flash`)만 있다.
- 정본 히스토리 객체(`traces/<trace>/objects/d6/d6d29e…`)는 그 결과를 `role`·`origin`·`content` 로만 저장한다.
- 공식 클라이언트 턴은 Agent Core 체크포인트를 남기지 않는다(`keeper_agent_run_finalize_response.ml:394-401`, `Official_client, None -> Ok None`). 그래서 새 세션에 다시 들어가는 도구 결과는 Agent Core 턴이 붙인 것이다. 이 사례도 GLM 턴이 붙였다.
- 결과 본문에는 레인 서버의 관측 시각(`at_unix` 22:34:33Z 와 00:56:41Z)이 들어 있었다. 모델은 그 숫자를 지금과 견주지 않았다. 도구마다 시각 필드를 더해도 같은 일이 난다.
- 결과는 2,048 B 보다 작다. #51657 의 마커 규칙에 걸리지 않고 원문으로 갔다. 마커가 되었어도 「언제 본 것인가」는 남는다.
- 새 세션의 목표 문장은 「직전 대화·자율턴에서 이어 하던 작업의 남은 다음 단계를 확인하고 진행합니다」로 시작한다. 지난 대화를 이어 받으라는 뜻이다. 그 대화가 언제 일인지는 알려 주지 않는다.

## 3. 왜 이 모양인가

새 필드는 없으면 정본이 사실을 잃을 때만 더한다. 그래서 이미 있는 기록에서 시각을 투영하는 길을 먼저 봤다. 두 투영 모두 이 사례에서 답을 내지 못한다.

| 후보 | 이 사례에서 | 판단 |
|---|---|---|
| 턴 경계 `recorded_at` 으로 투영 | 턴 2183 은 `turn_ended` 줄이 없다 | 버림. 실패한 턴이 남긴 결과가 가장 위험한데, 바로 그 결과가 `unknown` 이 된다 |
| 도구 호출 원장 `ts` 로 투영 (`tool_use_id` 로 찾기) | 원장에는 08:06:49Z 가 있다 | 버림. 원장은 전체 Keeper 가 같이 쓰는 쓰기 전용 로그다. 하루 파일이 여러 개로 나뉘고 합이 수십 MB 다. 읽는 함수가 없다. Start 마다 며칠 치를 훑어야 한다 |
| `ToolResult` 블록에 typed 필드 추가 | 결과마다 정확한 시각을 남긴다 | 운영자 결정(§5-6). 체크포인트 객체 형식이 바뀐다. 헌법 `legacy_residue` 는 옛 데이터 호환 코드를 금지하고 바닥부터 다시 쌓는 것을 허용한다. 그래서 배포 때 모든 Keeper 의 히스토리를 버리는 것과 같다 |
| **metadata 키 (D1, 권함)** | 붙이는 순간 남는다 | 체크포인트 형식은 그대로다. 옛 메시지는 `Absent` 로 읽힌다. `Absent` 는 옛 형식 reader 가 아니라 키 모듈이 원래 갖는 상태다(`Input_speaker` 와 같다) |

대가:

- 시각이 결과마다가 아니라 묶음마다 하나다. 묶음 안의 이른 결과는 묶음 실행 시간만큼 실제보다 젊어 보인다. 시간 단위의 낡음을 가리는 데는 충분하다고 본다. 이 판단은 §6 시험이 확인한다.
- metadata 는 `(string * Yojson.Safe.t) list` 다(`types.mli:416-417`). 키 모듈 밖에서 이 키를 직접 쓰거나 읽으면 타입이 지켜 주지 못한다. `Input_speaker` 와 같이 모듈 밖에서는 키 문자열을 쓰지 않는다.

강타입 쪽 극단(블록 필드)과 동적 쪽 극단(원장 투영)을 모두 봤다. 체크포인트 형식을 지키면서 정본에 사실을 남기는 자리는 키 모듈뿐이다.

## 4. 운영자에게 보이는 변화

- 새 세션 씨앗의 도구 결과마다 `result_time` 이 붙는다. 기록이 있으면 붙인 시각과 나이, 없으면 `unrecorded` 다.
- 배포 직후 한 번, Muse·Antigravity 의 저장된 세션은 새 세션으로 시작한다. 코덱 schema 가 바뀌어 digest 가 한 번 바뀌기 때문이다. Keeper 마다 Start 가 한 번 더 생긴다.
- 대시보드·TUI 화면은 바뀌지 않는다. 새 Gate 는 없다. 「확인했다」는 말을 막는 장치도 없다.

## 5. 한계와 열린 질문

1. 이어 쓰는 세션(Resume)은 다루지 않는다. 공식 클라이언트가 자기 세션에 쥐고 있는 지난 턴의 결과에도 시각이 없다. 같은 종류의 문제다.
2. Agent Core 요청에도 붙인 시각을 실을지 정하지 않는다. 값이 메시지마다 고정이라 prefix 캐시는 깨지지 않는다. 대신 provider 요청 모양이 바뀐다. 별도 결정이다.
3. `appended_at` 은 MASC 가 답을 받은 시각이다. 도구가 바깥 세상을 잰 시각은 아니다. 11-14 결과도 08:06Z 에 받았지만 안의 관측은 그 전날 22:34Z 였다. 그 차이는 도구 결과 본문의 몫이다.
4. 나이를 보여 줘도 모델이 도구를 다시 부르지 않을 수 있다. 그러면 원인은 다른 곳이다. 후보는 목표 문장(§2 마지막 줄)이다. §6 시험이 이 가설을 가른다.
5. 일지에서 다시 붙인 결과(`pipeline_terminal_resume.ml`)는 `unrecorded` 다. 일지에 완료 시각을 남길지는 이 RFC 에서 정하지 않는다.
6. 운영자가 정할 것: 시각을 어디에 남기는가. 권하는 쪽은 metadata 키(D1)다. 히스토리를 버리지 않고, 묶음 단위 시각으로 시간 단위의 낡음을 가릴 수 있다고 본다. `ToolResult` 블록 필드를 고르면 결과마다 정확하고 컴파일러가 모든 생성 자리를 찾는다. 대신 배포 때 모든 Keeper 의 히스토리를 버린다. §6.1 시험에서 묶음 단위 시각으로 FAIL 이 줄지 않으면 이 질문을 다시 연다.

## 6. 확인 방법

### 6.1 고정 시험 (L1 에서 먼저 넣는다)

- 입력: 11-14 씨앗과 같은 모양의 history 3개다. 지시, `keeper_lane_status` 호출, 실패한 레인 결과 순서다. 결과는 세션 시작 4시간 전에 붙은 것으로 둔다. 목표는 그 레인이 필요한 리뷰 요청이 든 자율 턴이다. 본문은 지어낸 값이고 운영 기록을 옮기지 않는다.
- 두 갈래: 지금 인코딩(v4)과 D2·D3 인코딩(v5)이다. 같은 런타임·같은 모델로 갈래마다 20번 돌린다.
- 판정은 도구 호출 순서로만 한다. 바깥에 쓰는 도구(`masc_board_comment`, `masc_board_post`, 리뷰 게시 도구, `masc_keeper_msg`. 목록은 시험 파일에 고정) 중 첫 호출이 이 세션의 첫 `keeper_lane_status` 보다 앞서면 FAIL 이다. 글자로 「확인했다」를 찾지 않는다.
- 통과 기준: v5 의 FAIL 수가 v4 보다 적어야 L3 를 Ready 로 바꾼다. 줄지 않으면 「시각이 없어서」라는 가설이 틀린 것이다. L3 를 병합하지 않고 §5-4 로 돌아간다.
- 비용: 유료 세션 40번이다. 운영자가 허락한 뒤 돌린다. CI 에서는 판정 스크립트만 고정 기록으로 시험한다.

### 6.2 단위 시험

- L2: `stage_execute` 가 붙인 Tool 메시지에 키가 하나 있다. 일지에서 다시 붙인 메시지는 `Absent` 다. 체크포인트를 저장하고 읽어도 값이 같다. provider 요청 직렬화에는 키가 없다.
- L3: v5 인코딩이 raw 키를 뺀다. `recorded`·`unrecorded` 를 그대로 싣는다. `started_at` 만 다른 두 Start 에서 `canonical_source_sha256` 이 같다. 나이는 `started_at − appended_at` 이다.

### 6.3 배포 뒤

- 원장과 Claude Code 기록으로, 새 세션에서 바깥에 쓰는 첫 호출이 관측 도구보다 앞선 경우를 날짜별로 센다. 같은 정의를 쓴다.

## 7. 하지 않는 것

- 「확인했다」「checked」 같은 말을 글자로 잡는 검사.
- 새로 부르지 않고는 댓글을 못 달게 막는 Gate.
- 프롬프트에 「지난 결과를 믿지 마라」 문장만 더하기.
- 도구마다 시각 필드 더하기. `keeper_lane_status` 는 이미 `at_unix` 를 싣는다. 이 사례가 그 방법이 통하지 않는다는 것을 보였다.
- 옛 결과를 씨앗에서 빼기. 근거가 사라진다.
- 시각이 없을 때 턴 경계나 원장으로 짐작해 채우기.
- 나이를 정본 인코딩에 넣기(D3).

## 8. 층

RFC 가 Draft 일 때 native stack 으로 묶는다. 층마다 자기 changelog 조각을 넣는다.

| 층 | 내용 | 확인 |
|---|---|---|
| L0 | 이 RFC | `python3 scripts/rfc-generate-index.py --check` |
| L1 | §6.1 시험 입력과 판정 스크립트. v4 갈래 값 기록(운영자 허락 뒤) | 판정 스크립트 단위 시험 |
| L2 | Agent Core `Tool_results_appended_at` 키 모듈, `stage_execute` 에서 찍기, 일지 자리는 `Absent` | §6.2 L2 |
| L3 | 코덱 v5, `rendering` 타입, Claude Code 봉투 v2, Start 경로 넷 | §6.2 L3, §6.1 v5 갈래 값 |
