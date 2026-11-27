---
rfc: "finished-turn-result-plans-are-computed-once"
title: "끝난 턴의 메시지는 Keeper 마다 한 번만 잰다"
status: Draft
created: 2026-11-27
updated: 2026-11-27
author: claude
related: ["tool-results-age-out-of-context"]
---

# RFC finished-turn-result-plans-are-computed-once: 끝난 턴의 메시지는 Keeper 마다 한 번만 잰다

- 상태: **초안(2026-11-27).**
- 11-27 18:35 에 다시 띄운 masc 서버에서, 11분 뒤 CPU 풀 스레드 둘이 5초 표본 내내 쉬지 않았다.
- 두 스레드는 끝난 턴의 큰 도구 결과를 요청마다 다시 직렬화해서 크기를 잰다.
- 이 RFC 는 그 측정을 끝난 메시지 하나에 한 번으로 줄인다.

## 0. 요약

- Keeper 는 provider 요청을 보낼 때마다 `Keeper_model_input_demotion.plan` 으로 durable 기록 전체를 훑는다.
- 끝난 턴에서 2,048바이트를 넘는 도구 결과를 만나면 preview 를 만든다.
- 그다음 요청 본문을 직렬화해서 marker 로 바꾼 쪽이 더 작은지 잰다.
- Agent Core lane 은 잰 크기를 provider 시도(attempt) 하나 동안만 기억한다. 시도가 바뀌면 처음부터 다시 잰다.
- 공식 클라이언트 lane(Claude Code·Codex·Antigravity·ACP)은 잰 크기를 기억하지 않는다.
- 끝난 턴의 메시지는 다시 바뀌지 않는다. 메시지만 읽는 인코더의 측정값은 메시지로만 정해진다.
- 결정
  - D1. 메시지만 읽는 인코더의 측정값을 Keeper 와 인코더마다 기억한다. 프로세스가 사는 동안 남긴다.
  - D2. 공식 클라이언트 lane 네 곳은 인코더가 하나라서 표 하나를 같이 쓴다.
  - D3. 표마다 바이트 상한을 둔다. 두 걸음 동안 안 쓴 항목부터 빼고, 그래도 넘치면 새 항목을 넣지 않는다.
  - D4. provider 설정을 읽는 wire 인코더의 측정과 preview 는 2단계다. 설정을 키로 쓸 투영을 먼저 정한다.
- 바뀌지 않는 것: 어떤 결과가 marker 가 되는지, marker 글자, 요청 크기, durable 기록, checkpoint.

## 1. 관찰

### 1.1 CPU 표본

- macOS `sample <pid> 5` 로 5초씩 떴다. 파일은 `~/me/.tmp/masc-cpu-20261127/` 에 있다.
- 바쁜 표본은 스레드마다 대기 호출 밖에서 보낸 자기 시간(self)을 더한 값이다.
  - 대기 호출: `__psynch_cvwait`, `__psynch_mutexwait`, `kevent`, `poll`, `__ulock_wait` 등.
- 기계 load average 는 250~410 이었다. CPU 를 기다린 시간도 바쁜 표본에 들어가니 비율로 읽는다.

| 표본 | 프로세스 | 띄운 뒤 | 바쁜 표본 | 이 경로를 도는 스레드 |
|---|---|---|---|---|
| 15:10 | PID 10835 | 18분 (Fresh state 뒤) | — | 없음 |
| 17:30 | PID 10835 | 2시간 37분 | 3,183 | 1개: 1,022 (32%) |
| 18:46 | PID 98020 | 11분 | 4,244 | 2개: 958 + 958 (45%) |

- 18:46 두 스레드의 자기 시간 상위는 다음과 같다. JSON 문자열을 이스케이프하고 버퍼로 옮기는 일이다.
  - `Yojson.Safe.write_string_body` 302 + 345
  - `_platform_memmove` 124 + 115, `Stdlib.Buffer.add_substring` 120 + 110
  - `Stdlib.Bytes.unsafe_escape` 55 + 53
  - `Tool_blob_store.sanitize_utf8_slice` 50 (한 스레드. preview 를 만드는 함수다)
- 18:46 표본에서 Yojson 으로 들어간 경로 978개 중 976개는 바로 위가 잘려 있다.
  - OCaml 5 fiber 경계에서 native 스택이 끊긴다. 이 표본만으로는 누가 직렬화를 불렀는지 모른다.
  - 남은 2개는 `Keeper_claude_code_runtime.measure_model_input_message_bytes` ← `Keeper_model_input_demotion` 이다.
