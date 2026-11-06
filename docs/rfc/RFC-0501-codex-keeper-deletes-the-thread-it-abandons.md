---
rfc: "0501"
title: "Codex Keeper 는 새 thread 를 열기 전에 버리는 thread 를 지운다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["0495"]
---

# RFC-0501 — Codex Keeper 는 새 thread 를 열기 전에 버리는 thread 를 지운다

## 0. 요약

- Codex 계정 home 하나의 `sessions` 에 rollout 이 7,008개, 11.9 GB 쌓였다(#49031). Keeper 세션 기록이 가리키는 것은 3개뿐이다.
- Keeper 가 새 thread 로 갈 때 claim 이 옛 `session_id` 를 기록에서 지운다. vendor 쪽 rollout 은 그대로 남는다.
- Codex app-server 에는 `thread/delete` 가 있다. codex-cli 0.166.0 에서 rollout 파일을 지우는 것을 확인했다.
- 제안: claim 계획이 버리는 thread id 를 값으로 낸다. Codex runtime 은 같은 app-server 연결에서 `thread/start` 전에 그 thread 를 `thread/delete` 한다.
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

### 1.3 Keeper 가 새 thread 를 여는 때

claim 계획에 `previous_settlement` 가 없으면 `Keeper_codex_runtime` 은 `thread/start` 를 보낸다. 앞 thread 를 놓는 곳은 `plan_claim` 과 `reconcile_tool_surface` 다.

- 기록이 `Settled` 인데 client 종류나 runtime id 가 바뀌었을 때
- 기록이 `Settled` 인데 도구 목록 digest 가 바뀌었을 때. 도구를 더하거나 설명을 고치는 배포마다 바뀐다.
- 기록이 `Recovery_required` 일 때(`Input_rejected` 는 거절)

`claim_with_context_frontier` 는 이때 `Start { previous_settlement = None }` 을 저장한다. 앞 thread 의 id 는 기록에서 사라진다. 다시 읽는 곳이 없다.

같은 Keeper 의 claim 은 겹치지 않는다. 기록이 `Start`·`Active`·`Turn_inflight` 이면 `plan_claim` 이 거절한다.

### 1.4 지울 길이 있다

- `codex app-server generate-json-schema`(0.166.0)에 `thread/delete`·`thread/archive`·`thread/list` 가 있다. `thread/delete` 의 인자는 `threadId` 하나다.
- 임시 `CODEX_HOME` 에 rollout 하나를 복사해 `thread/delete` 를 불렀다.
  - 응답은 `{}` 이고, rollout 파일이 지워지고, `thread/deleted` 알림이 온다.
  - 같은 id 를 다시 지우면 `-32600 no rollout found for thread id …` 로 거절한다.
  - 로그인 없이 동작한다.
- upstream `codex-rs/thread-store/src/local/delete_thread.rs`(main) 는 rollout 파일, `thread_history` 행, state DB 행을 지운다. 붙은 하위 thread 가 있으면 거절한다.

Muse 에는 세션을 지우는 요청이 없어서 RFC-0495 는 storage root 를 비운다. Codex 는 계정 home 에 `auth.json` 과 설정이 같이 있어 비울 수 없다. 대신 thread 를 하나씩 지울 수 있다.

## 2. 제안

### 2.1 claim 계획이 버리는 thread 를 낸다

`Keeper_official_client_session_store` 에 순수 함수 하나를 더한다.

```ocaml
val abandoned_sessions :
  expected:t option -> client_kind:client_kind -> runtime_id:string ->
  claim_plan -> string list
```

계획에 `previous_settlement` 가 없을 때만 id 를 낸다. 기록 단계마다 이렇다. 와일드카드 없이 생성자를 모두 적는다.

| 기록 | 같은 client·runtime | 내는 id |
| --- | --- | --- |
| 없음, `Ready` | — | 없음 |
| `Settled s` | 예 | `s.session_id` |
| `Recovery_required r` | 예 | `r.observed_session_id` 와 `r.previous_settlement` 의 `session_id`. 같으면 하나 |
| `Settled`·`Recovery_required` | 아니오 | 없음(2.4) |
| `Start`·`Active`·`Turn_inflight` | — | 없음. `plan_claim` 이 이미 거절한다 |

새 상태나 필드는 없다. 지금 `expected` 와 계획에서 계산한다.

### 2.2 Codex runtime 은 `thread/start` 전에 지운다

`thread_mode` 를 세 갈래로 바꾼다.

```ocaml
type thread_mode =
  | Ephemeral
  | Start of { discard : string list }
  | Resume of { thread_id : string }
```

- `Start { discard }` 이면 `initialize` 뒤, `thread/start` 전에 `discard` 의 thread 마다 `thread/delete` 를 보낸다.
- 결과는 Keeper 로그에 한 줄씩 남긴다. 성공, 또는 RPC 오류의 code 와 message 다.
- 실패해도 턴은 이어 간다. 새 thread 는 옛 thread 와 무관하다. claim 이 이미 옛 id 를 기록에서 지웠으니 이어 갈 길도 없다.
- 지우기를 다시 시도하지 않는다. 실패한 id 를 저장하는 필드도 두지 않는다. 디스크가 남는 일은 durable truth 를 해치지 않는다.

`Keeper_codex_runtime` 은 2.1 의 값을 `discard` 로 넘긴다.

### 2.3 이어 가지 않는 호출은 `Ephemeral`

- `?thread_mode` 기본값을 없애고 `~thread_mode` 를 필수로 한다. 호출처마다 고른다.
- `Fusion_official_client`, `Keeper_capability_probe` 는 `Ephemeral` 을 넘긴다. `thread/start` 에 `"ephemeral": true` 를 보낸다.
- `Runtime_verification` 은 실행 폴더 안 `codex-home` 을 쓴다. `Ephemeral` 로 바꿔도 그 폴더의 수명은 바뀌지 않는다. 이 RFC 는 `Ephemeral` 만 넘긴다.
- `thread_is_ephemeral` 상수는 지운다. 값은 생성자가 정한다.

### 2.4 client 나 계정이 바뀐 thread

runtime id 나 client 종류가 바뀌면 옛 thread 는 다른 계정 home 이나 다른 client 에 있을 수 있다. 지금 runtime 의 app-server 로는 지울 수 없다. 이 경우는 지우지 않는다. 얼마나 자주 일어나는지는 재지 못했다(6장).

### 2.5 하드컷

이미 쌓인 rollout 은 옮기거나 지우는 코드를 만들지 않는다. 운영자가 배포 때 지운다.

1. 서버를 멈춘다.
2. Codex 계정 home 의 `sessions`, `state_5.sqlite*`, `thread_history_1.sqlite*` 를 지운다.
3. 새 버전으로 서버를 띄운다.

`auth.json`, `config.toml` 은 남긴다. 기억한 thread 가 있던 Keeper 는 다음 `thread/resume` 이 실패하고, 그다음 claim 이 새 thread 를 연다. 이 절차가 로그인 상태를 지키는지는 L4 전에 임시 home 복사본에서 확인한다.

## 3. 바뀌는 것

| 모듈 | 바뀌는 것 |
| --- | --- |
| `Keeper_official_client_session_store` | `abandoned_sessions` 추가 |
| `Runtime_codex_app_server` | `thread_mode` 세 갈래, `~thread_mode` 필수, `Start` 의 `thread/delete`, `thread_is_ephemeral` 삭제 |
| `Keeper_codex_runtime` | `Start { discard }` 를 만든다 |
| `Fusion_official_client`, `Keeper_capability_probe`, `Runtime_verification` | `Ephemeral` 을 넘긴다 |

## 4. 하지 않는 것

- 서버 시작 때 모든 thread 를 훑어 기록에 없는 것을 지우지 않는다. `thread/start` 를 보냈지만 아직 기록되지 않은 thread 를 지울 수 있다. 버리는 순간에 지우면 이 경합이 없다.
- `session.json` 에 필드를 더하지 않는다.
- 실패한 `thread/delete` 를 다시 시도하지 않는다.
- Muse 는 RFC-0495 가 다룬다. Claude Code 와 Antigravity 는 이 RFC 밖이다.
- 배포마다 도구 목록 digest 가 바뀌어 새 thread 가 열리는 일은 그대로 둔다. 이 RFC 는 버린 thread 의 디스크만 다룬다.

## 5. 층

| 층 | 내용 | 확인 |
| --- | --- | --- |
| L1 | 이 RFC | 리뷰 |
| L2 | `abandoned_sessions`(2.1), `Start { discard }` 와 `thread/delete`(2.2) | type-check. 시험: 기록 단계별로 내는 id, `Start { discard }` 가 `thread/start` 전에 `thread/delete` 를 보내고 거절돼도 턴을 이어 감 |
| L3 | `Ephemeral`, `~thread_mode` 필수(2.3) | type-check. 시험: `Ephemeral` 이 `"ephemeral": true` 를 보냄. 배포 전에 실제 app-server 에서 ephemeral thread 가 `dynamicTools` 를 받는지 확인 |
| L4 | changelog `Fresh state required`, 운영자 절차(2.5) | `changelog-fragments.py check`, 임시 home 복사본에서 절차 확인 |

배포 뒤 확인: Codex Keeper 가 다시 돌면 계정 home 의 rollout 수가 Codex Keeper 수 근처에 머무는지 본다.

## 6. 열린 질문

- `thread/delete` 가 실패하면 턴을 멈춰야 하나? 이 RFC 는 이어 간다(2.2).
- runtime id 가 바뀐 thread(2.4)를 지울 주체가 필요한가? 바뀐 횟수를 Keeper 로그에서 세어 정한다.
- 하드컷 대상에 두 SQLite 파일을 넣어도 되나? `thread/delete` 는 행을 지우지만 파일 크기는 VACUUM 없이 줄지 않는다.
