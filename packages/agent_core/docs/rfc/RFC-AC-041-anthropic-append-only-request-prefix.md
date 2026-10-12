# RFC-AC-041: Anthropic 요청의 앞부분은 이어 붙이기만 한다

| | |
|---|---|
| Status | Draft |
| Author | vincent (with Claude analysis) |
| Created | 2026-10-13 |
| Target | `agent_core` — `lib/agent/agent_turn.ml`, `lib/llm_provider/{retry,reasoning_dialect,reasoning_history_projection,backend_anthropic,types}.ml`, 카탈로그(`models.toml`). masc — `lib/keeper/keeper_turn_driver_try_provider.ml`, `lib/runtime/runtime_model_input_tail_window.ml`, `lib/keeper/keeper_carried_front.mli` |
| Related | #42636, #42632, RFC-AC-029 §S3, RFC-AC-040, `docs/rfc/RFC-keeper-context-window-in-tokens.md` §1·§13.4, `docs/rfc/RFC-librarian-lifecycle.md` §4.10 |
| 측정 기준 | `origin/main` `c7fa2a0cec` (2026-10-13). `파일:줄` 은 이 커밋 기준이고 부록 A 의 명령으로 다시 확인한다 |
| 디렉터리 | `packages/agent_core/docs/rfc/`. 이유는 부록 B |

## 0. 요약

- 2026-10-12 06:36Z~15:26Z 에 `claude_vincent.*` 런타임의 Keeper 4개가 같은 400 으로 60번 실패했다. 문구는 `Invalid signature in thinking block. The block is bound to a different conversation.` 이다.
- Anthropic 은 서명이 붙은 thinking 블록을 다시 보낼 때 system, tools, 앞선 messages 가 만들 때와 같아야 받는다. masc 는 요청마다 이 앞부분을 바꾼다.
- 바꾸는 곳은 코드로 확인한 것이 셋이다. (1) 턴별 문맥을 요청 끝에 붙였다가 다음 요청에서 뺀다. (2) 보내는 이력 창의 시작점이 움직인다. (3) 앞부분이 달라졌는데도 이력의 모든 서명 블록을 그대로 다시 보낸다. system·tools 가 턴 사이에 바뀐다는 기록(wire-capture)도 있으나 바꾸는 코드는 아직 못 찾았다(§1.3).
- 같은 400 이 `Unknown_invalid_request` 로 읽히고, `boundary_resend_on` 이 이 값에 true 를 돌려준다. 크기와 상관없는 400 에도 짧은 창으로 한 번 더 보낸다.
- 이 RFC 는 다섯 가지를 정한다. (a) Anthropic 요청의 앞부분은 이어 붙이기만 한다. (b) 턴별 문맥은 턴당 한 번 만들어 이력에 남긴다. (c) system·tools 는 세션 동안 고정하고, 바꿔야 하면 바뀌었다고 기록한다. (d) 서명 블록은 앞부분 지문이 같을 때만 다시 보내고, 아니면 뺀다. (e) 크기 때문이라는 증거가 있는 400 에만 짧은 창으로 다시 보낸다.
- 쓰지 않는 길: `drop_block`, 오류 문구 매칭, 재시도 횟수 제한.
- 작업은 여섯 층의 스택으로 나눈다(§4.3). 층마다 결과 하나다.

## 1. 문제와 근거

### 1.1 증상 (이슈 #42636 본문 기준)

| 사실 | 값 | 확인 방법 |
|---|---|---|
| 실패한 서명 400 | 60건 (polisher 17, ocaml-agent-ic 19, you-never-change 13, e-masc-the-leader 11) | 이슈가 인용한 실패 영수증. 이 RFC 작성 중에는 영수증 원본을 다시 세지 않았다 |
| 시간 범위 | 2026-10-12 06:36Z~15:26Z | 같음 |
| `claude.*` 런타임 | 같은 코드로 thinking 과 도구를 섞은 실행 약 300회, 서명 오류 0 | 같음 |
| vincent 키 | 한 실행의 첫 호출은 통과하고 두 번째 호출에서 거절된다 | 같음 |
| 한 번 실패한 Keeper | 이후 매 턴 첫 요청에서 계속 실패(13연속, 17연속) | 같음 |

확인하지 못한 것:

- 요청 본문이 로그에 없다. 라운드 N 과 N+1 의 실제 바이트를 대조하지 못했다. 아래 원인은 코드 읽기와 오류 문구에서 나온 추정이다.
- vincent 키 계정이 2026-08-31 이후 생성인지 모른다. 공식 문서는 그날 이후 만든 계정에 검사를 기본으로 켠다(§1.2). vincent 만 실패하는 이유가 계정 나이라는 설명은 맞을 수 있으나 확인하지 않았다.
- 같은 코드가 `claude.*` 에서 통과한 이유도 같은 이유로 추정이다. 그쪽 계정이 2026-08-31 이전이면 설명되는데 이것도 확인하지 않았다.

### 1.2 Anthropic 규칙 (공식 문서, 2026-10-13 조회)

읽은 곳은 네 페이지다. 조회 도구가 페이지를 요약해 돌려주는 방식이라, 아래 인용은 그 결과에 들어 있던 원문 인용이다.

- `https://platform.claude.com/docs/build-with-claude/preserved-thinking` (전체 121,909자를 두 번에 나눠 읽었다)
- `https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting` (전체)
- `https://platform.claude.com/docs/en/api/errors` (전체)
- `https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages` (105,261자 중 앞 100,000자. "Limitations" 절은 읽지 못했다)

규칙과 위치:

1. 검사 대상 모델은 Claude Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5 이다. 검사하는 앞부분은 세 가지다. top-level `system`, `tools` 의 집합, 블록 앞의 모든 `message` (preserved-thinking, "Keeping the prefix unchanged"). `effort`, `max_tokens`, `output_config`, `tool_choice`, `metadata`, `cache_control` 은 앞부분이 아니다.
2. 문서의 지침: "Keep `system` and `tools` fixed for the session and treat `messages` as append-only."
3. 앞부분이 다르면 `"error"`(기본값)는 400 `invalid_request_error` 로 거절하고, `"drop_block"` 은 실패한 블록과 그 뒤 thinking 블록을 서버가 버리고 성공시킨다. 버려진 블록은 과금되지 않는다 (같은 페이지, "What the API does with an invalid block").
4. 2026-08-31 00:00 UTC 이후 만든 계정은 검사가 기본이다. 그 전 계정은 요청에 `thinking.block_binding.prefix_mismatch_behavior` 를 넣을 때만 검사한다. 이 필드는 beta 헤더 `thinking-binding-controls-2026-08-01` 이 있어야 한다 (같은 페이지).
5. 시작부터, 끝부터, 전부 thinking 블록을 빼는 것은 유효하다. 중간에서 빼면 뒤 블록이 무효다. 뺀 블록을 다시 넣어도 그 사이에 만든 블록이 무효다 ("What counts as an edit" 표). 문서는 "Earlier thinking blocks aren't in the prefix" 라고 적는다.
6. 오류 본문의 구조는 `{"type":"error","error":{"type","message"},"request_id"}` 이고 "`type` values will grow over time" 이라고 적혀 있다 (errors, "Error shapes"). 서명 400 에 대해 문서는 "That sentence is for people and logs. Its wording can change, so don't match on it in code." 라고 쓴다 (thinking-troubleshooting). 별도 오류 코드 필드는 문서에 없다.
7. 서명 400 이 아닌 400 도 같은 `invalid_request_error` 이다. 조직·워크스페이스 지출 한도에 닿으면 400 을 돌려준다 (errors, "HTTP errors").
8. `drop_block` 의 출력 토큰 증가는 표가 아니라 본문 문단에 적혀 있다. 다중 턴 코딩 벤치마크에서 첫 턴 이후 매 턴 버리면 low 4.6%, medium 9.7%, high 10.3%, max 67.1% 늘었다. 한 세션에 한 번 버리면 2.5%, 3.9%, 4.5%, 20.1% 였다 (preserved-thinking, "Output-token cost of `drop_block`"). 문서는 "stopgap" 이라 부른다. 원문에 "table" 은 없었으므로 이 RFC 는 표라고 부르지 않는다.
9. 앞부분을 건드리지 않고 정보를 더하는 방법: `role: "system"` 메시지를 이력 중간에 덧붙인다. 이 메시지는 beta 헤더 없이 쓴다. Sonnet 5 에서는 못 쓴다 (mid-conversation-system-messages). 턴 범위 메시지 `clear_at: "next_user_message"` 는 `mid-conversation-system-clear-at-2026-08-21` 가 필요하다. 도구 변경 `tool_addition`·`tool_removal` 은 `inline-tools-2026-09-15` 가 필요하다 (preserved-thinking 의 beta 표).
10. 계정이 다르면: "Thinking blocks that Claude Sonnet 5.5 or Claude Haiku 5.5 produces work only in the account that produced them". 다른 계정이 보내면 서버가 조용히 버린다. 헤더가 있으면 `input_transformations` 에 `organization_binding_mismatch` 로 나온다.

### 1.3 앞부분을 바꾸는 곳

요청 하나가 만들어지는 길은 이렇다. Keeper 가 이력을 정하고, agent_core 가 턴 준비 단계에서 턴별 문맥을 붙이고, 공급자 쪽에서 thinking 재생 규칙을 적용해 본문을 만든다.

**(1) 턴별 문맥이 요청 끝에 붙었다 빠진다.**

- `Agent_turn.prepare_messages` (`packages/agent_core/lib/agent/agent_turn.ml:34-53`)는 `extra_system_context` 가 있으면 `role = User` 메시지 `[system context] …` 를 만들어 `messages @ [ system_msg ]` (같은 파일 52줄)로 끝에 붙인다.
- 이 결과는 `prepare_turn` 의 `effective_messages` 로만 쓰인다. `Pipeline_stage_prepare.prepare_turn_for_agent` (`packages/agent_core/lib/pipeline/pipeline_stage_prepare.ml:148-155`)는 `agent.state.messages` 를 넘기고, 붙인 메시지는 `agent.state.messages` 에 돌려놓지 않는다. 그래서 이력에는 남지 않고 다음 라운드에 새 값으로 다시 붙는다.
- 코드 주석(`agent_turn.ml:38-43`)은 이렇게 한 이유를 "대화 앞부분이 바이트까지 같아야 로컬 LLM 의 KV 캐시가 재사용된다" 로 적는다. 이 판단은 Ollama·llama.cpp 에 대한 것이고 Anthropic 에는 반대로 작용한다.
- 1.1 의 두 오류 문구와 이 설명이 맞아 보인다. 이슈는 "missing from this request" 43건과 "rewritten since it was created, first at messages.0.content.0" 16건(polisher)을 든다. 두 문구의 건수는 영수증에서 다시 세지 않았다.
- 용어집(`docs/spec/00-glossary.md` 의 "Extra System Context")은 이 메시지를 `System` 메시지라고 적는데 코드는 `User` 이다. 이 RFC 는 코드를 따른다.

**(2) 이력 창의 시작점이 움직인다.**

- `Runtime_model_input_tail_window` (`lib/runtime/runtime_model_input_tail_window.ml:4`, `atoms_per_window = 60`)는 남는 이력이 들어갈 때까지 앞에서 60 atom 의 배수만큼 자른다 (같은 파일 340-353줄). 자르면 맨 앞에 합성 메시지 `[context window] Older turns … are omitted` 가 붙는다 (같은 파일 4-14줄).
- 시작점을 어디에 둘지는 `Keeper_carried_front` 가 정한다 (`lib/keeper/keeper_carried_front.mli`). Librarian 이 흡수한 지점이나 마지막에 받아들여진 시작점을 쓴다. 시작점이 한 턴 안에서 자주 움직이는지는 이 조사에서 재지 못했다. 60 atom 단위라 매 라운드 움직이지는 않는 것으로 읽힌다. 움직이는 순간 앞부분의 첫 메시지가 바뀐다.

**(3) 앞부분이 달라졌는데 서명 블록을 그대로 다시 보낸다.**

- Anthropic 쪽 재생 규칙은 `All_assistant_messages` 이다 (`reasoning_dialect.ml:506-531`, 521줄). 이력의 모든 assistant thinking 을 보낸다.
- 서명 블록은 글자 그대로 직렬화한다 (`api_common.ml:364-379`).
- 저장된 블록의 출처 검사는 `Reasoning_source` 가 한다 (`types.ml:341-420`). 비교하는 값은 provider 종류, 엔드포인트(`base_url` + `request_path` 의 해시), 모델 id, 재생 규칙이다. Anthropic 은 `Require_identical_source` 이다 (`reasoning_dialect.ml:635-650`). 앞 내용이 같은지는 보지 않는다. `reasoning_history_projection.ml:204-217`(`replay_selected`)과 254-262줄(`rotation_admits` 호출)이 이 판정을 쓴다.
- 같은 엔드포인트에 키만 다른 런타임(`claude`, `claude_vincent`)은 같은 `Reasoning_source` 로 보인다. 계정이 다른 블록을 걸러 낼 수 없다.

**(4) system 과 tools.**

- 이슈는 polisher 의 wire-capture 에서 system prompt 해시가 `b89d0d67` 에서 `43079d2e` 로, tools 가 52개와 175개 사이로 바뀐 기록을 든다. 이 RFC 는 그 캡처를 다시 열지 않았다.
- 코드에서 확인한 것은 일부다. Anthropic 본문은 `system` 을 top-level 에 한 번 놓는다 (`backend_anthropic.ml:550-567`). 턴 프롬프트는 실행 컨텍스트의 `base_system_prompt` 이다 (`lib/keeper/keeper_run_prompt.ml:92`). 이 값이 턴 사이에 달라지는 경로와, tools 목록이 턴마다 달라지는 경로는 찾지 못했다. 구현 1층이 이것을 특정한다.
- `backend_anthropic.ml:336` 은 `System` 역할 메시지를 `user` 로 내보낸다. `role: "system"` 메시지를 내보내는 길은 지금 없다.

### 1.4 400 처리의 부작용

