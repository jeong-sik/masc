# 기존 HWP의 표와 차트 데이터를 가져온다

확인일: 2026-11-16. Task: `task-3694`. 기존 Office PR: #52514.

## 확인할 문제

사용자는 기존 `.hwp`를 한글에서 HWPX로 다시 저장하지 않고 가져오길 원한다.
글자만 추출하면 병합 셀과 차트 데이터를 고칠 수 없다. 변환 성공은 본문과
개체 순서, 표의 셀 위치, 차트 종류·항목·계열·값을 읽었다는 뜻이어야 한다.
기관 양식의 페이지 배치와 한컴 화면의 동일성은 별도로 검증해야 한다.

## 후보를 실제 경로로 비교했다

| 후보 | 확인한 동작 | 선택에 미친 영향 |
| --- | --- | --- |
| `hwp-convert`의 HWP→HWPX | OLE를 unknown으로 읽고 HWPX 출력에서 생략한다. Markdown 출력은 병합 셀 내용을 여러 칸에 복제한다. | 편집 가능한 차트와 병합 표를 옮기는 경로로 쓰지 않는다. |
| `@rhwp/core`의 HWP→HWPX | 공개 HWP parser와 HWPX serializer가 있다. `exportHwpxWithReport`는 bytes와 내용 손실 보고서를 함께 돌려준다. | 문서 parser를 새로 쓰지 않고 재사용한다. 내용이 빠지면 성공으로 바꾸지 않는다. |
| RHWP의 차트 데이터 조회 | HWP5 OLE 차트를 읽지만 단순 조회 DTO에는 제목·막대 방향·숫자 형식 등이 없다. | 이 DTO로 기존 OfficeChart를 만들면 안 된다. |
| HWP5 OLE의 표준 차트 XML | `OOXMLChartContents`에 DrawingML 원데이터가 있다. | 원래 XML을 기존 Office 차트 reader로 읽는다. |

`hwp-convert`는 `fc154db8219279f8fc7904e6f1efa019c6774710`의
[GSO parser](https://github.com/shyang1012/hwp-convert/blob/fc154db8219279f8fc7904e6f1efa019c6774710/src/lib/hwp/control.ts),
[HWPX builder](https://github.com/shyang1012/hwp-convert/blob/fc154db8219279f8fc7904e6f1efa019c6774710/src/lib/hwp/hwpxBuilder.ts),
[Markdown writer](https://github.com/shyang1012/hwp-convert/blob/fc154db8219279f8fc7904e6f1efa019c6774710/src/lib/hwp/mdWriter.ts)를 읽었다.
RHWP는 공개 [v0.9.0](https://github.com/edwardkim/rhwp/releases/tag/v0.9.0)의
parser·WASM API·HWPX serializer를 대조했다. 로컬 `pkg` 0.8.2를
공개 0.9.0의 실행 결과로 취급하지 않는다.

## 차트 파일에서 직접 확인한 것

[한컴 HWP5 규격 revision 1.3 §4.3.9.6](https://cdn.hancom.com/link/docs/%ED%95%9C%EA%B8%80%EB%AC%B8%EC%84%9C%ED%8C%8C%EC%9D%BC%ED%98%95%EC%8B%9D_5.0_revision1.3.pdf)의
차트 경로를 RHWP의 공개 `samples/chart` HWP 4종과 대조했다.
기준 checkout은 `1a76570e833917d15817415a53c09ad61ab3203f`다.
독립 확인에는 `olefile 0.47`, Python의 zlib와 ElementTree를 썼다.

```text
HWP CFB
  BinData/BIN0001.OLE
    raw deflate → 크기 prefix → 중첩 CFB
      OOXMLChartContents → DrawingML chartSpace
```

4개 모두 HWP 5.1.1.0의 압축 문서였다. 차트는 OLE 참조로 연결됐으며,
별도 `CHART_DATA` 레코드는 없었다. 짝 HWPX의 차트와 항목·계열·값·
점 인덱스·점 개수는 4/4 같았다. XML 바이트는 3/4 같았다.
이것은 저장 데이터의 비교이며 실제 한컴 화면이나 인쇄 결과의 증거는 아니다.

HWP5의 `chart_id_ref=None`은 HWPX serializer에서 `hp:ole`로 남는다.
`exportHwpx()`만 호출한 결과를 기존 importer에 주면 차트를 가져올 수 없다.
출력된 OLE의 원래 XML을 읽어야 하며, 이미지로 대체해 성공으로 표시하면 안 된다.
`Contents`만 있는 구형 차트와 해석할 수 없는 OLE는 오류로 돌려준다.

## 비용과 남은 확인

검토 중 `cfb@1.2.2`의 작은 손상 FAT에서 무한 순회를 재현했다.
순환 검사로 그 입력은 거부했지만, 정상적인 역순 FAT에서도 기존
`make_sector_list`는 이미 읽은 꼬리를 반복 복사한다. 입력 크기만으로
이 reader의 시간·메모리가 선형이라고 주장할 수 없다.
검사한 물리 연결을 다시 해석하지 않고 그 결과에서 stream을 읽는다.
CFB 패키지는 독립 테스트 입력의 writer로만 사용한다.
[MS-CFB 형식](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/53989ce4-7b05-4f8d-829b-d08d6148375b)은
FAT·MiniFAT·directory의 해석 근거다.

실제 공개 WASM에서도 모르는 control을 생략한 뒤 손실 0을 보고했다.
본문에 섞인 수식, 문단에 직접 속하지 않은 텍스트, 짝 없는 UTF-16도
성공 결과의 텍스트에서 빠지거나 바뀌었다. 원본 control·record·문자 검사는
이 반례를 거부한다. HWP 전용 소비자는 미지원 요소를 경고 후 생략하지 않는다.

공식 npm registry에서 `@rhwp/core@0.9.0`이 존재함을 확인했다.
패키지의 압축 해제 크기는 32,452,840 bytes다. 실제 브라우저 번들 크기는
격리 Vite 빌드에서 확인했다. WASM 파일은 26,835,482 bytes다.
HWP를 선택할 때만 worker에서 불러온다. 패키지가 제공한 라이선스·고지 파일도
Dashboard 정적 asset 경로에 함께 출력한다.
서버에 한글을 설치하거나 사용자의 파일을 외부 변환 서비스에 보내지 않는다.

버전 고정과 패키지 무결성은 lockfile에 남긴다. 실제 공개 패키지로 차트 4종과
표 131개 셀의 내용을 대조하고, 값을 고친 HWPX·DOCX 10개를 다시 읽었다.
이 결과를 실제 브라우저 다운로드나 한컴 화면 일치로 보고하지 않는다.

추가 반례에서 517,120 bytes의 유효 CFB가 4,000,000자의 경로를 만들었다.
stream payload가 없어도 메모리가 늘어나므로, 경로를 만들기 전에 UTF-16
바이트를 전체 확장 예산에 포함한다. 대소문자가 다른 FileHeader도 실제
Core에서는 정상 문서였다. 조회와 충돌 검사는 공통 CFB 이름 index를 쓴다.
[MS-CFB §2.6.4](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/d30e462c-5f8a-435b-9c4c-cc0b9ea89956)의
길이·단순 대문자 규칙을 따르며, `ß`와 `SS`처럼 길이가 다른 이름을 합치지 않는다.

설계: [HWP 자동 가져오기](../rfc/RFC-artifact-hwp-import.md).
