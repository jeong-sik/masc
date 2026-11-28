---
rfc: "workspace-documents-arrive-as-pages-and-text"
title: "Workspace Documents Arrive as Pages and Text"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: vincent
related: ["workspace-chat-media-renders-where-it-is-written", "workspace-documents-are-written-together", "workspace-media-and-rich-embed"]
---

# RFC workspace-documents-arrive-as-pages-and-text: 문서는 페이지와 글로 도착한다

## 0. 요약

사람이 Dashboard 채팅에 DOCX 를 끌어다 놓으면 업로드가 거절된다.
서버가 아는 문서는 PDF 하나다(`lib/attachment_store/attachment_store.ml:383-412`).
PDF 는 올라가지만 Dashboard 는 다운로드 카드만, TUI 는 `[pdf]` 자리표시만 보여 준다.
Keeper 는 PDF 의 글을 읽는다. 나머지 형식은 읽을 길이 없다(`lib/keeper/keeper_media_reading.ml:234-239`).

이 RFC 는 HWP·HWPX·DOC·DOCX·XLS·XLSX·PPT·PPTX·PDF 아홉 형식을 받는다.
서버가 격리된 컨테이너에서 각 문서를 PDF 와 페이지 PNG 로 바꾸고, PDF 가 아닌 형식은 글(`text.md`)도 뽑는다.
사람은 두 클라이언트에서 페이지를 넘겨 보고, Keeper 는 글을 읽는다.

11-24 #54560 은 브라우저 안의 Office·HWP 변환기를 지워 Dashboard 배포 자산을 59.38 MB 에서 4.52 MB 로 줄였다.
이 RFC 는 읽기·미리보기 변환기를 브라우저로 되살리지 않는다. 클라이언트는 서버가 만든 PNG 만 받는다.
HWP 를 HWP 그대로 고치는 편집기만 따로, 편집을 누를 때 불러온다.
그 편집기는 [workspace-documents-are-written-together](RFC-workspace-documents-are-written-together.md) §5 가 맡는다.

## 1. 지금 (`899cb2033e5fa`)

| 단계 | 지금 동작 | 근거 |
|---|---|---|
| 서버 받기 | 문서는 PDF 만 받는다. 나머지는 `Unsupported_or_unknown_format` | `attachment_store.mli:86-100`(형식), `:127-140`(오류), `attachment_store.ml:383-412` |
| 서버의 선언 MIME | 없거나 `application/octet-stream` 이면 판별 결과를 쓴다 | `attachment_store.ml:1293-1310` |
| Dashboard 받기 | 허용 목록의 문서는 PDF 뿐이다. 확장자로 MIME 을 정해 `Content-Type` 으로 보낸다 | `dashboard/src/components/attachments/validation.ts:16-18,120-126,207`, `dashboard/src/api/attachments.ts:315` |
| TUI 받기 | 앞 512 바이트를 보고, 모르면 확장자로 짐작한다. 둘 다 모르면 올리지 않는다 | `lib/masc_tui/protocol/wire_attachment.ml:399-404,499-511`, `lib/masc_tui/net/http_client.ml:464-474` |
| Keeper 읽기 | PDF 만. 호스트에서 `pdftotext` 를 돌린다. 60초, 64쪽 상한 | `keeper_media_reading.ml:234-239`, `verification_pdf_inspection.ml:98,107,222` |
| 외부 reader | `[[media_readers]]` 선언(`markitdown_mcp`)은 있지만 설치된 경로가 없다 | `docs/RUNTIME-TOML-REFERENCE.md` §10 |
| Dashboard 미리보기 | 다운로드 카드 | `attachment-gallery.ts:15-16` |
| TUI 미리보기 | `[pdf]` 자리표시 | `lib/masc_tui/store/chat_transcript.ml:942` |

MIME 문자열 비교도 흩어져 있다.
`keeper_media_reading.ml:235`, `chat_transcript.ml:942`, `wire_attachment.ml:638` 이 `"application/pdf"` 를 직접 비교한다.
문서 형식을 여덟 개 더하면서 이 비교를 하나씩 늘리지 않는다. §3.1 의 variant 로 바꾼다.

## 2. 결과

- 아홉 형식이 업로드에서 받아들여진다. 형식은 파일 이름이 아니라 내용 구조로 정한다.
  `.doc` 라는 이름의 DOCX 도 DOCX 로 받는다.
- 암호가 걸린 문서는 업로드할 때 `Encrypted_document` 로 거절한다. 메시지는 「암호를 푼 뒤 다시 올려 주세요」다.
- Dashboard 는 첨부 카드에 첫 페이지와 쪽수를 보여 준다. 누르면 페이지 보기가 열린다.
- TUI 는 첫 페이지를 Kitty·iTerm2·반블록으로 그리고, `/page <n>` 으로 넘긴다.
- Keeper 는 아홉 형식의 글을 읽는다. 표는 Markdown 표로, 슬라이드는 슬라이드마다 절로 나뉜다.
- 원본은 바뀌지 않는다. 변환 결과는 원본과 변환기 판에 묶인 파생 캐시다.

## 3. 설계

### 3.1 형식을 내용으로 고른다