- `Retry.classify_error` 는 HTTP 400 과 422 를 모두 `InvalidRequest { reason = Unknown_invalid_request }` 로 만든다 (`packages/agent_core/lib/llm_provider/retry.ml:340-341`). 413 은 이미 별도 값 `Request_body_refused_by_provider` 이다 (같은 파일 350줄).
- `boundary_resend_on` (`lib/keeper/keeper_turn_driver_try_provider.ml:2511-2535`)은 `ContextOverflow`, `Request_body_refused_by_provider`, `Unknown_invalid_request` 에 true 를 돌려준다. 같은 파일의 `refusal_evicts` (2323줄)는 앞의 둘에만 true 이다. 둘이 다르게 쓰인 것은 의도다. 주석(2494-2510줄)이 이유를 적는다. 실제로 재 본 크기 거절이 "문장만 있는 400" 으로 온다는 것이다.
- `turn_boundary_resend_sequence` (2564줄 이하)는 true 면 시작점을 턴 경계로 옮겨 한 번 더 보낸다. 다시 보낸 요청이 크기 거절이 아니면 앞서 들고 있던 시작점을 돌려놓는다 (2596줄, `restore_front before`).
- 따라서 이슈가 말하는 "컨텍스트가 조용히 잘린다" 는 다시 보낸 요청이 받아들여졌을 때만 성립한다. 사용 한도 400(이슈 집계 579건)은 다시 보내도 같은 거절이 나므로 코드상으로는 시작점이 돌아오고 요청 한 번이 더 나간다. 서명 400 에서 짧은 창으로 다시 보내면 받아들여지는지는 확인하지 못했다. 로그로 확인한 것이 아니라 코드를 읽은 결과다.
- 이슈의 집계: 사용 한도 400 579건(`claude.*` 세 종류), temperature 400 5건, 크기 초과 3건. 이 숫자도 다시 세지 않았다.
- 크기 때문인지 아닌지는 지금 오류 값에 없다. 문장으로 가르면 문자열 분류기가 된다(RFC-AC-029 §S1, §S8). Anthropic 도 문구로 가르지 말라고 한다(§1.2-6).

### 1.5 확인 상태 요약

| 주장 | 상태 |
|---|---|
| 앞부분 규칙과 `drop_block` 비용 | 공식 문서를 읽음 (2026-10-13) |
| 턴별 문맥이 이력에 남지 않고 끝에 붙는다 | 코드로 확인 |
| 서명 블록을 앞부분 비교 없이 모두 재생한다 | 코드로 확인 |
| 창 시작점이 움직여 맨 앞 메시지가 바뀐다 | 코드로 확인. 움직이는 빈도는 못 쟀다 |
| system·tools 가 턴 사이에 바뀐다 | wire-capture 기록을 이슈에서 인용. 코드 경로 미확인 |
| vincent 계정이 2026-08-31 이후 생성 | 미확인 |
| 서명 400 이 위 원인 때문에 난다 | 추정. 요청 본문 대조 없음 |
| 서명 400 뒤 짧은 창 재전송이 성공한다 | 미확인 |
| 60건·579건·5건·3건 | 이슈의 집계. 이 RFC 에서 재집계하지 않음 |

## 2. 목표와 비목표

### 목표

1. Anthropic 레인에서 앞부분 위반으로 나는 400 을 구성으로 막는다. 막지 못한 400 은 숨기지 않는다.
2. 앞부분이 바뀔 수밖에 없을 때(창 이동, 이력 재작성, 런타임 전환)는 서명 블록을 빼고 보낸다. 빼는 이유를 타입으로 남긴다.
3. 크기 때문이라는 증거 없이는 짧은 창으로 다시 보내지 않는다.
4. 위 세 가지를 라운드 N 과 N+1 의 요청 본문 대조로 테스트한다.

### 비목표

- `drop_block` 을 기본값으로 쓰지 않는다. 문서가 임시방편이라 부르고, 매 턴 버리면 출력 토큰이 최대 67.1% 늘었다(§1.2-8). 조건: Anthropic 자체 벤치마크이고 effort max 의 값이다. 우리 하네스에서 재지 않았다.
- 오류 문구를 읽어 원인을 가르지 않는다.
- 재시도 횟수·쿨다운 같은 상한을 두지 않는다.
- 이 RFC 는 Codex·Gemini·OpenAI 호환 공급자의 재생 규칙을 바꾸지 않는다. 같은 문제가 있는지는 §6 에 질문으로 남긴다.
- 용어집은 고치지 않는다.

## 3. 설계

### 3.1 불변식 (Anthropic 레인)

세션 안에서 연속한 요청 `R_n`, `R_{n+1}` 이 서명 블록을 하나라도 담으면 아래가 성립해야 한다.

- 이어 붙이기만 하는 것: `system` 값, `tools` 값, `messages` 의 `R_n` 길이까지의 항목. thinking·redacted_thinking 블록은 비교에서 뺀다(§1.2-5). 비교는 JSON 값으로 한다. 문서가 "JSON formatting and key order don't matter; the values do" 라고 적는다.
- 바뀌어도 되는 것: `messages` 끝에 덧붙인 항목, `effort`, `max_tokens`, `output_config`, `tool_choice`, `metadata`, `thinking.display`, `cache_control`.
- 앞부분이 바뀐 요청은 그 앞부분에 묶인 서명 블록을 하나도 담지 않는다(§3.4).

이 불변식은 우리가 보내는 JSON 에 대한 것이다. 우리 쪽 값이 같으면 Anthropic 쪽 앞부분도 같다. 반대는 성립하지 않는다. 우리 쪽이 같아도 계정이 다르거나 서버가 다르게 읽으면 거절될 수 있다. 그 경우를 §3.5 가 다룬다.

### 3.2 턴별 문맥을 어디에 두는가

선택지 넷을 비교한다. 이 비교의 기준은 앞부분을 건드리는지, 토큰이 얼마나 드는지, 필요한 beta 와 모델 제약이다.

| | 방법 | 앞부분 | 토큰 비용 | beta·모델 제약 |
|---|---|---|---|---|
| A | 턴이 시작될 때 한 번 만들어 이력에 그대로 남긴다. 요청에는 지금처럼 `User` 메시지로 나간다 | 유지 | 턴마다 문맥 크기만큼 이력이 자란다. 캐시된 앞부분은 읽기 가격이다 | 없다 |
| B | `role: "system"` 메시지에 `clear_at: "next_user_message"` 를 달아 이력에 남긴다 | 유지 (문서의 표: "A cleared turn-scoped system message left in place" 는 유효) | 문서는 정리된 메시지가 입력 토큰을 쓰지 않는다고 적는다 | `mid-conversation-system-clear-at-2026-08-21`. Sonnet 5 는 못 씀. 와이어에 `role: "system"` 을 내보내야 한다(§1.3-4). "Limitations" 절을 읽지 못했다 |
| C | 그냥 `role: "system"` 메시지를 남긴다 | 유지 | A 와 같다 | beta 없음. Sonnet 5 는 못 씀 |
| D | 새 user 메시지에 text 블록으로 합친다 | 유지 | A 와 같다 | 없다. 문서가 "Put changing context in the newest turn" 으로 권한다 |

추천은 A 다.

