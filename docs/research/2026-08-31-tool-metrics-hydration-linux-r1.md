# Tool metrics 재시작 복구 Linux R1

## 결과

`/api/v1/tool-metrics`가 컨테이너 교체 뒤에도 보존된 호출 수와 지연 시간을 보여준다.
서버는 observer를 등록하기 전에 현재 보존 기간의 `data/tool-metrics` JSONL을 시간순으로 읽는다.
읽기가 끝난 뒤에만 `Tool_metrics` 스냅샷을 한 번에 바꾼다. JSON 문법이 깨졌거나 현재 형식과
맞지 않는 행은 개수를 기록하고 건너뛴다. 읽기 자체가 실패하면 기존 스냅샷을 유지한다.

대시보드 요약도 같은 `Tool_metrics` 스냅샷에서 총합, 도구 수, 상위 도구, 지연 시간을 계산한다.
이전에는 총합과 상위 도구는 `Tool_registry`, 지연 시간은 `Tool_metrics`에서 읽었다. 서로 다른
메모리 저장소를 섞은 탓에 JSONL 복구 로그가 성공해도 API는 0을 반환했다.

## 반증과 수정

- r87: 자동 발급 credential을 Bearer로 재사용할 수 있다고 잘못 가정했다. MCP 요청은 HTTP 401로
  끝났고 `total_calls=0`이었다. 이 측정은 폐기했다.
- r88: 첫 구현은 B 시작 로그에서 `hydrated 1`을 보였지만 API를 두 번 읽어도 0이었다. 파일은
  1행 그대로였다. 이 반례로 API의 총합 원천이 `Tool_registry`라는 두 번째 상태를 찾았다.
- r89: API가 집계 전체를 `Tool_metrics`에서 읽도록 바꾼 뒤 A→B→C 교체를 새 이미지와 새
  볼륨으로 다시 측정했다.

