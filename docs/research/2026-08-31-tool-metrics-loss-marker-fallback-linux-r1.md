# Tool metrics loss marker fallback Linux R1

## 결과

r118은 `/app/data` 전체가 쓰기 불가일 때 pending row와 primary loss marker가 함께 사라지는
반례였다. process 안에서는 4,097 calls, queue 4,096, drop 1을 볼 수 있었지만 `SIGKILL` 뒤
replacement는 aggregate 0과 integrity `unknown`만 반환했다.

이 변경은 primary marker 쓰기만 실패했을 때
`<base>/.masc/tool-metrics-loss-marker.json`에 같은 166-byte marker를 원자적으로 쓴다. 전체
metrics row를 복제하지 않는다. startup은 bulk data marker와 runtime-state fallback을 따로 읽고,
retention 안에서 가장 최신인 유효 marker를 고른다.

r119에서 r118과 같은 `/app/data` permission failure를 다시 만들었다. 4,097 tool call 뒤 primary
marker는 실패했고 fallback은 성공했다. `SIGKILL` 뒤 aggregate row는 하나도 복구되지 않았지만
replacement는 원래 runtime ID와 `known_incomplete`를 유지했다. 따라서 aggregate 0을 완전한
history로 오인하지 않는다.

## 현재 형식

`aggregate_integrity`에는 다음 필드가 추가된다.

- `loss_marker_source`: `bulk_data | runtime_state_fallback | null`
- `invalid_loss_marker_sources`: 읽기 실패나 current schema 불일치가 난 source 목록

current-process persistence에는 다음 필드가 추가된다.

- `loss_marker_fallback_write_failed_records`
- `last_loss_marker_fallback_error`

유효 fallback과 깨진 primary가 같이 있으면 status는 `known_incomplete`, source는
`runtime_state_fallback`, invalid source 목록은 `["bulk_data"]`다. 유효 marker가 하나도 없고
깨진 source만 있으면 `invalid_marker`다. 두 marker가 모두 없으면 계속 `unknown`이다. absence를
`complete`로 바꾸지 않는다.

## exact runtime identity

- base head: `b0b5968f3142a0f803b9bf37e053c33a8a140eb8`
- product head: `3aa69fb34f8f1d25e5c58d0c0b37350fac201d74`
- Linux/arm64 image:
  `sha256:5eb0eb6ac4abfa1f7715abf981d1e9fb15be36db04f38bd0fba4be6e1116b78a`
- binary SHA-256:
  `abf9ed595928e4fa2069e2af89f09a0d86a9654f453e522bbfe60c06da2f2af7`
- preflight helper SHA-256:
  `4043b7ce8a24d8619e271b927b08c6b75df9d417cf9bf212815327d388a04c7a`
- helper와 `/health?full=1`이 모두 product head와 binary SHA를 확인했다.

## focused 검증

- `Tool_metrics_persist`: 17/17
- `Tool_unified`: 6/6
- focused `lib/masc.cma`, 두 test executable build, `@fmt`: 통과

테스트에는 primary failure 뒤 fallback write와 memory reset/hydration, 유효 fallback과 깨진
primary의 동시 노출, primary/fallback 이중 write failure가 포함된다.

## r119: r118 반례 뒤집기

producer runtime은 `01a0556d-99cf-7000-af2c-6119f1bc3672`였다. `/app/data`와 기존
`/app/data/tool-metrics`를 mode 0555로 바꾼 뒤 actual MCP tool call 4,097건을 실행했다.

- server completion log 4,097, aggregate 4,097
- queue 4,096, drop 1, pending 0, final JSONL 0
- pending spool failure 4,096
- primary marker failure 1, fallback marker failure 0
- integrity `known_incomplete`, source `runtime_state_fallback`
- fallback marker mode 0600, 166 bytes, SHA-256
  `9a4cc7f8bd64b451b77f2c1974cbb50d37eed86c1989c747538775696ef72698`
- CPU snapshot 1.49%, memory 148.6 MiB

producer를 `SIGKILL`로 종료했다. exit는 137, OOM은 false였다. data permission만 복구한
replacement runtime은 `01a05570-47e5-7000-acbf-014a5b00c42b`였다.

- aggregate 0, pending 0, final JSONL 0
- current-process queue/drop/spool/marker failure counter는 모두 0
- integrity `known_incomplete`, source `runtime_state_fallback`
- loss origin runtime은 producer ID를 유지
- replacement graceful exit 0, OOM false

