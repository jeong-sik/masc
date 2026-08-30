# Docker bulk data persistence 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T05:10:38+09:00
- 작성자: Codex
- 결정 ID: docker-persist-bulk-data-r86
- 적용 대상: production/one-click Dockerfiles, docker-compose, install contract test
- 결정 상태: 확정

## 근거

- 항목: Docker bulk data `/app/data`는 별도 declared/named volume으로 연결하고, image가 mount root의 appuser ownership을 생산해야 한다.
- 출처: issue #32002, r83 production replacement, r84 one-click owner 반례, r85/r86 final replacements, `docs/research/2026-08-31-docker-persist-bulk-data-linux-r1.md`
- 확인일시: 2026-08-31T05:10:38+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop local named volumes에서 확인했다.

## 검증

- 1차: RFC-0121 data path `/app/data`와 compose의 유일한 state mount `/app/.masc`가 분리된 것을 확인했다.
- 2차: 두 Dockerfile의 volume 선언과 compose의 service-specific named data volumes를 추가하고 source contract 44 cases와 compose config parse를 통과했다.
- 3차: r83 production에서 실제 `masc_config` tool metric 1 row를 shutdown flush하고 replacement가 새 call 전에 동일 bytes/API aggregate를 읽은 뒤 2 rows로 늘리는 것을 확인했다.
- 4차: r84 one-click named volume이 root-owned 0:0이 되어 startup degraded인 반례를 얻고 결과를 폐기했다. VOLUME 전 `/app/data` producer를 추가했다.
- 5차: final head r85 one-click과 r86 production에서 각각 two-container replacement를 다시 실행했다. 두 surface 모두 1 row → identical 1 row → 2 rows, unique runtime, ready/auth ok, clean exit 0이었다.
- 재현 결과: image volume metadata와 compose named mounts가 `/app/.masc` 및 `/app/data`를 함께 포함했고 실제 MASC producer/consumer data가 replacement를 통과했다.

## 불확실성

- 미확인 항목: 기존 writable-layer `/app/data` 자동 migration, anonymous volume 자동 재연결, GitHub published artifact, Kubernetes PVC/RWX, multi-host filesystem.
- 영향: 동일 named volume을 다시 mount하지 않는 plain container replacement는 기존 bulk data를 찾지 못한다.
- 추가 확인 필요: release notes에 explicit data-volume/migration contract를 문서화하고 orchestrator별 replacement smoke를 별도로 수행한다.

## 적용범위

- 영향 받는 영역: production/one-click image volume metadata와 docker-compose data mounts.
- 제약/배제: OCaml data path resolver, BasePath lease, PID lock, Runtime_events, existing data migration은 바꾸지 않는다.
- 롤백 조건: either image의 `/app/data`가 appuser-writable이 아니거나, named-volume replacement에서 producer JSONL/API read가 사라지거나, `.masc` state volume과 충돌하면 변경을 중단한다.
