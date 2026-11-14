---
rfc: "retained-results-carrier-shrinks-to-an-address"
title: "남은 도구 결과 묶음은 크기 거절을 받으면 주소 꼴로 바꿔 같은 턴에서 다시 보낸다"
status: Draft
created: 2026-11-08
updated: 2026-11-08
author: claude
supersedes: []
superseded_by: null
related: ["claude-code-context-overflow-bounded-restart", "official-client-conversation-in-masc", "context-overflow-semantic-recovery", "0473"]
---

# RFC: 남은 도구 결과 묶음은 크기 거절을 받으면 주소 꼴로 바꿔 같은 턴에서 다시 보낸다

줄 번호는 `6581d43773c` 기준이다.

## 1. 결정

끝나지 못한 vendor 턴은 도구 결과 기록(receipt)을 outbox에 남긴다. 다음 요청은 receipt 전부를 묶음(carrier) 하나로 싣는다. 이 RFC는 묶음에 꼴(form)을 둘 둔다.

- `Inline`: 지금 묶음이다. receipt를 전부 글로 싣는다.
- `By_address`: receipt가 몇 개든 길이가 도구 종류와 개수의 자릿수로만 달라진다. 이미 돌아온 호출 수, 도구별 개수, 그리고 `Inline` 글을 담은 blob 하나의 주소를 싣는다.

run(runtime 호출 하나. 한 후보에게 보내는 provider 시도 전부)은 `Inline`으로 시작한다. lane이 다른 후보로 넘어가면 새 run이 다시 `Inline`으로 시작한다. typed 크기 거절이 오면 이미 있는 재투영 hook `on_memory_capacity_refusal`이 묶음을 `By_address`로 한 번 바꾼다. `By_address` 글이 엄격히 짧을 때만 바꾼다. 그러면 같은 capacity로 다시 보낸다(§5.2). 그다음 거절은 지금처럼 history를 줄인다. 그 view와 floor에도 `By_address`가 실린다.

줄이기 단계(walk), floor 계산, tail window, blob 정리, ACK 규칙은 바꾸지 않는다.

결과는 이렇다. typed 크기 거절이 hook에 닿는 경로(§7)에서만 그렇다.

- 고정부(system prompt, 도구, 목표)와 `By_address` 묶음이 창에 들어가면, 효과 전에 온 크기 거절로 그 Keeper가 floor에서 잠기지 않는다(`Bootstrap_floor_exceeded`). receipt 개수와 상관없다.
- 넘친 턴은 같은 턴 안에서 사람 손 없이 다시 보내진다. 그 턴의 `Completed`가 receipt를 지운다.
- 모델은 호출 몇 개가 이미 결과를 돌려줬는지 안다. reader가 있으면 그 결과도 읽는다. 「끝난 효과를 반복하지 말라」는 안내는 두 꼴 모두에 있다.
- 효과 뒤에 턴 안에서 넘치는 경우(`Effect_fenced`)는 지금처럼 운영자 몫이다(§9).

## 2. 일어난 일

