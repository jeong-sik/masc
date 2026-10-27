---
rfc: "lane-addon-observation-commits-at-the-binding"
title: "Lane add-on observation commits at the binding"
status: Draft
created: 2026-10-27
updated: 2026-10-27
author: vincent
supersedes: []
superseded_by: null
related: []
---

# Lane add-on 관측은 binding 교체로 커밋한다

## 0. 요약

- 지금은 관측 파일 N 을 먼저 공개하고 binding 에 N 을 나중에 써요. 그 사이에 실패하면 "공개됐지만 binding 에 없는 관측"이 남아요.
- 그래서 binding 을 읽는 모든 경로가 읽을 때마다 관측 디렉터리 전체를 훑어 그 관측을 되찾아요(`highwater`).
- 이 RFC 는 binding 파일 교체 한 번을 커밋 시점으로 삼아요.
  - 관측 파일은 binding 이 그 순번을 가리켜야 커밋돼요.
  - 의존하는 쪽은 커밋 뒤에만 깨워요.
  - 읽는 쪽은 binding 순번에서 멈춰요.
- 이렇게 하면 어긋난 상태가 생기지 않아요. 그래서 `highwater` 와 읽기 쪽 복구를 지워요.
- 하나만 필요한 읽기(`persisted_binding`, `browser_service_status`)는 binding 파일 하나만 열어요.
- 저장 형식은 바꾸지 않아요. 10-27 운영 저장소에는 binding 보다 앞선 관측 파일이 0개라서 버릴 데이터도 없어요.

## 1. 문제

### 1.1 지금 비용

`Lane_addon_store.read_bindings`(`lib/lane_addon/lane_addon_store.ml`)는 binding 파일마다 `highwater` 를 불러요. `highwater` 는 그 인스턴스의 `observations/<digest>/` 를 처음부터 끝까지 `readdir` 해서 가장 큰 순번을 찾아요.

