---
rfc: "muse-refused-resume-restarts-fresh"
title: "호스트가 크기로 거절한 Muse 이어 쓰기는 같은 실행에서 새 세션으로 한 번 다시 연다"
status: Draft
created: 2026-11-13
updated: 2026-11-13
author: claude
supersedes: []
superseded_by: null
related:
  - claude-code-context-overflow-bounded-restart
  - librarian-lifecycle
  - "0509"
implementation_prs: []
---

# RFC: 크기로 거절된 Muse 이어 쓰기는 같은 실행에서 새 세션으로 연다

## 1. 결정

호스트가 이어 쓰던 세션의 입력을 크기로 거절하면 그 세션은 끝난 것이다.
효과가 없었다고 확인된 일반 턴은 같은 실행 안에서 새 세션으로 한 번 다시 연다.

Claude Code 와 Codex 는 이미 이렇게 한다(RFC
claude-code-context-overflow-bounded-restart §6.3,
`keeper_claude_code_runtime.ml:1575-1586`). 거절된 Resume 은 호스트가 가진 대화와
이번 프롬프트를 보내므로 아무리 줄여도 입력이 그대로다. 그래서 다시 여는 것은
늘 새 시작이다. Muse 는 같은 사실을 따르지 않아서, 다음 턴이 할 일을 이번 턴이
실패로 넘긴다.

## 2. 무슨 일이 있었나 (#51689)

- 2026-11-12 00:00Z~10:47Z 에 `ocaml-agent-ic` 의 Muse 턴이 7번 거절됐다(03:18,
  04:08, 05:05, 06:03, 07:57, 09:01, 10:45Z). 메시지는
  `The input (92만~95만 tokens) exceeds…` 였다.
- 7건 모두 같은 세션을 18~19번 이어 쓴 뒤(`mode=resume`)였다. 거절 뒤 2분 안에
  다음 턴이 `mode=start` 로 새 세션을 열었고 거기서 풀렸다.
- 이어 쓰는 턴마다 `prompt_bytes` 가 153,000~163,000 이었다. 이어 쓸 때마다 고른
  현재 맥락(Memory 포함)을 다시 싣기 때문이다(`keeper_muse_runtime.ml:1238-1242`).
- 호스트가 스스로 줄여도 모자랐다. 03:17:57Z 에 `tokens_before=920815
  tokens_after=808476` 으로 줄인 7초 뒤 거절됐다. Muse Code 1.4.15, 창은
  1,048,576 토큰이다.

Keeper 한 명, 하루치다. 세션이 턴마다 얼마씩 자라는지는 토큰으로 재지 않았다.

## 3. 지금 코드가 하는 일

- 거절은 호스트의 typed 입력 거절이다. `model_input_refusal_of_error` 가
  `Some Model_error_not_retryable` 을 돌려준다(`keeper_muse_runtime.ml:79-120`,
  RFC-librarian-lifecycle §4.10).
- 세션 저장소는 이 실패를 `Provider_rejected` 로 적는다(`keeper_muse_runtime.ml:350-363`).
  Phase 는 `Recovery_required` 가 된다.
- 턴은 `Provider_attempt_effect_fenced` 로 끝난다. 그 턴 자기 범위를 읽어
  `Turn_quiet` 를 얻으면 같은 lane 의 다음 runtime 후보로 넘어갈 수는 있다
  (RFC-0509). 같은 Muse 후보를 새 세션으로 다시 부르는 길은 없다.
- 다음 턴의 claim 은 `Recovery_required` 를 새 claim 으로 넘긴다
  (`keeper_official_client_session_store.ml:1536-1548`). 그래서 `Serve.Start` 가
  고른다. Start 는 Keeper 의 호스트 저장소를 지운다(`keeper_muse_runtime.ml:1571-1572`).
  거절된 세션은 다시 이어 쓰지 않는다.
