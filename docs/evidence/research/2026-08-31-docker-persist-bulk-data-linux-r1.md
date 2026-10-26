# Docker bulk data container-replacement persistence Linux R1

## 결과

기존 Docker packaging은 `.masc`만 named volume에 연결했다. RFC-0121 bulk tool data는 sibling
`/app/data`에 기록되므로 process restart는 버텨도 container replacement에서는 보존 계약이 없었다.

변경은 production/one-click Dockerfile이 `/app/.masc`와 `/app/data`를 모두 volume으로 선언하고,
compose가 서비스별 named data volume을 `/app/data`에 연결한다. one-click image는 volume mount가
appuser 소유로 초기화되도록 선언 전에 `/app/data`를 명시적으로 만든다.

r83 production pre-final proof에서 첫 container의 실제 MCP `masc_config` call이 tool-metrics JSONL
1 row를 만들고 clean shutdown에서 flush됐다. replacement container는 새 call 전에 동일 bytes와
1 row를 읽었고 `/api/v1/tool-metrics`로 조회한 뒤 두 번째 call에서 2 rows로 늘렸다.

r84는 첫 one-click 시도를 반증했다. `/app/data`를 image layer에 만들지 않은 채 VOLUME만 선언해
named volume root가 UID/GID 0:0이 됐고 startup이 tool-metrics permission error로 degraded였다.
이 결과를 폐기하고 directory producer를 추가했다.

최종 head에서 r85 one-click과 r86 production을 각각 container replacement했다. 두 surface 모두
서로 다른 두 runtime이 startup ready/auth ok/clean exit 0이었다. 첫 call 뒤 1 row, replacement의
새 call 전 동일 1 row, 두 번째 call 뒤 2 rows였다. 그러나 replacement의
`/api/v1/tool-metrics`는 HTTP 200이면서 `total_calls=0`이었다. Disk JSONL은 보존됐지만 현재
dashboard API가 restart 시 이를 hydrate하지 않는다는 별도 반례다.

## 변경

- production/one-click Dockerfile:
  `VOLUME ["/app/.masc", "/app/data"]`
- one-click final stage: VOLUME 선언 전에 `/app/data` 생성 및 appuser chown
- compose production: `masc-data:/app/data`
- compose one-click: `masc-oneclick-data:/app/data`
- named volume declarations: `masc-data`, `masc-oneclick-data`
- install contract test가 두 image 선언, one-click producer, compose mounts/declarations를 고정

## r83: production pre-final replacement

- product head: `a895984f6861001d697424945afcf249543136e0`
- image: `sha256:7f2273de44f03e63a7d6b2de9609fda05d4a6fcb646928e9d44cfc1b65cee979`
- runtime A: `01a05442-1a35-7000-8e92-c5e824529392`
- runtime B: `01a05442-273f-7000-b82e-947dbc11d687`
- both startup ready/auth ok/clean exit 0
- rows: A stop 뒤 1, B call 전 동일 bytes 1, B stop 뒤 2
- B `/api/v1/tool-metrics`: HTTP 200, `total_calls=0`; persisted JSONL hydrate 없음

이후 one-click owner fix로 product head가 바뀌었으므로 production surface도 r86에서 갱신했다.

## r84: one-click volume-owner 반례

- product head: `a895984f6861001d697424945afcf249543136e0`
- measurement head: `a3a69dfd18281bb0b3dcb3b5403e654470bc79d7`
- image: `sha256:15c18e6eb52d4c0ef6f78dd166c34103193ee4bd9f54145cd78f3b29c9c952c8`
- runtime: `01a05444-2cc2-7000-9aef-4e53f897391b`
- mounted `/app/data`: mode 755, UID/GID 0:0
- startup degraded: permission denied creating `/app/data/tool-metrics`
- clean exit 0/OOM false

Docker VOLUME 선언만으로 image의 `/app` chown이 새 mount root에 전달된다고 가정한 것이 잘못이었다.
one-click image layer에 `/app/data`가 존재하지 않았으므로 named volume은 root-owned로 초기화됐다.

## r85: final one-click replacement

- product head: `ac42f63a2b659f3b3f6f0be85576f03643d1516f`
- measurement head: `f3d7778960c5c25706578a946fbf29f7ba997eb3`
- image: `sha256:3877e8a3077df779bea9b5f5ae6b2056cf3bdbd3b1f60ba7422a0d4ea2d5faca`
- runtime A: `01a0544a-488e-7000-818e-cd580b42cab4`
- runtime B: `01a0544a-5b68-7000-a219-c82c4b92e1d3`
- both startup ready/auth ok/clean exit 0
- rows: 1 → replacement call 전 identical 1 → 2
- replacement API: reachable, `total_calls=0`; persisted JSONL hydrate 없음
- image declared volumes: `/app/.masc`, `/app/data`

measurement head는 product head에 이미 main에 병합된 one-click build fix 3개만 더한 합성본이다.
제품 기능 코드는 product head와 같다.

## r86: final production replacement

- product head: `ac42f63a2b659f3b3f6f0be85576f03643d1516f`
- image: `sha256:d2a661879b8003d11c257c37aa52bfb13fbd82fe2704c28f6713decf328e0863`
- runtime A: `01a0544b-712e-7000-8c53-64734256f524`
- runtime B: `01a0544b-7ded-7000-b041-fb93918a3f7b`
- both startup ready/auth ok/clean exit 0
- rows: 1 → replacement call 전 identical 1 → 2
- replacement API: reachable, `total_calls=0`; persisted JSONL hydrate 없음
- both containers mounted the same named `state` and `data` volumes read-write
- image declared volumes: `/app/.masc`, `/app/data`

실제 JSONL row의 `tool_name`은 `masc_config`였다. marker file이 아니라 MASC producer, shutdown
flush, 다음 runtime의 byte-identical disk read까지 연결했다. HTTP consumer는 persisted file을
반영하지 않아 별도 문제로 분리한다.

## 검증과 경계

- focused build: `main_eio`, `test_install_script`
- `test_install_script`: 44/44 pass
- `docker compose config --quiet`, `ocamlformat --check`, `git diff --check`: pass
- JSON/JSONL parse, secret-string scan, SHA-256 manifest, evidence-record strict validation을 수행한다.
- Linux/arm64 Docker Desktop local named volumes에서 측정했다.
- plain `docker run --rm`이 자동 생성한 anonymous `/app/data` volume을 자동 재연결해주지는 않는다.
  replacement persistence는 compose named volume 또는 사용자가 동일 volume을 다시 mount할 때 성립한다.
- 기존 배포가 이미 container writable layer에 쓴 `/app/data`를 자동 migration하지 않는다.
- `/api/v1/tool-metrics`는 persisted JSONL을 hydrate하지 않는다. 이 PR은 storage retention만
  증명하며 dashboard/runtime aggregate continuity를 주장하지 않는다. 별도 issue
  [#32005](https://github.com/jeong-sik/masc/issues/32005)에 기록했다.
- GitHub published artifact, Kubernetes PVC/RWX, multi-host filesystem은 측정 범위 밖이다.
- full suite와 CI는 실행하거나 통과했다고 주장하지 않는다.

## 근거

- [근거] r83-r86 source/image/runtime/mount identity, MCP producer calls, shutdown-flushed JSONL,
  byte-identical replacement disk read, HTTP consumer zero-count counterexample, Docker/compose volume
  contracts, 2026-08-31T05:15:05+09:00 확인, 신뢰도 High.
