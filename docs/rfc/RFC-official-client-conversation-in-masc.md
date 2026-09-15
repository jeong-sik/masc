---
rfc: "official-client-conversation-in-masc"
title: "Record official-client turns in the keeper checkpoint so the token window can bound their sessions"
status: Draft
created: 2026-09-16
updated: 2026-09-16
author: vincent
related: ["keeper-context-window-in-tokens", "claude-code-context-overflow-bounded-restart"]
---

# RFC: 공식 클라이언트 턴도 keeper 체크포인트에 남겨야 토큰 창으로 세션을 묶을 수 있다

- 상태: Draft. `RFC-keeper-context-window-in-tokens` §11 4단계(공식 클라이언트 레인)가 막힌 이유와 그 앞에 필요한 결정이다.
- 기준: 코드 origin/main 3047704d5d, Claude Code 2.1.272. 공식 문서와 `claude --help` 는 2026-09-16 01:30 KST 에 읽었다.
- 관련 이슈: #36688 (claude_code 세션 resume), #36687 (memory recall 상한)

## 1. 요약

**사실**

1. 2026-09-15 16.5시간 동안 Claude Code keeper 세션 108개가 요청 4,225번을 보냈다. 요청 하나의 입력은 중앙값 374,876 토큰, 최대 967,180 토큰이다. 선언한 토큰 창은 이 레인에서 아무것도 줄이지 않는다.
2. masc 는 공식 클라이언트 턴의 대화를 keeper 체크포인트에 남기지 않는다. 새 세션의 이력은 그 체크포인트에서 만든다.
   - 그래서 세션을 새로 열 때마다 keeper 는 이전 세션에서 한 일을 잃는다.
   - 그래서 잃지 않으려고 세션을 이어 쓰면, 세션이 공급자 요약 지점(약 967K)까지 자란다.
3. 2026-09-08 20:46Z 에 Claude Code 가 2.1.265 가 된 뒤로, resume 턴에는 masc 가 턴마다 새로 만드는 System 맥락이 가지 않는다. memory recall, dynamic context, temporal summary, operator note 가 여기에 든다.
4. 턴 레코드와 세션 저장소는 resume 턴에 masc 입력을 보냈다고 적는다.

**결정**

5. masc 가 공식 클라이언트 턴의 대화를 keeper 체크포인트에 남긴다(§5.1).
6. 그 뒤 매 턴 새 세션을 열고, 이력은 masc 가 토큰 창으로 고른다. 원래 세션이 꼭 필요한 이어가기만 resume 한다(§5.3).
7. 순서: 기록을 바로잡는다 → 턴 대화를 남긴다 → 씨앗을 토큰으로 자른다 → 매 턴 새 세션.

## 2. 측정

### 2.1 무엇을 어디서 읽었나

| 수치 | 만든 곳 | 남는 곳 | 쓰는 곳 |
|---|---|---|---|
| 요청 하나의 입력 토큰 = `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` | Anthropic API 응답 usage. Claude Code 가 assistant 항목에 적는다 | `~/.claude/projects/<cwd>/<session>.jsonl` | §2.2, §2.4~2.6 |
| masc 가 띄운 세션인지 | 항목의 `entrypoint = "masc"` | 같은 파일 | 표본 고르기 |
| keeper 세션인지 | 파일이 있는 cwd 가 keeper base path(`-Users-dancer-me`)인지 | 파일 위치 | 표본 고르기 |
| 턴의 시작 | masc 가 stdin 으로 보낸 user 항목. `tool_result`·`isMeta`·`isCompactSummary` 는 뺀다 | 같은 파일 | 턴당 요청 수, 턴 사이 증가 |
| Claude Code 요약 | `system` 항목 `subtype = "compact_boundary"` | 같은 파일 | §2.6 |
| masc 기록의 atom 수 | 턴 레코드 `total_atoms` (그 턴의 이력 원천 전체) | `keepers/<name>/turn-records/` | §2.3 |
| 턴마다 붙인 System 맥락 | 턴 레코드 `blocks[].bytes`, `digest` | 같은 곳 | §2.4 |
| 시스템 프롬프트 파일 크기 (디스크 바이트) | `Runtime_claude_code.with_system_prompt_file` | `$TMPDIR/masc-claude-system-*.txt`, 프로세스가 도는 동안 | §2.4 |

