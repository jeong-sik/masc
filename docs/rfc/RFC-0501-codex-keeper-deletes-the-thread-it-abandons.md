---
rfc: "0501"
title: "Codex Keeper 는 세션 기록이 잊은 thread 를 지운다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["0495"]
---

# RFC-0501 — Codex Keeper 는 세션 기록이 잊은 thread 를 지운다

## 0. 요약

- Codex 계정 home 하나의 `sessions` 에 rollout 이 7,008개, 11.9 GB 쌓였다(#49031). Keeper 세션 기록이 가리키는 것은 3개뿐이다.
- Keeper 세션 기록이 thread id 를 잊는 때가 둘이다. 새 thread 로 가는 claim, 그리고 일시 오류 뒤 `Ready` 로 돌리는 release 다. 어느 쪽도 vendor 쪽 rollout 은 지우지 않는다.
- Codex app-server 에는 `thread/delete` 가 있다. codex-cli 0.166.0 에서 rollout 파일을 지우는 것을 확인했다.
- 제안: 기록이 바뀔 때 잊은 thread id 를 순수 함수로 계산한다. Codex Keeper 턴이 끝나면 그 id 들을 `thread/delete` 한다.
- 이어 갈 일이 없는 호출(Fusion, capability probe)은 `ephemeral` thread 를 연다.
- 세션 저장소(`session.json`) 스키마는 바꾸지 않는다. 이미 쌓인 rollout 은 hard cut 이다.

## 1. 지금

### 1.1 쌓이는 양

11-06 KST 에 크기·개수·메타데이터 키만 쟀다. 기록 내용은 읽지 않았다. rollout 이 있는 Codex 계정 home 은 하나다.

| 무리 | rollout | 바이트 | 마지막 날 |
| --- | ---: | ---: | --- |
| 동적 도구 `masc` 하나, 턴 2개 이상 | 1,995 | 9,043,684,426 | 11-03 |
| 동적 도구 `masc` 하나, 턴 1개 | 496 | 1,467,094,072 | 11-03 |
| 동적 도구 없음, 턴 1개 | 4,517 | 1,402,317,417 | 10-26 |

- 턴 수는 rollout 안의 `turn_context` 줄 수다. 모든 rollout 의 `originator` 는 `masc` 다.
- 턴 2개 이상은 Keeper 턴이다. 다른 호출처는 thread 를 이어 가지 않는다(1.2).
- 턴 1개짜리 `masc` thread 는 Keeper 턴과 capability probe 를 못 나눈다. 둘 다 동적 도구를 넘긴다.
- 동적 도구가 있는 쪽은 10-28 ~ 11-03 한 주에 1,177개, 약 5.8 GB 가 생겼다. 11-03 에 Codex 사용 한도로 Codex Keeper 가 멈춰 그 뒤로는 늘지 않았다.
- 같은 home 에 `thread_history_1.sqlite` 3.6 GB, `state_5.sqlite` 1.48 GB 가 있다.
- Keeper 세션 기록 `session.json` 43개가 담은 id 42개 중, 이 home 의 rollout 과 맞는 것은 3개(7.1 MB)다.

### 1.2 MASC 가 Codex thread 를 여는 곳

`Runtime_codex_app_server.run_turn` 호출처는 넷이다. `thread_is_ephemeral = false` 라서 `thread/start` 로 연 thread 는 모두 디스크에 남는다.

| 호출처 | 계정 home | `thread_mode` | 이어 가기 |
| --- | --- | --- | --- |
| `Keeper_codex_runtime` | 계정 home | `Start` 또는 `Resume` | 한다 |
| `Fusion_official_client` | 계정 home | 기본값 `Start` | 안 한다 |
| `Keeper_capability_probe` | 계정 home | 기본값 `Start` | 안 한다 |
| `Runtime_verification` | 실행 폴더 안 `codex-home`(`isolated_home`) | 기본값 `Start` | 안 한다 |

`?thread_mode` 의 기본값이 `Start` 라서, 이어 가지 않는 호출처도 남는 thread 를 연다.

### 1.3 기록이 thread 를 잊는 때

`Keeper_official_client_session_store` 의 기록은 단계마다 thread id 를 담는다. `Settled`·`Active`·`Turn_inflight` 는 `session_id` 를, `Start`·`Active`·`Turn_inflight` 는 `previous_settlement` 를, `Recovery_required` 는 `observed_session_id` 와 `previous_settlement` 를 담는다. `Ready` 는 아무 id 도 담지 않는다.

기록이 thread 를 잊는 길은 둘이다.

1. 새 thread 로 가는 claim. `plan_claim` 과 `reconcile_tool_surface` 가 계획에서 `previous_settlement` 를 비우면, `claim_with_context_frontier` 가 `Start { previous_settlement = None }` 을 저장한다.
   - 기록이 `Recovery_required` 일 때(`Input_rejected` 는 거절)
   - 기록이 `Settled` 인데 도구 목록 digest 가 바뀌었을 때. 도구를 더하거나 설명을 고치는 배포마다 바뀐다.
   - 기록이 `Settled` 인데 client 종류나 runtime id 가 바뀌었을 때
2. `release_transient`. 새 thread 로 시작한 턴(`previous_settlement = None`)이 일시 오류로 끝나면 기록을 `Ready` 로 돌린다. 그 턴이 연 `session_id` 는 사라진다.

잊은 id 를 다시 읽는 곳은 없다.

11-06 에 서버 로그 8일치(10-30 ~ 11-06, 모든 official client)를 셌다. 1번의 `Recovery_required` 갈래가 4,898번(`provider_rejected` 4,615, `protocol_failed` 189, `transport_interrupted` 86, `process_restarted` 8)이다. 2번이 164번(`owner_stopped_turn` 126, `pre_dispatch_failed` 38)이다. 도구 목록 digest 갈래는 로그가 없어 세지 못했다.

같은 Keeper 의 claim 은 겹치지 않는다. 기록이 `Start`·`Active`·`Turn_inflight` 이면 `plan_claim` 이 거절한다.

### 1.4 지울 길이 있다

- `codex app-server generate-json-schema`(0.166.0)에 `thread/delete`·`thread/archive`·`thread/list` 가 있다. `thread/delete` 의 인자는 `threadId` 하나다.
- 임시 `CODEX_HOME` 에 rollout 하나를 복사해 `thread/delete` 를 불렀다.
  - 응답은 `{}` 이고, rollout 파일이 지워지고, `thread/deleted` 알림이 온다.
  - 같은 id 를 다시 지우면 `-32600 no rollout found for thread id …` 로 거절한다.
  - 로그인 없이 동작한다. `initialize` 만 하면 된다.
- upstream `codex-rs/thread-store/src/local/delete_thread.rs`(main) 는 rollout 파일, `thread_history` 행, state DB 행을 지운다. 붙은 하위 thread 가 있으면 거절한다.

Muse 에는 세션을 지우는 요청이 없어서 RFC-0495 는 storage root 를 비운다. Codex 는 계정 home 에 `auth.json` 과 설정이 같이 있어 비울 수 없다. 대신 thread 를 하나씩 지울 수 있다.

## 2. 제안

### 2.1 기록이 잊은 thread 를 계산한다

`Keeper_official_client_session_store` 에 순수 함수 하나를 더한다.

```ocaml
type forgotten =
  | Same_client of string list
  | Other_client of
      { client_kind : client_kind; runtime_id : string; session_ids : string list }

val forgotten_sessions : before:t option -> after:t -> forgotten
```

- `before` 단계가 담은 thread id 중 `after` 단계가 담지 않은 것을 낸다. 1.3 의 단계별 id 를 쓴다.
- `before` 가 `None`(앞 기록 없음)이면 `Same_client []` 다.
- `before` 와 `after` 의 client 종류와 runtime id 가 같으면 `Same_client`, 다르면 `before` 쪽 정체를 담은 `Other_client` 다(2.4).
- 단계 match 는 생성자를 모두 적는다. 와일드카드는 없다. 새 단계가 생기면 컴파일러가 이 함수를 고치게 한다.

1.3 의 두 길에 넣으면 이렇다.

| before | after | 내는 id |
| --- | --- | --- |
| `Settled s` | `Start { previous_settlement = None }` | `s.session_id` |
| `Settled s` | `Start { previous_settlement = Some s }` | 없음 |
| `Recovery_required r` | `Start { previous_settlement = None }` | `r.observed_session_id`, `r.previous_settlement` 의 id |
| `Active`·`Turn_inflight { session_id = x; previous_settlement = None }` | `Ready` | `x` |
| `Turn_inflight { session_id = x }` | `Settled { session_id = x }` | 없음 |

새 상태나 필드는 없다. 이미 저장하는 두 기록에서 계산한다.

### 2.2 Codex Keeper 턴이 끝나면 지운다

`Runtime_codex_app_server` 에 함수 하나를 더한다.

```ocaml
val delete_threads :
  mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock -> cwd:Eio.Fs.dir_ty Eio.Path.t ->
  config -> string list -> ((string * (unit, error) result) list, error) result
```

바깥 `Error` 는 app-server 를 띄우지 못했거나 `initialize` 가 실패한 경우다. 안쪽 목록은 id 마다 `thread/delete` 의 답이다.

- 턴과 같은 계정 home 으로 app-server 를 띄우고 `initialize` 뒤 id 마다 `thread/delete` 를 보낸다. `account/read` 는 보내지 않는다.
- `Keeper_codex_runtime` 은 턴이 지나간 기록(불러온 기록, claim, 그 뒤 전이마다)을 모두 모은다. 턴이 끝나면 모은 기록 하나하나를 마지막 기록과 2.1 로 견주고, `Same_client` id 를 한 목록으로 합친다. 한 전이와 바로 다음 전이를 견주지 않는다. 설정 단계에서 거절되면 `revert_claim` 이 claim 이 잊은 thread 를 다시 담는데, 이 thread 는 지우면 안 된다.
- `run_turn` 이 돌아오고 기록을 정리한 뒤, 결과와 상관없이 한 번 부른다. 모은 id 가 없으면 부르지 않는다. 취소로 끝난 턴은 예외를 다시 올리므로 지우지 않는다.
- 결과는 Keeper 로그에 id 마다 한 줄씩 남긴다. 성공이거나, 오류의 code 와 message 그대로다.
- `-32600 no rollout found` 를 "이미 없음"으로 따로 나누지 않는다. `-32600` 은 invalid request 일반 코드이고, 둘을 가르는 것은 message 문자열뿐이다. 문자열로 분류하지 않는다. 배포 뒤에는 로그 줄을 code·message 별로 센다.
- 실패해도 턴 결과는 바꾸지 않는다. 기록이 이미 그 id 를 잊었으니 이어 갈 길이 없다.
- 다시 시도하지 않는다. 실패한 id 를 저장하는 필드도 두지 않는다. 디스크가 남는 일은 durable truth 를 해치지 않는다.

턴 앞이 아니라 뒤에서 지운다. 앞에서 지우면 새 thread 를 여는 턴마다 app-server 를 한 번 더 띄우는 만큼 늦어진다. release 로 잊는 id 는 턴이 끝나야 생긴다. 앞에서 지우려면 지우지 못한 id 를 저장해야 하는데, 이 RFC 는 그 필드를 두지 않는다.

지우는 app-server 와 다른 Keeper 의 app-server 가 같은 계정 home 을 함께 쓸 수 있다. 지금도 Codex Keeper 여럿과 Fusion·probe 가 한 계정 home 을 같이 쓴다. 새로 생기는 겹침이 아니라서 따로 막지 않는다.

### 2.3 이어 가지 않는 호출은 `Ephemeral`

```ocaml
type thread_mode =
  | Start
  | Resume of { thread_id : string }

type thread =
  | Ephemeral
  | Persistent of thread_mode
```

- `run_turn` 과 `validate_turn` 의 `?thread_mode` 를 없애고 `~thread` 를 필수로 한다. 호출처마다 고른다.
- `Keeper_codex_runtime` 은 `Persistent thread_mode` 를 넘긴다. Keeper 가 들고 다니는 `thread_mode` 는 그대로다. `Ephemeral` 을 `thread_mode` 에 넣으면 Keeper 의 `thread_mode` match 12곳에 일어나지 않는 갈래가 생긴다. 그래서 감싸는 타입을 따로 둔다.
- `Fusion_official_client`, `Keeper_capability_probe`, `Runtime_verification` 은 `Ephemeral` 을 넘긴다. `thread/start` 에 `"ephemeral": true` 를 보낸다. `Persistent Start` 는 `false` 를, `Resume` 은 이 필드를 보내지 않는다.
- `Runtime_verification` 은 실행 폴더 안 `codex-home` 을 쓴다. `Ephemeral` 로 바꿔도 그 폴더의 수명은 바뀌지 않는다.
- `thread_is_ephemeral` 상수는 지운다. 값은 생성자가 정한다.

11-06 에 codex-cli 0.166.0 으로 확인했다. 빈 임시 `CODEX_HOME` 과 로컬 모의 Responses 서버를 썼다. 실제 계정과 모델은 쓰지 않았다. 동적 도구 하나(`masc/probe_echo`)를 넘기고 턴 하나를 끝까지 돌렸다.

| `ephemeral` | `thread/start` 답의 `path` | 모델 요청의 도구 목록 | `sessions/` rollout | `state_5` `threads` 행 | `thread_history_1.sqlite` |
| --- | --- | --- | --- | --- | --- |
| `true` | null | `masc/probe_echo` 있음 | 0개 | 0 | 없음 |
| `false` | 있음 | `masc/probe_echo` 있음 | 1개 | 1 | turns 1, items 2 |

두 경우 모두 `thread/tokenUsage/updated` 와 `turn/completed` 가 왔다. `Fusion_official_client` 가 읽는 thread 사용량 알림은 `Ephemeral` 에서도 온다.

### 2.4 client 나 계정이 바뀐 thread

runtime id 나 client 종류가 바뀌면 옛 thread 는 다른 계정 home 이나 다른 client 에 있을 수 있다. 지금 runtime 의 app-server 로는 지울 수 없다. 옛 home 에서 지우려면 MASC 가 지난 모든 runtime 의 계정을 기억해야 한다. 이 경우는 지우지 않는다.

`Other_client` 를 받으면 Keeper 로그에 한 줄을 남긴다. 옛 client 종류, 옛 runtime id, 잊은 id 수다. 계정 home 경로는 기록에 없어 적지 않는다. 6장의 질문은 이 줄 수로 정한다.

같은 runtime id 인데 운영자가 계정 home 을 바꾸면, 새 home 에 `thread/delete` 를 보내고 `no rollout found` 를 받는다. 로그에 남고 옛 home 의 rollout 은 그대로다.

### 2.5 하드컷

이미 쌓인 rollout 은 옮기거나 지우는 코드를 만들지 않는다. 운영자가 배포 때 지운다.

1. 서버를 멈춘다.
2. Codex 계정 home 마다 `sessions`, `state_5.sqlite*`, `thread_history_1.sqlite*` 를 지운다. 지금 어느 runtime 도 쓰지 않는 옛 계정 home 도 같다.
3. 새 버전으로 서버를 띄운다.

`auth.json`, `config.toml` 은 남긴다. 기억한 thread 가 있던 Keeper(11-06 측정으로 3개)는 다음 `thread/resume` 이 한 번 실패하고, 그다음 claim 이 새 thread 를 연다. 이 실패는 예상된 것이라고 changelog 에 적는다. 이 절차가 로그인 상태를 지키는지는 L4 전에 임시 home 복사본에서 확인한다.

## 3. 바뀌는 것

| 모듈 | 바뀌는 것 |
| --- | --- |
| `Keeper_official_client_session_store` | `forgotten` 타입과 `forgotten_sessions` 추가 |
| `Runtime_codex_app_server` | `delete_threads` 추가, `thread = Ephemeral \| Persistent of thread_mode` 추가, `run_turn`·`validate_turn` 의 `~thread` 필수, `thread_is_ephemeral` 상수 삭제 |
| `Keeper_codex_runtime` | 턴이 지나간 기록을 모아 마지막 기록과 견주고, 잊은 id 를 턴 뒤 `delete_threads` 로 지운다. `~thread:(Persistent thread_mode)` 를 넘긴다 |
| `Fusion_official_client`, `Keeper_capability_probe`, `Runtime_verification` | `~thread:Ephemeral` 을 넘긴다 |

## 4. 하지 않는 것

- 서버 시작 때 모든 thread 를 훑어 기록에 없는 것을 지우지 않는다. `thread/start` 를 보냈지만 아직 기록되지 않은 thread 를 지울 수 있다. 잊는 순간을 아는 쪽이 지우면 이 경합이 없다.
- `session.json` 에 필드를 더하지 않는다.
- 실패한 `thread/delete` 를 다시 시도하지 않는다.
- 삭제 결과를 세는 새 계측(Otel 카운터 등)을 두지 않는다. 배포 뒤 확인은 2.2 의 로그 줄로 한다.
- 서버의 recovery 해제 엔드포인트처럼 Keeper 턴 밖에서 기록을 바꾸는 곳은 지우지 않는다. 운영자가 손으로 하는 일이고 드물다.
- Muse 는 RFC-0495 가 다룬다. Claude Code 와 Antigravity 는 이 RFC 밖이다.
- recovery 뒤에 새 thread 를 여는 규칙은 그대로 둔다. `provider_rejected` 가 많은 것은 #48674 가 다룬다. 이 RFC 는 잊은 thread 의 디스크만 다룬다.

## 5. 층

| 층 | 내용 | 확인 |
| --- | --- | --- |
| L1 | 이 RFC | 리뷰 |
| L2 | `forgotten_sessions`(2.1), `delete_threads` 와 Keeper 턴 뒤 호출(2.2) | type-check. 시험: 기록의 실제 전이(resume, 바뀐 도구 면 claim, revert, release, client 전환)에서 2.1 이 내는 id, 그리고 `thread/delete` 가 id 마다 답을 따로 낸다(하나는 성공, 하나는 `-32600`). 삭제는 턴 결과를 다 계산한 뒤 `unit` 을 돌려주는 함수가 하므로 거절이 턴 결과를 바꿀 길이 없다 |
| L3 | `thread = Ephemeral \| Persistent of thread_mode`, `~thread` 필수(2.3) | type-check. 시험: `Ephemeral` 은 `"ephemeral": true`, `Persistent Start` 는 `false`, `Resume` 은 필드 없음. 실제 app-server 확인은 2.3 의 표 |
| L4 | changelog `Fresh state required`, 운영자 절차(2.5) | `changelog-fragments.py check`, 임시 home 복사본에서 절차 확인 |

배포 뒤 확인: Codex Keeper 가 다시 돌면 계정 home 의 rollout 수가 Codex Keeper 수 근처에 머무는지 본다. 로그의 `thread/delete` 결과 줄 수와 실패 수를 센다.

## 6. 열린 질문

- runtime id 가 바뀐 thread(2.4)를 지울 주체가 필요한가? 배포 뒤 `Other_client` 로그 줄 수로 정한다.
- 하드컷 대상에 두 SQLite 파일을 넣어도 되나? `thread/delete` 는 행을 지우지만 파일 크기는 VACUUM 없이 줄지 않는다. 그래서 이미 쌓인 5 GB 는 파일을 지워야 돌아온다. L4 의 임시 home 확인에서 정한다.

## 7. 리뷰에서 정한 것

11-06 Keeper 리뷰(5794636677)에서 정했다.

- 실패한 `thread/delete` 는 턴 결과를 바꾸지 않고, 실패 id 를 저장하지 않는다. 기록이 이미 잊은 id 라 이어 갈 길이 없고, 저장하려면 이 RFC 가 피한 필드가 생긴다.
- 턴 뒤에 지운다. release 로 잊는 id 를 저장 없이 덮는 길은 이것뿐이다.
- 다른 home 의 thread 를 지울 주체를 두지 않는다. 대신 `Other_client` 로그 한 줄을 남기고, 하드컷 절차가 옛 home 도 다룬다.
- 서버 시작 때 훑어 지우지 않는다. `thread/start` 뒤 기록 전에 서버가 죽으면, 훑기가 그 thread 를 지워 되살릴 수 있는 크래시를 영구 손실로 바꾼다.
