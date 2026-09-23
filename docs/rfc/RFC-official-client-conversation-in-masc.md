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
- 관련 이슈: #36688 (claude_code 세션 resume), #36687 (memory recall 상한), #36716 (브리핑 예산), #36757 (다음 요청 예보)

## 1. 요약

**사실**

1. 2026-09-15 16.5시간 동안 Claude Code keeper 세션 108개가 요청 4,225번을 보냈다. 요청 하나의 입력은 중앙값 374,876 토큰, 최대 967,180 토큰이다. 선언한 토큰 창은 이 레인에서 아무것도 줄이지 않는다.
2. masc 는 공식 클라이언트 턴의 대화를 keeper 체크포인트에 남기지 않는다. 새 세션의 이력은 그 체크포인트에서 만든다.
   - 그래서 세션을 새로 열 때마다 keeper 는 이전 세션에서 한 일을 잃는다.
   - 그래서 잃지 않으려면 세션을 이어 써야 하고, 세션은 공급자 요약 지점(약 967K)까지 자란다.
3. 세션은 자주 버려진다. 같은 날 새 세션 115개 중 48개는 공급자 거절(대부분 429, 도구 효과 없음) 뒤 30초 안에 열렸다. 도구 개수도 keeper 마다 하루에 여섯 가지 값으로 흔들렸다.
4. 2026-09-08 20:46Z 에 Claude Code 가 2.1.265 가 된 뒤로, resume 턴에는 masc 가 턴마다 새로 만드는 System 맥락이 가지 않는다. memory recall, dynamic context, temporal summary, operator note 가 여기에 든다.
5. 턴 레코드와 세션 저장소는 resume 턴에 masc 입력을 보냈다고 적는다.

**결정과 순서**

| | 무엇 | 왜 이 자리인가 |
|---|---|---|
| 1 | 효과가 없는 공급자 거절은 세션을 버리지 않는다(§5.1). 도구 표면이 흔들리는 원인을 멈춘다(§5.2) | 기록이 없는 동안 세션이 유일한 사본이다. 지금 바로 할 수 있다 |
| 2 | 전송 기록을 사실대로 적는다(§5.3) | 거짓 durable 기록이다. 동작을 바꾸지 않는다 |
| 3 | 턴 맥락 전달을 켤지 정한다(§5.4) | 운영자 결정. 맞는 방향이지만 resume 턴마다 캐시를 다시 쓴다 |
| 4 | 고정부 예산을 정한다(§5.5) | 도구 스키마와 pinned 맥락이 창보다 크다. 이걸 두고는 어떤 창 설계도 이력을 담지 못한다 |
| 5 | 공식 클라이언트 턴의 대화를 체크포인트에 남긴다(§5.6) | 뿌리. 캡처 설계가 필요하다 |
| 6 | 씨앗을 토큰으로 자르고, 매 턴 새 세션을 열고, 공급자 요약을 끈다(§5.7) | 5 단계가 있어야 안전하다 |

## 2. 측정

### 2.1 무엇을 어디서 읽었나

| 수치 | 만든 곳 | 남는 곳 | 쓰는 곳 |
|---|---|---|---|
| 요청 하나의 입력 토큰 = `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` | Anthropic API 응답 usage. Claude Code 가 assistant 항목에 적는다 | `~/.claude/projects/<cwd>/<session>.jsonl` | §2.2, §2.4~2.6 |
| masc 가 띄운 세션인지 | 항목의 `entrypoint = "masc"` | 같은 파일 | 표본 고르기 |
| keeper 세션인지 | 파일이 있는 cwd 가 keeper base path(`-Users-dancer-me`)인지 | 파일 위치 | 표본 고르기 |
| 턴의 시작 | masc 가 stdin 으로 보낸 user 항목. `tool_result`·`isMeta`·`isCompactSummary` 는 뺀다 | 같은 파일 | 턴당 요청 수, 턴 안팎의 증가 |
| Claude Code 요약 | `system` 항목 `subtype = "compact_boundary"` | 같은 파일 | §2.6 |
| masc 기록의 atom 수 | 턴 레코드 `total_atoms` (그 턴의 이력 원천 전체) | `keepers/<name>/turn-records/` | §2.3 |
| 턴마다 붙인 System 맥락 | 턴 레코드 `blocks[].bytes`, `digest` | 같은 곳 | §2.4 |
| 시스템 프롬프트 파일 크기 (디스크 바이트) | `Runtime_claude_code.with_system_prompt_file` | `$TMPDIR/masc-claude-system-*.txt`, 프로세스가 도는 동안 | §2.4 |
| 새 세션·resume 과 도구 수, 복구 승계 | 서버 로그 `Claude Code turn composition: mode=… tools=…`, `auto-superseded official-client recovery=… failure=…` | `<base-path>/.masc/logs/system_log_2026-09-15.jsonl` | §2.7 |

