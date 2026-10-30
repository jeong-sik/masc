# One-click OTLP late recovery Linux runtime R2

## 결과

R1과 같은 exact image를 collector DNS가 없는 격리 Docker network에서 시작했다.
listener와 dashboard loop는 즉시 시작했고, OTLP는 5회 retry 뒤 recovery mode로
들어갔다. 그 뒤 synthetic collector를 network에 붙이자 다음 30초 probe에서
exporter가 active로 전환됐고 실제 OTLP metrics와 trace POST가 도착했다.

collector가 살아 있는 상태로 MASC container를 실제 restart했을 때도 listener,
dashboard wiring, exporter setup이 수 ms 안에 완료됐다. background scheduling은
collector 부재 retry뿐 아니라 late recovery와 immediate-success 경로도 보존했다.

## exact identity

- source change commit: `10e994faa6fe332c5e2902a09119685309dee879`
- Linux measurement composition/embedded commit:
  `5f5b3086349ba5c3206dc473beba50af4c377717`
- Linux/arm64 image digest:
  `sha256:0ca5b40b770641023cab274980f4f0d5effef0eba3c2a44aea7859de995d4ce2`
- binary SHA-256:
  `adfaca2806c57fafcfb13a201fd692feac01998f84f8f2abbb0d2346b4d8200f`
- late-recovery runtime instance: `01a051d8-d31a-7000-93e4-c8f718943af4`
- restarted runtime instance: `01a051db-23d1-7000-b6c2-d73b8d3afd92`
- synthetic collector image digest:
  `sha256:d09d15e60962ca365d1cd544a48773bac9d33f2fb1b00f2aa0deec78ade7dc31`
- endpoint: `http://otel-late-collector-r16:4318`

## late-start 타임라인

- recovery mode 진입: `2026-08-30T08:46:31.035236970Z`
- collector running 관측: `2026-08-30T08:46:45.954458000Z`
- exporter started: `2026-08-30T08:47:01.048060554Z`
- collector running부터 exporter start까지: `15.093603s`
- recovery mode 진입부터 exporter start까지: `30.012824s`

health는 `otel.status=ok`, `exporter_active=true`, `exporter_degraded=false`,
`consecutive_failures=0`으로 전환됐다. synthetic collector는 최종적으로
`/v1/metrics` 41건과 `/v1/traces` 1건을 받았다. trace body는 849 bytes였다.

## restart 타임라인

- listener: `2026-08-30T08:48:31.578827804Z`
- dashboard execution loop: `2026-08-30T08:48:31.579311262Z`
- exporter started: `2026-08-30T08:48:31.583002679Z`
- listener에서 dashboard loop까지: `0.483458ms`
- dashboard loop에서 exporter start까지: `3.691417ms`

restart health는 새 runtime instance와 같은 embedded commit/binary hash를
보고했고, startup은 `serving/ready`, OTLP는 active였다. restart 뒤에도 metrics
POST가 이어졌다.

## adversarial 경계

외부 MCP endpoint에 공개되지 않은 `keeper_tasks_list`를 이름으로 직접 호출하자
typed workflow rejection이 반환됐다. 이어진 `tools/list`는 public tool 39개만
광고했고 keeper-internal tool은 0개였다. 따라서 이는 광고 후 거절되는
false-context loop가 아니라 undisclosed tool을 fail-closed한 정상 동작이다.

## 종료 상태

MASC container는 graceful shutdown으로 exit 0이었다. synthetic Python collector는
SIGTERM handler가 없어 Docker stop timeout 뒤 exit 137이었으며 MASC 제품 실패가
아니다. 두 container, MASC volume, 격리 network는 정지·보존했다. deployed
`/Users/dancer/me/.masc`는 바꾸지 않았다.

## 남은 경계

synthetic collector는 OTLP protobuf를 decode하지 않고 HTTP 200으로 수신만 했다.
따라서 payload semantic validity와 실제 observability backend 반영은 주장하지
않는다. 이번 R2의 계약은 late endpoint discovery, exporter activation, HTTP
transport, restart continuity다.

## 근거

- [근거] exact-head r15 image, Docker network/container inspect, fresh/restart
  `/health?full=1`, nanosecond server logs, synthetic collector request logs,
  2026-08-30T17:49:26+09:00 확인, 신뢰도 High.
