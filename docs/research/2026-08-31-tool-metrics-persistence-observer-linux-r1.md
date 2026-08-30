# Tool metrics persistence observer Linux R1

## 결과

`/api/v1/tool-metrics`가 restart-safe aggregate와 별도로 current-process persistence snapshot을
반환한다. snapshot은 runtime identity, queue depth/capacity/high watermark, queue-full drop,
append failure, 성공 flush 누계와 마지막 batch 상태를 포함한다. process-local counter는 hydration하지
않으며 missing event는 추측값 대신 JSON `null`이다.

이 표면으로 두 개의 기존 사각지대를 실제 Linux runtime에서 반증했다.

- r106: SIGKILL 직전 aggregate 5,000과 disk 4,096 사이의 pending 904를 직접 관측했다.
  replacement는 새 runtime ID로 4,096만 hydrate했다.
- r107: 실제 permission-denied append가 row 하나를 queue에서 제거했다. storage 복구 뒤 다음 row는
  기록됐지만 이전 row는 돌아오지 않았고 clean replacement는 1/2만 hydrate했다.

미해결 durability는 각각 [#32014](https://github.com/jeong-sik/masc/issues/32014)와
[#32015](https://github.com/jeong-sik/masc/issues/32015)에 기록했다.

## 현재 형식

`persistence.schema = masc.tool_metrics.persistence.v1`, `scope = current_process`다.
`runtime_instance_id`와 `process_started_at`은 `/health?full=1`의 `build` identity와 일치한다.
주요 필드는 다음과 같다.

- `queue_depth`, `queue_capacity`, `queue_high_watermark`
- `queue_full_dropped_records`, `append_failed_records`
- `flushed_records`, `flush_batches`
- `last_flush_trigger`, `last_flush_rows`, `last_flush_failed_rows`
- `last_flush_at_unix`, `last_append_error`

이 형식은 persisted lifetime total로 보이는 alias나 이전 형식 fallback을 만들지 않는다.

## r106 pending queue + SIGKILL

- base head: `a7b539b0565d6d8af13819c2dd1e3067cd5ee0f6`
- product head: `e152e2ce2554743e952519587ee94536c36d1134`
- image: `sha256:7ea771373f053a554135500d9a2f5883b11cf1e9a14e0cc88752e0036267fc62`
- binary: `69a0ce12...3f96`, preflight helper: `9572676a...b398`
- timer 300초, 실제 `masc_goal_list` 5,000/5,000 HTTP 200 및 body-level `isError=false`.
- 27.724811초, 평균 180.344 calls/s, sampled queue peak 2,040.
- 두 high-water batch 뒤 API: aggregate 5,000, flushed 4,096, queue 904,
  queue-full drop 0, append failure 0.
- disk 4,096행/463,618 bytes, SHA-256 `b4c2547f...a89c9`.
- SIGKILL exit 137/OOM false. replacement의 새 runtime ID는 `01a054ca-...`, hydrate/API 4,096,
  process counters 0, last event `null`이었다. pending 904는 사라졌다.
- replacement는 clean exit 0/OOM false.

## r107 append failure + recovery

- fresh volume의 `/app/data/tool-metrics`를 startup 뒤 mode 0555로 바꿨다.
- 첫 실제 call은 성공했지만 timer append가 `Permission_denied mkdirat`로 실패했다.
- API: aggregate 1, queue 0, flushed 0, append failed 1, last failed rows 1, raw error present.
- mode 0755로 복구하고 두 번째 실제 call을 성공시켰다.
- API: aggregate 2, flushed 1, historical append failed 1, last failed rows 0,
  last error `null`. disk는 1행/114 bytes, SHA-256 `1437f6b5...3a8a`였다.
- clean replacement는 새 runtime ID로 1행만 hydrate했다. 두 runtime 모두 exit 0/OOM false.

## r108 read latency

r106의 4,096행 volume을 새 runtime에서 hydrate한 뒤 `/api/v1/tool-metrics`를 순차 1,000회
호출했다. mean 0.173ms, p95 0.270ms, max 0.941ms였고 exit 0/OOM false였다. 이는 local
Linux/arm64 warm-cache 측정이며 네트워크 latency나 동시 fan-out의 상한으로 일반화하지 않는다.

## 검증과 경계

- Tool_metrics_persist 8/8, Tool_unified 6/6, focused `main_eio` build 통과.
- unit failure injection은 counter contract만 고정한다. r106/r107 판단은 actual MCP, HTTP API,
  Linux filesystem permission, disk rows/SHA, process replacement로 만들었다.
- observer는 손실을 복구하지 않는다. crash pending queue와 failed append retry는 별도 후속 구현이다.
- 전체 테스트와 GitHub CI는 실행하거나 통과했다고 주장하지 않는다.
- `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지 않았다.

## 근거

- [근거] exact product/image/binary/helper, API runtime identity, body-level accepted responses,
  live queue/flush/drop/failure snapshot, SIGKILL 및 permission failure, disk rows/SHA,
  replacement hydration/API와 exit/OOM을 2026-08-31T07:31:12+09:00 확인, 신뢰도 High.
- [근거] 4,096행 hydration 뒤 동일 API의 sequential 1,000회 latency와 runtime exit/OOM을
  2026-08-31T07:33:57+09:00 확인, 신뢰도 High.
