---
rfc: "finished-turn-result-plans-are-computed-once"
title: "끝난 턴의 도구 결과는 Keeper 와 lane 마다 한 번만 계획한다"
status: Draft
created: 2026-11-27
updated: 2026-11-27
author: claude
related: ["tool-results-age-out-of-context"]
---

# RFC finished-turn-result-plans-are-computed-once: 끝난 턴의 도구 결과는 Keeper 와 lane 마다 한 번만 계획한다

- 상태: **초안(2026-11-27).**
- 11-27 18:35 에 다시 띄운 masc 서버에서, 11분 뒤 CPU 풀 스레드 둘이 5초 표본 내내 쉬지 않았다.
- 두 스레드는 끝난 턴의 큰 도구 결과를 요청마다 다시 직렬화해서 크기를 잰다.
- 이 RFC 는 그 계산을 끝난 메시지 하나에 한 번으로 줄인다.

## 0. 요약

- Keeper 는 provider 요청을 보낼 때마다 `Keeper_model_input_demotion.plan` 으로 durable 기록 전체를 훑는다.
- 끝난 턴에서 2,048바이트를 넘는 도구 결과를 만나면 preview 를 만든다.
- 그다음 요청 본문을 직렬화해서 marker 로 바꾼 쪽이 더 작은지 잰다.
- Agent Core lane 은 잰 크기를 provider 시도(attempt) 하나 동안만 기억한다. 시도가 바뀌면 처음부터 다시 잰다.
- 공식 클라이언트 lane(Claude Code·Codex·Antigravity·ACP)은 잰 크기를 기억하지 않는다.
- 끝난 턴의 메시지는 다시 바뀌지 않는다. 그 메시지의 계획은 메시지와 lane 의 wire 인코더만으로 정해진다.
- 결정
  - D1. 끝난 메시지 하나의 계획을 Keeper 와 wire 인코더마다 기억한다. 프로세스가 사는 동안 남긴다.
  - D2. 공식 클라이언트 lane 도 같은 기억을 쓴다.
  - D3. 기억에는 상한을 둔다. 밀려난 메시지는 다시 계산하고, 결과는 같다.
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
  - 그 아래 history JSON 측정이 250, wire 측정이 112 다.
  - memo 를 부른 자리는 메시지 비교(`keeper_model_input_demotion.ml:593`) 257, 본문 후보 비교(550) 85, 원래 블록 측정(567) 27 이다.
  - 같은 스레드에서 UTF-8 검사(`Utf8_sanitize`)가 268 이다.
  - 그중 166 은 `plan` 이 부른 측정 아래에 있다. 나머지 102 는 경로가 잘려 호출자를 모른다.

### 1.2 같은 표본의 다른 비용 (이 RFC 밖)

- 18:46 바쁜 표본의 41%(932 + 795)는 반응 원장 읽기다.
  - `Keeper_ask_answer_wake.pulse` 가 60초마다 답변된 질문의 전달 증명을 원장에서 다시 찾는다.
  - 원장은 Keeper 28개, 날짜 파일 549개, 301.7MB 다. 파일 캐시 상한은 256개다(`keeper_reaction_ledger.ml:1127`).
  - #55146, #55156(18:41 병합, 이 프로세스에는 없음), #55171, #55173 이 다룬다.
- 메인 스레드는 376(9%)이다. 그중 일부는 TUI 설정을 읽을 때마다 TOML 을 다시 파싱하는 일이다.
  - `Tui_preference.settings_of_reading` ← `handle_tui_preferences_get`.

### 1.3 코드 (main `0473d5cc3aa30`)

- 크기 memo 는 provider 시도마다 새로 만든다(`keeper_turn_driver_try_provider.ml:2248-2275`).
  - 주석: 턴 하나가 요청을 62~83번 보낸다(턴 두 개의 wire capture 실측). 요청마다 같은 기록을 다시 잰다.
  - 주석: 살아 있는 Keeper 의 기록은 메시지가 수만 개다.
- `plan` 은 durable 기록 전체를 받는다.
  - 같은 파일 1750-1758 이 `demotion_plan ~demote_before:finished messages` 를 부른다.
  - carried 창은 그 뒤 1771-1780 에서 자른다.