- 10-27 운영 저장소에는 binding 이 918개 있었어요. 관측이 있는 인스턴스는 165개, 관측 파일은 5만여 개(가장 큰 디렉터리 13,815개)였어요.
- `read_bindings` 를 한 번 부르면 binding JSON 918개를 파싱하고 디렉터리 항목을 5만여 개 읽어요.
- `Lane_addon_runtime.read_retained_bindings` 가 이 일을 `offload`(= `Eio_unix.run_in_systhread`)로 돌려요. 그래서 부른 쪽 도메인(대개 도메인 0)의 시스템 스레드에서 돌아요. `readdir` 은 항목마다 도메인 잠금을 놓았다 다시 잡아요.
- 10-27 16:32 KST 운영 sample(#46413)에서는 메인 스레드 잠금 대기 431 샘플 중 328 이 이 스캔 중이었어요.

### 1.2 왜 매번 훑는가

`read_bindings` 위 주석이 이유를 적고 있어요. "A renamed observation can survive a failed binding write. Recover its sequence for every retained reader." 쓰는 쪽의 실패를 읽는 쪽이 매번 메우는 구조예요. 비용은 관측이 쌓이는 만큼 계속 커져요.

## 2. 지금 커밋 순서

`Lane_addon_runtime.commit_output` 은 이 순서로 써요.

1. 순번 `seq = e.seq + 1` 로 `Lane_addon_store.append_observation`. 관측 파일 `observations/<digest>/<seq 20자리>.json` 을 원자 교체로 써요. 같은 순번 파일이 있으면 "observation sequence already committed" 로 거절해요.
2. 성공하면 `converge`(`e.seq <- seq`, `e.output <- output`) → `wake_dependents` → `persist`(binding 저장).
3. 1이 `After_rename` 에서 실패해도 `converge` 해요. 2의 binding 저장은 따로 실패할 수 있어요.

그래서 두 가지가 생겨요.
- 1 뒤 2 전에 죽거나 binding 저장이 실패하면, 관측 N 은 디스크에 있는데 binding 은 N-1 이에요.
- 의존하는 쪽은 binding 이 쓰이기 **전에** 이미 N 을 받았어요. 그래서 N 을 버릴 수 없고, 읽는 쪽이 N 을 되찾아야 해요.

## 3. 설계: binding 교체가 커밋이다

### 3.1 쓰기 순서

한 인스턴스의 커밋은 지금처럼 그 소유 도메인에서 `persistence_mutex` 아래 하나씩 일어나요.

1. 관측 파일 N 을 쓴다. 이 파일은 아직 커밋이 아니다.
2. binding 을 `observation_seq = N` 으로 교체한다. **이 교체가 커밋이다.**
3. 커밋된 뒤에만 `converge` 하고 의존하는 쪽을 깨운다.

### 3.2 실패 경우

| 단계 | 실패 | 결과 |
|---|---|---|
| 1 관측 | `Before_rename` | 커밋 아님. 아무것도 공개되지 않음. 지금과 같음. |
| 1 관측 | `After_rename` | 커밋 아님. 파일 N 은 보이지만 binding 이 N-1 이라 아무도 읽지 않음. 레인은 지금처럼 `Failed` 로 가고, 회복은 같은 N 을 다시 커밋함. |
| 2 binding | `Before_rename` | 커밋 아님. 파일 N 은 커밋되지 않은 찌꺼기. 다음 커밋이 N 을 덮어씀. |
| 2 binding | `After_rename` | binding N 이 보이므로 커밋으로 친다. `converge` 하고 깨운다. 디스크 내구성은 다음 `persist` 가 다시 확인. |

- 1단계 `After_rename` 의 결과가 지금과 달라요. 지금은 순번을 N 으로 올려요. 새 계약에서는 binding 이 가리키기 전까지 N 은 커밋이 아니에요.
- 2단계 `After_rename` 은 지금 관측 `After_rename` 을 다루는 방식(보이면 공개로 친다)을 binding 에 그대로 옮긴 거예요.

### 3.3 순번 불변식

- 커밋된 순번은 binding 의 `observation_seq` 하나뿐이에요. 1부터 그 값까지 파일이 빈틈없이 있어요.
- binding 순번보다 큰 파일은 커밋되지 않은 찌꺼기예요. 다음 커밋은 `seq = committed + 1` 을 쓰고, 그 자리에 찌꺼기가 있으면 덮어써요. "already committed" 검사는 지워요.
- 관측 파일 하나만 지우는 경로는 없어요. 인스턴스를 치울 때는 binding 과 관측 디렉터리를 함께 옮겨요(`Lane_addon_store_preflight`).

### 3.4 읽기

- `read_bindings` 는 binding 파일의 순번을 그대로 돌려줘요. `highwater` 를 지워요.
- `query_observations ~expected_seq` 는 `expected_seq` 까지만 읽어요. 지금은 `max highwater expected_seq` 예요.
- 기동 때 인스턴스 순번은 binding 에서만 가져와요.
- 행 ID(`instance/<seq>/...`)는 커밋된 출력에서만 나와요. 그래서 그 ID 로 정확히 읽는 `read_observation` 은 바뀌지 않아요.

### 3.5 하나만 필요한 읽기

binding 경로는 인스턴스 ID 로 정해져요(`bindings/<digest instance_id>.json`).

- `persisted_binding m id` 와 `browser_service_status ~instance_id` 는 지금 모든 binding 을 읽은 뒤 하나를 골라요. 그 binding 파일 하나만 열게 바꿔요. 파일 하나를 읽고 분류하는 규칙(JSON 아님, 객체 아님, ID·순번 없음 → unreadable)은 `read_bindings` 와 같은 함수를 써요.
- `slice`, `historical`, `attach_entry`, `reconcile_configuration` 은 정말로 전부가 필요해요. 그대로 두고, `highwater` 가 빠지면서 binding 수에 비례하는 비용만 남아요.

## 4. 지금 데이터

- 저장 형식은 그대로예요. 마이그레이션 코드를 만들지 않아요.
- 새 계약에서 버려지는 데이터는 "binding 보다 앞선 관측 파일"뿐이에요. 10-27 운영 저장소를 세어 보니 0개였어요.
  - 셈한 범위: binding 918개 전부, 관측 디렉터리가 있는 165개 인스턴스.
  - 셈한 방법: 읽기 전용 스크립트로, 파일 이름의 순번 최댓값과 binding 의 `observation_seq` 를 비교했어요.
- 같은 셈에서 모든 인스턴스의 순번에 빈틈이 없었어요.

## 5. 바뀌는 계약과 시험

- `Lane_addon_store.mli` 의 `read_bindings` 설명에서 두 문구를 지워요. "sits beside a misnamed observation file" 과 "Each readable sequence is reconciled with retained observation filenames" 예요. 이름이 잘못된 관측 파일을 읽을 때마다 잡던 검사는 없어져요. 커밋된 순번의 정확한 레코드 검증은 그대로예요.
- `test_lane_addon_actions.ml` 의 `test_observation_publication_keeps_sequence_and_action_uncertainty` 는 관측 `After_rename` 뒤 순번이 N 으로 오르는 것을 기대해요. 3.2 대로 N-1 에 머무는 것으로 바꿔요.
- 새 기능 시험을 더해요.
  - binding 저장이 `Before_rename` 에서 실패하면 순번이 오르지 않고, 의존하는 쪽이 깨지 않아요.
  - 다음 커밋이 같은 순번의 찌꺼기를 덮어쓰고 커밋해요.
  - binding 저장이 `After_rename` 에서 실패하면 커밋으로 쳐요.
  - binding 보다 큰 관측 파일이 있어도 `read_bindings` 와 `query_observations` 가 그 파일을 읽지 않아요.

## 6. 하지 않는 것

- 여러 파일을 묶는 저널이나 디렉터리 교체는 하지 않아요. 커밋 시점을 binding 하나로 정하면 필요 없어요.
- 캐시, 횟수 제한, 스캔 간격 조정은 하지 않아요.
- `offload` 를 도메인 0 밖으로 옮기는 일은 이 RFC 범위가 아니에요. 이 RFC 뒤에는 그 안에서 도는 일이 binding 수에 비례하는 만큼으로 줄어요.

## 7. 위험

- **binding `After_rename` 뒤 죽는 경우:** binding N 이 보였지만 내구성이 확인되지 않은 채 프로세스가 죽으면, 재시작 뒤 binding 이 N-1 로 돌아갈 수 있어요.
  - 그러면 커밋 전에 깨운 의존 쪽이 N 을 이미 받았는데, 다음 커밋이 N 을 다른 내용으로 덮어써요.
  - fsync 실패와 프로세스 종료가 겹쳐야 일어나요. 지금 구조에서도 관측 파일 `After_rename` 뒤 같은 창이 있어요.
  - 리뷰에서 이 창을 받아들일지, 2단계 `After_rename` 을 `Failed` 로 두고 내구성이 확인될 때까지 깨우지 않을지 정해요.
- **덮어쓰기:** 커밋되지 않은 순번만 덮어써요. 커밋된 순번은 binding 이 가리키므로 `seq = committed + 1` 규칙으로는 닿지 않아요.

## 8. 단계

| 층 | 내용 |
|---|---|
| L1 | 이 RFC |
| L2 | 커밋 순서 변경(3.1~3.2), "already committed" 검사 삭제, `highwater` 와 읽기 쪽 복구 삭제(3.4), 계약 문구와 시험(5) |
| L3 | 하나만 필요한 읽기를 binding 파일 하나로(3.5) |

## 9. 검증

- 기능 시험: 5의 시험을 대상 suite 로 돌려요. 맨 아래 PR 은 Core 빌드만 확인해요.
- 운영 측정: 배포 전후로 같은 부하에서 두 값을 재요.
  - `read_retained_bindings` 한 번의 시간
  - 메인 스레드 잠금 대기 비율(`_pthread_cond_wait` 의 부모가 `caml_thread_leave_blocking_section` 인 샘플 / 메인 스레드 전체)
- binding 보다 앞선 관측 파일 수를 배포 직전에 다시 세서 0인지 확인해요.
