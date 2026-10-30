# RFC-AC-041: Anthropic 요청의 앞부분은 이어 붙이기만 한다

| | |
|---|---|
| Status | Draft |
| Author | vincent (with Claude analysis) |
| Created | 2026-10-13 |
| Updated | 2026-10-13 (독립 검토 반영. #42677 이 들어간 main 기준으로 문제 진술과 인용을 다시 읽음) |
| Target | `agent_core` — `lib/agent/agent_turn.ml`, `lib/llm_provider/{retry,reasoning_dialect,reasoning_history_projection,backend_anthropic,types}.ml`, 카탈로그(`models.toml`). masc — `lib/keeper/keeper_turn_driver_try_provider.ml`, `lib/runtime/runtime_model_input_tail_window.ml`, `lib/keeper/keeper_model_input_demotion.mli`, `lib/keeper/keeper_run_tools_hooks.ml` |
| Related | #42636, #42632, #42671, #42677, #42713, #42729, RFC-AC-029 §S3, RFC-AC-040, `docs/rfc/RFC-keeper-context-window-in-tokens.md` §1·§13.4, `docs/rfc/RFC-librarian-lifecycle.md` §4.10, `docs/rfc/RFC-0363-historical-tool-result-demotion.md` |
| 측정 기준 | `파일:줄` 은 `origin/main` `4cc7ed1ebf`(2026-10-13 조회)에서 다시 읽은 값이다. 처음 쓴 기준 `361883ee64` 와 줄이 다른 곳은 부록 A 에 두 열로 적었다. 측정 수치는 2026-10-12T16:04Z(2026-10-13 01:04 KST)에 `~/.masc` 에서 잰 값이고, 센 방법을 각 곳에 적었다 |
| 디렉터리 | `packages/agent_core/docs/rfc/`. 이유는 부록 B |

## 0. 요약

- 2026-10-12 06:36Z~15:38Z 에 `claude_vincent.*` 런타임의 Keeper 4개가 같은 400 으로 61번 실패했다. 문구는 ``Invalid `signature` in `thinking` block. The block is bound to a different conversation.`` 이다.
- Anthropic 은 서명이 붙은 thinking 블록을 다시 보낼 때, 그 블록을 만든 요청과 system, tools, 앞선 messages 가 같아야 받는다. masc 는 요청을 만들 때마다 이 앞부분을 바꾼다.
- 바꾸는 곳은 코드로 확인한 것이 넷이다. (1) 턴별 문맥을 요청 끝에 붙였다가 다음 라운드에서 뺀다. (2) 보내는 이력 창의 시작점이 움직인다. (3) 오래된 도구 결과를 마커로 줄이는 경계(강등)가 턴마다 움직인다. (4) 다시 보내는 서명 블록에 앞부분 비교가 없다. 현 main 은 #42677 때문에 최신 턴의 도구 루프 thinking 만 다시 보내지만, 그 블록이 만들어진 때와 앞부분이 같은지는 보지 않는다(§1.3-4). system·tools 가 라운드 사이에 바뀌는 경로도 코드에서 둘 찾았다(§1.3).
- 같은 400 이 `Unknown_invalid_request` 로 읽히고 `boundary_resend_on` 이 이 값에 true 를 돌려준다. 크기와 상관없는 400 에도 짧은 창으로 한 번 더 보낸다.
- 이 RFC 는 다섯 가지를 정한다. (a) Anthropic 요청은 앞부분을 이어 붙이기만 한다. (b) 턴별 문맥은 만든 뒤 바꾸지 않는 메시지로 이력에 남긴다. (c) 서명 블록은 앞부분 지문이 맞을 때만 다시 보내고, 아니면 빼며 이유를 타입으로 남긴다. (d) system·tools 는 고정하지 않고 바뀐 것을 지문으로 알아낸다. (e) 크기 때문이라는 증거가 있는 400 에만 짧은 창으로 다시 보낸다.
- 서명 블록은 앞부분 지문이 맞는 것 말고도, 보내는 thinking 블록이 원래 순서의 끊기지 않는 구간일 때만 다시 보낸다. 문서가 thinking 블록마다 바로 앞 thinking 블록을 기록한다고 적기 때문이다(§1.2-14, §3.4 의 서명 사슬 확인).
- #42677(병합 `c72b91bc99`)과 이 RFC 는 층이 다르고 둘 다 남는다. #42677 은 어느 블록이 다시 보낼 후보인지를 정하고, 이 RFC 의 지문은 후보 블록의 앞부분이 그대로인지를 정한다. #42677 의 강제를 풀지는 이 RFC 가 정하지 않고 운영자 결정으로 둔다(§1.3-4, Q13).
- 이 RFC 가 해 주지 못하는 것: 턴 사이의 thinking 이어짐. 현 main 은 #42677 의 정책으로 이미 새 턴에서 지난 턴 thinking 을 뺀다. 그 정책을 풀어도 강등과 창 이동은 그대로이므로 그 둘이 일어나는 턴 경계에서는 끊긴다. 턴 안(도구 라운드 사이)의 이어짐만 지킨다(§3.5).
- 범위는 Anthropic 요청 경로다. 다른 공급자의 요청과 재전송 규칙은 지금 그대로 둔다(§2).
- 작업은 여덟 층의 스택이다(§4.3). 400 을 없애는 층(지문과 재생 판정)을 가장 먼저 둔다.

## 1. 문제와 근거

용어: 이 문서의 "턴" 은 Keeper 가 입력 하나를 처리하는 한 번이고, "라운드" 는 그 안에서 공급자를 부르는 한 번이다. 한 턴에 라운드가 여러 번 있을 수 있다(도구 호출 때문이다).

### 1.1 증상

| 사실 | 값 | 센 방법 (2026-10-12T16:04Z) |
|---|---|---|
| 서명 400 | 61건. ocaml-agent-ic 19, polisher 18, you-never-change 13, e-masc-the-leader 11 | `~/.masc/keepers/*/execution-receipts/2026-10/12.jsonl` 에서 ``Invalid `signature` in `thinking` block`` 를 담은 줄을 센다 |
| 시간 범위 | 06:36:18Z ~ 15:38:56Z | 그 줄들의 `recorded_at` 의 최소·최대 |
| "rewritten since it was created" | 17줄 | 같은 파일에서 그 문장을 담은 줄 |
| "missing from this request" | 43줄 | 같음 |
| 사용 한도 400 | 585줄 (10-11 이 502, 10-12 가 83. 10-12 의 줄은 문장이 두 번씩 들어 있어 문장 수로는 166) | 10월 전체 receipts 에서 `reached your specified API usage limits` 를 담은 줄 |
| temperature 400 | 5줄 | 10월 전체 receipts 에서 `` `temperature` may only be set to 1 `` 를 담은 줄 |
| `claude.*` 런타임 | 같은 코드로 thinking·도구 혼합 실행 약 300회, 서명 오류 0 | 이슈 #42636 인용. 다시 세지 않았다 |
| vincent 키의 두 번째 호출 | 첫 호출은 통과하고 두 번째가 거절된다 | 이슈 인용. 다시 확인하지 않았다 |

61건 중 두 문구의 합은 60이다. 나머지 1줄의 문구는 확인하지 않았다. 이슈가 든 "크기 초과 3건" 은 다시 세지 않았다.

사용 한도 400 의 실제 문장은 "You have reached your specified API usage limits. You will regain access on 2026-11-01 at 00:00 UTC." 이다. 이 Keeper 들은 11월 1일까지 어떤 코드로도 성공할 수 없으므로 이 400 에 짧은 창으로 다시 보내는 것은 요청만 늘린다.

확인하지 못한 것:

- 요청 본문이 로그에 없다. 라운드 N 과 N+1 의 실제 바이트를 대조하지 못했다. 아래 원인은 코드 읽기와 오류 문구에서 나온 추정이다. 라운드 N 과 N+1 의 요청 본문 쪽 증거는 #42713 이 `docs/evidence/2026-10-13-anthropic-thinking-prefix/diagnosis.json`(glossary-maniac 요청 #2326/#2327: system·tools 동일, 이전 문맥 블록이 다음 요청에서 사라짐)으로 남겼다.
- 위 수치는 #42677 병합(2026-10-13T03:07:10Z) 전의 것이다. 병합 뒤 같은 400 이 줄었는지는 세지 못했다. 이 실행 환경에 `~/.masc/keepers` 가 없었고, 병합한 빌드가 Keeper 에 배포된 시각도 모른다.
- vincent 키 계정이 2026-08-31 이후 생성인지 모른다. 공식 문서는 그날 이후 만든 계정에 검사를 기본으로 켠다. vincent 만 실패하고 `claude.*` 는 통과하는 이유가 계정 나이라는 설명이 맞을 수 있으나 확인하지 않았다.

### 1.2 Anthropic 규칙 (공식 문서, 2026-10-13 조회)

읽은 곳은 네 페이지다. 조회 도구가 페이지를 요약해 돌려주는 방식이라, 아래 인용은 그 결과에 들어 있던 원문 인용이다.

- `https://platform.claude.com/docs/build-with-claude/preserved-thinking` (121,909자 전체)
- `https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting` (전체)
- `https://platform.claude.com/docs/en/api/errors` (전체)
- `https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages` (105,261자 전체. "Limitations" 절은 처음 읽을 때 잘려서 같은 날 뒷부분을 다시 읽었다)

1. 검사 대상 모델은 Claude Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5 이다. 검사하는 앞부분은 top-level `system`, `tools` 의 집합, 블록 앞의 모든 `message` 다. `effort`, `max_tokens`, `output_config`, `tool_choice`, `metadata`, `cache_control` 은 앞부분이 아니다.
2. 문서의 지침: "Keep `system` and `tools` fixed for the session and treat `messages` as append-only."
3. 앞부분이 다르면 `"error"`(기본값)는 400 `invalid_request_error` 로 거절한다. `"drop_block"` 은 실패한 블록과 그 뒤 thinking 블록을 서버가 버리고 성공시키며, 버려진 블록은 과금되지 않는다.
4. 2026-08-31 00:00 UTC 이후 만든 계정은 검사가 기본이다. 그 전 계정은 요청에 `thinking.block_binding.prefix_mismatch_behavior` 를 넣을 때만 검사한다. 이 필드는 beta 헤더 `thinking-binding-controls-2026-08-01` 이 있어야 한다. Sonnet 5.5 와 Haiku 5.5 에서 `block_binding` 은 `thinking: {"type": "adaptive"}` 일 때만 동작한다. `between_tools`(Sonnet 5.5)나 `disabled`(Haiku 5.5)에서는 이력을 이어 붙이기만 하거나 thinking 블록을 직접 빼야 한다.
5. thinking 블록을 시작부터, 끝부터, 전부 빼는 것은 유효하다. 중간에서 빼면 뒤 블록이 무효다. 뺀 블록을 다시 넣으면 그 사이에 만든 블록이 무효다. 문서는 "Earlier thinking blocks aren't in the prefix" 라고 적는다.
6. 이전 도구 결과를 지우거나 줄이면 이후 모든 thinking 이 무효다. 문서의 "What counts as an edit" 표가 "Clear or shorten an earlier `tool_result`" 를 "Invalid for every later thinking block" 으로 분류한다.
7. 오류 본문은 `{"type":"error","error":{"type","message"},"request_id"}` 이고 "`type` values will grow over time" 이라고 적혀 있다. 서명 400 에 대해 문서는 "That sentence is for people and logs. Its wording can change, so don't match on it in code." 라고 쓴다. 별도 오류 코드 필드는 문서에 없다.
8. 서명 400 이 아닌 400 도 같은 `invalid_request_error` 다. 조직·워크스페이스 지출 한도에 닿으면 400 이다(errors, "HTTP errors").
9. `drop_block` 의 출력 토큰 증가는 표가 아니라 본문 문단에 있다. 다중 턴 코딩 벤치마크에서 첫 턴 이후 매 턴 버리면 low 4.6%, medium 9.7%, high 10.3%, max 67.1% 늘었다. 한 세션에 한 번 버리면 2.5%, 3.9%, 4.5%, 20.1% 였다. 문서는 "stopgap" 이라 부른다.
10. 앞부분을 건드리지 않고 정보를 더하는 방법은 `role: "system"` 메시지다. Fable 5.1, Mythos 5.1, Fable 5, Mythos 5, Opus 5.5, Opus 4.8, Opus 5, Sonnet 5.5, Haiku 5.5 에서 쓸 수 있고 beta 헤더가 필요 없다. Sonnet 5 는 못 쓴다. `clear_at: "next_user_message"` 인 턴 범위 메시지는 같은 모델 목록에서 `mid-conversation-system-clear-at-2026-08-21` 이 필요하다. 정리된 메시지는 이력에 남지만 "renders nothing and costs no input tokens" 이고, 이후 요청에 글자 그대로 다시 보내야 한다. 도구 변경 `tool_addition`·`tool_removal` 은 `inline-tools-2026-09-15` 가 필요하다.
11. 그 메시지의 제약(Limitations): 첫 메시지가 될 수 없다. 반드시 `user` 턴(도구 결과만 있는 user 턴 포함) 바로 뒤에 오고 `assistant` 턴 앞이거나 배열 끝이어야 한다. `tool_use` 와 `tool_result` 사이에는 못 둔다. 턴 범위 메시지는 text 만 되고 `cache_control` 을 못 단다. "Not a place for untrusted content": 도구 출력·검색 문서 같은 바깥 글을 system 메시지에 넣으면 운영자 권한이 된다.
12. 계정이 다르면: "Thinking blocks that Claude Sonnet 5.5 or Claude Haiku 5.5 produces work only in the account that produced them". 다른 계정이 보내면 서버가 조용히 버린다. 헤더가 있으면 `input_transformations` 에 `organization_binding_mismatch` 로 나온다.
13. 문서의 처리 안내: 도구 사용을 끄려면 `tools` 를 빼지 말고 `tool_choice: {"type": "none"}` 를 보낸다.
14. thinking 블록끼리의 순서 규칙. `preserved-thinking` 페이지(121,909자 중 처음 100,000자를 다시 읽었고 나머지 21,909자는 이 항목을 위해 읽지 않았다)의 문장이다: "Earlier thinking blocks aren't in the prefix, but each thinking block records which thinking block came before it, across turns. You can remove thinking blocks from the start of the history (oldest first), from the end, or all of them. What fails is a gap: the thinking blocks you keep must be an unbroken run of the original sequence, so removing one from the middle invalidates the thinking blocks after it. Once you remove a block, leave it out. Putting it back invalidates the thinking blocks produced while it was gone." 같은 페이지의 "What counts as an edit" 표: 앞에서, 끝에서, 전부 빼기는 "Valid (the model loses that reasoning)", 중간에서 빼고 뒤를 남기기는 "Invalid for every later thinking block", 뺐던 블록을 되돌리기는 "Invalid for thinking blocks produced while it was gone" 이다. 이 문장들은 `redacted_thinking` 이 순서에 드는지 말하지 않는다. 확인하지 못했다.

### 1.3 앞부분을 바꾸는 곳

요청 하나가 만들어지는 길은 이렇다. Keeper 가 이력을 정하고, 창과 강등을 거쳐 보낼 범위를 자르고, agent_core 가 턴별 문맥을 붙이고, 공급자 쪽에서 thinking 재생 규칙을 적용해 본문을 만든다.

**(1) 턴별 문맥이 요청 끝에 붙었다 빠진다.**

- `Agent_turn.prepare_messages` (`packages/agent_core/lib/agent/agent_turn.ml:34-53`)는 `extra_system_context` 가 있으면 `role = User`(45줄) 메시지 `[system context] …` 를 만들어 `messages @ [ system_msg ]`(52줄)로 끝에 붙인다.
- 이 결과는 요청과 입력 검사에만 쓰인다. `Pipeline_stage_prepare.prepare_turn_for_agent` (`packages/agent_core/lib/pipeline/pipeline_stage_prepare.ml:148-155`)는 `agent.state.messages` 를 넘기고, 붙인 메시지를 거기에 돌려놓지 않는다. 이력에는 남지 않는다.
- Keeper 의 hook 은 라운드마다 돈다(`lib/keeper/keeper_run_tools_hooks.ml` 의 `before_turn_hook`, 810줄. 937줄 `post_tool_round`). 2026-10-12 의 runtime-manifest 에서 문맥이 있는 라운드는 첫 라운드(`pre_tool_context_injection`) 1,188건이고, 두 번째 이후 라운드(`post_tool_context_injection`) 6,883건은 전부 문맥 크기가 비어 있다. 같은 턴의 두 번째 이후 라운드가 전체 라운드의 85%다. 세는 방법은 `~/.masc/keepers/*/runtime-manifests/**/*.jsonl` 에서 `context_injection` 상태 줄의 `extra_system_context_computed_size` 를 읽는 것이다. 모든 Keeper, 모든 공급자를 합친 값이다.
- 두 번째 이후 라운드에도 실리는 블록은 `Keeper_instructions` 와 `Operator_note` 둘뿐이다(`lib/types/prompt_block_id.ml:75-78`, `injected_on_post_tool_round`). 둘이 없으면 그 라운드의 문맥은 비어 있다.
- 그러므로 오늘의 요청은 첫 라운드에만 문맥을 싣고 둘째 라운드에서 뺀다. 첫 라운드에 만든 서명 블록은 둘째 라운드 앞부분이 달라져 무효가 된다. 이 설명은 1.1 의 두 문구와 맞아 보이나, 요청 본문 대조는 없다.
- 코드 주석(`agent_turn.ml:38-43`)은 끝에 붙이는 이유를 "앞부분이 바이트까지 같아야 로컬 LLM 의 KV 캐시를 재사용한다" 로 적는다. Ollama·llama.cpp 에 대한 판단이고 Anthropic 에는 반대로 작용한다.
- 용어집(`docs/spec/00-glossary.md` 의 "Extra System Context")은 이 메시지를 `System` 메시지라고 적는데 코드는 `User` 다. 이 RFC 는 코드를 따른다.

**(2) 이력 창의 시작점이 움직인다.**

- `Runtime_model_input_tail_window` (`lib/runtime/runtime_model_input_tail_window.ml:4`, `atoms_per_window = 60`)는 남는 이력이 들어갈 때까지 앞에서 60 atom 의 배수만큼 자른다(340줄 이하). 자르면 맨 앞에 합성 메시지 `[context window] Older turns … are omitted` 가 붙는다(7줄 이하).
- 시작점은 `Keeper_carried_front` 가 정한다. 시작점이 움직이는 빈도는 재지 못했다. 움직이는 순간 맨 앞 메시지가 바뀌어 모든 서명 블록이 무효가 된다.

**(3) 강등이 턴마다 오래된 도구 결과를 바꾼다.**

- `Keeper_model_input_demotion` (`lib/keeper/keeper_model_input_demotion.mli:1-3`)은 오래된 도구 결과 본문을 blob 마커로 바꾼 사본을 공급자에 보낸다. 경계 `demote_before` 는 "마지막으로 끝난 턴의 끝"이고(`keeper_turn_driver_try_provider.ml:1543-1550`), 정책 `Small`(기본값, `keeper_input_policy.ml:2`)에서는 항상 적용된다. `Wide` 는 연속성에 따라 적용하지 않는다(1179-1189).
- 모듈 설명(`keeper_model_input_demotion.mli` 의 `plan`)이 스스로 적는다. 경계가 움직이면 보내는 앞부분이 다시 쓰이고, 그래서 경계를 "턴마다 한 번" 움직이게 골랐다. 한 턴 안의 라운드 사이에서는 경계가 고정된다("pinned to the turn's seed").
- 따라서 새 턴의 첫 요청에서 지난 턴의 큰 도구 결과(마커가 더 작아지는 것)가 마커로 바뀐다. 6번 규칙(§1.2)대로 이후 서명 블록이 무효다. 바뀐 도구 결과보다 뒤에 있는 서명 블록이 무효가 된다. 마커보다 작은 결과만 있는 턴은 바뀌지 않는다.
- 크기 거절 뒤 재전송에서는 이번 턴의 도구 결과도 강등한다(`Current_turn_demoted`, #28845).

**(4) 다시 보내는 서명 블록에 앞부분 비교가 없다.**

- Anthropic wire 의 재생 규칙은 모델 행이 정한다. 행이 `reasoning_replay` 를 적지 않았으면(`Default_reasoning_replay`) 런타임이 `Force_latest_user_turn_tool_calls` 를 강제한다. #42677(병합 `c72b91bc99`, 2026-10-13T03:07:10Z)이 넣은 규칙이다(`lib/runtime/runtime_adapter.ml:608` `with_client_history_replay`, 강제는 `:635`). 찾은 행이 없어 능력 값이 `None` 이면 강제하지 않는다(`:637`). Anthropic 갈래는 행의 선언을 따른다(`reasoning_dialect.ml:523` `apply_replay_override`). 선언이 없을 때의 라이브러리 기본값은 `All_assistant_messages` 다(`:527`).
- `claude-*` 행(`packages/agent_core/models.toml` 52~303줄)에는 `reasoning_replay` 선언이 없다. 이 파일의 첫 선언은 588줄이다. 그래서 Sonnet 5.5 같은 `claude-*` 모델은 강제 경로를 탄다. `claude_vincent` 런타임의 설정은 이 저장소 밖이라 읽지 못했다. #42677 본문이 이 런타임을 대상으로 적는다. 행이 스스로 규칙을 적으면 그 규칙이 이긴다(`deepseek-v4-pro` 행 802줄 `latest_user_turn_tool_calls`, `kimi-k2.7-code` 행 929줄 `preserve_always`).
- 강제가 하는 일: 가장 새 user 메시지 뒤의 도구 루프에서 나온 thinking 만 다시 보내고(`reasoning_history_projection.ml:204-220` `replay_selected`), 이전 턴 assistant 메시지에서는 thinking 블록을 뗀다(같은 파일 303줄 `without_reasoning`). 턴별 문맥 메시지(`message.origin = System_context | Historical_system_context`)는 user 턴으로 세지 않는다(같은 파일 176-202줄). 서명 블록은 글자 그대로 직렬화한다(`api_common.ml:364-379`).
- #42677 본문은 입력 토큰이 줄고 모델이 이전 턴의 추론을 못 보게 된다고 적고, 품질과 비용이 얼마나 달라지는지는 재 보지 않았다고 적는다. 실제 Anthropic API 로 400 이 사라지는지도 확인하지 못했다고 적는다.
- 남은 결함: 강제가 정하는 것은 어느 블록이 후보인지다. 후보 블록이 만들어질 때와 앞부분이 같은지는 비교하지 않는다. 같은 턴의 도구 라운드 사이에도 앞부분이 바뀌는 경로가 있다. 첫 라운드에만 붙는 턴별 문맥(§1.3-1)이 그렇다. 첫 라운드에서 만든 서명 블록은 문맥 메시지 뒤에 묶이는데, 둘째 라운드 요청에서는 그 블록 앞에 문맥 메시지가 없다. 이것은 코드를 읽고 낸 추론이고 요청 본문으로 확인하지 않았다(Q14).

**#42677 과 이 RFC 의 관계.** 층이 다르다. 어느 쪽도 다른 쪽을 대체하지 않는다.

| 층 | 정하는 것 | 소유 |
|---|---|---|
| 정책 | 어느 assistant 메시지의 thinking 이 다시 보낼 후보인가 | 모델 행의 `reasoning_replay` 와 런타임 강제(#42677). 판정 함수는 `replay_selected` |
| 지문 | 후보 블록이 만들어질 때와 앞부분(system, tools, 앞선 메시지)이 같은가. 같은 출처·계정인가 | 이 RFC. `Reasoning_history_projection.project` 의 새 판정(§3.4) |

- 정책이 후보로 보지 않는 블록은 지문을 보지 않고 뺀다(§3.4). 후보여도 지문이 안 맞으면 뺀다.
- #42677 은 뭉툭한 처치다. 이전 턴 thinking 을 전부 버리므로 앞부분이 그대로인 경우의 thinking 도 같이 잃는다. 지문이 있어야 이전 턴 thinking 을 앞부분이 그대로인 만큼만 다시 보낼 수 있다. 그 길을 여는 방법은 카탈로그 행에 `reasoning_replay = "preserve_always"` 를 적는 것이다. 행의 선언이 강제보다 앞서므로(`runtime_adapter.ml:637`) 코드를 바꿀 필요가 없다. 언제 여는지는 Q13 이다.
- 지문 층 없이 #42677 만으로는 같은 턴 안의 앞부분 변경(위 문맥, 도구 목록)이 막히지 않는다.
- 이 RFC 는 #42677 의 코드를 바꾸지 않는다.

**출처와 계정.**

- 저장된 블록의 출처 검사는 `Reasoning_source` 가 한다(`types.ml:341-420`). 비교하는 값은 provider 종류, 엔드포인트(`base_url` + `request_path` 해시), 모델 id, 재생 규칙이다. Anthropic 은 `Require_identical_source` 다(`reasoning_dialect.ml:641-658` `rotation_policy`, 649줄). 앞 내용이 같은지는 보지 않는다. 판정 코드는 `reasoning_history_projection.ml:204-220`(`replay_selected`)과 258줄(`rotation_admits`)이다.
- 같은 엔드포인트에 키만 다른 런타임(`claude`, `claude_vincent`)은 같은 `Reasoning_source` 로 보인다. 계정이 다른 블록을 걸러 낼 수 없다.

**(5) system 과 tools.**

- 이슈는 polisher 의 wire-capture 에서 system prompt 해시가 `b89d0d67` 에서 `43079d2e` 로, tools 가 52개와 175개 사이로 바뀐 기록을 든다. 이 RFC 는 그 캡처를 다시 열지 않았다.
- tools 는 라운드마다 달라질 수 있는 경로가 코드에 둘 있다. 하나는 hook 이 라운드마다 `Keeper_agent_tool_surface.for_request`(`keeper_run_tools_hooks.ml:998`, `keeper_agent_tool_surface.mli:77`)로 현재 도구 집합을 `tool_choice`, 스키마 필터, 표면 스위치에 맞춰 다시 정하는 것이다. 다른 하나는 Agent Core 레인이 처음에는 목록만 받고, 모델이 서비스를 불러오면 그 라운드부터 도구를 넓히는 것이다(`keeper_agent_tool_surface.mli:47-57`, `on_the_wire`). 넓히면 `tools` 가 바뀐다. 문서는 `defer_loading: true` 없이 도구를 더하면 앞부분이 바뀐다고 적는다.
- 도구가 없는 요청은 `tools` 필드를 아예 뺀다(`agent_turn.ml:26-31`, `prepare_tools` 가 빈 목록이면 `None`). 문서는 도구를 끄려면 `tool_choice: none` 을 쓰고 `tools` 는 빼지 말라고 한다(§1.2-13).
- system prompt 는 `build_base_system_prompt` (`lib/keeper/keeper_run_context.ml:43`)가 Keeper 실행마다 만들고, 턴 프롬프트는 그 값이다(`keeper_run_prompt.ml:92`). 값이 턴 사이에 달라지는 경로는 찾지 못했다.
- `backend_anthropic.ml:336` 은 `System` 역할 메시지를 `user` 로 내보낸다. `role: "system"` 메시지를 내보내는 길은 지금 없다. `anthropic-beta` 헤더를 보내는 코드도 없고(`rg "anthropic-beta" packages lib` 는 테스트 한 곳만 나온다), `thinking.block_binding` 을 보내는 코드도 없다.

### 1.4 400 처리의 부작용

- `Retry.classify_error` 는 HTTP 400 과 422 를 모두 `InvalidRequest { reason = Unknown_invalid_request }` 로 만든다(`packages/agent_core/lib/llm_provider/retry.ml:340-341`). 413 은 이미 별도 값 `Request_body_refused_by_provider` 다(350줄).
- `boundary_resend_on` (`lib/keeper/keeper_turn_driver_try_provider.ml:2542-2570`)은 `ContextOverflow`, `Request_body_refused_by_provider`, `Unknown_invalid_request` 에 true 를 돌려준다. 같은 파일의 `refusal_evicts`(2354줄)는 앞의 둘에만 true 다. 다르게 쓴 것은 의도다. 주석(2525-2541줄)이 이유를 적는다. 지금까지 다시 확인한 크기 거절이 "문장만 있는 400" 으로 온다는 것이다.
- `turn_boundary_resend_sequence` (2595줄 이하)는 true 면 시작점을 턴 경계로 옮겨 한 번 더 보낸다. 다시 보낸 요청이 크기 거절이 아니면 앞서 들고 있던 시작점을 돌려놓는다(2627줄, `restore_front before`).
- 따라서 "컨텍스트가 조용히 잘린다" 는 다시 보낸 요청이 받아들여졌을 때만 성립한다. 사용 한도 400 은 다시 보내도 같은 거절이 나므로 코드상으로는 시작점이 돌아오고 요청이 한 번 더 나갈 뿐이다. 서명 400 에서 짧은 창으로 다시 보내면 받아들여지는지는 확인하지 못했다. 로그가 아니라 코드를 읽은 결과다.
- 크기 때문인지는 지금 오류 값에 없다. 문장으로 가르면 문자열 분류기다(RFC-AC-029 §S1, §S8). Anthropic 도 문구로 가르지 말라고 한다(§1.2-7).

### 1.5 턴별 문맥의 크기 (2026-10-12)

| 값 | n | 중앙 | p90 | 최대 | 센 방법 |
|---|---|---|---|---|---|
| 첫 라운드의 문맥 | 1,188 | 28,732 B | 50,212 B | 63,424 B | runtime-manifest 의 `pre_tool_context_injection` 줄, `extra_system_context_computed_size` |
| receipt 의 `extra_system_context_injected_size` | 593 | 26,746 B | 47,433 B | 62,230 B | `~/.masc/keepers/*/execution-receipts/2026-10/12.jsonl` 의 같은 이름 필드 (검토자는 n=587 을 얻었다. 그 뒤 줄이 늘어 593 이다) |

단위는 바이트다(`String.length ctx`, `keeper_run_tools_hooks.ml:1276`). 모든 Keeper 와 공급자를 합친 값이다. 토큰으로 바꾸지 않았다.

### 1.6 확인 상태 요약

| 주장 | 상태 |
|---|---|
| 앞부분 규칙, `drop_block` 비용, 도구 결과 변경의 효과 | 공식 문서를 읽음 |
| 턴별 문맥이 이력에 남지 않고 첫 라운드에만 붙는다 | 코드와 manifest 로 확인 |
| 강등 경계가 턴마다 움직인다 | 코드로 확인. 움직이는 빈도는 못 쟀다 |
| 다시 보내는 서명 블록에 앞부분 비교가 없다 | 코드로 확인(`replay_selected`, `rotation_admits` 가 지문을 안 본다) |
| #42677 이후 Anthropic Default 행은 최신 턴 도구 루프 thinking 만 재생한다 | 코드와 PR 본문으로 확인. 실제 API 에서 400 이 사라지는지는 미확인 |
| #42677 이후에도 같은 턴 둘째 라운드에서 앞부분이 바뀐다 | 코드 읽기 추론. 요청 본문 대조 없음(Q14) |
| 서명 사슬: 뺐던 블록을 다시 넣으면 그 동안 만든 블록이 무효가 된다 | 공식 문서를 읽음(§1.2-5). §3.4 의 선행자 검사가 담당한다 |
| 창 시작점이 움직여 맨 앞 메시지가 바뀐다 | 코드로 확인. 빈도는 못 쟀다 |
| tools 가 라운드마다 바뀌는 경로 | 코드로 둘 확인. 52↔175 캡처와 연결은 못 했다 |
| system prompt 가 턴 사이에 바뀐다 | wire-capture 인용. 코드 경로 미확인 |
| vincent 계정이 2026-08-31 이후 생성 | 미확인 |
| 서명 400 이 위 원인 때문에 난다 | 추정. 요청 본문 대조 없음 |
| 서명 400 뒤 짧은 창 재전송이 성공한다 | 미확인 |

## 2. 목표와 비목표

### 목표

1. Anthropic 요청에서 앞부분 위반 400 이 일어나지 않게, 요청을 만들 때부터 막는다. 그래도 나는 400 은 숨기지 않는다.
2. 앞부분이 바뀔 수밖에 없을 때(창 이동, 강등, 이력 재작성, 런타임·계정 전환)는 서명 블록을 빼고 보내고, 빼는 이유를 타입으로 남긴다.
3. 크기 때문이라는 증거가 있을 때만 짧은 창으로 다시 보낸다.
4. 위 세 가지를 라운드 N 과 N+1 의 요청 본문 대조로 테스트한다.

### 비목표

- `drop_block` 을 기본값으로 쓰지 않는다. 문서가 임시방편이라 부르고 매 턴 버리면 출력 토큰이 최대 67.1% 늘었다(§1.2-9, Anthropic 자체 벤치마크의 effort max 값이고 우리 하네스에서 재지 않았다). 이 이유가 이 RFC 의 설계에도 해당하는지는 §3.5 에 쓴다.
- 오류 문구를 읽어 원인을 가르지 않는다.
- 재시도 횟수·쿨다운 같은 상한을 두지 않는다.
- Anthropic 이 아닌 공급자의 요청 구성과 재전송 규칙은 바꾸지 않는다. 구체적으로 (1) 턴별 문맥을 이력에 남기는 일은 Anthropic 요청 경로를 쓰는 턴에서만 하고, 다른 공급자는 지금처럼 가장 최근 문맥만 끝에 붙인다(§3.2). (2) `boundary_resend_on` 의 `Unknown_invalid_request` 갈래는 크기를 측정할 수 있는 공급자(`Count_tokens_sync.supports_completion_request_measurement`, `count_tokens_sync.ml:151-158`: Anthropic 과 Kimi)에서만 바꾸고, 나머지(OpenAI 호환, Ollama, Gemini, GLM)는 지금 그대로 둔다(§3.4). 그 공급자들에는 "크기와 상관없는 400 에 짧은 창으로 다시 보낸다" 는 문제가 남는다. 이슈로 따로 기록한다.
- #42677 이 넣은 재생 강제(`Force_latest_user_turn_tool_calls`)를 이 RFC 가 바꾸지 않는다. 풀지 말지는 Q13 이다.
- Codex 레인(`keeper_codex_runtime`)은 이 요청 경로가 아니라서 건드리지 않는다. 경로를 끝까지 따라가 확인하지는 않았다.
- 용어집은 고치지 않는다.
- system·tools 값을 세션 동안 저장해 고정하지 않는다(§3.3). 불필요한 변경을 없애는 일(위 1.3-5 의 두 경로)은 이 RFC 의 범위 밖이고 후속 이슈로 남긴다.

## 3. 설계

### 3.1 불변식 (Anthropic 요청)

연속한 요청 `R_n`, `R_{n+1}` 이 서명 블록을 하나라도 담으면 아래가 성립해야 한다.

- 이어 붙이기만 하는 것: `system` 값, `tools` 값, `messages` 의 `R_n` 길이까지의 항목. thinking·redacted_thinking 블록은 비교에서 뺀다(§1.2-5). 비교는 JSON 값으로 한다. 문서가 "JSON formatting and key order don't matter; the values do" 라고 적는다.
- 바뀌어도 되는 것: `messages` 끝에 덧붙인 항목, `effort`, `max_tokens`, `output_config`, `tool_choice`, `metadata`, `thinking.display`, `cache_control`.
- 앞부분이 바뀐 요청은 그 앞부분에 묶인 서명 블록을 담지 않는다(§3.4).
- 보내는 thinking·redacted_thinking 블록은 원래 순서의 끊기지 않는 구간이다(§1.2-14). 빼는 것은 오래된 쪽 끝이나 새 쪽 끝에서만 한다. 뺐던 블록을 다시 넣으면 그동안 만든 블록은 보내지 않는다(§3.4 의 서명 사슬 확인).

이 불변식은 우리가 보내는 JSON 에 대한 것이다. 우리 쪽 값이 다르면 Anthropic 쪽 앞부분도 다르다. 반대는 성립하지 않는다. 우리 쪽 값이 같아도 계정이 다르거나 서버가 다르게 읽으면 거절될 수 있다. 그 경우는 §3.4 의 계정 라벨과 §3.6 의 라이브 증명이 다룬다.

### 3.2 턴별 문맥을 어디에 두는가

선택지와 비교는 다음과 같다. 기준은 앞부분을 건드리는지, 모델이 보는 것이 지금과 같은지, 토큰과 저장 비용, 필요한 beta·모델 제약이다.

| | 방법 | 모델이 보는 것 | 비용 | 제약 |
|---|---|---|---|---|
| A | 만든 문맥을 `User` 메시지로 이력에 그대로 남긴다 | 지난 문맥이 계속 보인다. 오늘은 첫 라운드에만 보인다 | 토큰이 턴마다 늘고 저장도 는다. 오래된 문맥은 시간이 지나 낡는다 | beta 없음. 모든 Anthropic 행 |
| B | `role: "system"`, `clear_at: "next_user_message"` 메시지로 이력에 남긴다 | 다음 user 메시지가 오면 정리되어 안 보인다. 도구 결과가 오면 정리되므로 오늘처럼 첫 라운드에만 보인다 | 정리된 뒤에는 입력 토큰이 들지 않는다. 저장은 는다 | beta `mid-conversation-system-clear-at-2026-08-21`. Sonnet 5 는 못 쓴다. system 권한이라 안에 바깥 글이 있으면 안 된다 |
| C | `clear_at` 없는 `role: "system"` | A 와 같다 | A 와 같다 | 권한 문제는 B 와 같다. 이득이 없다 |
| D | 새 user 메시지에 text 블록으로 합친다 | A 와 같다 | A 와 같다 | 문맥만 가려내는 지금의 코드(`Runtime_model_input_tail_window.is_extra_context`, `lib/runtime/runtime_model_input_tail_window.ml:122`)가 깨진다 |

추천은 B 다. 이유는 둘이다.

1. 모델이 보는 것이 지금과 같다. A 는 지난 문맥이 계속 보이게 한다. 코드 주석(`keeper_run_tools_hooks.ml` 의 `post_tool_round` 위, task-514)은 세계 상태를 라운드마다 다시 보내면 모델이 같은 대답을 되풀이했다고 적는다. A 는 같은 위험을 새로 만든다.
2. 정리된 문맥은 입력 토큰을 쓰지 않는다. A 의 비용(§1.5 의 중앙 28.7KB 가 턴마다 쌓인다)을 지지 않는다.

B 의 조건과 비용:

- 조건 1, 권한: B 는 문맥을 운영자 권한으로 올린다. 문맥에는 Librarian 기억 블록 등이 있다. 바깥에서 온 글(도구 출력, 웹 내용)이 섞여 있으면 B 는 쓸 수 없다. 블록별로 확인해야 하고 이 RFC 는 확인하지 않았다(§6 Q3). 확인되지 않은 동안 B 의 구현을 병합하지 않는다.
- 조건 2, 모델: 카탈로그 행이 `turn_scoped_system_message` 를 지원한다고 적어야 한다. 문서가 지원을 적은 모델은 Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5 를 포함한 목록이다(§1.2-10). 문서에서 확인하지 못한 행은 지원하지 않는 것으로 두고 A 로 간다.
- 비용: 저장은 는다. 첫 라운드 문맥의 중앙값이 28.7KB 이므로(§1.5), 한 턴에 하나씩 이력에 남으면 턴 수가 6,494 인 polisher 의 경우 약 186MB 를 더한다. 이것은 두 측정값(6,494 는 2026-10-12 receipt 의 `turn_count`, 28.7KB 는 중앙값)을 곱한 산수이고 실제 증가량을 잰 것이 아니다. 같은 Keeper 의 현재 체크포인트 snapshot 한 개가 112MB 다(`~/.masc/traces/trace-1788310783225-00003/agent-core-snapshot-*.json`). 저장량이 문제가 되면 블록 단위로 주소를 붙여 한 번만 저장하는 방법이 있다. 문맥의 큰 블록은 자주 안 바뀌고 시계 줄이 자주 바뀐다(`keeper_run_tools_hooks.ml:1109-1117` 의 `cache_rank` 정렬 위 주석. 정렬 기준은 `lib/types/prompt_block_id.ml:56`). 이 RFC 는 이 방식을 정하지 않는다(§6 Q4).
- 문맥 하나를 한 번 만들어 남긴 뒤에는 글자 그대로 다시 보낸다. 다시 렌더하면 앞부분이 바뀐다(문서: "Rebuilding it from current state … is an edit to an earlier message").

공급자별 렌더링 방식을 카탈로그가 닫힌 값으로 고른다.

```
type context_placement =
  | Turn_scoped_system     (* B. 지원하는 Anthropic 행 *)
  | Persisted_user_message (* A. 지원하지 않는 Anthropic 행 *)
  | Latest_at_tail         (* 지금 방식. 다른 공급자 *)
```

- 이력에 남기는 것은 앞의 둘일 때만이다. `Latest_at_tail` 인 공급자의 요청은 이력에 남은 지난 문맥을 보내지 않고 가장 최근 문맥만 지금처럼 끝에 붙인다. 이렇게 하면 다른 공급자의 요청 바이트는 변하지 않는다.
- 폴백으로 런타임이 바뀌어도 이력은 하나다. 각 요청이 자기 공급자의 방식으로 그린다. 앞부분이 바뀌는지는 §3.4 의 지문이 알려 준다.
- "턴별" 의 뜻: hook 이 문맥을 낼 때마다(`Some ctx`) 한 번 남긴다. 문맥이 없는 라운드는 아무것도 남기지 않는다. 오늘은 첫 라운드에서만 `Some` 이다(§1.3-1). 이후 라운드에 문맥을 싣는 블록(`Prompt_block_id.injected_on_post_tool_round`)이 선언되면 그 라운드의 문맥이 새 메시지로 덧붙는다. 지난 문맥을 고치지 않는다.
- 지금의 "요청 하나에 문맥 하나" 전제와 점검(`Keeper_agent_prompt_metrics` 의 `Prompt_context_carrier_repeated`, `lib/keeper/keeper_agent_prompt_metrics.ml:51`·`:180`. 용어집 "Extra System Context")은 "요청에 실려 보이는 문맥 하나" 로 바꾼다. 고정(pinned) 규칙도 바뀐다. 이력에 남은 지난 문맥은 보통 이력 atom 이어서 창에 잘린다. 잘리면 §3.4 가 그 앞부분에 묶인 서명 블록을 뺀다.
- 이력에 남기는 문맥 메시지는 `message.origin = Historical_system_context` 를 갖는다. 현재 문맥은 `System_context` 로 생성하고, 재생 경계는 `Conversation` 출처의 User 입력만 센다. 메타데이터나 문장 접두사는 메시지 출처의 권위가 아니다.

### 3.3 system·tools 는 고정하지 않고 바뀐 것을 알아낸다

- system prompt 와 tools 의 값을 따로 저장해 세션 동안 고정하지 않는다. 운영자가 `base_system_prompt` 를 고치면 다음 요청부터 반영되어야 하고, 고정하면 그 수정이 숨는다. 값을 저장하면 저장 위치와 갱신 규칙도 새로 정해야 한다.
- 대신 두 값은 지문의 재료다(§3.4). 바뀌면 그 요청의 서명 블록이 빠지고 이유가 `System_changed`, `Tools_changed` 로 남는다. 운영자 수정의 대가는 그 한 번의 추론 이어짐 손실과 캐시 재시작이다.
- 도구 목록이 라운드마다 달라지는 경로(§1.3-5)를 없애는 일은 이 RFC 가 하지 않는다. 두 경로가 턴 안에서 앞부분을 바꾸므로 그 턴의 서명 블록은 계속 빠진다. 후속 이슈의 방향은 문서가 말하는 `defer_loading: true` 선언(처음부터 전체 도구를 올려 두고 `tool_addition`·`tool_removal` 로 켜고 끈다, beta `inline-tools-2026-09-15`)과 "도구를 끌 때는 `tool_choice: none`" 이다. 이 방향은 검증하지 않았다.

### 3.4 서명 블록 재생 규칙

**지문을 어디서 만드는가.**

- `Reasoning_history_projection.project` (`reasoning_history_projection.ml:222-226`)는 `messages` 만 받는다. system 과 tools 를 모르므로 지문을 거기서 만들 수 없다.
- 지문은 Anthropic 요청 객체(`Backend_anthropic.build_request_artifact`, `backend_anthropic.mli:114`, `.ml:763`)가 만든다. 이 객체는 창, 강등, 턴별 문맥, 재생 투영을 모두 거친 뒤의 `system`, `tools`, `messages` 를 가지고 있다. 그 본문이 실제로 나가는 것이다.
- 지문은 `system` 과 `tools` 를 재료로 시작해 메시지를 하나씩 이어 쌓는다. thinking·redacted_thinking 블록은 재료에서 뺀다(§1.2-5). 메시지 `i` 앞까지의 값을 `prefix_before(i)` 라고 부른다. 요청 객체가 모든 `i` 의 값을 가진다.
- 응답 시점에 붙인다. 응답으로 만든 assistant 메시지(`Types.assistant_message_of_response`, `types.ml:839`)에 그 요청의 마지막 지문(요청의 모든 메시지 뒤 값)을 붙인다. 지금도 같은 자리에서 `Reasoning_source` 를 붙인다. 지문은 응답 텔레메트리에 실려 그 함수까지 온다.
- 다음 요청을 만들 때, 이력의 서명 assistant 메시지마다 저장된 지문을 새 요청의 `prefix_before(그 메시지 자리)` 와 비교한다. 투영은 메시지를 지울 수 있으므로(`removed_empty_assistant_indices`) 자리는 투영 뒤 위치로 센다.

**저장: Anthropic 전용 별도 키.**

- `Reasoning_source` 는 그대로 둔다. 지문과 계정 라벨은 새 메타데이터 키 `agent_core.prefix_binding.v1` 에 둔다. 값은 `{ prefix_fingerprint; credential_scope; thinking_predecessor }` 다.
- `credential_scope` 는 계정을 가르는 라벨이다. `claude` 와 `claude_vincent` 는 같은 `Reasoning_source` 이므로 이 값으로만 구별된다(§1.3-4). 값은 키가 아니고 설정이 정한 런타임 프로필의 안정된 이름이다. 어떤 이름을 쓸지는 `Provider_config` 를 더 읽어야 정해지고 이 RFC 는 거기까지 읽지 못했다. 같은 계정에 라벨이 둘이면 보수적으로 블록을 뺀다. 키를 바꿔도 라벨이 같으면 계속 쓴다. 키 교체가 계정 교체와 같은지는 라벨로 알 수 없다(§6 Q5).
- `thinking_predecessor` 는 이 서명 블록이 만들어진 요청이 실제로 보낸 열에서 바로 앞에 있던 thinking·redacted_thinking 블록의 서명 해시다. 없으면 `none` 이다. 응답 시점에 지문과 같이 붙는 덧붙임 사실이고, 정책이 제외했는지와 무관하게 그 요청이 보낸 열을 기록한다. 문서가 "each thinking block records which thinking block came before it, across turns" 라고 적은 규칙을 우리 쪽 값으로 옮긴 것이다(§1.2-5). 재생 판정의 사슬 확인이 이 값을 읽는다.
- 재생하려면 `Reasoning_source` 가 맞고(`rotation_admits`, 지금 그대로) 이 키가 있고 지문과 라벨이 맞아야 하며, 모은 열의 사슬 확인(아래)을 통과해야 한다. 하나라도 빠지면 뺀다.

**카탈로그 사실.**

- 모델 행이 `thinking_binding = prefix_bound | not_prefix_bound` 를 적을 수 있다. 문서가 확인한 네 모델(§1.2-1)은 `prefix_bound` 를 적는다. 안 적은 행은 RFC-AC-040 의 `unknown` 이고, 소비자는 `prefix_bound` 와 같게 다룬다. 이유: 지문이 맞는 블록만 보내므로 틀린 쪽으로 틀려도 요청은 거절되지 않고 추론만 잃는다. `not_prefix_bound` 인 행은 지금 하나도 없다. Anthropic 호환 표면을 쓰는 행(DeepSeek 등, `models.toml` 의 `base = "anthropic"` 12행 중 일부)이 문서로 확인되면 그때 적는다.
- 소비자의 `match` 는 `Some Not_prefix_bound`, `Some Prefix_bound`, `None` 을 모두 적는다. `_ ->` 갈래를 두지 않는다.

**재생 판정.**

```
type prefix_change =
  | System_changed
  | Tools_changed
  | History_front_moved
  | History_rewritten of { first_index : int }
  | Tool_result_demoted of { first_index : int }
  | Context_message_changed

type signed_thinking_disposition =
  | Replay
  | Omit_replay_policy_excluded    (* 정책(#42677 의 강제 포함)이 후보로 보지 않는다 *)
  | Omit_prefix_changed of prefix_change
  | Omit_binding_absent
  | Omit_source_changed
  | Omit_account_changed
  | Omit_older_than_unreplayable   (* 이 블록은 맞지만 더 새 블록이 안 맞는다 *)
  | Omit_chain_mismatch of { first_index : int }
      (* 뒤 블록이 기록한 선행자가 이 블록이 아니어서 빠진다 *)
```

- `reasoning_history_projection.project` 는 `disposition` 을 `match` 로 다루고 `_ ->` 갈래를 두지 않는다. 지금의 `reasoning_replay_drop_reason`(`reasoning_history_projection.ml:3-8`)에 `Prefix_not_preserved of prefix_change` 와 계정·지문 부재 갈래를 더하는 방향이다. 지금 있는 `Replay_policy_excluded` 는 아래 `Omit_replay_policy_excluded` 에 대응한다.
- #42677 의 강제(`Force_latest_user_turn_tool_calls`)는 `prefix_change` 변형을 새로 만들지 않는다. 근거 셋:
  1. 강제가 하는 일은 이전 턴 assistant 메시지에서 thinking·redacted_thinking 블록을 떼는 것이다(`reasoning_history_projection.ml:303` `without_reasoning`). 이 블록들은 지문 재료가 아니다(§3.1). 남은 메시지의 `prefix_before` 는 강제가 있든 없든 같다.
  2. 떼어내는 구간은 시작부터 이어진다. `replay_selected`(같은 파일 214-220줄)가 남기는 것은 가장 새 user 메시지 뒤의 도구 호출을 가진 assistant 메시지의 thinking 이고, 도구 호출 없는 assistant 메시지의 thinking 도 갈래에 따라 빠질 수 있다. 그 중간 빠짐이 시작부터 이어지게 하는 것은 강제가 아니라 아래 걷어내기 규칙이다. 문서가 유효하다고 적은 "시작부터 빼기"다(§1.2-5).
  3. 메시지 목록에 남는 영향은 하나다. thinking 만 있던 assistant 메시지는 thinking 을 떼면 내용이 비어 메시지째 빠진다(`removed_empty_assistant_indices`, 같은 파일 317-321줄. Anthropic 은 내용이 `[]` 이면 빈 것으로 본다, `backend_anthropic.ml:291`). 그 메시지가 서명 블록을 기록한 때는 있었고 지금 요청에는 없으면 뒤 메시지의 지문이 달라져 `History_rewritten` 으로 읽힌다. 그래서 따로 변형을 두지 않고 `History_rewritten` 이 받는다.
- 정책이 후보로 보지 않는 블록은 `Omit_replay_policy_excluded` 다. 이 블록은 지문을 계산하지 않는다. 앞부분이 바뀐 것이 아니라 정책이 보내지 않기로 한 것이어서 `prefix_change` 가 아니다. 판정 순서는 출처(`rotation_admits`, 지금 그대로), 정책, 그다음 새 검사(키 있음, 계정, 지문)다. 정책을 먼저 보는 이유는 보내지 않을 블록 때문에 `Omit_prefix_changed` 기록이 늘어 끊김 횟수가 부풀려지는 것을 막기 위해서다.
- 재생할 블록은 이렇게 고른다. 가장 새 서명 블록부터 거슬러 올라가며 `Replay` 인 블록을 모은다. `Replay` 가 아닌 블록(`Omit_replay_policy_excluded` 포함)을 처음 만나면 멈춘다. 그 블록과 그보다 오래된 서명 블록은 전부 뺀다(앞쪽부터 빼기만 한다). 문서가 유효하다고 적은 방식이다(§1.2-5). 정책이 중간 블록만 제외하는 설정(`Tool_call_assistant_messages_all_history` 등)에서도 빠지는 구간은 이 규칙 때문에 시작부터 이어진다.
- 모은 열로 서명 사슬을 확인한다. 보낼 열의 각 서명 블록에 대해 `thinking_predecessor` 가 실제로 바로 앞에 보내는 블록의 서명 해시와 같은지 본다. 맨 앞(오래된) 블록의 선행자는 `none` 이든 무엇이든 시작부터 빼기라 유효하다. 뒤에서 앞으로 링크를 확인해 끊긴 링크를 찾으면 그 오래된 쪽과 그 앞 전부를 뺀다(`Omit_chain_mismatch`). 정책 제외로 한 번 빠진 블록을 나중에 되살리는 전이가 지문에는 보이지 않는데(지문 재료가 thinking 을 빼므로), 이 검사가 그 전이를 닫는다. 문서의 "Once you remove a block, leave it out" 을 기록된 사실로 지키는 규칙이다(§1.2-5).
- 사슬이 끊기면 새 구간을 남기고 오래된 구간을 뺀다. 근거 셋. 첫째, 두 쪽 모두 문서가 유효하다고 적은 모양이다. 오래된 쪽을 빼면 "시작부터 빼기"이고 새 쪽을 빼면 "끝에서 빼기"다(§1.2-14 표). 둘째, 새 쪽은 열린 도구 라운드의 마지막 assistant 메시지를 포함할 수 있고, 문제 해결 문서는 그 메시지의 thinking 을 고치면 400 이라고 적는다(아래 열린 도구 라운드 항목). 셋째, 지금 코드도 같은 쪽을 남긴다. `replay_selected` 는 가장 새 user 메시지 뒤의 블록을 남기고 앞의 블록을 뺀다. 둘을 함께 남기는 길은 없다. 되돌린 `T1` 과 그동안 만든 `T2` 는 함께 보낼 수 없기 때문이다(§1.2-14).
- `redacted_thinking` 이 사슬에 드는지는 문서가 말하지 않는다(확인 못 함). 위 정의는 드는 것으로 센다. 실제로 들지 않는 블록이라면 우리 규칙이 필요 이상으로 블록을 뺄 뿐 요청은 거절되지 않는다. 라이브 증명이 확인한다(§3.6).
- 이 규칙은 한 번 앞부분이 바뀐 뒤에 새로 만든 블록을 영구히 잃지 않는다. 바뀐 뒤의 요청은 새 앞부분으로 지문을 붙이고, 그 블록은 이후 요청이 바뀌지 않는 한 재생된다. 앞쪽의 안 맞는 블록만 계속 빠진다. 안 맞는 블록과 같은 앞부분에 묶인 오래된 블록 중 맞는 것까지 빠지는 것은 보수적인 선택의 비용이다. 맞는 블록만 남기고 중간 블록만 빼는 쪽은 문서가 gap 으로 무효라고 적었다(§1.2-5). 그래서 앞쪽부터 빼기만 한다.
- 창 시작점이 움직이면 모든 지문이 달라져 서명 블록이 전부 빠진다. 강등도 마커로 바뀐 도구 결과 뒤의 모든 서명 블록을 뺀다.
- 열린 도구 라운드(마지막 assistant 메시지가 `tool_use` 를 가졌고 답이 오는 중)에서 그 마지막 메시지의 서명 블록을 빼야 하는 경우가 있다. 문서의 두 곳이 어긋나 보인다. 앞부분 문서는 끝에서 빼는 것이 유효하다고 하고, 문제 해결 문서는 마지막 assistant 메시지의 thinking 을 고치면 400 이라고 한다. 어느 쪽이 맞는지 확인하지 못했다. 라이브 증명이 이 경우를 시험한다. 400 이 나면 이 경우는 조용히 빼지 않고 타입 있는 턴 실패(`Open_tool_round_cannot_drop_signed_thinking`)로 만든다.
- `Omit_binding_absent`: 이 RFC 이전에 저장된 블록. 호환 읽기 코드를 만들지 않는다(§4.1).

### 3.5 이 설계가 지키는 것과 못 지키는 것

이 RFC 가 서명 블록을 빼는 것은 `drop_block` 이 블록을 버리는 것과 같은 비용을 낸다. 모델이 지난 추론을 잃어 출력 토큰이 늘 수 있다. 비목표에서 `drop_block` 을 거부한 이유가 이 설계에도 해당한다. 다른 점은 빈도다. `drop_block` 을 쓰면 앞부분이 바뀌는 모든 요청에서 버리고, 이 설계는 바뀌지 않는 요청에서는 보낸다.

- 지키는 것: 같은 턴의 라운드 사이. 2026-10-12 에 같은 턴의 두 번째 이후 라운드가 전체 라운드의 85%(6,883/8,071)다(§1.3-1). 이 라운드들은 문맥 메시지를 고정하고(§3.2) 강등 경계가 턴 안에서 고정되어 있으므로(§1.3-3), 도구가 안 바뀌고 창이 안 움직이면 앞부분이 이어 붙이기만 한다.
- 못 지키는 것: 턴 사이. 현 main 에서는 #42677 의 정책이 새 턴의 첫 요청에서 지난 턴 thinking 을 모두 뺀다. 이 RFC 의 지문 층은 그 빠짐을 되돌리지 않는다. 정책을 풀면(Q13) 지난 턴 thinking 이 후보가 되고, 그다음부터는 지문과 서명 사슬 확인이 가른다. 정책 제외 중에 만든 블록이 있는 이력에서는 사슬 확인이 없으면 정책을 푸는 순간 400 이 난다(시나리오 12). 그래서 푸는 일은 사슬 확인이 들어간 지문 층 뒤에만 한다. 새 턴의 첫 요청에서 지난 턴의 도구 결과가 마커로 바뀌면(강등) 그 뒤 서명 블록이 전부 빠진다. 창이 움직일 때도 같다. `Small`(기본값) 정책에서 지난 턴에 마커보다 큰 도구 결과가 있으면 해당한다. 마커보다 작은 결과만 있는 턴은 해당하지 않는다. 해당하는 턴이 얼마나 되는지는 재지 않았다.
- 턴 사이 손실의 비용은 잰 적이 없다. Anthropic 의 수치(첫 턴 이후 매 턴 버리면 4.6~67.1%)는 다른 하네스의 값이라 상한을 가늠하는 참고일 뿐이다. 우리 하네스에서 재는 방법: 실제 체크포인트 하나에 요청 본문 생성기를 돌려 턴 경계마다 빠지는 서명 블록 수와 그 블록들이 가진 추론 크기를 센다. 정책을 적용한 값과 적용하지 않은 값을 나란히 낸다. 둘의 차이가 #42677 이 이미 잃게 한 양이고, 정책을 껐을 때 지문이 맞는 블록의 비율이 Q13 의 근거다. 공급자를 부르지 않으므로 비용이 들지 않고 결정적이다. 값은 아직 없다(미측정).

강등 경계를 안정시키는 선택지와 비교는 다음과 같다.

| 선택지 | 얻는 것 | 잃는 것 |
|---|---|---|
| 지금 그대로 둔다 (추천) | 토큰이 줄어드는 지금의 이점 유지. 변경이 없다 | 턴 사이 추론 이어짐을 잃는다 |
| 서명 블록이 있는 구간 앞은 강등하지 않는다 | 턴 사이 이어짐 | 큰 도구 결과가 마커로 안 바뀌어 요청이 커진다. 강등의 존재 이유와 부딪힌다. 서명 블록은 거의 모든 assistant 턴에 있어 사실상 강등을 끈다 |
| 강등을 창이 움직이는 때에만 한꺼번에 한다 | 두 경계가 같이 움직여 끊김 횟수가 준다 | 그때까지 큰 결과가 원문으로 남아 요청이 커진다. 늘어나는 크기는 재지 않았다 |

추천은 지금 그대로 두는 것이다. 이유: 턴 사이 이어짐이 줄이는 출력 토큰은 측정하지 않았고, 다른 두 선택지는 모두 입력 토큰과 맞바꾼다. 위 방법으로 측정한 뒤 턴 경계마다 빠지는 추론이 크면 마지막 선택지를 다시 연다.

### 3.6 400 을 타입으로 구분하는 방법과 하네스

**400.** 오류 본문이 주는 구조는 `type`(`invalid_request_error`), `message`, `request_id` 와 HTTP 상태 코드뿐이다(§1.2-7). 서명 400, 사용 한도 400, temperature 400, 크기 400 은 같은 `type` 이다. 구조 필드로는 이 넷을 가를 수 없다. 별도 코드 필드를 만들어 내지 않는다. 파싱 경계는 지금처럼 `Unknown_invalid_request` 로 둔다. 본문이 말하지 않는 것을 말하지 않는 값이다. 원인을 가를 증거는 구조 있는 곳에서 따로 얻는다.

1. 요청 쪽 사실을 오류에 붙인다. 보낸 요청이 서명 블록을 몇 개 재생했는지, 지문이 모두 맞았는지, 샘플링 파라미터를 보냈는지는 우리가 안다. 응답을 읽지 않고 얻는 값이다. 서명 400 이 "서명 블록 N개를 재생했고 지문이 모두 맞았는데도 거절" 로 보이면 우리 결함이거나 이 RFC 가 모르는 규칙이다. 숨기지 않는다.
2. 크기 증거는 공급자가 재 준 숫자로만 얻는다. 측정할 수 있는 공급자(Anthropic, Kimi)에서 `Unknown_invalid_request` 를 받은 뒤 한 번 센다. 센 입력 토큰이 카탈로그의 `max_context` 를 넘으면 `Size_refusal_measured { input_tokens; max_context }` 를 만든다. 넘지 않거나 셀 수 없으면 크기 증거가 없다. 이미 있는 `Count_tokens_sync` 와 `Retry.input_capacity_reason` 의 `Token_measurement_unavailable`(`packages/agent_core/lib/llm_provider/retry.ml:12`)를 쓴다. 이 판정은 문구를 읽지 않는다.
3. `boundary_resend_on` 은 `Size_refusal_measured`, `ContextOverflow`, `Request_body_refused_by_provider` 에 true 이고, 측정할 수 있는 공급자의 `Unknown_invalid_request` 에 false 다. 측정할 수 없는 공급자의 `Unknown_invalid_request` 는 지금처럼 true 다(§2). 이 분기는 `supports_completion_request_measurement` 가 정한다. 공급자 이름 문자열이 아니다.
4. 측정할 수 있는 공급자의 알 수 없는 400 은 (3)에 따라 다시 보내지 않고 턴 실패로 드러난다. 실패 값에 요청 쪽 사실(1)을 붙인다. 사실을 붙이는 일은 재전송 규칙을 바꾸지 않으므로 (3)과 따로 들어갈 수 있다(§4.3).

이 설계가 어디서 깨지는지:

- 실제 크기 거절이 문장만 있는 400 으로 온다는 기존 실측(`keeper_turn_driver_try_provider.ml:2525-2541` 의 주석, `RFC-librarian-lifecycle` §4.10)은 이 RFC 가 다시 확인하지 못했다. 그 전제가 맞고 `count_tokens` 가 크기 초과를 가리키지 못하면, 측정할 수 있는 공급자에서도 크기 거절이 보이게 실패한다. 지금은 시작점을 옮겨 해결되던 경우다. 받아들일지는 운영자 결정이다(§6 Q1).
- `RFC-keeper-context-window-in-tokens` §1 결정 2 는 "요청을 보내기 전에 재지 않는다" 이다. 이 RFC 는 거절 뒤에 한 번 센다. 보내기 전 측정이 아니라 문장은 지키지만 결정을 다시 읽어 줘야 한다.
- 사용 한도 400 과 temperature 400 은 타입으로 가르지 못한다. 문장은 receipts 에서 구했다(§1.1). 응답 헤더와 구조 필드가 있는지는 모른다. 테스트에는 그 문장을 입력으로 쓰되 분류에는 쓰지 않는다. temperature 는 카탈로그의 `ignored_sampling_parameters` 가 보내지 않으려는 장치이므로 이 400 은 요청 구성 결함으로 읽는다.
- 서명 400 을 응답으로 구별하는 구조 신호는 없다. 구조 신호는 2xx 응답의 `input_transformations` 뿐이다. 이 신호는 진단에 쓸 수 있고 정책에는 쓰지 않는다.

**하네스.** 결정적인 것과 아닌 것을 나눈다.

결정적 (오프라인, 항상 돌린다):

- 순수 함수 `Anthropic_request_prefix.relation : previous:Yojson.Safe.t -> next:Yojson.Safe.t -> relation` 을 둔다. 값은 `Append_only` 와 `Broke of prefix_change` 다. 오프라인 하네스와 라이브 증명이 같은 함수를 쓴다.
- 시나리오는 실제 Keeper 경로로 라운드 N 과 N+1 의 본문을 만들어 대조한다.

| # | 시나리오 | 기대 |
|---|---|---|
| 1 | 같은 턴 안의 도구 라운드 둘, 첫 라운드에만 문맥 | `Append_only`, 서명 블록 전부 재생 |
| 2 | 도구 라운드 사이에 도구 결과가 두 번 쌓임 | `Append_only`, 전부 재생 |
| 3 | 창 시작점이 한 칸 움직임 | 서명 블록 없음, 이유 `History_front_moved` |
| 4 | 폴백으로 다른 런타임(`claude` → `claude_vincent`) | 서명 블록 없음, `Omit_account_changed` |
| 5 | 저장된 이력을 읽어 재시작 후 이어서 보냄 | `Append_only`, 전부 재생 |
| 6 | 이 RFC 이전에 저장된 이력(지문 키 없음) | 서명 블록 없음, `Omit_binding_absent` |
| 7 | 새 턴에서 지난 턴의 도구 결과가 마커로 바뀜 | 마커 뒤 서명 블록 없음, `Tool_result_demoted` |
| 8 | 도구가 없는 요청 | `tools` 필드가 있고 `tool_choice: none` |
| 9 | 한 턴 안에서 도구가 넓어짐 | 서명 블록 없음, `Tools_changed` |
| 10 | 정책 강제(`Force_latest_user_turn_tool_calls`) 아래 새 턴의 첫 요청 | 지난 턴 서명 블록 없음, 이유 `Omit_replay_policy_excluded`, `prefix_change` 기록 없음. 최신 턴의 블록은 지문이 맞으면 재생 |
| 11 | 서명 블록을 기록한 때는 있던 thinking 만 있는 assistant 메시지가 정책 변경으로 지금 요청에서 빠짐 | 그 뒤 서명 블록 없음, `History_rewritten` |
| 12 | 정책 제외 중 만든 블록의 사슬: T1 이 제외된 동안 T2 생성(T2 의 선행자 `none`), 정책 해제 뒤 요청 | T1 없음, `Omit_chain_mismatch`, T2 재생. `prefix_change` 기록 없음 |

- 시나리오 1~9 는 재생 정책을 `All_assistant_messages` 로 두고 돈다. 지문 층만 시험하려는 것이다. 정책 강제와 함께 도는 경우는 시나리오 10, 11, 12 이다.
- 판정 방법: 끊김이 없어야 하는 시나리오(1, 2, 5)는 `Append_only` 이면서 만든 서명 블록 수와 보낸 서명 블록 수가 같아야 한다. 모든 서명 블록을 빼는 구현이 통과하지 못하게 하려는 조건이다. 끊김이 기대되는 시나리오(3, 4, 6, 7, 9, 11, 12)는 끊긴 지점 앞에 묶인 서명 블록이 없고 이유 값이 기록되어야 한다. 시나리오 10 은 정책 제외 이유만 기록되고 `prefix_change` 는 하나도 기록되지 않아야 한다.
- 일부러 되돌려 보는 검사: 문맥을 요청 끝에 붙이고 이력에 남기지 않는 옛 코드로 되돌리면 1 이 실패해야 한다. 지문 비교를 빼면 3 이 실패해야 한다. 사슬 확인을 빼면 12 가 실패해야 한다.
- 속성 테스트: 이력이 같으면 한 번 뺀 앞쪽 블록이 되살아나지 않는다. 사슬 확인이 이 성질을 정책 제외 전이까지 넓힌다(시나리오 12).
- Anthropic 규칙을 흉내 내는 스텁 서버는 만들지 않는다. 문서를 읽은 우리 해석이지 Anthropic 이 아니고, 스텁이 통과해도 실제 통과를 뜻하지 않는다.

비결정적 (라이브, 수동):

- 기존 `packages/agent_core/test/anthropic_live_proof.ml` 은 두 턴 도구 왕복에서 서명 블록 재생을 확인한다(296-321줄). 어느 test alias 에도 걸려 있지 않고 `ANTHROPIC_LIVE=1` 과 키가 있어야 하며 비용이 든다. 여기에 턴별 문맥이 있는 두 라운드와 라운드 사이에 문맥 값을 바꾸는 경우를 더한다.
- 요청에 beta 헤더와 `thinking.block_binding.prefix_mismatch_behavior: "error"` 를 명시한다. 문서는 `"error"` 를 회귀를 크게 실패시키는 용도로 권한다. 이 값이 있으면 계정 나이와 상관없이 검사가 켜진다(문서 FAQ). Sonnet 5.5 와 Haiku 5.5 에서는 `thinking: {"type": "adaptive"}` 일 때만 동작하므로 증명도 adaptive 로 보낸다. 이 필드와 헤더를 보내는 코드가 지금 없으므로 요청 옵션을 타입으로 새로 만든다(`prefix_mismatch_behavior = Provider_default | Error_on_mismatch`). 운영 요청은 `Provider_default`(보내지 않음)다. 테스트 전용 뒷문이 아니라 증명이 쓰는 같은 옵션이다.
- 추가로 확인할 것 셋. (1) 열린 도구 라운드에서 마지막 assistant 메시지의 thinking 을 빼면 400 이 나는가(§3.4). (2) 우리의 앞쪽부터 빼기가 문서의 사슬 규칙과 일치하는지. 문서가 gap 을 무효로 적었으므로(§1.2-5) 유효성 질문이 아니라 일치 확인이다. 그리고 `redacted_thinking` 이 사슬에 드는가. 문서가 말하지 않아 확인하지 못했다(§3.4). 라이브 증명에서 두 가지를 모두 본다. (3) 지문 층 없이 #42677 만 있는 빌드에서, 턴별 문맥이 첫 라운드에만 붙는 도구 루프의 둘째 라운드가 400 을 받는가(§1.3-4, Q14).
- 현재 실행 제약: MASC 는 push 마다 CI 를 돌리지 않고 Release/Tag 에서 Full CI 를 돌린다(`instructions/masc-workflow.md`). 라이브 증명은 수동 실행이고 결과는 PR 본문에 실행 명령과 모델 이름·날짜로 남긴다. 실행하지 않은 증명의 통과를 적지 않는다.
- 모델이 thinking 블록을 아예 안 낼 수 있다(문서: 단순한 요청에는 생략). 블록이 없는 실행은 아무것도 증명하지 않으므로 실패가 아니라 "증명 못 함" 으로 보고한다.

## 4. 이행

### 4.1 저장된 이력

- 이 저장소는 데이터 형식이 바뀔 때 migration 이나 명시적 hard cut 중 하나를 고른다. hard cut 에서는 호환 읽기·변환 코드를 만들지 않는다. 이 규칙은 저장소 constitution 에 없고 운영자의 작업 지침(`~/me/instructions/workflow.md` "진입 장벽", 저장소 밖)에 있다.
- 이 RFC 는 `Reasoning_source` 를 바꾸지 않고 새 키를 더한다. 형식이 바뀌는 것이 없으므로 hard cut 도 migration 도 필요 없다. 옛 Anthropic 블록은 새 키가 없어 `Omit_binding_absent` 로 빠진다. 호환 코드가 아니라 재생 판정의 한 갈래다.
- 대안인 `Reasoning_source` v3(hard cut)를 고르지 않은 이유(§5): `of_json` 이 필드를 정확히 네 개만 받는다(`types.ml:439`). 필드를 더하면 모든 공급자의 저장된 출처가 `Absent` 가 된다. 저장된 v2 표식은 한 Keeper(polisher)의 이력 하나에 6,967개 있다(`~/.masc/traces/trace-1788310783225-00003/` 의 `trace-….json` 에서 `"agent_core.reasoning_source.v2"` 를 센 값. 같은 폴더의 snapshot 3개도 같은 이력의 사본이라 같은 수이고 합치지 않는다. 이 Keeper 는 계속 돌아서 값이 늘고 있다). Gemini 도 `Require_identical_source` 라서(`reasoning_dialect.ml:649`) Anthropic 만의 문제를 고치려고 다른 공급자의 저장된 추론까지 한 번 잃는다. 지문은 요청 앞부분에 대한 사실이고 출처는 만든 쪽에 대한 사실이라 같은 레코드에 둘 이유도 없다.
- 기존 체크포인트 파일은 고치지 않는다.

### 4.2 지금 실패하는 Keeper

- 한 번 실패한 Keeper 는 이후 매 턴 같은 400 으로 실패한다(§1.1). 이력에 남은 서명 블록과 지금 앞부분이 맞지 않기 때문이다.
- #42677 이 들어간 빌드에서는 이전 턴 thinking 이 빠지므로 옛 블록 때문에 나던 400 은 코드상 사라진다. 같은 턴 둘째 라운드에서 나는 400 은 남을 수 있다(§1.3-4). 배포 여부와 실제 효과는 확인하지 못했다.
- 지문 층이 배포되면 지문 키가 없는 옛 블록이 모두 빠지므로 첫 요청부터 앞부분 위반이 없다. 별도 복구 절차가 없다.
- 사용 한도 400 으로 멈춘 Keeper(2026-11-01 00:00 UTC 까지)는 이 RFC 로 풀리지 않는다.
- 배포 전에 풀려면 해당 Keeper 이력에서 thinking 블록을 지우는 것인데(문서: 지워도 유효), 운영 조치이고 이 RFC 의 범위가 아니다. 이슈에 따로 적는다.

### 4.3 PR 스택 (층마다 결과 하나, 층마다 테스트는 초록)

MASC 규칙에 따라 gh stack 으로 쌓고 맨 위 PR 로 스택째 병합한다(`masc-workflow.md`). 층마다 리뷰한다. 실패하는 테스트를 PR 에 넣지 않는다. 시나리오 테스트는 그것을 초록으로 만드는 층에 둔다.

| 층 | 결과 | 주요 파일 |
|---|---|---|
| 1 | 앞부분 대조 함수와 그 단위 테스트. 실제 체크포인트에 돌려 턴 경계마다 빠질 서명 블록 수를 정책 적용 전후로 세는 읽기 전용 보고 명령(§3.5 의 측정) | 새 순수 함수, 보고 명령 |
| 2 | 서명 블록은 지문이 맞을 때만 재생한다 (400 이 없어지는 층). 별도 키, 요청 객체의 지문, 재생 판정 `match`(정책 제외 `Omit_replay_policy_excluded`, 사슬 `Omit_chain_mismatch` 포함), 서명 사슬 필드 `thinking_predecessor`, 카탈로그 `thinking_binding`. 시나리오 3, 4, 6, 7, 9, 10, 11, 12 | `backend_anthropic.ml`, `types.ml`, `reasoning_dialect.ml`, `reasoning_history_projection.ml`, `models.toml` |
| 3 | 크기 증거가 있을 때만 짧은 창으로 다시 보낸다 (측정할 수 있는 공급자). 거절 뒤 `count_tokens`, `Size_refusal_measured`, `boundary_resend_on`. 측정할 수 있는 공급자의 `Unknown_invalid_request` 를 다시 보내지 않게 바꾸는 곳은 이 층뿐이고, Q1 의 답이 이 층의 동작을 정한다 | `retry.ml`, `keeper_turn_driver_try_provider.ml` |
| 4 | 알 수 없는 400 의 실패 값에 보낸 요청의 사실을 붙인다. 재전송 규칙은 바꾸지 않는다 | `retry.ml` 또는 오류 값, 실패 기록 |
| 5 | 턴별 문맥을 이력에 남기고(A, `Persisted_user_message`) 다른 공급자는 `Latest_at_tail` 로 그대로 둔다. 문맥 개수 점검을 고친다. 시나리오 1, 2, 5, 8 | `agent_turn.ml`, `keeper_agent_prompt_metrics.ml`, 창의 고정 규칙 |
| 6 | 와이어: beta 헤더 전송, `role: "system"` 메시지, `clear_at`, `prefix_mismatch_behavior` 옵션을 요청에 담을 수 있다. 기본 동작은 바뀌지 않는다 | `backend_anthropic.ml`, `Provider_config` |
| 7 | 지원하는 행은 B(`Turn_scoped_system`)로 그린다. Q3 확인 뒤에만 병합한다 | `models.toml`, 5·6 층 코드 |
| 8 | 라이브 증명 확장 (§3.6) | `anthropic_live_proof.ml` |

순서의 이유: 2층이 가장 먼저 400 을 없앤다. 문맥이 아직 끝에 붙고 사라지므로 이 시점에는 매 라운드 서명 블록이 빠지지만 요청은 거절되지 않는다. 5층이 라운드 사이 이어짐을 되살린다. 3·4층은 2층과 독립이라 앞서도 되고 뒤에도 된다. 4층을 3층보다 먼저 쌓아도 Q1 이 열려 있는 동안 안전하다. 4층은 실패 값에 사실을 붙일 뿐 재전송을 바꾸지 않고, 재전송 규칙이 바뀌는 곳은 3층뿐이다. Q1 에 아니라고 답하면 3층에서 `Unknown_invalid_request` 변경을 빼고, 4층은 그대로 남는다. 7층은 5·6층 뒤다.

system·tools 가 라운드마다 바뀌는 경로를 없애는 일은 이 스택에 넣지 않는다. 후속 이슈로 남긴다(§3.3).

### 4.4 열린 PR 과의 관계 (#42713, #42729)

읽은 곳: #42713 의 head `8b94bb037199d62655f376a8b6542fcbb4795a7f`, #42729 의 head `280d4ee9400cdca8d658bacb4a601cb48efe0f5b`. 2026-10-13 에 PR 의 파일 변경(`git diff`)을 읽었다. 둘 다 병합 전이다. 아래 줄 번호는 각 PR head 의 파일 기준이다. 두 PR 의 빌드·테스트 실행 결과는 읽지 않았다.

층별로 어디에 코드가 있고 어디가 정의하는가.

| 층 | 코드 | 정의 |
|---|---|---|
| 1, 3, 4, 6, 7, 8 | 아직 없음 | 이 RFC |
| 2 (지문과 재생 판정) | #42729: 기록 `backend_anthropic.ml:861-907`, 검증 `reasoning_history_projection.ml` 의 `verify_prefix_binding` | 이유 타입의 확장(`prefix_change`, `Omit_*`)과 서명 사슬 필드(`thinking_predecessor`)는 이 RFC 가 정의한다 |
| 5 (문맥을 이력에 남기기, A안) | #42713: `agent_turn.ml:35-57`, `pipeline.ml:276-286`·`:337`, `types.ml:325-342` | #42713 이 정본이다. 이 RFC 의 5층은 아래 표의 차이를 #42713 에 맞춘다 |

두 PR 의 순서: #42729 만 먼저 병합하면 안 된다. #42729 가 기록하는 요청 digest 는 첫 라운드에만 붙던 턴별 문맥을 포함한다(`backend_anthropic.ml:898-900` 의 `request_digest` 는 요청 메시지 전체의 마지막 digest 다). 둘째 라운드 요청에는 문맥이 없어서 `Prefix_request_mismatch` 가 되고 같은 턴 둘째 라운드부터 thinking 이 빠진다. 문맥을 이력에 남기는 #42713 이 먼저 들어가야 한다. 이것은 코드 읽기 추론이고 실행으로 확인하지 못했다.

이 RFC 와 두 PR 의 차이.

| 항목 | 이 RFC | #42713 | #42729 |
|---|---|---|---|
| 턴별 문맥을 이력에 남기는 때 | 문맥이 있을 때마다(§3.2) | Anthropic 응답에 서명 thinking 이나 redacted_thinking 이 있을 때만. 값을 `historical` 로 바꿔 남긴다(`pipeline.ml:276-286`, `:337`) | 하지 않음 |
| 서버 쪽 `drop_block` | 기본값으로 쓰지 않는다(§5) | adaptive Sonnet/Haiku 5.5 의 completion 요청마다 `block_binding.prefix_mismatch_behavior = "drop_block"` 과 beta 헤더를 보낸다(`backend_anthropic.ml:14-37`, `:665-682`) | 쓰지 않음 |
| 지문 재료 | system, tools, 메시지. thinking 블록은 뺀다(§3.4) | 해당 없음 | head(system 텍스트, tools 목록)와 모든 메시지 블록. 남아 있는 thinking 블록도 digest 에 든다(`reasoning_history_projection.ml:478-481`, `backend_anthropic.ml:421-435`) |
| 생성 뒤 앞쪽 thinking 을 빼는 경우 | 문서가 유효하다고 적으므로 남은 블록을 재생한다(§3.4 서명 사슬 확인) | 해당 없음 | 앞쪽 thinking 이 뒤 블록의 digest 에 들어 있어, 빼면 뒤 블록의 digest 가 달라져 `Prefix_request_mismatch` 로 빠진다. 코드 읽기 결과이고 실행 확인은 못 했다 |
| thinking 끼리의 순서(서명 사슬) | 있음(`thinking_predecessor`) | 해당 없음 | 없음 |
| 이유 타입 | `prefix_change` 6종과 `Omit_*` 갈래(§3.4) | 해당 없음 | `Prefix_source_not_present`, `Prefix_digest_absent`, `Prefix_entry_invalid`, `Prefix_entry_duplicate`, `Prefix_request_mismatch`, `Prefix_chain_broken_upstream`, `Prefix_reasoning_mismatch` 7종(`reasoning_history_projection.ml`) |
| 계정 라벨 | `credential_scope`(§3.4) | 해당 없음 | 없음 |
| 저장 태그가 손상된 경우 | 정하지 않았다 | 해당 없음 | 그 메시지의 thinking 만 `Prefix_entry_invalid` 또는 `Prefix_entry_duplicate` 로 버리고 요청은 만든다. 버림은 Warn 으로 남는다. 기존 `Reasoning_source` 투영 오류는 여전히 `invalid_arg` 를 던진다(`backend_anthropic.ml`, #42713 의 공유 계약) |
| tools 해시 | 정하지 않았다(Q16) | 해당 없음 | 순서 있는 목록 그대로 넣는다(`backend_anthropic.ml:421-435`). 문서는 tools 를 집합이라고 적는다. 순서가 바뀐 요청을 서버가 받아 주는지는 확인 못 함 |
| 메타데이터 키 | `agent_core.prefix_binding.v1`(§3.4) | `agent_core.extra_system_context.v1` 의 값만 바꿈 | `agent_core.reasoning_prefix.v1`, 필드 `request_digest`, `message_digest`(`types.ml` 의 `Reasoning_prefix`) |

- #42713 의 상시 `drop_block` 은 이 RFC §5 가 "긴급 완화용 `WORKAROUND:` 로만 허용"한 것과 다르다. 어느 쪽으로 정할지는 운영자 결정이다(Q15).
- 키 이름과 필드 이름은 #42729 의 코드가 이미 정했다. 이 RFC 의 이름과 맞추는 방법은 Q17 이다.

## 5. 검토한 대안

| 대안 | 얻는 것 | 버리는 것 / 기각 이유 |
|---|---|---|
| `drop_block` 을 기본값으로 | 코드를 거의 안 바꾼다. 요청이 항상 성공한다 | 앞부분이 바뀌는 원인을 안 고친다. 매 턴 버리면 출력 토큰이 늘어난다(§1.2-9, 우리 하네스 측정 없음). 문서도 임시방편이라 한다. 저장소의 워크어라운드 거부 기준과 맞지 않는다. 라이브가 지금 깨져 있을 때의 긴급 완화로는 가장 빠르다. 그때는 `WORKAROUND:` 라벨과 대체 RFC 번호(이 RFC)를 달아 따로 올린다 |
| 서명 400 문구를 읽어 thinking 을 빼고 한 번 더 보낸다 | 문서가 권하는 복구 순서와 같다 | 문구를 읽는 일이다. 문서가 문구는 바뀔 수 있다고 한다. 문자열 분류기 금지 |
| 서명 블록을 아예 보내지 않는다 (`No_replay`) | 가장 단순하다. 400 이 구조적으로 사라진다 | 모델이 지난 추론을 잃는다. 열린 도구 라운드의 마지막 assistant 턴은 thinking 을 그대로 돌려보내라고 문서가 말한다. 앞부분을 안정시킬 이유(캐시 적중)도 남는다 |
| 턴별 문맥을 `system` 으로 올린다 | 이력이 안 자란다 | `system` 이 바뀌면 모든 서명 블록이 무효다(§1.2). 가장 나쁜 자리다 |
| 턴별 문맥을 A(이력의 `User` 메시지)로만 | beta 도 와이어 변경도 필요 없다. 모든 행에서 같다 | 지난 문맥이 계속 보여 같은 대답을 되풀이할 위험(task-514)이 있고, 토큰과 저장이 턴마다 는다. 지원하지 않는 행(Sonnet 5 등)에서는 쓴다 |
| 턴별 문맥을 C(`clear_at` 없는 `role: "system"`) | 와이어가 B 와 같다 | A 의 비용에 B 의 권한 문제까지 진다. 이득이 없다 |
| 지문을 `Reasoning_source` 에 넣고 v3 으로 올린다 (hard cut) | 출처와 지문이 한 레코드다 | 모든 공급자의 저장된 추론이 한 번 빠진다(§4.1). 지문은 요청에 대한 사실이라 출처와 다른 사실이다. 별도 키는 추가만이라 컷도 호환 코드도 필요 없다. 별도 키의 단점은 두 키가 어긋날 수 있는 것인데 재생 조건이 둘을 모두 요구해서 어긋나면 뺀다 |
| 요청 전에 `count_tokens` 로 매번 크기를 잰다 | 크기 거절을 미리 안다 | `RFC-keeper-context-window-in-tokens` §1 결정 2 와 충돌한다. 매 요청에 호출이 하나 더 든다 |
| 이력 창을 없애 앞부분을 안 바꾼다 | 앞부분이 항상 안정된다 | 컨텍스트 한계가 있다. 창은 `RFC-keeper-context-window-in-tokens` 의 설계다 |
| 강등 경계를 바꿔 턴 사이 이어짐을 지킨다 | 턴 사이 추론을 지킨다 | 입력 토큰과 맞바꾼다. 얻는 이득을 아직 재지 못했다(§3.5). 측정 뒤 다시 연다 |
| 정책이 thinking 을 뺄 때 이력에 "뺐다" 표식을 남겨 사슬을 지킨다 | 뺀 사실이 이력에 남는다 | 정책이 제외한 시점에 그 요청이 실제로 나가지 않았으면 표식이 사실과 다르다. 투영이 이력을 쓰게 되어 순수 함수가 아니게 된다. 정책을 풀어도 표식을 되돌릴 수 없다. 대신 만든 때의 `thinking_predecessor` 를 기록하고 보낼 때 비교한다(§3.4) |
| system·tools 값을 저장해 세션 동안 고정한다 | 바뀔 일이 없다 | 운영자의 `base_system_prompt` 수정이 숨는다. 저장 위치와 갱신 규칙이 새로 필요하다(§3.3) |

## 6. 열린 질문과 위험

운영자가 정해야 할 것:

- **Q1.** 크기 거절이 문장만 있는 400 으로 오고 `count_tokens` 로도 가려지지 않으면, 측정할 수 있는 공급자에서 그 거절이 보이게 실패한다. 받아들이는가, 아니면 다른 증거를 찾는가.
- **Q2.** 측정할 수 없는 공급자(OpenAI 호환, Ollama, Gemini, GLM)의 `Unknown_invalid_request` 재전송을 지금 그대로 둔다(§2). 이 공급자들의 문제를 별도 RFC 로 낼 것인가.
- **Q13.** 지문 층이 들어간 뒤에도 #42677 의 재생 강제를 Anthropic 행에 유지할 것인가. (a) 유지한다. 이전 턴 thinking 은 계속 빠지고, 입력 토큰이 줄며, 추론 이어짐은 턴 안에만 남는다. (b) 행마다 `reasoning_replay = "preserve_always"` 를 적어 푼다. 지문이 맞는 이전 턴 thinking 만 다시 가고, 모델이 이전 추론을 다시 본다. 출력 토큰이 얼마나 줄지는 잰 값이 없다. 추천은 (a) 로 시작하는 것이다. 1층의 보고 명령이 "정책을 껐을 때 지문이 맞는 서명 블록의 비율"을 내고 8층 라이브 증명이 통과하면 행 하나(`claude-sonnet-5-5`)부터 (b) 로 연다. 이유: 지금은 앞부분이 유지되는 비율을 모르고(§3.5), #42677 은 품질과 비용 영향을 재지 않았다. 푸는 일은 카탈로그 한 줄이라 되돌리기도 쉽다. 단, (b) 전환은 서명 사슬 확인(§3.4 의 선행자 검사)이 구현되기 전에는 정책 해제로 되살아난 오래된 블록이 그 사이 만든 블록을 무효로 만들어 400 을 낼 수 있다(§3.6 시나리오 12).
- **Q15.** #42713 은 adaptive Sonnet/Haiku 5.5 요청마다 서버 쪽 `drop_block` 을 보낸다. 이 RFC §5 와 비목표는 `drop_block` 을 기본값으로 쓰지 않고, 긴급 완화에만 `WORKAROUND:` 라벨과 대체 RFC 번호를 달아 허용한다. 상시 `drop_block` 을 받아들일지는 운영자 결정이다.

조사로 닫을 것:

- **Q3.** 턴별 문맥 블록 중 바깥에서 온 글(도구 출력, 웹 내용, 사용자 입력)이 섞인 것이 있는가. 있으면 B 를 쓸 수 없다. B 를 병합하기 전에 블록별로 확인한다.
- **Q4.** 이력에 남기는 저장량(§3.2). 블록 단위 주소 저장을 쓸지, 원문 저장으로 시작할지.
- **Q5.** vincent 키 계정이 2026-08-31 이후 생성인가. 틀리면 §1.3 의 원인들이 vincent 만 실패하는 이유를 설명하지 못한다. 층 1 의 대조가 가른다. 같은 계정에서 키만 바꿨을 때 `credential_scope` 라벨이 같아도 괜찮은지도 같이 본다.
- **Q6.** 창 시작점이 움직이는 빈도와 강등으로 빠질 추론의 크기(§3.5). 자주 움직이면 서명 재생이 턴 안 이어짐 외에는 꺼진다.
- **Q7.** 서버 쪽 compaction·context editing 은 앞부분 편집이 아니라고 문서가 적는다. masc 의 Librarian 요약이 어디에 해당하는지, 고정 구간을 어떻게 다룰지 정해야 한다. 직접 쓴 요약이 남긴 턴의 thinking 은 실패한다고 문서가 말한다.
- **Q8.** Gemini 는 `reasoning_dialect.ml:534` 의 주석이 서명 파트를 그대로 돌려보내야 한다고 적는다. 같은 모양의 문제가 있는지 이 RFC 가 보지 않았다.
- **Q9.** 사용 한도 400 과 temperature 400 의 응답 헤더와 구조 필드. 본문 문장은 구했다(§1.1). 구조 필드가 있으면 §3.6 에 변형을 더한다.
- **Q10.** 도구 목록이 라운드마다 달라지는 두 경로(§1.3-5)와 `defer_loading` 으로 옮기는 방법. 후속 이슈다.
- **Q11.** `clear_at` 메시지가 도구 결과 user 메시지 앞에 오는 위치 제약(§1.2-11)이 우리 문맥 위치(user 입력 바로 뒤)에서 지켜지는지 실제 요청으로 확인한다.
- **Q12.** 지문 비교의 요청당 비용(직렬화·해시). 이력이 클 때 얼마인지 재지 않았다.
- **Q14.** #42677 만 적용된 빌드에서 같은 턴 둘째 라운드가 400 을 받는가(§1.3-4 의 추론). 지문 층 없이 `prefix_mismatch_behavior: "error"` 로 턴별 문맥이 있는 두 라운드 도구 루프를 보내 확인한다. 400 이 나면 2·5층의 우선순위가 올라간다. 안 나면 §1.3-1 의 설명을 다시 읽어야 한다. 요청 본문 쪽 증거는 #42713 의 `docs/evidence/2026-10-13-anthropic-thinking-prefix/diagnosis.json`(glossary-maniac 요청 #2326/#2327: system·tools 동일, 이전 문맥 블록이 다음 요청에서 사라짐)에 이미 있어 라이브 호출 없이 반쯤 닫혀 있다.
- **Q16.** tools 를 지문 재료로 넣을 때 순서를 어떻게 다루는가. 문서는 tools 를 집합이라고 적고, #42729 는 목록 순서 그대로 해시한다. 순서만 바뀐 요청을 서버가 받는지는 확인하지 못했다. 받는다면 정렬해서 넣는 쪽이 불필요한 지문 변화를 줄인다.
- **Q17.** 메타데이터 키와 필드 이름을 어떻게 맞추는가. #42729 는 `agent_core.reasoning_prefix.v1`(`request_digest`, `message_digest`)을 쓰고 이 RFC 는 `agent_core.prefix_binding.v1`(`prefix_fingerprint`, `credential_scope`, `thinking_predecessor`)을 쓴다. 구현 때 한쪽으로 맞춘다.

위험:

- A 는 이력을 키운다. B 도 저장을 키운다. 키우는 양을 재기 전에 5층을 병합하면 창이 더 자주 움직이고 §3.5 의 손실이 커진다.
- 요청 본문을 로그로 남기지 않아 지문 불일치의 원인을 사후에 가려내기 어렵다. 불일치 지점(`prefix_change`)은 기록하되 본문 전체를 로그에 남기는 일은 이 RFC 가 정하지 않는다. 본문에는 사용자 데이터가 있다.
- 지문이 우리 JSON 기준이라 서버가 다르게 읽는 경우를 못 잡는다. 계정 불일치와 서버 쪽 규칙 변경이 그렇다. 라이브 증명이 잡을 수 있는 범위만 잡는다.
- 이 RFC 는 공식 문서 2026-10-13 판에 기댄다. 문서가 바뀌면 지문의 범위(thinking 블록 제외 등)를 다시 읽어야 한다.

## 7. 테스트 계획과 합격 기준

| 층 | 기준 | 방법 |
|---|---|---|
| 1 | 대조 함수가 `Append_only`·`Broke` 를 낸다. 같은 JSON 은 키 순서와 공백이 달라도 `Append_only` 다 | 단위 테스트 |
| 1 | 보고 명령이 실제 체크포인트에서 턴 경계마다 빠질 서명 블록 수를 출력한다 | 수동 실행. 출력값은 §3.5 의 미측정 칸을 채운다 |
| 2 | 시나리오 3, 4, 6, 7, 9, 11 에서 끊긴 지점 앞에 묶인 서명 블록이 없고 이유가 기록된다. 시나리오 10 에서는 `Omit_replay_policy_excluded` 만 기록되고 `prefix_change` 는 없다. 시나리오 12 에서는 `T1` 이 `Omit_chain_mismatch` 로 빠지고 `T2` 가 재생된다 | 오프라인 하네스 |
| 2 | 속성: 정책을 요청마다 바꿔도 보내는 thinking 블록은 원래 순서의 끊기지 않는 구간이다. 정책과 이력이 같으면 한 번 뺀 앞쪽 블록이 되살아나지 않는다 | 속성 테스트 |
| 2 | 재생 판정의 `match` 에 `_ ->` 갈래가 없다. 새 변형을 더하면 컴파일이 깨진다 | 컴파일 |
| 2 | 일부러 지문 비교를 빼면 시나리오 3 이 실패한다 | 되돌려 보는 검사 |
| 3 | 측정할 수 있는 공급자에서 `Unknown_invalid_request` 는 `boundary_resend_on` 이 false 다. 측정할 수 없는 공급자에서는 지금처럼 true 다 | 공급자마다 값을 넣는 표 기반 테스트. 새 변형을 더하면 컴파일이 깨진다 |
| 3 | `count_tokens` 가 `max_context` 를 넘는 값을 주면 `Size_refusal_measured` 로 시작점이 옮겨지고, 넘지 않으면 옮겨지지 않는다 | 가짜 측정기를 넣는 단위 테스트 |
| 3 | receipts 에서 구한 사용 한도·temperature 문장을 넣은 요청이 시작점을 옮기지 않는다 (문장은 입력일 뿐 분류에 쓰지 않는다) | 고정 입력 테스트 |
| 4 | 알 수 없는 400 의 실패 값에 재생한 서명 블록 수와 지문 일치 여부가 붙는다 | 단위 테스트 |
| 5 | 시나리오 1, 2, 5 에서 `Append_only` 이고 보낸 서명 블록 수가 만든 수와 같다. 시나리오 8 에서 `tools` 가 있고 `tool_choice: none` 이다 | 오프라인 하네스. 문맥을 옛 방식으로 되돌리면 1 이 실패해야 한다 |
| 5 | 다른 공급자의 요청 본문이 바뀌지 않는다 | 공급자별 본문 스냅샷 비교(`packages/agent_core/test/test_snapshot_provider_serialization.ml` 가 쓰는 방식) |
| 6 | 기본 설정으로 만든 요청 본문이 이 층 앞과 같다 | 스냅샷 비교 |
| 7 | 지원하는 행의 요청에 `role: "system"`, `clear_at`, beta 헤더가 있고 지원하지 않는 행에는 없다 | 스냅샷 비교 |
| 8 | 라이브: 카탈로그 행마다 문맥이 있는 두 라운드에서 `prefix_mismatch_behavior: "error"`, adaptive thinking 으로 앞부분 위반 400 이 0 이다. 서명 블록이 안 나온 실행은 "증명 못 함" 이다 | 수동 실행. 명령·모델·날짜를 PR 본문에 남긴다. 실행하지 않았으면 통과라고 적지 않는다 |
| 8 | §3.6 의 세 가지 추가 확인(열린 도구 라운드, 중간 블록만 빼기, #42677 만 있는 빌드의 둘째 라운드)의 결과를 적는다 | 수동 실행 |

전체 합격 기준:

- 오프라인 하네스에서 끊김이 없어야 하는 시나리오(1, 2, 5)는 모두 `Append_only` 이고 만든 서명 블록을 전부 재생한다. 끊김이 기대되는 시나리오는 모두 이유와 함께 블록을 뺀다. 시나리오 10 은 정책 제외 이유만 남긴다.
- 크기 증거가 없는 400 에서 측정할 수 있는 공급자의 시작점 이동이 테스트에서 0 이다.
- 라이브 증명에서 앞부분 위반 400 이 0 이다. 실행한 모델과 날짜를 적는다.
- 1.1 의 Keeper 4개가 배포 후 첫 요청부터 서명 400 없이 진행하는지는 운영 관찰이다. 합격 기준에 넣지 않고 배포 후 이슈에 적는다.

## 부록 A. 인용 위치 확인 (`361883ee64` 와 `origin/main` `4cc7ed1ebf`, 2026-10-13)

두 커밋 사이는 84 커밋이다. 본문의 `파일:줄` 은 오른쪽 열(`4cc7ed1ebf`)을 쓴다. 이슈 #42636 의 인용과 처음 쓴 기준 `361883ee64` 의 값을 같이 적는다.

| 인용 | 이슈 #42636 | `361883ee64` | `4cc7ed1ebf` | 비고 |
|---|---|---|---|---|
| `agent_turn.ml` 문맥 붙임 | `:34-54` | `:34-53` (`:52` 가 `messages @ [ system_msg ]`) | `:34-53` | 같음. 이슈보다 한 줄 짧다 |
| `pipeline_stage_prepare.ml` | `:148-153` | `:148-155` | `:148-155` | 같음. 경로는 `packages/agent_core/lib/pipeline/` |
| `retry.ml` 400, 422 | `:340` | `:340-341` | `:340-341` | 같음 |
| `boundary_resend_on` (`keeper_turn_driver_try_provider.ml`) | `:2515-2540` | `:2511-2539` | `:2542-2570` | 줄만 밀림(+31) |
| 같은 파일의 `refusal_evicts` | | `:2323` | `:2354` | 줄만 밀림 |
| 같은 파일의 주석(크기 거절이 문장만 있는 400 으로 온다) | | `:2494-2510` | `:2525-2541` | 줄만 밀림 |
| 같은 파일의 `turn_boundary_resend_sequence`, `restore_front before` | | `:2564`, `:2596` | `:2595`, `:2627` | 줄만 밀림 |
| 같은 파일의 강등 경계 `demote_before` | | `:1540-1547` | `:1543-1550` | 줄만 밀림(+3) |
| 같은 파일의 `ordinary_demote_before` (`Wide` 처리) | | `:1177-1187` | `:1179-1189` | 줄만 밀림(+2) |
| Anthropic 재생 갈래 (`reasoning_dialect.ml`) | `:520-523` | `:521` (`replay_policy = All_assistant_messages`) | `:523` (`apply_replay_override`), `:527` | #42677 이 `:523` 을 넣었다. 선언을 따르는 코드다 |
| `rotation_policy` 의 `Require_identical_source` | | `:635-652`, Anthropic·Gemini 줄 `:643` | `:641-658`, 같은 줄 `:649` | 줄만 밀림(+6) |
| Gemini 서명 파트 주석 | | `:528` | `:534` | 줄만 밀림(+6) |
| 재생 강제 `with_client_history_replay` (`lib/runtime/runtime_adapter.ml`) | | 없음 | `:608`, 강제 `:635`, 선언 우선 `:637` | #42677 이 넣었다 |
| `api_common.ml` | `:364-379` | `:364-379` | `:364-379` | 같음 |
| `types.ml` `Reasoning_source` | `:383-420` | `:341-420` (`rotation_admits` `:401`, 필드 4개 `:439`, `assistant_message_of_response` `:839`) | 같음 | 범위를 넓혀 적음 |
| `reasoning_history_projection.ml` | | `replay_selected` `:204-220`, `project` `:222`, `rotation_admits` 호출 `:258` | 같음 | 같음 |
| `runtime_model_input_tail_window.ml` | `:4` | `:4` (`atoms_per_window = 60`), `is_extra_context` `:122` | 같음 | 같음 |
| `keeper_run_tools_hooks.ml` | | `before_turn_hook` `:810`, `post_tool_round` `:937`, `for_request` `:998`, `cache_rank` `:1121`, `String.length ctx` `:1276` | 같음 | 같음 |
| `keeper_carried_front.mli` | 있음 | 있음 | 있음 | 같음. 문서 주석만 바뀜 |
| `packages/agent_core/models.toml` | | 첫 `reasoning_replay` 선언 `:588` | 같음 | 같음 |
| 스냅샷 테스트 | | `packages/agent_core/test/test_snapshot_provider_serialization.ml` | 같음 | 본문 §7 에 전체 경로를 적음 |

- 이 표에 든 파일 중 두 커밋 사이에 바뀐 것은 `keeper_turn_driver_try_provider.ml`(#42602, 요청 범위 기록을 더함. 인용한 코드의 뜻은 그대로이고 줄만 밀렸다), `reasoning_dialect.ml`(#42677), `runtime_adapter.ml`(#42677), `keeper_carried_front.mli`(문서 주석), `docs/spec/00-glossary.md` 다. 나머지는 줄이 같다. 확인한 방법은 `git diff 361883ee64 origin/main -- <파일>` 이다.
- `boundary_resend_on` 의 끝 줄은 `;;` 위치로 다시 센 값이다.
- 이름을 확인한 곳(`4cc7ed1ebf` 기준): `Prompt_context_carrier_repeated` 는 `lib/keeper/keeper_agent_prompt_metrics.ml:51`·`:64`·`:180` 에 있다. `Runtime_model_input_tail_window.is_extra_context` 는 `lib/runtime/runtime_model_input_tail_window.ml:122` 에 있다. `Prompt_block_id.cache_rank` 는 `lib/types/prompt_block_id.ml:56` 에 있다. `Token_measurement_unavailable` 는 `Retry.input_capacity_reason` 의 변형이다(`packages/agent_core/lib/llm_provider/retry.ml:12`).
- 이 RFC 가 제안하는 이름은 코드에 없다. `prefix_binding`, `prefix_mismatch_behavior`, `block_binding` 은 이 RFC 파일을 뺀 `origin/main` 의 `lib packages test docs bin` 어디서도 나오지 않는다(`git grep` 으로 확인). `anthropic-beta` 는 테스트 한 곳(`packages/agent_core/test/test_exact_output_single_surface.ml:778`)에만 나온다.
- 새 메타데이터 키 `agent_core.prefix_binding.v1` 을 나열하거나 지우는 코드가 있는지: 이름으로 `agent_core.*` 키를 지우는 곳은 못 찾았다. 체크포인트는 메시지 메타데이터를 키 구분 없이 JSON 으로 쓰고 읽는다(`packages/agent_core/lib/checkpoint_codec.ml:486-515`, `lib/keeper/keeper_context_core_message_json.ml:143`). 값이 JSON 으로 인코딩되지 않을 때만 값을 버리는 곳이 하나 있다(`checkpoint_codec.ml:784-794`). `Input_speaker.without`(`types.ml:272`)와 `keeper_approval_input_admission.ml:55` 는 각자 자기 키 하나만 지운다. 새 메시지를 `metadata = []` 로 만드는 곳(`keeper_next_request_forecast.ml:385` 등)은 새 메시지라 해당하지 않는다. 확인하지 못한 것: 기존 메시지를 복사하면서 메타데이터를 통째로 버리는 경로가 `lib packages` 전체에 없다는 것은 모든 파일을 읽어 확인하지 않았다. 그 경로가 있으면 지문 키가 사라져 `Omit_binding_absent` 로 빠진다. 요청이 거절되지는 않고 추론만 잃는다.

다시 확인하는 명령(`4cc7ed1ebf` 기준):

```
rg -n "messages @ \[ system_msg \]" packages/agent_core/lib/agent/agent_turn.ml
rg -n "Unknown_invalid_request" packages/agent_core/lib/llm_provider/retry.ml | head -3
rg -n "let boundary_resend_on|restore_front before" lib/keeper/keeper_turn_driver_try_provider.ml
rg -n "replay_policy = All_assistant_messages|apply_replay_override" packages/agent_core/lib/llm_provider/reasoning_dialect.ml
rg -n "with_client_history_replay|Force_latest_user_turn_tool_calls" lib/runtime/runtime_adapter.ml
rg -n "^reasoning_replay" packages/agent_core/models.toml | head -1
rg -n "supports_completion_request_measurement" packages/agent_core/lib/llm_provider/count_tokens_sync.ml
rg -n "Keeper_agent_tool_surface.for_request" lib/keeper/keeper_run_tools_hooks.ml
git grep -n -E "prefix_binding|prefix_mismatch_behavior|block_binding" origin/main -- lib packages test docs bin
```

## 부록 B. 디렉터리와 번호

- `packages/agent_core/docs/rfc/` 에 둔다. 번호 `RFC-AC-041` 은 이 디렉터리의 마지막 번호 `RFC-AC-040` 다음이다. 열린 PR 검색(`gh pr list -R jeong-sik/masc --state open --search "RFC-AC-041"`)에서 같은 번호가 나오지 않았다.
- 이유: 규칙의 중심이 agent_core 에 있다. 요청 본문을 만드는 `backend_anthropic.ml`, 재생 규칙 `reasoning_dialect.ml`, 저장 출처 `types.ml`, 오류 분류 `retry.ml` 이 모두 agent_core 다. 이어받는 RFC-AC-029(재생 표준)와 RFC-AC-040(카탈로그 소유)이 같은 디렉터리에 있다. keeper 쪽 변경(`boundary_resend_on`, 창, 강등, hook)은 소비자이고, RFC-AC-029 §6 의 경계 원칙(agent_core 는 typed 사실을 내고 MASC 가 쓴다)을 따른다.
- `docs/rfc/` 는 새 RFC 에 번호를 발급하지 않고 `RFC-<slug>.md` 만 받는다(`docs/rfc/README.md`). 번호를 달라는 요구와 맞지 않는다. keeper 쪽 구현 층이 별도 설계 판단을 낳으면 그때 `docs/rfc/` 에 slug RFC 를 따로 쓰고 이 RFC 를 `related` 로 건다.
- 변경 기록 조각(`changelog.d/<PR 번호>.md`)은 PR 번호가 필요하다. 이 RFC 는 로컬 커밋이라 PR 번호가 없어 만들지 않았다. `changelog-fragments.py missing` 은 알림이지 거절이 아니다. PR 을 열 때 필요한지 다시 본다.