- 17:30 표본은 덜 잘렸다. 그 스레드에서 `plan` 이 부른 크기 memo 가 369 표본이다.
  - 그 아래 history JSON 측정이 250, wire 측정이 112 다. history JSON 은 provider 설정을 읽지 않는다.
  - memo 를 부른 자리는 메시지 비교(`keeper_model_input_demotion.ml:593`) 257, 본문 후보 비교(550) 85, 원래 블록 측정(567) 27 이다.
  - 같은 스레드에서 UTF-8 검사(`Utf8_sanitize`)가 268 이다.
  - 그중 166 은 `plan` 이 부른 측정 아래에 있다. 나머지 102 는 경로가 잘려 호출자를 모른다.

### 1.2 같은 표본의 다른 비용 (이 RFC 밖)

- 18:46 바쁜 표본의 41%(932 + 795)는 반응 원장 읽기다.
  - `Keeper_ask_answer_wake.pulse` 가 60초마다 답변된 질문의 전달 증명을 원장에서 다시 찾는다.
  - #55146, #55156, #55171, #55173 이 다룬다. #55146 댓글에 파일 수와 상한을 적었다.
- 메인 스레드의 TOML 파싱은 #55254 가 다룬다.

### 1.3 코드 (main `9cdbaa9ddf3ff`, 아래 파일은 `0473d5cc3aa30` 과 같다)

- 크기 memo 는 provider 시도마다 새로 만든다(`keeper_turn_driver_try_provider.ml:2248-2275`).
  - 주석: 턴 하나가 요청을 62~83번 보낸다(턴 두 개의 wire capture 실측). 요청마다 같은 기록을 다시 잰다.
  - 주석: 살아 있는 Keeper 의 기록은 메시지가 수만 개다.
- `plan` 은 durable 기록 전체를 받는다.
  - 같은 파일 1750-1758 이 `demotion_plan ~demote_before:finished messages` 를 부른다.
  - carried 창은 그 뒤 1771-1780 에서 자른다.
- `plan`(`keeper_model_input_demotion.ml:494-604`)은 끝난 메시지의 블록마다 아래 일을 한다.
  - `demotable_bodies`(403-424)로 2,048바이트(`aged_result_min_bytes`, try_provider 895) 이상인 본문을 고른다.
  - 본문마다 `planned_reference`(478-482)로 preview 를 만든다. preview 는 부를 때마다 `Buffer` 를 새로 만든다(`tool_blob_store.ml:218-232`).
  - 본문마다 그 블록 하나를 담은 provider 요청 본문을 통째로 직렬화해 길이를 잰다(545-567 → `keeper_model_input_wire_bytes.ml:48-58`).
  - 바뀐 메시지는 메시지 전체를 history 인코더로 두 번 더 잰다(593).
- 공식 클라이언트 lane 은 `keeper_official_client_host.ml:924-930` 에서 `plan` 을 부른다.
  - 두 측정 모두 `String.length (encode_history_message message)`(248)이고 memo 가 없다.
  - Claude Code(60)·Codex(106)·Antigravity(191) 런타임의 `measure_model_input_message_bytes` 와 ACP(2620)의 `Host.measure_message_bytes` 가 모두 이 식이다.

### 1.4 기억에 드는 값 (11-27 20~22시)

- run 을 시작할 때 넘겨받은 checkpoint 가 없으면 디스크에서 다시 읽는다(`keeper_run_context.ml:192-203`).
  - 그래서 앞 run 의 메시지 값은 이번 run 의 메시지와 문자열을 나눠 쓰지 않는다. 표의 키는 사본 하나를 붙잡는다.
- 기록을 셌다. 11-26 이후 snapshot 을 쓴 trace 14개의 history segment 와 turn bundle 을 읽었다.
  - 도구 결과 글이 2,048바이트 이상인 메시지: Keeper 하나에 많게는 3,295개(저장 JSON 28.6MB), 14개를 합치면 19,905개(206.1MB).
  - 이 서버(PID 98020)의 RSS(`ps -o rss`)
    - 띄운 지 1시간 59분: 8,045,856KiB(7.7GiB)
    - 3시간 12분(21:47): 10,642,176KiB(10.1GiB)
- history 인코더(`Keeper_context_core.message_measurer`)는 측정기 하나에 버퍼 하나를 둔다(`keeper_context_core_message_json.ml:169-189`). 측정기는 걸음 하나의 것이다.
- `Provider_config.t` 의 `credential_source` 는 `Refreshable_credential of (unit -> …)` 를 담는다.
  - `Stdlib.compare` 는 함수 값에서 예외를 낸다. 설정 값을 통째로 표의 키로 쓸 수 없다.
  - 응답 캐시는 필드를 빠짐없이 펼쳐(warning 9) 고른 값만 키에 넣는다(`packages/agent_core/lib/llm_provider/cache.ml`).

