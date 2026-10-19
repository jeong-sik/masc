# Report artifacts: implementation and runtime evidence

## 공통 헤더

- 날짜(ISO8601): 2026-10-19T12:33:00+09:00
- 작성자: Codex
- 결정 ID: report-artifacts-runtime-proof
- 적용 대상: Native Stack #43877 — core #43874, dashboard #43872
- 결정 상태: 확정 (아래 구현·격리 환경 검증 범위)

## 근거 (Evidence)

- 항목: Keeper 보고서를 영속 문서로 게시하고 대시보드 목록에서 다시 여는 기능.
- 출처: [native build39193931417](https://github.com/jeong-sik/masc/actions/runs/39193931417), [focused tests39194397496](https://github.com/jeong-sik/masc/actions/runs/39194397496), 아래 실제 HTTP·브라우저 실행 기록.
- 확인일시: 2026-10-19T12:33:00+09:00
- 신뢰도: High
- 제한조건: 격리 작업 공간의 실행이다. 운영 배포나 실제 모델 호출을 검증한 기록이 아니다.

서버 바이너리와 깨끗한 체크아웃에서 만든 대시보드 번들은 모두
`5e2483c8857a18c0e7e8391a8fa5f7b77b1bf748`이다. 실제 health 응답의
`binary_commit`과 `dashboard_surface.status=ok`를 검사했다.
바이너리 SHA256은
`94683d3e0b52b2e17d7ceee390d0d80f3aa60751ec3ed4e51e45f0a753a685ea`이다.

OCaml 검사 head는 `7782a9702726a92091efd7fd767a416b8a2abb23`이다.
바이너리 head와의 차이는 테스트 stanza의 직접 라이브러리 의존성 선언뿐이다.
이후 변경은 브라우저 하네스와 이 검증 기록이다. 제품 코드는 동일하다.

## 검증 (Verification)

- 1차: 설계·저장·도구·HTTP·UI의 소스를 직접 읽고 독립 적대적 리뷰를 받았다.
- 2차: 서버·TUI·browser host·preflight 실행 파일을 원격에서 빌드했다. 다운로드한 패키지의 manifest 해시, 소스 tree, 실제 바이너리 commit을 확인했다.
- 3차: 실제 서버와 production 대시보드에서 게시·조회·조작을 실행하고 서버를 종료·재시작해 반복했다. HTTP 응답 mock은 사용하지 않았다.
- 재현 결과: 아래 시나리오와 원격 OCaml69개, dashboard115개 검사가 통과했다. 검사 범위와 이월 근거는 아래와 같다.

| 요구 사항 | 직접 확인한 결과 |
|---|---|
| Keeper의 명시적 보고서 게시 | `test_published_artifact`: 실제 producer 호출, 작성자 identity, 본문 저장, 이전 버전 충돌, 도구 discovery, blob 보존 검사 7개 통과 |
| 도구 schema·registry 연결 | schema parity3개 및 descriptor registry59개 통과 — [실행 로그 발췌](focused-test-summary.txt) |
| 목록·검색·선택 | 실제 API로 두 문서를 게시한 뒤 production 대시보드의 목록 선택과 검색으로 각각 열기 |
| Markdown 보고서 | 실제 lazy renderer가 GFM 표를 렌더링함을 검사하고 [화면](desktop-markdown.png) 저장 |
| 원본·버전·다운로드 | v1 원문 SHA256 일치, v2 최신 본문 일치, v1 다운로드 바이트 해시 일치, 버전 URL reload 후 v1 유지 |
| 오래된 버전 수정 거절 | HTTP에서 오래된 expected_revision을409로 거절하고 최신 본문 보존 |
| 인터랙티브 HTML | 데스크톱 버튼1회, 모바일 버튼2회 및 결과 변경 — [데스크톱](desktop-html.png), [모바일](mobile-html.png) |
| HTML 격리 | parent document·localStorage 접근 거절, fetch 거절과 해당 connect-src CSP 위반 이벤트를 함께 확인 |
| 서버 재시작 | PID69736에 SIGTERM, exit0 확인 후 새 PID70999에서 동일 문서 ID·모든 원문 해시·화면 검사를 재통과 |
| 대화 게시 카드 | 컴포넌트 검사로 정확한 성공 실행만 링크 생성, 실패·deferred 제외, blob/manifest 복원·재조회 확인. 실제 모델 대화 실행은 미실행 |

처음 게시한 [create receipt](create-receipt.json), 재시작 뒤의
[resume receipt](resume-receipt.json), 바이너리·대시보드·종료 기록과 하네스
해시를 모은 [runtime receipt](runtime-receipt.json)를 함께 보관한다.
스크린샷은 재시작 뒤의 실제 화면이며 소스 불일치 경고를 숨기지 않았다.

Dashboard115개 검사는 아티팩트 surface/card, navigation, router 네 파일의
Vitest 결과다. 이후 제품 frontend 소스는 변경되지 않았다. 변경 파일 ESLint와
production bundle 빌드는 통과했다. 전체 dashboard typecheck에는 기존 main의
`dashboard-turn-records.ts:7` 미사용 import 두 건이 남아 있으며 #43871에 기록했다.
이를 전체 typecheck 성공이나 전체 회귀 성공으로 해석하지 않는다.

재현 시 바이너리와 같은 깨끗한 commit에서 `pnpm -C dashboard build`를 실행한다.
별도의 base 아래 `.masc/config/runtime.toml`에
`scripts/fixtures/release-evidence/runtime.toml`을 복사하고, 전용 admin token과
사용하지 않는 port를 사용한다. autonomous Keeper는 끄고, `MASC_ASSETS_DIR`은
그 checkout의 `assets`로 지정한다. 운영 설치·기본 base 설정을 바꾸지 않는다.

```sh
node scripts/verify-report-artifacts.mjs \
  "$BASE_URL" "$BINARY_COMMIT" "$ISOLATED_BASE" "$OUTPUT_DIR" "$TOKEN_FILE"
# 이 실행의 서버 PID만 종료하고 exit를 기록한 뒤 같은 base·binary로 재시작한다.
node scripts/verify-report-artifacts.mjs \
  "$BASE_URL" "$BINARY_COMMIT" "$ISOLATED_BASE" "$OUTPUT_DIR" "$TOKEN_FILE" resume
```

## 불확실성 (Uncertainty)

- 미확인 항목: 실제 모델이 게시 도구를 선택하는 대화, 운영 설치, 전체 회귀·릴리즈 검증은 이 기록의 범위 밖이다.
- 영향: 실행한 producer/API/UI 동작을 입증한다. 모델의 판단이나 운영 배포 완료를 주장하지 않는다.
- 추가 확인 필요: 운영 반영 시 해당 배포의 바이너리·대시보드 identity와 live base를 별도로 확인한다.

## 적용범위 (Scope)

- 영향 받는 영역: `<base-path>/.masc/published_artifacts`, Keeper 게시 도구, 인증된 HTTP API, Work → Artifacts 목록과 reader, 대화 카드.
- 제약/배제: 기존 runtime 파일을 자동 수집하지 않는다. self-contained HTML의 self-navigation은 가능하므로 일반적인 네트워크 sandbox를 주장하지 않는다. 재시작 검사는 graceful SIGTERM이며 강제 crash 검사가 아니다.
- 롤백 조건: 게시·원문 해시·버전·격리 경계가 재현되지 않으면 이 기록을 완료 근거로 사용하지 않는다.