- 이유: beta 와 모델 제약이 없고, 기존 코드가 이미 이 문맥을 `User` 메시지로 내보낸다. 와이어와 카탈로그를 바꾸지 않고도 앞부분 불변식이 선다.
- D 를 고르지 않는 이유: 문맥이 사용자 메시지에 섞이면 `Extra_system_context_provenance` 로 문맥만 가려내는 지금의 코드(`runtime_model_input_tail_window.ml` 의 `is_extra_context`, `reasoning_history_projection.ml` 의 `find_latest_user_message_index`)가 깨진다.
- C 를 고르지 않는 이유: 이 문맥은 Keeper hook 이 조립한 자료다. 운영자 권한의 지시 표면에 올려도 되는지 정해지지 않았다(§6 Q3). 문서도 신뢰할 수 없는 텍스트는 user 턴에 두라고 한다.
- B 는 나중에 측정해서 고른다. 토큰 비용이 문제가 될 때만 이점이 있다. 첫 구현은 A 만 만든다. B 의 변형을 지금 타입에 선언하지 않는다. 쓰이지 않는 갈래가 되기 때문이다.

A 의 비용:

- 턴마다 문맥이 이력에 쌓인다. 문맥 크기는 턴 기록의 `extra_system_context_injected_size` 에 남아 있으나 이 RFC 는 값을 재지 않았다. 쌓이는 양 = 문맥 크기 × 턴 수이므로, 이 값은 구현 3층 전에 재야 한다(§7).
- 지금 문맥은 고정(pinned)이라 어떤 자르기도 지우지 않고 요청당 하나다. A 이후에는 지난 턴 문맥이 보통 이력 atom 이 되어 자르기에 지워지고, 요청에는 문맥이 여러 개 있다. 용어집의 "요청 하나에 carrier 가 하나" 전제와 `prompt_context_carrier_repeated` 입력 귀속 검사가 바뀐다. 이 두 곳을 같은 층에서 고친다.
- 한 턴 안의 도구 라운드에서는 문맥을 다시 만들지 않는다. 같은 턴의 시각·도구 수는 턴 시작 값으로 굳는다. 라운드마다 최신 값이 필요한 항목이 있는지는 §6 Q4 다.
- 이력에 남은 문맥은 만든 뒤 바이트까지 그대로 보낸다. 다시 렌더하지 않는다. 문서의 표에서 "Re-render the context you put in the first user message with a changed value" 는 모든 서명 블록을 무효로 만든다.

### 3.3 system 과 tools 는 세션 동안 고정한다

- 세션은 (Keeper, 런타임, 계정 라벨) 한 줄기를 뜻한다. 그 줄기의 첫 Anthropic 요청에서 `system` 과 `tools` 값을 지문으로 남기고, 이후 요청은 같은 값을 쓴다. 지문의 정의는 §3.4 다.
- `system` 이 바뀌어야 하면 바꾸지 않는다. 새 지시는 이력 끝에 메시지로 덧붙인다. 문서도 그렇게 권한다(§1.2-9).
- `tools` 가 바뀌어야 하면 두 길이 있다.
  - 첫 구현: 앞부분 끊김으로 기록한다. 타입 있는 `Prefix_break` 사유를 남기고 서명 블록을 뺀다. 줄기의 지문을 새로 시작한다. 캐시도 이 지점에서 다시 시작한다. 조용히 바뀌지 않는다는 점이 핵심이다.
  - 나중: 처음에 도구 전체를 `defer_loading: true` 로 선언하고 `tool_addition`·`tool_removal` 로 켜고 끈다. beta `inline-tools-2026-09-15` 가 필요하다. 도구 목록이 52개와 175개 사이로 오간다는 기록(§1.3-4)이 이 길이 필요한지 가늠하는 근거다. 이 RFC 는 이 길을 설계하지 않는다(§6 Q2).
- 요청 구성이 `system`·`tools` 를 세션 값과 다르게 만들려 하면 단위 테스트가 실패한다. 이유를 문서가 아닌 코드로 강제한다.

### 3.4 서명 블록 재생 규칙 (타입으로)

앞부분 지문:

- 요청 본문의 `system`, `tools`, 그리고 서명 블록 앞의 `messages`(thinking·redacted_thinking 블록은 뺌)를 JSON 정규형으로 직렬화해 SHA-256 을 낸다. 메시지 단위로 이어 쌓는 지문(`fp_{i+1} = H(fp_i ‖ message_i)`)이면 서명 블록마다 그 앞까지의 값을 하나씩 갖는다.
- 정규형은 객체 키 순서를 정렬하고, 공백을 정하지 않는다(문서: 값만 본다). 우리가 보낸 JSON 을 정규화한다. 직렬화 코드가 바뀌면(예: `Utf8_sanitize` 변경) 지문도 바뀌어, 구버전이 만든 블록은 뺀다. 안전한 방향이다.

저장:

- `Reasoning_source` (`types.ml:341-`)에 묶음 방식 필드를 더한다. 지금은 `provider_kind`, `provider_instance`, `canonical_model_id`, `replay_contract` 네 개다. `of_json` 은 필드가 정확히 네 개일 때만 받는다(`List.length fields = 4`).

```
type binding =
  | Self_contained                       (* 문장 그대로 쓸 수 있는 추론 글 *)
  | Prefix_bound of Prefix_fingerprint.t (* 만든 요청의 앞부분에 묶인 서명 블록 *)

(* Reasoning_source.t 에 binding 과 credential_scope 를 더한다 *)
```

- `credential_scope` 는 계정을 가르는 라벨이다. 같은 엔드포인트에 키만 다른 `claude`, `claude_vincent` 를 구별하려고 둔다(§1.3-3). 값은 키 자체가 아니고 설정에서 정해진 런타임 프로필의 안정된 이름으로 한다. 같은 계정에 라벨이 둘이면 보수적으로 빼게 된다. 어떤 라벨을 쓸지는 `Provider_config` 에서 안정된 것을 골라야 하고, 이 RFC 는 거기까지 읽지 못했다.
- 키를 바꿔도 라벨이 같으면 계속 쓴다. 키 교체가 계정 교체와 같은지는 라벨로 알 수 없다(§6 Q5).

카탈로그가 선언한다 (RFC-AC-040 의 소유권):

- 모델 행이 `thinking_binding = Prefix_bound | Not_prefix_bound` 를 적는다. 문서가 확인한 네 모델(§1.2-1)은 `Prefix_bound` 이다. 나머지 Anthropic 와이어 행은 적어야 한다. 적지 않은 행은 로드 오류다(RFC-AC-040 의 "아무도 적지 않은 사실은 unknown", RFC-AC-029 §S1.4 의 "fail closed"). 문서에서 확인하지 못한 모델의 값을 이 RFC 가 정하지 않는다.
- `replay_policy` 에 정해진 한 가지만 두지 않는다. Anthropic 의 `All_assistant_messages` 는 그대로 두고, 그 위에 앞부분 판정을 둔다. 판정은 닫힌 값이다.

```
type signed_thinking_disposition =
  | Replay of Prefix_fingerprint.t
  | Omit_prefix_changed of prefix_change
  | Omit_binding_absent
  | Omit_source_changed of Reasoning_source.t

type prefix_change =
  | System_changed
  | Tools_changed
  | History_front_moved
  | History_rewritten of { first_index : int }
  | Context_carrier_changed
```