## 2. 원인

- 끝난 턴의 메시지는 durable 기록에서 바뀌지 않는다.
- history 인코더와 공식 lane 인코더의 측정값은 메시지로만 정해진다.
- 그런데 Agent Core lane 은 측정값을 provider 시도 하나 동안만 기억한다. 공식 클라이언트 lane 은 기억하지 않는다.
- 그래서 CPU 는 새로 끝난 결과 수가 아니라 「durable 기록에 쌓인 큰 결과 수 × 시도 수」를 따라 는다.
- Fresh state 뒤에는 끝난 턴이 없어서 `plan` 이 497-498 에서 바로 끝난다. 15:10 에 이 경로가 없던 까닭이다.
- 18:35 재시작 뒤에는 11분 만에 나타났다. 비용이 가동 시간이 아니라 남은 기록을 따른다는 뜻이다.

## 3. 결정

### D1. 메시지만 읽는 인코더의 측정값을 Keeper 와 인코더마다 기억한다

- 새 모듈 `Keeper_message_measurement_memo` 가 표를 가진다.
- 인코더는 그 인코딩을 가진 모듈이 한 번 만든다. 측정기를 만드는 함수와 상한을 묶는다.
  - Agent Core history: `Keeper_context_core.message_measurer` (try_provider)
  - 공식 클라이언트: `String.length (encode_history_message message)` (official client host)
  - 인코더 값은 만들 때마다 번호가 다르다. 같은 표에 다른 인코딩이 섞일 수 없다.
- 걸음(walk)은 기록을 한 번 훑는 단위다. Agent Core 는 provider 시도 하나, 공식 lane 은 턴 하나다.
  - 걸음마다 그 인코더의 측정기를 새로 만든다. 측정기의 버퍼는 걸음끼리 나누지 않는다.
- 키는 지금 memo 처럼 메시지 값(`Agent_core.Types.Message_value`)이다. 값은 바이트 수 하나다.
- 맞는 항목을 찾으면 키를 이번 걸음의 메시지로 바꾼다.
  - 앞 run 의 사본은 GC 가 거둔다. 같은 run 의 다음 조회는 물리적으로 같은 값을 비교하고 끝난다.
- 표는 시도와 턴이 끝나도 남는다. 프로세스가 끝나면 사라진다.
- provider 설정을 읽는 wire 측정기는 지금처럼 시도마다 memo 한다(D4).

### D2. 공식 클라이언트 lane 은 인코더 하나로 표를 같이 쓴다

- 네 런타임의 측정기가 같은 식이다(§1.3). 인코더를 하나만 만든다.
- `start_range_projection` 이 걸음을 연다. 런타임이 측정기를 따로 넘기지 않게 인자를 없앤다.

### D3. 표마다 바이트 상한을 둔다

- 상한은 표 하나에 64MiB 다. 항목의 크기는 그 메시지를 잰 바이트 수로 센다.
  - 키가 붙잡는 문자열은 인코딩한 길이보다 크지 않다. 이스케이프는 길이를 늘리기만 한다.
    - 인코딩 전 UTF-8 수리도 잘못된 바이트 하나를 U+FFFD 세 바이트로 바꾼다(`lib/core/safe_ops.ml:204-217`).
  - §1.4 에서 가장 큰 Keeper 가 28.6MB 다. 두 배 남짓 여유를 둔다.
- 새 항목이 상한을 넘기면, 이번 걸음과 바로 앞 걸음이 묻지 않은 항목을 먼저 뺀다.
- 그래도 넘치면 새 항목을 넣지 않는다. 측정값은 그대로 돌려준다.
- 한 걸음은 표를 한 번만 훑는다.
  - 항목은 걸음을 얻기만 한다. 같은 걸음이 다시 훑어도 뺄 항목이 없다.
  - 이 제한이 없으면, 기록이 상한보다 큰 Keeper 는 넣지 못한 메시지마다 표 전체를 훑는다.
- LRU 로 빼지 않는다.
  - 걸음은 기록을 늘 같은 순서로 훑는다. 작업 집합이 상한을 넘으면 LRU 는 모든 조회를 놓친다.
  - #55146 의 원장 파일 캐시(256개, 파일 549개)가 그렇게 됐다.
- 상한은 정확성이 아니라 메모리만 정한다. 빠진 메시지는 다음에 다시 잰다. 값은 같다.
- 표 접근은 표마다 mutex 로 감싼다. 측정은 lock 밖에서 한다.
  - 한 Keeper 의 시도는 차례로 돌지만, CPU 풀 job 은 다른 domain 에서 돈다.

