---
rfc: "size-refusal-starts-fresh-then-cuts-to-the-floor"
title: "크기 거절 뒤에는 세션을 버리고, 그래도 넘치면 floor로 자른다"
status: Draft
created: 2026-11-09
updated: 2026-11-09
author: claude
supersedes: []
superseded_by: null
related: ["retained-results-carrier-shrinks-to-an-address", "claude-code-context-overflow-bounded-restart", "keeper-context-window-in-tokens", "official-client-conversation-in-masc"]
---

# RFC: 크기 거절 뒤에는 세션을 버리고, 그래도 넘치면 floor로 자른다

줄 번호는 `498d0415b59` 기준이다.

## 1. 결정

규칙은 하나다.

> official-client lane에서 효과 전에 typed 크기 거절이 오면, 다시 보내는 요청은 정해진 단계를 하나씩 내려간다. Resume이 거절되면 vendor 세션을 버린 fresh Start를 보낸다. Start가 거절되면 모든 부분을 가장 작은 꼴로 자른 floor Start를 보낸다. floor가 거절되면 끝낸다.

- 크기를 재서 단계를 고르지 않는다. 들어가는지는 provider가 판정한다(§3).
  - 보내기 전에 provider가 센 수로 합산해 판정하는 일은 다음 RFC다(§12, #50445). 합산은 틀릴 수 있다. 그래서 이 단계는 그 뒤에도 거절 뒤의 답으로 남는다.
- 거절이 한도를 숫자로 주면 그 숫자만 쓴다. Codex `input_too_large`의 `max_chars`다.
  - masc는 다음 단계의 `turn/start` 글을 provider와 같은 방식으로 센다. 한도를 넘는 단계는 건너뛴다(§7).
- 그래서 run 하나의 다시 보내기는 많아야 두 번이다.
- floor로 갈 때 한 부분의 floor 꼴을 만들지 못하면(묶음 blob 쓰기 실패 등), 그 부분만 지금 꼴로 두고 floor를 보낸다. 실패는 typed 결과에 싣는다(§8, #50170).

바뀌는 것:

- official-client lane에서 history 반 자르기와 중간 view가 없어진다. Start 거절 다음은 floor다.
- 묶음·memory·recall block이 「내 글이 짧아졌나」로 다시 보낼지 정하던 판정을 official-client lane에서는 쓰지 않는다. floor가 네 부분을 한꺼번에 가장 작은 꼴로 바꾼다.
- Resume 거절 뒤 fresh Start는 carried range 전체, 묶음 `Inline`, memory 그대로 간다.
  - 지금은 hook이 묶음이나 memory를 먼저 바꾼다. 바꿨으면 range 전체로 간다. 아무것도 못 바꿨으면 Claude Code는 보내지 않은 range를 재서 반으로 줄인다(§6).
- Codex에도 floor capacity가 생긴다. Claude Code에는 이미 있다.
- Codex `input_too_large`는 가짜 413 대신 provider가 준 숫자를 타입으로 싣는다(§4).
  - Start는 다시 보내지 않는다. 세션 기록은 `Input_rejected Bootstrap_floor_exceeded`이고, 다음 claim을 막는다.
  - Resume은 fresh Start 글이 한도 안일 때만 보낸다. 세션 기록은 `Provider_rejected`다.
  - 둘 다 masc가 거절된 글을 센 값이 `actual_chars`와 같을 때다. 다르면 숫자를 쓰지 않고 단계를 내려간다(§7).
- hook 실패를 원래 거절로 덮지 않는다. agent_core도 그 실패를 버리지 않고 싣는다.

그대로인 것:

- lane walk다. 줄이기 단계는 끝날 때 마지막 거절을 돌려준다(§9).
- 세션 기록 갈래다. 새 갈래를 만들지 않는다.
- receipt 쓰기·ACK 규칙, Librarian, Gate continuation(같은 run에서 다시 보내지 않는다)이다.
- agent_core lane의 줄이기다. RFC-keeper-context-window-in-tokens가 정한다(§10).

## 2. 일어난 일

- 11-08 #49853~#50004가 묶음 단계를 세 runtime에 넣었다. 묶음(carrier)은 끝나지 못한 vendor 턴이 남긴 도구 결과 기록(receipt) 모음이다.
- 11-09 #50263은 Codex `input_too_large`에서 묶음 단계를 건너뛰게 했다. 운영자가 「하드코딩·SSOT 위반·휴리스틱 아닌가」라고 짚었다. 코드와 대조하니 맞았고, 병합 전에 닫았다.
  - 거절 종류로 바꿀 부분을 고르는 갈래를 손으로 썼다.
  - Codex lowering이 `input_too_large`를 `Request_body_refused_by_provider { status = 413 }`으로 바꾼다(`keeper_codex_runtime.ml:721-728`). 413은 온 적이 없다. 거절이 준 `{actual_chars; max_chars}`는 버린다.
  - 묶음만 고치고 memory·history는 #50255로 넘겼다.
- 이 RFC의 첫 안은 「거절된 요청을 거절이 잰 방식으로 다시 재서, 엄격히 작을 때만 보낸다」였다.
  - 그 안은 masc가 보내는 글을 바이트로 쟀다. 창 거절은 provider 토큰으로 센다.
  - 단위만 다른 것이 아니었다. official-client 요청은 CLI가 조립해서, masc가 쥐지 않은 몫도 같이 간다(§3).
  - 운영자는 그 비교가 어색하다고 봤다. provider 셈과 100% 맞출 수 없으니 맞추려 하지 말고, 자르고 새로 시작하자고 정했다.
  - 그다음 Resume 거절 뒤 바로 floor로 갈지 물었다. 운영자는 세션만 먼저 버리고, 그다음 floor로 가는 쪽을 골랐다.

## 3. 왜 재지 않나

**masc는 official-client 요청 전부를 provider 단위로 잴 수 없다.**

- 창 거절은 모델이 읽는 전부를 provider 토큰으로 센다. 숫자를 주지 않는다.
  - Claude Code는 거절 문장에 토큰 수를 적는다. 문장은 읽지 않는다(문자열 분류).
- official-client lane에서 요청은 CLI가 조립한다. masc가 넘기지 않은 몫도 같이 간다.
  - Claude Code: 시스템 프롬프트 자리는 masc 파일로 바꾼다(`--system-prompt-file`, `runtime_claude_code.ml:2883`). MCP 도구 정의는 masc가 SDK 서버로 넘긴다(`:769-773`, `:2826-2841`). 내장 도구 정의는 CLI가 넣는다. `--tools`로 고른 것이다(`:2897`). 그 정의들을 요청에 어떤 꼴로 싣는지는 CLI가 정한다.
  - Codex: 시스템 쪽으로 masc가 넘기는 것은 `developerInstructions`와 `dynamicTools`다(`runtime_codex_app_server.ml:2588-2598`). base instructions는 Codex가 넣는다. masc가 연 thread의 rollout `session_meta.base_instructions`에 그 글이 있다(`docs/evidence/task-362-bundle/codex-rollout-01a05969.jsonl:1`).
  - Resume에서는 vendor가 쥔 세션 기록도 간다. masc는 그 기록을 보지 못한다(`keeper_official_client_host.mli:44-58`).
- masc 글은 provider 셈 API로 토큰을 셀 수 있다.
  - agent_core lane은 Anthropic·Kimi provider에서 보내기 전에 그렇게 판정한다(`count_tokens_sync.ml:151-158`).
  - 그 밖의 provider는 config에 serving constraint가 없으면 바이트로만 판정한다(`Body_only`, `runtime_agent_context.ml:199-206`).
  - official-client 요청에 이 셈을 써도 CLI가 더하는 몫은 빠진다.
- Codex `input_too_large`는 `turn/start` 글만 Unicode scalar로 센다. 묶음·memory·history는 Codex Start의 그 글에 없다(§7).
- 그래서 「다시 보낼 요청이 provider 단위로 작다」를 masc가 보내기 전에 증명할 길이 없다. 첫 안의 바이트 비교가 보이는 것은 「다르고, masc 글이 바이트로 작다」뿐이다.

**중간 view는 거절만 쌓았다.**

- 2026-09-05 keeper geek-scout에서 4.1 MB history가 128k 토큰 모델에 1.9 MB, 507 KB, 498 KB로 차례로 거절됐다. floor는 묻지 않은 채 `Bootstrap_floor_exceeded`로 기록됐다(`keeper_turn_driver_try_provider.ml:3098-3107`).
- #31684에서는 줄일 수 없는 몫(도구 schema, 시스템 프롬프트)이 469,638 B였다. capacity를 131,072와 65,536으로 줄인 view가 턴마다 세 번 거절됐다. 어느 것도 들어갈 수 없었다(`:3115-3123`).
- RFC-keeper-context-window-in-tokens는 HTTP lane의 반 자르기를 2026-09-19에 버렸다(그 RFC 305행, §13.3). 「거절 사유를 못 읽는 것과 크기를 모르는 것은 다르다」고 적었다.

**floor는 생각보다 덜 버린다.**

- floor는 history의 대화 atom을 모두 뺀다. durable checkpoint 원문은 그대로다.
- Librarian working state와 unread state, 지금 runtime 맥락, System 줄은 pinned라서 floor에 남는다(`runtime_model_input_tail_window.ml:124-133`). Librarian이 흡수한 요약은 floor에도 실린다.

## 4. typed 거절 (L1)

| 거절 | 무엇을 세나 | 단위 | 숫자 | 오는 곳 |
|---|---|---|---|---|
| 창 | 모델이 읽는 전부 | provider 토큰 | 없음 | Claude Code `terminal_reason`, Codex `contextWindowExceeded`, agent_core `ContextOverflow` |
| 본문 | HTTP 본문 | 바이트 | 없음(status만) | agent_core의 진짜 HTTP 413(`retry.ml:380`) |
| turn text | `turn/start` 글 | Unicode scalar | `actual_chars`, `max_chars` | Codex `input_too_large`(`runtime_codex_app_server.ml:441-465`) |

- `Agent_core.Retry.invalid_request_reason`에 `Input_text_over_limit of { actual_chars : int; max_chars : int }`를 더한다. 뜻은 「provider가 턴의 text 입력을 Unicode scalar로 세어 거절했다」다.
- Codex lowering은 이 reason을 만든다. 가짜 `status = 413`은 지운다. `Request_body_refused_by_provider`는 진짜 HTTP 413에만 남는다.
- `Candidate_fault.of_api_error`는 새 reason을 `Binding Body_limit`로 둔다(`candidate_fault.ml:41`). 지금 가짜 413이 받는 판정과 같아서, lane 후보를 넘기는 동작이 그대로다.
- 관측은 지금 가짜 413을 `Provider_request_body_refusal { status = 413 }`으로 적는다(`keeper_turn_runtime_budget.ml:82-85`). 새 reason은 글자 수와 한도를 그대로 적는다.
- reason을 나열한 곳은 새 reason을 `_` 없이 다룬다. `is_size_refusal`(`keeper_turn_driver_try_provider.ml:3002-3046`), `boundary_resend_on`, event JSON, `retry.ml`의 판정들이다.

## 5. 단계 (L2)

| 거절된 요청 | 다음 요청 | 바뀌는 것 |
|---|---|---|
| Resume | fresh Start | vendor 세션을 버린다. range 전체, 묶음 `Inline`, memory는 그대로다 |
| Start(첫 Start 또는 fresh Start) | floor Start | 네 부분이 가장 작은 꼴로 간다 |
| floor Start | 없음 | 마지막 거절을 돌려준다 |

**floor의 네 부분**

| 부분 | floor 꼴 | 코드 |
|---|---|---|
| history | 줄일 수 있는 atom을 모두 뺀다. pinned 줄과 생략 안내(preamble)만 남는다 | `Runtime_model_input_tail_window.minimum_capacity_bytes` |
| 묶음 | `By_address`다. `By_address` 글이 `Inline`보다 짧지 않으면 `Inline`에 둔다 | `switch_to_address`(`keeper_client_tool_outbox.ml:444-470`) |
| host memory recall | 고른 행을 모두 미룬다(`capacity_deferred`, 행 0개) | `defer_for_capacity`(`keeper_workspace_memory_host_recall.ml:137-168`) |
| recall block | 미룬 상태 줄 | `defer_for_capacity`(`keeper_memory_recall_blocks.ml:55-73`) |

- 네 부분을 한꺼번에 바꾼다.
  - 지금 hook 사슬은 처음 바뀐 부분에서 멈춘다(`carrier_reprojection ~then_`, `keeper_client_tool_outbox.ml:472-475`; `keeper_run_tools_hooks.ml:707-713`).
  - host memory는 지금 행을 반씩 줄인다. floor는 하나도 남기지 않는다.
- 묶음의 두 꼴 비교는 그 부분의 두 꼴 가운데 짧은 쪽을 고를 뿐이다. 요청이 작아졌다고 주장하지 않는다. host memory와 recall block 안의 비교도 같다.
- Claude Code는 floor capacity를 이미 센다(`keeper_claude_code_runtime.ml:134-137`). 그 값을 `final_shrink_capacity`로 넘긴다(`:1810-1811`).
- Codex는 floor를 세지 않는다. `final_shrink_capacity`를 넘기지 않아서, 반 자르기가 history 0까지 내려간다. L2가 Claude Code와 같은 floor 계산을 `record_next_shrink_capacity`(`keeper_codex_runtime.ml:118-146`)에 더한다.
- 어떤 부분도 바뀌지 않으면 floor는 거절된 요청과 같다. 그때는 보내지 않고 끝낸다.
  - 뺄 atom, receipt, memory 행, 미룰 block이 하나도 없을 때다.
  - 있어도 작은 꼴이 지금 꼴보다 짧지 않을 때다(`runtime_model_input_tail_window.ml:344`, `keeper_client_tool_outbox.ml:460`, `keeper_workspace_memory_host_recall.ml:158-165`, `keeper_memory_recall_blocks.ml:69-74`).
  - bounded-restart RFC §5의 「floor와 현재 view가 같으면 provider를 다시 호출하지 않는다」와 같다.

**걸음**

- `context_overflow_shrink_sequence`(`keeper_turn_driver_try_provider.ml:3065-3138`)가 위 표를 따른다.
- 반 자르기에만 쓰는 값은 지운다. `context_overflow_shrink_divisor`, `default_context_overflow_shrink_capacity`, `shrink_capacity`, `shrink_admits_history`, `next_shrink_capacity_bytes` 관측이다.
  - 부르는 곳은 official-client lane 두 곳뿐이다(`keeper_codex_runtime.ml:118-146`, `:191-202`, `:2143-2152`; `keeper_claude_code_runtime.ml:110-137`, `:1806-1817`). L2가 시험까지 찾아 확인하고 지운다.
- 다시 보낼 때마다 지금처럼 `resolve_input_rejected_for_shrink_retry`로 막는 기록을 푼다.
- 같은 run 재시도 허락(`same_run_retry_authorized`)은 그대로다. 효과·응답 뒤, Completion review, Gate continuation은 다시 보내지 않는다.
- floor 쓰기는 floor를 보내기 바로 앞에만 한다. floor를 보내지 않고 끝나는 run은 아무것도 쓰지 않는다.

## 6. Resume (L2)

지금 Resume 거절 뒤 다시 보내는 요청은 늘 fresh Start다(`keeper_codex_runtime.ml:1990-1998`, `keeper_claude_code_runtime.ml:694-697`). 이 RFC는 그 fresh Start의 꼴만 정한다.

- fresh Start는 range 전체, 묶음 `Inline`, memory 그대로 간다.
  - Resume에서 넘친 것은 vendor가 쥔 세션일 수 있다. masc가 보내지 않은 range를 줄일 근거가 없다.
- 지금은 두 runtime 모두 Resume 거절에 hook을 먼저 부른다(`keeper_codex_runtime.ml:2116-2121`, `keeper_claude_code_runtime.ml:1787-1792`).
  - 묶음이나 memory가 바뀌면(`Reprojected`) 같은 capacity로 간다. 그 capacity는 처음 값 `max_int`다. 그래서 fresh Start는 range 전체와 바뀐 꼴로 간다(`keeper_turn_driver_try_provider.ml:3088-3090`, `keeper_codex_runtime.ml:99`, `keeper_claude_code_runtime.ml:59`).
  - 아무것도 바뀌지 않으면(`Unchanged`) 반 자르기의 다음 capacity로 간다(`keeper_turn_driver_try_provider.ml:3091-3134`). 묶음은 `Inline`이다.
  - 이 RFC 뒤로는 hook을 부르지 않는다.
- Codex에서 그 다음 capacity는 반 자르기의 첫 걸음이고, 그 걸음이 range 전체를 싣는다(`keeper_codex_runtime.ml:191-202`). 그래서 range는 지금과 같다. 이 RFC 뒤로 fresh Start는 처음 Start처럼 capacity 제한 없이 간다.
- Claude Code에서 그 다음 capacity는 반이다. Resume도 range를 projection하고, 보내지 않은 그 range를 재서 정한다(`keeper_claude_code_runtime.ml:110-137`, `:1806-1809`, `:1850-1866`). 이 RFC 뒤로는 range 전체다.
- fresh Start가 거절되면 §5대로 floor로 간다.

**#50263과 다른 점**

- #50263은 거절 종류를 보고 바꿀 부분을 골랐다.
- 이 단계는 거절 종류를 보지 않는다. 거절된 요청이 Resume인지, Start인지, floor인지만 본다.
- 쓰는 숫자는 provider가 준 `max_chars` 하나다(§7).

**Gate continuation**

- Gate continuation의 Resume은 잡힌 thread로만 간다. 같은 run에서 다시 보내지 않는다(`keeper_codex_runtime.ml:2130-2142`).
- 창 거절이면 지금처럼 `Vendor_session_full`로 끝난다(`keeper_codex_runtime.ml:856-864`).
- `input_too_large`면 L1 뒤로 `Provider_rejected`가 된다. Gate는 `Vendor_session_full`일 때만 끝나고, 다른 실패는 Gate를 다시 걸어 둔다(`keeper_turn.ml:900-947`). 그래서 다음 continuation이 같은 거절을 받는다. #50398로 남긴다.

**세션 기록 이름은 바꾸지 않는다**

- Gate가 아닌 Resume의 창 거절은 `Input_rejected Bootstrap_floor_exceeded`로 적힌다(`keeper_codex_runtime.ml:832-841`, `keeper_claude_code_runtime.ml:531-541`). 같은 run에서 `resolve_input_rejected_for_shrink_retry`가 바로 푼다.
- 이름은 사실과 다르다. Resume은 floor를 보낸 적이 없다.
- 이름을 바꾸면 Gate continuation이 그 기록을 제 것으로 읽을 수 있다(`keeper_direct_gate_continuation.ml:447-475`). #50368로 남긴다.

## 7. Codex `input_too_large` (L1, L3)

| 요청 | `turn/start` 글 |
|---|---|
| Start | start_context(Goals_awaiting_proof, Completion_authority)와 goal(`Host.start_prompt`, `keeper_official_client_host.ml:217`) |
| Resume | composed context, Librarian working state, 지난 task 참조와 goal(`resume_prompt`, `keeper_codex_runtime.ml:1162-1171`) |

- floor의 네 부분은 Start의 이 글에 없다. history와 묶음은 `thread/inject_items`로, memory는 `developerInstructions`로 간다. 그래서 floor Start의 글은 fresh Start의 글과 같다.
- masc는 이 글을 `prompt_char_count`로 센다(`runtime_codex_app_server.ml:424-439`). Codex `text_char_count`와 같은 셈이다.

**숫자를 쓰기 전에 대조한다**

- masc가 거절된 요청의 글을 센 값이 `actual_chars`와 같을 때만 `max_chars`를 쓴다.
- 다르면 masc의 셈은 provider의 셈이 아니다. 숫자를 쓰지 않고, 숫자 없는 거절처럼 단계를 내려간다.
  - 요청은 Start에서 하나(floor), Resume에서 둘까지(fresh Start, floor) 더 든다.

**Start**

- 다음 단계는 floor다. floor의 글은 거절된 Start의 글과 같아서 한도를 넘는다. 그래서 floor를 건너뛰고 끝난다.
- 세션 기록은 `Input_rejected Bootstrap_floor_exceeded`다. floor의 글이 거절됐으니 참이다.
  - 다음 claim은 운영자가 풀 때까지 막힌다(`keeper_official_client_session_store.ml:1513-1519`). 창의 floor와 같다.
  - 막지 않으면 goal과 관측이 그대로인 동안 cycle마다 같은 거절을 받는다. 그때마다 Codex는 persistent thread를 새로 만들어 남긴다(`keeper_codex_runtime.ml:1672`). memory 선택 판정도 모델에 다시 묻는다(`keeper_workspace_memory_host_recall.ml:186`).
  - #49634의 잠김과 다르다. 그때는 묶음을 줄이면 들어갈 요청에 floor 기록을 남겼다. 이 기록은 floor의 글이 한도를 넘을 때만 남는다.

**Resume**

- 다음 단계는 fresh Start다. 그 글이 `max_chars` 안이면 보낸다.
- 넘으면 floor도 같은 글이라 넘는다. 둘 다 건너뛰고 끝난다.
- 세션 기록은 `Provider_rejected`다. Resume의 글은 floor가 아니다. 다음 claim은 fresh plan을 받는다(`keeper_official_client_session_store.ml:1536-1548`).
  - 그래서 Start 글도 넘는 경우, 다음 cycle이 fresh Start를 보내 같은 거절을 받고 그때 막힌다(§12).
  - 그 run 안에서 기록을 `Input_rejected`로 다시 쓸 수는 없다. 까닭은 §8과 같다.

## 8. floor 꼴을 만들지 못할 때 (#50170)

- 지금 hook이 `Error`를 돌려주면 official 줄이기 단계는 원래 거절을 돌려준다(`keeper_turn_driver_try_provider.ml:3087`).
  - 그 attempt가 남긴 `Input_rejected Bootstrap_floor_exceeded`가 같은 runtime의 다음 claim을 막는다. floor에는 닿지 않았다.
  - 실패 내용은 반환값에 남지 않는다. 로그는 recall block만 남긴다(`keeper_memory_recall_blocks.ml:61-63`).
- hook의 `Error`는 쓰기 실패만이 아니다.
  - 묶음: 도구 이름 읽기(`tool_name_of`), 주소 marker 만들기(`make_artifact_ref`), blob 쓰기(`keeper_client_tool_outbox.ml:450-463`)
  - host memory: 미루기 기록 쓰기, 그 사이 projection이 바뀐 경합(`keeper_workspace_memory_host_recall.ml:140-142`, `:159-164`)
  - recall block: 미룬 상태 줄 만들기(`keeper_memory_recall_blocks.ml:60-64`)
- 이 RFC 뒤로 floor의 한 부분이 floor 꼴을 만들지 못하면, 그 부분만 지금 꼴로 남긴다. 까닭은 가리지 않는다. 나머지 부분은 바뀌고 floor는 간다.
  - 묶음이 실패하면 묶음은 `Inline`으로 floor에 실린다.
  - memory가 실패하면 memory는 지금 꼴로 실린다.
  - 모든 부분이 실패해 floor가 거절된 요청과 같으면 §5대로 보내지 않고 끝낸다.
  - floor가 받아들여지면 막는 기록이 남지 않는다. 실패는 typed 결과에 남는다.
  - floor가 거절되면 `Input_rejected Bootstrap_floor_exceeded`가 남는다. 그 run에서 masc가 만들 수 있는 가장 작은 요청이 거절됐다는 뜻이다.
- 새 세션 전이는 만들지 않는다.
  - `State_persistence_failed`로 다시 적을 수 없다. 거절된 attempt는 이미 제 claim을 `Recovery_required`로 정산했다. 저장소는 `Recovery_required`에서 다시 `Recovery_required`로 가는 것을 거절한다(`keeper_official_client_session_store.ml:1936-1937`). Codex `require_recovery`는 그 상태면 아무것도 쓰지 않는다(`keeper_codex_runtime.ml:1482-1488`).
  - run을 `Internal` 같은 오류로 끝내면 창이 더 큰 다음 lane 후보를 시도하지 않는다. typed 창 거절은 다음 후보로 넘어가지만(`keeper_turn_driver.ml:743-750`), `Internal`은 후보 판정에 들지 않고 rotation도 없다(`keeper_turn_driver_try_runtime.ml:28-39`, `keeper_runtime_attempt.ml:112-113`). #50170도 이 까닭으로 그 길을 버렸다.
- agent_core도 hook 실패를 버린다. `memory_capacity_retry_sequence`가 `Error`에 `on_projection_failure`를 부르고 원래 거절을 돌려준다(`keeper_turn_driver_try_provider.ml:3347-3358`).
  - hook은 실패를 결과 값의 한 칸으로 돌려준다. 두 줄이기 단계는 그 칸을 run 결과로 옮긴다. 시험이 그 칸을 읽는다.
  - agent_core의 다시 보내기 정책은 바꾸지 않는다. 실패 뒤 같은 run의 다른 다시 보내기를 막는 `projection_failed`(`:3386-3393`)는 그대로다.

## 9. 끝날 때

- 줄이기 단계는 마지막 거절을 그대로 돌려준다. 그래서 lane walk의 판정이 지금과 같다(`lane_should_retry`, `keeper_turn_driver.ml:730-762`).
  - 창 거절은 `context_overflow_should_try_next`로, Codex `input_too_large`는 `attempt_rejected_should_try_next`(`keeper_turn_driver_try_runtime.ml:115`)로 다음 lane 후보에 넘어간다.
  - 다른 lane 후보는 한도가 다르다. 같은 입력을 받을 수 있다.
- 걸어온 단계와 끝난 까닭은 줄이기 단계의 typed 결과에 따로 싣는다. 관측과 시험이 이것을 읽는다.
  - 마지막으로 거절된 단계: Resume, Start, floor
  - 끝난 까닭: floor가 거절됐다 / floor가 거절된 요청과 같다 / 남은 단계가 provider 한도를 넘는다 / 같은 run 재시도가 허락되지 않는다
  - floor 꼴을 만들지 못한 부분과 그 까닭
- 새 recovery 갈래는 만들지 않는다. 있는 갈래로 기록이 참이 된다(§7, §8). 새 갈래가 없어도 durable truth는 손상되지 않는다.

## 10. agent_core

- agent_core lane은 이 RFC 밖이다. 줄이기는 RFC-keeper-context-window-in-tokens가 정한다.
- 묶음 hook(carrier RFC §5.1)과 memory hook은 agent_core에서 지금처럼 자기 글로 판정한다.
- 이 RFC가 agent_core에 닿는 것은 둘이다. 새 reason을 `_` 없이 다루는 것(§4), hook 실패를 싣는 것(§8)이다.
- antigravity와 muse에는 크기 거절 다시 보내기가 없다(carrier RFC §7).

## 11. runtime별로 바뀌는 것

| 거절 | 지금 | 이 RFC 뒤 |
|---|---|---|
| Claude Code Start 창 | 묶음 → memory → history 반 자르기를 차례로 거쳐 floor까지 | 다음 요청이 floor다 |
| Claude Code Resume 창 | hook이 묶음이나 memory를 바꾸면 fresh Start를 range 전체와 바뀐 꼴로 보낸다. 못 바꾸면 보내지 않은 range의 반 capacity와 `Inline`으로 보낸다 | fresh Start를 range 전체와 `Inline`으로 보낸다. 거절되면 floor |
| Codex Start `contextWindowExceeded` | Claude Code Start와 같다. floor가 없어 반 자르기가 history 0까지 간다 | 다음 요청이 floor다 |
| Codex Resume `contextWindowExceeded` | fresh Start를 range 전체로 보낸다. hook이 묶음이나 memory를 바꾸면 바뀐 꼴로, 못 바꾸면 `Inline`으로 간다 | Claude Code Resume과 같다 |
| Codex Start `input_too_large` | 가짜 413으로 묶음·memory·history를 차례로 바꾸며 같은 글을 다시 보낸다. 세션에는 `Protocol_failed`가 남는다 | 다시 보내지 않는다. 세션에는 `Input_rejected Bootstrap_floor_exceeded`가 남는다. masc 셈이 `actual_chars`와 다르면 floor를 한 번 보낸다 |
| Codex Resume `input_too_large` | Start와 같은 경로를 fresh Start로 간다 | fresh Start 글이 `max_chars` 안이면 보낸다. 아니면 끝난다. 세션에는 `Provider_rejected`가 남는다. masc 셈이 다르면 숫자 없이 단계를 내려간다 |
| floor 꼴을 만들지 못할 때 | 원래 거절로 끝난다. floor에 닿지 않았는데 막힌다 | 그 부분만 지금 꼴로 두고 floor를 보낸다. 실패는 typed 결과에 남는다 |
| Gate continuation | 창은 `Vendor_session_full`. `input_too_large`는 `Protocol_failed`로 Gate를 다시 건다 | 창은 같다. `input_too_large`는 `Provider_rejected`이고 되풀이는 그대로다(#50398) |
| agent_core | hook이 자기 글로 판정한다. 다시 보내기는 RFC-keeper-context-window-in-tokens를 따른다 | 같다. hook 실패만 결과에 싣는다 |

## 12. 대가와 가정

**대가**

- 조금 넘쳐도 그 턴은 floor로 간다. 그 턴의 모델은 지난 대화 atom을 보지 못한다. Librarian 상태와 durable history는 남는다(§3).
  - 묶음만 넘친 경우도 그렇다. carrier RFC는 같은 capacity에서 묶음만 바꿔 history를 지켰다. 이제는 floor에서 history도 잘린다.
  - 그 턴의 `Completed`가 receipt를 지운다. 다음 턴은 다시 range 전체로 간다.
- Claude Code에서 Resume 거절 뒤 fresh Start는 range 전체다. 지금은 hook이 아무것도 못 바꾸면 반이다. 그래서 거절이 한 번 더 생길 수 있다. 그다음은 floor다.
- Codex Start `input_too_large`는 같은 runtime을 통째로 막는다.
  - goal이나 관측이 바뀌어 들어갈 다음 턴도 운영자가 풀 때까지 기다린다.
  - 막힘을 episode 단위로 좁히는 일은 bounded-restart RFC §6.2의 fence 몫이다. 그 fence는 아직 없다(Phase C).
- Codex Resume `input_too_large`에서 fresh Start 글도 한도를 넘으면 cycle 하나를 더 쓴다. 그 cycle은 persistent thread 하나를 만들고, memory 선택 판정으로 모델에 한 번 더 묻는다.
- floor 꼴을 만들지 못한 부분이 있으면 floor가 그만큼 크다. 그 floor가 거절돼도 `Bootstrap_floor_exceeded`로 막힌다. 운영자는 그 실패를 typed 결과에서 본다.

**가정**

1. masc는 floor보다 작은 요청을 만들지 못한다. floor가 들어가는지는 provider가 판정한다.
2. masc의 `prompt_char_count`는 Codex의 셈과 같다. 거절마다 `actual_chars`로 대조한다(§7).
3. masc가 넘긴 것이 provider 요청에 다 실렸다는 증명은 없다(`keeper_official_client_host.mli:44-58`). 단계는 크기를 재지 않으니 이 가정에 기대지 않는다.

**다음 RFC (#50445)**

- 보내기 전에 「지난 요청의 provider 수 + 이번에 더해지는 몫」을 창과 비교한다. 창을 넘을 단계는 보내지 않고 다음 단계로 간다.
- 받아들여진 요청 뒤에는 provider가 그 요청 전체를 센 수가 올 수 있다. CLI 몫과 세션 기록도 그 수에 들어 있다. 수가 왔을 때만 쓴다.
  - Claude Code: 가장 최근 요청의 `latest_request_input`(input, cache creation, cache read)이 `Some`일 때다(`runtime_claude_code.ml:168-212`).
  - Codex: `thread/tokenUsage/updated`의 `last`가 `Request_usage`일 때다(`runtime_codex_app_server.ml:119-121`).
  - Codex에서 수가 아닌 것: `Context_estimate`는 Codex의 추정이다. 창을 채운 턴(`Thread_count_replaced`)에는 `last`가 없다. frame이 없던 턴은 `None`이다(`:128-135`, `:186-188`). 2026-09-25 frame 29,088개에서 추정이 266개, 채움이 332개였다(`:137-143`).
  - 창 크기 `model_context_window`도 `int option`이다(`:189`).
- 먼저 usage 기록으로 CLI 몫이 턴마다 얼마나 흔들리는지 잰다. Claude Code 창 크기를 어디서 읽을지도 확인해야 한다.
- 합산은 틀릴 수 있다. 그래서 이 RFC의 단계는 그 뒤에도 거절 뒤의 답으로 남는다.

## 13. 버린 방법

1. **거절된 요청을 다시 재서 엄격히 작을 때만 보내기**(이 RFC의 첫 안)
   - 장점: 조금 넘친 턴이 history를 더 지킨다.
   - 단점: 창 거절은 provider 토큰으로 센다. official-client 요청에는 masc가 쥐지 않은 몫이 있다(§3). 그래서 첫 안은 masc 글을 바이트로 쟀다. 그 비교가 보이는 것은 「다르고, 바이트로 작다」뿐이다.
   - 단점: attempt를 그리기와 보내기로, hook을 제안과 확정으로 나눠야 했다. 코드가 크게 는다.
2. **바꾼 부분이 거절이 센 자리에 있는지만 보기**
   - 장점: 크기를 재지 않는다. #50263처럼 센 자리 밖의 부분을 바꾸는 일을 막는다.
   - 단점: runtime마다 어느 부분이 어느 요청 칸에 실리는지 알아야 한다. 그 지식이 runtime 밖으로 흩어진다. 그 자리에 있어도 들어갈지는 여전히 모른다.
3. **거절 종류로 바꿀 부분 고르기**(#50263)
   - 장점: 바꾸는 곳이 하나다.
   - 단점: 손으로 쓴 갈래다. 부분이 실리는 자리가 바뀌면 조용히 틀린다.
4. **반 자르기와 중간 view 남기기**(지금)
   - 장점: 조금 넘친 턴은 history를 더 지킨다.
   - 단점: 거절은 크기를 알려 주지 않는다. 중간 view는 거절만 쌓았다(§3). HTTP lane은 이미 버렸다.
5. **묶음만 바꾸는 단계를 floor 앞에 두기**(carrier RFC의 동작)
   - 장점: 묶음만 넘친 턴이 history를 지킨다.
   - 단점: 그 단계가 들어갈지 masc는 모른다. 묶음이 거절이 센 자리에 없으면(Codex `input_too_large`) 같은 거절을 한 번 더 받는다. 단계를 하나 더 둘 근거가 측정이 아니다.
6. **Resume 거절 뒤 바로 floor로 가기**
   - 장점: Start도 넘칠 때 거절이 한 번 준다.
   - 단점: Resume에서 넘친 것은 vendor가 쥔 세션일 수 있다. 들어갈 range까지 자른다. 운영자가 세션을 먼저 버리는 쪽을 골랐다.
7. **typed 크기 거절이면 바로 끝내기**
   - 장점: 가장 단순하다.
   - 단점: #49634의 잠김이 돌아온다. 묶음만 넘쳐도 Keeper가 멈춘다.
8. **provider 셈 API로 다시 보낼 요청 세기**
   - 장점: provider 단위다. agent_core lane은 Anthropic·Kimi에서 이미 그렇게 판정한다(§3).
   - 단점: masc 글만 센다. CLI가 더하는 내장 도구 정의·base instructions와 Resume의 세션 기록이 빠진다(§3). 셀 때마다 요청이 하나 더 든다.
   - 지난 요청의 provider 수로 그 빈칸을 메우는 일은 다음 RFC다(§12, #50445).
9. **vendor 세션 파일로 Resume 크기 재기**
   - 단점: vendor 내부 형식이다. 모델 입력이 아닌 메타데이터까지 센다. CLI 판이 바뀌면 깨진다.
10. **Codex Start `input_too_large`를 막지 않기**(`Provider_rejected`)
    - 장점: goal이나 관측이 바뀌면 다음 턴이 바로 들어간다.
    - 단점: 그대로인 동안 cycle마다 같은 거절을 받는다. thread가 하나씩 남고, memory 판정이 모델에 다시 묻는다. 창의 floor와 다르게 다룰 까닭이 없다.
11. **floor 꼴 실패를 run 오류로 끝내기**
    - 장점: 오류가 실제 원인을 말한다.
    - 단점: 그 기록을 쓸 수 없다(§8). lane walk가 다음 후보를 시도하지 않는다.
12. **새 recovery 갈래 만들기**
    - 단점: 있는 갈래로 기록이 참이 된다(§9).

## 14. TLA+ 모델

`specs/bug-models/SizeRefusalRetryAdmission.tla`

- 요청은 두 칸이다. turn 칸(Codex `turn/start` 글)과 나머지 칸이다. 묶음·memory·history는 각각 한 칸에 실린다.
  - `Layouts`는 모든 배치다(8가지). 지금 runtime이 쓰지 않는 배치도 TLC가 돈다.
  - goal 크기(`FixedTurnSizes`)와 나머지 칸의 고정 몫(`FixedSideSizes`)을 run마다 고른다.
  - Resume으로 시작하는 run은 Resume 글 크기(`ResumeTurnSizes`)와 vendor 몫(`VendorSizes`)도 고른다.
  - 묶음 blob 쓰기가 되는지(`blobOk`)도 고른다.
- 거절은 둘이다.
  - turn text 거절은 turn 칸만 세고 한도(`TurnLimit`)를 알린다. provider는 이것을 먼저 본다.
  - 창 거절은 Start면 두 칸을, Resume이면 Resume 글과 vendor 몫을 센다. 한도를 알리지 않는다.
- 정상(`Next`, 약한 공정성)
  - `Send`: 지금 단계의 요청을 보낸다.
  - `StepDown`: 거절되면 다음 단계로 간다. 한도를 알린 거절 뒤에는 turn 글이 한도를 넘는 단계를 건너뛴다. floor로 갈 때만 floor 꼴을 쓴다.
  - `End`: 남은 단계가 없으면 끝난다.
- 지키는 것
  - 성질 `EveryResendStepsDown`: 다시 보내는 요청은 늘 아래 단계다.
  - 성질 `NoResendOverTheBound`: 한도를 알린 거절 뒤에 보내는 요청은 turn 글이 그 한도 안이다.
  - 성질 `FreshStartCarriesEverything`: Resume 거절 뒤 fresh Start는 모든 부분을 처음 꼴로 싣는다.
  - 불변식 `WritesOnlyForTheFloor`: floor 꼴 쓰기는 floor 단계에서만 일어난다.
  - 불변식 `EndsOnlyWhenNoRungIsLeft`: 끝나는 것은 남은 단계가 없을 때뿐이다.
  - 불변식 `NoPrematureEnd`: provider가 받았을 floor를 두고 끝나는 run은 없다. blob 쓰기가 실패한 floor도 따진다.
  - 성질 `RunEnds`: 모든 run이 받아들여지거나 끝난다.
- 버그는 여섯이다. 각각 `Next \/ 버그 동작`이다.
  - `ResendTheRefusedRung`: 거절된 요청을 그대로 다시 보낸다.
  - `SendOverTheBound`: 한도를 알린 거절 뒤에, turn 글이 한도를 넘는 단계를 보낸다. 지금 Codex `input_too_large` 줄이기가 그렇다.
  - `EndBeforeTheFloor`: Start의 창 거절 뒤 floor를 묻지 않고 끝난다.
  - `EndOnWriteFailure`: floor로 갈 때 blob 쓰기가 실패하면 끝난다. #50170의 지금 동작이다.
  - `WriteBeforeChoosing`: floor로 가기 전에 floor 꼴을 쓴다. 지금 hook이 Resume 거절에 묶음을 바꾸는 것이 그렇다.
  - `CutOnTheSessionDrop`: Resume 거절 뒤 fresh Start가 history를 반으로 줄여 간다. 지금 Claude Code에서 hook이 아무것도 못 바꿀 때가 그렇다.
- 모델에 없는 것
  - 효과 뒤의 거절이다. 같은 run에서 다시 보내지 않는다.
  - `actual_chars` 대조다. 모델의 masc 셈은 provider 셈과 늘 같다.
  - floor가 거절된 요청과 같은 경우다. 모델의 floor는 늘 memory를 미룬다.
  - 묶음 밖 부분의 floor 꼴 실패와 실패의 까닭(쓰기, 경합, 렌더)이다. 묶음 blob 쓰기 실패(`blobOk`)로 대표한다.

TLC 1.8.0으로 로컬에서 돌렸다. 플래그는 `scripts/tla-check.sh`와 같은 `-deadlock -coverage 1`이다. 정상 cfg는 CI처럼 `-workers auto`로, 버그 cfg는 `-workers 1`로 돌렸다. 일꾼이 하나면 너비 우선으로 찾은 가장 짧은 반례가 늘 같다. 상수는 cfg 일곱이 같다(`TurnLimit` 35, `WindowLimit` 200, goal 20·40, 나머지 고정 몫 30·90·190, Resume 글 30·50, vendor 몫 20·200, 묶음 40·5, memory 40·5, history 32·4).

| cfg | 결과 |
|---|---|
| `SizeRefusalRetryAdmission.cfg` | 상태 1,736개(처음 상태 480개), 위반 없음(exit 0). `Send`·`StepDown`·`End`가 모두 일어난다 |
| `-resend-refused-buggy.cfg` | `EveryResendStepsDown` 위반(exit 13). Resume(글 30, vendor 몫 200)이 창 230으로 거절되고, 같은 Resume을 다시 보낸다 |
| `-over-bound-buggy.cfg` | `NoResendOverTheBound` 위반(exit 13). Resume 글 50이 한도 35로 거절되고, turn 글이 132인 fresh Start를 보낸다 |
| `-skip-floor-buggy.cfg` | `EndsOnlyWhenNoRungIsLeft` 위반(exit 12). 세 부분이 나머지 칸에 있고 blob 쓰기가 실패한다. Start가 창 222로 거절되고 끝난다. floor(창 159)는 들어간다 |
| `-write-failure-buggy.cfg` | `NoPrematureEnd` 위반(exit 12). Resume 글 50이 한도 35로 거절된다. fresh Start 글 92는 건너뛰고 floor(글 29)로 간다. blob 쓰기가 실패하자 끝난다. 묶음이 `Inline`인 floor(글 29, 창 99)는 들어간다 |
| `-commit-first-buggy.cfg` | `WritesOnlyForTheFloor` 위반(exit 12). Resume이 창 230으로 거절되고, Resume 단계에서 floor 꼴을 쓴다 |
| `-cut-on-drop-buggy.cfg` | `FreshStartCarriesEverything` 위반(exit 13). Resume이 거절되고, fresh Start가 history 32 대신 16을 싣는다 |

- 표의 cfg 이름은 앞의 `SizeRefusalRetryAdmission`을 줄였다.
- TLC는 `[][A]_v` 꼴 성질의 위반을 exit 13으로 낸다. `scripts/tla-check.sh`는 12와 13을 모두 위반으로 본다. 어느 성질이 깨졌는지는 보지 않아서, 표의 성질 이름은 로그로 따로 맞췄다.
- 정상 모델이 비어 있지 않은지도 봤다. 아래 일곱을 「일어나지 않는다」는 임시 불변식으로 두고 TLC를 돌리면 모두 깨진다(exit 12). 곧 일곱 모두 일어난다.
  - 받아들여지는 run
  - 끝나는 run
  - Resume 거절 뒤 fresh Start가 받아들여지는 run
  - floor가 받아들여지는 run
  - blob 쓰기가 실패해 묶음이 `Inline`인 floor가 받아들여지는 run
  - 한도 때문에 fresh Start를 건너뛰고 floor로 가는 run
  - floor를 보내지 않고 끝나는 run

## 15. 다른 RFC에서 바뀌는 문장

이 PR이 두 RFC의 아래 문장을 고친다.

**RFC-retained-results-carrier-shrinks-to-an-address**

| 자리 | 지금 | 고친 뒤 |
|---|---|---|
| §1 | typed 크기 거절이 오면 hook이 묶음을 `By_address`로 한 번 바꾸고 같은 capacity로 다시 보낸다. 그다음 거절은 history를 줄인다 | official-client lane에서는 Start가 거절되면 floor에서 `By_address`가 된다. agent_core lane은 hook이 바꾼다. 본문의 official-client 걸음 설명은 이 RFC 전의 동작이라고 밝힌다 |
| §1의 결과 | 넘친 턴은 같은 턴 안에서 다시 보내진다 | Codex Start `input_too_large`는 다시 보내지 않고 막힌다(이 RFC §7) |
| §4.3 | hook이 꼴을 바꿀 때 blob을 쓴다 | official-client lane에서는 floor가 같은 함수로 꼴을 바꾼다. 절의 「hook」은 그 floor도 뜻한다 |
| §5.1 | official 줄이기 단계가 hook을 부른다 | official 줄이기 단계는 hook을 부르지 않는다. floor로 갈 때 묶음 꼴을 바꾼다 |
| §5.2 | 같은 capacity로 다시 보낸다. Codex `input_too_large`는 `Protocol_failed`로 기록된다 | official-client lane에는 같은 capacity 다시 보내기가 없다. `input_too_large`는 Start면 `Input_rejected Bootstrap_floor_exceeded`, Resume이면 `Provider_rejected`로 기록된다 |
| §5.3 | Resume `Inline`이 넘치면 hook이 꼴을 바꾼다 | fresh Start가 `Inline`으로 간다. 그 Start가 거절되면 floor에서 바뀐다 |
| §5.4 | 다음 일반 턴에서 hook이 꼴을 바꾼다 | 다음 일반 턴의 floor에서 바뀐다 |
| §7 | Claude Code와 Codex의 typed 크기 거절이 hook에 닿는다 | 그 두 lane에서는 단계가 답한다(이 RFC §5, §7) |
| §9 | blob 쓰기가 실패하면 history를 줄여 보지 않고 끝난다 | official-client lane에서는 묶음만 `Inline`으로 두고 floor가 간다(이 RFC §8) |
| §10 | 모델이 hook과 history 반 자르기를 본다 | official-client lane의 걸음은 이 RFC의 모델이 본다 |
| §11의 2 | 「floor에서만 꼴 바꾸기」를 버렸다 | official-client lane은 이 방법을 받아들였다. 중간 view가 없어져 버린 까닭이 사라졌다 |
| §12 | 고정한 assertion은 바꾸지 않는다. PR B 시험은 history 줄이기와 Resume 꼴 바꾸기를 고정한다 | 이 RFC가 그 시험 일부를 바꾼다(이 RFC §16) |

**RFC-claude-code-context-overflow-bounded-restart**

| 자리 | 지금 | 고친 뒤 |
|---|---|---|
| §1의 3·4 | 더 작은 history view, 제한된 중간 view 뒤 floor | full 다음 view는 floor 하나다 |
| §4.1 | carrier 꼴만 바뀐다. 첫 typed 거절에서 엄격히 짧으면 바뀐다 | memory delivery 꼴도 바뀐다. 둘 다 floor에서 바뀐다 |
| §4.2, §4.3 | carrier 꼴만 identity에서 빼고 view에 적는다 | memory delivery 꼴도 같다 |
| §5 | full → carrier view → midpoint 둘 → floor. halving 횟수로 bound | Resume → fresh Start → floor. 다시 보내기는 많아야 두 번 |
| §6.3 | next view가 strictly smaller다. floor rejection이 마지막이다 | 다음 단계가 있다. §5의 글자 한도 예외가 같이 적용된다 |
| §8 | recoverable은 더 작은 view를 시도 중이다. floor에는 carrier가 늘 `By_address`로 실린다 | recoverable은 다음 단계를 시도 중이다. floor 꼴을 만들지 못한 부분은 지금 꼴로 실린다. Codex `input_too_large`는 floor를 보내지 않고 기록한다. blocker에 memory delivery 꼴을 더한다 |
| §10.1 | `terminal_reason`이 없는 구버전 CLI의 문구 폴백 | 폴백을 지운다. #37667이 폴백 코드를 지웠다 |
| §10.2의 3 | carrier만 꼴에 따라 달라진다 | carrier와 memory delivery가 달라진다 |
| §10.3, §10.5 | midpoint 시험 | floor 시험 |
| §11 Phase D | live full → smaller/floor | live full → floor |
| §13 | (없음) | 중간 view를 버린 까닭을 더한다 |

## 16. 시험과 구현 순서

시험은 각 PR의 첫 커밋에 넣는다. 로컬 Dune 빌드는 하지 않는다. PR마다 type-check와 leader CI 시험 결과를 본다. 핵심 회귀는 임시 브랜치의 변이 run으로 시험이 깨지는지 본다.

**L0. 이 문서 PR**

- 이 RFC, 두 RFC 고침(§15), TLA+ 모델과 cfg 일곱, `specs/INDEX.md`

**L1. typed 거절** (`packages/agent_core/lib/llm_provider/retry.ml(i)`, `candidate_fault.ml`, `keeper_codex_runtime.ml`, 오류를 JSON·관측·lane walk로 옮기는 곳)

- `input_too_large`가 `Input_text_over_limit { actual_chars; max_chars }`로 온다. 413은 없다.
- 진짜 HTTP 413은 `Request_body_refused_by_provider`로 남는다.
- `Candidate_fault.of_api_error`는 새 reason을 `Binding Body_limit`로 둔다.
- Codex 세션 기록은 `input_too_large`면 Start는 `Input_rejected Bootstrap_floor_exceeded`, Resume은 `Provider_rejected`다. `input_capacity_refusal`이 이미 읽어 둔 typed 값과 thread mode로 가른다.

**L2. 단계** (`keeper_turn_driver_try_provider.ml`, `keeper_codex_runtime.ml`, `keeper_claude_code_runtime.ml`, outbox, memory 두 모듈, `keeper_run_tools_hooks.ml`)

- Resume → fresh Start(range 전체, `Inline`) → floor → 끝으로 간다.
- Codex에 floor capacity를 더한다.
- floor에서 네 부분을 한꺼번에 바꾼다. floor 꼴을 만들지 못한 부분만 지금 꼴로 남긴다.
- host memory는 지금 행을 반씩 줄이는 hook뿐이다. 행을 모두 미루는 floor 꼴을 더한다. agent_core는 지금 hook을 그대로 쓴다.
- hook 실패를 결과 칸으로 옮긴다. agent_core 단계도 같다.
- 반 자르기와 그 상수·관측을 지운다.
- carrier RFC의 모델(`specs/bug-models/RetainedResultCarrier.tla`)은 걸음이 반 자르기다. 그 걸음을 새 단계에 맞춘다. 꼴이 한쪽으로만 바뀌고 receipt는 받아들여진 뒤에만 준다는 성질은 그대로 둔다.
- 시험은 돌려준 값만 보지 않고 세션 저장소의 기록을 읽는다. floor가 받아들여지면 막는 기록이 없고, floor가 거절되면 `Input_rejected Bootstrap_floor_exceeded`가 남는다.

**L3. Codex `input_too_large` 단계 건너뛰기** (`keeper_codex_runtime.ml`)

- 시험 fixture는 `turn/start` 글을 실제로 센다. `max_chars`를 넘으면 그 글자 수와 한도로 `input_too_large`를 돌려준다.
  - 한 번만 거절하는 marker 파일은 쓰지 않는다. 닫은 #50263의 첫 시험은 fixture가 한 번만 거절해서 통과했다.
  - `actual_chars`를 일부러 틀리게 주는 스위치를 둔다. §7의 대조를 시험한다.
- #50263 브랜치의 시험 다섯을 옮긴다.
- Start: 다시 보내지 않는다. 마지막 거절을 돌려주고, 묶음 blob이 없다. 세션에는 `Input_rejected Bootstrap_floor_exceeded`가 남는다.
- Resume: fresh Start 글이 `max_chars` 안이면 보낸다. 아니면 보내지 않고 끝나고, 세션에는 `Provider_rejected`가 남는다.

**마무리**

- 이 RFC와 carrier RFC의 상태를 바꾼다. #50255와 #50170을 닫는다. changelog 조각을 쓴다.
- #50330(masc 자신의 예산 초과가 provider 창 초과와 같은 생성자로 온다), #50368, #50398은 이 스택 밖이다.
- 배포 뒤 확인은 운영자 승인 뒤에 한다.

**고정 assertion이 바뀌는 시험**

carrier RFC §12는 고정한 assertion을 바꾸지 않는다고 했다. 아래 시험은 이 RFC가 바꾸는 동작을 고정했다. 그래서 바꾼다.

| 시험 | 바뀌는 까닭 |
|---|---|
| `test/test_keeper_context_overflow_shrink.ml:44-105`, `:160-298`, `:310-328`, `:359-408` | 반 자르기, 중간 view, 같은 capacity 다시 보내기를 고정했다. 걸음의 인자 `shrink_capacity`, `shrink_admits_history`도 지운다. Start 거절 다음은 floor다(§5) |
| `test/test_keeper_context_overflow_shrink.ml:410-423` | hook 실패가 원래 거절로 끝났다. floor는 그 부분만 남기고 간다(§8) |
| `test/test_keeper_workspace_memory_selection.ml:496-517` | 줄이기 단계를 직접 불러, 같은 capacity로 memory 행을 반만 남겨 다시 보냈다. floor는 행을 모두 미룬다(§5) |
| `test/test_keeper_claude_code_runtime.ml:5423-5426` | 같다. 다시 보낸 Start에 행 A·B가 남았다 |
| `test/test_keeper_claude_code_runtime.ml:7032`, `:7062` | Resume 창 거절 뒤 fresh Start는 range 전체와 `Inline`이다(§6) |
| `test/test_keeper_codex_current_context.ml:1614` | 같다 |
| `test/test_keeper_codex_error_carriage.ml:91-104` | `input_too_large`가 새 reason으로 온다(§4) |

- assertion이 그대로인 시험이다. hook 실패를 싣는 assertion만 더한다.
  - `test_keeper_context_overflow_shrink.ml:107-158`, `:332-357`: 크기 아닌 거절, checkpoint 경계, 효과 뒤 거절. 지우는 인자 `shrink_admits_history`만 호출에서 뺀다(`:118`, `:147`, `:342`).
  - `test_keeper_host_result_retention.ml:843-891`, `:1070-1089`: 묶음 hook과 그 사슬(`carrier_reprojection ~then_`). agent_core가 계속 쓴다(§10)
  - `test_keeper_carried_range_eviction`, `test_keeper_memory_recall_blocks`, `test_keeper_workspace_memory_selection`의 hook 단위 assertion