- `reasoning_history_projection.project` 는 이 값을 `match` 로 다룬다. `_ ->` 갈래를 두지 않는다. 새 갈래가 생기면 컴파일이 깨진다. 지금 있는 `replay_drop_reason` (`Incompatible_reasoning_source`, `Missing_reasoning_source`, `Replay_policy_excluded`, `Reasoning_on_non_assistant`)에 `Prefix_not_preserved of prefix_change` 를 더하는 방향이다.
- 재생하는 것은 지금 보내려는 앞부분의 지문이 저장된 지문과 같은 서명 블록뿐이다. 같지 않으면 그 블록과 그 뒤의 서명 블록을 뺀다. 빼는 것은 문서가 유효하다고 적은 방식이다(§1.2-5).
- 한 번 뺀 블록이 다시 들어오지 않는 이유(추론): 블록이 안 맞는 까닭은 이력에 남은 편집이다. 편집이 이력에 남아 있는 한 지문은 계속 안 맞는다. 문서는 뺀 블록을 되돌리면 그 사이에 만든 블록이 무효라고 한다. 이 성질은 속성 테스트로 확인한다(§3.6). Anthropic 서버가 같은 결론을 내는지는 라이브 증명으로만 안다.
- 창 시작점이 움직이면 모든 서명 블록의 지문이 달라져 전부 빠진다. 그 뒤 만드는 블록은 새 앞부분에 묶이고, 다음에 시작점이 움직일 때까지 재생된다. 이 비용은 §6 Q6 이 묻는다.
- `Omit_binding_absent`: 이 RFC 이전에 저장된 블록. 호환 읽기 코드를 만들지 않고 뺀다(§4.1).

### 3.5 400 을 타입으로 구분하는 방법

오류 본문이 주는 구조: `type`(`invalid_request_error`), `message`, `request_id` 와 HTTP 상태 코드뿐이다(§1.2-6). 서명 400, 사용 한도 400, temperature 400, 크기 400 은 모두 같은 `type` 이다. 구조 필드로는 이 넷을 가를 수 없다. 별도 코드 필드를 만들어 내지 않는다.

그래서 파싱 경계는 지금처럼 `Unknown_invalid_request` 로 둔다. 아는 만큼만 말하는 값이다. 대신 원인을 가를 증거를 구조 있는 곳에서 따로 얻는다.

1. **요청 쪽 사실을 오류에 붙인다.** 보낸 요청이 서명 블록을 몇 개 재생했는지, 지문 검사를 모두 통과했는지, 샘플링 파라미터를 보냈는지는 우리가 안다. 이 값은 응답을 읽지 않고 얻는다. `Unknown_invalid_request` 에 `attempt_facts` 를 붙인다. 이렇게 하면 "서명 블록 N개를 재생했고 지문이 모두 맞았는데도 거절" 같은 줄이 운영자에게 보인다. 이것은 알림이 아니라 원인을 좁히는 사실이다.
2. **크기 증거는 공급자가 재 준 숫자로만 얻는다.** `Unknown_invalid_request` 를 받은 뒤, 공급자의 토큰 세기(`count_tokens`)가 있는 레인에서만 한 번 센다. 센 입력 토큰이 카탈로그가 적은 `max_context` 를 넘으면 `Size_refusal_measured { input_tokens; max_context }` 로 값을 만든다. 넘지 않거나 셀 수 없으면 크기 때문이라는 증거가 없다. 코드에는 이미 `Count_tokens_sync` 와 `Input_capacity` 의 `Token_measurement_unavailable` 가 있다(`prepared_completion_request.mli:90`, `retry.ml` 의 `input_capacity_reason`). 이 판정은 문구를 읽지 않는다.
3. **`boundary_resend_on` 은 `Size_refusal_measured`, `ContextOverflow`, `Request_body_refused_by_provider` 에만 true 를 돌려준다.** `Unknown_invalid_request` 는 false 다. 지금 true 인 `Unknown_invalid_request` 갈래를 지운다. 이것은 값을 더하는 것이 아니라 갈래 하나를 지우는 변경이다.
4. 알 수 없는 400 은 보이게 실패한다. 이력도 줄이지 않고 다시 보내지도 않는다. 이 실패 값에 요청 쪽 사실(1)이 붙는다. 서명 400 이 위 조치로도 나면 그것은 우리 결함이거나 이 RFC 가 모르는 규칙이다. 숨기면 안 된다.

이 설계가 어디서 깨지는지:

- 실제 크기 거절이 문장만 있는 400 으로 온다는 기존 실측(`keeper_turn_driver_try_provider.ml:2495-2510` 의 주석, `RFC-librarian-lifecycle` §4.10)을 이 RFC 는 다시 확인하지 못했다. 그 전제가 맞고 `count_tokens` 가 쓸 수 없는 레인이면, 크기 거절이 보이게 실패한다. 지금은 시작점을 옮겨 해결되던 경우다. 이 비용을 받아들일지는 운영자 결정이다(§6 Q1).
- `RFC-keeper-context-window-in-tokens` §1 의 결정 2 는 "요청을 보내기 전에 재지 않는다" 이다. 이 RFC 는 거절 뒤에 한 번 센다. 보내기 전 측정이 아니라서 문장은 지키지만, 같은 결정을 다시 읽어 줘야 한다.
- 사용 한도 400 과 temperature 400 은 타입으로 가르지 못한다. 구조 필드가 있는지 응답 헤더까지 포함해 실제 본문 하나씩을 받아 확인하는 일이 필요하다(§7 의 측정 항목). 있으면 그때 변형을 더한다. 없으면 `Unknown_invalid_request` + 요청 쪽 사실로 남는다. temperature 는 카탈로그의 `ignored_sampling_parameters` 가 이미 보내지 않기 위한 장치이므로 이 400 은 요청 구성 결함으로 읽는다.
- 서명 400 을 응답으로 구별하는 구조 신호는 없다. 구조 신호가 있는 곳은 2xx 응답의 `input_transformations` 뿐이다. `prefix_binding_mismatch` 이유는 `drop_block` 일 때 `thinking_dropped` 로, 검사하지 않는 계정에서 beta 헤더를 보내고 필드를 비워 두면 `thinking_mismatch_allowed` 로 나온다(preserved-thinking). 이 값은 진단에 쓸 수 있다. 정책으로 쓰지 않는다. 검사가 기본인 계정에서 필드를 비웠을 때 어떻게 되는지는 문서에서 확인하지 못했다.

### 3.6 하네스 먼저

결정적인 것과 아닌 것을 나눈다.

**결정적 (오프라인, 항상 돌린다).**

- 순수 함수 `Anthropic_request_prefix.relation : previous:Yojson.Safe.t -> next:Yojson.Safe.t -> relation` 을 둔다. 값은 `Append_only` 와 `Broke of prefix_change` 다. 서명 블록 유무와 함께 읽는다. 오프라인 하네스와 라이브 증명이 같은 함수를 쓴다.
- 시나리오는 실제 Keeper 경로로 라운드 N 과 N+1 의 본문을 만들어 대조한다.
  1. 도구 없는 두 라운드 (턴별 문맥 있음, 내용 다름)
  2. 도구 라운드가 한 턴 안에서 두 번 이어짐
  3. 창 시작점이 한 칸 움직임 (`atoms_per_window` 경계)
  4. 폴백으로 다른 런타임(`claude` → `claude_vincent`)으로 넘어감
  5. 저장된 이력을 읽어 재시작 후 이어서 보냄
  6. 이 RFC 이전에 저장된 이력 (binding 없음)
