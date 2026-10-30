# Tool metrics 요약 캐시 Linux R1

## 결과

`Tool_metrics.all_stats`가 불변 통계 스냅샷을 한 번 계산한 뒤 재사용한다. 여러 HTTP 요청이 동시에
들어오면 mutex 안에서 첫 요청만 duration 배열을 만들고 정렬한다. 나머지는 같은 스냅샷을 받는다.
새 도구 결과, 시작 복구의 전체 교체, 테스트 초기화는 스냅샷을 즉시 버린다.

이 변경은 #32006의 재시작 복구 형식이나 집계 값은 바꾸지 않는다. #32007에서 확인한 요청별
반복 정렬만 없앤다.

## 결정론적 테스트

- 연속된 두 `all_stats`가 같은 불변 스냅샷을 반환한다.
- 8개 OCaml domain의 동시 조회가 같은 스냅샷을 반환한다.
- `record` 뒤에는 새 스냅샷과 증가한 호출 수를 반환한다.
- `replace_samples` 뒤에는 이전 값이 사라진 새 스냅샷을 반환한다.
- 기존 hydration, 실패 시 원자성, 대시보드 요약 테스트를 함께 실행했다.

## r93 Linux/arm64 1M 동시 요청

- product head: `71830bcd9726e1cb73978810bd392d835b742029`
- image: `sha256:b26c094ac56bd76743940d808fce3d27cf1f36539098012192ac99af0e3ced0e`
- binary: `1841aa575250dd2658ca31d674c3dfba38a5e7cb76c58224a4488fae8e0b05bd`
- 입력: 정상 1,000,000행, 깨진 JSON 1,000행, 형식 불일치 1,000행, 89,019,000 bytes.
- cold 16-way: 평균 0.190초, 최대 0.203초.
- warm 16-way: 평균 1.64ms, 최대 7.24ms.
- API 총합은 전후 모두 1,000,000이었다.
- 컨테이너는 exit 0/OOM false였다.

같은 입력과 이전 image의 r92는 평균 1.987초, 최대 2.905초였다. cold 평균은 10.5배, 최대값은
14.3배 줄었다. cold 요청 16개가 모두 약 0.18–0.20초에 끝난 것은 한 요청의 정렬 결과를 다른
요청이 기다렸다가 함께 사용했다는 동작과 맞는다. warm 결과는 빈 저장소 기준 1.2ms 평균에
근접했다.

대규모 분산 시스템에서 평균이 아닌 tail과 중복 작업을 줄여야 한다는 원칙은
[The Tail at Scale](https://www.cse.ust.hk/~weiwa/teaching/Fall15-COMP6611B/reading_list/TheTailAtScale.pdf)과
[Straggler Mitigation at Scale](https://arxiv.org/abs/1906.10664)의 문제 설정과 같다. 여기서는
추측이 아니라 동일 1M 입력의 전후 16-way HTTP 시간으로 판정했다.

## r93 실제 호출 뒤 무효화

원본 1M 볼륨을 새 볼륨으로 복제해 별도 컨테이너에서 확인했다.

1. 첫 API 조회는 0.193초, 총합 1,000,000이었다.
2. 실제 `masc_config`를 정확히 한 번 호출했다. HTTP 200, `isError=false`였다.
3. 다음 API 조회는 0.189초가 걸렸고 총합·성공 수가 1,000,001이었다.
4. 두 번째 조회는 0.395ms였고 같은 1,000,001을 반환했다.
5. 정상 종료 뒤 JSONL은 1,002,001 physical rows, 89,019,112 bytes가 됐다.

첫 조회가 다시 정렬 비용을 내면서 새 값을 반영하고, 다음 조회가 캐시를 쓴다. stale cache와
중복 집계가 모두 없었다.

## r94 쓰기·읽기 혼합 부하

캐시를 먼저 채운 뒤 실제 `masc_status` 20회(50ms 간격)와 API 조회 20회(20ms 간격)를 함께
실행했다. 첫 warm 조회는 0.582ms였다. 각 쓰기 뒤의 19개 조회는 최소 0.176초, 평균 0.189초,
최대 0.217초였다. 20개 호출은 모두 HTTP 200/`isError=false`였고 총합은 정확히
1,000,000→1,000,020으로 늘었다. 관측 최고치는 CPU 94.96%, 메모리 205.8MiB였다.

동시 reader가 같은 generation을 읽는 중복 작업은 사라졌다. 그러나 write와 read가 교차하면 새
generation마다 한 번은 전체 정렬한다. 이 PR의 작은 cache 범위를 넘는 자료구조 변경은 후속
[#32009](https://github.com/jeong-sik/masc/issues/32009)에 기록했다.

## 검증과 경계

- focused `main_eio` build 통과.
- `test_tool_metrics`: 9/9, `test_tool_metrics_persist`: 5/5, `test_tool_unified`: 6/6 통과.
- `ocamlformat --check`, `git diff --check`, JSON parse, SHA-256 manifest, 비밀 문자열 검사를 수행한다.
- 반환하는 `tool_stats`와 list는 모두 불변이다. 외부 호출자가 캐시 내용을 바꿀 수 없다.
- `stats_for`의 단일 도구 조회는 이번 변경 범위가 아니다.
- 호출이 계속 들어오는 동안에는 매 호출이 캐시를 무효화한다. API 조회 빈도와 호출 빈도가 모두
  높을 때는 r94처럼 generation마다 전체 정렬 비용이 남는다.
- 메모리와 CPU는 `docker stats --no-stream` 표본이라 정밀 profile로 해석하지 않는다.
- 전체 테스트, GitHub CI, Kubernetes/PVC, published artifact는 확인 범위 밖이다.
- `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지 않았다.

## 근거

- [근거] source/image/binary identity, 동일 1M 입력 SHA-256, r92/r93 16-way HTTP timing,
  실제 MCP 호출 뒤 cold/warm API, 종료 코드와 OOM, 2026-08-31T06:03:33+09:00 확인,
  신뢰도 High.
- [근거] The Tail at Scale과 Straggler Mitigation at Scale 원문을 2026-08-31에 확인,
  신뢰도 High.
- [근거] r94 1M retained rows에서 실제 `masc_status` 20회와 API read 20회를 교차 실행하고
  요청 시간, 정확한 총합, CPU/메모리 표본, 종료 뒤 JSONL SHA-256을 확인,
  2026-08-31T06:08:41+09:00 확인, 신뢰도 High.
