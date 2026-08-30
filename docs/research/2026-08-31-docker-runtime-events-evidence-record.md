# Docker Runtime_events 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T04:28:14+09:00
- 작성자: Codex
- 결정 ID: docker-runtime-events-dir-r79
- 적용 대상: MASC Dockerfiles와 container entrypoints
- 결정 상태: 확정

## 근거

- 항목: Docker runtime-events ring file은 writable volume의 전용 directory에 두고, shared BasePath lease와 container-local PID lock의 경계를 보존한다.
- 출처: OCaml 5.5 Runtime_events 공식 API/runtime tracing manual, issue #31998, r70 반례, r74 shared-PID 반례, r79 Linux artifacts
- 확인일시: 2026-08-31T04:28:14+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop local volume과 one-click measurement composition에서 확인했다.

## 검증

- 1차: 공식 문서에서 working-directory default, `OCAML_RUNTIME_EVENTS_DIR` override, normal-exit cleanup 계약을 확인했다.
- 2차: rebased product HEAD의 focused build와 `test_install_script` 44 cases, `bash -n`, `ocamlformat --check`, `git diff --check`를 통과했다.
- 3차: r70에서 root-owned working directory의 exit 134를 재현했다. r71-r73은 runtime-events 동작을 보였지만 폐기된 shared-PID base이므로 preliminary evidence로 강등했다.
- 4차: r77은 event 하나를 두 줄로 기록한 뒤 line count를 file count로 사용한 harness 오류로 최종 assertion이 실패했다. artifact를 보존하고 acceptance evidence에서 제외했다.
- 5차: r78 통과 뒤 base evidence JSONL 수정으로 stacked identity가 바뀌어 결과를 supersede했다. 새 product/measurement identity의 r79 fresh shared volume에서 12/12 unique runtime/current-ready를 다시 확인했다.
- 재현 결과: r79의 11회 SIGKILL 뒤 ring 1개가 남고 다음 ready에서 정확히 1개의 새 ring으로 교체됐다. 동일 event filename 재사용 7회 모두 이전/새 ring SHA-256이 달랐고, 다른 filename 전환 4회는 stale cleanup log가 있었다. 마지막 clean exit 뒤 ring은 0개였다. same-volume contender는 exit 1, token hash 불변이었고 shared PID file과 잘못된 takeover log는 0건이었다.

## 불확실성

- 미확인 항목: 최종 product head의 release artifact image, GitHub published artifact, Kubernetes RWX volume, multi-host filesystem lock.
- 영향: release build flag나 volume driver가 local one-click measurement composition과 다르면 결과가 달라질 수 있다.
- 추가 확인 필요: 다음 published release artifact와 실제 배포 volume driver에서 같은 12회 restart scenario를 다시 잰다.

## 적용범위

- 영향 받는 영역: Docker HTTP/stdio server의 OCaml Runtime_events ring 위치와 entrypoint directory 준비.
- 제약/배제: host-native runtime-events 기본 경로, tracing enable/disable 정책, BasePath lease 경로와 PID lock 경계를 바꾸지 않는다.
- 롤백 조건: ring이 전용 directory 밖에 생기거나, 정상 Docker runtime이 directory owner/mode 때문에 시작하지 못하거나, SIGKILL 후계가 이전 ring을 current ring으로 재사용하면 변경을 중단한다.
