# Tool metrics fallback pending spool Linux R1

## 결과

r125는 queue capacity 아래에서도 metrics가 조용히 사라지는 반례였다. `/app/data`가 쓰기
불가인 상태에서 actual MCP call 1,000건은 모두 성공했지만 primary pending spool 1,000건이
실패했다. queue는 1,000이라 queue-full loss marker도 없었다. `SIGKILL` 뒤 replacement는
aggregate 0과 integrity `unknown`을 반환했다.

이 변경은 primary pending write가 실패한 record를
`<base>/.masc/tool-metrics-pending/<record-id>.json`에 원자적으로 쓴다. 같은 4,096 queue capacity가
fallback file 수도 제한한다. final JSONL append가 성공한 뒤에만 해당 pending file을 지운다.
따라서 임시 risk marker를 만들고 concurrent enqueue와 안전하게 지우는 새 race를 만들지 않는다.

r126에서 r125와 같은 1,000-call 장애를 다시 만들었다. producer는 fallback pending file 1,000개를
남겼고 `SIGKILL` replacement는 1,000개를 모두 aggregate로 복구한 뒤 final JSONL로 옮겼다. 다음
restart는 final row 1,000개만 읽어 중복이 없었다.

## 현재 형식

`persistence` current-process projection에 다음 필드가 추가된다.

- `fallback_spool_backed_queue_depth`
- `spool_fallback_write_failed_records`
- `last_spool_fallback_error`

startup hydrate report와 log에는 다음 수가 추가된다.

- `recovered_fallback_pending_records`
- `invalid_fallback_pending_files`

Primary와 fallback에 같은 `record_id`가 동시에 있으면 primary를 선택하고 한 번만 복구한다. fallback
pending path가 file이거나 unreadable이어도 final JSONL과 primary pending hydration을 중단하지 않고
invalid fallback source를 센다.

## exact runtime identity

- base head: `a1f97d44ce95e0dda9a1ed5f260646f3272b2ee7`
- product head: `f7eac670fd78093d9a8b58adf6a03b09cfcbed86`
- Linux/arm64 image:
  `sha256:ec68b5d24eb2d3e9c778290a24d80d5ba6ed2b50f4ef308ff4f5401e0f6039e4`
- binary SHA-256:
  `7cc72b450ad6ced660885d32a52c258e6dea9c60e73361db9fa16206ff00e3c5`
- preflight helper SHA-256:
  `49dec5ce9fb092592886c565cd76a7a6a1930de1a9ab13cdb5ea287fe098d545`
- helper와 health가 product head와 binary SHA를 각각 확인했다.

## focused 검증

- `Tool_metrics_persist`: 20/20
- `Tool_unified`: 6/6
- focused `lib/masc.cma`, 두 test executable build, `@fmt`: 통과

테스트는 fallback write/restart, 두 spool write failure의 memory-only 경계, primary/fallback duplicate
ID, unreadable fallback directory 격리를 포함한다.

## r125 반례

Parent #32031 exact image에서 `/app/data`를 mode 0555로 바꾸고 flush interval을 300초로 두었다.
256-way actual MCP call 1,000건을 보냈다.

- producer runtime: `01a0557a-af3a-7000-85d0-919012ec7526`
- HTTP/body success 1,000/1,000
- elapsed 5.264124초, 189.965/s, mean 1,037.897ms, p95 3,384.016ms,
  p99 4,188.374ms, max 5,041.557ms
- aggregate/queue 1,000, spool-backed 0, primary spool failure 1,000
- pending/final/marker file 0, integrity `unknown`
- `SIGKILL` exit 137, OOM false
- replacement runtime `01a0557b-4bf3-7000-ab89-4e90cda01885`: aggregate 0,
  queue 0, marker 없음, integrity `unknown`, graceful exit 0/OOM false

## r126: below-capacity 복구

같은 256-way/1,000-call/data-root failure 조건을 product image에서 반복했다.

- producer runtime: `01a0558b-b2e3-7000-b08b-187078f6c470`
- HTTP/body success 1,000/1,000
- aggregate/queue 1,000
- primary spool failure 1,000, fallback spool failure 0
- spool-backed/fallback-backed 1,000/1,000
- primary pending/final 0/0, fallback pending 1,000
- fallback directory disk blocks 약 4,076 KiB
- `SIGKILL` exit 137, OOM false

Data permission을 복구한 replacement runtime은
`01a0558c-7e98-7000-8edf-f5bd0dbfc7cb`였다.

