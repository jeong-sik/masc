# 표와 차트를 편집하는 문서 왕복

확인: 2026-11-16. 사용자 요청과 MASC Task `task-3689`가 범위다.

## 구현 전 코드

조사 기준은 main `6613af522408`이다. 아래는 구현 전 상태다.

`Published_artifact.format`은 HTML과 Markdown이다. Dashboard의
`artifact-word-export.ts`는 문단·병합 표·포함된 PNG/JPEG를 DOCX로 만든다.
Canvas와 SVG는 건너뛴다. 파일 가져오기는 UTF-8 HTML/Markdown만 받는다.
공유 원고와 문장 편집기는 HTML 표 안의 글자도 수정할 수 있다.

## 재사용할 부분

- 고정 의존성 `docx@9.14.0`의 `docx/charts`는 native 차트와 내장
  Excel 데이터를 만든다. `ChartRun`은 새 차트를 만들고 `ChartDataPatch`는
  템플릿의 차트 데이터를 바꾼다.
- `jszip`과 `@xmldom/xmldom`은 이미 Dashboard에 있다. ZIP과 XML을 새로
  구현하지 않고 각 문서 형식의 문단·표·차트 구조를 이 라이브러리로 읽는다.
- `saxes@6.0.0`도 기존 개발 의존성에 있다. XML 1.0 namespace 검사를 DOM
  생성 전에 두면 같은 namespace의 속성이 덮어써져 사라지는 입력을 거부한다.
  실제 Office 입력 검사에 쓰기 위해 직접 의존성으로 고정했다.
- `rhwp`에는 HWPX 차트 조회·값 수정·저장 코드가 있다. 그러나 HTML 변환은
  차트를 생략하며 새 차트 삽입 API도 없다. HTML 왕복만 연결하면 요구한
  차트 편집이 성립하지 않는다. 로컬 WASM 산출물과 Rust 소스의 API도 다르다.
- `hwp-convert`는 차트를 지원하지 않는다고 명시한다. `handoc`의 일반
  HWPX 트리 역시 차트의 계열·값을 편집하는 공통 계약을 제공하지 않는다.

## 출처와 한계

- [한컴 HWPX 구조](https://tech.hancom.com/hwpxformat/)
- [docx native 차트](https://docx.js.org/api/modules/charts.html)
- [saxes XML 검사](https://github.com/lddubeau/saxes)
- [docx 템플릿 차트 데이터](https://docx.js.org/api/classes/charts.ChartDataPatch.html)
- [rhwp 공개 차트 API](https://github.com/edwardkim/rhwp/blob/v0.9.0/src/wasm_api.rs)
- [hwp-convert 지원 범위](https://github.com/shyang1012/hwp-convert)
- [handoc 패키지](https://github.com/muin-company/handoc)

소스와 공식 문서에 대한 조사다. 실제 한글·Microsoft Word에서의 열기,
페이지 배치와 인쇄 결과는 아직 확인하지 않았다. 기존 기관 서식 전체를
HTML로 바꿨다가 원래 모양으로 복원할 수 있다는 근거도 없다.

결정은 [문서 왕복 RFC](../rfc/RFC-artifact-office-roundtrip.md)에 둔다.
