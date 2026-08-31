# Tool metrics pending spool Linux R1

## 결과

`Tool_metrics_persist.enqueue`가 성공한 호출은 최종 JSONL batch 전에
`data/tool-metrics-pending/<record_id>.json`으로 원자 게시된다. final append가 성공하면 pending
파일을 제거하고, 프로세스가 그 전에 종료되면 다음 기동이 pending row를 aggregate와 retry queue에
복구한다. final append 뒤 pending 삭제만 실패한 창은 JSONL의 `record_id`로 dedup한다.

r111에서 timer를 300초로 고정한 뒤 실제 `masc_goal_list` 401건을 받았다. kill 직전 aggregate,
queue, spool-backed queue, pending file은 모두 401이고 final JSONL은 0행이었다. `SIGKILL` exit 137,
OOM false 뒤 replacement는 pending 401건을 복구해 final 401행으로 수렴했다. 기존 r106의
`accepted 5,000 / final 4,096 / replacement 4,096` 반례와 달리 이 범위의 accepted row가
사라지지 않았다.

별도 restart에서 pending 디렉터리를 mode 0555로 바꿔 shutdown final append는 성공하고 pending
삭제만 실패하게 만들었다. 다음 기동은 final 402행과 stale pending 1개를 읽어
`deduplicated pending=1`, aggregate 402를 반환했다. 403으로 중복 집계하지 않았다.

## 변경

- 모든 새 row에 UUIDv7 `record_id`를 기록한다.
- queue capacity는 ready, retry, in-flight뿐 아니라 아직 spool을 게시 중인 producer도 포함한다.
- pending 파일 쓰기는 Eio fiber에서 `Eio_guard.run_in_systhread`로 분리하고, 짧은 queue mutex는 I/O
  동안 잡지 않는다.
- atomic pending 게시 실패는 in-memory fallback으로 남기고 `spool_write_failed_records`와
  `last_spool_error`에 노출한다.
- final append 실패는 기존 retry queue와 pending 파일을 모두 보존한다.
- startup은 pending ID 집합만 메모리에 올린 뒤 final JSONL을 streaming scan해 stale pending을
  dedup한다. 전체 lifetime ID set은 만들지 않는다.
- snapshot에 `spooling_records`, `spool_backed_queue_depth`, spool write/delete failure를 추가했다.

## r111 SIGKILL과 dedup

- base head: `1cdf8d1e9bb84f04302a39866b20cf1d5167e49b`
- product head: `f2d5269e7ed97dff819641bc6f8a3618b207c3a2`
- image: `sha256:7bd2952dc38655301302d1867534b42b27e8997fab5b01efbd6be1ee113639a6`
- binary: `1ea4b93b...ce9b`, preflight helper: `9575193b...b90`
- preflight helper와 `/health?full=1` 모두 product head와 binary SHA를 증언했다.
- kill 전: aggregate가 actual call 401건을 관측했고, 그중 저장한 body-level check 201건은
  `isError=false`였다. aggregate/queue/spool-backed/pending 401, final 0, drop/spool failure 0이었다.
- kill: exit 137, OOM false.
- replacement: 새 runtime ID, `recovered pending=401`, aggregate/final 401, pending 0,
  final SHA-256 `919614b6...26`.
- append/delete 창: final 402, pending 1에서 replacement가 `loaded=402`,
  `deduplicated pending=1`, aggregate/final 402, pending 0을 확인했다.

## r112 256-way latency와 반복 crash

fresh named volume에서 256-way actual call 1,000건을 비교했다.

| image | body OK | elapsed | throughput | mean | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|---:|
| old append-retry | 1,000/1,000 | 3.303561s | 302.704/s | 590.135ms | 2,008.874ms | 2,548.915ms | 3,282.011ms |
| pending spool | 1,000/1,000 | 3.502401s | 285.518/s | 598.825ms | 2,115.920ms | 2,582.855ms | 3,109.525ms |