- 합격 조건: 모든 연속 쌍에서 `Append_only` 이거나, N+1 본문이 끊긴 지점 앞에 묶인 서명 블록을 하나도 담지 않고 사유 값이 기록되어 있다.
- 변이 검사: 턴별 문맥을 요청 끝에 붙이고 이력에 남기지 않는 옛 코드로 되돌리면 시나리오 1 이 실패해야 한다. 지문 비교를 빼면 시나리오 3 이 실패해야 한다.
- 속성 테스트: 뺀 블록은 이력이 같으면 다시 들어오지 않는다.
- Anthropic 규칙을 흉내 내는 로컬 스텁 서버는 이 RFC 에서 만들지 않는다. 문서를 읽은 우리 해석이지 Anthropic 이 아니다. 스텁이 통과해도 실제 통과를 뜻하지 않는다.

**비결정적 (라이브, 수동).**

- 기존 `packages/agent_core/test/anthropic_live_proof.ml` 은 두 턴 도구 왕복에서 서명 블록 재생을 확인한다(289-321줄). 어느 test alias 에도 걸려 있지 않고 `ANTHROPIC_LIVE=1` 과 키가 있어야 하며 비용이 든다. 여기서는 턴별 문맥이 있는 두 라운드와 라운드 사이에 문맥 값을 바꾸는 경우를 더한다.
- 요청에 `thinking.block_binding.prefix_mismatch_behavior: "error"` 와 beta 헤더를 명시한다. 문서는 `"error"` 를 회귀를 크게 실패시키는 용도로 권한다. 이 값이 있으면 계정 나이와 상관없이 검사가 켜진다(문서 FAQ). 그래서 오래된 계정에서도 이 증명이 앞부분 위반을 잡는다.
- 현재 실행 제약: MASC 는 push 마다 CI 를 돌리지 않고 Release/Tag 에서 Full CI 를 돌린다(`instructions/masc-workflow.md`). 라이브 증명은 수동 실행이고, 결과는 PR 본문에 실행 명령과 모델 이름·날짜로 남긴다. 실행하지 않은 증명의 통과를 적지 않는다.
- 응답의 비결정성 때문에 모델이 thinking 블록을 아예 안 낼 수 있다(문서: 단순한 요청에는 생략). 기존 증명이 계산을 먼저 시키는 이유다. 블록이 없으면 그 실행은 아무것도 증명하지 않으므로 실패가 아니라 "증명 못 함" 으로 보고한다.

## 4. 이행

### 4.1 저장된 이력: 하드 컷

- 이 저장소 정책은 데이터 스키마가 바뀔 때 migration 이나 명시적 hard cut 중 하나를 고르고, hard cut 에서는 호환 읽기·변환·마이그레이션 코드를 만들지 않는다(`workflow.md` 진입 장벽).
- 선택: 하드 컷이다. `Reasoning_source` 키를 `agent_core.reasoning_source.v3` 으로 올린다(현재 `v2`, `types.ml`). v2 로 저장된 항목은 `classify` 가 `Absent` 로 읽고, 재생 투영은 이미 `Absent` 를 `Missing_reasoning_source` 로 기록하며 추론을 뺀다(`reasoning_history_projection.ml`).
- 이유: 옛 블록은 만든 요청의 앞부분이 기록되어 있지 않아 지금 맞는지 알 수 없다. 모르는 것을 맞다고 읽으면 400 이다. 빼는 것은 문서가 유효하다고 적은 길이고 코드를 더하지 않는다. 변환기를 만들면 그 변환이 틀렸을 때 같은 400 을 다시 만든다.
- 비용: 모든 공급자에서 저장된 추론이 한 번 빠진다. 비 Anthropic 공급자의 자기 완결형 추론 글도 포함이다. 모델이 지난 추론을 잃는다. 이 비용이 크면 대안(§5 의 "별도 키")이 있다. 운영자가 고른다(§6 Q7).
- 기존 체크포인트 파일은 지우지 않는다. 읽을 때 빠질 뿐이다.

### 4.2 지금 실패하는 Keeper

- 한 번 실패한 Keeper 는 이후 매 턴 같은 400 으로 실패한다(§1.1). 이력에 남은 서명 블록과 지금 앞부분이 맞지 않기 때문이다.
- 하드 컷이 배포되면 v2 블록이 모두 빠지므로 첫 요청부터 앞부분 위반이 없다. 별도 복구 절차가 없다.
- 배포 전에 임시로 풀려면 해당 Keeper 의 이력에서 thinking 블록을 지우는 것인데(문서: 지워도 유효), 이것은 운영 조치이고 이 RFC 의 범위가 아니다. 이슈에 따로 적는다.

### 4.3 PR 스택 (층마다 결과 하나)

MASC 규칙에 따라 gh stack 으로 쌓고 맨 위 PR 로 스택째 병합한다(`masc-workflow.md`). 층마다 리뷰한다.

| 층 | 결과 | 주요 파일 |
|---|---|---|
| 1 | 조사: system·tools 가 턴 사이에 바뀌는 코드 경로를 특정하고, 앞부분 대조 함수와 시나리오 1~2 를 일부러 실패하는 상태로 넣는다 (현재 코드가 위반한다는 증거) | `test/`, 새 순수 함수 |
| 2 | `boundary_resend_on` 에서 `Unknown_invalid_request` 갈래를 지운다. 거절 뒤 `count_tokens` 로 `Size_refusal_measured` 를 만든다. 요청 쪽 사실을 오류에 붙인다 | `retry.ml`, `keeper_turn_driver_try_provider.ml` |
| 3 | 턴별 문맥을 턴당 한 번 만들어 이력에 남기고 입력 귀속 검사를 맞춘다 | `agent_turn.ml`, `keeper_agent_prompt_metrics.ml`, 용어집 연동 문구 |
| 4 | `Reasoning_source` v3(`binding`, `credential_scope`), 카탈로그 `thinking_binding`, 재생 판정 `match` | `types.ml`, `reasoning_dialect.ml`, `reasoning_history_projection.ml`, `models.toml` |
| 5 | system·tools 고정과 `Prefix_break` 기록 | 1층 결과에 따라 정해짐 |
| 6 | 라이브 증명 확장과 `prefix_mismatch_behavior: "error"` 명시 | `anthropic_live_proof.ml` |

순서의 이유: 2층은 3~5층과 독립이라 가장 먼저 증상(조용한 시작점 이동)을 막는다. 4층은 하드 컷이라 3층 뒤에 둔다. 앞부분이 안정되기 전에 지문을 저장하면 지문이 매번 달라져 모든 블록이 빠진다.

## 5. 검토한 대안