- `plan`(`keeper_model_input_demotion.ml:494-604`)은 끝난 메시지의 블록마다 아래 일을 한다.
  - `demotable_bodies`(403-424)로 2,048바이트(`aged_result_min_bytes`, try_provider 895) 이상인 본문을 고른다.
  - 본문마다 `planned_reference`(478-482)로 preview 를 만든다. preview 는 부를 때마다 `Buffer` 를 새로 만든다(`tool_blob_store.ml:218-232`). 이 일은 memo 가 없다.
  - 본문마다 그 블록 하나를 담은 provider 요청 본문을 통째로 직렬화해 길이를 잰다(545-567 → `keeper_model_input_wire_bytes.ml:48-58`).
  - 바뀐 메시지는 메시지 전체를 두 번 더 잰다(593).
- 공식 클라이언트 lane 은 `keeper_official_client_host.ml:924-930` 에서 `plan` 을 부른다.
  - 두 측정 모두 `String.length (encode_history_message message)`(248)이고 memo 가 없다.
  - 이 경로는 Claude Code·Codex·Antigravity·ACP 런타임이 `start_range_projection`(943)으로 부른다.

## 2. 원인

- 끝난 턴의 메시지는 durable 기록에서 바뀌지 않는다.
- 계획의 입력도 바뀌지 않는다. 메시지, lane 의 wire 인코더, 2,048바이트 기준이다.
- 자리 토큰(`placeholder_sha256`, demotion 533-538)은 메시지 위치로 만들지만 폭이 고정이다. 그래서 크기와 "marker 가 더 작은가"의 답은 위치와 상관없다.
- 그런데 Agent Core lane 은 계산을 provider 시도 하나 동안만 기억한다. 공식 클라이언트 lane 은 기억하지 않는다.
- 그래서 CPU 는 새로 끝난 결과 수가 아니라 「durable 기록에 쌓인 큰 결과 수 × 시도 수」를 따라 는다.
- Fresh state 뒤에는 끝난 턴이 없어서 `plan` 이 497-498 에서 바로 끝난다. 15:10 에 이 경로가 없던 까닭이다.
- 18:35 재시작 뒤에는 11분 만에 나타났다. 비용이 가동 시간이 아니라 남은 기록을 따른다는 뜻이다.

## 3. 결정

### D1. 끝난 메시지의 계획을 Keeper 와 wire 인코더마다 기억한다

- 기억하는 단위는 끝난 메시지 하나의 계획이다.
  - 어느 본문을 marker 로 바꾸는지
  - 본문마다 preview 와 바이트 수
  - 그 결정을 내린 크기(바꾸기 전과 뒤)
- 키는 지금 memo 처럼 메시지 값(`Agent_core.Types.Message_value`)이다.
  - 요청마다 projection 이 레코드를 새로 만들기 때문이다(try_provider 774-780 주석).
- 표는 Keeper 마다 하나다. 그 안을 wire 인코더마다 나눈다.
  - wire 인코더를 정하는 값은 provider 종류, dialect, 모델처럼 요청 본문의 모양을 바꾸는 필드다.
  - API 키 같은 비밀값은 키에 넣지 않는다.
- 표는 시도와 턴이 끝나도 남는다. 프로세스가 끝나면 사라진다.
- `plan` 은 끝난 메시지를 만나면 표를 먼저 본다.
  - 있으면 기억한 계획에 지금 자리 토큰만 붙여 후보를 만든다.
  - 없으면 지금처럼 계산하고 표에 넣는다.
- 이번 턴의 인자 시드(`completed_arguments`)가 걸린 메시지는 기억하지 않는다. 자리(occurrence)에 묶인 입력이라서다.

### D2. 공식 클라이언트 lane 도 같은 표를 쓴다

- `keeper_official_client_host.ml:924-930` 은 D1 의 표를 받아 쓴다.
- 그 lane 의 wire 인코더는 `encode_history_message` 다. 다른 lane 과 항목을 나누지 않는다.

### D3. 표에는 상한을 둔다