2026-11-07 Keeper 하나에서 두 번 일어났다(#49634).

**첫 번째**

- 12:00:40 KST부터 Claude Code 턴이 모델에 닿기 전에 거절됐다. 첫 거절 문구는 `the request is ~9802538 tokens (limit 1000000) but this conversation is only ~1907 tokens`다.
- system prompt 12,208,629자 가운데 12,154,908자가 묶음 한 줄이었다. 그 줄에 receipt 248개가 있었다. 11:40 KST에 시작한 vendor 턴 하나가 남겼다.
- 화면 캡처 receipt 하나는 약 90 KB였다. 640x480 PNG가 `response.content_blocks`에 base64로 들어 있었다.
- 자동 shrink-retry가 12:00:30에 `restart_fresh`를 했다. 묶음은 그대로라 10초 뒤 다시 잠겼다. 14:53 KST까지 158번 연속 실패했다.
- 15:45 KST에 운영자가 receipt 폴더를 옮기고 `restart_fresh`를 보내서 풀었다.

**두 번째**

- 16:36~16:42 KST에 vendor 턴 하나가 receipt 62개(2.4 MB)를 남겼다.
- 요청은 약 197만 토큰이었다. 17:34 KST까지 47번 연속 실패했다. 잠긴 이유는 `input_rejected_bootstrap_floor_exceeded`다.
- 17:51 KST에 운영자가 같은 방법으로 풀었다.

**#49665·#49680·#49698이 고친 것과 못 고친 것**

세 PR은 두 사고 뒤인 11-07 17:25~18:19 KST에 병합됐다.

- 고친 것
  - 새로 쓰는 receipt 하나의 크기다(#49680·#49698). 그림과 긴 글 본문을 blob 주소로 남긴다. 백업한 receipt 248개에 새 쓰기 규칙을 Python으로 흉내 내면 11,833,867 B가 326,903 B가 된다. OCaml 코드로 잰 값은 아니다.
  - 묶음 글의 그림이다(#49665). receipt 파일에 base64 그림이 있어도 묶음 글에는 바이트 수와 sha256만 싣는다(`keeper_client_tool_outbox_media.ml:97`). 옛 모양 receipt와 Codex receipt의 data URL도 같다.
- 못 고친 것
  - receipt 개수에 상한이 없다.
  - 이미 쌓인 옛 모양 receipt의 긴 글 본문은 묶음 글에 그대로 실린다.
  - Codex receipt 파일은 그림 data URL을 그대로 담는다(#49697). 묶음 글에서는 빠지지만 파일은 크다.
  - 무엇보다, 한 번 넘친 Keeper가 스스로 빠져나올 길이 없다.

## 3. 원인

세 성질이 겹쳐서 교착이 생긴다.

**1. receipt는 상한 없이 쌓인다.**

- host는 도구 결과를 받을 때마다 receipt를 하나씩 쓴다(`keeper_official_client_host.ml:1694-1718`). receipt를 지우는 것은 받아들여진 `Completed`뿐이다(아래 3).
- 그래서 받아들여지지 않은 턴은 그 턴에 쓴 receipt와 이미 있던 receipt를 모두 남긴다. vendor가 받은 결과도 남는다.
  - 시험 `test/test_keeper_claude_code_runtime.ml:6915-6929`가 이를 확인한다. vendor가 결과를 낸 턴을 caller가 받아들이지 않은 경우다.
- 남기는 것은 맞는 동작이다. 모델이 이미 일어난 효과를 다시 일으키지 않게 한다.

**2. 묶음은 크기를 잰 뒤에 붙는다.**

| runtime | 붙는 곳 | 자리 |
|---|---|---|
| Claude Code | `keeper_claude_code_runtime.ml:943-946` | Start는 system prompt, Resume은 resume prompt 앞의 carried context(`Tool_result_receipts`) |
| Codex | `keeper_codex_runtime.ml:1251-1266` | Start와 Resume 모두 developer item |
| agent_core | `keeper_turn_driver_try_provider.ml:2614-2658` | projection 뒤 `place_carrier`. 바이트는 ledger tail에 더할 뿐 capacity에서 빼지 않는다 |

- floor는 history만 잰다. pinned 바이트에 preamble을 더한 값이다(`lib/runtime/runtime_model_input_tail_window.ml:318-342`).
- 그래서 줄이기 단계의 어떤 view도, floor도 묶음을 줄이지 못한다.

**3. receipt는 받아들여진 `Completed`만 지운다.**

- `settle_after_turn`은 `Completed`일 때만 `acknowledge`한다(`keeper_client_tool_outbox.ml:376-391`).
- `resolve_recovery`는 `session.json`만 쓴다. `restart_fresh` 뒤의 run은 같은 묶음을 다시 싣는다.
- floor가 거절되면 `plan_claim`이 같은 runtime을 막는다(`keeper_official_client_session_store.ml:1493-1503`).

셋이 겹치면, 창을 한 번 넘은 Keeper는 사람 없이 못 빠져나온다. bounded-restart RFC는 floor가 거절되면 운영자가 고정부를 줄이라고 한다(§8). 이 RFC 전에는 그 RFC의 floor 목록(§5)에 receipt 묶음이 없었다. 11-07에 운영자가 손으로 한 일이 그것이다.

관련 RFC 넷(bounded-restart, official-client-conversation-in-masc, context-overflow-semantic-recovery, 0473) 가운데 receipt 묶음의 자리·크기·비우기를 정한 것은 없다.

## 4. 두 꼴

### 4.1 `Inline`

지금 `developer_context`의 글 그대로다(`keeper_client_tool_outbox.ml:318-337`).

- receipt마다 `carrier_row`를 거친 JSON이다. base64 그림은 바이트 수와 sha256으로 보이고(#49665), 나머지 값은 그대로다.

### 4.2 `By_address`

글은 다음 순서다.

1. 지금 prefix. receipt를 도구 데이터로 다루고, 끝난 효과를 반복하지 말라는 안내다.
2. 「이 요청은 receipt N개를 주소로 싣는다. 하나하나 결과가 이미 돌아왔고, 실패나 실행 전 거절일 수 있다.」
   - receipt에는 실패와 실행 전 거절도 있다. 그래서 「반복하지 말라」는 끝난 효과에만 건다. 그 말은 1의 prefix에 있다.
   - 이 줄이 모든 호출을 반복하지 말라고 하면, 주소 꼴에서는 실패한 호출도 다시 부르지 못한다. 모델이 어느 호출이 실패했는지 가르지 못하기 때문이다.
3. 도구별 개수. snapshot에서 처음 나온 순서를 지킨 JSON 객체다.
4. 「개수로는 어느 호출이 무엇을 했는지 알 수 없다.」
5. blob marker 한 줄(`[masc:blob sha256=… bytes=… mime=text/plain preview="…"]`).
6. 읽는 법
   - 요청 도구 목록에 `keeper_artifact_read`가 있으면, 위 도구를 다시 부르기 전에 그 sha256으로 읽고 `next_offset`을 따라가라고 적는다. 읽는 글은 이 요청이 `Inline`으로 실었을 글이라고 적는다.
   - 없으면 「이 요청에는 reader가 없어 receipt를 읽을 수 없다. 위 도구를 다시 부르기 전에 지금 상태를 본다」고 적는다(§6.2).

blob은 하나다. 바이트는 `Inline` 글 그대로다.

- 모델이 주소로 읽는 내용과 `Inline`으로 받았을 내용이 같다. 꼴은 글이 놓이는 자리만 바꾼다.
- 이름표(MIME)는 `text/plain`이다.
  - 정리 작업은 살아 있는 marker가 artifact manifest MIME(`application/vnd.masc.tool-result-manifest+json`)을 단 blob만 열어 읽는다. 그 밖의 blob 내용은 읽지 않는다(`tool_blob_maintenance.mli:3-11`).
  - manifest MIME을 달면 엄격한 manifest로 읽힌다. 잘못된 manifest 하나가 base path 정리 전체를 멈춘다. #49698이 고친 함정과 같다.
- marker의 preview는 고정 글이다. Librarian recall도 같은 방법을 쓴다(`keeper_librarian_context_recall.ml:179`).
  - 그래서 marker 길이는 바이트 수의 자릿수로만 달라진다.
- receipt마다 blob을 두고 목록 blob으로 가리키는 꼴은 버렸다(§11의 9).

### 4.3 blob 쓰기와 수명

- hook이 꼴을 바꿀 때 blob을 한 번 쓴다. `Tool_blob_store.put_durable_reuse`를 쓴다(`tool_blob_store.mli:129-135`).
  - 이 process가 이미 쓴 주소는 읽어서 비교만 한다. 없거나 깨졌으면 다시 쓴다.
  - 쓰기가 실패하면 `put_durable_reuse`는 `Sys_error`를 던진다. hook은 이것을 `Error`로 돌려주고 꼴을 바꾸지 않는다(§5.1). 예외는 run 밖으로 나가지 않는다.
- 렌더는 파일을 읽지도 쓰지도 않는다.
  - `Inline`이면 run을 시작할 때 만든 글을, `By_address`면 hook이 만든 글을 돌려준다.
  - 그래서 렌더는 실패하지 않는다.
- 길이를 잴 때는 sha256 자리를 0으로 채운 marker를 쓴다.
  - sha256은 늘 64자이고 preview는 고정 글이다. 그래서 이 marker는 실제 marker와 길이가 같다.
  - 해시도 파일 I/O도 하지 않는다. 길이가 줄지 않으면 blob을 쓰지 않는다.
  - receipt 글 본문을 marker로 바꿀지 정할 때도 같은 방법을 쓴다(`keeper_client_tool_outbox.ml:125-159`).
- blob 삭제는 배포 helper가 BasePath lease를 쥐고 오프라인에서 두 번 검사할 때만 일어난다(`tool_blob_maintenance.mli:35-41`).
  - 서버 안의 sweep(RFC-0499 1층)은 세기만 하고 지우지 않는다(`tool_blob_sweep.mli:1-2`). 그래서 run 안에서는 이 blob이 늘 읽힌다.
  - 이 blob은 정리 작업이 보는 저장소에서 참조되지 않는다. 그래서 배포 때 지워질 수 있다.
  - 배포 뒤 receipt가 아직 남아 있으면 다음 run의 hook이 같은 주소로 다시 쓴다. 주소는 바이트에서 나오고, 바이트는 같은 snapshot의 `Inline` 글이기 때문이다.
  - 그래서 정리 규칙은 바꾸지 않는다.

## 5. 바꾸는 때

### 5.1 hook

`Keeper_memory_delivery_reprojection.t`는 `refusal:Agent_core.Error.t -> (Unchanged | Reprojected, string) result`다. 두 곳이 이 hook을 부른다.

- official client의 줄이기 단계 `context_overflow_shrink_sequence`(`keeper_turn_driver_try_provider.ml:3038-3065`)
  - typed 크기 거절이고 같은 run 재시도가 허락되면 hook을 부른다.
  - `Reprojected`: `on_memory_retry ()` 뒤 같은 capacity로 다시 보낸다.
  - `Unchanged`: history를 줄인다.
  - `Error`: 그 거절로 끝난다.
- agent_core의 `memory_capacity_retry_sequence`(`keeper_turn_driver_try_provider.ml:3320-3330`)
  - `Reprojected`면 다시 보내고, `Unchanged`면 history 쪽 복구로 넘긴다.

묶음 hook은 run마다 하나인 carrier 값을 가진다. 그 값은 run이 load한 snapshot, 그 `Inline` 글, 지금 꼴을 안다.

- 꼴이 `Inline`이고, receipt가 있고, `By_address` 글이 `Inline` 글보다 엄격히 짧다.
  - 길이는 sha256 자리를 0으로 채운 marker로 잰다(§4.3).
  - blob을 `put_durable_reuse`로 쓴다. 쓰기가 실패하면 `Error`를 돌려준다.
  - 꼴을 `By_address`로 바꾸고 `Reprojected`를 돌려준다.
- 그 밖에는 `Unchanged`를 돌려준다. 이미 바꾼 뒤에도 `Unchanged`다.
  - hook에는 반복을 막는 장치가 없다. 그래서 묶음 쪽이 한 번만 바뀌게 한다.

묶음 hook을 caller가 넘긴 memory hook 앞에 이어 붙인다.

- 묶음 hook이 `Unchanged`면 memory hook을 부른다.
- memory hook도 이미 이런 식으로 이어져 있다. host memory 다음에 recall block이다(`keeper_run_tools_hooks.ml:707-713`).
- 묶음을 먼저 둔다. receipt 개수만큼 길어지는 쪽을 먼저 줄여서, 넘침이 묶음 탓이면 다시 보내기 한 번으로 끝나게 한다.

### 5.2 다시 보내기

- Claude Code와 Codex의 `on_memory_retry`는 `resolve_input_rejected_for_shrink_retry`다(`keeper_claude_code_runtime.ml:681-710`).
  - Claude Code의 크기 거절과 Codex의 `contextWindowExceeded`는 `Input_rejected Bootstrap_floor_exceeded`로 기록된다. `on_memory_retry`가 이것을 `Restart_fresh`로 푼다.
  - Codex의 `input_too_large`는 `Protocol_failed`로 기록된다(`keeper_codex_runtime.ml:826-828`). `on_memory_retry`는 아무것도 하지 않고, 다음 `plan_claim`이 fresh plan을 낸다(`keeper_official_client_session_store.ml:1520-1532`).
  - 어느 쪽이든 다시 보내는 요청은 fresh Start다.
- 같은 capacity로 다시 보내니 history는 그대로이고 묶음만 짧아진다.
- 그다음 거절은 history를 줄인다. 그 view와 floor에도 `By_address`가 실린다.
- floor는 history만 재니(§3) floor 계산은 그대로 맞다.

### 5.3 Resume

- Resume에도 따로 규칙을 두지 않는다. Resume도 `Inline`으로 시작한다.
- `Inline`이 넘치면 §5.1의 hook이 꼴을 바꾼다.
  - 다시 보내기는 fresh Start라서 vendor 세션을 버린다.
  - 지금의 Resume overflow도 같다(`keeper_claude_code_runtime.ml:681-684`).
- Claude Code Resume은 vendor 세션이 이미 가진 carried context를 다시 보내지 않는다(`keeper_claude_code_runtime.ml:958-990`). receipt 묶음도 `Tool_result_receipts` carried context다(`keeper_official_client_context_projection.ml:413-414`). 이 점을 써서 Resume을 `By_address`로 시작하는 규칙은 닿는 길이 좁아서 두지 않는다(§11의 8).
- Codex는 receipt를 Start와 Resume 모두 developer item으로 늘 다시 넣는다(`keeper_codex_runtime.ml:1251-1266`).

### 5.4 Gate continuation

- Gate continuation Resume은 같은 run에서 다시 보내지 않는다. 그래서 hook이 불리지 않는다.
  - Claude Code: `keeper_claude_code_runtime.ml:1531-1539`
  - Codex: `keeper_codex_runtime.ml:2106-2114`
- 묶음 때문에 넘치면 `Vendor_session_full`로 기록된다(`keeper_claude_code_runtime.ml:534-552`, `keeper_codex_runtime.ml:846-861`).
  - 실제로는 vendor 세션이 아니라 묶음이 넘친 것이다.
  - 다음 일반 턴이 fresh 세션을 열고, 그 턴에서 hook이 꼴을 바꾼다.
- 같은 세션에서 다시 보내려면 실측이 먼저다. CLI가 거절된 resume prompt를 세션 기록에 남기지 않는지 봐야 한다. 이 RFC는 그 일을 하지 않는다.
- 위 줄들의 주석은 「resume prompt는 어떤 capacity에서도 같다」고 말한다. 묶음 꼴이 바뀌면 이 말이 틀린다. 주석을 「history를 줄여도 같다」로 고친다.

## 6. ACK와 reader

### 6.1 ACK

- 바꾸지 않는다. 모든 receipt가 늘 한 꼴로 실린다. 그래서 「load한 snapshot을 지운다」가 「실린 것을 지운다」와 같다.
- `By_address`에서 모델이 blob을 읽지 않고 턴을 끝낼 수 있다. 그래도 `Completed`면 receipt를 지운다.
  - 실린 것은 「호출 N개가 결과를 돌려줬다」는 사실과 주소다.
  - 결과 바이트는 blob에 남는다(§4.3).

### 6.2 reader가 없는 요청

- 그래도 `By_address`로 바꾼다. 교착을 막는 쪽을 먼저 지킨다.
- 글에 「이 요청에는 reader가 없어 receipt를 읽을 수 없다. 위 도구를 다시 부르기 전에 지금 상태를 본다」고 적는다. 모델은 호출 수와 도구별 개수만 본다.
- memory recall은 reader가 없으면 inline으로 돌아간다. receipt 묶음은 길이를 묶는 곳이 없어서 그렇게 하지 않는다.
- 11-07 17:55 KST에 마지막 프롬프트가 남은 Keeper 36명은 모두 `keeper_artifact_read`를 받고 있었다(#49698).

## 7. 닿는 경로와 닿지 않는 경로

hook은 typed 크기 거절에만 불린다. 거절 문장을 읽어 크기 거절로 가리면 문자열 분류기가 된다. 그래서 그렇게 넓히지 않는다.

**닿는 경로**

- Claude Code: `prompt_too_long`이 `Context_window_exceeded`로 온다. Start와 Resume에서 닿고, Gate continuation에서는 닿지 않는다(§5.4).
- Codex: `turn/start`가 돌려준 `contextWindowExceeded`와 `input_too_large`다.
- agent_core: provider가 parse 경계에서 크기 거절을 typed로 줄 때만 닿는다.

**닿지 않는 경로** (이슈로 남긴다. §12의 4)

- Codex에서 10,485,760자를 넘는 `Inline` 묶음
  - 묶음은 `turn/start` 전에 `thread/inject_items`로 들어가 developer item **하나**가 된다(`keeper_codex_runtime.ml:1264-1266`, `runtime_codex_app_server.ml:2655-2671`).
  - upstream은 문자열 하나가 10,485,760자를 넘으면 `string_above_max_length`로 거절한다(RFC-official-client-conversation-in-masc §2.5, #37353).
  - #37353(codex 0.155.1)에서 이 거절은 `codexErrorInfo=other`로 왔다. 그래서 `Turn_failed`가 되고 `Provider_rejected`로 기록된다(`keeper_codex_runtime.ml:830-831`).
  - codex-cli 0.167.0의 app-server schema(`codex app-server generate-json-schema`)를 11-08에 봤다.
    - `ThreadInjectItemsParams.items`는 길이 제한 없는 raw JSON이다.
    - `CodexErrorInfo`에는 문자열 길이를 뜻하는 값이 없다.
    - app-server가 typed로 주는 글자 한도(`input_too_large`)는 `turn/start` 입력에만 있다(`keeper_codex_runtime.ml:711-720`).
  - 그래서 hook이 불리지 않는다. run마다 같은 `Inline`을 다시 보내 같은 거절을 받는다. 11-07 첫 사고 묶음(12,154,908자)이 Codex였다면 이 경로였다.
  - 그보다 작은 묶음이 창을 넘으면 `turn/start`의 `contextWindowExceeded`로 와서 hook에 닿는다.
  - 실제 턴으로 재지는 않았다. 근거는 schema와 #37353이고, 신뢰도는 Medium이다.
  - 구조 해결은 이슈로 남긴다(§12의 4).
    - receipt마다 developer item을 나누면 item 하나가 상한에 닿기 어렵다. 전체가 넘치면 typed 거절이 된다.
    - provider 문자열 상한을 넘는 `Inline`은 처음부터 `By_address`로 보낸다.
    - 둘 다 Codex 전송 모양을 바꾸니 이 RFC 범위 밖이다.
- agent_core의 문장만 있는 400
  - 지금까지 잰 live 크기 거절은 모두 typed 이유 없이 문장만 있는 400이다(`keeper_turn_driver_try_provider.ml:3112-3118`).
  - `is_size_refusal`은 이런 거절을 크기 거절로 보지 않는다(`:2988-2999`). 그래서 hook에 닿지 않는다.
  - turn boundary resend가 이 거절에 답하지만 history 앞자리만 옮긴다. 묶음은 run마다 `Inline` 그대로다.
- antigravity와 muse
  - hook을 받지 않는다. `rg on_memory_capacity_refusal lib/keeper/`에 두 runtime이 없다. 넘침을 typed로 가리지도 않는다.

어느 경로든 parse 경계에 typed 크기 거절이 생기면 같은 hook으로 꼴 바꾸기를 이어받는다.

## 8. 따라 풀리는 것과 남는 것

- 옛 모양 receipt의 그림 base64와 Codex receipt의 data URL은 #49665가 이미 묶음 글에서 뺀다. 이 RFC가 할 일은 아니다.
- 옛 모양 receipt의 긴 글 본문은 `Inline`에 그대로 실린다. 넘쳐서 꼴이 바뀌면 `Inline` 글이 통째로 blob으로 가니, 변환 없이 주소로 간다.
- 들어갈 때는 지금처럼 `Inline`으로 간다. #49697(Codex receipt 파일이 data URL을 담는 것)은 receipt를 쓸 때 따로 고쳤다. Codex receipt도 host receipt와 같은 규칙으로 그림과 긴 글을 blob 주소로 남긴다(`Keeper_client_tool_outbox.codex_response`).
- `By_address` 글은 도구 종류 수, 개수 자릿수, reader 여부로만 길이가 달라진다. receipt 개수로는 Codex 문자열 상한에 닿지 않는다. `Inline`이 그 상한을 넘을 때의 거절은 typed가 아니다(§7).

## 9. 남는 대가

- receipt가 남아 있는 동안 run마다 첫 요청이 한 번 거절될 수 있다. run이 `Inline`으로 시작하기 때문이다. lane이 후보를 바꾸면 후보마다 되풀이된다.
  - typed 거절이고 effect·response 전이라 효과는 반복되지 않는다.
  - provider 요청 하나와 CLI process 하나를 쓴다. 거절된 요청의 과금과 rate limit 계산은 확인하지 않았다.
  - 꼴을 run 사이에 기억하면 이 거절이 사라진다. 그러려면 새 durable 상태가 필요하다. 그 상태가 없어도 durable truth는 손상되지 않으니 두지 않는다(§11의 7).
- 효과 뒤의 넘침은 막지 않는다.
  - `Inline` 묶음이 첫 요청에는 들어가도, 턴 안에서 도구 결과가 쌓이면 다음 요청이 넘칠 수 있다.
  - 효과나 응답이 나온 뒤라 같은 run에서 다시 보내지 않는다(`keeper_claude_code_runtime.ml:1537-1550`, `keeper_codex_runtime.ml:2114-2116`). hook도 불리지 않는다.
  - `Input_rejected Effect_fenced`로 기록되고(`keeper_claude_code_runtime.ml:527-530`, `keeper_codex_runtime.ml:838-841`), `plan_claim`이 막는다. bounded-restart RFC §7대로 운영자가 풀어야 한다.
  - 이 RFC 전에도 있던 경로다. 다만 `Inline` 묶음이 그 턴의 여유를 줄인다.
  - 풀린 뒤 다음 run도 `Inline`으로 시작한다. 그래서 첫 요청이 들어가는 동안은 되풀이될 수 있다.
  - §11의 7(꼴 기억)이 효과 뒤 넘침에서도 배우게 하면, 다음 run을 `By_address`로 시작할 수 있다.
- Resume이 `Inline`으로 넘치면 vendor 세션을 버린다(§5.3). receipt가 남아 있는 동안 Resume 턴마다 되풀이될 수 있다.
- Codex의 10,485,760자 초과 묶음과 agent_core의 문장만 있는 400에서는 꼴이 바뀌지 않는다(§7).
- blob 쓰기가 실패하면 묶음 쪽은 `Error`를 돌려주고 `then_`을 부르지 않는다(§5.1).
  - receipt가 있는 run은 크기 거절을 받으면 history를 줄여 보지 않고 끝난다. 묶음이 작고 history가 넘친 경우도 그렇다.
  - agent_core에서는 그 run의 다른 다시 보내기(turn boundary resend, demotion)도 막힌다. `memory_capacity_retry_sequence`가 `Error`에 `on_projection_failure`를 부르기 때문이다(`keeper_turn_driver_try_provider.ml:3320-3330`).
  - blob 저장소가 고장 나면 큰 도구 결과와 그림 저장도 같이 실패한다. 그래서 묶음만 따로 살리는 길은 두지 않는다.
- Gate continuation이 묶음 때문에 넘치면 `Vendor_session_full`로 잘못 기록된다(§5.4).
- Completion review 요청은 같은 run에서 다시 보내지 않는다(`keeper_claude_code_runtime.ml:1768`, `keeper_codex_runtime.ml:2112`). 그래도 묶음 때문에 넘치지는 않는다. review는 Keeper가 아닌 임시 base path에서 돌아서(`lib/workspace_metric_hooks.ml:369-394`) 그 Keeper의 receipt를 싣지 않는다.
- ACK된 뒤의 blob은 배포 때 오프라인 검사 두 번이 지나면 지워질 수 있다. 그 뒤에 vendor 대화에 남은 주소로 읽으면 실패한다.
- reader가 없는 요청은 호출 수와 도구별 개수만 본다. 어느 호출이 실패했는지 모르니, 다시 부르기 전에 지금 상태를 보라는 안내만 받는다.
- hook이 꼴을 바꿀 때 blob 하나를 쓰고 파일과 부모 폴더를 fsync한다. 크기는 `Inline` 글과 같다. 11-07 첫 번째 사고라면 약 12 MB다. 비용은 재지 않았다.
- 호출 하나를 찾으려면 blob을 앞에서부터 나눠 읽어야 한다. receipt마다 따로 읽는 꼴은 버렸다(§11의 9).
- 이 RFC가 배포되기 전에는 #49698이 receipt 하나를 흉내 값 기준 약 36분의 1로 줄인다. 그 사이 다시 잠기면 11-07처럼 receipt를 옮긴다.
  - 배포 뒤 floor 거절로 이미 잠긴 Keeper는 `restart_fresh` 한 번이면 풀린다. 다음 run의 첫 요청이 넘치면 hook이 꼴을 바꾼다. receipt를 옮길 필요가 없다.

## 10. TLA+ 모델

`specs/bug-models/RetainedResultCarrier.tla`

- 요청 = 고정부 + history + 묶음이다. 묶음은 `Inline`이면 receipt 수 × `ReceiptBytes`, `By_address`면 `AddressBytes`다.
- 정상(`Next`, 약한 공정성)
  - 크기 거절이 오면, 아직 `Inline`이고 receipt가 있고 `By_address`가 엄격히 짧을 때 꼴을 바꾼다.
  - 그렇지 않으면 history를 반으로 줄인다. history가 0이면 잠근다.
  - run마다 `Inline`으로 다시 시작한다. 고정부 크기는 run마다 `FixedSizes` 가운데 하나다.
- 지키는 것
  - 불변식 `NoLockWhileFloorFits`: 가장 작은 요청(history 0, 짧은 꼴)이 창을 넘을 때만 잠긴다.
  - 불변식 `SwitchBeforeShrink`: 꼴을 바꿀 수 있는 동안에는 history를 줄이지 않는다.
  - 성질 `RunEnds`: 모든 run이 끝난다. 받아들여지거나 floor에서 잠긴다.
  - 성질 `ReceiptsLeaveOnlyOnAccept`: receipt는 provider가 받은 요청 뒤에만 준다. 결과를 버려서 자리를 만들지 않는다는 뜻이다.
- 버그는 셋이다. 각각 `Next \/ 버그 동작`이다.
  - `RefuseIgnoringCarrier`: 크기 거절이 history만 줄인다. 이 RFC 전의 동작이다.
  - `ShrinkBeforeSwitch`: 꼴을 바꿀 수 있는데 history부터 줄인다. §11의 2(floor에서만 바꾸기)다.
  - `SwitchBack`: hook이 꼴을 `Inline`으로 되돌린다.
- 모델에 없는 것: 효과 뒤의 거절과 typed가 아닌 거절이다. 둘 다 hook에 닿지 않는다(§7, §9).

TLC 1.8.0(로컬, `-workers 1`) 결과는 이렇다.

| cfg | 결과 |
|---|---|
| `RetainedResultCarrier.cfg` | 상태 155개, 위반 없음(exit 0). 동작 6개를 모두 지난다. 고정부 98에서는 주소 floor도 넘쳐 잠긴다. 운영자 몫이라 불변식을 지킨다 |
| `RetainedResultCarrier-buggy.cfg` | `NoLockWhileFloorFits` 위반(exit 12). 고정부 40, receipt 7개에서 잠긴다. 주소 floor(55)는 들어간다 |
| `RetainedResultCarrier-shrink-first-buggy.cfg` | `SwitchBeforeShrink` 위반(exit 12) |
| `RetainedResultCarrier-switch-back-buggy.cfg` | `RunEnds` 위반(exit 13). 두 꼴을 오가며 끝없이 거절된다 |

## 11. 버린 방법

1. **줄이기 단계와 floor에 묶음 꼴을 새 축으로 넣기**
   - 장점: walk가 모든 축을 한곳에서 안다.
   - 단점: hook이 이미 같은 일을 한다. walk, floor 계산, 세 runtime의 capacity 코드를 모두 바꿔야 한다.
2. **floor에서만 꼴 바꾸기**
   - 장점: 바꾸는 곳이 하나다.
   - 단점: Codex와 agent_core에는 floor hook이 없다. 묶음만으로 창을 넘으면 중간 view가 모두 거절된다. floor에 닿기 전에 provider 요청을 history 크기의 log2번 버린다.
3. **receipt를 checkpoint history로 옮기기**
   - 장점: 묶음이 history가 되어 walk가 줄인다.
   - 단점: official-client-conversation-in-masc RFC §5.6(턴의 대화를 checkpoint에 남긴다)이 아직 Draft이고 구현이 없다. 효과 반복 금지 안내를 둘 자리도 새로 정해야 한다.
4. **floor가 거절되면 receipt를 다른 곳으로 옮기기**
   - 장점: 11-07에 손으로 한 일을 자동으로 한다.
   - 단점: 권위 저장소(outbox)를 실패한 뒤에 고친다. 모델이 무엇이 실행됐는지 잃는다. 11-07 첫 격리 뒤에는 같은 키 입력을 다시 할 수 있었다.
5. **receipt 개수 상한, 도구 호출 막기**
   - 장점: 단순하다.
   - 단점: 상한은 증상을 누를 뿐이다. 넘는 receipt를 버리면 효과 반복을 막는 근거가 사라진다. 호출을 막으면 정상 작업이 멈춘다.
6. **늘 `By_address`로만 싣기**
   - 장점: hook도, run마다의 꼴 값도 필요 없다. 가장 단순하다.
   - 단점: receipt가 몇 개뿐인 보통 경우에도 모델이 결과를 보려면 reader를 불러야 한다. reader가 없는 Keeper는 결과를 전혀 못 본다.
7. **꼴을 run 사이에 기억하기**
   - 장점: receipt가 남아 있는 동안 run마다 한 번씩 거절받지 않는다. Resume이 vendor 세션을 버리는 일도 줄어든다. 효과 뒤 넘침(§9)에서도 배우게 하면, 운영자가 풀어 준 다음 run을 `By_address`로 시작할 수 있다.
   - 단점: 새 durable 상태(예: session store의 carried context 종류 하나 더)다. 없어도 durable truth는 손상되지 않는다. 거절이 실제로 얼마나 되풀이되는지 잰 뒤에 다시 본다.
8. **세션이 가진 해시로 Resume 꼴 정하기**
   - 내용: 세션이 지금 snapshot의 `By_address` 글의 sha256을 `Tool_result_receipts`로 이미 가지고 있으면(`held_context_for_resume`, `keeper_official_client_session_store.mli:427-431`) Resume을 `By_address`로 시작한다.
   - 장점: 저장된 값을 읽기만 한다. 닿으면 묶음을 다시 보내지 않고 vendor 세션을 지킨다.
   - 단점: 닿는 길이 좁다.
     - receipt가 남은 채 정산된 턴 뒤에 snapshot이 그대로여야 한다.
     - official client 턴이 `Completed`가 아니게 정산되는 길은 터미널 도구가 durable stimulus에 자리를 내준 경우다(`keeper_official_client_host.ml:202-204`).
     - receipt를 쓰는 runtime에서는 그 도구를 포함해 dynamic 도구 호출의 결과가 모두 receipt가 된다(`keeper_official_client_host.ml:1694-1718`). 그래서 그런 턴 뒤 snapshot은 바뀐다.
     - 남는 길은 caller가 도구 없이 끝난 턴을 받아들이지 않은 경우 정도다. 그 길을 위해 분기를 두지 않는다.
9. **receipt마다 blob을 두고 목록 blob으로 가리키기**
   - 내용: 목록 blob에 receipt마다 `call_id`, `tool_name`, receipt blob 주소를 적는다. 이 RFC의 첫 안이었다.
   - 장점: 모델이 receipt 하나만 골라 읽을 수 있다.
   - 단점
     - fresh Start 뒤 모델은 지난 턴의 `call_id`를 모른다. 목록에서 고를 단서는 `tool_name`뿐이다. 인자를 보려면 receipt를 하나씩 읽어야 한다.
     - 꼴을 바꿀 때 blob을 receipt 수 + 1개 쓰고, 하나마다 fsync한다. 5,000개면 5,001번이다.
     - receipt 파일 바이트를 그대로 실으면 #49665가 뺀 그림 base64가 다시 들어온다. `carrier_row`를 거치면 blob sha256이 파일 이름과 달라져, 목록에 receipt 이름을 따로 적어야 한다.
     - 목록 형식(schema)과 코드가 는다.

## 12. 시험과 구현 순서

시험은 각 PR의 첫 커밋에 넣고, 그 뒤로 고치지 않는다. 검토가 찾은 빈 곳은 새 시험으로 더하고, 고정한 assertion은 바꾸지 않는다. 로컬 Dune 빌드는 하지 않는다. PR마다 type-check와 leader CI 시험 결과를 본다.

**1. 이 문서 PR**

- 이 RFC, bounded-restart RFC 고침, TLA+ 모델과 cfg 넷, `specs/INDEX.md`.

**2. PR A — outbox 꼴과 hook** (`keeper_client_tool_outbox.ml/.mli`, 시험)

- receipt 1·248·5,000개에서 `By_address` 글은 숫자와 sha256만 다르다. 숫자를 지우고 sha256을 가리면 세 글이 같다.
- 도구별 개수 JSON은 snapshot에서 처음 나온 순서를 따른다.
- blob은 `Inline` 글과 바이트가 같고, 이름표는 `text/plain`이다.
- hook
  - `By_address`가 엄격히 짧지 않으면 `Unchanged`이고 blob을 쓰지 않는다.
  - 한 번 바꾼 뒤에는 `Unchanged`다.
  - receipt가 없으면 `Unchanged`다.
  - 묶음 쪽이 `Unchanged`일 때만 memory hook을 부른다. 묶음 쪽이 `Reprojected`나 `Error`면 부르지 않는다.
- blob 쓰기가 실패하면 hook이 `Error`를 돌려주고 꼴을 바꾸지 않는다.
- reader가 없으면 글에 읽을 수 없다는 줄이 있고 reader 이름이 없다.
- 옛 모양 receipt(base64가 글 안에 있는 것)도 `By_address` 글과 blob에 base64가 없다. Codex의 data URL receipt와 #49680 전 host receipt를 따로 본다.
- 계획 marker는 저장한 marker와 길이가 같고, 바뀐 글은 `Inline` 글보다 짧다. 문턱에서 먼 fixture만으로는 두 marker 길이가 어긋나도 드러나지 않는다.
- 정리 작업을 두 번 돌려도 멈추지 않고, receipt가 가리키는 blob은 남는다.
- 묶음 blob이 지워져도 다음 run의 hook이 같은 주소로 다시 쓴다.
  - 정리 작업은 분류되지 않은 항목이 하나라도 있으면 아무것도 지우지 않는다(`tool_blob_maintenance.mli:121-125`). 그래서 시험은 blob 파일을 직접 지운다.
- 꼴을 바꿔도 receipt 파일은 그대로다.

**3. PR B — runtime 연결** (`keeper_claude_code_runtime.ml`, `keeper_codex_runtime.ml`, `keeper_turn_driver_try_provider.ml`, 주석)

- Codex 10,485,760자 초과 묶음은 11-08에 schema와 #37353으로 확인했다. typed 크기 거절이 아니다(§7). 그래서 PR B는 실제 턴으로 재지 않고, 이 경로를 Codex 시험에 넣지 않는다.
- 가짜 provider가 창 W를 넘는 요청을 typed overflow로 거절한다. 옛 모양 receipt 248개를 넣는다.
  - Claude Code Start: 두 번째 시도가 받아들여진다. `Input_rejected`가 남지 않는다. `Completed` 뒤 outbox가 빈다.
  - Codex(`contextWindowExceeded`)와 agent_core도 같다.
- 묶음을 바꿔도 창을 넘으면 history 줄이기가 이어지고, floor까지 `By_address`가 실린다.
- Claude Code Resume: `Inline` 묶음이 넘치면 꼴을 바꾸고 fresh Start로 다시 보내 받아들여진다.
- Gate continuation: 묶음 넘침에 다시 보내지 않고 `Vendor_session_full`로 끝난다. 지금 동작을 고정한다.
- 효과 뒤 넘침은 지금처럼 `Effect_fenced`로 끝나고 hook이 불리지 않는다. 지금 동작을 고정한다.
- 기존 시험 「거절돼도 receipt는 남는다」(`test/test_keeper_claude_code_runtime.ml:6927-6929`)는 그대로 통과한다.

PR A와 PR B는 이 PR 위에 `gh stack`으로 쌓는다.

**4. 이슈**

- antigravity·muse의 typed overflow와 hook.
- agent_core provider의 문장만 있는 크기 거절. parse 경계에서 typed 이유를 주게 한다.
- Codex의 10,485,760자 초과 `Inline` 묶음(§7). 구조안 둘을 같이 적는다.
- outbox가 codec이 이미 확인한 receipt 필드(`tool_name`, `call_id`, `host_producer_id`)를 다시 읽는다. 그래서 닿지 않는 `Error` 갈래가 생긴다. codec이 확인한 값을 돌려주게 한다.
- `keeper_turn_driver_try_provider.ml:2953`의 주석이 없는 함수 `Runtime_instance.prompt_capacity_bytes`를 가리킨다.

**5. 배포 뒤(운영자 승인)**

- 이미 잠긴 Keeper에 `restart_fresh`를 한 번 보낸다.
- 시험용 base path의 Keeper에 11-07 백업 receipt 248개를 넣고 한 턴을 돌린다. floor 거절 없이 끝나는지, outbox가 비는지 본다.

**6. 마무리**

- RFC 상태를 바꾼다. #49697을 닫거나 「쓸 때 줄이기」만 남기고 좁힌다.