| 대안 | 얻는 것 | 버리는 것 / 기각 이유 |
|---|---|---|
| `drop_block` 을 기본값으로 | 코드를 거의 안 바꾼다. 요청이 항상 성공한다 | 앞부분이 바뀌는 원인을 안 고친다. 매 턴 버리면 출력 토큰이 늘어난다(§1.2-8, 우리 하네스 측정 없음). 문서도 임시방편이라 한다. 우리 저장소의 워크어라운드 거부 기준과 맞지 않는다. 장점은 있다. 라이브가 지금 깨져 있으면 가장 빠른 완화다. 그래서 이 RFC 는 이 길을 영구 설정으로 쓰지 않는다고 못박을 뿐, 긴급 상황의 임시 조치는 `WORKAROUND:` 라벨과 대체 RFC 번호(이 RFC)를 달고 따로 올릴 수 있다 |
| 서명 400 문구를 읽어 thinking 을 빼고 한 번 더 보낸다 | 문서가 권하는 복구 순서와 같다 | 문구 매칭이다. 문서가 문구는 바뀔 수 있다고 한다. 우리 규칙의 문자열 분류기 금지 |
| 서명 블록을 아예 보내지 않는다 (`No_replay`) | 가장 단순하다. 400 이 구조적으로 사라진다 | 모델이 지난 추론을 잃는다. 도구 라운드 안의 최신 assistant 턴은 문서가 thinking 을 그대로 돌려보내라고 한다("Send assistant turns back exactly as returned"). 모든 턴에 `No_replay` 를 걸면 이것도 어긴다. 또 앞부분을 안정시킬 이유가 캐시 적중에도 남는다 |
| 턴별 문맥을 요청마다 새로 만들되 `system` 으로 올린다 | 이력이 안 자란다 | `system` 이 바뀌면 모든 서명 블록이 무효다(문서의 표). 가장 나쁜 자리다 |
| 턴별 문맥을 B(`clear_at`)로 | 토큰이 안 든다 | beta 와 모델 제약, 읽지 못한 "Limitations" 절, 와이어에 `role: "system"` 추가. 근거가 모자라 첫 구현에서 뺀다. 측정으로 필요가 확인되면 다음 RFC |
| 지문을 `Reasoning_source` 대신 별도 메타데이터 키로 | 비 Anthropic 공급자의 저장된 추론이 하드 컷에 안 빠진다 | 같은 메시지에 출처와 지문이 따로 있어 둘이 어긋날 수 있다. 한 사실을 한 곳에 두는 원칙과 맞지 않는다. 운영자가 비용을 크게 본다면 이쪽이 낫다(§6 Q7) |
| 요청 전에 `count_tokens` 로 매번 크기를 잰다 | 크기 거절을 사전에 안다 | `RFC-keeper-context-window-in-tokens` §1 결정 2 와 충돌한다. 매 요청에 호출이 하나 더 든다 |
| 이력 창을 없애 앞부분을 안 바꾼다 | 앞부분이 항상 안정된다 | 컨텍스트 한계가 있다. 창은 `RFC-keeper-context-window-in-tokens` 의 설계다. 이 RFC 는 창이 움직일 때의 서명 블록 처리만 정한다 |

## 6. 열린 질문과 위험

운영자가 정해야 할 것:

- **Q1.** 크기 거절이 문장만 있는 400 으로 오고 `count_tokens` 가 쓸 수 없는 레인이면, 이 RFC 이후 그 거절은 보이게 실패한다. 받아들이는가, 아니면 그 레인에 한해 다른 증거(예: 413)를 찾는가.
- **Q7.** `Reasoning_source` v3 하드 컷(모든 공급자의 저장 추론이 한 번 빠짐)과 별도 키(비용 적고 사실이 두 곳) 중 어느 쪽인가.

조사로 닫을 것:

- **Q2.** 도구 목록이 바뀔 때 `tool_addition`·`tool_removal`(beta `inline-tools-2026-09-15`)이 필요한가. 먼저 도구 목록이 52개와 175개 사이로 바뀌는 이유를 코드에서 특정해야 한다(구현 1층).
- **Q3.** 턴별 문맥에 사용자·외부가 쓴 글이 들어가는가. 들어가면 `role: "system"` 에 올리지 않는다.
- **Q4.** 턴 시작 값으로 굳혀도 되는가. 도구 라운드마다 최신 값이 필요한 항목(예: 남은 예산)이 있는가.
- **Q5.** vincent 키 계정이 2026-08-31 이후 생성인가. 맞다면 증상이 설명된다. 틀리면 §1.3 의 세 곳이 원인이 아닐 수 있다. 구현 1층의 대조가 이것을 가른다. 같은 계정에서 키만 바꾼 경우 `credential_scope` 라벨이 같아도 괜찮은지도 같이 본다.
- **Q6.** 창 시작점이 움직이는 빈도. 한 번 움직일 때마다 서명 블록이 전부 빠지고 캐시가 다시 시작한다. 움직이는 빈도와 그 때 늘어나는 입력 토큰을 측정해야 한다. 자주 움직이면 서명 재생이 실질적으로 꺼지고, 이 RFC 는 400 만 없앨 뿐 추론 보존 이득은 못 얻는다.
- **Q8.** 서버 쪽 compaction·context editing 은 앞부분 편집으로 세지 않는다고 문서가 적는다. masc 의 Librarian 요약(자체 요약)이 어디에 해당하는지, 고정 구간을 어떻게 다룰지 정해야 한다. 문서는 직접 쓴 요약이 "keep-tail" 방식이면 남긴 턴의 thinking 이 실패한다고 한다.
- **Q9.** Codex·Gemini·OpenAI 호환 공급자에 같은 문제가 있는지는 이 RFC 가 보지 않았다. Gemini 는 `reasoning_dialect.ml:528` 의 주석에서 서명 파트를 그대로 돌려보내야 한다고 적는다. 같은 모양이면 별도 RFC 로 낸다.
- **Q10.** 사용 한도 400 과 temperature 400 의 실제 본문과 헤더. 구조 필드가 있으면 §3.5 에 변형을 더한다.
- **Q11.** mid-conversation 시스템 메시지의 "Limitations" 절(미확인). B 를 고를 때 읽는다.
- **Q12.** 지문 비교의 소요 비용(요청당 직렬화·해시). 이력이 클 때 얼마인지 측정하지 않았다.

위험:

- A 는 이력을 키운다(§3.2). 키우는 양을 재기 전에 3층을 병합하면 창이 더 자주 움직이고 §6 Q6 의 비용이 커진다.
- 요청 본문을 로그로 남기지 않아 지문 불일치의 원인을 사후에 가려내기 어렵다. 불일치 지점(`prefix_change`)은 기록하되 본문 전체를 로그에 남기는 것은 이 RFC 가 정하지 않는다. 본문에는 사용자 데이터가 있다.
- 지문이 우리 JSON 기준이라 서버가 다르게 읽는 경우를 못 잡는다. 계정 불일치와 서버 쪽 규칙 변경이 그렇다. 라이브 증명이 잡을 수 있는 범위만 잡는다.
- 이 RFC 는 공식 문서 2026-10-13 판에 기대고 있다. 문서가 바뀌면 지문의 범위(thinking 블록 제외 등)를 다시 읽어야 한다.