- Keeper 하나의 표에 메시지 수 상한을 둔다. 넘으면 가장 오래 안 쓴 항목을 뺀다.
- 빠진 메시지는 다음에 다시 계산한다. 결과는 같다. 상한은 정확성이 아니라 메모리만 정한다.
- 상한 값은 구현 PR 에서 정한다. Keeper 마다 끝난 큰 결과 수와 preview 메모리를 재고 고른다.
  - 비슷한 선례: `keeper_model_input_ledger.ml:508` 의 `max_entries = 512`.
- 표 접근은 mutex 로 감싼다. 한 Keeper 의 턴은 차례로 돌지만, CPU 풀 job 은 다른 domain 에서 돌 수 있다.

## 4. 바뀌는 동작

- 사용자에게 보이는 변화는 없다. 같은 결과가 같은 marker 로 나가고 요청 크기도 같다.
- 프로세스를 띄운 뒤 Keeper 의 첫 시도는 지금과 같은 일을 한다.
- 같은 Keeper 의 다음 시도와 다음 턴에서는 끝난 메시지마다 표 조회 한 번으로 끝난다.
- 메모리는 Keeper 마다 표 상한만큼 는다. 항목은 크기 정수와 4,096바이트 이하 preview 다.

## 5. 경계 조건과 한계

- 메시지 값이 같으면 계획도 같아야 한다.
  - `Message_value.equal` 은 모든 필드를 구조적으로 비교한다(`packages/agent_core/lib/llm_provider/types.ml:719-800`).
  - 해시는 문자열 일부만 본다. 충돌은 비교로 걸러진다.
- 모델 전환이나 failover 로 provider 설정이 바뀌면 다른 wire 인코더 키를 쓴다. 이전 키의 항목은 상한에 따라 빠진다.
- 조회 비용은 남는다. 끝난 메시지마다 해시와 비교를 하고, 메시지 수만 개 × 요청 수만큼 반복한다.
  - 직렬화보다 작지만 0 은 아니다. 측정해서 크게 남으면 §6 의 창 자르기를 따로 다룬다.
- 18:46 표본은 경로가 잘려서 직렬화의 호출자를 다 보여 주지 않는다.
  - 근거는 17:30 표본의 경로와 코드다. 확신도는 Medium 이다.
  - 구현 PR 은 측정기 호출 수 시험으로 효과를 직접 보인다(§8).

## 6. 하지 않는 것

- 어떤 결과를 marker 로 바꿀지의 규칙(`tool-results-age-out-of-context`)은 바꾸지 않는다.
- durable 기록과 checkpoint 에 marker 를 쓰지 않는다. 기록은 지금처럼 본문 전체를 가진다.
- carried 창을 `plan` 앞에서 자르지 않는다. 창 경계는 marker 로 줄어든 크기로 정해지기 때문이다.
- 반응 원장 읽기(#55146, #55173)와 TUI 설정 TOML 파싱은 다루지 않는다.
- 조회마다 메시지 하나를 다시 인코딩하는 `runtime_model_input_tail_window.ml:222-244` `digest_for_labelled` 도 다루지 않는다.

## 7. Fresh state required

- 아니다. 표는 메모리에만 있고 저장 형식이 바뀌지 않는다.

## 8. 검증

- 시험
  - 같은 기록으로 시도 두 번을 돌린다. 표가 있을 때와 없을 때 `plan` 결과가 같은지 본다.
  - 두 번째 시도에서, 끝난 메시지에 대한 두 측정기 호출 수가 0 인지 센다.
  - wire 인코더 키가 다른 두 lane 이 항목을 나눠 쓰지 않는지 본다.
  - 상한을 1 로 두어도 결과가 같은지 본다.
- 운영
  - 배포한 뒤, 재시작 11분 뒤와 2시간 뒤에 `sample <pid> 5` 를 뜬다.
  - 스레드별 바쁜 표본에서 `Yojson.Safe.write_string_body` 가 주로 쓰는 스레드의 몫을 18:46(45%)과 비교한다.
  - wire capture 로 요청 바이트가 바뀌지 않았는지 본다.