`supported_mime` 에 생성자 하나를 더하고, 기존 `Application_pdf` 를 그 안으로 옮긴다.
`media_kind_of_mime` 은 모두 `Document` 다.

```ocaml
type document_format =
  | Pdf | Hwp | Hwpx | Doc | Docx | Xls | Xlsx | Ppt | Pptx

type supported_mime =
  | ...                       (* 기존 이미지·오디오·동영상 *)
  | Document of document_format
```

`"application/pdf"` 를 비교하던 세 곳은 `Document Pdf` 를 `match` 한다.

판별은 새 순수 라이브러리 `media_format` 이 한다. 서버 `Attachment_store` 와 TUI `Wire_attachment` 가 같이 링크한다.
TUI 의 512 바이트 판별과 확장자 짐작은 이것으로 바꾼다.
ZIP 의 목차는 파일 끝에 있으므로, TUI 는 최대 크기 안에서 파일 전체를 읽어 판별한다.

| 형식 | 컨테이너 | 판별 기준 |
|---|---|---|
| PDF | `%PDF-` | 지금과 같다 |
| DOCX | ZIP | `_rels/.rels` 의 officeDocument 관계가 가리키는 part 의 형식이 `[Content_Types].xml` 에서 `…wordprocessingml.document.main+xml` |
| XLSX | ZIP | 같은 자리가 `…spreadsheetml.sheet.main+xml` |
| PPTX | ZIP | 같은 자리가 `…presentationml.presentation.main+xml` |
| HWPX | ZIP | 첫 항목 `mimetype` 이 압축 없이 저장되어 있고 내용이 `application/hwp+zip` |
| DOC | CFB (`D0 CF 11 E0 A1 B1 1A E1`) | `WordDocument` stream |
| XLS | CFB | `Workbook` 또는 `Book` stream |
| PPT | CFB | `PowerPoint Document` stream |
| HWP | CFB | `FileHeader` stream 이 `HWP Document File` 로 시작 |

- ZIP 안에서 위 기준이 정확히 하나만 맞아야 한다. 하나도 없거나 둘 이상이면 `Unsupported_or_unknown_format` 이다.
  `mimetype` 과 `[Content_Types].xml` 이 함께 있거나 main part 가 둘이면 여기에 걸린다.
- 매크로가 든 OOXML(`…macroEnabled.main+xml`)은 닫힌 집합 밖이라 `Unsupported_or_unknown_format` 이다.
- XML 은 이미 쓰는 `markup` 으로 읽는다. 부분 문자열로 찾지 않는다.
- ZIP 은 `zipc`(ISC, 순수 OCaml)로 읽는다. 펼치는 항목은 `_rels/.rels`·`[Content_Types].xml`·`mimetype` 셋뿐이다.
  안전 경계로 앞의 둘은 적힌 크기가 `package_part_max_bytes`(1 MiB)를 넘으면 펼치지 않고 깨진 컨테이너로 본다.
  펼친 크기가 central directory 에 적힌 크기와 달라도 깨진 컨테이너다.
- CFB 를 읽는 OCaml 라이브러리는 찾지 못했다. 그래서 작은 reader 를 둔다.
  이 reader 는 header·FAT·miniFAT·디렉터리를 읽고, 이름이 정해진 stream 의 앞부분을 읽는다.
  `FileHeader` 는 4 KiB 보다 작아 mini stream 에 있으므로 miniFAT 사슬을 따라간다.
  sector 사슬이 돌거나 범위를 벗어나면 깨진 컨테이너다. 시험 표에는 정상·잘림·순환 사슬·이름 없음을 넣는다.

암호는 구조의 bit 로 판별한다. 문자열이나 변환기 오류 메시지로 판별하지 않는다.

| 형식 | 암호 표시 | 출처 |
|---|---|---|
| OOXML(DOCX·XLSX·PPTX) | ZIP 이 아니라 CFB 이고 `EncryptionInfo`·`EncryptedPackage` stream 이 있다 | [MS-OFFCRYPTO] |
| DOC | `WordDocument` FibBase 의 `fEncrypted` bit | [MS-DOC] FibBase |
| XLS | `Workbook` globals 의 BOF 다음에 `FilePass`(0x002F) 레코드가 있다 | [MS-XLS] FilePass |
| PPT | `Current User` stream 의 `headerToken` 이 `0xF3D1C4DF` | [MS-PPT] CurrentUserAtom |
| HWP | `FileHeader` 속성의 암호 bit | 한글 문서 파일 형식 5.0 |
| HWPX | 확인 필요. 공개 표본으로 manifest 의 암호 표시를 확인한 뒤 L2 에서 정한다 | — |

bit 위치는 L2 가 명세와 생성 표본으로 시험 표에 고정한다. HWPX 의 판별을 정하지 못하면 이 RFC 를 고친다.