이 과정은 모델이 이미 선택한 설명에 매달리지 않고 실제 consumer까지 거꾸로 확인하라는
[Lemmalog](https://pwning.systems/posts/llm-memory-program-analysis/)의 핵심을 적용했다. 오래된 문맥이
새 판단을 오염시키는 문제는 [STALE](https://arxiv.org/abs/2605.06527)과
[Supersede](https://arxiv.org/abs/2606.27472)가 다루는 실패 유형과도 맞닿아 있다. 여기서는 성공 로그를
정답으로 취급하지 않고 API의 실제 반환값으로 반증했다.

## r89 Linux/arm64 컨테이너 교체

- product head: `4dd5fc316520460f5f52795bced68b552744da28`
- image: `sha256:0ea91a347442b5b8399a379906b5db65b1d93f7b3dae34e3b7f1c81ea00315b4`
- binary: `e494ec0eaaa4bc36739505b6e92c122f599968436dc558535b79ab8a596cd6d3`
- runtime A: `01a05466-8b32-7000-89af-4f54168add74`
- runtime B: `01a05467-5693-7000-9991-0ea079eb28e7`
- runtime C: `01a05468-0279-7000-a10f-e1032fd86561`
- 세 컨테이너 모두 같은 named state/data volume을 읽기-쓰기로 연결했다.
- 세 컨테이너 모두 exit 0, OOM false로 정상 종료했다.

관측 순서:

1. A 시작: `hydrated 0`, API 0.
2. A에서 실제 `masc_config` 1회: HTTP 200, `isError=false`, API 두 번 모두 1.
3. A 종료: JSONL 1행, SHA-256 `581f8e7b...d4761`.
4. B 시작: `hydrated 1`, 새 호출 전 API 두 번 모두 1.
5. B에서 실제 `masc_config` 1회: API 두 번 모두 2.
6. B 종료: JSONL 2행, SHA-256 `ec128863...e69ac`.
7. C 시작: `hydrated 2`, 새 호출 없이 API 두 번 모두 2.
8. C 종료: JSONL은 2행과 같은 SHA-256을 유지했다.

## 로컬 검증

- `test_tool_metrics`: 8/8 통과.
- `test_tool_metrics_persist`: 5/5 통과.
- `test_tool_unified`: 6/6 통과.
- focused `main_eio` build 통과.
- Linux builder에서 `main_eio`와 deployment preflight helper를 새로 컴파일했다.
- `ocamlformat --check`, `git diff --check`, JSON/JSONL parse를 확인한다.
- 전체 테스트와 GitHub CI는 이 로컬 결과에 포함하지 않는다.

## r90/r91 크기 측정

같은 image와 빈 named volume에서 기준값을 잰 뒤 100,000행과 1,000,000행을 넣었다. 각 파일에는
정상 행 외에 깨진 JSON과 현재 형식에 맞지 않는 행을 0.1%씩 추가했다. 컨테이너 시작 시각은
`docker inspect .State.StartedAt`, 완료 시각은 `docker logs --timestamps`의 hydration 로그를 썼다.

| 입력 | 정상/깨짐/형식 불일치 | 시작→hydration 로그 | API 응답 | 관측 메모리 | 결과 |
|---|---:|---:|---:|---:|---|
| 빈 저장소 | 0/0/0 | 0.800s | 총합 0 | 78.22MiB | 통과 |
| 8.90MB | 100,000/100/100 | 0.864s, 재시작 0.881s | 20.6–25.0ms | 81.45–82.95MiB | 통과 |
| 89.0MB | 1,000,000/1,000/1,000 | 1.846s, 재시작 1.898s | 186–206ms | 116.0–131.6MiB | 통과 |

두 크기 모두 API 총합과 `p50=51`, `p95=95`, `p99=99`가 입력과 맞았다. 재시작 뒤에도 같은
총합을 반환했고 모든 컨테이너가 exit 0/OOM false였다. 1,000,000행은 이번 측정의 상한일 뿐
제품의 최대 허용치가 아니다. 여러 도구로 넓게 퍼진 분포와 1,000,000행 초과는 아직 측정하지 않았다.

## r92 동시 요청 반례

1,000,000행 상태와 빈 상태에 각각 16개 GET을 동시에 보냈다. HTTP 응답 시간은 curl이 서버에서
첫 바이트부터 응답을 모두 받을 때까지 잰 값이다. `docker exec` 전체 wall time은 별도 비용을
포함하므로 판정에 쓰지 않았다.

- 빈 상태: 평균 1.2ms, 최대 4.8ms, 관측 메모리 78.68MiB.
- 1,000,000행: 최소 0.198초, 평균 1.987초, 최대 2.905초.
- 1,000,000행 처리 중 관측 최고치는 CPU 100.58%, 메모리 203.2MiB였다.
- 전후 API 총합은 모두 1,000,000이었다. 데이터 정확성이나 중복 문제는 없었다.
- 두 컨테이너 모두 exit 0/OOM false였다.

`Tool_metrics.compute_stats`는 요청마다 duration list를 배열로 복사하고 정렬한다. 16개 요청은 같은
백만 개 값을 반복 정렬해 뒤 요청의 지연을 키웠다. 이 PR의 재시작 정확성과는 별개로 다뤄야 하므로
후속 [#32007](https://github.com/jeong-sik/masc/issues/32007)에 기록했다.

## 경계

- 현재 JSONL 형식만 읽는다. 예전 `success` 형식 변환 코드는 추가하지 않았다.
- 보존 기간이 지난 날짜 파일은 복구 전에 삭제한다.
- JSONL은 호출 출처와 assignment ID를 저장하지 않는다. 따라서 이번 변경은 이 값을 추측해
  `Tool_registry`에 되살리지 않고, 해당 값을 쓰지 않는 대시보드 집계를 `Tool_metrics`로 통일했다.
- 읽기 실패는 경고로 남고 서버는 계속 뜬다. 일부만 읽은 스냅샷은 공개하지 않는다.
- Linux/arm64 Docker Desktop의 로컬 named volume에서 측정했다. Kubernetes, multi-host storage,
  GitHub 배포 artifact는 범위 밖이다.
- 크기·동시 요청 측정의 메모리는 `docker stats --no-stream` 표본이다. GC와 다른 시작 fiber의
  영향을 포함하므로 정밀한 heap profile로 해석하지 않는다.
- `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지 않았다.

## 근거

- [근거] `scripts/dune-local.sh build bin/main_eio.exe`, 세 focused test 실행 결과,
  image/binary SHA-256, A→B→C runtime ID, startup hydration 로그, 실제 MCP 호출, API 반복 조회,
  종료 코드, JSONL 행 수와 SHA-256, 2026-08-31T05:42:07+09:00 확인, 신뢰도 High.
- [근거] r90 100,000행과 r91 1,000,000행의 두 번 연속 Linux 시작, 정확한 skip count,
  API 응답 시간/총합/percentile, `docker stats`, exit/OOM, 입력 파일 SHA-256,
  2026-08-31T05:49:38+09:00 확인, 신뢰도 High.
- [근거] r92 동일 image의 16-way GET 비교에서 빈 상태 평균/최대 1.2/4.8ms와 1M 상태
  1.987/2.905s, CPU/메모리 표본, 전후 총합, exit/OOM을 확인,
  2026-08-31T05:53:21+09:00 확인, 신뢰도 High.
- [근거] Lemmalog, STALE, Supersede 원문을 2026-08-31에 확인, 신뢰도 High.
