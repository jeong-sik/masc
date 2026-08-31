# Tool metrics loss marker Linux R1

## 결과

`/api/v1/tool-metrics.aggregate_integrity`가 aggregate의 손실 증거를 별도 current-format으로
반환한다. marker가 없다고 complete를 추정하지 않고 `unknown`, retention 안의 유효 queue-full
marker는 `known_incomplete`, 손상된 marker는 `invalid_marker`다.

r116에서 final JSONL만 permission-denied로 막고 actual MCP call 5,000건을 보냈다. 응답은 HTTP
200/body `isError=false` 5,000/5,000이었다. 기존 bounded contract대로 aggregate 5,000,
pending/queue 4,096, explicit drop 904였고, 새 marker는 원래 process identity와 drop 시각을 mode
0600 파일로 남겼다.

`SIGKILL` 뒤 replacement는 pending 4,096을 final JSONL로 복구했다. current-process drop counter는
0으로 재시작했지만 aggregate integrity는 원래 runtime ID를 가리키는 `known_incomplete`를 유지했다.
따라서 pre-kill snapshot이 없어도 aggregate 4,096이 완전한 history라고 오인하지 않는다.

## 현재 형식

`aggregate_integrity.schema = masc.tool_metrics.aggregate_integrity.v1`,
`scope = retention_window`다.

- `status`: `unknown | known_incomplete | invalid_marker`
- `retention_days`: hydration과 같은 현재 retention
- `loss_reason`: 현재는 `queue_full`
- `loss_observed_at_unix`
- `loss_runtime_instance_id`

absence를 `complete`로 바꾸는 alias나 fallback은 없다. marker가 retention 밖이면 `unknown`으로
돌아가며, invalid JSON/current schema mismatch는 `invalid_marker`로 분리된다. marker write failure는
current-process persistence snapshot의 `loss_marker_write_failed_records`와
`last_loss_marker_error`에 남는다.

## exact runtime identity

- base head: `c7c4e56ef72ede3c51bc64a40bc78280013077e1`
- final product head: `ecba6acffb72f66f245c7ee6466883e691aecbf1`
- final image: `sha256:68256617aa7bdea424b1631458a734ca8e150904b300c4516470c892b01c5976`
- final binary: `bd61f90c...a089`, preflight helper: `ca741494...4b0e`
- marker-success head/image: `9978e056...a101e` /
  `sha256:e73fda83aef5a9b9c6d2088a00e4575a41610e2188c8dc19127c82a28eb2d70a`

## r116 marker-success runtime

- initial API: aggregate 0, integrity `unknown`, missing loss fields JSON `null`.
- saturated API: aggregate 5,000, queue/pending 4,096, drop 904, final 0,
  marker write failure 0, integrity `known_incomplete`.
- marker: reason `queue_full`, origin runtime `01a05533-...`, 166 bytes, mode 0600.
- kill: exit 137, OOM false.
- replacement: new runtime `01a05535-...`, recovered/flushed 4,096, current drop 0,
  integrity `known_incomplete`, origin runtime unchanged, final SHA-256 `68b799d6...e1f48`.
- marker를 의도적으로 corrupt한 다음 restart: hydration `invalid loss marker=true`, aggregate 4,096,
  integrity `invalid_marker`, loss fields `null`, exit 0/OOM false.

## r117 marker read-failure 격리

self-review에서 marker path가 디렉터리이거나 unreadable하면 marker read 예외가 전체 hydration을
중단해 pending recovery까지 막을 수 있는 결합을 발견했다. final head는 marker read의
`Sys_error`/`Unix_error`만 `invalid_marker`로 격리하고 cancellation은 계속 전파한다.

실제 Linux에서 marker target을 디렉터리로 만들고 final JSONL도 permission-denied로 막았다.

- actual MCP HTTP/body success 5,000/5,000, 12.574112초(397.642/s)
- aggregate 5,000, queue/pending 4,096, drop 904, marker write failure 904, final 0
- marker를 쓸 수 없으므로 pre-kill integrity는 `unknown`; last marker error는 target directory를
  직접 명시했다.
- `SIGKILL` exit 137/OOM false 뒤 unreadable marker directory를 그대로 유지하고 final storage만
  복구했다.
- replacement는 hydration을 중단하지 않고 `invalid loss marker=true`, recovered/final 4,096,
  pending 0, integrity `invalid_marker`를 반환했다. final SHA-256은 `2c9faf58...064b0`이다.
- replacement는 graceful exit 0/OOM false였다.

## saturation 비용

같은 256-way/5,000-call 조건의 parent r114와 비교했다.

| image | elapsed | throughput | mean | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|
| marker 없음 r114 | 10.923281s | 457.738/s | 507.809ms | 2,192.432ms | 3,790.646ms | 8,658.102ms |
| loss marker r116 | 12.529526s | 399.057/s | 584.025ms | 2,492.025ms | 3,832.421ms | 8,325.064ms |

단일 로컬 표본에서 marker head의 saturation throughput은 12.8% 낮고 p95는 299.593ms 높았다.
marker I/O는 queue-full 경로에서만 발생하고 정상 4,096 이내 enqueue 경로는 바꾸지 않는다. 이
비교는 단일 실행이라 배포 상한으로 일반화하지 않으며, 성능 비용을 0이라고 주장하지 않는다.

## 판정 경계

- marker는 “retention 범위 안에서 최소 한 번 알려진 손실”만 증언한다. exact lifetime drop count가
  아니다.
- marker write 자체가 실패하면 restart 뒤 손실 증거를 보장하지 못한다. current process의 failure
  counter만 증언한다.
- host power loss, network filesystem, Kubernetes/PVC, multi-process writer는 확인하지 않았다.
- 전체 테스트와 GitHub CI는 실행하거나 통과했다고 주장하지 않는다.
- `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지 않았다.

[Hada topic 33015](https://news.hada.io/topic?id=33015)의 stale-context 원칙에 맞춰 aggregate 값만
보존하지 않고 그 값이 불완전하다는 durable counterevidence를 함께 노출한다. marker absence도
complete로 승격하지 않는다.

## 근거

- [근거] exact product/image/binary/helper, focused 15/15 및 6/6, 5,000 actual MCP body,
  queue/drop/marker, SIGKILL replacement, origin runtime identity, invalid-marker restart를
  2026-08-31T09:33:33+09:00 확인, 신뢰도 High.
- [근거] 같은 local Linux/arm64 256-way parent/new 단일 run latency를
  2026-08-31T09:26:25+09:00 비교, 신뢰도 Medium.
