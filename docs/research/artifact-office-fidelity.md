# 표 너비와 편집 반복 비용 조사

확인: 2026-11-17. 코드 기준 `277c8f55816d`.

공개 `rhwp/samples/table-001.hwp`의 SHA-256은
`7238f63629ca1c9af1419324a2ad10c031634c5b182398742eaf67179d6b5223`다.
HWP5 버전은 5.0.3.0이다. 압축을 푼 `BodyText/Section0`의
LIST_HEADER record 554, payload 558, 너비 필드 574에
`b6390000`이 있다. little-endian 정수 14774다. 원본 CFB의
파일 오프셋과 압축 해제 스트림의 오프셋을 혼동하지 않는다.

공식 `@rhwp/core@0.9.0`이 출력한 HWPX에도 첫 셀 너비가 14774다.
현재 HTML에는 너비가 없고, DOCX의 첫 열은 1002twip이다.
그 DOCX를 거친 HWPX의 첫 셀은 5010HWPUNIT이다.
이 비교는 파일에 저장한 데이터다. 한글의 실제 화면을 잰 값은 아니다.

Microsoft의 [표 격자 설명](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.tablegrid)
은 `tblGrid`가 공유 경계와 기본 너비를 정의한다고 설명한다.
[셀 너비 설명](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.tablecellwidth)
은 선호 너비와 표 배치 알고리즘을 구분한다. 숫자 필드 일치만으로
실제 글꼴·줄바꿈·페이지 일치를 주장할 수 없다.
[한컴의 HWPX 설명](https://tech.hancom.com/hwpxformat/)에서 본문·
서식·바이너리 파트와 읽기 순서를 확인했다. 공식 HWP5 PDF는 이번
웹 도구로 열리지 않았다. 바이트 해석은 공개 원본과 고정 Core 출력도
함께 비교한다.

공동 편집기의 실제 `selectSharedTextRange`를 같은 방식으로 반복하면,
셀 400개인 4058B 원고는 44.06ms, 1052634B 원고는 762.90ms였다.
Node 26.3.0, 준비 1회·측정 3회 중앙값이다. 큰 원고는 합성 data-URI
문자열을 썼다. 이미지 디코딩과 브라우저 렌더 시간은 포함하지 않는다.
조각마다 encode·Y.Doc 복원·Unicode 검사를 반복하는 것이 원인이다.
호출 안에서 검사를 한 번으로 묶고 같은 입력으로 다시 잰다.

결정: [표 너비와 화면 편집 RFC](../rfc/RFC-artifact-office-fidelity.md).