- 거절 기록 hook(`on_model_input_refused`, #51625)은 이어 쓰기에서도 불리지만 남기는
  것이 없다. 이어 쓰기는 씨앗을 보내지 않았으므로 거절된 범위가 없다
  (`keeper_turn_driver.ml:2871-2873`).

세션이 찼다는 사실은 거절 순간에 이미 확정이다. 새 세션을 여는 일은 지금도
일어난다. 다만 한 턴 늦게, 실패 하나를 남기고 일어난다.

## 4. 조건

다음이 모두 참일 때만 같은 실행에서 다시 연다. 모두 이미 있는 판정이다. 새
상수는 없다.

1. 거절된 시도가 일반 턴의 `Serve.Resume` 이다. Gate continuation 은 잡힌 세션에
   묶여 있어 다시 열지 않는다. Claude Code(`Resume _, Some _ -> false`)와 Codex 가
   같은 이유로 그렇게 한다.
2. 거절이 호스트의 typed 입력 거절이다. 거절 뒤 읽은 사용량과 카탈로그가 다른
   원인을 말하지 않았다. #51686 의 `marks_refused_range` 와 같은 판정이다.
   사용량 창이 찼으면 크기 거절로 보지 않는다.
3. 거절된 턴이 효과를 남기지 않았다. 그 턴 자기 범위를 읽어 `Turn_quiet` 를
   얻었다(RFC-0509). 얻지 못하면 지금처럼 `Provider_attempt_effect_fenced` 로
   끝난다.
4. 다시 여는 것은 한 번이다. 다시 연 `Serve.Start` 가 거절되면 #51625·#51626
   길로 끝난다. 거절된 범위를 턴 기록에 남기고, 다음 새 세션은 그 시작점 뒤에서
   연다. Start 는 다시 열지 않는다.

## 5. 바뀌는 곳

- 기록: 조건 2 를 만족한 Resume 거절은 `Provider_rejected` 대신
  `Vendor_session_full` 로 적는다. 조건 3 을 얻으면 `No_activity_observed`, 못
  얻으면 `Activity_observed` 다. Codex·Claude Code 가 Gate 이어 쓰기 넘침에 쓰는
  같은 값이고 실패 성격(`Fatal`)도 같다. 새 상태나 필드는 만들지 않는다.
- 다시 열기: `Vendor_session_full No_activity_observed` 이고 조건 1 이 참이면
  같은 실행에서 Muse 시도를 한 번 더 부른다. claim 은 지금처럼 이 recovery 를 새
  claim 으로 넘기므로(`keeper_official_client_session_store.ml:1544`) Start 가
  된다. 저장소 정리와 씨앗(carried range)은 지금 Start 와 같다.
- 로그: 다시 열 때 한 줄을 남긴다. "host session <id> refused the turn input;
  the turn starts a fresh session" 꼴이다. 배포 뒤 셀 근거다.
- 구현 PR 에서 확인할 것: `Vendor_session_full` 을 읽는 곳
  (`Keeper_direct_gate_continuation.session_full` 등)이 일반 턴의 기록을 받아도
  뜻이 맞는지.

## 6. 하지 않는 것

- 이어 쓰기 전에 크기를 미리 재서 새로 열기(#51689 의 두 번째 길): 다음 입력의
  토큰 수를 알려면 바이트를 토큰으로 바꾸는 상수가 필요하다. Muse 창도 runtime.toml
  `max_context` 로만 안다(`runtime_instance.ml:246-256`). 호스트 카탈로그의
  `contextLimit` 은 읽지 않는다.
- 이어 쓸 때 맥락을 다시 싣지 않기(#51689 의 첫 번째 길): 호스트가 줄인 뒤에도
  맥락이 남았다고 보증할 durable 증거가 먼저 있어야 한다
  (`keeper_muse_runtime.ml:1238-1242`). 이 일은 세션이 차는 빈도를 줄인다. 찼을 때
  할 일은 이 RFC 와 같다.
- `Runtime.capability_of_runtime` 이 Muse_serve 를 `Truncates_silently` 로 두는
  분류(`runtime.ml:3742-3746`): 호스트가 크기를 typed 로 거절하는 것과 맞지 않아
  보인다. 그러나 호스트 auto-compaction 이 MASC 모르게 이력을 줄이는 점을 같이 봐야
  해서 이 RFC 에서 바꾸지 않는다. 확인 필요로 남긴다.

## 7. 대가

- 세션이 찰 때 그 턴은 거절된 요청 한 번과 새 세션 시작만큼 길어진다.
- 새 세션의 첫 요청은 carried range 씨앗을 싣는다. `ocaml-agent-ic` 의 씨앗은
  11-12 에 최대 129,983 B 였다.
- 같은 이유로 실패하던 턴이 성공한다. 2.의 기준으로 이 Keeper 에서 19턴에 1턴이다.

## 8. 시험

1. 일반 턴 Resume 이 typed 거절되고, 읽기가 다른 원인을 말하지 않고, `Turn_quiet`
   를 얻었다. 같은 실행에서 Start 로 이어져 턴이 성공한다. 세션 저장소에는 새
   세션의 settlement 가 남는다.
2. Start 가 거절됐다. 다시 열지 않고 #51625 의 거절 기록 길로 끝난다.
3. `Turn_quiet` 를 얻지 못했다. 다시 열지 않는다. `Vendor_session_full
   Activity_observed` 로 남고 턴은 `Provider_attempt_effect_fenced` 로 끝난다.
4. 사용량 창이 찼다. 다시 열지 않는다.
5. Gate continuation 의 Resume 이 거절됐다. 다시 열지 않는다.
6. 다시 연 Start 도 거절됐다. 두 번째로 다시 열지 않는다.

변이: 조건 1 에서 "Resume 만"을 빼면 시험 2 와 6 이 실패해야 한다.

## 9. 배포 뒤 확인

- 같은 Keeper 에서 Resume 거절 수와 "starts a fresh session" 로그 수가 같다.
- 그 턴들이 성공으로 끝난다.
- 기준은 2.의 11-12 7건이다. Muse 를 쓰지 않는 날에는 셀 것이 없다.