wire MIME 은 IANA 등록 값을 쓴다. HWP 와 HWPX 는 IANA 에 등록된 값이 없다
([libmagic 논의](https://bugs.astron.com/view.php?id=467)).
그래서 HWPX 는 파일이 스스로 적는 `application/hwp+zip` 을, HWP 는 `application/x-hwp` 를 쓴다.

클라이언트는 문서의 MIME 을 확장자로 정하지 않는다.
Dashboard 와 TUI 는 문서를 `application/octet-stream` 으로 보내고, 서버가 판별한다(`attachment_store.ml:1310`).
그래서 이름과 내용이 달라도 `Mime_mismatch` 가 나지 않는다.
Dashboard 허용 목록과 고르기 창의 `accept` 는 아홉 형식의 확장자를 「보여 줄 파일」로만 쓴다.
TUI 의 `has_supported_media_extension` 은 붙여 넣은 경로가 첨부 후보인지 고르는 데만 남긴다.
확장자 목록은 `media_format` 의 형식 표에서 만든다. MIME 짐작 함수 `extension_mime_opt` 는 지운다.

새 `put_error` 는 `Encrypted_document of document_format option` 하나다.
암호 걸린 OOXML 은 안을 열기 전에는 DOCX·XLSX·PPTX 를 구별할 수 없어서 `None` 이다.

### 3.2 변환기: 호스트 mount 없는 컨테이너

변환은 서버가 띄우는 컨테이너 `masc-document-renderer` 에서 돈다.
LibreOffice 를 호스트에서 돌리지 않는다. 문서 안의 외부 링크·OLE·매크로가 네트워크와 파일 시스템에 닿을 수 있어서다.

**이미지와 설치**

- masc 가 이미지 입력(Dockerfile 과 worker)을 들고 있다. Exact worker package 와 같은 방식이다(`lib/exact_addon_setup.mli:1-12`).
- 담는 것: LibreOffice(writer·calc·impress), Poppler, pandoc, `fonts-nanum`·`fonts-noto-cjk`, rhwp CLI.
- rhwp 는 소스에서 빌드하지 않는다. 소스 빌드는 이 맥에서 41분, 최대 메모리 8.5 GiB 였다(§4.2).
  upstream 이 릴리스마다 내는 Linux 바이너리(x86_64·aarch64)를 판 번호로 고정해 받는다.
  받은 파일은 같은 릴리스의 `SHA256SUMS.txt` 와 Dockerfile 에 적은 digest 로 확인한다. 다르면 이미지 빌드가 실패한다.
  릴리스 바이너리에 PNG 출력(`native-skia`)이 들어 있는지는 L3 에서 확인한다.
- rhwp 는 없는 글꼴을 CDN 에서 받으려 한다. 이미지 안에서는 `RHWP_WEBFONT_OFFLINE=1` 과 `--font-path` 로 이미지 글꼴만 쓴다.
  rhwp 가 원래 받던 글꼴(함초롬 등)을 이미지에 넣어도 되는지는 라이선스를 L3 에서 확인한다. 못 넣으면 다른 글꼴로 그려 모양이 달라진다.
- 설치는 운영자가 `masc document-renderer-setup` 으로 한다. 이미지에는 입력 digest label 을 붙이고, 같은 label 이면 다시 빌드하지 않는다.
- 실행은 `--pull never` 다. 이미지가 없으면 `Unavailable Image_missing` 이다.
  Dashboard 는 「문서 변환기가 설치되지 않았습니다」와 설치 명령을 보여 준다.

**격리**

- 격리 인자는 Lane Add-on 과 같다: `--network none`, `--read-only`, `--cap-drop ALL`, cpu·memory·pids 제한.
  memory 는 2 GiB 다. rhwp 의 PNG 출력이 최대 1,249 MB 를 썼다(§4.2). LibreOffice 의 최대 메모리는 L3 에서 컨테이너 안에서 잰다.
  L3 에서 이 인자를 `Lane_addon_engine.create_arguments`(`lane_addon_engine.ml:66-91`)에서 함수로 꺼내 둘이 같이 쓴다.
  workdir `/addon` 과 package mount 는 Lane Add-on 쪽에만 남긴다.
- 호스트 디렉터리는 하나도 붙이지 않는다. 지금 bind mount 는 읽기 전용뿐이다(`lane_addon_engine.ml:55-64`).
- 입력: 원본 바이트를 stdin 으로 넣는다. 형식은 §3.1 의 variant 이름을 인자로 넘긴다. 변환기 안에서 형식을 다시 짐작하지 않는다.
- 작업 공간: 크기를 정한 tmpfs `/tmp`. LibreOffice profile 과 중간 파일이 여기에 있다.
  Docker 는 `--tmpfs` 를 쓴다. Apple container 의 tmpfs 지원은 L3 에서 확인한다. 없으면 이 절을 다시 연다.
- 출력: worker 가 결과를 tar 하나로 묶어 stdout 으로 낸다.

**호스트 검증**

- stdout 은 `render_output_max_bytes` 까지만 읽는다. 넘으면 컨테이너를 지우고 `Refused Output_too_large` 다.
- tar 항목은 일반 파일만 받는다. symlink·hard link·장치·디렉터리 밖 경로(`..`, 절대 경로)가 하나라도 있으면 `Output_invalid` 다.
- 이름은 닫힌 집합이다. 변환은 `manifest.json`·`document.pdf`·`page-1.png`·`text.md`, 페이지 그리기는 `page-<n>.png` 하나다.
- manifest 는 typed decoder 로 읽는다. PDF·PNG 는 `media_format` 으로 판별하고, `text.md` 는 UTF-8 인지 본다.
  manifest 의 페이지 목록은 비어 있지 않아야 하고, `page <n>` 의 n 은 그 목록 안이어야 한다.
  하나라도 어긋나면 `Output_invalid` 이고 아무것도 저장하지 않는다.

**문서 탓과 변환기 탓을 가른다**

- 변환 도구가 정상 종료하면서 실패를 알렸을 때만 worker 가 manifest 에 refusal 을 적는다.
  예를 들면 non-zero exit 이고 signal 이 아니며, 결과 파일이 없는 경우다.
- 도구가 signal 로 끝났거나(메모리 초과 포함) worker 가 manifest 를 쓰지 못했으면 `Unavailable` 이다.
- 그래서 메모리 초과가 「문서가 깨졌다」로 영구 저장되지 않는다.

**한 번에 하나**

- 서버는 변환을 한 번에 하나씩 돌린다. 나머지는 도착한 순서로 기다린다.
  LibreOffice 는 문서마다 메모리를 크게 쓰고, 개인 서버에서 동시 변환 수를 조정할 값을 따로 두지 않기 위해서다.
- 같은 (원본, 변환기 판) 요청은 한 번만 돈다(single-flight).
- 서버가 시작할 때 변환기 scope label 이 붙은 컨테이너를 지운다(`Lane_addon_engine.scoped_list_arguments`).
  호스트에 작업 디렉터리가 없으므로 남는 파일도 없다.

**멈춘 변환기**

- 변환 하나에는 안전 경계로 `render_wall_clock_bound` 가 있다. 넘으면 컨테이너를 지우고 `Unavailable Timed_out` 이다.
  헌법 `budget_gate` 는 안전·자원 경계를 금지 대상에서 뺀다. 이 값은 Keeper 행동을 제한하지 않는다.
  깨진 문서 하나가 서버 변환 줄과 그 문서를 읽는 Keeper 턴을 끝없이 막지 않게 한다.
- `render_wall_clock_bound` 는 300초다. §4 에서 가장 오래 걸린 정상 실행은 178쪽 HWP 의 PDF 출력 97.4초다. 그 세 배쯤으로 잡았다.
- `render_output_max_bytes` 는 128 MiB 다. 가장 큰 출력은 178쪽 HWP 의 96 DPI PNG 전체 21.5 MB 였다.
  110 DPI 로 그리면 약 28 MB 가 된다. 그 네 배쯤으로 잡았다.
  출력이 이 값을 넘으면 같은 변환기 판에서는 같은 결과가 나오므로 `Refused Output_too_large` 로 남긴다.

**worker 동작 셋**

형식에 따라 무엇을 먼저 만들지가 다르다. 측정에서 비싼 단계가 형식마다 달랐기 때문이다(§4).

| 동작 | LibreOffice 형식·PDF | HWP·HWPX |
|---|---|---|
| `render` | PDF, 첫 페이지 PNG, `text.md`, manifest(쪽수·페이지 크기) | 모든 페이지 PNG(`export-png --dpi 110`), `text.md`, manifest |
| `page <n>` | 캐시된 PDF 에서 그 페이지 PNG 하나(`pdftoppm -r 110 -f n -l n`) | 쓰지 않는다 |
| `pdf` | 쓰지 않는다 | 원본 → PDF(`export-pdf`). `rendition.pdf` 를 요청할 때만 돈다 |

- LibreOffice 형식은 PNG 를 모두 만들지 않는다. 190쪽 시트를 모두 그리면 60초, 41 MB 가 든다.
  사람이 보는 페이지만 그때 그리고 캐시한다. 페이지 하나는 작은 문서에서 0.15초 안쪽이다.
- HWP 는 반대다. rhwp 의 PDF 출력은 178쪽에서 97.4초였고, 같은 문서의 PNG 전체는 8.7초, 글은 0.9초였다.
  그래서 PNG 와 글을 먼저 만들고, PDF 는 내려받기를 누를 때 만든다.
- 컨테이너를 띄우는 비용이 페이지 그리기보다 크면 `page <n>` 을 다시 본다. L3 에서 Docker 와 Apple container 둘 다 잰다.
- worker 는 도구가 0 으로 끝났을 때만 결과를 묶는다. rhwp `export-png` 는 한 페이지가 실패해도 나머지를 쓰고 non-zero 로 끝난다.
  이때 일부만 쓴 페이지를 내보내지 않는다.

| 형식 | PDF | 글(`text.md`) |
|---|---|---|
| HWP·HWPX | rhwp `export-pdf`(요청할 때) | rhwp `export-text` 의 쪽별 글을 순서대로 이어 `## <n>쪽` 절로 나눈다. `export-markdown` 은 병합 칸을 빈 열로 늘리고 그림 파일을 183 MB 까지 써서 쓰지 않는다 |
| DOC·DOCX | `soffice --convert-to pdf` | `soffice --convert-to "txt:Text (encoded):UTF8"`. 앞의 BOM 을 지운다. 표의 행은 탭으로 나뉜다 |
| XLS·XLSX | 같음 | 시트마다 CSV(필터 인자의 시트 번호 `-1`)로 뽑아 `## <시트 이름>` 과 Markdown 표로 바꾼다. 수식 칸은 계산된 값이다 |
| PPT·PPTX | 같음 | 변환한 PDF 에 `pdftotext -layout`. 쪽 나눔(form feed)마다 `## 슬라이드 <n>` 절로 나눈다 |
| PDF | 원본 그대로 | 만들지 않는다. 지금의 `builtin.pdf_text` reader 를 쓴다 |

슬라이드의 발표자 노트는 이 경로로 나오지 않는다(§7).

한국어 글꼴은 이미지 안의 `fonts-nanum`·`fonts-noto-cjk` 로 그린다.
글꼴이 없으면 PDF·PNG 에서 한글이 빈칸이 되는데, `pdftotext` 는 글을 그대로 뽑아 글만 보는 검사를 통과한다(§4).
그래서 L3 시험은 한국어 표본의 출력 PDF 에 CJK 글꼴이 실렸는지 `pdffonts` 로 본다.
글꼴이 바뀌면 쪽수도 바뀐다(32쪽 → 60쪽). 글꼴 패키지는 이미지 digest 에 묶여 변환기 판의 일부가 된다.

### 3.3 변환 결과는 파생 캐시다

```ocaml
type renderer =
  { runtime : Lane_addon_types.runtime
  ; image_digest : string        (* Lane_addon_engine.image_digest 로 얻은 값 *)
  ; revision : string }          (* worker 계약의 판 *)

type page_box = { index : int; width_pt : float; height_pt : float }   (* pdfinfo 가 준 크기 *)

type page_image = { index : int; png_sha256 : string; width_px : int; height_px : int }

type text_source =
  | Extracted of { sha256 : string }
  | Builtin_pdf_reader            (* PDF: 글은 기존 reader 가 읽는다 *)

type pages =
  | From_pdf of { boxes : page_box list; first : page_image }   (* 나머지는 볼 때 그린다 *)
  | Prerendered of { images : page_image list }                 (* HWP·HWPX *)

type pdf =
  | Pdf_ready of { sha256 : string }
  | Pdf_on_request                                              (* HWP·HWPX *)

type rendition = private
  { source_sha256 : string
  ; renderer : renderer
  ; format : Attachment_store.document_format
  ; pages : pages                (* 목록은 비어 있지 않다 *)
  ; pdf : pdf
  ; text : text_source }
(* 생성자가 짝을 막는다:
   Hwp·Hwpx 이면 Prerendered + Pdf_on_request + Extracted,
   Pdf 이면 From_pdf + Pdf_ready + Builtin_pdf_reader,
   나머지는 From_pdf + Pdf_ready + Extracted. *)

type refusal =                   (* 문서 자체의 문제. 같은 변환기 판에서는 다시 돌리지 않는다 *)
  | Corrupt of { evidence : string }
  | Empty_document
  | Output_too_large of { bytes : int }

type unavailable =               (* 변환기 쪽 문제. 저장하지 않는다. 다음 요청이 다시 돌린다 *)
  | Engine_unreachable of Lane_addon_lifecycle.engine_fault
  | Image_missing
  | Spawn_failed of string
  | Timed_out
  | Output_invalid of string
  | Cancelled

type outcome = Rendered of rendition | Refused of refusal | Unavailable of unavailable
```

- 암호는 업로드에서 거절하므로 `refusal` 에 없다. LibreOffice 는 암호 문서와 잘린 문서에 똑같이 rc 1 과 같은 stderr 를 낸다(§4). 그래서 변환기 결과로는 둘을 가를 수 없다.
- 그 밖의 페이지 PNG 는 `page_image` 로 rendition 옆에 캐시한다. 페이지 그리기의 실패도 같은 `refusal`·`unavailable` 로 나눈다.
- 변환을 부르는 함수는 `document_format` 을 받는다. 그 값은 `Document` meta 에서만 나온다.
  그래서 문서가 아닌 첨부는 변환기에 닿을 수 없다. HTTP 는 그런 첨부에 `415 not_a_document` 를 준다.
- `renderer` 는 자기 JSON codec 을 갖는다. `Lane_addon_engine.image_identity` 는 decoder 가 없는 추상 타입이라 저장하지 않는다.
- 위치는 `.masc/attachments/renditions/<aa>/<source_sha256>/<renderer_key>/` 다. 지금의 `thumbs/` 와 같은 캐시다.
  원본과 변환기 판만 있으면 언제든 다시 만들 수 있으므로 authority 가 아니다.
- `Refused` 는 그 변환기 판의 manifest 로 남긴다. `Unavailable` 은 남기지 않는다.
- 정리:
  - Attachment GC 가 원본을 지울 때 그 원본의 `renditions/<aa>/<sha>/` 도 지운다.
    `Keeper_media_reading_maintenance` 가 원본 없는 reading 을 지우는 규칙과 같다.
  - 지금 설치된 변환기 판과 다른 옛 결과도 GC 가 지운다. 시간이 지났다는 이유로는 지우지 않는다.

### 3.4 HTTP

기존 `/api/v1/attachments/<id>` 아래에 붙인다. 권한과 ephemeral 범위는 지금의 `read_permission` 을 그대로 따른다.
모든 응답은 지금 첨부 응답의 머리글을 그대로 쓴다:
`X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'none'; sandbox`, 내용 digest `ETag`, `immutable` 캐시
(`server_routes_http_routes_attachments.mli:11-17`).

| 경로 | 응답 |
|---|---|
| `GET …/<id>/rendition` | `outcome` JSON: 쪽수, 페이지별 크기, 실패 이유 |
| `GET …/<id>/pages/<n>` | 페이지 PNG. 캐시에 없으면 그때 그린다. `?max_px=` 는 지금의 bucket 규칙으로 줄인다 |
| `GET …/<id>/rendition.pdf` | 변환한 PDF. HWP·HWPX 는 이때 `pdf` 동작을 돌린다. `?download=1` 이면 원본 이름 뒤에 `.pdf` 를 붙인다 |
| `GET …/<id>/text` | `text/markdown; charset=utf-8`. PDF 는 `404`(글은 Keeper reader 가 읽는다) |

변환이 아직이면 `GET …/rendition` 은 변환이 끝날 때까지 기다렸다가 답한다.
기다림의 끝은 §3.2 의 `render_wall_clock_bound` 와 클라이언트 연결 끊김이다.
상태 문자열을 주기적으로 묻는 polling 계약은 만들지 않는다.

### 3.5 Keeper 가 읽는다

`Keeper_media_reading.production_readers` 의 `Document` 경우를 `document_format` 으로 나눈다.

- `Pdf` 는 지금의 `builtin.pdf_text` 다. 64쪽 상한도 그대로다.
- 나머지 여덟 형식은 `builtin.document_text` 다. identity 의 revision 은 `renderer` 의 image digest 와 `revision` 이다.
  읽기는 §3.3 의 `text.md` 다. 변환기 판이 바뀌면 옛 reading 을 다시 쓰지 않는다.
- 이 reader 는 서버가 소유한 변환기를 쓴다. Keeper sandbox 안의 외부 실행이 아니므로 Gate 승인을 거치지 않는다.
  지금의 PDF reader 가 호스트 `pdftotext` 를 Gate 없이 부르는 것과 같은 자리다.
  선언된 외부 reader 가 있으면 지금처럼 그것이 먼저다(`keeper_media_reading.ml:551-562`).
- reader 는 Keeper 턴 안에서 돈다. 그 턴이 기다리는 시간의 끝은 §3.2 의 경계다.

모델이 문서 원본을 직접 받는 경로(PDF native block)는 바꾸지 않는다.
DOCX 처럼 모델이 받지 못하는 형식은 지금의 「원본을 못 받는 후보」 경로로 reading 이 들어간다.

### 3.6 클라이언트

- Dashboard: 문서 카드가 `GET …/pages/1?max_px=320` 썸네일과 쪽수를 보여 준다.
  누르면 페이지 보기가 열린다. 세로로 넘기고, 화면에 보이는 페이지만 불러오고, 원본과 PDF 를 받을 수 있다.
  카드는 [workspace-chat-media-renders-where-it-is-written](RFC-workspace-chat-media-renders-where-it-is-written.md) L4 의 `attachment-cards.ts` 에 더한다.
  인증 blob 캐시(`workspace-media-cache.ts`)를 그대로 쓴다. 새 렌더링 의존성은 없다.
- `Unavailable Image_missing` 이면 카드는 다운로드 단추와 「문서 변환기가 설치되지 않았습니다」를 보여 준다.
- TUI: 문서 블록이 첫 페이지 PNG 를 `Document_graphics` 로 그린다. `/page <n>` 은 그 블록의 페이지를 바꾼다.
  채팅 본문의 문서 embed 는 `embed_shown` 의 `Embed_document of { label; attachment }` 로 받는다.

## 4. 측정

### 4.1 LibreOffice (11-28, 이 맥)

LibreOffice 26.8.0.3, pandoc 3.9.0.2, Poppler 26.03.0 이다. 입력은 모두 pandoc·LibreOffice 로 만든 합성 표본이고 한국어 문장이 들어 있다.
실행마다 profile 을 따로 썼다. 표는 세 번 잰 값의 중앙값이다. 측정 중 부하 평균이 15~22 였다.

| 표본 | 새 profile 초 | 데운 profile 초 | 쪽 | PDF |
|---|---|---|---|---|
| 문서 작은 것 .docx / .doc | 3.6 / 3.6 | 2.1 / 2.1 | 1 | 54 KB |
| 문서 큰 것 .docx / .doc | 3.5 / 4.0 | 2.7 / 2.3 | 32 | 1.5 MB |
| 시트 작은 것 .xlsx / .xls | 2.0 / 1.8 | 1.3 / 1.0 | 1 | 53 KB |
| 시트 큰 것 .xlsx / .xls | 15.7 / 38.5(부하 평균 182) | 12.8 / 15.2 | 190 | 16.3 MB |
| 슬라이드 작은 것 .pptx / .ppt | 2.5 / 2.5 | 2.1 / 1.0 | 3 | 33 KB |
| 슬라이드 큰 것 .pptx / .ppt | 4.5 / 3.7 | 3.1 / 2.1 | 40 | 575 KB |

- **한국어 글꼴**: 이 맥의 LibreOffice 는 시스템 글꼴을 보지 못했다. 그래서 어느 PDF 에도 CJK 글꼴이 없었고, 한글이 PDF·PNG 에서 빈칸이었다.
  `pdftotext` 는 그래도 한글을 그대로 뽑았다. `FONTCONFIG_FILE` 로 시스템 글꼴을 보이게 하자 글자가 그려졌고, 문서 큰 것이 32쪽에서 60쪽이 됐다.
- **PDF → PNG**: `pdftoppm -r 110` 은 작은 표본에서 0.13~0.15초, 40쪽 슬라이드에서 2.6~2.9초, 190쪽 시트에서 59~61초(41 MB)였다.
  `soffice --convert-to png` 는 첫 페이지만 쓴다.
- **글 뽑기**: 어느 방법도 한글을 깨뜨리지 않았다(U+FFFD 0개).
  - 문서는 `txt:Text (encoded):UTF8` 이 문장 60개를 모두 찾았다.
  - 시트는 그냥 `csv` 이면 첫 시트만 나왔다(문장 3/15). 시트 번호 `-1` 필터 인자를 쓰니 15/15 였다.
  - 슬라이드는 `txt` 변환이 rc 1 로 실패했다. 변환한 PDF 의 `pdftotext -layout` 이 40/40 을 찾았다. 발표자 노트는 없었다.
- **profile 공유**: 문서 큰 것 넷을 동시에 돌렸다.
  - profile 을 하나로 같이 쓰면 12건 중 6건이 rc 1 로 끝났다. PDF 도 없었고 stderr 에도 아무것도 없었다.
  - profile 을 따로 쓰면 12/12 가 2.9~3.2초에 끝났다.
- **깨진 입력**(60초 상한, 멈춘 것은 없었다):
  - 잘린 DOCX, 이름만 바꾼 zip, 암호 DOCX·XLSX·DOC 는 1초 안에 rc 1 로 끝났다. stderr 는 모두 `source file could not be loaded` 였다.
  - 아무 바이트를 넣은 `.xlsx` 는 rc 0 이었고, 7쪽짜리 쓰레기 PDF 를 만들었다.
  - 0 바이트 `.docx` 는 rc 0 이었고, 빈 1쪽 PDF 를 만들었다.
  - 이 둘은 업로드 판별(§3.1)과 `Empty_payload` 가 변환 전에 막는다.
- **이름이 틀린 파일**: `.xlsx` 라는 이름의 DOCX 도 LibreOffice 는 내용대로 바꿨다.
- **stderr**: stderr 에는 늘 Fontconfig 경고가 있다. 비어 있지 않은 stderr 는 실패 표시가 아니다. evidence 로만 남긴다.
- **판별**:
  - OOXML 셋은 `50 4B 03 04` 로 시작하고 `[Content_Types].xml` 의 main part 형식으로 갈린다.
  - DOC·XLS·PPT 는 `D0 CF 11 E0 A1 B1 1A E1` 로 시작하고 stream 이름으로 갈린다.
  - 암호 OOXML 은 `EncryptionInfo`·`EncryptedPackage` stream 만 있었다. 암호 DOC 는 FIB 의 0x0A 위치에서 0x0100 bit 가 켜져 있었다.
  - `file --mime-type` 은 잘린 DOCX 를 DOCX 로 잘못 봤다.

측정에 쓴 스크립트와 원자료는 PR 본문에 붙인다. 저장소에는 넣지 않는다.
실제 Office 문서(차트, SmartArt, OLE, 매크로)는 재지 않았다. L3 이 공개 표본으로 잰다.

### 4.2 rhwp

upstream `main` 의 `981ce66b41`(v0.9.1, 11-18)을 이 맥에서 빌드해 쟀다. 표본은 저장소 안의 공개 표본만 썼다.
세 번 잰 값의 중앙값이다. 측정 중 부하 평균이 18~24 였다. PNG 는 96 DPI 다.

| 표본 | 쪽 | PDF 초 / MB | PNG 전체 초 / MB | 글 초 |
|---|---|---|---|---|
| BlogForm_BookReview.hwp (24 KB) | 1 | 0.81 / 0.02 | 2.98 / 0.07 | 0.01 |
| KTX.hwp (66 KB) | 1 | 3.59 / 13.4 | 3.19 / 0.31 | 0.02 |
| hwpspec.hwp (2.7 MB) | 178 | 97.4 / 9.4 | 8.66 / 21.5 | 0.86 |
| k-water-rfp.hwp | 27 | 19.1 / 2.6 | 4.83 / 5.3 | 0.12 |
| exam_kor.hwp (10.4 MB) | 20 | 19.0 / 7.5 | 7.03 / 9.2 | 0.35 |
| business_overview.hwpx | 1 | 1.33 / 0.05 | 2.26 / 0.14 | 0.02 |
| form-002.hwpx | 10 | 11.9 / 0.85 | 4.37 / 2.6 | 0.16 |
| k-water-rfp.hwpx | 27 | 18.6 / 2.6 | 6.64 / 5.3 | 0.18 |
| exam_kor.hwpx | 20 | 22.8 / 7.5 | 8.75 / 9.2 | 0.29 |

- **명령**: `export-pdf`, `export-png`(쪽마다 파일 하나, `--dpi`), `export-text`(쪽마다 `.txt`), `export-markdown`, `info --json`(쪽수).
- **메모리**: 최대 RSS 는 PDF 150~835 MB, PNG 455~1,249 MB, 글 16~241 MB 였다.
- **고정 비용**: PNG 는 한 쪽짜리도 2~3초가 든다.
- **깨진 입력**: 1 KB·절반 잘린 HWP·HWPX, 이름만 바꾼 README·PNG·zip 을 모든 출력 명령에 넣었다. 모두 종료 코드 1 이었고, stdout 과 출력 파일이 없었다.
- **매번 같은지**: 같은 글꼴이면 세 번 모두 바이트까지 같았다. PDF 에 만든 시각이 들어가지 않는다.
- **글꼴**: 없는 글꼴은 `cdn.jsdelivr.net` 에서 받아 캐시한다(첫 실행에 4개, 약 36 MB).
  `RHWP_WEBFONT_OFFLINE=1` 이면 받지 않는다. 이때도 종료 코드는 0 이지만 다른 글꼴로 그려 바이트가 달라진다. 글은 같다.
- **HWP ↔ HWPX**: `export-hwpx`(178쪽 0.92초)와 `convert`(HWPX → HWP)가 있다. 쪽수가 유지되고 결과가 매번 같았다.
- **빌드**: `cargo build --release --locked --features native-skia` 가 41분 23초, 최대 메모리 8.5 GiB 였다. 바이너리는 63.6 MB 다.
- **`--backend direct`**: 일부 표본에서 「cannot replay line without visual loss」로 거절했다. 기본 svg backend 를 쓴다.
- 모두 macOS 에서 잰 값이다. Linux 컨테이너에서는 글꼴이 달라 L3 에서 다시 잰다.

## 5. 헌법과 맞추기

- `closed_sum_over_string`: `document_format`, `text_source`, `refusal`, `unavailable` 이 닫힌 합이다.
  `"application/pdf"` 비교 세 곳을 variant `match` 로 바꾼다. 암호는 구조 bit 로 판별한다.
- `strict_parse_no_default`: 판별하지 못한 컨테이너는 `None` 이다. 확장자나 선언 MIME 으로 메우지 않는다.
- `failure_keeps_evidence`: `Corrupt` 는 변환기 stderr 를 evidence 로 갖는다. 실패한 출력은 저장하지 않는다.
- `no_wall_clock_death`: 캐시는 원본이 없어질 때와 변환기 판이 바뀔 때만 지운다.
- `budget_gate`: `render_wall_clock_bound`, `render_output_max_bytes`, `package_part_max_bytes` 는 안전·자원 경계다. Keeper 행동을 제한하지 않는다.
- `libraries`: LibreOffice, rhwp, Poppler, pandoc, `zipc`, `markup` 을 쓴다. 새로 만드는 것은 CFB reader 뿐이다.
- 번들: Dashboard 에 변환 라이브러리를 넣지 않는다. 배포 자산과 첫 화면 `index.js` gzip 바이트를 `main` 과 비교해 PR 에 남긴다.

## 6. Stack 계획

| 층 | 범위 | 확인 |
|---|---|---|
| L1 | 이 RFC, §4 측정값 | `python3 scripts/rfc-generate-index.py --check` |
| L2 | `media_format`(ZIP·CFB 판별, 암호 bit), `document_format`, `Encrypted_document`, MIME 문자열 비교 세 곳 교체. `zipc` 를 `dune-project`·`masc.opam`·`masc.opam.locked` 에 더한다 | PR `type-check`, 생성 표본과 깨진 표본의 시험 표 |
| L3 | 이미지 입력과 worker(`render`·`page`), `masc document-renderer-setup`, 격리 인자 함수 분리, tar 검증, 실행 | PR `type-check`, 이미지 빌드 workflow, 표본 열두 개 변환 결과, 한국어 표본의 `pdffonts` CJK 글꼴, Docker·Apple container 기동 비용 |
| L4 | rendition·페이지 캐시, single-flight·순서 대기, 시작 시 정리, GC 연결, HTTP 네 경로 | PR `type-check`, 캐시·GC 시험 |
| L5 | `builtin.document_text` reader | PR `type-check`, reader identity 와 캐시 재사용 시험 |
| L6 | Dashboard: 문서를 `octet-stream` 으로 보내기, 허용 목록, 문서 카드·페이지 보기. chat-media L4 뒤에 쌓는다 | `pnpm typecheck`, vitest, 배포 자산·첫 화면 `index.js` 비교 |
| L7 | TUI: `media_format` 판별, `extension_mime_opt` 삭제, 문서 블록·`/page`, `Embed_document` | PR `type-check` |

## 7. 범위 밖

- 원본 서식을 지키며 DOCX·XLSX·PPTX 를 그 자리에서 고치기. 공동 작성은 원고에서 하고 형식으로 내보낸다.
- 매크로가 든 문서, ODF(ODT·ODS·ODP), HWP 3.0 이하.
- 슬라이드의 발표자 노트를 글로 뽑기.
- HWP ↔ HWPX 로 바꿔 받기. rhwp 에 `export-hwpx`·`convert` 가 있고 빠르다(§4.2). 필요하면 따로 정한다.
- 모델에게 페이지 그림을 보여 주는 도구. 글 읽기로 모자란 사례가 쌓이면 따로 정한다.
