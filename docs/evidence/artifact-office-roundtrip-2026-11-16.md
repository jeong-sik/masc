# HWPX·DOCX 표와 차트 왕복 검증

Task: `task-3689`. 작업 브랜치: `feat/artifact-office-roundtrip-20261116`.
코드 기준: `003c11a91f984a1c4a92f05d9154027f7f41888a`.
원래 base: `6613af5224086b0fdeec82250edde86e05833ae8`.

## 결과와 범위

HTML 아티팩트와 HWPX/DOCX 사이에서 병합 표와 native 차트를 옮긴다.
표 셀·차트 값을 고쳐 새 게시 버전에서 다시 내보낸다. 저장된 정본은
기존 HTML 원문이며 SVG·차트 캐시·내장 워크북은 출력할 때 만든다.
새 게시 상태나 서버 변환 API를 추가하지 않았다.

코드는 별도 worktree에 있다. main 병합·설치·배포는 하지 않았다.
GitHub CLI는 HTTP 401 또는 연결 실패로 원격 상태를 읽지 못했다.
PR·Native Stack 생성과 GitHub 정식 승인은 남아 있다.

## 로컬 검사

- 관련 테스트 165개 통과, 실패·보류 0개. 실제 테스트 파일은 10개다.
  `artifacts/office-roundtrip/final-focused.json`에 결과를 남겼다.
- Dashboard `tsc --noEmit`과 fixture 별도 타입 검사가 통과했다.
- 변경한 TypeScript 27개 파일의 ESLint 오류·경고는 0개다.
  마지막 차트 parser 변경에도 테스트 102개·타입·대상 lint를 다시 확인했다.
- `pnpm install --lockfile-only --offline --ignore-scripts --frozen-lockfile`이
  통과했다. `saxes@6.0.0`은 기존 lock의 버전·integrity를 재사용했다.
- 독립 리뷰는 위 head와 직접 base `bd5deec09399`를 지정했다.
  검토 범위에서 미해결 P0·P1·P2를 찾지 못했다. GitHub 승인은 아니다.

실제 파일 검사는 2026-11-16 18:04:55~18:05:13 KST에 실행했다.
검사 전후 관련 35파일의 SHA-256와 head가 같았다.

| 입력 | 확인한 결과 | 근거 파일 |
|---|---|---|
| 한컴 차트 4종 | 전체 항목·계열·숫자·숫자 형식 일치 | `artifacts/office-roundtrip/hwpx/final-native-charts.json` |
| 실제 기관 양식 | 표 56개 셀 내용·병합 일치, 그림 25개 SHA-256 일치 | `artifacts/office-roundtrip/hwpx/final-government-roundtrip.json` |
| 캡션 재현 문서 | `[그림 1]`~`[그림 3]` 전체 설명·출처가 DOCX/HWPX 재출력 후 유지 | `artifacts/office-roundtrip/hwpx/final-caption-autonum-roundtrip.json` |

파일 바이트 검사와 자체 재가져오기 결과다. 실제 Word·한컴 앱 열기나
페이지 배치·인쇄 품질을 증명하지 않는다.

## 남은 확인

ego-browser는 앱 시작에 실패했고, Playwright Chromium은 macOS
`MachPortRendezvousServer` 시작 단계에서 종료됐다. 실제 브라우저 다운로드는
미검증이다. 재실행 방법은
[격리 fixture](../../dashboard/fixtures/office-roundtrip/README.md)에 있다.
UI 통합 테스트의 게시 API는 mock이며 실제 MASC 서버 저장 확인과 구분한다.

기존 `artifact-editing.test.ts`는 문서 reader가 로딩에 머무는 실패가 있다.
같은 단일 테스트가 원래 main과 작업 브랜치에서 모두 실패했다.
이 문제는 `task-3690`에 따로 기록했고 이번 기능의 성공에 포함하지 않았다.
전체 Dashboard 테스트·전체 빌드·Release/Tag CI는 실행하지 않았다.

바이너리 `.doc`, 기관별 양식의 페이지 배치, 누적·조합·보조축·날짜축 차트는
지원하지 않는다. 자동 번호는 정적 글자로 바뀐다. HWPX의 일부 글자 서식도
달라진다. 사용 범위는 [사용법](../design/artifact-document-export.md)에 적었다.