## 7. 테스트 계획과 합격 기준

합격 기준은 층마다 잰다.

| 층 | 기준 | 방법 |
|---|---|---|
| 1 | 현재 코드에서 시나리오 1·2 가 실패한다 (위반의 증거) | `dune test` 중 해당 테스트. 실패가 기대 결과이므로 PR 본문에 이유와 함께 적는다 |
| 2 | 크기 증거 없는 400 에서 `boundary_resend_on` 이 false 다. 한 케이스도 시작점을 옮기지 않는다 | `Unknown_invalid_request`, `Size_refusal_measured`, `ContextOverflow`, `Request_body_refused_by_provider` 를 각각 넣는 표 기반 테스트. 새 변형을 더하면 컴파일이 깨져야 한다 |
| 2 | 사용 한도 400 과 temperature 400 의 본문을 넣은 요청이 시작점을 옮기지 않고 `attempt_facts` 가 붙은 오류로 끝난다 | 실제 본문을 받은 뒤 고정 입력으로 쓴다 (Q10) |
| 3 | 오프라인 하네스 시나리오 1·2·5 에서 N+1 본문이 N 본문의 `Append_only` 이다. 라운드 수 N 은 시나리오마다 20 이상 | 변이: 옛 동작으로 되돌리면 실패 |
| 4 | 시나리오 3·4·6 에서 앞부분이 끊긴 요청은 끊긴 지점 앞에 묶인 서명 블록을 하나도 담지 않는다. 사유가 `prefix_change` 값으로 기록된다 | 속성 테스트: 뺀 블록은 이력이 같으면 다시 들어오지 않는다 |
| 4 | 카탈로그에 `thinking_binding` 이 없는 Anthropic 와이어 행은 로드가 실패한다 | 카탈로그 로드 테스트 |
| 4 | `project` 의 `signed_thinking_disposition` 처리에 `_ ->` 갈래가 없다 | 컴파일 (새 변형 추가 시 깨짐) |
| 5 | `system`·`tools` 가 세션 값과 다른 요청 구성은 `Prefix_break` 로만 나온다 | 단위 테스트 |
| 6 | 라이브: `claude-haiku-5-5` 등 카탈로그 행마다 턴별 문맥이 있는 두 라운드에서 `prefix_mismatch_behavior: "error"` 로 400 이 0 이다. 서명 블록이 한 번도 안 나온 실행은 "증명 못 함" 이다 | 수동 실행. 명령·모델·날짜를 PR 본문에 남긴다. 실행하지 않았으면 통과라고 적지 않는다 |

전체 합격 기준:

- 오프라인 하네스의 모든 시나리오에서 서명 블록을 담은 연속 쌍 중 `Append_only` 이거나 끊긴 지점 앞의 서명 블록이 없는 비율이 100% 다. 라운드 수는 시나리오마다 20 이상이다.
- 크기 증거 없는 400 에서 시작점이 이동한 사례가 테스트에서 0 이다.
- 라이브 증명에서 앞부분 위반 400 이 0 이다. 실행한 모델과 날짜를 적는다.
- 1.1 의 Keeper 4개가 배포 후 첫 요청부터 서명 400 없이 진행하는지는 운영 관찰이다. 합격 기준에 넣지 않고 배포 후 이슈에 적는다.

## 부록 A. 인용 위치 확인 (`origin/main` `c7fa2a0cec`, 2026-10-13)

이슈 #42636 의 인용 중 줄 번호가 바뀐 것과 그대로인 것을 구분한다.

| 이슈의 인용 | 지금 | 상태 |
|---|---|---|
| `agent_turn.ml:34-54` | `agent_turn.ml:34-53` | 한 줄 차이로 고침 |
| `pipeline_stage_prepare.ml:148-153` | `packages/agent_core/lib/pipeline/pipeline_stage_prepare.ml:148-155` | 경로 보완, 범위 고침 |
| `retry.ml:340` | `retry.ml:340-341` (400, 422) | 그대로 맞음 |
| `keeper_turn_driver_try_provider.ml:2515-2540` | `:2511-2535` (`boundary_resend_on`) | 줄 번호가 움직임. 고침 |
| `reasoning_dialect.ml:520-523` | `:506-531` (Anthropic 갈래, 521줄이 `All_assistant_messages`) | 범위 고침 |
| `api_common.ml:364-379` | 그대로 | 맞음 |
| `types.ml:383-420` | `:341-420` (`Reasoning_source`, `rotation_admits` 는 401줄) | 범위 넓힘 |
| `runtime_model_input_tail_window.ml:4` | 그대로 (`atoms_per_window = 60`) | 맞음 |
| `keeper_carried_front.mli` | 있음 | 맞음 |

이 RFC 가 새로 인용한 줄은 모두 같은 커밋에서 읽었다. 다시 확인하는 명령:

```
rg -n "messages @ \[ system_msg \]" packages/agent_core/lib/agent/agent_turn.ml
rg -n "Unknown_invalid_request" packages/agent_core/lib/llm_provider/retry.ml | head -3
rg -n "let boundary_resend_on|restore_front before" lib/keeper/keeper_turn_driver_try_provider.ml
rg -n "replay_policy = All_assistant_messages" packages/agent_core/lib/llm_provider/reasoning_dialect.ml
```

버린 인용: 없다. 이슈의 `reasoning_dialect.ml:520-523` 은 정확한 범위가 아니라서 위처럼 고쳤다.

## 부록 B. 디렉터리와 번호

- `packages/agent_core/docs/rfc/` 에 둔다. 번호 `RFC-AC-041` 은 이 디렉터리의 마지막 번호 `RFC-AC-040` 다음이다. 열린 PR 검색(`gh pr list -R jeong-sik/masc --state open --search "RFC-AC-041"`)에서 같은 번호가 나오지 않았다.
- 이유: 규칙의 중심이 agent_core 에 있다. 요청 본문을 만드는 `backend_anthropic.ml`, 재생 규칙 `reasoning_dialect.ml`, 저장 출처 `types.ml`, 오류 분류 `retry.ml` 이 모두 agent_core 다. 이어받는 RFC-AC-029(재생 표준)와 RFC-AC-040(카탈로그 소유)이 같은 디렉터리에 있다. keeper 쪽 변경(`boundary_resend_on`, 창, 시작점)은 소비자이고, RFC-AC-029 §6 의 경계 원칙(agent_core 는 typed 사실을 내고 MASC 가 쓴다)을 따른다.
- `docs/rfc/` 는 새 RFC 에 번호를 발급하지 않고 `RFC-<slug>.md` 만 받는다(`docs/rfc/README.md`). 번호를 달라는 요구와 맞지 않는다. keeper 쪽 구현 층이 별도 설계 판단을 낳으면 그때 `docs/rfc/` 에 slug RFC 를 따로 쓰고 이 RFC 를 `related` 로 건다.
- 변경 기록 조각(`changelog.d/<PR 번호>.md`)은 PR 번호가 필요하다. 이 RFC 는 로컬 커밋이라 PR 번호가 없어 만들지 않았다. `changelog-fragments.py missing` 은 알림이지 거절이 아니다(스크립트 설명). PR 을 열 때 필요한지 다시 본다.
