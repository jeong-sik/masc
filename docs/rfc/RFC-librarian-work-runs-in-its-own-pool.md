---
rfc: "librarian-work-runs-in-its-own-pool"
title: "Librarian 작업은 자기 pool 에서 돈다"
status: Draft
created: 2026-11-16
updated: 2026-11-16
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0204", "0474", "librarian-gate-waits-on-the-destination-not-on-passes"]
---

# Librarian 작업은 자기 pool 에서 돈다

## 0. 요약

- 11-16 TypeSafe 가 402 로 거절하는 동안 Librarian pass 하나가 50~303초 걸렸다. 서버는 CPU 416% 를 썼다(이슈 #52389).
- 그 CPU 는 Keeper 턴과 HTTP 요청이 쓰는 shared pool 에서 나갔다. Librarian 의 비용이 바깥 서비스 상태에 따라 커지면 다른 일의 worker 를 가져간다.
- 이 RFC 는 `Pool_lane` 에 `Librarian` 갈래를 더하고, 그 갈래의 pool 작업을 domain 1개짜리 Librarian pool 로 보낸다.
- 숫자 상한이나 cooldown 은 쓰지 않는다. lane 은 typed variant 이고, 나누는 기준은 "누구의 일인가" 다.

## 1. 지금

- `Pool_lane.lane` 은 `Read | Background` 다. HTTP 읽기는 RFC-0204 L3 부터 read pool(2 domain)을 쓰고, 나머지는 모두 shared pool 을 쓴다.
- 16 코어 운영 서버의 배분은 shared 8 + read 2 + codec 2 + fixed 3 = 15 다(`Executor domains` 로그 줄, 11-16 03:30Z).
- Librarian 의 모든 pass 는 `Keeper_memory_lane.submit_librarian` 의 `Keeper_lane.fork` 한 곳에서 시작한다. pass 안의 pool 작업(`Pool_work.submit`, 사슬 복원·sha256 포함)은 이 fiber 와 그 자식에서 나온다.
- add-on 검증(`server_librarian_addon_validation.ml`)은 pool 이 아니라 `Systhread_host` 에서 돈다. 이 RFC 범위 밖이다.

### 1.1 잴 수 없었던 것

- pool 대기는 프로세스 메모리(`Pool_wait`)에만 있고 `/health?full=1` 로만 보인다. 11-16 사고 구간 값은 재시작으로 지워졌다.
- 로그로 본 대리 지표: Keeper 턴 시간은 모델 호출 시간과 같이 움직였다(p95 둘 다 814.9 s, 01–02Z). 대시보드 렌더는 사고 직전 01:2x–01:5x 에 48.6 s 까지 늘었다. 경합과 맞는 모양이지만 대기와 실행이 섞인 값이라 증명은 아니다.

## 2. 정하는 것

### 2.1 lane

```ocaml
type lane = Read | Librarian | Background
```

- `with_librarian f` 는 `f` 와 그 자식 fiber 를 `Librarian` 으로 표시한다.
- read 표시가 Librarian 표시보다 먼저다. `with_background` 는 둘 다 지운다.
- pool 작업 안에서는 lane 을 물려받지 않는다(RFC-0204 그대로). 중첩 submit 은 그 worker 에서 바로 돈다.

### 2.2 pool

- `Executor_pool_ref` 와 `Domain_pool_ref` 는 `Librarian` lane 의 작업을 Librarian pool 로 보낸다. 그 pool 이 없으면(시험, 설치 전) shared pool 로 보낸다. read pool 과 같은 규칙이다.
- `Pool_wait` 는 lane 마다 따로 센다. `/health?full=1` 의 `pool_wait.librarian` 과 `librarian_pool_domains` 로 보인다.

### 2.3 크기

- Librarian pool 은 어떤 호스트에서도 domain 1개다. 다른 pool 을 나누기 전에 limit 에서 먼저 뺀다.
- 규칙: Librarian 은 턴이 기다리지 않는 기억 관리다. 그래서 모든 pool 이 갖는 최소 1개만 받는다. 측정으로 맞춘 값이 아니다.
- 16 코어에서는 shared 8 → 7 이 된다.

## 3. 대가

- Librarian 작업은 한 worker 에 줄을 선다. Cpu 작업(가중치 1.0)은 그 worker 의 Io 작업이 끝나야 들어간다. 여러 Keeper 의 pass 가 겹치면 Librarian 이 늦어진다. 턴과 요청은 늦어지지 않는다.
- Librarian 작업끼리 서로의 결과를 기다리면 worker 1개에서 멈출 수 있다. Librarian 모듈(`keeper_librarian*`, `keeper_memory_admission*`, `keeper_memory_lane`)에서 fiber 사이 기다림은 purge 의 `exited` promise 하나뿐이고, 이것은 pool 작업이 아니다. 중첩 submit 은 바로 돈다.
- shared pool 이 1개 줄어든다.

## 4. 버린 것

- 동시 pass 수 상한, cooldown: 바깥 서비스 상태에 맞춘 숫자가 필요하다.
- Librarian pool 2개: read pool 과 같은 크기지만 근거가 없다.
- 측정 먼저(`pool_wait` 를 주기적으로 기록): 다음 사고까지 구조 문제가 남는다. 사용자가 고치는 쪽을 먼저 골랐다(11-16).

## 5. 확인

- `test/test_read_pool.ml`: Librarian pool worker 를 잡아 둔 동안 다른 lane 의 submit 네 가지가 shared pool 에서 시작한다. Librarian 작업과 그 자식 fiber 의 작업은 Librarian pool 에서 돈다.
- `test/test_pool_lane.ml`: 표시와 우선순위.
- `test/test_domain_budget.ml`: 16 코어 7/2/2/1, 작은 호스트의 줄이는 순서.
- 배포 뒤: `/health?full=1` 의 `pool_wait.background.wait` 와 `pool_wait.librarian.wait` 를 다음 판정 서버 거절 구간 앞뒤로 읽는다(#52403).
