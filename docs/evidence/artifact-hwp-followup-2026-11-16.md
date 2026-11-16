# HWP 가져오기 취소와 표 크기 사전 검사

관측일: 2026-11-16. Task: `task-3695`.
병합된 #52541의 후속 수정이다.
코드 후보 `421e4323e959faa32d1e4ecd623d3ba124bb2d7b`를
base `607419c653251c46470eabee1b71f0ac8bd61b48`와 비교했다.

## 바뀌는 동작

- 읽는 중 `가져오기 취소`를 누르면 화면을 유지하며 현재 읽기를 무효화한다.
  HWP worker는 즉시 종료한다. `닫기`도 부모의 unmount를 기다리지 않고 취소한다.
- 늦게 도착한 파일 바이트로 취소한 변환을 시작하지 않는다.
  이전 성공·실패가 다음 읽기의 메시지나 원고를 덮지 못한다.
- 선택한 File을 고정한 뒤 파일 입력을 비운다.
  취소·실패 뒤 같은 파일을 다시 선택할 수 있다.
- HWP 읽기는 필수 `AbortSignal`을 받는다.
  기존 실제 호출자는 이미 신호를 전달했으며, 이번 변경은 API에서도 이를 요구한다.
- 원본 TABLE 레코드의 행·열 수를 기존 `hwpxTableLimits`로 확인한다.
  후단 HWPX importer가 지원하지 않는 크기를 WASM 호출 전에 거부한다.
  새 표 면적 제한이나 경과 시간 제한은 추가하지 않았다.

## 실패 재현과 수정 확인

| 검사 | 수정 전 | 수정 후 |
| --- | --- | --- |
| 같은 화면에서 취소·즉시 닫기·파일 바이트 지연 | 새 회귀 3건 실패 | UI 11건과 worker driver 9건 통과 |
| native input.files에 같은 File 재선택 | 파일 선택값이 남아 1건 실패 | 선택값·FileList를 비우고 재시도 통과 |
| 지원 범위를 넘는 원본 표 행·열 | 경계 3건 실패 | 지원 경계·초과·큰 양성 면적 5건 통과 |

컴포넌트 시험은 happy-dom과 모의 worker를 쓴다.
실제 picker나 브라우저 Worker 시험으로 보고하지 않는다.
WHATWG는 같은 파일 재선택을 `change` 대신 `cancel`로 볼 수 있게 한다.
[파일 선택 규약](https://html.spec.whatwg.org/multipage/input.html#show-the-picker-if-applicable)

원본 Header·DocInfo를 공개 `table-001.hwp`에서 유지하고
본문만 독립 작성한 9,728바이트 입력도 대조했다.
행·열 65,535개, 전체를 병합한 셀 하나를 선언한다.
입력 SHA-256은 `36c0bff813a1514663947d2de45f9ee6f63f011fa86fb11704ea8855b9c6cfc1`이다.
이전 preflight는 통과했으며, 실제 Core 생성자는 진단 관측 2,500ms 안에
반환하지 않았다. 진단 worker를 종료했으며 serializer는 호출하지 않았다.
무한 실행이나 한컴에서 열리는 정상 문서라고 판정한 결과가 아니다.
수정 후에는 WASM을 초기화하지 않은 직접 변환 호출에서도 지원 범위 오류로 끝난다.
진단 관측 시간은 제품의 제한 시간이 아니다.

Core의 격자 할당 크기를 입력 면적 제한으로 쓰지도 않았다.
고정 [Core 소스](https://github.com/edwardkim/rhwp/blob/c9095c5f67632e6721e800ccc7fb43ea49d26682/src/model/table.rs#L1148)는
할당과 셀 범위 순회를 별도로 한다.
4,001행·1,000열의 양성 입력은 4,001,000개 논리 위치를 갖는다.
수정 후 실제 WASM의 손실 보고는 0건이다.
HWPX·HTML의 4,001개 셀 값·순서·좌표·병합 범위가 독립 작성한 정답과 일치했다.
입력 SHA-256은 `76cafef421de1cfc1141bb1bc68e5109d1afc55891766c03344230c7925fa9d9`이다.

## 최종 검사

- 관련 15파일의 300건 통과, 실패·보류 0건.
  공개 입력과 실제 Core OLE 출력의 선택 검사를 모두 켰다.
  검사 전후 변경 7파일의 SHA-256이 같았다.
- 전체 Dashboard `tsc --noEmit` 통과. 변경 TypeScript 6파일 ESLint 통과.
- 실제 `@rhwp/core@0.9.0`으로 공개 HWP 차트 4종을 짝 HWPX와 비교했다.
  표는 원본 131개 셀의 값·좌표·병합을 대조했다.
  값을 수정한 HWPX/DOCX 10개를 다시 읽어 전체 데이터를 비교했다.
- HWP fixture의 격리 Vite 빌드 통과. 큰 chunk 경고는 남는다.
  WASM과 라이선스·고지 85파일의 패키지/빌드 SHA-256이 일치했다.
- 독립 세션이 같은 코드 head의 전체 7파일을 직접 읽었다.
  확정된 미해결 P0·P1·P2 없음으로 판정했다. GitHub 정식 승인은 별도다.

로그·JSON·원본 대조 입력은 checkout의 `artifacts/hwp-followup/`에 둔다.
`focused-final.json`, `grid-exact.json`, `grid/row-cells-4001x1000.json`,
`native-roundtrip/report.json`, `native-roundtrip/tables.json`, `packaging.json`이 근거다.
원래 거대 입력의 수정 전 진단은 main checkout의
`artifacts/hwp-followup-review-grid/`에 있다.
HWP 바이너리나 생성 출력은 커밋하지 않는다.

## 확인하지 못한 범위

자동 응답 시한은 없다. 사용자가 취소하지 않으면 변환이 계속될 수 있다.
표 축 사전 검사가 모든 허용 입력의 CPU 시간 상한을 증명하지는 않는다.
취소는 worker가 메시지에 응답하기를 기다리지 않는 `terminate()`를 호출한다.
[worker 종료 규약](https://html.spec.whatwg.org/multipage/workers.html#terminate-a-worker)

브라우저 실행 도구가 시작 단계에서 실패했다.
실제 업로드·worker 실행·다운로드는 미검증이다.
실제 MASC 게시와 한컴·Word 화면, 전체 회귀, CI, 설치·배포도 이 결과에 포함하지 않는다.

## 재실행

기존 [HWP fixture](../../dashboard/fixtures/hwp-import/README.md)의 두 Node probe와
격리 Vite 명령을 사용한다. 관련 Vitest를 실행할 때
`MASC_HWP_PUBLIC_SAMPLES`는 공개 `samples/chart` 경로로,
`MASC_HWP_CORE_EXPORTS`는 실제 Core로 만든 `<종류>-core-0.9.0.hwpx` 4개가
있는 경로로 지정한다. 입력이 없으면 해당 선택 검사는 건너뛴다.
