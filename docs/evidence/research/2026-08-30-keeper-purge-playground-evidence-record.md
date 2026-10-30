# Keeper purge playground 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T15:08:10+09:00`
- 작성자: `Codex`
- 결정 ID: `keeper-purge-playground-linux-r1`
- 적용 대상: dashboard Keeper purge의 backend playground artifact cleanup
- 결정 상태: `추적 필요`

## 근거

- 항목: Keeper purge는 같은 이름의 모든 backend playground root를 제거해야
  same-name successor가 과거 workspace를 false context로 읽지 않는다.
- 출처: exact Git-context image build, binary `build-commit`, `/health`,
  `sha256sum`, Linux named volume, dashboard purge response/log/post-state,
  Qwen chat/metrics/last-prompt
- 확인일시: `2026-08-30T15:08:10+09:00`
- 신뢰도: `High`
- 제한조건: 128자 ASCII portable Keeper name과 Local playground에서 실제 turn을
  측정했다. Docker/microVM roots는 같은 typed plan의 integration fixture와
  runtime post-state로 검증했다.
- Delta: `Keeper_playground_bundles_artifact`가 모든 sandbox profile root를
  idempotent하게 제거하고 unrelated playground는 보존한다.

## 검증

- 1차: baseline exact Linux image에서 purge 202 뒤 playground가 남고, 재시작한
  same-name Qwen turn이 `RECREATE_CONTENT:mode=current-linux-r1`을 반환했다.
- 2차: focused build와 heartbeat purge integration case 1/1이 통과했다.
- 3차: fixed exact Linux image에서 purge 202 뒤 core artifact와 세 distinct
  playground root가 모두 absent였다.
- 재현 결과: 서버 재시작 뒤 fresh Qwen operation은 `Succeeded`, 최종 응답
  `RECREATE_ABSENT`, dynamic context 0 bytes, stale match 0이었다.

## 불확실성

- 미확인 항목: remote SSH endpoint의 원격 filesystem data 삭제는 이 host-side
  bundle artifact 범위가 아니다.
- 영향: remote endpoint 자체에 남은 workspace는 별도 remote lifecycle 계약이
  필요하다.
- 추가 확인 필요: #31926 same-process SQLite handle과 #31927 one-click sandbox
  CLI teardown warning을 각각 닫아야 한다.

## 적용범위

- 영향 받는 영역: dashboard Keeper purge completion artifact plan.
- 제약/배제: plain-agent purge, 일반 operator stop, remote endpoint data,
  deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: unrelated playground가 삭제되거나, artifact removal 실패가 완료로
  표시되거나, same-name successor가 purge 전 파일을 다시 읽으면 롤백한다.