- 요청은 assistant 항목의 `message.id` 로 센다. 병렬 도구 호출은 같은 id 를 되풀이하므로 한 번만 센다(#36725 과 같은 규칙).
- `model = "<synthetic>"` 항목은 API 호출이 아니어서 뺐다.
- 구간은 2026-09-15 00:00Z~16:30Z 다.
- masc 가 띄운 세션은 167개다. 이 중 keeper cwd 가 108개이고, 나머지 59개는 `masc-runtime-verify-*`·`masc-completion-review-*` 임시 디렉터리 57개와 scratchpad 2개다(§9).

### 2.2 요청 크기 (keeper 세션 108개)

| 항목 | 값 |
|---|---|
| 세션 / 이 구간에 새로 연 세션 | 108 / 75 |
| 턴 / 요청 | 810 / 4,225 |
| 요청 하나의 입력 토큰 | 중앙값 374,876 · p90 627,900 · 최대 967,180 |
| 턴당 요청 수 | 중앙값 2 · p90 11 · 최대 104 |
| 새 세션 첫 요청의 입력 토큰 | 중앙값 254,749 · p90 316,744 · 최대 336,011 · 최소 69,338 · 합 19,153,552 |
| 이어진 두 턴의 마지막 요청 차이 | 중앙값 3,929 · p90 25,463 · 최대 151,841 (693쌍) |
| cache_read / cache_creation 합 | 1,697,812,017 / 39,551,061 |
| input / output 합 | 8,450 / 2,528,625 |

- 다시 읽은 토큰(cache_read)이 새로 들어간 토큰(input + cache_creation)의 42.9배다.
- RFC-keeper-context-window-in-tokens 가 창 값으로 적은 85,000 토큰(§10.2)과 비교하면 중앙값은 4.4배, 최대는 11.4배다.

한 세션 안의 모습 (analyst, 2026-09-15):

| 턴 시작 (UTC) | masc 프롬프트 (글자) | 요청 수 | 첫 요청 cache_creation | 첫 요청 cache_read | 마지막 요청 입력 토큰 |
|---|---|---|---|---|---|
| 11:19:03 (새 세션) | 122,513 | 4 | 171,241 | 0 | 185,240 |
| 11:20:48 | 63 | 9 | 846 | 185,238 | 220,941 |
| 12:04:29 | 63 | 16 | 202 | 262,770 | 320,835 |
| 12:29:31 | 63 | 2 | 426 | 359,689 | 361,049 |
| 13:16:42 | 63 | 4 | 361,404 | 0 | 372,748 |

- resume 턴에 masc 가 보내는 프롬프트는 63자짜리 자율 턴 안내문 하나다.
- 세션은 keeper 자신의 작업(도구 호출과 결과, 응답)으로 자란다. 19턴 동안 185,240 → 372,748 토큰이 됐다.
- 13:16:42 턴은 캐시를 전혀 읽지 못했다. 원인은 재지 않았다(§8).

### 2.3 masc 기록은 Claude Code 턴으로 자라지 않는다

코드:
- 공식 클라이언트 레인은 턴 결과에 체크포인트를 싣지 않는다(`keeper_claude_code_runtime.ml:1120`, `keeper_codex_runtime.ml:1152`, `keeper_antigravity_runtime.ml:1060` 의 `checkpoint = None`).
- 턴 마무리는 공식 클라이언트 턴이면 체크포인트를 저장하지 않는다(`keeper_agent_run_finalize_response.ml:233-240`). 체크포인트를 들고 오면 오류다.
- librarian 은 이 턴의 마지막 assistant 메시지 하나만 받는다(`:245-249`).
- 새 세션 이력은 keeper 체크포인트의 메시지에서 온다(`keeper_agent_run.ml:982`, `Keeper_run_prompt.history_messages`).

턴 레코드 (2026-09-15, Claude Code 턴만):

| keeper | 턴 수 | `absolute_turn` | `total_atoms` 범위 | 이어진 두 레코드 사이에 바뀐 횟수 |
|---|---|---|---|---|
| critic | 156 | 2177..2342 | 1,691..1,788 | 3 |
| edgar.a.poe | 133 | 2750..2891 | 877..931 | 4 |
| analyst | 84 | 3941..4057 | 7,867..8,225 | 13 |
| rondo | 84 | 4484..4580 | 8,347..9,137 | 7 |
| jazz-developer | 79 | 2469..2575 | 3,852..4,088 | 19 |
| kidsnote-slack-context-collector | 72 | 884..991 | 2,238..2,401 | 16 |
| goo-yang-bong | 50 | 1609..1681 | 11,095..11,443 | 12 |
| code-reviewer | 49 | 3640..3695 | 14,348..14,550 | 3 |

- 턴마다 요청을 여러 번 보내 도구를 쓰는데, masc 기록은 수십 턴에 한 번 바뀐다.

같은 씨앗으로 연 새 세션 (keeper cwd, 첫 masc 프롬프트 글자 수가 같은 것):

| 씨앗 (글자) | 새 세션 수 | 첫 세션 ~ 마지막 세션 (UTC) | 세션별 요청 수 |
|---|---|---|---|
| 185,787 | 13 | 04:07:54 ~ 11:09:30 | 66, 4, 1, 11, 7, 1, 39, 20, 9, 5, 44, 58, 50 |
| 256,513 | 6 | 05:44:07 ~ 09:38:41 | 3, 1, 6, 5, 55, 124 |
| 134,417 | 6 | 08:21:10 ~ 10:32:10 | 16, 86, 92, 26, 65, 12 |

- 185,787자 세션 두 개(05:47:33, 05:53:09)의 첫 요청(246,996, 250,908 토큰)은 edgar.a.poe 턴 2773, 2776 레코드의 `input_tokens` 와 같다. 256,513자 세션(05:47:24)의 첫 요청 313,439 토큰은 critic 턴 2208 과 같다. 세 세션 모두 요청이 1번뿐이라, #36725 전의 합산 기록도 요청 하나의 값이다.
- 185,787자 씨앗으로는 7시간 동안 새 세션 13개가 열렸고, 그 세션들의 요청은 모두 315번이다. 씨앗 크기가 한 글자도 안 바뀌었다.

### 2.4 resume 턴에는 턴마다 만든 System 맥락이 가지 않는다

**masc 가 보내는 것.** 턴마다 만드는 맥락 블록은 System 역할 메시지 하나가 된다(`keeper_run_tools_hooks.ml:793-885` → `keeper_official_client_host.ml:89-95, 431-434`). Claude Code 레인은 System 메시지를 모두 시스템 프롬프트 파일에 넣는다(`keeper_claude_code_runtime.ml:29-43, 611-617`). resume 때는 여기에 canonical 대화 스냅샷(`masc.official-client-canonical-context.v1`)도 붙인다(`:579-590`).

블록은 거의 매 턴 바뀐다. 2026-09-14~15 Claude Code 턴 레코드에서 잰 값이다.

| keeper | 턴 수 | `memory_os_recall` 서로 다른 값 수 · 크기 | `dynamic_context` 서로 다른 값 수 · 크기 |
|---|---|---|---|
| code-reviewer | 49 | 49 · 204,836~210,909 B | 49 · 7,795~41,858 B |
| analyst | 175 | 166 · 132,319~193,266 B | 166 · 7,078~15,075 B |
| rondo | 84 | 80 · 158,800~163,944 B | 80 · 1,953~16,685 B |
| edgar.a.poe | 133 | 132 · 71,892~82,177 B | 131 · 4,766~19,923 B |

**Claude Code 가 받는 것.** 설치된 2.1.272 의 `claude --help`:

> --system-prompt-snapshot <on|off>  Record the system prompt once per conversation and reuse it verbatim on every request and resume. on (the default): the prompt is rendered on the conversation's first request — a --system-prompt or --append-system-prompt included — sent, and recorded; every later request and resume sends the record as-is, even when a later launch passes different text, until the conversation is compacted. off: never record; the prompt is rendered fresh every request.

- 공식 문서(code.claude.com/docs/en/cli-reference, "System prompt flags in resumed conversations")도 같다.
- 조건이 있다.
  - 기본값 `on` 은 2.1.265 부터다. 그 전에는 시스템 프롬프트 플래그를 주면 기록이 꺼졌다.
  - bare mode 는 기록하지 않는다. feature flag 를 받지 않는 공급자(Bedrock, Agent Platform, Foundry)는 2.1.268 전까지 기록하지 않았다.
  - 요약하면 그때부터 마지막으로 띄운 프로세스의 시스템 프롬프트가 쓰인다(§2.6).
- masc 는 `--system-prompt-snapshot` 을 넘기지 않고(`runtime_claude_code.ml:1296-1349`) CLI 버전도 고정하지 않는다. 그래서 이 동작은 설치된 CLI 버전과 공급자가 정한다.

**버전별 실측.** resume 턴 첫 요청에서 캐시에 새로 쓴 비율이다. 표본은 2026-09-05~09-11 에 수정된 transcript 이고, 턴 버전은 그 턴 user 항목의 `version` 이다.

| Claude Code | 기간 (UTC, masc 세션에서 본 것) | resume 턴 | 새로 쓴 비율 중앙값 | 절반 넘게 새로 쓴 턴 |
|---|---|---|---|---|
| 2.1.261 | 09-05 | 979 | 0.863 | 979 |
| 2.1.263 | 09-06 ~ 09-08 20:15 | 3,351 | 0.868 | 3,185 |
| 2.1.265 | 09-08 20:46 ~ 23:55 | 113 | 0.001 | 0 |
| 2.1.266 | 09-09 | 432 | 0.001 | 10 |

- 2.1.263 까지는 resume 턴마다 새 시스템 프롬프트를 보냈다. 캐시는 도구 층에서 끊겨 요청의 약 86% 를 다시 썼다.
- 2.1.265 부터는 세션 첫 요청의 시스템 프롬프트를 계속 쓴다.

**이번 주 확인.** 2026-09-15 16:28~16:35Z 에 masc 가 띄운 `claude` 프로세스의 인자와 시스템 프롬프트 파일 크기를 0.3초 간격으로 기록했다. 기록을 시작할 때 이미 돌던 프로세스도 들어간다. 파일은 프로세스를 띄우기 전에 한 번 쓰고 바꾸지 않는다.

| keeper | 턴 시작 (UTC) | 방식 | 시스템 프롬프트 파일 | 첫 요청 cache_creation | 첫 요청 cache_read |
|---|---|---|---|---|---|
| code-reviewer | 16:26:55 | 새 세션 | 266,930 B | 309,272 | 0 |
| code-reviewer | 16:31:55 | resume | 535,812 B, 스냅샷 있음 | 965 | 380,950 |
| msx-retro-mania | 16:32:15 | resume | 353,933 B, 스냅샷 있음 | 676 | 267,052 |
| msx-retro-mania | 16:33:10 | resume | 413,083 B, 스냅샷 있음 | 1,932 | 270,416 |

- code-reviewer 턴 3693(새 세션) 블록 합은 264,380 B 로 새 세션 파일 266,930 B 와 거의 같다. 턴 3694(resume) 에서 `dynamic_context` 가 41,858 B 에서 36,048 B 로 바뀌었지만, 그 턴은 캐시에서 첫 요청의 것을 읽었다.
- operator note 는 이 System 맥락에 들어가고, 넣은 턴에서 소비됨으로 표시된다(`keeper_run_tools_hooks.ml:948-952`). resume 턴이면 전달되지 않은 채 소비된다. 2026-09-16 에 디스크에 남은 note(`keepers/*/pending-note.json`)는 없었다.

### 2.5 기록이 틀렸다

- 턴 레코드 입력 구성: `report_transmitted_input` 이 resume 에도 `Whole_input_transmitted prepared.messages` 를 보고한다(`keeper_claude_code_runtime.ml:594-598`).
  - `Keeper_official_client_host` 계약(`keeper_official_client_host.mli:30-37`)과 이 레인의 계약(`keeper_claude_code_runtime.mli:84-89`)은 resume 을 `Held_by_client_session` 으로 정한다.
  - 2026-09-14 #36035 가 두 계약과 다르게 바꿨다. #36688 이 본 "turn 4484~4550 동안 똑같은 composition" 이 그 결과다.
- 세션 저장소: code-reviewer `official-client-runtime/session.json` 에 `context_frontier.delivery = "replaced_configuration"`, `message_count = 86` 이 남았다(2026-09-15 16:33Z). 요약 전에는 바뀌지 않는 구성을 바꿨다고 적은 기록이다.
- Codex 레인도 같은 구조다(`keeper_codex_runtime.ml:662-725`). `thread/resume` 에서 새 `developerInstructions` 를 쓰는지는 확인하지 않았다.
- Antigravity 레인은 resume 을 `Held_by_client_session` 으로 보고한다(`keeper_antigravity_runtime.ml:531-535`).

### 2.6 Claude Code 가 keeper 대화를 요약했다

- 2026-09-15T12:40:44Z, 세션 `01a0a4c1-7858…`: `trigger = auto`, `preTokens = 967,790`, `postTokens = 5,133`.
- 바로 다음 요청은 296,010 토큰이었다. cache_read 50,210, cache_creation 245,798.
  - 요약본은 5,133 토큰이다. 문서대로라면 나머지는 도구 층과, 요약 뒤부터 쓰이는 마지막 resume 프로세스의 시스템 프롬프트(스냅샷 포함)다.
- 공식 문서(code.claude.com/docs/en/model-config, "Default auto-compact thresholds"): 1M 창으로 도는 Sonnet 5 는 "compact before the window fills, at about 967K tokens by default".
- masc 에는 요약이 없다(RFC-keeper-context-window-in-tokens §1.3). 이 레인에서는 공급자가 요약하고, masc 는 그 사실을 기록하지 않는다.

## 3. 현재 동작

- **세션을 새로 여는 때** (`keeper_claude_code_runtime.ml:519-524`, `keeper_official_client_session_store.ml:810-869`)
  - 저장 상태가 없거나 `ready` 일 때
  - `client_kind` 나 `runtime_id` 가 바뀌었을 때
  - 도구 표면 digest 가 바뀌었을 때(`reconcile_tool_surface`)
  - 복구가 새 시작을 고른 때
  - 그 밖에는 저장된 settlement 로 항상 resume 한다.
- **새 세션의 이력 씨앗** (`:1193-1213`): 체크포인트 이력을 `min(max-prompt-bytes, max-request-body-bytes)` 바이트로 자른다. 라이브 설정은 둘 다 524,288 이다.
- **resume 턴** (`:579-613`, `runtime_claude_code.ml:1329-1331`): 프롬프트는 goal 한 줄이고 `--resume=<id>` 로 띄운다.
- **usage** (`runtime_claude_code.ml:98-118`): 턴 레코드는 가장 최근 요청의 usage 를 `per_request` 로 적는다(#36725).
- **원래 세션이 필요한 이어가기**
  - Gate 이어가기: 저장된 settled 세션이 원래 세션이어야 한다(`validate_continuation`, `keeper_official_client_session_store.mli:184-188`).
  - direct checkpoint 이어가기: 같다. 사이에 끼인 steering 턴도 같은 세션에서 돈다(`keeper_direct_checkpoint_continuation.ml:18-27`).
- **Codex** (`keeper_codex_runtime.ml:591-595`): resume 규칙이 같다. usage 는 `tokenUsage.last` 다.
- **Antigravity** (`keeper_antigravity_runtime.ml:455-477, 1055`): resume 규칙이 같다. canonical 원본이 바뀌면 resume 을 거절한다. usage 는 `conversation_cumulative` 다.

## 4. 결함

1. **masc 가 이 레인의 대화를 갖고 있지 않다.** 세션을 새로 열면 keeper 는 이전 세션에서 한 일을 잃는다. 잃지 않으려면 세션을 끝없이 이어 써야 한다. 크기 문제는 이 결함의 결과다(§2.3).
2. **resume 턴에 System 맥락이 가지 않는다.** 2026-09-08 20:46Z 부터다. keeper 는 세션을 연 때의 memory recall 과 dynamic context 로 일한다. operator note 는 전달 없이 소비된다(§2.4).
3. **창이 요청 크기를 정하지 않는다.** 세션은 요약 지점까지 자라고, 요약되면 masc 모르게 대화가 5,133 토큰으로 바뀐다(§2.2, §2.6).
4. **새 세션 씨앗을 바이트로 자른다.** RFC-keeper-context-window-in-tokens §4 4번과 같다.
5. **전송 기록이 틀렸다.** resume 턴을 전송했다고, 구성을 바꿨다고 적는다(§2.5).

## 5. 결정

### 5.1 공식 클라이언트 턴의 대화를 keeper 체크포인트에 남긴다

| | |
|---|---|
| 남기는 것 | 턴의 user 메시지, assistant 텍스트와 masc 도구 호출, masc 가 돌려준 도구 결과, 마지막 응답. 턴 안의 순서 그대로 |
| 만드는 곳 | masc 가 이미 받는 것들이다. 스트림 프레임(`claude_stream_callback`, `keeper_claude_code_runtime.ml:159`)과 MCP 도구 경계(`on_official_client_tool_boundary`) |
| 두는 곳 | keeper 체크포인트 메시지. Agent Core 레인과 같은 이력 원천이다 |
| 쓰는 곳 | 다음 새 세션 씨앗(§5.2), librarian 입력(지금은 마지막 메시지 하나) |

- `keeper_agent_run_finalize_response.ml:233-240` 의 소유 규칙이 바뀐다. 공식 클라이언트 턴도 체크포인트를 쓴다.
- 이 기록이 있어야 다른 런타임이 대신 돈 턴, direct 채팅, 복구 뒤 새 세션이 같은 대화를 본다. #36035 가 스냅샷으로 풀려던 문제도 여기서 풀린다.
- 체크포인트 쓰기 비용이 커진다. 지금 Agent Core 레인 체크포인트는 도구 라운드마다 전체를 다시 쓴다. 이 결정은 그 비용을 이 레인으로 넓힌다(§8).

### 5.2 새 세션의 씨앗을 토큰으로 자른다

- 이력 용량은 `W = [turn] context_window_tokens` 에서 고정부(도구 정의와 시스템 프롬프트)를 뺀 값이다(RFC-keeper-context-window-in-tokens §10.3).
- 이 레인은 보내기 전에 토큰을 셀 수 없다. 공급자 수치는 보낸 뒤 첫 요청 usage 로만 온다.
- 요청 하나의 바이트를 토큰으로 바꾸는 한 개의 비율은 이 레인에서 맞지 않는다.
  - Claude Code 가 붙이는 앞부분이 있다. 서로 다른 keeper 두 세션(geek-scout 16:27:49Z, msx-retro-mania 16:28:06Z)이 첫 요청에서 똑같이 50,210 토큰을 캐시에서 읽었다.
  - masc 는 그 앞부분의 바이트를 모른다. MCP 도구 스키마를 Claude Code 가 늦게 싣는지도 확인하지 않았다(env-vars 문서 `ENABLE_TOOL_SEARCH`).
  - 그래서 "토큰 = 고정 앞부분 + 기울기 × masc 바이트" 꼴이다. 비율 하나는 숨은 계수가 된다.
- 방법은 정하지 않았다(§8 1번). 방법이 정해지기 전에는 §5.3 을 켜지 않는다.

### 5.3 매 턴 새 세션을 연다

| 상태 | 이번 턴 |
|---|---|
| Gate 이어가기나 direct checkpoint 이어가기가 settled 세션에 묶여 있음 | 그 세션을 resume 한다 |
| 그 밖 | 새 세션. 씨앗은 §5.2 로 고른다 |

- 요청 하나의 크기는 `씨앗 + 그 턴의 증가` 다. 턴 사이 증가는 중앙값 3,929, p90 25,463, 최대 151,841 토큰이었다.
- "직전 요청이 W 이하일 때만 resume" 은 고르지 않았다.
  - 씨앗을 W 에 맞춰 채우면 첫 턴에 도구를 몇 번만 써도 W 를 넘는다. 결국 거의 매 턴 새 세션이 된다.
  - 이를 피하려면 씨앗과 W 사이 여유를 정해야 하는데, 그 크기는 계수다.
  - 새로 저장할 값(직전 요청 토큰), 전이마다 그 값을 옮기는 규칙, 저장 형식 hard cut 이 따라온다.
- 턴 맥락을 매 턴 전달하면 resume 의 캐시 이점이 대부분 사라진다. 시스템 프롬프트가 바뀌면 그 뒤 캐시가 모두 무효다. 2.1.263 까지 resume 턴은 요청의 약 86% 를 다시 썼다(§2.4).
- 새 세션도 매 턴 씨앗을 cache_creation 으로 쓴다. 차이는 크기다. 새 세션은 `W + 턴 증가` 안이고, resume 은 세션 전체다.
- 판정 입력(묶인 이어가기가 있는가)은 `plan_claim` 과 `claim_with_context_frontier` 가 똑같이 받는다. 지금 claim 은 계획을 다시 세운다(`keeper_official_client_session_store.ml:944-945`). 두 계획이 다르면 turn count 가 어긋나 복구로 빠진다.
- Antigravity 는 이 규칙에서 뺀다. 요청별 토큰이 없고, canonical 원본 guard 가 따로 있다(§8).

### 5.4 resume 과 요약을 명시한다

- 모든 Claude Code 실행에 `--system-prompt-snapshot off` 를 넘긴다.
  - §5.3 전에 켜면 resume 턴에도 턴 맥락이 간다. 대신 resume 턴마다 캐시를 다시 쓴다. 이때 켤지는 운영자가 정한다(§10 1b).
  - §5.3 뒤에는 묶인 이어가기 턴에만 의미가 있다.
  - CLI 기본값과 공급자에 따라 동작이 달라지지 않게 한다(§2.4 조건).
- resume 시스템 프롬프트에 canonical 스냅샷을 넣지 않는다. `off` 에서는 transcript 와 같은 대화가 두 번 들어간다.
- 모든 Claude Code 실행에 `DISABLE_COMPACT=1` 을 넘긴다(env-vars 문서). 창을 넘으면 공급자 요약 대신 이미 있는 typed `Context_window_exceeded` 경로로 간다(`runtime_claude_code.ml` terminal 판정).

### 5.5 전송 기록

- resume 은 보낸 것만 적는다. 이 턴의 System 메시지는 보냈고, 이력은 공급자 세션이 쥐고 있다. `transmitted_model_input` 에 이 경우를 뜻하는 생성자를 더한다. 쓰는 곳은 `keeper_agent_run.ml:1324-1333` 하나다.
- resume 은 `context_frontier` 의 스냅샷 값(`snapshot_sha256`, `message_count`, `delivery`)을 저장된 값 그대로 넘긴다. `acknowledged_turn` 은 지금처럼 claim 이 비우고 settle 이 채운다(`:941-942`, `:1074-1077`).

## 6. 고르지 않은 것

| 안 | 고르지 않은 이유 |
|---|---|
| 지금대로 둔다 | 결함 1~5 가 그대로다 |
| 직전 요청이 W 이하일 때만 resume | §5.3. 여유 크기가 계수가 되고, 결국 매 턴 새 세션에 가깝다 |
| Claude Code 요약 창을 W 로 (`--autocompact`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`) | LLM 요약이다(RFC-keeper-context-window-in-tokens §1.3). §2.6 에서 967,790 토큰이 5,133 토큰이 됐고 masc 는 무엇이 남았는지 모른다. 문서상 창 하한도 100,000 토큰이다 |
| `--system-prompt-snapshot off` 만 켠다 | 턴 맥락은 간다. 하지만 세션은 계속 자라고, 턴마다 세션 전체의 약 86% 를 다시 쓴다. 새 세션 때 일을 잃는 것도 그대로다 |
| 턴 맥락을 user 메시지로 보낸다 (Antigravity 방식) | transcript 에 턴마다 쌓인다. memory recall 만 턴마다 71,892~210,909 B 다 |
| 체크포인트 대신 공급자 transcript 를 읽어 씨앗을 만든다 | 공급자 파일 형식에 기대고, 공급자가 요약하면 원문이 없다 |
| 모델 창(1M) 기준으로 새 세션 (#36688 제안 3) | 운영자는 전송 창을 `W` 로 정했다 |
| 턴당 요청 수 상한 (`--max-turns`) | 크기가 아니라 keeper 의 일을 자른다 |

## 7. RFC-keeper-context-window-in-tokens §7 대조

| §7 | 이 RFC 에서 |
|---|---|
| 1. 창은 토큰으로 선언한다 | `W` 하나를 쓴다 |
| 2. 본문 상한은 판정에만 쓴다 | `max-prompt-bytes` 는 씨앗 판정에만 쓴다 |
| 7. 요약하지 않는다 | `DISABLE_COMPACT=1`. 대화 원문은 masc 체크포인트에 있다 |
| 8. 계수를 박지 않는다 | §5.2 방법을 정하기 전에는 §5.3 을 켜지 않는다 |
| 9. 모델 창을 넘는 창은 없다 | `W ≤ max-context` 검사를 이 레인 후보에도 적용한다 |
| 10. 운영자가 설정만 보고 안다 | 턴마다 새 세션인지, resume 이면 어떤 이어가기인지 로그 한 줄 |

## 8. 열린 질문

1. **씨앗을 토큰으로 자르는 방법(§5.2).** 보내기 전에 셀 수 없는 레인에서, 계수 없이 무엇으로 자르나.
   - 후보 가. keeper 별로 새 세션 첫 요청의 공급자 토큰과 masc 바이트를 쌓아 "앞부분 + 기울기" 두 값을 관측으로 맞춘다. 관측이 둘 미만이면 floor.
   - 후보 나. 공급자 토큰 계산 경로가 구독 CLI 에 있는지 확인한다.
2. **턴에서 무엇을 남길 수 있나(§5.1).** thinking 블록, native 도구(Read/Grep 등)를 켠 keeper 의 결과, 병렬 도구 호출 순서. Codex(`thread/inject_items`)와 Antigravity 의 경로.
3. **체크포인트 쓰기 비용.** 공식 클라이언트 턴까지 체크포인트에 쓰면 쓰기와 크기가 늘어난다. 체크포인트를 작업 꼬리만 두는 설계와 순서를 맞춰야 한다.
4. **Codex.** `thread/resume` 의 `developerInstructions` 적용 여부. `tokenUsage.last` 가 요청 단위인지 턴 단위인지(`runtime_codex_app_server.ml:92, 920`).
5. **Antigravity.** 요청별 토큰이 없다. 같은 정책으로 갈지, 지금의 guard 로 둘지.
6. **§2.2 13:16:42 처럼 resume 턴이 캐시를 전혀 못 읽는 원인.**

## 9. 범위 밖

- keeper cwd 가 아닌 masc 호출 59개(§2.1). 누가 왜 부르는지는 따로 본다.
- memory recall·브리핑 크기 자체. #36687 과 RFC-keeper-context-window-in-tokens 2단계가 다룬다. 다만 고정부가 `W` 를 넘으면 §5.3 뒤 씨앗은 floor 가 된다.

## 10. 이행

| 단계 | 내용 | 먼저 필요한 것 | 비용 변화 |
|---|---|---|---|
| 1 | 전송 기록 바로잡기(§5.5), resume 스냅샷 삭제, `DISABLE_COMPACT=1` | 없음 | 토큰은 거의 그대로다. 공급자 요약 대신 typed overflow 로 턴이 실패한다(09-15 에 1번 날 일) |
| 1b | `--system-prompt-snapshot off` (§5.4) | 운영자 결정 | resume 턴마다 세션의 약 86% 를 cache_creation 으로 쓴다(09-08 전 수준) |
| 2 | 공식 클라이언트 턴 대화를 체크포인트에(§5.1) | §8 2·3번 | 체크포인트 쓰기 증가 |
| 3 | 씨앗을 토큰으로(§5.2) | §8 1번 | 새 세션 첫 요청이 `W` 안으로 |
| 4 | 매 턴 새 세션(§5.3) | 2·3단계 | 요청 하나가 `W + 턴 증가` 안으로 |
| 5 | Codex, Antigravity | §8 4·5번 | |

## 11. 배포 후 측정

§2 와 같은 방법으로 잰다.

- 1단계 뒤: `compact_boundary`(`entrypoint = "masc"`) 수는 0. resume 턴 레코드의 입력 구성이 `Client_session_holds_input` 계열로 바뀌었는지.
- 1b 뒤: resume 턴 첫 요청의 새로 쓴 비율. 턴 레코드 블록 digest 가 바뀐 턴에서 캐시가 끊기는지.
- 2단계 뒤: Claude Code 턴마다 `total_atoms` 가 늘어나는지. 같은 씨앗으로 연 새 세션 수는 0.
- 4단계 뒤: 요청 하나의 입력 토큰 중앙값·p90·최대. 최대는 `W + 턴 사이 증가 p90` 부근이어야 한다. cache_read ÷ (input + cache_creation).