- startup: loaded final 0, recovered pending 1,000, fallback pending 1,000
- initial aggregate/queue/retry/fallback-backed 1,000/1,000/1,000/1,000
- timer flush: final 1,000, fallback pending 0, queue 0
- final SHA-256: `daf0760c5886e93d18d2f5a7bf8c7c336099e81437359379a2fae920af9177f0`
- graceful exit 0/OOM false

세 번째 runtime `01a0558c-c7a6-7000-a451-048f9f0e74b1`는 final 1,000,
recovered pending 0, aggregate 1,000을 반환했다. 중복은 없었고 graceful exit 0/OOM false였다.

## r127: queue capacity와 loss marker 결합

같은 장애에서 256-way actual MCP call 5,000건을 보냈다.

- producer runtime: `01a0558d-5007-7000-b8ba-906beacaa62a`
- HTTP/body success 5,000/5,000
- elapsed 27.469079초, 182.023/s, mean 1,332.390ms, p95 5,237.535ms,
  p99 7,844.066ms, max 14,249.280ms
- aggregate 5,000, queue/fallback pending 4,096, drop 904
- primary spool failure 4,096, fallback spool failure 0
- concurrent queue-full marker primary failure 2, marker fallback failure 0
- integrity `known_incomplete`, marker source `runtime_state_fallback`
- `SIGKILL` exit 137, OOM false

Replacement runtime `01a0558e-4f4f-7000-aac8-ec783c3b89ad`는 startup에서 fallback pending
4,096개를 복구했다. final JSONL 4,096으로 flush한 뒤 fallback pending은 0이었다. final SHA-256은
`64b341a13b1b4979d1bd3a0d1033b36356323b38e4b99a491f80a52b3e49a4d4`다. Integrity는
producer runtime을 가리키는 `known_incomplete`를 유지했고 replacement는 exit 0/OOM false였다.

## r128: fallback pending 자체가 실패하는 경계

Primary data root를 막고 `.masc/tool-metrics-pending`을 regular file로 만들었다. 나머지 `.masc`는
writable이었다.

- producer runtime: `01a0558f-1980-7000-8528-050d87b9c23c`
- actual MCP HTTP/body success 100/100
- aggregate/queue 100, spool-backed 0
- primary/fallback spool failure 100/100
- last fallback error가 `Not a directory` target을 직접 가리킴
- `SIGKILL` exit 137/OOM false
- replacement runtime `01a0558f-6bca-7000-b9f3-5557d9915df8`: aggregate 0,
  invalid pending 1, invalid fallback pending 1, graceful exit 0/OOM false

두 pending 위치가 모두 실패하면 record는 memory-only다. 이 변경은 그 상태를 복구한다고 주장하지
않는다. 현재 process failure counter와 restart 뒤 invalid fallback source만 증언한다.

## 비용

| run | durable fallback | elapsed | throughput | mean | p95 | p99 | max |
|---|---|---:|---:|---:|---:|---:|---:|
| r125 parent | 없음 | 5.264124s | 189.965/s | 1,037.897ms | 3,384.016ms | 4,188.374ms | 5,041.557ms |
| r126 product | 1,000 files | 9.693538s | 103.162/s | 2,104.325ms | 6,100.684ms | 8,444.545ms | 9,297.650ms |

단일 local sample에서 r126 throughput은 45.7% 낮고 elapsed는 84.1% 길었다. 이는 primary가 실패할
때 actual record 1,000개를 sync atomic file로 보존한 비용이다. 정상 primary write 경로나 배포
latency 상한으로 일반화하지 않는다. Batch/WAL 방식은 이 비용을 줄일 수 있지만 이번 변경에는
추가하지 않았다.

## 판정 경계

- fallback pending은 queue capacity 4,096 안에서만 생성된다.
- host power loss, fsync durability, network filesystem, Kubernetes/PVC, multi-process writer는
  확인하지 않았다.
- 전체 테스트와 GitHub CI는 실행하거나 통과했다고 주장하지 않는다.
- `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지 않았다.

[Hada topic 33015](https://news.hada.io/topic?id=33015)의 원칙에 맞춰 “memory에는 있으니 나중에
flush될 것”이라는 낙관적 context를 process restart로 반박했다. 그 뒤 risk 설명만 저장하지 않고
복구 가능한 record를 다른 failure domain에 남겼다.

## 근거

- [근거] exact product/image/binary/helper, focused 20/20 및 6/6, r126/r127/r128 actual Linux
  response·file·SIGKILL·replacement를 2026-08-31T11:04:31+09:00 확인, 신뢰도 High.
- [근거] r125 parent와 r126 product의 단일 local 1,000-call latency 비교를
  2026-08-31T11:04:31+09:00 확인, 신뢰도 Medium. host load와 run order는 통제하지 않았다.