- 요청은 assistant 항목의 `message.id` 로 센다. 병렬 도구 호출은 같은 id 를 되풀이하므로 한 번만 센다(#36725 과 같은 규칙).
- `model = "<synthetic>"` 항목은 API 호출이 아니어서 뺐다.
- 구간은 2026-09-15 00:00Z~16:30Z 다.
- masc 가 띄운 세션은 167개다. 이 중 keeper cwd 가 108개이고, 나머지 59개는 `masc-runtime-verify-*`·`masc-completion-review-*` 임시 디렉터리 57개와 scratchpad 2개다(§9).

### 2.2 요청 크기 (keeper 세션 108개)

| 항목 | 값 |
|---|---|
| 세션 / 이 구간에 새로 연 세션 | 108 / 75 (transcript 기준. 서버 로그의 새 세션 줄은 115개다 — §2.7) |
| 턴 / 요청 | 810 / 4,225 |
| 요청 하나의 입력 토큰 | 중앙값 374,876 · p90 627,900 · 최대 967,180 |
| 턴당 요청 수 | 중앙값 2 · p90 11 · 최대 104 |
| 새 세션 첫 요청의 입력 토큰 | 중앙값 254,749 · p90 316,744 · 최대 336,011 · 최소 69,338 · 합 19,153,552 |
| 한 턴 안에서 자란 양 (첫 요청 → 마지막 요청) | 요청이 2번 이상인 턴 631개: 중앙값 4,829 · p90 29,623 · 최대 188,116. 새 세션의 첫 턴 57개: 중앙값 17,387 · p90 106,276 · 최대 188,116 |
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

- resume 턴에 masc 가 보내는 프롬프트는 63자짜리 자율 턴 안내문 하나다(131 바이트).
- 세션은 keeper 자신의 작업으로 자란다. 19턴 동안 185,240 → 372,748 토큰이 됐다.
- 13:16:42 턴은 캐시를 전혀 읽지 못했다. 원인은 재지 않았다(§8).

### 2.3 masc 기록은 Claude Code 턴으로 자라지 않는다

코드:
- 공식 클라이언트 레인은 턴 결과에 체크포인트를 싣지 않는다(`keeper_claude_code_runtime.ml:1120`, `keeper_codex_runtime.ml:1152`, `keeper_antigravity_runtime.ml:1060` 의 `checkpoint = None`).
- 턴 마무리는 공식 클라이언트 턴이면 체크포인트를 저장하지 않는다(`keeper_agent_run_finalize_response.ml:233-240`). 체크포인트를 들고 오면 오류다.
- librarian 은 이 턴의 마지막 assistant 메시지 하나만 받는다(`:245-249`).
- 새 세션 이력은 keeper 체크포인트의 메시지에서 온다(`keeper_agent_run.ml:982`, `Keeper_run_prompt.history_messages`).

턴 레코드 (2026-09-15 00:00Z~16:30Z, `request_runtime_profile` 이 claude_code 인 레코드):

| keeper | 레코드 | `absolute_turn` | `total_atoms` 범위 | 이어진 두 레코드 사이에 바뀐 횟수 |
|---|---|---|---|---|
| critic | 156 | 2177..2342 | 1,691..1,788 | 3 |
| edgar.a.poe | 132 | 2750..2887 | 877..915 | 3 |
| analyst | 84 | 3941..4057 | 7,867..8,225 | 13 |
| rondo | 83 | 4484..4578 | 8,347..9,137 | 6 |
| jazz-developer | 79 | 2469..2575 | 3,852..4,088 | 19 |
| kidsnote-slack-context-collector | 72 | 884..991 | 2,238..2,401 | 16 |
| goo-yang-bong | 50 | 1609..1681 | 11,095..11,443 | 12 |
| code-reviewer | 46 | 3640..3689 | 14,348..14,368 | 2 |

- 바뀐 자리를 나눠 보면 기록이 자라는 쪽은 다른 레인이다.
  - critic: claude_code 156턴, 다른 레인 53턴. 바뀐 3번 모두 사이에 다른 레인 턴이 있었다.
  - analyst: 84턴 / 70턴. 13번 중 8번이 그랬고, 5번은 ±1 이다.
  - jazz-developer: 79턴 / 51턴. 19번 중 6번이 그랬고, 13번은 ±1 이다.
- ±1 은 고정으로 붙는 System 메시지가 있고 없고의 차이다. Claude Code 턴이 남긴 대화는 없다.

같은 씨앗으로 연 새 세션 (keeper cwd, 첫 masc 프롬프트 글자 수가 같은 것):

| 씨앗 (글자) | 새 세션 수 | 첫 세션 ~ 마지막 세션 (UTC) | 세션별 요청 수 |
|---|---|---|---|
| 185,787 | 13 | 04:07:54 ~ 11:09:30 | 66, 4, 1, 11, 7, 1, 39, 20, 9, 5, 44, 58, 50 |
| 256,513 | 6 | 05:44:07 ~ 09:38:41 | 3, 1, 6, 5, 55, 124 |
| 134,417 | 6 | 08:21:10 ~ 10:32:10 | 16, 86, 92, 26, 65, 12 |

- 같은 크기의 씨앗은 SHA-256 까지 같았다.
- 185,787자 세션 두 개(05:47:33, 05:53:09)의 첫 요청(246,996, 250,908 토큰)은 edgar.a.poe 턴 2773, 2776 레코드의 `input_tokens` 와 같다. 256,513자 세션(05:47:24)의 첫 요청 313,439 토큰은 critic 턴 2208 과 같다. 세 세션 모두 요청이 1번뿐이라 #36725 전의 합산 기록도 요청 하나의 값이다.
- 185,787자 씨앗으로는 7시간 동안 새 세션 13개가 열렸고, 그 세션들의 요청은 모두 315번이다.

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

> --system-prompt-snapshot <on|off>  Record the system prompt once per conversation and reuse it verbatim on every request and resume. on (the default): the prompt is rendered on the conversation's first request — a --system-prompt or --append-system-prompt included — sent, and recorded; every later request and resume sends the record as-is, even when a later launch passes different text, until the conversation is compacted. off: never record; the prompt is rendered fresh every request (for iterating on prompt text). No effect where system-prompt recording is not yet enabled.

- 공식 문서(code.claude.com/docs/en/cli-reference, "System prompt flags in resumed conversations")도 같다.
- 조건이 있다.
  - 기본값 `on` 은 2.1.265 부터다. 그 전에는 시스템 프롬프트 플래그를 주면 기록이 꺼졌다.
  - bare mode 는 기록하지 않는다. feature flag 를 받지 않는 공급자(Bedrock, Agent Platform, Foundry)는 2.1.268 전까지 기록하지 않았다.
  - 요약하면 그때부터 마지막으로 띄운 프로세스의 시스템 프롬프트가 쓰인다(§2.6).
- masc 는 `--system-prompt-snapshot` 을 넘기지 않고(`runtime_claude_code.ml:1296-1349`) CLI 버전도 고정하지 않는다. 그래서 이 동작은 설치된 CLI 버전과 공급자가 정한다.

**버전별 실측.** resume 턴 첫 요청에서 캐시에 새로 쓴 비율이다. 표본은 2026-09-05~09-11 에 수정된 transcript 이고, 턴 버전은 그 턴 user 항목의 `version` 이다.

| Claude Code | masc 세션에서 본 기간 (UTC) | resume 턴 | 새로 쓴 비율 중앙값 | 절반 넘게 새로 쓴 턴 |
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
- 이어가기 턴에만 붙는 historical task reference 도 System 메시지다(`keeper_official_task_reference.ml:24`). 이어가기 턴은 항상 resume 이므로 2.1.265 뒤로 한 번도 전달되지 않았다.

### 2.5 기록이 틀렸다

- 턴 레코드 입력 구성: `report_transmitted_input` 이 resume 에도 `Whole_input_transmitted prepared.messages` 를 보고한다(`keeper_claude_code_runtime.ml:594-598`).
  - `Keeper_official_client_host` 계약(`keeper_official_client_host.mli:30-37`)과 이 레인의 계약(`keeper_claude_code_runtime.mli:84-89`)은 resume 을 `Held_by_client_session` 으로 정한다.
  - 2026-09-14 #36035 가 두 계약과 다르게 바꿨다. #36688 이 본 "turn 4484~4550 동안 똑같은 composition" 이 그 결과다.
- 세션 저장소: code-reviewer `official-client-runtime/session.json` 에 `context_frontier.delivery = "replaced_configuration"`, `message_count = 86` 이 남았다(2026-09-15 16:33Z).
- #38075 부터 Claude Code resume 은 `context_frontier.delivery = "held_by_vendor_session"` 을 남기고, 입력 보고는 `Held_by_client_session` 이다. 턴 컨텍스트, working state, historical task reference 는 resume 사용자 프롬프트 앞에 실리고(`Keeper_official_client_host.resume_prompt`), 대화 스냅샷은 보내지 않는다.
- Codex 레인도 같은 구조다(`keeper_codex_runtime.ml:662-725`). `thread/resume` 에서 새 `developerInstructions` 를 쓰는지는 확인하지 않았다.
- Antigravity 레인은 resume 을 `Held_by_client_session` 으로 보고한다(`keeper_antigravity_runtime.ml:531-535`).

### 2.6 Claude Code 가 keeper 대화를 요약했다

- 2026-09-15T12:40:44Z, 세션 `01a0a4c1-7858…`: `trigger = auto`, `preTokens = 967,790`, `postTokens = 5,133`.
- 바로 다음 요청은 296,010 토큰이었다. cache_read 50,210, cache_creation 245,798.
  - 요약본은 5,133 토큰이다. 문서대로라면 나머지는 도구 층과, 요약 뒤부터 쓰이는 마지막 resume 프로세스의 시스템 프롬프트(스냅샷 포함)다.
- 공식 문서(code.claude.com/docs/en/model-config, "Default auto-compact thresholds"): 1M 창으로 도는 Sonnet 5 는 "compact before the window fills, at about 967K tokens by default".
- masc 에는 요약이 없다(RFC-keeper-context-window-in-tokens §1.3). 이 레인에서는 공급자가 요약하고, masc 는 그 사실을 기록하지 않는다.

### 2.7 세션은 왜 버려지나

- 공급자 거절은 복구 불가로 분류되고, 다음 claim 이 자동으로 새 세션을 연다.
  - `Quota_blocked`·`Turn_failed`·`Turn_failed_with_observation`·`Subscription_required` → `Provider_rejected` (`keeper_claude_code_runtime.ml:340-344`)
  - `Provider_rejected -> Fatal` (`keeper_official_client_session_store.ml:57`)
  - `plan_claim` 은 `Input_rejected` 가 아닌 `Recovery_required` 를 새 세션으로 넘긴다(`:868`, `Ok (None, 1, None)`).
- 서버 로그 (2026-09-15 00:00Z~16:30Z)
  - `Claude Code turn composition` 줄: `mode=start` 115, `mode=resume` 706
  - `auto-superseded official-client recovery=… failure=provider_rejected`: 78
  - 새 세션 115개 중 48개가 같은 keeper 의 승계 30초 안에 열렸다
  - `Claude Code turn failed (kind=quota_blocked): … api_status=429 tool_effect_attempted=false response_emitted=false`: 38
- 즉 아무 효과도 없던 429 하나가 keeper 작업의 유일한 사본을 버리고, 중앙값 254,749 토큰짜리 씨앗을 한도가 찬 상태에서 다시 보낸다.
- 도구 표면도 흔들린다. 새 세션을 열 때 기록된 도구 수다.
  - critic 142·144·145·147·149·153 · edgar.a.poe 200·202·203·205·207·211 · analyst 188·189·197 · goo-yang-bong·kidsnote-slack-context-collector·jazz-developer 144·145·153
  - 도구 표면 digest 가 바뀌면 세션은 이어 쓸 수 없다(`reconcile_tool_surface`). MCP 도구 목록은 세션 중간에 바꿀 수 없다.
- 서버 재기동 때 턴이 걸려 있던 세션도 같은 경로로 간다(`Process_restarted -> Ambiguous`, `reconcile_process_restart`).

## 3. 현재 동작

- **세션을 새로 여는 때** (`keeper_claude_code_runtime.ml:519-524`, `keeper_official_client_session_store.ml:810-869`): 저장 상태가 없거나 `ready` 일 때, `client_kind`·`runtime_id` 가 바뀌었을 때, 도구 표면 digest 가 바뀌었을 때, 복구가 승계되거나 새 시작을 고른 때. 그 밖에는 저장된 settlement 로 resume 한다.
- **새 세션의 이력 씨앗** (`:1193-1213`): 체크포인트 이력을 `min(max-prompt-bytes, max-request-body-bytes)` 바이트로 자른다. 라이브 설정은 둘 다 524,288 이다. 고정으로 붙는 맥락이 먼저 이 용량을 쓰고, 남은 자리를 60 atom 단위로 자른다(`runtime_model_input_tail_window.ml`).
- **resume 턴** (`:579-613`, `runtime_claude_code.ml:1329-1331`): 프롬프트는 goal 한 줄이고 `--resume=<id>` 로 띄운다.
- **usage** (`runtime_claude_code.ml:98-118`): 턴 레코드는 가장 최근 요청의 usage 를 `per_request` 로 적는다(#36725).
- **원래 세션이 필요한 이어가기**
  - Gate 이어가기(`validate_continuation`, `keeper_official_client_session_store.mli:184-188`)
    - 그 원래 세션이 가득 차서 resume 이 거절되면, 세션은 `Vendor_session_full` 로 기록되고 거절 전에 응답·도구 실행이 있었는지도 남는다(Codex 는 도구 실행 뒤일 때만). Gate operation 은 `Gate_session_full` 원인으로 실패하고, 다음 일반 턴은 새 세션을 연다(`Keeper_direct_gate_continuation.session_full`, #38086).
  - direct checkpoint 이어가기(`keeper_direct_checkpoint_continuation.ml:18-27`). 사이에 끼인 steering 턴도 같은 세션에서 돌아야 한다.
  - `Retry_previous` 복구는 대화를 그대로 잇는 것이 계약이다(`keeper_official_client_session_store.ml:1219-1224`).
- **Codex** (`keeper_codex_runtime.ml:591-595`): resume 규칙이 같다. usage 는 `tokenUsage.last` 다.
- **Antigravity** (`Keeper_antigravity_runtime.run`): resume 규칙이 같다. canonical 원본(시스템 프롬프트나 공유 기록)이 settle 때와 달라지거나, settle 때의 원본 기록이 없어 같은지 알 수 없으면 그 세션을 이어 쓰지 않고 새 세션을 연다(`Keeper_official_client_session_store.reconcile_context`). 도구 목록이 바뀌었을 때와 같은 처리다. 옛 vendor 세션 안에만 있던 대화는 새 세션으로 넘어가지 않는다. 예외: Gate 이어가기는 원래 세션에 묶여 있어서(완료 판정이 같은 세션의 다음 settle 을 요구한다) 새 세션을 열지 않고 dispatch 전에 거절한다. usage 는 `conversation_cumulative` 다.

## 4. 결함

1. **masc 가 이 레인의 대화를 갖고 있지 않다.** 세션을 새로 열면 keeper 는 이전 세션에서 한 일을 잃는다. 크기 문제도 여기서 나온다(§2.3).
2. **효과 없는 거절과 도구 표면 흔들림이 그 세션을 자주 버린다.** 하루 새 세션 115개 중 48개가 429 뒤였다(§2.7).
3. **resume 턴에 System 맥락이 가지 않는다.** 2026-09-08 20:46Z 부터다. operator note 와 이어가기용 task reference 는 전달 없이 소비되거나 사라진다(§2.4).
4. **창이 요청 크기를 정하지 않는다.** 세션은 요약 지점까지 자라고, 요약되면 masc 모르게 대화가 5,133 토큰으로 바뀐다(§2.2, §2.6).
5. **새 세션 씨앗을 바이트로 자른다.** RFC-keeper-context-window-in-tokens §4 4번과 같다.
6. **전송 기록이 틀렸다**(§2.5).

## 5. 결정

### 5.1 효과가 없는 공급자 거절은 세션을 버리지 않는다

- 도구 효과도 응답도 없던 거절(`tool_effect_attempted = false && response_emitted = false`)은 공급자 쪽 사정이지 이 대화의 문제가 아니다. 세션은 거절 전과 똑같다.
- 그런 거절은 `Transient` 와 같은 자리로 보내 previous settlement 를 되살린다(`release_transient` 경로). 다음 턴은 같은 세션을 이어 쓴다.
- 효과가 관측된 거절은 지금처럼 복구로 남긴다. 다만 복구를 새 세션으로 승계하는 자리(`plan_claim:868`)는 5.6 전까지 "유일한 사본을 버리는 선택"이라는 사실을 로그에 남긴다.
- 429 는 한도 문제이므로, 되살린 뒤 언제 다시 도는지는 기존 quota 경로가 정한다. 이 RFC 는 재시도 간격을 만들지 않는다.

### 5.2 도구 표면이 흔들리는 원인을 멈춘다

- 하루에 keeper 마다 도구 수가 여섯 가지였다(§2.7). 바뀔 때마다 세션을 새로 열어야 한다.
- 무엇이 목록을 바꾸는지부터 찾는다(레인 부착, composition/skill, 브라우저·음성 도구 등).
- 세션을 이어 쓰는 값어치는 도구 표면이 조용한 만큼만 나온다.

### 5.3 전송 기록을 사실대로 적는다

- resume 은 보낸 것만 적는다. 이 턴의 System 메시지는 보냈고, 이력은 공급자 세션이 쥐고 있다. `transmitted_model_input` 에 이 경우를 뜻하는 생성자를 더한다. 쓰는 곳은 `keeper_agent_run.ml:1324-1333` 하나다.
- resume 시스템 프롬프트에 canonical 스냅샷을 넣지 않는다. 지금은 전달되지 않고, 전달되는 설정(§5.4)에서는 이력이 두 번 들어간다.
  - 스냅샷은 masc 체크포인트 이력이다. 여기에는 다른 레인에서 돈 턴도 들어 있다. 그 전달은 5.6 이 맡는다.
- resume 은 `context_frontier` 의 스냅샷 값을 저장된 값 그대로 넘긴다. `acknowledged_turn` 은 지금처럼 claim 이 비우고 settle 이 채운다(`keeper_official_client_session_store.ml:941-942, 1074-1077`).

### 5.4 턴 맥락 전달 (운영자 결정)

- 모든 Claude Code 실행에 `--system-prompt-snapshot off` 를 넘긴다. 그러면 요청마다 그 실행의 시스템 프롬프트가 쓰인다. CLI 버전과 공급자 기본값에 맡기지 않는다.
- 켜면: keeper 가 그 턴의 memory recall·dynamic context·operator note 를 받는다.
- 대가: resume 턴 첫 요청이 세션의 대부분을 다시 쓴다. 2.1.263 까지 중앙값 0.863 이었다(§2.4). 지금 세션 크기(중앙값 374,876 토큰)에서는 그만큼 커진다.
- 이 대가는 §5.5 로 고정부를 줄이고 §5.7 로 세션 크기를 묶으면 작아진다. 언제 켤지는 운영자가 정한다.

### 5.5 고정부 예산 (결정 필요)

- 이력보다 먼저 들어가는 부분이 이미 창보다 크다.
  - MCP 도구 스키마: geek-scout 과 msx-retro-mania 의 새 세션 첫 요청이 똑같이 50,210 토큰을 캐시에서 읽었다. 두 세션의 도구 표면은 145개·128,968 B 로 같았다. edgar.a.poe 는 200~211개를 싣는다.
  - pinned 맥락: memory recall 71,892~210,909 B, dynamic context 1,953~41,858 B (§2.4)
  - `W` 는 85,000 토큰이다.
- 선택지는 둘이다. 고정부를 줄이거나(도구 수와 스키마 크기, memory recall 상한 #36687, 브리핑 예산 #36716), `W` 를 올리거나.
- 정하지 않으면 §5.7 의 씨앗은 매 턴 floor 가 된다. 그러면 세션을 새로 여는 것이 이력을 거의 버리는 일이 된다.
- 재는 자리는 이미 있다. #36757 의 `GET /api/v1/keepers/:name/next-request` 가 `reserved_bytes`(도구 스키마 + keeper 지시)와 `pinned_bytes` 를 창·용량과 함께 낸다. 2026-09-16 01:5x KST 라이브 서버는 아직 이 배포 전이라 404 였다. 공식 클라이언트 레인 후보도 내도록 넓혀야 한다.

### 5.6 공식 클라이언트 턴의 대화를 keeper 체크포인트에 남긴다

| | |
|---|---|
| 남기는 것 | 턴의 user 메시지, assistant 텍스트와 도구 호출, 도구 결과, 마지막 응답. 턴 안의 순서 그대로 |
| 만드는 곳 | 공급자 스트림 프레임. assistant 프레임의 `message.id` 와 `tool_use` id, 그리고 tool_result 프레임이 짝을 정한다 |
| 두는 곳 | keeper 체크포인트 메시지. Agent Core 레인과 같은 이력 원천이다 |
| 쓰는 곳 | 다음 새 세션 씨앗, librarian 입력(지금은 마지막 메시지 하나) |

- `keeper_agent_run_finalize_response.ml:233-240` 의 소유 규칙이 바뀐다. 공식 클라이언트 턴도 체크포인트를 쓴다.
- 먼저 풀어야 할 것(§8): 지금 masc 안쪽 이벤트에는 assistant message id 도, 도구 결과도 없다. MCP 다리는 호출 id 를 다시 매긴다. 병렬 도구 호출이 흔해서 순서로 짝을 맞추면 틀린다. thinking 블록은 서명만 있고 본문이 없다.
- 쓰는 주체와 `turn_count` 주인도 정해야 한다. 체크포인트 저장소는 턴 번호가 낮은 쓰기를 조용히 건너뛴다. 같은 체크포인트를 Agent Core 단계 저장과 실패 턴 기록, purge 도 쓴다.
- 이 기록이 있어야 다른 런타임이 대신 돈 턴, direct 채팅, 복구 뒤 새 세션이 같은 대화를 본다. #36035 가 스냅샷으로 풀려던 문제도 여기서 풀린다.
- 체크포인트 쓰기 비용이 커진다. 지금 Agent Core 레인 체크포인트는 도구 라운드마다 전체를 다시 쓴다.

### 5.7 씨앗을 토큰으로 자르고, 매 턴 새 세션을 연다

- 2026-09-20: 자리 씨앗은 먼저 들어갔다. Antigravity 와 Claude Code 의 새 세션 씨앗은 이제 RFC-keeper-context-window-in-tokens §10.4 의 앞머리에서 시작한다(`Keeper_official_client_host.carried_start_range`). 토큰으로 자르는 아래 설계는 그대로 남은 일이다.
- 이력 용량은 `W` 에서 고정부를 뺀 값이다(RFC-keeper-context-window-in-tokens §10.3). 이 레인은 보내기 전에 토큰을 셀 수 없으므로, 보낸 뒤 공급자 수치로 다음 씨앗을 고친다. 관측이 없으면 가장 새 atom 만 보낸다.
- 세션 정책

| 상태 | 이번 턴 |
|---|---|
| Gate 이어가기가 settled 세션에 묶여 있음 | 그 세션을 resume 한다 |
| direct checkpoint 이어가기가 묶여 있음. 그 사이의 steering 턴도 같다 | 그 세션을 resume 한다 |
| `Retry_previous` 로 되살린 세션 | 그 세션을 resume 한다 |
| 그 밖 | 새 세션. 씨앗은 창으로 고른다 |

- 요청 하나의 크기는 `씨앗 + 그 턴의 증가` 다. 한 턴 안의 증가는 중앙값 4,829, p90 29,623, 최대 188,116 토큰이었다(§2.2).
- "직전 요청이 W 이하일 때만 resume" 은 고르지 않았다. 씨앗을 W 에 맞춰 채우면 첫 턴에 도구를 몇 번만 써도 W 를 넘어 결국 거의 매 턴 새 세션이 된다. 여유를 두려면 그 크기가 계수가 된다. 새로 저장할 값과 전이 규칙, 저장 형식 hard cut 도 따라온다.
- 판정 입력(묶인 이어가기가 있는가)은 `plan_claim` 과 `claim_with_context_frontier` 가 똑같이 받는다. 지금 claim 은 계획을 다시 세운다(`:944-945`).
- 여기까지 오면 `DISABLE_COMPACT=1` 을 넘긴다. 창을 넘으면 공급자 요약 대신 typed `Context_window_exceeded` 로 간다.
  - 그 전에는 켜지 않는다. 도구를 쓴 뒤 넘치면 `Input_rejected Effect_fenced` 가 되고, 이 복구는 운영자가 풀기 전까지 claim 을 막는다(`:838-852`). 대화가 체크포인트에 없는 동안에는 `Restart_fresh` 가 그 일을 전부 버린다.
  - 이 값은 CLI env 허용 목록에 없다(`runtime_claude_code.ml:348-390`). masc 가 넣어야 한다.
- Antigravity 는 이 규칙에서 뺀다. 요청별 토큰이 없고 canonical 원본 guard 가 따로 있다(§8).

## 6. 고르지 않은 것

| 안 | 고르지 않은 이유 |
|---|---|
| 지금대로 둔다 | 결함 1~6 이 그대로다 |
| 직전 요청이 W 이하일 때만 resume | §5.7. 여유 크기가 계수가 되고, 결국 매 턴 새 세션에 가깝다 |
| Claude Code 요약 창을 W 로 (`--autocompact`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`) | LLM 요약이다(RFC-keeper-context-window-in-tokens §1.3). §2.6 에서 967,790 토큰이 5,133 토큰이 됐고 masc 는 무엇이 남았는지 모른다. 문서상 창 하한도 100,000 토큰이다 |
| `--system-prompt-snapshot off` 만 켠다 | 턴 맥락은 간다. 세션은 계속 자라고, 새 세션 때 일을 잃는 것도 그대로다 |
| 턴 맥락을 user 메시지로 보낸다 (Antigravity 방식) | transcript 에 턴마다 쌓인다. memory recall 만 턴마다 71,892~210,909 B 다 |
| 체크포인트 대신 공급자 transcript 를 읽어 씨앗을 만든다 | 공급자 파일 형식에 기대고, 공급자가 요약하면 원문이 없다 |
| 모델 창(1M) 기준으로 새 세션 (#36688 제안 3) | 운영자는 전송 창을 `W` 로 정했다 |
| 턴당 요청 수 상한 (`--max-turns`) | 크기가 아니라 keeper 의 일을 자른다 |

## 7. RFC-keeper-context-window-in-tokens §7 대조

| §7 | 이 RFC 에서 |
|---|---|
| 1. 창은 토큰으로 선언한다 | `W` 하나를 쓴다 |
| 2. 본문 상한은 판정에만 쓴다 | 원칙 유지. 예외: Antigravity 는 typed overflow 가 없어 선언된 `max-prompt-bytes` 안에서 fresh-session 씨앗을 임시로 자른다. 미선언은 거절한다. 대체: agy usage `input_tokens` 로 만든 토큰 창과 "trajectory cleared" 의 typed 분류 (#37123) |
| 5. 앞부분 흔들림을 재고 그 이상 늘리지 않는다 | 매 턴 새 세션은 고정부와 씨앗을 매번 다시 쓴다. 지금 resume 턴의 재기록 비율은 0.001 이다. §11 에서 잰다 |
| 6. 도구 호출과 결과는 같이 남거나 같이 빠진다 | §5.6 이 짝을 id 로 남긴다. 씨앗 자르기는 지금 규칙 그대로다 |
| 7. 요약하지 않는다 | §5.7 뒤에 `DISABLE_COMPACT=1`. 대화 원문은 체크포인트에 있다 |
| 8. 계수를 박지 않는다 | 씨앗은 공급자 수치로 고친다. 관측이 없으면 floor |
| 9. 모델 창을 넘는 창은 없다 | `W ≤ max-context` 검사를 이 레인 후보에도 적용한다 |
| 10. 운영자가 설정만 보고 안다 | 세션을 새로 연 이유와 이어 쓴 이유를 턴마다 로그 한 줄로 남긴다 |

## 8. 열린 질문

1. **고정부 예산(§5.5).** 줄일지, `W` 를 올릴지. 줄인다면 도구 수·스키마 크기·memory recall 중 무엇부터인지.
2. **턴을 어떻게 남기나(§5.6).** 스트림 프레임에서 assistant message id·`tool_use` id·tool_result 를 masc 안쪽까지 가져오는 길, 병렬 호출 짝, thinking 서명, native 도구를 켠 keeper 의 결과, 실패·중단 턴의 마감.
3. **체크포인트 소유.** 쓰는 주체와 `turn_count` 주인, Agent Core 단계 저장·실패 기록·purge 와의 순서. 반복 스냅샷과 판정 쌍은 누가 갖나.
4. **bootstrap 에피소드 동일성.** RFC-claude-code-context-overflow-bounded-restart 는 durable 이력 전체로 에피소드를 식별한다. §5.6 뒤에는 그 이력이 턴마다 바뀐다.
5. **Codex.** `thread/resume` 의 `developerInstructions` 적용 여부. `tokenUsage.last` 가 요청 단위인지 턴 단위인지.
6. **Antigravity.** 요청별 토큰이 없다. 같은 정책으로 갈지, 지금의 guard 로 둘지. (canonical 원본이 바뀐 뒤의 처리는 정했다: 새 세션. 2026-09-23 운영자 결정)
7. **§2.2 13:16:42 처럼 resume 턴이 캐시를 전혀 못 읽는 원인.**
8. **실패한 Agent Core 턴 다음의 Claude Code 턴이 `keeper_instructions` 만 기록한 이유**(analyst 3987·4004·4009·4012·4029·4033·4057).

## 9. 범위 밖

- keeper cwd 가 아닌 masc 호출 59개(§2.1). 같은 구간에 요청 679번, cache_read 113,622,520 토큰이다.
- memory recall·브리핑 크기 자체. #36687 과 #36716 이 다룬다.

## 10. 이행

| 단계 | 내용 | 먼저 필요한 것 | 비용 변화 |
|---|---|---|---|
| 1 | 효과 없는 거절은 세션을 지킨다(§5.1) | 없음 | 새 세션과 씨앗 재전송이 준다 |
| 2 | 도구 표면 흔들림 원인 제거(§5.2) | 원인 조사 | 같다 |
| 3 | 전송 기록 바로잡기(§5.3) | 없음 | 거의 없다 |
| 4 | `--system-prompt-snapshot off`(§5.4) | 운영자 결정 | resume 턴마다 세션 대부분을 다시 쓴다 |
| 5 | 고정부 예산(§5.5) | 운영자 결정 | 요청 크기가 준다 |
| 6 | 턴 대화를 체크포인트에(§5.6) | §8 2·3번 | 체크포인트 쓰기 증가 |
| 7 | 씨앗을 토큰으로, 매 턴 새 세션, `DISABLE_COMPACT`(§5.7) | 5·6단계 | 요청 하나가 `W + 턴 증가` 안으로 |

Antigravity 임시 guard 를 배포하기 전에는 운영 중인 `antigravity-cli` 모델마다
실측한 `max-prompt-bytes`를 명시한다. 저장소 seed는 새 설정에만 들어가며 기존
설정의 모델 행을 덮지 않는다. 선언이 빠진 기존 모델은 조용히 무제한으로
돌아가지 않고 typed `InvalidConfig(max_prompt_bytes)`로 거절된다.

## 11. 배포 후 측정

§2 와 같은 방법으로 잰다.

- 1·2단계 뒤: 하루 새 세션 수와 이유별 수. `auto-superseded … provider_rejected` 뒤 30초 안의 새 세션은 0.
- 3단계 뒤: resume 턴 레코드의 입력 구성이 "세션이 이력을 쥐고 있음"으로 바뀌었는지.
- 4단계 뒤: resume 턴 첫 요청의 새로 쓴 비율. 턴 레코드 블록 digest 가 바뀐 턴에서 캐시가 끊기는지.
- 5단계 뒤: `next-request` 예보의 `reserved_bytes + pinned_bytes` 가 창 안인지. floor 로 잘리는 keeper 수.
- 6단계 뒤: Claude Code 턴마다 `total_atoms` 가 늘어나는지. 같은 씨앗으로 연 새 세션 수는 0.
- 7단계 뒤: 요청 하나의 입력 토큰 중앙값·p90·최대. 최대는 `W + 한 턴 증가 p90` 부근이어야 한다. cache_read ÷ (input + cache_creation). `compact_boundary`(`entrypoint = "masc"`) 수는 0.
