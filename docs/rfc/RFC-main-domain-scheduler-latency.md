---
rfc: "main-domain-scheduler-latency"
title: "Main domain scheduler latency: measure it, then remove what makes it wait"
status: Draft
created: 2026-09-05
updated: 2026-09-05
author: vincent
related: ["0204", "0239", "0302"]
---

# RFC — 메인 도메인이 기다리는 시간을 재고, 기다리게 만드는 것을 없앤다

## 0. 요약

TUI 와 대시보드가 느린 이유는 메인 Eio 도메인이 자기 일을 못 하고 기다리기 때문이다. 2026-09-05 실측(`docs/research/2026-09-05-main-domain-scheduler-latency-research-r1.md`)에서 메인 스레드 시간의 72% 가 blocking syscall 뒤의 도메인 락 재획득 대기였고, `/health` 는 p90 3.4초, 최대 9.6초였다. 호스트는 load 80~300 이었다.

이 RFC 는 다섯 단계다. 단계마다 같은 계기로 전후를 잰다.

| 단계 | 내용 | 성공 기준 (같은 호스트, 같은 계기) |
|---|---|---|
| 0 | 메인 도메인 lag 프로브 + GC 카운터를 `/health` 에 싣고 하네스로 읽는다 | 배포 후 `.scheduler` 가 채워진다. 기준선이 기록된다 |
| 0b | 힙 루트 진단: 등록된 루트별 `Obj.reachable_words` | live 2.5GB 의 상위 3 보유자를 이름으로 안다 |
| 1 | 부팅 창: TUI 는 `startup.state_ready` 전엔 surface 를 안 부르고 "server booting" 을 보인다. 레지스트리 재생 상한을 소비자 크기로 내린다 | 재기동 뒤 TUI 에 10초 타임아웃이 0건. 포트 열림→ready 가 절반 이하 |
| 2 | 메인 도메인 위생: keeper fiber 가 부르는 `Dated_jsonl` 스캔·`Stdlib.input`·`fsync` 를 domain pool 또는 Eio 경로로 옮긴다. `run_in_systhread` 는 닫힌 syscall 집합만 받는 타입 경계로 바꾼다 | 프로브 p99 가 절반 이하, 1초 이상 stall 이 분당 0 |
| 3 | 서빙 도메인 분리(RFC-0204 Phase 3): wait-free 읽기 경로를 별도 도메인에서 서빙, 상태를 만지는 핸들러는 메인 도메인 큐로 전달 | 메인 도메인이 멈춰도 `/health` 와 스냅샷 읽기는 p99 50ms 이하 |
| 4 | 할당과 live 줄이기: exact-lane projection 은 요약만 상주, 본문은 디스크에서 읽는다. 체크포인트는 messages 본문 대신 blob 참조 | live 힙 절반 이하, major GC 분당 횟수 절반 이하 |

## 1. 문제

측정값은 연구 문서에 있다. 여기서는 구조만 적는다.

1. HTTP accept, 모든 연결 fiber, SSE, 5개 refresh loop, 12개 keeper loop 가 한 도메인 위에 있다. 이 도메인의 스레드가 blocking section 을 나올 때마다 도메인 락을 다시 잡아야 하고, 그 락은 같은 도메인의 systhread 나 STW 를 대신하는 backup thread 가 잡고 있을 수 있다. 초당 약 15,000회 syscall 이면 그 대기가 곧 지연이다.
2. 워커 도메인 14개는 한가하다. 무거운 일은 이미 pool 로 넘어가 있다. 그런데도 메인이 느린 이유가 1번이다.
3. live 힙 2.5GB 는 모든 major 마킹의 분모다. 할당은 13~20MB 체크포인트 인코딩, 대시보드 프로젝션(시간당 약 4GB), 키퍼 턴 본문(185~299KB)이 만든다.
4. 부팅 때 425MB 레지스트리 로그를 메인 fiber 가 전부 파싱한다. 포트는 그 전에 열린다.
5. 서버는 하루 8~19번 재시작된다. 매번 1~4가 다시 일어난다.

## 2. 왜 이 순서인가

