# 표·차트 파일의 실제 브라우저와 Office 출력 확인

관측일: 2026-11-16. Task: `task-3697`.
기반은 #52552가 병합된 `ea0b8d1fd284fad784557373fd82e8565a774b10`이다.
제목 수리와 최종 회귀 후보는 `aa8dca08304c51bdddf5f8397adfe701e4c75b95`다.

## 실제로 확인한 경로

공식 Playwright `1.61.1` Linux arm64 이미지에서 Chromium `149.0.7827.0`을 실행했다.
이미지 digest는 `sha256:5b8f294aff9041b7191c34a4bab3ac270157a28774d4b0660e9743297b697e48`이다.
격리 HWP fixture를 빌드한 실제 컴포넌트·worker·WASM을 사용했다.
브라우저 컨테이너는 외부 네트워크 없이 로컬 정적 서버를 읽었다.
게시 API와 작업 공간 응답은 탭의 메모리로 대체했다.

| 흐름 | 확인한 결과 |
| --- | --- |
| 초기 병합 표와 4종 차트를 DOCX/HWPX로 다운로드 | 실제 파일 2개 |
| 각 파일을 다시 가져와 차트 값을 수정하고 게시·재다운로드 | 흐름 2개, 실제 파일 2개 |
| 공개 HWP 차트 4종과 표 1개를 가져와 값 수정·게시·두 형식 다운로드 | 흐름 5개, 실제 파일 10개 |
| 읽기 취소 후 같은 HWP 재선택 | 실제 worker 종료 2회 |
| 읽는 중 닫기 | 실제 worker 종료와 가져오기 화면 닫힘 |
| 지원 범위를 넘는 표와 HWP가 아닌 파일 | 오류 2개, 원고 생성 없음 |

최종 12개 흐름이 통과했다. 실제 worker 10개가 모두 종료됐다.
pageerror는 0건이었다. 실제 WASM 응답의 MIME도 확인했다.
다운로드 14개의 바이트 수·SHA-256을 실행 결과와 다시 대조했다.

다운로드 파일은 Node의 기존 Office reader로 다시 읽었다.
HWP에서 읽은 차트 4종의 전체 데이터와 원본 표 131셀을 비교했다.
수정한 HWPX/DOCX의 차트 종류·제목·계열·항목·값·서식도 비교했다.
표는 전체 내용·행/열 좌표·병합 범위를 대조했다.
초기 4차트 문서도 수정한 차트와 나머지 차트·병합 표를 함께 비교했다.

이는 실제 파일 선택·worker 실행·편집·다운로드 증거다.
실제 MASC 서버에 원고를 저장했다는 증거는 아니다.

## 외부 Office 프로그램에서 찾은 문제와 수리

실제 다운로드 DOCX 6개를 Linux LibreOffice `24.2.7.2`에서 열고 PDF로 출력했다.
내용을 다시 읽는 검사에서는 제목 없는 차트가 그대로였다.
하지만 실제 출력에는 `main-title`이라는 제목이 나타났다.
세로 막대·가로 막대·꺾은선·원형 4종 모두 같았다.

원본 차트 제목은 빈 문자열이었다.
`docx@9.14.0`의 ChartRun은 title 옵션이 없을 때 제목을 생략한다.
그때 `autoTitleDeleted=1`도 함께 기록한다.
MASC는 빈 문자열을 명시해 빈 title과 `autoTitleDeleted=0`을 만들었다.
빈 제목이면 옵션을 생략하도록 생성 시점의 매핑 한 곳을 고쳤다.
HWPX도 이 생산자의 native 차트 XML을 사용한다.

- 첫 DOCX 회귀 8건은 수정 전 빈 제목 4건이 실패했다.
- 최종 제목 회귀는 DOCX/HWPX × 4종 × 빈/명명 제목의 16건이다.
- 관련 3파일 116건 통과, 실패·보류 0건.
- 전체 Dashboard TypeScript와 변경 TypeScript 2파일 ESLint 통과.
- 수정 후 번들을 다시 빌드하고 위 브라우저 12흐름·14다운로드를 재실행했다.
- 새 DOCX 6개를 LibreOffice에서 다시 열었다.
  제목 없는 4종 모두 `main-title`이 사라졌다.
  명명된 차트 제목 4개는 남았다. PDF의 글과 실제 렌더 이미지로 확인했다.

## 남은 범위

원본 표 열 너비는 보존하지 않는다.
공개 표 첫 열은 14774 HWPUNIT이지만 DOCX는 9열에 폭을 균등 배분한다.
이 때문에 한국어 줄바꿈이 달라진다.
셀 데이터 보존과 원본 인쇄 배치는 다른 결과다.
별도 [이슈 #52562](https://github.com/jeong-sik/masc/issues/52562)에 기록했다.

실제 한컴과 Microsoft Word 실행, 실제 MASC 저장, 설치·배포는 미검증이다.
LibreOffice 결과를 한컴·Word 호환성 전체의 증거로 바꾸어 쓰지 않는다.
macOS Ego와 직접 Chromium 시작은 막혔다.
macOS LibreOffice도 독립 텍스트 대조 입력에서 시작에 실패했다.
실제 성공한 환경은 위 Linux Chromium과 Linux LibreOffice다.

## 원문 보관

실행 스크립트·입력 해시·JSON·trace·다운로드·PDF 전후 출력은
checkout의 `artifacts/hwp-browser-verification/`와
Task의 producer artifact 스냅샷에 보관한다.
`browser/result.json`, `download-data-check.json`, `office-render-check.json`,
`title-before.json`, `title-final.json`이 집계 근거다.
스크린샷의 일부 표가 보인다는 사실을 전체 페이지 배치 일치로 보고하지 않는다.
바이너리와 생성 출력은 커밋하지 않는다.
