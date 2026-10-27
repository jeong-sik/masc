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
- 이 RFC 는 binding 교체를 커밋 시점으로 삼아요.
  - 관측 파일 N 이 보이게 돼도, binding 이 N 을 가리키기 전에는 공개하지 않아요. 그동안 N 을 메모리에 붙잡아(held) 둬요.
  - 그 인스턴스의 다음 binding 쓰기가 붙잡은 N 을 가리켜요. 쓰기가 성공하면 그 자리에서 N 을 공개하고 의존하는 쪽을 깨워요.
  - 보이게 된 관측 파일은 절대 다시 쓰지 않아요.
  - 읽는 쪽은 binding 순번에서 멈춰요. 그래서 `highwater` 를 지워요.
- 하나만 필요한 읽기(`persisted_binding`, `browser_service_status`)는 binding 파일 하나만 열어요.
- 저장 형식은 바꾸지 않아요.

## 1. 문제

### 1.1 지금 비용

`Lane_addon_store.read_bindings` 는 binding 파일마다 `highwater` 를 불러요. `highwater` 는 그 인스턴스의 `observations/<digest>/` 를 처음부터 끝까지 `readdir` 해서 가장 큰 순번을 찾아요.

- 10-27 운영 저장소에는 binding 이 918개 있었어요. 관측이 있는 인스턴스는 165개, 관측 파일은 5만여 개(가장 큰 디렉터리 13,815개)였어요.
- 그래서 `read_bindings` 를 한 번 부르면 binding JSON 918개를 파싱하고 디렉터리 항목을 5만여 개 읽어요.
- `Lane_addon_runtime.read_retained_bindings` 는 이 일을 `offload`(= `Eio_unix.run_in_systhread`)로 돌려요. 그래서 부른 쪽 도메인(대개 도메인 0)의 시스템 스레드에서 돌아요.
- 10-27 16:32 KST 운영 sample(#46413)에서는 메인 스레드 잠금 대기 431 샘플 중 328 이 이 스캔 중이었어요.

### 1.2 왜 매번 훑는가

`read_bindings` 위 주석에 이유가 적혀 있어요. "A renamed observation can survive a failed binding write. Recover its sequence for every retained reader."

쓰는 쪽의 실패를 읽는 쪽이 매번 메우는 구조예요. 비용은 관측이 쌓이는 만큼 계속 커져요.

## 2. 지금 커밋 순서

`Lane_addon_runtime.commit_output` 은 이 순서로 써요.

1. 순번 `seq = e.seq + 1` 로 `Lane_addon_store.append_observation` 을 불러요. 관측 파일 `observations/<digest>/<seq 20자리>.json` 을 원자 교체로 써요. 같은 순번 파일이 있으면 거절해요.
2. 성공하면 `converge`(`e.seq <- seq`, `e.output <- output`) → `Attached` → `wake_dependents` → `persist`(binding 저장) 순서로 진행해요.
3. 1이 `After_rename` 에서 실패해도 `converge` 하고 깨운 뒤 binding 을 저장해요. 레인은 `Failed`("observation published with unconfirmed durability")로 가요.

의존하는 쪽은 binding 이 아니라 producer 의 메모리 항목(`e.seq`, `e.output`)을 읽어요. 그래서 binding 저장이 실패하거나 그 전에 프로세스가 죽으면, 의존하는 쪽은 이미 N 을 읽었는데 binding 은 N-1 이에요. 이 N 을 되찾으려고 읽는 쪽이 매번 훑어요.

## 3. 설계

### 3.1 전제로 삼는 사실 두 가지

- **보이게 된 관측 파일은 다시 쓰지 않는다.** 행동(action)이 돈 관측에는 행동 요청 행이 들어 있어요. 영수증은 `result` 만 들고 있어서, 이 파일이 그 행동의 유일한 증거예요. `test_observation_publication_keeps_sequence_and_action_uncertainty` 가 "later retries never overwrite the failed published record" 로 이걸 지켜요. `Lane_addon_store.append_observation` 계약도 "runtime must reserve the renamed sequence" 예요.
- **인스턴스는 재시작 뒤 이어지지 않는다.** 항목을 만드는 곳은 한 곳이고, 늘 새 `Random_id.uuid_v7 ()` 과 `seq = 0` 으로 만들어요. 그래서 지난 프로세스의 관측 디렉터리에 새 프로세스가 쓰는 일은 없어요.

### 3.2 커밋 순서

한 인스턴스의 커밋은 그 인스턴스의 루프에서 하나씩 일어나요.

1. `e.held` 가 비어 있을 때만 새 관측을 써요. 순번은 `seq = e.seq + 1` 이에요. 붙잡은 관측이 남아 있으면 먼저 binding 을 다시 써서 그것을 커밋해요(3.4). 이게 실패하면 새 출력은 쓰지 않고 실패를 돌려줘요. 그래서 붙잡는 관측은 늘 한 개 이하예요.
2. 관측 파일 N 이 보이게 되면(성공이든 `After_rename` 이든) `e.held <- Some (N, output)` 으로 붙잡아요. 아직 공개하지 않아요.
3. binding 을 써요. 이 binding 은 붙잡은 N 을 가리켜요. **이 교체가 커밋이에요.**
4. binding 쓰기가 끝나면, `persistence_mutex` 를 놓기 전에 양보 없이 한 걸음으로 이렇게 해요: `e.seq <- N`, `e.output <- output`, `e.held <- None`, 레인 상태 정하기, `wake_dependents`.
   - 레인 상태는 붙잡을 때 함께 둔 규칙을 커밋하는 순간의 상태에 적용해서 정해요. 보통 관측은 "붙잡은 뒤 상태가 바뀌지 않았으면 `Attached`, 바뀌었으면 나중 상태를 둔다"예요. 관측 `After_rename` 은 "지금 상태를 `Failed` 로"예요.
   - 규칙이 붙잡은 값에 실려 있어서, 어느 binding 쓰기가 커밋하든 결과가 같아요.
   - 인스턴스가 멈추는 중(`stopping`)이면 상태는 건드리지 않아요. 워커 종료·도구 취소처럼 커밋 도중 상태를 바꾸는 경로는 먼저 `stopping` 을 켜요.

4는 지금 코드가 지키는 순서("Wake them in the same step that makes [refreshing] false")를 그대로 지켜요. `refreshing` 이 거짓이 되는 걸음과 깨우는 걸음이 같아요.

### 3.3 실패 경우

| 단계 | 결과 | 공개 | 레인 |
|---|---|---|---|
| 관측 `Before_rename` | 아무것도 보이지 않음. held 없음. | 안 함 | 지금과 같음 |
| 관측 `After_rename` | N 이 보임. held 에 붙잡고 binding 쓰기로 넘어감. | binding 결과를 따름 | `Failed`(unconfirmed durability). 지금과 같음 |
| binding 성공 | 커밋 | 함, 깨움 | `Attached`(관측이 `After_rename` 이었으면 `Failed`) |
| binding `Before_rename` | 커밋 아님. N 은 held 에 남음. | 안 함 | `Failed`(binding persistence) |
| binding `After_rename` | binding 이 N 을 가리킴. 커밋으로 침. | 함, 깨움 | `Failed`(binding published with unconfirmed durability) |
| 취소(`Cancelled`) | 관측이든 binding 이든 이름이 바뀌었으면 위 줄대로 맞춘 뒤 다시 던짐 | 위 줄을 따름 | 위 줄을 따름 |

- binding `After_rename` 을 커밋으로 치는 이유: `Fs_compat.save_file_atomic_strict_staged` 계약이 "Transaction owners must converge any dependent in-memory publication before propagating an [After_rename] failure" 예요. 맞춘 뒤에는 의존하는 쪽이 메모리 항목을 직접 읽으므로, 깨우지 않아도 N 을 읽어요. 깨움을 늦추면 지연만 생겨요.
- 이 경우 binding 이 프로세스 종료로 되돌아가지는 않아요. 이름 바꾸기는 커널이 이미 끝낸 일이에요. 되돌아갈 수 있는 건 OS 가 죽거나 전원이 나갈 때뿐이고, `Fs_compat` 은 성공한 쓰기에도 그 경우를 보장하지 않아요("not hardware or power-loss persistence"). 지금 관측 파일도 같은 조건이에요.
- 취소 줄은 지금 관측 `After_rename` 처리(맞춘 뒤 다시 던짐)를 binding 에 똑같이 적용한 거예요. 그래야 `detach_entry` 의 `persist` 가 보이는 N 위에 N-1 을 쓰지 않아요.

### 3.4 붙잡은 관측의 커밋

- `persist` 는 어느 경로에서 부르든(종료 감시, 도구 취소, `failed`, detach 등) 붙잡은 관측이 있으면 그 순번을 binding 에 써요. 성공하면 3.2 의 4를 해요. 레인 상태도 붙잡을 때 둔 규칙대로 정해요.
- 그래서 binding `Before_rename` 뒤에는 그 인스턴스의 다음 binding 쓰기가 N 을 커밋해요. N+1 을 쓰기 전에 N 이 먼저 커밋돼요. 의존하는 쪽은 N 이 커밋될 때 한 번 깨요.
- binding 쓰기 시도는 반드시 다시 와요. 커밋 실패는 곧바로 `failed` 가 `persist` 를 다시 부르고, 인스턴스가 끝날 때도 detach 와 종료 감시가 `persist` 를 불러요. 그래서 살아 있는 인스턴스의 붙잡은 관측은 그 시도가 한 번이라도 성공하면 커밋돼요. 끝까지 커밋되지 않는 경우는 binding 쓰기가 계속 실패하거나 프로세스가 죽을 때뿐이에요(§7).
- binding 을 지우는 판단(`leaves_no_record`)도 붙잡은 관측을 봐요. 붙잡은 관측이 있으면 지우지 않아요.
- binding 에 쓰는 순번은 줄어들지 않아요. `persist` 는 `persistence_mutex` 안에서 상태를 떠서 쓰고, 떠내는 값(`held` 가 있으면 그 순번, 없으면 `e.seq`)은 늘기만 해요. 그래서 N 을 쓴 뒤에 다른 경로가 N-1 을 쓸 수 없어요.
- 새 필드 `held` 가 필요한 이유: 없으면 둘 중 하나예요. 보이는 N 을 다시 쓰거나(행동 증거를 지움), binding 전에 공개하거나(읽는 쪽이 매번 되찾아야 함). 둘 다 이 RFC 가 없애려는 상태예요.

### 3.5 읽기

- `read_bindings` 는 binding 파일의 순번을 그대로 돌려줘요. `highwater` 를 지워요.
- `query_observations ~expected_seq` 는 `expected_seq` 까지만 읽어요. 지금은 `max highwater expected_seq` 예요.
- `freeze` 는 고른 행의 순번이 넘겨받은 binding 의 `observation_seq` 보다 크면 거절해요. 지금은 행 ID 에서 뽑은 순번을 그대로 읽어요.
- `Store.observations` 는 디렉터리 전체를 읽는 공개 함수예요. 부르는 곳은 시험 하나뿐이라 binding 순번까지만 읽게 바꾸거나 `For_testing` 으로 옮겨요.
- 행 ID(`instance/<seq>/...`)로 정확히 읽는 `read_observation` 은 바뀌지 않아요. 행 ID 는 공개된 출력에서만 나와요.
- 이미 binding 의 `latest` 까지만 읽는 Subscription 읽기는 바뀌지 않아요.

### 3.6 하나만 필요한 읽기

binding 경로는 인스턴스 ID 로 정해져요(`bindings/<digest instance_id>.json`).

- `persisted_binding m id` 와 `browser_service_status ~instance_id` 는 지금 모든 binding 을 읽은 뒤 하나를 골라요. 그 binding 파일 하나만 열게 바꿔요.
- 단, `read_retained_bindings` 가 하던 두 가지는 그대로 해요.
  - `m.recovering` 에 있는 인스턴스는 디스크 대신 복구 중 상태를 써요(`recovery_bindings`). Retain 이 요구하는 `Failed {Cleanup_unconfirmed}` 은 이 겹침에만 있어요.
  - 파일 하나를 읽고 분류하는 규칙(JSON 아님, 객체 아님, ID·순번 없음 → unreadable)은 `read_bindings` 와 같은 함수를 써요.
- 전부가 필요한 읽기는 그대로 둬요: `slice`, `historical`, `attach_entry`, `reconcile_configuration`, `gecko_sweepable`, Subscription 의 `Store.bindings` 세 곳. `highwater` 가 빠지면서 binding 수에 비례하는 비용만 남아요.

## 4. 지금 데이터와 배포 조건

- 저장 형식은 그대로예요. 마이그레이션 코드를 만들지 않아요.
- 새 계약에서 읽히지 않게 되는 데이터는 "binding 보다 앞선 관측 파일"뿐이에요. 지금 바이너리는 그런 파일을 이미 공개했으니, 새 바이너리가 숨기면 의존하는 쪽이 읽은 것과 어긋나요.
- 10-27 운영 저장소를 세어 보니 0개였어요.
  - 셈한 범위: binding 918개 전부, 관측 디렉터리가 있는 165개 인스턴스.
  - 셈한 방법: 읽기 전용 스크립트로, 파일 이름의 순번 최댓값과 binding 의 `observation_seq` 를 비교했어요.
  - 같은 셈에서 모든 인스턴스의 순번에 빈틈이 없었어요.
- **배포 조건:** 지난 서버를 멈춘 뒤, 새 서버를 띄우기 전에 다시 세요. 0이 아니면 배포를 멈추고 그 인스턴스를 어떻게 할지 따로 정해요.
- 이 조건은 이 변경 이전 바이너리가 공개했을 수 있는 파일을 잡으려는 거예요. 새 바이너리가 돈 뒤에는 §7 의 고아(아무도 읽은 적 없는 파일)가 생길 수 있어요. 그래서 롤백했다가 다시 올릴 때 0이 아니면, 그 파일이 롤백한 바이너리가 돈 동안 생겼는지부터 봐요. 새 바이너리가 돈 동안 생긴 고아는 배포를 막을 이유가 아니에요.

## 5. 바뀌는 계약과 시험

- `Lane_addon_store.mli`
  - `read_bindings` 설명에서 "sits beside a misnamed observation file" 과 "Each readable sequence is reconciled with retained observation filenames" 를 지워요. 커밋된 순번의 정확한 레코드 검증은 그대로예요.
  - `append_observation` 의 "runtime must reserve the renamed sequence" 는 그대로 둬요. 예약하는 방법이 `held` 예요.
  - binding 을 단계(`Before_rename`/`After_rename`)와 함께 돌려주는 쓰기 함수를 더해요. 지금 `save_binding` 은 `save_file_atomic_strict` 를 써서 단계를 지워요.
- 그대로 통과해야 하는 시험: `test_observation_publication_keeps_sequence_and_action_uncertainty`. 관측 `After_rename` 뒤 binding 이 성공하면 지금처럼 N 이 커밋되고 레인은 `Failed` 예요. 실패한 관측 파일을 다시 쓰지 않는다는 단언도 그대로예요.
- 새 기능 시험
  - binding `Before_rename`: 순번이 오르지 않고, 의존하는 쪽이 깨지 않고, 파일 N 은 그대로예요. 다음 binding 쓰기가 N 을 커밋하고 의존하는 쪽을 한 번 깨워요. 그다음 관측은 N+1 이에요.
  - binding `After_rename`: N 이 커밋되고, 레인은 `Failed`, coverage 는 complete 가 아니에요.
  - binding 이름 바꾸기 뒤 취소: 다시 던지기 전에 N 이 맞춰져요. 이어지는 detach 의 `persist` 가 N-1 을 쓰지 않아요.
  - N 을 붙잡은 동안 다른 경로가 `persist` 해도 binding 은 N 을 가리켜요.
  - binding 보다 큰 관측 파일이 있어도 `read_bindings`, `query_observations`, `freeze` 가 그 파일을 읽지 않아요.
  - 하나만 필요한 읽기가 `m.recovering` 상태를 돌려줘요(Retain, `browser_service_status`).

## 6. 하지 않는 것과 고르지 않은 안

- 여러 파일을 묶는 저널이나 디렉터리 교체는 하지 않아요. 커밋 시점을 binding 하나로 정하면 필요 없어요.
- 캐시, 횟수 제한, 스캔 간격 조정은 하지 않아요.
- `offload` 를 도메인 0 밖으로 옮기는 일은 이 RFC 범위가 아니에요.
- **고르지 않은 안 1: binding 보다 큰 파일을 덮어쓰기.** 처음 초안의 안이에요. 행동 증거를 지우고 `append_observation` 계약과 부딪쳐서 버렸어요.
- **고르지 않은 안 2: 공개 순서는 그대로 두고 첫 읽기 때 binding 을 앞으로 당기기.** 읽기 경로가 지난 레코드를 고쳐 써요. 복구 중 쓰기와 겹치지 않게 하려면 별도 조율이 필요해서 버렸어요.
- **고르지 않은 안 3: `highwater` 대신 다음 순번 파일만 확인하기.** 비용은 binding 수에 비례로 줄지만, 쓰는 쪽 실패를 읽는 쪽이 메우는 구조가 남아서 버렸어요.

## 7. 위험

- **붙잡은 관측이 오래 남는 경우:** binding 쓰기가 계속 실패하거나, 그 인스턴스가 다시 binding 을 쓰지 않으면 N 은 공개되지 않아요. 레인은 그동안 `Failed` 이고, 의존하는 쪽은 N-1 을 봐요. 어긋난 상태는 아니에요.
- **붙잡은 채 프로세스가 죽는 경우:** 파일 N 은 디스크에 남지만 커밋되지 않았으므로 읽는 쪽이 보지 않아요. 아무도 N 을 읽은 적이 없어서 어긋나지 않아요. 행동이었다면 영수증은 "package returned a result but its evidence was not committed" 를 이미 말해요. 인스턴스가 이어지지 않으므로 이 파일을 덮어쓰는 일도 없어요.
  - 이 고아는 보존되지만 지금은 어떤 읽기도 보여 주지 않아요. 운영자에게 보여 주는 길은 이 RFC 범위 밖이라 #46432 로 따로 다뤄요.
- **전원 차단:** binding 이 이전 내용으로 돌아갈 수 있어요. `Fs_compat` 이 처음부터 보장하지 않는 범위이고, 지금 관측 파일도 같아요.
- **이전 바이너리에서 넘어오는 순간:** 4의 배포 조건으로 막아요.

## 8. 단계

각 층은 혼자서도 맞게 동작해요.

| 층 | 내용 |
|---|---|
| L1 | 이 RFC |
| L2 | 단계를 돌려주는 binding 쓰기, `held`, binding 성공 뒤 공개(3.2~3.4), 3.3 표와 5의 runtime 시험. 이 층에서는 `highwater` 가 남아 있어 디스크 binding 을 읽는 쪽은 붙잡은 N 을 일찍 볼 수 있어요(지금과 같은 동작). 메모리 항목을 읽는 쪽은 커밋 뒤에만 봐요. L3 에서 같아져요. |
| L3 | `highwater` 삭제, 읽기 상한(3.5), `Lane_addon_store.mli` 문구, 5의 읽기 시험 |
| L4 | 하나만 필요한 읽기를 binding 파일 하나로(3.6), 복구 중 상태 시험 |

L2~L4 는 한 native stack 으로 함께 병합해요. 층을 따로 배포하지 않아요. L2 만 들어간 구간에서는 디스크 binding 을 읽는 쪽이 아직 붙잡은 N 을 볼 수 있어서, 이 RFC 가 없애려는 어긋남이 그 경로에 남아요.

## 9. 검증

- 기능 시험: 5의 시험을 대상 suite 로 돌려요. 맨 아래 PR 은 Core 빌드만 확인해요.
- 운영 측정: 배포 전후로 같은 부하에서 두 값을 재요.
  - `read_retained_bindings` 한 번의 시간
  - 메인 스레드 잠금 대기 비율(`_pthread_cond_wait` 의 부모가 `caml_thread_leave_blocking_section` 인 샘플 / 메인 스레드 전체)
- 4의 배포 조건을 지켜요.
