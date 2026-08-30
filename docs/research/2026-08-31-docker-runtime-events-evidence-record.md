# Docker Runtime_events 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T03:50:00+09:00
- 작성자: Codex
- 결정 ID: docker-runtime-events-dir-r71
- 적용 대상: MASC Dockerfiles와 container entrypoints
- 결정 상태: 확정

## 근거

- 항목: Docker runtime-events ring file은 writable volume의 전용 directory에 둔다.
- 출처: OCaml 5.5 Runtime_events 공식 API, issue #31998, r70/r71/r72/r73 Linux artifacts
- 확인일시: 2026-08-31T03:50:00+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop local volume과 production-shaped local image에서 확인했다.

## 검증

- 1차: 공식 API에서 working-directory default와 `OCAML_RUNTIME_EVENTS_DIR` override 계약을 확인했다.
- 2차: source contract 44 cases, `bash -n`, `ocamlformat --check`, SHA-256 manifest를 확인했다.
- 3차: r70 negative, writable override 진단, r71 production-shaped image, r72 one-click image, r73 SIGKILL recovery를 fresh volume에서 실행했다.
- 재현 결과: r70은 exit 134였다. r71/r72는 전용 directory에 ring file을 만든 뒤 current-ready/auth ok와 exit 0/OOM false를 보였다. r71의 same-volume second는 preflight에서 거부됐다. r73 후계는 crash remnant를 지우고 정상 부팅했다.

## 불확실성

- 미확인 항목: GitHub release가 게시한 실제 binary/helper artifact와 Kubernetes RWX volume.
- 영향: release build flag나 volume driver가 local production-shaped image와 다르면 결과가 달라질 수 있다.
- 추가 확인 필요: 다음 published release artifact를 동일 image final stage에 넣어 smoke를 다시 잰다.

## 적용범위

- 영향 받는 영역: Docker HTTP server의 OCaml Runtime_events ring file 위치와 entrypoint directory 준비.
- 제약/배제: host-native runtime-events 기본 경로, tracing enable/disable 정책, BasePath lease 경로는 바꾸지 않는다.
- 롤백 조건: ring file이 전용 directory 밖에 생기거나, 정상 Docker runtime이 directory owner/mode 검사 때문에 시작하지 못하면 변경을 중단한다.