단일 로컬 표본에서 spool head는 old보다 throughput이 5.7% 낮고 p95가 107.046ms 높았다.
노이즈와 단일 실행 때문에 회귀 상한으로 일반화하지 않는다. 양쪽 p95가 이미 2초대이므로 평균만 보고
completion path가 빠르다고 판정하지 않는다.

초기 load 시도는 xargs 자식에 session ID가 전달되지 않아 HTTP 400 1,000건, accepted 0이었다.
이 표본은 성능/내구성 근거에서 제외했다. 수정한 run은 HTTP 200 및 body `isError=false`
1,000/1,000, pending/queue 1,000, final 0, drop/spool failure 0이었다. 다시 `SIGKILL`한 뒤
replacement가 pending 1,000건을 복구해 final 1,000행, pending 0으로 수렴했다.

## r114 capacity 4,096 경계

final JSONL 디렉터리만 mode 0555로 막고 pending 디렉터리는 writable로 유지했다. 256-way actual
call 5,000건은 HTTP 200/body OK 5,000/5,000이었고 10.923281초(457.738/s)에 끝났다. aggregate는
5,000이지만 bounded persistence 상태는 다음처럼 정확히 갈렸다.

- queue/spool-backed/pending 4,096, final 0
- queue-full drop 904, spool write failure 0
- append failure attempt 31; retry queue 1, CPU point sample 0.61%, memory 161.2MiB
- pending directory 672,015 bytes

full queue에서 persistence snapshot은 queue를 순회한다. 동일 image의 1,000회 API GET은 empty queue
mean/p95 0.144/0.208ms, full 4,096 queue 0.249/0.385ms였다. 이 환경에서 관측된 증분은 mean
0.105ms, p95 0.177ms다.

full queue를 `SIGKILL`한 뒤 final storage 권한만 복구했다. replacement는 pending 4,096을 복구해
final 4,096행, pending 0으로 수렴했고 exit 0/OOM false였다. pre-kill에 명시적으로 drop된 904는
복구되지 않는다. replacement의 aggregate가 5,000이 아니라 4,096인 것은 durable capacity 계약과
일치한다. drop counter는 current-process라 replacement에서 0으로 재시작하므로, pre-kill snapshot이
없다면 과거 904 drop을 새 process가 증언하지는 못한다.

## 연구 연결과 판정 경계

- [Hada topic 33015](https://news.hada.io/topic?id=33015)의 핵심처럼 이전 process-memory queue가
  안전하다는 전제를 보존하지 않고, accepted/final/replacement를 서로 다른 truth로 다시 측정했다.
- [The Tail at Scale](https://www.cse.ust.hk/~weiwa/teaching/Fall15-COMP6611B/reading_list/TheTailAtScale.pdf)의
  관점대로 mean뿐 아니라 p95/p99/max를 기록했다.
- [Supersede](https://arxiv.org/abs/2606.27472)의 stale-state 교체 문제와 같은 방향으로,
  restart 시 final `record_id`가 stale pending을 명시적으로 대체한다.

이 증거는 Linux/arm64 Docker Desktop의 local named volume과 process `SIGKILL`에 한정한다. host
power loss, network filesystem, Kubernetes/PVC, multi-process writer, 전체 테스트, GitHub CI는
확인하지 않았다. pending 게시 자체가 실패하면 메모리 fallback이므로 crash guarantee가
없고 API가 그 실패를 노출한다. `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지
않았다.

## 근거

- [근거] exact product/image/binary/helper, focused 11/11 및 6/6, actual MCP body, pending/final
  file count, process exit/OOM, replacement hydration/dedup/API/disk SHA를
  2026-08-31T09:02:33+09:00 확인, 신뢰도 High.
- [근거] fresh-volume old/new 256-way 1,000-call HTTP/body success와 latency distribution을
  2026-08-31T09:02:33+09:00 확인, 신뢰도 Medium. 단일 로컬 실행이라 비교 일반화는 하지 않는다.
- [근거] unavailable final storage에서 5,000 accepted, bounded 4,096/904 분리, full-queue API
  latency, SIGKILL replacement 4,096 recovery를 2026-08-31T09:08:10+09:00 확인, 신뢰도 High.