- 0 이 먼저다. 지금까지의 성능 작업(RFC-0204, 0302, #31993)은 관찰로 시작했고 배포 뒤 다시 잴 계기가 없었다. `sample` 은 OCaml 5 fiber 스택을 못 풀어 leaf 만 준다. 프로브는 메인 도메인이 ready fiber 를 얼마나 늦게 돌리는지 직접 잰다. 이것이 TUI 가 겪는 숫자다.
- 0b 가 없으면 4 는 추측이다. `Gc.quick_stat` 의 live 는 총량만 준다.
- 1 은 코드가 작고 위험이 낮으며 "붙자마자 끊김" 을 바로 없앤다.
- 2 는 1번 구조를 직접 줄인다. `run_in_systhread` 60곳을 손으로 한 곳씩 고치는 것은 N-of-M 패치다. 대신 임의 클로저를 받는 `Eio_guard.run_in_systhread` 를 없애고, `fsync`·`fchmod`·`stat`·`readdir`·`rename`·`realpath`·파일 읽기/쓰기 같은 닫힌 집합만 systhread 로 가게 타입으로 막는다. 컴파일러가 모든 호출 지점을 열거한다.
- 3 은 RFC-0204 가 이미 실현 가능하다고 판단한 하이브리드 경로다. Eio 의 Promise·Stream 은 도메인 간 안전하다.
- 4 는 가장 크지만 0b 결과를 봐야 한다.

## 3. Phase 0 설계 (이 PR)

- `Scheduler_lag` (lib/core): 100ms 주기로 monotonic 클록에서 자고, 늦게 깬 만큼을 600칸 링에 기록한다. 링은 슬롯마다 `Atomic.t` 다. 요약은 nearest-rank p50/p95/p99/max/mean 과 1초 이상 stall 수.
- 프로브는 `mark_owner_state_ready` 직후 메인 도메인에서 fork 한다. 부팅 재생은 정상 상태 lag 로 세지 않는다. 프로브 안의 예외는 프로브만 멈추고 `stopped_reason` 으로 보고한다. 서버 switch 를 취소하지 않는다.
- `/health` `.gc` 에 `minor_collections`·`major_collections`·`forced_major_collections`·`minor_words`·`promoted_words`·`major_words`·`space_overhead` 를 더한다. 전부 누적값이라 두 번 읽으면 비율이 나온다. `Gc.quick_stat` 그대로다.
- `/health` `.scheduler` 는 `probe` 상태, `interval_ms`, `window_s`, `stall_threshold_ms`, `samples`, 백분위, `stalls`, `pool_domains` 를 싣는다.
- `scripts/harness/perf/scheduler_lag_probe.sh` 는 실행 중인 서버에 붙어 `/health` 지연 백분위, `.scheduler`, 두 번 읽은 `.gc` 의 비율을 찍는다. 문턱값은 없다. 기준선이 먼저다.

## 4. 수용 기준

- Phase 0: 배포 뒤 `scheduler_lag_probe.sh` 출력 두 벌(부팅 직후 2분, 안정 후)을 이 RFC 에 붙인다. 그 값이 Phase 1~4 의 기준선이다.
- 이후 단계는 위 표의 기준을 같은 스크립트로 증명한다. 호스트 load 를 함께 적는다. load 가 다르면 비교하지 않는다.

## 5. 하지 않는 것

- 타임아웃을 늘리거나 갱신 주기를 줄여 라벨만 바꾸는 것. 증상 억제다.
- 로그를 줄이거나 dedup 하는 것. 로그는 원인이 아니다(시간당 8,800줄).
- `Gc.set` 값을 측정 없이 올리는 것. 0 의 카운터로 minor/major 비율을 본 뒤에 결정한다.
- keeper 본문을 워커 도메인으로 옮기는 것. RFC-0059 가 affinity 문제로 철회했고, 그 전제(소유권 모델, RFC-0239)가 아직 없다.

## 6. 위험

- 프로브 fiber 는 100ms 마다 깨는 fiber 하나다. 비용은 sleep 하나와 float 하나 쓰기다.
- `/health` 응답이 필드 11개 늘어난다. 읽는 쪽(TUI `Tui_decode.decode_server_identity`)은 모르는 필드를 무시한다.
- 링을 다른 도메인에서 읽으면 한 슬롯이 덮어쓰기 중일 수 있다. 값은 옛것 아니면 새것이다. 진단 용도로 충분하다.
