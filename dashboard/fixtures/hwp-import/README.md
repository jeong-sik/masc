# 기존 HWP 차트 데이터 대조

공식 `@rhwp/core@0.9.0` WASM으로 실제 HWP를 읽고 기존 편집 원고로 만든다.
RHWP 공개 샘플의 짝 HWPX와 전체 차트 데이터를 비교한다.
첫 계열 값을 고친 뒤 HWPX·DOCX를 다시 가져와 수정값을 확인한다.

```sh
cd dashboard
pnpm exec tsx fixtures/hwp-import/probe.ts /path/to/rhwp/samples ../artifacts/hwp-import/native-roundtrip
pnpm exec tsx fixtures/hwp-import/table-probe.ts /path/to/rhwp/samples ../artifacts/hwp-import/native-roundtrip
pnpm exec vite build --config fixtures/hwp-import/vite.config.ts
```

기준 입력은 RHWP `1a76570e833917d15817415a53c09ad61ab3203f`의 공개
`samples/chart` 세로 막대·가로 막대·꺾은선·원형 4종이다.
이 저장소에는 해당 HWP 바이너리나 회사 문서를 복사하지 않는다.
실행 기록은 입력·WASM·출력 SHA-256과 비교한 데이터를 포함한다.

표 대조는 같은 공개 저장소의 `samples/table-001.hwp`를 쓴다.
원본 TABLE·LIST_HEADER·PARA_TEXT에서 읽은 19행·9열, 131개 셀의
내용·행/열 주소·가로/세로 병합을 HTML 원고와 비교한다.
셀 값을 고친 뒤 HWPX·DOCX를 다시 가져와 전체 셀을 비교한다.
`inner-table-01.hwp`는 일반 도형이 함께 있어 현재 가져오기에서 거부된다.
이 파일로 실제 HWP 중첩 표 보존을 확인했다고 보고하지 않는다.

화면에서 확인할 때는 [Office 왕복 fixture](../office-roundtrip/README.md)를 쓴다.
HWP를 가져온 뒤 편집·게시·HWPX/DOCX 다운로드를 확인한다.
이 Node 대조는 실제 브라우저 다운로드와 한컴·Word 화면을 증명하지 않는다.
별도 Vite 설정은 격리 화면과 실제 HWP worker·WASM·고지 파일만 빌드한다.
전체 Dashboard 빌드나 실행 중인 Dashboard 설치는 바꾸지 않는다.

2026-11-16에는 Linux Chromium에서 실제 HWP worker와 다운로드도 확인했다.
DOCX 6개는 Linux LibreOffice에서 열어 출력했다.
실제 한컴·Word 실행과 원본 표 너비 보존은 확인한 범위에 포함하지 않는다.
자세한 범위는 [검증 기록](../../../docs/evidence/artifact-office-browser-2026-11-16.md)에 있다.
