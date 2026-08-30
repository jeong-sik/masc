# Tool metrics append retry Linux R1

## 결과

`Tool_metrics_persist`가 JSONL append에 실패한 row를 버리지 않고 같은 4,096 capacity 안의 retry
queue에 보존한다. retry row와 append 중인 in-flight row도 capacity와 `queue_depth`에 포함한다.
writer는 retry를 새 row보다 먼저 처리하며 실패한 drain을 즉시 중단한다.

queue가 high watermark 위에 있어도 storage failure로 busy loop하지 않도록 retry delay는
`min(configured flush interval, 0.5s)`다. tool completion 경로는 기존처럼 짧은
`Stdlib.Mutex` enqueue만 수행하며 파일 I/O를 기다리지 않는다.

r109는 #32015의 한 건 반례를 그대로 뒤집었다. mode 0555에서 실패한 원래 row가 mode 0755
복구만으로 기록됐고 clean replacement가 1/1을 hydrate했다. r110은 storage unavailable 상태에서
256-way 실제 call 1,000건을 모두 받고, 복구 뒤 1,000행과 replacement 1,000을 확인했다.

## 변경

- `retry_queue`: failed append를 보존하고 main queue보다 먼저 처리한다.
- `in_flight_records`: append가 queue lock 밖에서 진행되는 동안 capacity slot을 예약한다.
- `queue_depth`: ready + retry + in-flight의 합이다.
- append failure와 Eio cancellation은 in-flight row를 retry queue로 되돌린다.
- snapshot에 `retry_queue_depth`, `in_flight_records`를 추가한다.
- `append_failed_records`는 unique row 수가 아니라 append 실패 시도 누계다.

## r109 단일 row

- base head: `6ca1b3f8229138add11c6cb37423baf6224d4117`
- product head: `0c743e5ffce60d7efe3f0564a3a90e4296f50d55`
- image: `sha256:6271fed1c232a91890f4ec45e87ce3c09a3a2da51ec5b234bb6c187d461a04fa`
- binary: `7155ff1c...b158`, preflight helper: `8f0cf1c9...5343`
- mode 0555에서 실제 call 1/1 성공. 2.2초 probe 시 append 시도 2회, CPU 0.23%,
  queue 1/retry 1/in-flight 0, flushed 0, drop 0이었다.
- mode 0755 복구 뒤 새 call 없이 0.763408초 안에 queue 0, flushed 1, last error `null`.
- disk 1행/114 bytes, SHA-256 `0bc30e33...7463`.
- clean replacement `hydrated 1`, API 1. 두 runtime 모두 exit 0/OOM false.

## r110 unavailable storage + 1,000 concurrent calls

- mode 0555에서 parallelism 256으로 `masc_goal_list` 1,000/1,000 HTTP 200 및
  body-level `isError=false`; 3.580424초.
- failure snapshot: aggregate/queue 1,000, retry 1, in-flight 0, flushed 0, drop 0,
  append failure 시도 5, CPU 0.42%, memory 101MiB.
- mode 0755 복구 뒤 새 call 없이 0.435634초 안에 1,000행을 한 batch로 기록했다.
- recovered snapshot: aggregate/flushed 1,000, queue/retry 0, historical failure 시도 18,
  last failed rows 0, last error `null`.
- disk 1,000행/112,815 bytes, SHA-256 `6ff4d906...a43`.
- clean replacement `hydrated 1000`, API 1,000. 두 runtime 모두 exit 0/OOM false.

## 검증과 경계

- Tool_metrics_persist 8/8, Tool_unified 6/6, focused `main_eio` build 통과.
- unit test는 failed row identity가 복구 뒤 실제 JSONL에 기록되는 것을 확인한다.
- 실제 판정은 Linux permission failure, actual MCP body success, live retry snapshot,
  storage-only recovery, disk rows/SHA, clean replacement로 수행했다.
- retry는 process memory에만 있다. SIGKILL pending loss #32014는 해결하지 않는다.
- storage failure가 계속되어 pending 4,096에 도달하면 이후 metric은 기존 non-blocking 정책대로 drop한다.
- partial append 뒤 exception의 중복/부분 JSONL, 자정 경계 retry, network filesystem은 미확인이다.
- 전체 테스트와 GitHub CI는 실행하거나 통과했다고 주장하지 않는다.
- `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지 않았다.

## 근거

- [근거] exact product/image/binary/helper, mode 0555/0755, body-level accepted responses,
  retry/in-flight/drop/flush snapshots, retry cadence CPU/memory, disk rows/SHA,
  replacement hydration/API 및 exit/OOM을 2026-08-31T07:48:15+09:00 확인, 신뢰도 High.
