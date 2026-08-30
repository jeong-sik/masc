# Shared-volume BasePath lease 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T03:31:00+09:00
- 작성자: Codex
- 결정 ID: health-shared-basepath-lease-r68
- 적용 대상: `Host_config.run_dir`, MASC Docker images, Docker entrypoints
- 결정 상태: 확정

## 근거

- 항목: 같은 `/app/.masc` volume을 쓰는 MASC Docker runtime은 하나만 BasePath를 소유해야 한다.
- 출처: r67 Linux 반례, issue #31996, r68/r69 Linux 재현, `docs/research/2026-08-31-health-scale-shared-lease-linux-r1.md`
- 확인일시: 2026-08-31T03:31:00+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop의 local volume과 one-click image에서 확인했다.

## 검증

- 1차: `Host_config`, `Server_startup_takeover`, 두 Dockerfile과 두 entrypoint의 producer-to-lock 경로를 확인했다.
- 2차: focused build, Host_config 13 cases, env snapshot 6 cases, `bash -n`, JSON/JSONL parse, SHA-256 manifest를 확인했다.
- 3차: r68과 r69의 fresh shared volume에서 첫 runtime, 거부될 두 번째 runtime, 후계 runtime을 차례로 실행했다. fresh different volume도 동시에 실행했다.
- 재현 결과: r69의 두 번째 same-volume runtime은 exit 1이고 token hash는 불변이었다. 첫 runtime과 후계, different-volume runtime은 auth ok/current-ready였고 exit 0/OOM false였다. `masc_config`도 실제 run directory와 env 출처를 반환했다.

## 불확실성

- 미확인 항목: release artifact image, Kubernetes RWX volume, 여러 Linux host를 가로지르는 filesystem lock.
- 영향: volume driver가 POSIX record lock을 공유하지 않으면 여러 host에서 배타성이 깨질 수 있다.
- 추가 확인 필요: release artifact image smoke와 실제 배포 volume driver별 lease conformance를 별도 측정한다.

## 적용범위

- 영향 받는 영역: Docker로 실행하는 HTTP/stdio server와 deployment preflight helper의 BasePath lease 경로.
- 제약/배제: host 기본값 `/tmp`와 BasePath 밖의 다른 임시 파일 경로는 바꾸지 않는다.
- 롤백 조건: 정상 단일 Docker runtime이 run directory owner/mode 검증을 통과하지 못하거나, 다른 volume끼리 충돌하면 변경을 중단한다.