### D4. wire 측정과 preview 는 2단계에서 다룬다

- wire 측정기는 `Provider_config.t` 에 따라 다르다. 설정을 키로 쓰려면 §1.4 의 `cache.ml` 처럼 필드를 펼쳐 고른 투영이 필요하다.
- preview(`Tool_blob_store.make_preview`)는 본문으로만 정해진다. 그러나 시도를 넘어 기억하려면 본문 사본이나 다른 키가 필요하다.
- 이 둘은 D1~D3 를 배포해서 잰 뒤 다룬다. 17:30 표본에서 wire 는 memo 아래 369 중 112 다.

## 4. 바뀌는 동작

- 사용자에게 보이는 변화는 없다. 같은 결과가 같은 marker 로 나가고 요청 크기도 같다.
- 프로세스를 띄운 뒤 Keeper 의 첫 걸음은 지금과 같은 일을 한다.
- 같은 Keeper 의 다음 걸음에서는 메시지만 읽는 인코더의 측정이 표 조회로 끝난다.
- 메모리
  - run 이 도는 동안에는 키가 그 run 의 메시지를 가리켜서 따로 드는 메모리가 거의 없다.
  - run 사이에는 표가 마지막 run 의 측정된 메시지를 붙잡는다. 11-27 기록으로는 모두 합쳐 206MB 남짓이다.
  - 표 하나의 상한은 64MiB 다. 공식 lane 과 Agent Core 를 함께 쓴 Keeper 는 표가 둘이다.

## 5. 경계 조건과 한계

- 메시지 값이 같으면 측정값도 같아야 한다.
  - `Message_value.equal` 은 `Stdlib.compare` 로 모든 필드를 비교한다(`packages/agent_core/lib/llm_provider/types.mli:604-623`).
  - raw JSON 안의 `0.0` 과 `-0.0` 은 같다고 보지만 1바이트 다르게 인코딩된다. 지금 memo 도 같은 차이를 받아들인다(try_provider 774-780).
  - 해시는 문자열 일부만 본다. 충돌은 비교로 걸러진다.
- Keeper 를 지우거나 이름을 바꾸면 옛 이름의 표는 프로세스가 끝날 때까지 남는다. 상한이 크기를 막는다.
- 조회 비용은 남는다. 메시지마다 해시와 비교를 하고, 메시지 수만 개 × 요청 수만큼 반복한다.
- 18:46 표본은 경로가 잘려서 직렬화의 호출자를 다 보여 주지 않는다.
  - 근거는 17:30 표본의 경로와 코드다. 확신도는 Medium 이다.

## 6. 하지 않는 것

- 어떤 결과를 marker 로 바꿀지의 규칙(`tool-results-age-out-of-context`)은 바꾸지 않는다.
- durable 기록과 checkpoint 에 marker 를 쓰지 않는다. 기록은 지금처럼 본문 전체를 가진다.
- carried 창을 `plan` 앞에서 자르지 않는다. 창 경계는 marker 로 줄어든 크기로 정해지기 때문이다.
- 반응 원장 읽기(#55146, #55173)와 TUI 설정 TOML 파싱(#55254)은 다루지 않는다.
- 조회마다 메시지 하나를 다시 인코딩하는 `runtime_model_input_tail_window.ml:222-244` `digest_for_labelled` 도 다루지 않는다.

## 7. Fresh state required

- 아니다. 표는 메모리에만 있고 저장 형식이 바뀌지 않는다.

## 8. 검증

- 시험
  - 같은 Keeper 와 인코더로 걸음 두 번을 돈다. 둘째 걸음은 값이 같은 새 메시지 레코드를 재지 않고 같은 값을 돌려준다.
  - Keeper 가 다르거나 인코더가 다르면 표를 나눠 쓰지 않는다.
  - 상한을 넘으면 새 항목을 넣지 않고, 그래도 잰 값을 돌려준다.
  - 두 걸음 동안 안 쓴 항목은 자리가 모자랄 때 빠진다.
  - 한 걸음이 상한을 넘겨도 메시지마다 제 크기를 돌려주고, 먼저 넣은 항목은 남는다.
- 운영
  - 배포한 뒤, 재시작 11분 뒤와 2시간 뒤에 `sample <pid> 5` 를 뜬다.
  - 스레드별 바쁜 표본에서 `Yojson.Safe.write_string_body` 가 주로 쓰는 스레드의 몫을 18:46(45%)과 비교한다.
  - 띄운 지 2시간 무렵의 RSS 를 PID 98020 의 8,045,856KiB(1시간 59분)와 비교한다.
  - wire capture 로 요청 바이트가 바뀌지 않았는지 본다.