즉 보존할 metric row가 하나도 없는 가장 불리한 restart에서도 손실 사실은 남았다.

## actual response와 latency 반복

r121과 r122는 각각 새 named volume을 사용했다. 두 run 모두 256-way actual MCP call
4,097/4,097이 HTTP 200과 body `isError=false`를 반환했다. 두 run 모두 queue 4,096/drop 1,
primary failure 1/fallback failure 0, source `runtime_state_fallback`이었다.

| run | elapsed | throughput | mean | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|
| r118 no fallback | 9.742431s | 420.532/s | 540.072ms | 2,425.904ms | 3,969.142ms | 8,073.702ms |
| r121 fallback | 12.667251s | 323.432/s | 727.307ms | 3,114.471ms | 5,133.335ms | 11,292.471ms |
| r122 fallback | 13.079222s | 313.245/s | 743.452ms | 3,055.611ms | 5,084.280ms | 9,783.551ms |

두 새 표본은 서로 가깝고 r118 한 표본보다 느렸다. 그러나 fallback I/O는 4,097번째 call에서
marker 한 개를 쓸 때만 발생한다. 로컬 머신 부하와 run order를 통제하지 않았으므로 이 차이를
fallback의 인과 효과나 배포 latency 상한으로 해석하지 않는다.

## r124: fallback 자체가 실패하는 경계

`/app/data`는 mode 0555로 막고 fallback target만 디렉터리로 만들었다. 나머지 `.masc`는
writable로 유지했다.

- actual MCP HTTP/body success 4,097/4,097
- aggregate 4,097, queue 4,096, drop 1
- primary marker failure 1, fallback marker failure 1
- pre-kill integrity `unknown`; 두 last error가 각 target을 직접 가리킴
- `SIGKILL` exit 137/OOM false 뒤 replacement는 fallback target을
  `invalid_loss_marker_sources=["runtime_state_fallback"]`, status `invalid_marker`로 반환
- replacement graceful exit 0/OOM false

fallback까지 쓸 수 없으면 restart-safe loss evidence를 보장하지 않는다. 대신 현재 process는 두
write failure를 따로 노출하고, restart 뒤 unreadable/corrupt target을 absence와 구분한다.

## 폐기한 측정

- session header 없이 보낸 4,097건은 전부 HTTP 400이고 aggregate 0이었다. 제품 측정에서 제외했다.
- 다음 유효 run은 xargs index가 응답 파일 하나를 덮어써 response별 latency가 사라졌다. restart
  판정에는 사용했지만 HTTP/latency 표에는 넣지 않았다.
- r120은 xargs의 `%` 치환자가 curl의 `%{http_code}`와 `%{time_total}`까지 바꿨다. body success와
  product snapshot은 유효했지만 latency 값은 폐기했다.
- r123은 `.masc` 전체를 mode 0555로 바꿔 audit write까지 막았다. marker counter 판정 외에는
  fallback-only 실험으로 사용하지 않았다.

## 판정 경계

- fallback은 exact lost row count가 아니라 retention 안에서 최소 한 번 queue-full loss가 있었다는
  증거다.
- host power loss, fsync durability, network filesystem, Kubernetes/PVC, multi-process writer는
  확인하지 않았다.
- 전체 테스트와 GitHub CI는 실행하거나 통과했다고 주장하지 않는다.
- `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지 않았다.

[Hada topic 33015](https://news.hada.io/topic?id=33015)의 stale-context 원칙에 맞춰 bulk aggregate와
그 aggregate가 불완전하다는 counterevidence의 failure domain을 분리했다. marker source와 invalid
source도 같이 노출해 fallback이 있었다는 사실만으로 primary 상태를 숨기지 않는다.

## 근거

- [근거] exact product/image/binary/helper, focused 17/17 및 6/6, r119 SIGKILL replacement,
  r121/r122 actual MCP response와 latency, r124 fallback-target failure를
  2026-08-31T10:37:05+09:00 확인, 신뢰도 High.
- [근거] r118 한 표본과 r121/r122 두 로컬 Linux/arm64 표본의 latency 비교를
  2026-08-31T10:37:05+09:00 확인, 신뢰도 Medium. run order와 host load는 통제하지 않았다.
