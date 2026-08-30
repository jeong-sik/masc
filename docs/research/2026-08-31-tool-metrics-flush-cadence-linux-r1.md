# Tool metrics flush cadence Linux R1

## 결과

`Tool_metrics_persist`의 기본 flush 간격을 300초에서 0.5초로 바꿨다. tool completion 경로는
기존과 같이 bounded memory queue에 넣기만 한다. 파일 I/O는 background fiber가 맡는다.
operator snapshot도 같은 기본값 상수를 읽고, 시작 로그는 `0.5s`를 정확히 표시한다.

## 반증

- r97은 기본 HTTP rate limit에서 5,000요청 중 285개만 dispatch됐다. queue 반례가 아니므로
  폐기했다.
- r98은 rate limit을 명시적으로 높이고 실제 `masc_status` 5,000회를 모두 성공시켰다.
  live API는 5,000이었지만 queue capacity 4,096 뒤 record를 버렸다.
- r98 정상 종료는 4,096행만 썼다. replacement도 `hydrated 4096`, API 4,096이었다.
  crash가 아닌 clean replacement에서 904건이 사라졌다.

## r99 설정 PoC

코드를 바꾸기 전에 같은 image에 `MASC_METRICS_FLUSH_SEC=0.5`만 설정했다. 실제 5,000회가 모두
성공했고 background fiber는 약 80행씩 주기적으로 썼다. drop 로그는 0, disk와 replacement API는
모두 5,000이었다. 이 결과로 기본값 변경을 선택했다.

## r100 최종 Linux/arm64

- product head: `64e4f705cab92d120cd47d9dbf51f771105f0f1f`
- image: `sha256:080d7c8f61614df10031d3cab54936549973d16f3585a21e4bc3b7740ce97a83`
- binary: `69b35ad527bb073857c62d21a433feee4bf5bb9df395b8d792d85b5e2d8597eb`
- `MASC_METRICS_FLUSH_SEC` override 없이 시작 로그 `interval=0.5s`.
- 실제 `masc_status` 5,000/5,000 HTTP 200, `isError=false`.
- live API 5,000, 실행 중 disk 4,976행, 다음 tick에서 마지막 24행 기록.
- queue drop 로그 0.
- 정상 종료 뒤 disk 5,000행, SHA-256 `e1f6bd59...05aa8a`.
- replacement는 `hydrated 5000`, API 5,000.
- 두 runtime 모두 exit 0/OOM false.

## r101 유휴 A/B

같은 image의 두 container에서 tool-metrics 간격만 기본 `0.5s`와 override `300s`로 달리했다.
68초 동안 process CPU는 각각 0.67초와 0.60초였다. 기본값의 관측 차이는 단일 core 기준
약 0.103%였다. 종료 RSS는 134,376KiB와 134,588KiB, write bytes 증분은 1,261,568과
1,265,664로 대조군보다 늘지 않았다. 둘 다 exit 0/OOM false였다. 이는 짧은 유휴 구간에서
뚜렷한 회귀가 없다는 결과이지 장시간·다중 노드 비용의 증명은 아니다.

## r102 폐기와 r103 bind-mount 병렬 부하

- r102는 `xargs` placeholder가 request id뿐 아니라 빈 `arguments` object까지 바꿨다.
  HTTP 200은 5,000건이었지만 handled call은 0이었다. 성공 코드만 센 증거를 폐기했다.
- r103은 placeholder를 분리하고 각 body의 `isError=false`를 검사했다. macOS bind-mounted
  `/app/data`에서 `masc_goal_list` 5,000건을 parallelism 256으로 실행했다.
- 5,000/5,000 HTTP 200 및 accepted body, live API 5,000. 9.664638초,
  평균 517.35 calls/s였다.
- 17회 periodic flush, drop 로그 0, disk 5,000행/565,263 bytes,
  SHA-256 `69ef89c4...759a`였다.
- 정상 종료 뒤 replacement는 `hydrated 5000`, API 5,000이었다. 두 runtime 모두
  exit 0/OOM false였다.

## 검증과 경계

- env snapshot/runtime default 7/7, tool metrics persist 5/5, focused `main_eio` build 통과.
- `ocamlformat --check`, `git diff --check`, JSON/SHA/secret scan을 수행한다.
- 0.5초는 단일-client 5,000회/약 31초와 256-way 5,000회/9.66초의 admitted load에서
  검증한 값이다.
- background storage가 0.5초마다 drain 속도를 따라가지 못하거나 0.5초 안에 4,096건이 몰리면
  bounded queue drop은 여전히 가능하다. call path를 막지 않는 기존 안전 조건을 유지한 결과다.
- empty queue는 파일 I/O를 하지 않지만 fiber wake-up은 초당 두 번 발생한다. r101의 짧은
  유휴 A/B에서는 300초 대조군보다 0.07 CPU초/68초 더 썼다.
- 전체 테스트, GitHub CI, 강제로 지연한 filesystem, 장시간 유휴, Kubernetes/PVC는 확인 범위 밖이다.
- `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지 않았다.

## 근거

- [근거] r98 live 5,000→disk/replacement 4,096 반례, r99 override PoC, r100 default image의
  실제 MCP 5,000회, batch flush/drop logs, disk rows/SHA, replacement API, exit/OOM을
  2026-08-31T06:41:30+09:00 확인, 신뢰도 High.
- [근거] r101 동일-image 유휴 A/B의 `/proc` CPU/RSS/context-switch/I/O 누적값과 r103의
  body-level accepted 5,000건, live/disk/replacement 5,000, SHA, exit/OOM을
  2026-08-31T06:56:11+09:00 확인, 신뢰도 High.
