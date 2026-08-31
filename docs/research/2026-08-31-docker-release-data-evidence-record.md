# Production Docker bulk data directory 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T04:52:22+09:00
- 작성자: Codex
- 결정 ID: docker-release-data-dir-r82
- 적용 대상: production Dockerfile과 install contract test
- 결정 상태: 확정

## 근거

- 항목: production image는 RFC-0121 bulk data sibling `/app/data`를 만들고 non-root appuser가 쓸 수 있게 해야 한다.
- 출처: issue #32001, r81 permission 반례, r82 production-shaped Linux artifacts, `docs/research/2026-08-31-docker-release-data-linux-r1.md`
- 확인일시: 2026-08-31T04:52:22+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop local volume과 local Linux builder의 production-shaped image에서 확인했다.

## 검증

- 1차: `Config_dir_resolver.data_dir`가 `<base_path>/data`를 반환하고 production Dockerfile만 `/app/data`를 준비하지 않는 producer-to-path 경계를 확인했다.
- 2차: production Dockerfile에 `/app/data` mkdir/chown을 추가하고 source contract test 2개를 추가했다. focused build와 `test_install_script` 44 cases를 통과했다.
- 3차: product head에서 Linux AArch64 ELF main/helper와 production image를 만들었다.
- 4차: fresh shared volume에서 4회 부팅했다. 4/4 preflight/startup ready/auth ok, `/app/data/tool-metrics` mode 755 owner 999:999를 확인했다.
- 재현 결과: 3회 SIGKILL exit 137과 마지막 clean exit 0, contender exit 124/token hash 불변, ring 교체, shared PID 0, 잘못된 takeover log 0을 확인했다.

## 불확실성

- 미확인 항목: container replacement 사이 `/app/data` persistence, GitHub published artifact, Kubernetes RWX, multi-host filesystem lock.
- 영향: 현재 declared volume은 `/app/.masc`뿐이므로 `/app/data` bulk telemetry는 container writable layer에 남는다.
- 추가 확인 필요: bulk telemetry의 intended retention contract를 결정하고 별도 volume/symlink/migration 중 하나를 독립 변경으로 검증한다.

## 적용범위

- 영향 받는 영역: production Docker image의 `/app/data` directory 생성과 소유권.
- 제약/배제: one-click image, OCaml path resolver, BasePath lease, PID lock, Runtime_events 경로는 바꾸지 않는다.
- 롤백 조건: production runtime이 startup ready에 도달하지 못하거나, `/app/data`가 appuser 소유가 아니거나, 다른 volume/runtime lock 계약이 회귀하면 변경을 중단한다.
