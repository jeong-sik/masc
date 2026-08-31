# Shared-volume BasePath lease 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T04:07:34+09:00
- 작성자: Codex
- 결정 ID: health-shared-basepath-lease-r76
- 적용 대상: `Host_config.base_path_lease_dir`, MASC Docker images, Docker entrypoints
- 결정 상태: 확정

## 근거

- 항목: 같은 `/app/.masc` volume을 쓰는 MASC Docker runtime은 BasePath ownership lease만 공유하고, PID lock은 각 PID namespace 안에 둬야 한다.
- 출처: r67 split-brain 반례, r74 shared-PID-lock 반례, issue #31996/#32000, r75/r76 Linux 재현, `docs/research/2026-08-31-health-scale-shared-lease-linux-r1.md`
- 확인일시: 2026-08-31T04:07:34+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop local volume과 one-click image에서 확인했다.

## 검증

- 1차: `Host_config`, `Server_startup_takeover`, HTTP/stdio server, deployment preflight helper, 두 Dockerfile과 두 entrypoint의 producer-to-lock 경로를 확인했다.
- 2차: focused build, Host_config env 7 cases, resolution 6 cases, env snapshot 6 cases, takeover 28 cases, `bash -n`, `ocamlformat --check`, `git diff --check`를 통과했다.
- 3차: r74에서 공유 PID 7이 새 PID namespace의 무관한 PID 7과 충돌해 세 번째 runtime을 exit 143으로 끝내는 것을 재현했다. r68/r69 판정을 폐기했다.
- 4차: r75 fresh shared volume에서 두 번째 runtime을 exit 1로 거부하고 token hash, 첫 runtime auth/current, successor, different-volume runtime을 확인했다. shared PID file은 0개였다.
- 5차: r76 fresh shared volume에서 11회 SIGKILL 뒤 12회 모두 unique runtime/current-ready를 확인했다. exit 137은 11개, 마지막 exit 0은 1개, OOM과 잘못된 takeover 로그는 0건이었다.
- 재현 결과: `MASC_BASE_PATH_LEASE_DIR`만 공유하고 PID lock을 `/tmp`에 두면 same-volume 배타성과 반복 재시작이 함께 유지됐다. 실제 `masc_config`도 새 lease 경로와 env 출처를 반환했다.

## 불확실성

- 미확인 항목: 최종 product head의 release artifact image, Kubernetes RWX volume, 여러 Linux host를 가로지르는 filesystem lock.
- 영향: volume driver가 POSIX record lock을 공유하지 않으면 여러 host에서 배타성이 깨질 수 있다.
- 추가 확인 필요: release artifact image smoke와 실제 배포 volume driver별 lease conformance를 별도 측정한다.

## 적용범위

- 영향 받는 영역: Docker로 실행하는 HTTP/stdio server와 deployment preflight helper의 BasePath lease 경로.
- 제약/배제: host 기본 PID/run directory와 takeover breadcrumb를 BasePath volume으로 옮기지 않는다.
- 롤백 조건: 정상 단일 Docker runtime이 lease directory owner/mode 검증을 통과하지 못하거나, 다른 volume끼리 충돌하거나, 반복 SIGKILL 뒤 새 runtime이 ready가 되지 못하면 변경을 중단한다.
