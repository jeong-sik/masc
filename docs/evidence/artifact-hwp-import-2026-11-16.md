# 기존 HWP 자동 가져오기 검증

Task: `task-3694`. 코드 head: `876e663322408d82d86ecf6b1300240feaf465b5`.
base: `d2fa5aadd2f4f64ec0ee1574decb769085b4f3cf`.
검증 tree: `00763a147194b6f4f8f597743268c5f84a3570a8`.
이후 추가하는 검증 문서와 changelog는 이 코드 실행의 대상과 구분한다.

## 동작

기존 HWP5를 선택하면 브라우저 worker에서 HTML 편집 원고로 가져온다.
한글 설치나 수동 HWPX 변환을 요구하지 않는다. 표 셀과 차트 데이터를 고친 뒤
기존 게시·HWPX/DOCX 내보내기를 쓴다. 원본 HWP는 쓰지 않는다.

HWP3, 암호·DRM·배포 문서, 일반 도형·수식·글상자와 구형 차트는 지원하지 않는다.
지원하지 않는 개체나 손상된 입력을 발견하면 일부 내용만 등록하지 않고 실패한다.
HWP 파일 쓰기와 원본 페이지·글꼴·인쇄 배치의 동일성은 이 기능의 범위가 아니다.

## 실행한 검사

- 관련 테스트 292/292 통과. 실제 테스트 파일 15개, 실패·보류 0개다.
  명시 목록은 `artifacts/hwp-import/focused-files.json`, 전체 결과는
  `focused-tests.json`에 남겼다. `candidate-checks.json`은 head·base·명령·
  종료 코드와 35개 변경 파일의 검사 전후 같은 SHA-256을 기록한다.
- 변경한 `dashboard/src` TypeScript 24개 파일 ESLint 오류·경고 0개.
  probe·격리 Vite 설정·notice plugin은 별도의 strict 타입 검사로 확인했다.
  프로젝트 ESLint에서 제외한 파일을 lint 성공에 포함하지 않았다.
- frozen offline lock 검사 통과. 전체 Dashboard 타입 검사는 기존
  `keeper-asks.test.ts`의 필수 `name` 누락 3건에서 실패했다.
  같은 문제를 다루는 [별도 PR #52526](https://github.com/jeong-sik/masc/pull/52526)은
  이 코드 head에 포함하지 않았다.
- 격리 Vite 빌드에서 실제 worker와 WASM을 출력했다. WASM은 26,835,482 bytes,
  SHA-256은 `c3b0632b84881f81f2c80be7c2f9e44a4086cb01e05a6a9107a3b3c6350abc1d`다.
  npm 패키지의 라이선스·고지 85개 파일, 4,723,999 bytes를 정적 asset 경로에
  함께 출력하고 원본과 해시를 대조했다. `browser-assets.json`에 기록했다.

실제 npm `@rhwp/core@0.9.0`을 썼다. worker mock은 화면의 취소·실패·게시 경로만
확인한다. WASM 양성 시험은 별도로 쓴 HWP5 레코드를 읽는다. TAB, UTF-16
서로게이트, 원본 제어 문자로 저장한 묶음 빈칸·고정폭 빈칸도 확인했다.

## 실제 공개 HWP와 재출력

RHWP `1a76570e833917d15817415a53c09ad61ab3203f`의 공개 샘플을 썼다.
회사 문서나 HWP 바이너리를 이 저장소에 추가하지 않았다.

| 입력 | 직접 대조한 것 | 수정 후 확인 |
| --- | --- | --- |
| 세로 막대·가로 막대·꺾은선·원형 HWP 4개 | 짝 HWPX의 전체 차트 항목·계열·값·숫자 형식·결측치 표시와 일치 | 첫 계열 값을 42로 고친 HWPX/DOCX 8개를 재가져와 전체 차트 데이터 일치 |
| `table-001.hwp` | 원본 TABLE·LIST_HEADER·PARA_TEXT의 19행·9열, 131개 셀 내용·좌표·병합과 일치 | 셀을 고친 HWPX/DOCX 2개를 재가져와 전체 표 일치 |
| HWP 4개와 실제 Core 출력의 OLE 4개 | 독립 reader와 52개 stream의 경로·바이트 일치 | reverse FAT·MiniFAT에서도 원래 bytes 유지 |

`native-roundtrip/report.json`, `native-roundtrip/tables.json`,
`compound-reader-summary.json`에 입력·출력 hash와 비교한 데이터를 기록했다.
실제 HWP 중첩 표 샘플 `inner-table-01.hwp`는 일반 도형을 함께 포함해 거부된다.
이 파일의 중첩 표가 보존됐다고 보고하지 않는다.

## 확인한 실패와 소스 리뷰

알 수 없는 원본 control, 잘못된 문단 소속, UTF-16 손상, 암호·압축 속성,
순환 FAT, 중간에서 잘린 mini sector, 경로 문자열 확장과 이름 충돌을 거부한다.
CFB 이름 조회는 원래 경로를 보존하며 단순 대문자·길이 규칙을 공유한다.
일반 대소문자 차이를 손상으로 오인하지 않고 `ß`와 `SS`도 합치지 않는다.

HWP와 HWPX의 같은 표 검사에서 반복 비용을 재현해 공통 행 이벤트 검사로 바꿨다.
HWPX를 가져와 HTML 표를 만들 때도 행마다 전체 셀을 다시 검색하지 않는다.
임의 셀·깊이 제한은 넣지 않았다.
Core의 실제 동시 문단 조상 한계 64개는 원본 검사에 반영했다.

독립 리뷰어가 위 head·base·전체 diff와 producer/consumer를 읽고 local source
PASS로 판정했다. 미해결 P0·P1·P2는 없다. 실제 WASM·공개 입력·경로·이름·표 검사도
별도로 실행했다. 이 판정은 GitHub 정식 승인이나 배포 승인이 아니다.

## 남은 확인

Chromium이 macOS `MachPortRendezvousServer` 시작 단계에서 종료됐다.
실제 브라우저 업로드·worker 실행·다운로드는 미검증이다. 격리 Vite 빌드 성공을
그 동작의 성공으로 보고하지 않는다. 실제 MASC 게시·한컴/Word 앱 화면·인쇄·
전체 Dashboard 회귀·전체 빌드·Release CI·설치·배포도 확인하지 않았다.

재실행: [HWP 대조 fixture](../../dashboard/fixtures/hwp-import/README.md).
사용 범위: [아티팩트 문서 내보내기](../design/artifact-document-export.md).
