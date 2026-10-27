---
rfc: "keeper-guests-stay-inside-a-host-memory-budget"
title: "Keeper 게스트는 호스트 메모리 예산 안에서만 뜨고, 놀면 내려간다"
status: Draft
created: 2026-10-27
updated: 2026-10-27
author: claude
related: ["0394", "0395", "0400", "0405", "0406", "keeper-guest-survives-restart", "keeper-build-output-returns-to-a-disposable-volume"]
---

# RFC: Keeper 게스트는 호스트 메모리 예산 안에서만 뜨고, 놀면 내려간다

- 상태: 초안. 운영자 결정 전이라 코드는 바꾸지 않았다.
- 근거: 측정은 이 Mac(M3 Max, 16코어, RAM 128 GiB, Darwin 25.6.0, container 1.3.1)에서 2026-10-27 19:10~19:45 KST 에 했다. 코드 사실은 `origin/main` `387655e5165e` 에서 읽었다. 시각은 모두 KST 다. 측정 방법은 부록 A.
- 사람 결정 필요: §8. 예산 값, 내리는 기준 시간, 빌드 볼륨 처리는 운영자가 정한다.

## 0. 요약

지금은 Keeper 마다 microVM 게스트가 하나 있고, 게스트는 Keeper 수명 동안 산다. 게스트 상한은 서버 환경변수 한 줄(`MASC_KEEPER_MICROVM_MEMORY=8g`)이다.

Apple 의 Virtualization.framework 는 게스트가 놓은 메모리를 호스트에 돌려주지 않는다. 그래서 게스트가 호스트에서 차지하는 메모리는 부팅 직후 약 290 MB 에서 시작해 파일 캐시로 상한까지 자란다. 지금 VM 프로세스 24개(Keeper 게스트 23개 포함)가 호스트 메모리 84.9 GiB(RAM 의 66%)를 잡고 있고, swap 은 96~97% 찼다.

설정 상한의 합(178 GiB)이 호스트 RAM(128 GiB)보다 큰데, 이 합을 막는 장치가 없다. 50 Keeper 를 같은 방식으로 띄우면 상한이 2 GiB 여도 최악의 합이 100 GiB 다.

이 RFC 는 세 가지를 바꾼다.

- 호스트마다(이 Mac 과 SSH 끝점 각각) 게스트 메모리 예산을 선언한다. 떠 있는 게스트의 상한 합이 예산을 넘는 부팅은 하지 않는다.
- 게스트 크기를 전체 환경변수가 아니라 Keeper 별 측정값으로 정한다.
- 놀고 있는 게스트를 내리고, 다음에 쓸 때 다시 띄운다. 작업 트리 볼륨은 남는다.

Keeper 마다 VM 하나라는 격리와 지금 인원은 그대로 둔다. 바꾸는 순서와 되돌리는 법은 §6 이다.

## 1. 문제

### 1.1 지금 구조

