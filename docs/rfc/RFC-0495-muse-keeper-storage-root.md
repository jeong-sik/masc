---
rfc: "0495"
title: "Keeper Muse 턴은 Keeper 마다 storage root 하나를 쓰고, 새 세션을 열 때 비운다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["0494"]
---

# RFC-0495 — Keeper Muse 턴은 Keeper 마다 storage root 하나를 쓴다

## 0. 요약

- Keeper Muse 턴이 연 세션이 지워지지 않고 쌓인다(#48512). 11-06 한 계정 home 의 `sessions` 가 30 GiB, `session-index.db` 가 19 GiB 다. 11월에는 하루 약 190개, 약 2 GiB 씩 늘었다.
- MASC 는 Keeper 마다 Muse 세션 하나만 기억한다. 나머지는 버린 세션이다.
- Muse 1.4.14 의 MSP 에는 세션을 지우는 요청이 없다. 세션 파일을 MASC 가 직접 지우면 Muse 의 `session-index.db` 와 어긋난다.
- 제안: Keeper Muse 턴은 계정 home 의 data 폴더 대신 Keeper 마다 storage root 하나를 쓴다. 새 세션을 열기 직전에 그 root 를 비운다. 기억한 세션을 이어 갈 때는 그대로 쓴다.
- 세션 저장소(`session.json`) 스키마는 바꾸지 않는다.

## 1. 지금

### 1.1 쌓이는 양

#48512 가 11-05 에 잰 값과 11-06 에 다시 잰 값이다. 읽기만 했다.

| 항목 | 11-05 | 11-06 |
| --- | --- | --- |
| `.masc/official-clients/muse` 합계 | 47.9 GiB | — |
| 가장 큰 계정 home 의 `.local/share/muse/sessions` | 27.2 GiB | 30 GiB |
| 같은 곳 `session-index.db` | 18.3 GiB | 19 GiB(+ `-wal` 846 MiB) |
| 같은 곳 `local-tracing` | — | 483 MiB |
| 2026/11(1~5일) 새 세션 | 958개, 9.9 GiB | — |

- 세션 파일 중앙값은 28 KB, 상위 10% 는 4.3 MB, 가장 큰 것은 538 MB 다(11-05).
- 데이터 볼륨 사용률은 93% 이고 남은 공간은 286 GiB 다(11-05).

### 1.2 MASC 가 Muse 를 띄우는 곳

`Runtime_muse_serve.run_turn` 을 부르는 곳은 셋이다.

| 호출처 | storage | 끝난 뒤 |
| --- | --- | --- |
| `Fusion_official_client` | 호출마다 임시 `storage_root` | `remove_muse_panel_root` 로 지운다 |
| `Runtime_verification_muse` | 호출마다 임시 `storage_root` | `Fs_compat.remove_tree` 로 지운다 |
| `Keeper_muse_runtime` | 없음. 계정 home 의 XDG 폴더 | 지우지 않는다 |

- `storage_root` 를 주면 `client_environment` 가 `XDG_DATA_HOME`·`XDG_CACHE_HOME`·`XDG_STATE_HOME`·`XDG_RUNTIME_DIR`·`TMPDIR` 를 그 아래로 바꾼다. `HOME`·`XDG_CONFIG_HOME` 과 credential backend 는 계정 home 그대로다.
- `run_turn` 은 `storage_root` 가 있으면 `Resume` 을 거절한다("isolated stateless storage cannot resume"). 지금 root 를 주는 곳은 Fusion·verification 뿐이고, 둘 다 호출이 끝나면 root 를 지운다. 그래서 그 root 에는 이어 갈 세션이 남지 않는다. 이 거절은 그 사실을 적은 것이다.
- 같은 계정을 쓰는 Keeper 는 모두 같은 `session-index.db` 를 쓴다.
- 계정 home 의 data 폴더(`.local/share/muse`)에는 `sessions`·`session-index.db`·`local-tracing`·`model-catalog`·`plugins`·`skills`·`rewind-progress-v2`·`serve-exit.jsonl`·`session-admission-locks` 가 있다. 로그인 파일 `auth.json` 은 `.config/muse` 아래에 있다(11-06, 이름만 확인).

### 1.3 새 세션이 열리는 때

claim 계획에 이어 갈 앞 세션(`previous_settlement`)이 없으면 `Keeper_muse_runtime` 은 `session/start` 를 보낸다. 앞 세션을 비우는 곳은 `plan_claim` 과 `reconcile_context` 다.

- 기록이 없거나 `Ready` 일 때, client 나 runtime 이 바뀌었을 때
- `Recovery_required` 뒤(`Pre_dispatch_failed`, `Process_restarted`, `Provider_rejected` 등)
- 기억한 세션이 지금 기록·system prompt·모델과 맞지 않을 때(`reconcile_context`, 로그 "starting a fresh session")

어느 경우든 새 claim 이 그 Keeper 의 기억을 새 세션으로 바꾼다. 앞 세션은 다시 읽히지 않는다.

같은 Keeper 의 claim 은 겹치지 않는다. 기록이 `Start`·`Active`·`Turn_inflight` 이면 `plan_claim` 이 `Start_incomplete`·`Active_unsettled`·`Turn_already_inflight` 로 거절한다.

### 1.4 지울 길이 없다

- `muse schema generate-json-schema` 의 stable·experimental 스키마(1.4.14) 어디에도 세션을 지우는 요청이 없다. 세션 관련 것은 `session/start`·`resume`·`fork`·`leave`·`list`·`read` 같은 것이고, 끝을 알리는 것은 `session/closed` 알림뿐이다.
- host 의 storage 성질은 `durable`·`ephemeral` 둘이고 host 를 띄울 때 정해진다. Keeper 턴은 `Resume` 을 쓰니 `durable` 이어야 한다.

## 2. 제안

### 2.1 storage 를 두 갈래 타입으로 나눈다

`run_turn` 의 `?storage_root:string` 을 꼭 받는 닫힌 합타입 `~storage` 로 바꾼다.

```ocaml
type storage =
  | Stateless of string     (* 호출마다 만든 임시 root. Start 만 받는다 *)
  | Keeper_owned of string  (* Keeper 하나가 소유한 root. Start·Resume 을 받는다 *)
```

- 계정 home 의 data 폴더를 쓰는 갈래는 두지 않는다. 바꾼 뒤 `run_turn` 을 부르는 세 곳 모두 root 를 넘긴다.
- `Stateless` 와 `Resume` 이 만나면 지금처럼 `Invalid_config` 다.
- `Keeper_owned` 와 `Resume` 은 받는다.
- 상대 경로는 두 갈래 모두 거절한다.
- Fusion·verification 은 `Stateless` 를 넘긴다. 동작은 그대로다.

### 2.2 Keeper 마다 root 하나

- 위치: `<keepers runtime>/<keeper>/official-client-runtime/muse-storage`. `Keeper_official_client_paths.state_dir` 아래이고 `session.json` 옆이다.
- 아래에 `data`·`cache`·`state`·`run`·`tmp` 를 둔다. Fusion 이 쓰는 모양과 같다.
- Keeper 를 지우면(`purge_keeper_artifacts` 의 `Keeper_runtime_directory_artifact`) 이 폴더도 같이 지워진다. 따로 지우는 코드는 없다.
- 같은 계정을 쓰는 Keeper 끼리 index 를 같이 쓰지 않는다.

### 2.3 새 세션을 열기 직전에 비운다

- `Keeper_muse_runtime` 이 `session_mode = Start` 로 정한 뒤, 프로세스를 띄우기 전에 root 를 통째로 지우고 다시 만든다.
- 1.3 에서 보듯 이 시점에 root 안의 세션은 모두 버린 세션이다. 같은 Keeper 의 다른 턴이 그 root 를 쓰는 중일 수 없다.
- `Resume` 이면 비우지 않는다.
- 세션을 바꾸는 일은 claim 경계에서만 일어난다. 1.3 의 `plan_claim` 거절 덕분에 같은 Keeper 의 턴이 살아 있는 동안에는 새 claim 이 없고, 비우기도 없다.

비우는 순간 그 root 를 쓰는 Muse 프로세스가 없어야 한다. 경우를 나누면 이렇다.

| 경우 | 지금 막는 것 | 남는 것 |
| --- | --- | --- |
| 같은 프로세스에서 턴을 중단했다 | `with_spawned_client` 는 `Eio.Process.spawn ~sw` 로 띄운다. switch 가 끝나면 child 에 `SIGKILL` 이 간다(`eio/process.mli`). 세션 기록은 `run_turn` 이 돌아온 뒤에야 `Turn_inflight` 를 벗어난다 | 없다 |
| 같은 Keeper 의 두 번째 claim | `plan_claim` 이 `Start`·`Active`·`Turn_inflight` 에서 거절한다 | 없다 |
| 서버가 죽어 Muse child 가 남았다 | 없다. 부모가 죽으면 `SIGKILL` 이 가지 않는다 | 남은 child 가 새 root 에 경로로 파일을 쓸 수 있다 |

- 세 번째 경우에 남은 child 가 쓰는 것은 버린 세션이다. `session-index.db` 는 SQLite 라 여러 프로세스가 같이 써도 파일이 깨지지 않는다. 새 세션의 기록은 그대로고, 버린 세션 하나가 다음 Start 까지 남는다.
- 그래서 따로 진행 중 호출 수를 세는 장치를 더하지 않는다. 같은 Keeper 의 겹침은 세션 기록의 phase 가 이미 막는다.
- 비우기에 실패하면 그 턴은 dispatch 전 실패로 끝난다. 비우지 못한 root 로 새 세션을 열지 않는다.

Muse 는 `model-catalog`·`plugins`·`skills` 도 data 폴더에 둔다(11-06 각각 8 KiB, 4.0 MiB, 6.1 MiB). 새 세션마다 다시 만든다. Fusion 은 지금도 호출마다 이렇게 돈다.

### 2.4 하드컷

Fresh state: Muse 를 쓰는 Keeper 의 `official-client-runtime/session.json` 과, 계정 home 의 `.local/share/muse` 아래 `sessions`·`session-index.db*`·`local-tracing`·`rewind-progress-v2` 를 지우고 설치한다.

- 옛 세션을 새 root 로 옮기는 코드는 만들지 않는다.
- 첫 턴은 새 세션으로 시작한다. MASC 의 canonical 기록은 그대로라 대화 내용은 잃지 않는다. Muse host 쪽 캐시는 한 번 비게 된다.
- 계정 home 의 data 폴더는 그 계정을 쓰는 모든 Keeper 가 같이 쓴다. 그래서 일부 Keeper 만 지우지 않는다. 배포하면 Muse 를 쓰는 Keeper 전원이 새 세션으로 시작한다.

## 3. 바뀌는 것

- Keeper 하나가 디스크에 남기는 Muse 세션은 많아야 하나다.
- 새 세션마다 Muse 가 data 폴더를 처음부터 만든다. 그 비용은 L2 에서 잰다.
- Keeper 턴은 계정 home 의 `.local/share/muse` 를 쓰지 않는다. 로그인(`login_environment`)은 지금처럼 계정 home 을 쓴다.

## 4. 하지 않는 것

- 세션마다 root 를 따로 두지 않는다. 그러려면 `session.json` 이 세션 id 와 root 를 같이 기억해야 하고(스키마 변경), 새 세션 기록과 옛 root 삭제 사이에 프로세스가 죽으면 남는 root 를 치우는 sweep 이 따로 필요하다. Keeper 마다 root 하나를 두고 Start 직전에 비우면, 죽어서 남은 세션도 다음 Start 가 지운다.

- 세션 파일이나 index 를 MASC 가 골라 지우지 않는다. Muse 내부 형식이다.
- 개수·용량·나이로 자르지 않는다. 기억하는 세션까지 지울 수 있다.
- Codex(16.0 GiB)·Antigravity(7.7 GiB)·Claude Code(7.0 GiB) 계정 home 은 다루지 않는다(11-05 합계). 같은 모양인지는 따로 재고 이슈로 남긴다.
- RFC-0494 가 다루는 resume 때 다시 보내는 context 는 건드리지 않는다.

## 5. 층

| 층 | 내용 | 확인 |
| --- | --- | --- |
| L1 | 이 RFC | 리뷰 |
| L2 | `storage` 합타입(2.1), Fusion·verification 을 `Stateless` 로 | type-check. 일회용 계정 사본에서 `Keeper_owned` root 로 Start → Resume 이 같은 세션으로 이어지는지, data 폴더를 처음 만드는 시간 측정 |
| L3 | Keeper root(2.2)와 Start 직전 비우기(2.3) | 시험: Start 는 root 를 비우고 Resume 은 남긴다, 비우기 실패는 dispatch 전 실패. 배포 뒤 한 Keeper root 크기가 세션 하나 크기로 머무는지 |
| L4 | changelog `Fresh state required`(2.4) | `changelog-fragments.py check` |

L2 는 혼자 들어가도 동작이 바뀌지 않는다. L3 와 L4 는 같이 배포한다.

## 6. 열린 질문

1. 로그인 유지. `auth.json` 은 config 쪽에 있고(1.2) Fusion 은 빈 data 폴더로 돈다. 다만 Fusion 은 Resume 을 하지 않는다. L2 의 일회용 사본에서 빈 `Keeper_owned` root 로 Start 한 뒤 Resume 이 로그인 없이 되는지 확인한다.
2. root 를 비우는 시점. 2.3 은 Start 직전이다. 새 세션이 settle 된 뒤 비우면 Start 가 실패했을 때 앞 세션 파일이 남지만, 그 세션은 이미 버려졌으니 쓸모가 없다.
3. Muse host 에 세션 삭제 요청이 생기면. root 는 그대로 Keeper 마다 두고, 비우기 대신 host 에 지우라고 요청할지 그때 정한다. host 쪽에 기능 요청을 올릴지는 운영자가 정한다.