- `sandbox_profile = "microvm"` 인 Keeper 는 Apple `container` 게스트 하나를 Keeper 이름으로 띄운다(`masc-keeper-vm-<keeper>-...`, RFC-0405). 게스트는 턴이 아니라 Keeper 수명이고, 서버를 재시작해도 산다(#31340).
- 게스트 상한은 서버 환경변수 `MASC_KEEPER_MICROVM_MEMORY=8g` 다. 코드 기본값은 2g 이다. `env_config_sandbox.ml` 주석에 따르면 2 GiB 게스트에서 빌드가 시간 초과이거나 exit 137 로 죽었다(2026-09-18 측정). Keeper TOML 의 `microvm_memory` 는 이 값을 Keeper 별로 덮어쓴다.
- Apple 문서(`docs/technical-overview.md`, 1.3.1 태그와 main 이 같다)는 이렇게 적는다. "memory pages freed to the Linux operating system by processes running in the container's VM are not relinquished to the host." 줄이려면 "occasionally restart them" 하라고 한다.
- container 1.3.1 에는 실행 중인 컨테이너의 메모리를 바꾸는 명령이 없다. `run -m` 은 만들 때만 적용되고, `container machine set memory=` 도 재시작 뒤에 적용된다.

### 1.2 측정

| 항목 | 값 | 방법 |
|---|---|---|
| 호스트 | RAM 128 GiB, 16코어 | `sysctl hw.memsize hw.ncpu` |
| 게스트 수와 설정 상한 합 | 23개, 178 GiB (8 GiB × 22 + 2 GiB × 1) | `container ls` |
| 게스트가 호스트에서 차지하는 메모리 | 84.9 GiB (VM 프로세스 24개, 평균 3.5, 최대 8.1) | 프로세스별 `footprint` 합 |
| 게스트가 안에서 쓴다고 보고한 양 | 55.3 GiB (중앙값 2.06, 위 5개 합 28.2) | `container stats` |
| 게스트 안 프로세스 메모리 | 3~26 MB. 사용 중인 메모리의 0.1% | `/proc/meminfo` 의 AnonPages. 작성 시점의 sampler 13틱, 게스트 161건 |
| 게스트 안 캐시 | 0.14~6.6 GiB. 사용 중인 메모리의 98%. 한 게스트(wkbl-front)는 tmpfs 1.04 GiB | 같은 곳. Cached, Buffers, Shmem, SReclaimable 합 |
| 새로 띄운 게스트(1 GiB, 놀고 있음) | 호스트 290 MB, 18초 뒤 292 MB. 부팅 2.58 s | `container run -d` 후 `footprint` |
| swap | 사용 29.7~31.5 GB, 전체의 96~97% | `sysctl vm.swapusage` |
| 압축 메모리 | 19:10 에 143 GiB 분량이 RAM 57 GiB 차지, 19:30 에 155 GiB 분량이 65 GiB 차지 | `vm_stat` |

### 1.3 원인

- 게스트가 호스트에서 차지하는 메모리는 쓴 최대치에서 줄지 않는다. 부팅 직후 290 MB 이던 게스트가 지금 평균 3.5 GiB 다. 늘어난 것은 프로세스 메모리가 아니라 파일 캐시다. 게스트는 캐시를 놓아도 되는 메모리로 보고하지만 호스트는 그 사실을 모른다.
- 그래서 최악의 합은 상한의 합이다. 178 GiB 는 호스트 RAM 128 GiB 보다 크다.
- 이 합을 막는 장치가 없다. `keeper_sandbox_microvm.ml` 주석은 게스트 하나를 호스트 메모리 약 460 MB 로 본다(2026-08-28 부팅 직후 측정, container 1.3.0). 그 값은 부팅 직후에만 맞다.

### 1.4 50 Keeper 이면

항상 켜 둔 게스트의 최악의 합은 50 × 상한이다.

| 상한 | 합 |
|---|---|
| 8 GiB | 400 GiB |
| 4 GiB | 200 GiB |
| 2 GiB | 100 GiB |
| 1 GiB | 50 GiB |

1 GiB 에서는 빌드가 되지 않는다. 2 GiB 에서도 실패한 기록이 있다. 상한만 낮추는 길은 50 Keeper 에서 막힌다. 떠 있는 게스트 수나 떠 있는 시간을 줄여야 한다.

### 1.5 Keeper 가 동시에 얼마나 쓰나

2026-10-27 09:00~19:36 에 `Execute` 도구 호출은 6,062건이고, 호출한 Keeper 는 21명이다(게스트 23개 중). 시간 창 안에서 `Execute` 를 한 번이라도 부른 Keeper 수는 이렇다.

| 창 | 중앙값 | p90 | 최대 |
|---|---|---|---|
| 5분 (창 124개) | 8 | 10 | 13 |
| 15분 | 11 | 13 | 16 |
| 30분 | 13 | 16 | 18 |

`Execute` 만 센 값이라 읽기나 검색 도구가 게스트를 쓴 시간은 빠졌다. 실제 사용은 이보다 많다. 이 값은 하한이다.

## 2. 이미 정해진 것

- RFC-0394, RFC-0395: 로컬 playground 는 닫혔고, 내구적인 격리 방향은 머신 경계다. 이 RFC 는 그 방향을 바꾸지 않는다.
- RFC-0400: 게스트가 자기 작업 트리를 볼륨에 가진다. 게스트를 내려도 트리는 남는다.
- RFC-0405: 게스트를 주는 런타임은 Keeper TOML 이 정한다. macOS 기본은 `apple_container` 다.
- RFC-keeper-guest-survives-restart(초안): 게스트에 부팅 계획 digest 를 label 로 붙인다. digest 에 메모리와 CPU 가 들어 있고, 계획이 다르면 게스트를 교체한다(`keeper_microvm_boot_plan.ml`). 이 RFC 의 "크기를 바꾸면 게스트가 교체된다"는 그 경로를 쓴다.
- RFC-0395 의 `remote_ssh`: Keeper 를 이름 있는 SSH 끝점에 붙인다(`[exec.ssh.endpoints.<name>]`).

## 3. 설계

### 3.1 호스트 예산

- 실행 호스트는 이 Mac 과 SSH 끝점 각각이다. 호스트마다 게스트 메모리 예산을 선언한다. 이 Mac 은 `[sandbox] microvm_memory_budget`, 끝점은 `[exec.ssh.endpoints.<name>] guest_memory_budget` 이다.
- 불변식: 한 호스트에서 떠 있는 게스트의 메모리 상한 합은 그 호스트의 예산 이하다.
- 검사는 한 곳에서 한다. 게스트를 부팅하거나 채택하는 함수가 예산을 예약하고, 못 하면 typed 오류로 끝낸다. 부르는 쪽마다 따로 검사하지 않는다.
- 장부는 따로 저장하지 않는다. 예약할 때마다 런타임 목록(`container ls` 와 inspect 의 `memoryInBytes`)에서 합을 다시 구한다. 서버를 재시작해도, 다른 프로세스가 게스트를 띄워도 어긋나지 않는다. 예약은 한 임계구역에서 한다.
- 예약이 안 되면 이 순서로 간다.
  1. 내릴 수 있는 놀고 있는 게스트가 있으면, 가장 오래 논 것부터 내리고 다시 예약한다. 마지막 사용 후 60초가 안 된 게스트는 내리지 않는다.
  2. 없으면 `boot_wait_sec`(기본 30초) 동안 기다린다.
  3. 그래도 안 되면 `microvm_memory_budget_exceeded` 로 그 턴을 실패시킨다. 오류에는 합, 예산, 요청 크기, 떠 있는 게스트 목록을 싣는다.
- 예산을 넘겨 조용히 부팅하는 갈래는 없다. 예산이 선언되지 않았으면 부팅을 거절한다(이름 있는 설정 오류). 단계 P1 까지는 거절하지 않고 기록만 한다(§6).

### 3.2 Keeper 별 크기

- `microvm_memory` 는 이미 Keeper TOML 에 있다. 전체 환경변수 `MASC_KEEPER_MICROVM_MEMORY` 는 새 Keeper 의 기본값으로만 남긴다. 운영 값은 Keeper 별로 둔다.
- 크기 규칙: `상한 = ceil(AnonPages 최대치 × 1.5) + 캐시 여유 1 GiB`. AnonPages 최대치는 P0 의 27시간 측정에서 Keeper 별로 읽는다. 빌드하는 Keeper 는 측정이 빌드를 잡았는지 확인한다. 못 잡았으면 빌드 한 번을 돌려 잰다. 캐시 여유 1 GiB 는 가정이고, P2 에서 빌드 시간이 늘지 않는지로 확인한다. tmpfs(Shmem)를 쓰는 Keeper(지금 wkbl-front 1.04 GiB)는 그만큼 더한다.
- 측정 전 처음 값은 가정이다. 가벼운 Keeper 2 GiB, 빌드하는 Keeper 6 GiB. 근거가 "2 GiB 에서 빌드가 실패했다"는 기록뿐이라 P0 결과로 바꾼다.
- 크기를 바꾸면 계획 digest 가 달라져 그 Keeper 의 게스트가 다음 부팅에 교체된다. 교체는 그 Keeper 가 놀 때만 한다. 교체 때 게스트 안 프로세스와 빌드 볼륨은 사라지고, 작업 트리 볼륨은 남는다.

### 3.3 놀면 내린다

- 상태는 셋이다. `Running`(턴 중이거나 최근에 씀), `Idle`(조건 충족 대기), `Hibernated`(컨테이너 없음, 작업 트리 볼륨 있음).
- 내리는 조건은 모두 만족해야 한다.
  1. 그 Keeper 의 턴이 진행 중이 아니다.
  2. 게스트에 사용자 프로세스가 없다. `container stats` 의 `numProcesses` 가 부팅 직후 기준값 이하다.
  3. 마지막 사용 후 `idle_after` 가 지났다. 마지막 사용은 마지막 턴 종료와 masc 가 게스트에 낸 마지막 요청 중 늦은 쪽이다.
  4. 붙어 있는 검증 조회가 없다(RFC-0406).
- 내리는 방법은 기존 `stop_and_delete_microvm_container` 다. 볼륨은 지우지 않는다.
- 깨우는 방법은 새 경로를 만들지 않는다. 다음 턴이나 읽기 요청이 지나가는 `ensure_started` 가 게스트가 없으면 부팅한다. 내렸다 깨우는 경우를 이 경로가 그대로 받는지는 §7 의 통합 시험으로 확인한다.
- 전이 이유는 typed 로 둔다. `Idle_timeout | Budget_pressure | Plan_changed | Operator`. 전이는 함수 하나가 하고, 매 전이를 생명주기 이벤트로 남긴다. 상태 전이 `match` 는 모든 쌍을 적고 `_ ->` 를 쓰지 않는다.
- `idle_after` 기본값은 10분으로 제안한다. 5분 창에서 Keeper 21명 중 8명, 15분 창에서 11명이 `Execute` 를 불렀다(§1.5). 값은 P3 의 그림자 기록으로 정한다.
- 깨우는 비용: 새 게스트 부팅은 2.58 s 였다(부하 중, 1 GiB, `container run -d`). 옛 측정은 1.3~2.4 s 다(2026-08-28). masc 의 부팅 경로는 볼륨과 shim 단계가 더해지므로 더 걸린다. 캐시가 비어서 첫 읽기는 느리다. P3 의 합격선에 깨움 지연을 넣는다.
- 빌드 볼륨: 지금은 부팅마다 새로 만든다(RFC-keeper-build-output-returns-to-a-disposable-volume). 내렸다 깨우면 빌드 결과가 사라져 다음 빌드가 처음부터다. 그래서 빌드하는 Keeper 는 빌드 볼륨을 내리기 전후로 살리는 방법이 정해지기 전에는 내리지 않는다(§8 Q3). 이 경우 빌더의 호스트 메모리는 크기 규칙으로만 묶인다.

### 3.4 SSH 끝점

- Keeper 끼리는 작업 트리를 공유하지 않는다(RFC-0400). Keeper 간 협업은 masc 서버(보드, 메시지)와 GitHub 를 거친다. 게스트가 이 Mac 에 있든 SSH 끝점에 있든 협업 경로는 같고, 배치는 격리와 메모리만 정한다.
- 예산은 게스트 상한의 합을 막는 규칙이라, 끝점이 Keeper 마다 게스트를 띄울 때(RFC-0395 Phase 2) 같은 불변식이 적용된다.
- Phase 1 끝점은 원격 계정의 프로세스라 Keeper 별 상한이 없다. 그 호스트에서 Keeper 별 메모리를 어떻게 묶을지는 이 RFC 밖이다(§8 Q5).
- Linux/KVM 호스트는 게스트 메모리를 되돌려받는 기능(balloon, free page reporting, KSM)을 쓸 수 있다. 이 RFC 는 그 기능을 요구하지 않는다. 예산은 어느 호스트에서나 맞는 상한이다.
- 어디에 둘지는 Keeper TOML 이 정한다(`sandbox_profile`, `remote_endpoint`). 자동 배치기는 범위 밖이다.
- `max_concurrent_sessions` 기본값 8 은 끝점을 쓰는 Keeper 전체 합산이다. 끝점 하나에 Keeper 여러 명을 두려면 올려야 하고, 요청마다 새로 인증하는 지연은 측정하지 않았다(§8 Q6).

### 3.5 측정은 계속 켠다

P0 의 sampler(부록 A)는 호스트 쪽 관측을 맡는다. P1 부터는 masc 가 게스트를 부팅·채택할 때 예약 전후의 합, 예산, 떠 있는 게스트 수를 생명주기 이벤트로 남긴다. §7 의 합격선은 이 둘로 판정한다.

## 4. 50 Keeper 에서 얼마나 드나

모델: 호스트 하나에서 `합 = 활동 Keeper 수 × (가벼운 상한 + 빌더 비율 × (빌더 상한 − 가벼운 상한))`. 가벼운 Keeper 2 GiB, 빌더 6 GiB, 빌더 비율 0.1~0.2 로 둔다. 내려간 게스트는 0, 떠 있는 게스트는 상한만큼으로 센다(최악).

가정 둘은 아직 측정이 없다.

- 활동하는 Keeper 의 비율이 인원에 비례한다. 오늘 21명에서 잰 비율(§1.5)을 50명에 그대로 쓴다.
- 빌더 비율 0.1~0.2. P0 에서 Keeper 별 AnonPages 최대치로 정한다.

| 내리는 기준 | 동시 활동 | 활동 Keeper 수 (50명, 한 호스트) | 합 GiB (한 호스트) | 25명씩 두 호스트, 호스트당 합 GiB |
|---|---|---|---|---|
| 5분 | p50 | 19 | 46~53 | 27 |
| 5분 | p90 | 24 | 57~67 | 33 |
| 5분 | 최대 | 31 | 74~87 | 43 |
| 15분 | p50 | 26 | 63~73 | 37 |
| 15분 | p90 | 31 | 74~87 | 43 |
| 15분 | 최대 | 38 | 91~107 | 53 |
| 내리지 않음 | - | 50 | 120~140 | 60~70 |

두 호스트 열은 빌더 비율 0.2 로 계산했다. 예산을 48 GiB(RAM 의 3/8)로 두면 이렇게 읽힌다.

- 한 Mac 에 50명을 올리면 빌더 비율 0.1 일 때 5분 기준 p50 에서만 예산 안이다.
- 25명씩 두 호스트로 나누고 5분 기준으로 내리면 최대 동시 활동에서도 43 GiB 로 예산 안이다. 15분 기준은 최대에서 53 GiB 로 예산을 넘는다.
- 빌더를 내리지 않으면(§3.3) 빌더 상한이 항상 떠 있다. 25명씩 나눈 호스트에서 빌더 비율 0.1 이면 항상 15 GiB, 0.2 이면 30 GiB 다. 여기에 가벼운 Keeper 의 활동분을 더하면 5분 기준 최대에서 각각 43 GiB 와 55 GiB 다. 0.2 이면 예산을 넘는다.

이 표는 모델의 출력이다. 가정이 바뀌면 숫자가 바뀐다. P0 결과로 다시 계산한다.

## 5. 다른 안

- **상한만 낮추기.** 50 Keeper 에서 상한 2 GiB 의 최악의 합이 100 GiB 다. 2 GiB 에서 빌드가 실패한 기록도 있다. 고르지 않는다.
- **게스트를 주기적으로 모두 재시작하기.** Apple 문서가 권하는 방법이다. 메모리가 자라는 원인은 그대로 두고 쌓인 만큼 비우는 일이라 증상 억제형 repair 다. 하던 일을 끊고 Keeper 마다 빌드 결과도 잃는다. 고르지 않는다. 이 RFC 의 내리기는 놀 때만, 조건을 모두 만족할 때만 하고 예산 불변식과 함께 간다.
- **Keeper 여러 명이 게스트 몇 대를 SSH 로 같이 쓰기.** 한 게스트 안에서는 한 Keeper 가 놓은 메모리를 다른 Keeper 가 다시 쓰므로 최대치가 겹치지 않아 합이 작다. 이미지에서 오는 파일(툴체인 등)의 캐시도 하나가 된다. Keeper 별 작업 트리는 복사본이라 합쳐지지 않는다. 고르지 않는 이유는 넷이다.
  1. 커널을 같이 쓴다. RFC-0394 의 머신 경계 방향과 다르다.
  2. 빌드 하나가 메모리를 다 쓰면 이웃이 같이 죽는다(2 GiB 게스트에서 빌드가 시간 초과이거나 exit 137 로 죽은 기록).
  3. Keeper 별 유닉스 계정, gh 신원, cgroup 상한을 따로 만들어야 한다.
  4. 게스트 이미지에 sshd 가 있는지, 요청마다 새로 인증하는 지연(RFC-0395)이 얼마인지 측정하지 않았다.
  읽기 전용 리뷰어처럼 격리를 낮춰도 되는 Keeper 집합이 정해지면 별도 RFC 로 다룬다. Apple `container machine`(1.3.x)이 재료가 될 수 있다.
- **전부 원격 Linux/KVM 로 옮기기.** 메모리 거동이 가장 좋다. 하드웨어가 필요하고 RFC-0395 Phase 2 가 아직 없다. 이 RFC 의 예산 모델은 그 위에서도 그대로 쓰이므로 막지 않는다.
- **Apple 에 메모리 반환을 요청하기.** 맞는 방향이지만 우리가 일정을 정할 수 없다. 이슈로 남기고 기다리지 않는다.

## 6. 단계와 되돌리기

한 번에 한 단계, 한 Keeper 씩 간다. 각 단계는 해당 Keeper 의 턴 실패율(제공자 원인 제외, 부록 A)이 기준선보다 오르면 멈춘다.

| 단계 | 내용 | 되돌리기 |
|---|---|---|
| P0 | 27시간 측정(진행 중). Keeper 별 AnonPages 최대치, 활동 시간대, 빌더 목록을 구한다. 코드 변경 없음 | `samples-20261027.stop` 파일 |
| P1 | 예산 보고만. 게스트를 부팅·채택할 때 합과 예산을 이벤트로 남긴다. 거절 없음 | 이벤트 끄기 |
| P2 | Keeper 별 크기. 가장 가벼운 Keeper 부터 하나씩, 그 Keeper 가 놀 때. 다음 부팅에 게스트가 교체된다 | TOML 값을 되돌리면 다음 부팅에 다시 교체 |
| P3 | 내리기 그림자 모드. 내렸을 결정만 `would_hibernate` 로 남기고 실제로는 내리지 않는다. 일주일 뒤 "내렸다면 다시 쓰기까지 걸린 시간" 분포를 본다. 짧으면 손해이니 기준을 늘린다. 그다음 가벼운 Keeper 부터 켠다 | 설정 한 줄 |
| P4 | 예산 거절 켜기. 예산이 선언되지 않으면 부팅 거절 | 예산 값 올리기 |
| P5 | SSH 끝점 예산과 배치. RFC-0395 Phase 2 이후 | 끝점에서 Keeper 떼기 |

## 7. 검증

합격선은 P4 이후 7일 연속으로 본다.

- 호스트의 VM 프로세스 `footprint` 합 ≤ 예산 × 1.1. 1.1 은 상한을 넘는 VM 고정 비용의 여유다. 상한 8 GiB 게스트의 최대 `footprint` 가 8.1 GiB 였다(§1.2).
- swap 사용량이 늘지 않고, 시간당 `swapouts` 증가가 P0 기준선의 1/10 이하다.
- 깨움 지연 p95 ≤ 5 s.
- 제공자 원인을 뺀 턴 실패율이 기준선 이하다.
- 빌드 exit 137 이 늘지 않는다.
- 예산 거절로 실패한 턴이 전체 턴의 1% 미만이다. 넘으면 예산이나 크기가 틀린 것이다.

시험:

- 예산 계산은 순수 함수로 둔다(떠 있는 상한 목록, 예산, 요청 → 예약 | 내릴 게스트 목록 | 거절). 성질 시험 둘: 결과의 합이 예산을 넘지 않는다. 턴 중인 게스트는 내릴 목록에 들어가지 않는다.
- 내리기 전이는 모든 (상태, 사건) 쌍을 `match` 로 적고, 새 상태를 더하면 컴파일이 막는지 본다.
- 가짜 `container` 런타임으로 깨우기, 내리기, 채택, 서버 재시작 뒤 장부 재계산을 시험한다.
- 실제 런타임으로 한 번: 게스트를 내렸다 깨운 뒤 작업 트리가 그대로이고 빌드 볼륨이 새로 만들어졌는지 본다.

## 8. 열린 질문

운영자 결정이 필요한 것.

- **Q1 예산.** 이 Mac 의 값. 제안은 48 GiB(RAM 의 3/8)다. 계산은 이렇다. 128 GiB 에서 masc 서버 21 GiB(측정 18~21)와 여유 20%(26 GiB)를 빼고, Spotlight·watchman·Ollama 가 압축 메모리로 잡은 약 28 GB 를 빼면 약 53 GiB 가 남는다. 다른 앱은 재지 않았고, 그만큼 더 줄어서 48 GiB 안팎이다. 그 28 GB 를 정리하면 76 GiB 안팎까지 올릴 수 있다.
- **Q2 `idle_after`.** 제안 10분. 5분과 15분 사이이고 §4 표의 두 줄 사이에서 합이 달라진다.
- **Q3 빌드 볼륨.** 내릴 때 빌드 볼륨을 살릴지 버릴지. 살리면 디스크를 쓰고, 버리면 깨울 때마다 처음부터 빌드한다. 정하기 전에는 빌더를 내리지 않는다.
- **Q4 빌더 목록.** 어느 Keeper 가 빌드하는지. P0 의 AnonPages 최대치로 정하고 운영자가 확인한다.
- **Q5 원격 호스트.** SSH 로 쓸 호스트가 있는지, 몇 GiB 인지. Phase 1 끝점에서 Keeper 별 메모리를 묶을 방법이 필요한지.
- **Q6 `max_concurrent_sessions`.** 끝점 하나에 Keeper 몇 명까지 둘지. 기본 8 이다.
- **Q7 공유 커널 샌드박스.** 격리를 낮춰도 되는 Keeper 범위가 있는지. 없으면 §5 의 해당 안은 닫는다.
- **Q8 lane add-on 컨테이너.** `lane_addon_engine.ml` 도 `--memory` 로 컨테이너를 띄운다. 같은 예산에 넣을지. 넣는다면 장부가 `masc-keeper-vm-*` 이름 규칙만으로는 부족하다.

## 9. 확신도

- §1.2 의 측정값과 §1.1 의 코드·문서 사실: 높음. 측정 조건을 적었다.
- §1.3 의 "늘어난 것은 파일 캐시": 높음. 게스트 161건에서 캐시가 사용 중인 메모리의 98%, 프로세스 메모리가 0.1% 였다. 단 측정은 한 시간 안의 놀고 있는 때이고 빌드 중의 값은 P0 에서 본다.
- §1.3 의 "호스트가 그 사실을 모른다": 중간. Apple 문서가 가리키는 방향이다. 게스트 하나를 골라 캐시를 비운 뒤 호스트 `footprint` 가 그대로인지는 직접 확인하지 않았다.
- §1.5 활동 수: 중간. `Execute` 호출만 센 하한이다.
- §4 표: 낮음. 인원 비례와 빌더 비율 가정이 측정 없이 들어갔다. 구조(합 = 활동 수 × 상한)는 맞고 숫자는 P0 뒤에 바뀐다.
- §3.3 의 깨움 지연과 빌드 볼륨 영향: 중간. 새 게스트 부팅은 쟀지만 masc 의 전체 부팅 경로는 이 RFC 에서 재지 않았다.
- §3.4 의 원격 호스트 메모리 거동: 낮음. Linux 호스트에서 쟀다는 근거가 없다.

## 부록 A. 측정 방법

모두 읽기만 하는 명령이다. 시각은 2026-10-27 KST 다.

- 호스트 메모리: `sysctl hw.memsize hw.ncpu`, `sysctl vm.swapusage`, `vm_stat`(페이지 크기 16 KiB, `Pages stored in compressor`, `Pages occupied by compressor`, `Swapins`, `Swapouts`).
- VM 프로세스 메모리: `pgrep -f com.apple.Virtualization.VirtualMachine` 로 PID 를 얻고 각각 `footprint <pid>` 의 `Footprint:` 값을 더했다.
- 게스트 보고: `container stats --no-stream --format json` 의 `memoryUsageBytes`, `memoryLimitBytes`, `numProcesses`.
- 게스트 안 구성: `container exec <게스트> cat /proc/meminfo` 의 MemTotal, MemFree, MemAvailable, Buffers, Cached, AnonPages.
- 새 게스트: `container run -d --name mem-probe-20261027 -m 1g masc-sandbox:general sleep 120` 으로 띄워 3초와 18초 뒤 `footprint` 를 재고 `container stop`, `container rm` 으로 지웠다.
- 서버 환경: masc 프로세스 환경에서 `MASC_KEEPER_MICROVM_MEMORY` 한 항목만 읽었다.
- 활동 수: `system_log_2026-10-27.jsonl` 의 `tool_call tool=Execute` 줄에서 Keeper 이름과 시각을 뽑아 5·15·30분 창마다 서로 다른 Keeper 수를 셌다.
- 턴 실패율(제공자 원인 제외): `keeper cycle FAILED` 줄을 Keeper 별로 세고 `dispatched=` 뒤 원인이 Provider 한도·오류·DNS·`auth status` 인 줄을 뺀다.
- 27시간 sampler: `.tmp/keeper-vm-memory/sample.sh` 가 1분마다 호스트 swap·load·압축 메모리, masc RSS, `container stats`, 2분마다 게스트 `/proc/meminfo` 를 `.tmp/keeper-vm-memory/samples-20261027.jsonl` 에 쌓는다. `samples-20261027.stop` 파일을 만들면 멈춘다.
