---
rfc: "workspace-documents-are-written-together"
title: "Workspace Documents Are Written Together"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: vincent
related: ["workspace-documents-arrive-as-pages-and-text", "workspace-chat-media-renders-where-it-is-written", "workspace-media-and-rich-embed"]
---

# RFC workspace-documents-are-written-together: 사람과 Keeper 가 같은 문서를 함께 쓴다

## 0. 요약

지금 사람은 Dashboard 에서 아티팩트를 읽고, 복사하고, 내려받을 수만 있다. 고칠 수는 없다.
Keeper 는 `keeper_artifact_draft` 로 원고를 고친다. #55387 본문 기준으로 10-28~11-27 에 462번 불렸다.
그 원고의 상태는 Yjs CRDT 다. Yjs 를 다루는 외부 실행 파일 `masc-artifact-document` 의 소스는 11-24 #54560 에서 지워졌다.
이 맥에는 11-02 에 설치한 묶음(`artifact-document.mjs`, 579 KB)이 남아 있어서 도구가 돈다.
새로 설치한 곳에서는 그 실행 파일을 만들 수 없다.

stack #55383~#55387 은 부르는 화면이 없는 원고 HTTP 라우트, 실시간 방, Keeper 편집 위치를 지운다.
이 RFC 는 그 stack 이 병합된 뒤를 전제로, 공동 작성을 처음부터 다시 정한다.

## 1. 결과

- 사람이 Dashboard 에서 아티팩트 원고를 열어 고치고, Keeper 가 같은 원고를 도구로 고친다. Markdown 과 HTML 아티팩트 모두다.
- 둘이 동시에 고쳐도 한쪽이 조용히 덮어쓰지 않는다.
  - 겹치지 않는 수정은 합쳐진다.
  - 겹치는 수정은 아무것도 쓰지 않고 양쪽 내용을 돌려준다.
  - 사람은 화면에서 고르고, Keeper 는 다음 도구 호출에서 고른다.
- 사람이 문장에 댓글과 바꿀 문장을 달고, Keeper 가 받아들이거나 거절한다. 반대 방향도 같다.
- 게시하면 지금처럼 바뀌지 않는 리비전이 된다.
- DOCX·XLSX·PPTX·PDF 로 내보낸다. HWPX 내보내기는 §4.5 의 확인 결과에 달렸다.
- HWP 원본을 HWP 그대로 고치는 길은 §5 의 별도 트랙이다.

## 2. 무엇이 실제로 동시에 일어나나

동시 편집 엔진을 고르기 전에 실제 쓰임을 본다.

- Keeper 의 수정은 도구 호출 단위다. 글자 단위로 타이핑하지 않는다. 한 호출은 「이 문장을 이것으로」다.
- 사람의 수정은 편집기에서 저장할 때 한 덩어리로 도착한다.
- 실시간 커서·참여자 표시는 11-24 에 화면이 빠진 뒤 받는 곳이 없다. #55387 이 지운다.

수정이 덩어리로 오므로, 글자 단위 CRDT 가 아니어도 덮어쓰기를 막을 수 있다.

## 3. 엔진: 두 안

| | A. 텍스트 리비전 + 3-way 병합 (권장) | B. Yjs 변환기 소스를 저장소로 되살림 |
|---|---|---|
| 정본 | 원고 원문 문자열과 리비전 번호 | Yjs 상태(바이너리)와 리비전 |
| 동시 수정 | 리비전이 다르면 공통 조상·내 것·지금 것으로 3-way 병합한다. 겹치는 구간은 충돌로 돌려준다 | CRDT 가 자동 병합한다. 겹쳐도 한 결과로 수렴한다 |
| 위치 기준 | 댓글은 인용문과 앞뒤 문맥으로 다시 찾는다. 못 찾으면 「자리 잃음」 상태가 된다 | Yjs 상대 위치 |
| 실행 | OCaml 안. 외부 프로세스 없음 | Node 실행 파일. 30초 상한의 외부 프로세스(`artifact_document_engine.ml:55`) |
| 실시간 | 없음. 저장할 때 합친다 | 나중에 붙일 수 있다 |
| 비용 | 새 OCaml 모듈(diff3), 원고 저장 형식 hard cut | JS 빌드와 설치 경로를 다시 들인다. 11-24 에 뺀 의존성의 일부가 돌아온다 |

A 를 권한다. 수정이 덩어리로 오고, 지금 받는 곳이 없는 실시간 표시를 위해 외부 런타임을 다시 들일 이유가 없다.
겹치는 수정을 조용히 수렴시키는 것보다 사람에게 보여 주는 편이 「덮어쓰지 않는다」에 맞다.
운영에서 충돌이 잦아 사람이 계속 골라야 한다는 기록이 쌓이면 그때 B 나 다른 CRDT 를 다시 본다.
이 판단은 기록을 보고 사람이 내린다. 런타임에 숫자로 엔진을 바꾸는 게이트는 두지 않는다.

**결정 필요**: A 와 B 중 하나. 아래는 A 를 기준으로 쓴다.

## 4. A 의 설계

### 4.1 원고와 저장

```ocaml
type target = { artifact_id : string; generation : string }   (* 지금 Artifact_draft.target 과 같다 *)

type draft = private
  { target : target
  ; revision : int                         (* 저장마다 1 증가 *)
  ; base_publication : int                 (* 이 원고가 출발한 게시 리비전 *)
  ; format : Published_artifact.format     (* Markdown | Html *)
  ; content : string
  ; updated_by : string
  ; updated_at : string }

type hunk =
  | Same of string
  | Changed of { base : string; ours : string; theirs : string }

type save_result =
  | Saved of draft
  | Merged of { draft : draft; merged_from : int }          (* 겹치지 않아 합쳤다 *)
  | Conflict of { current : draft; hunks : hunk list }      (* 아무것도 쓰지 않았다 *)
  | Generation_changed of { current : target }              (* 원고가 지워지고 다시 만들어졌다 *)
```

저장은 `expected : { target; revision }` 을 받고, 원고 하나에 대해 원자적으로 한 번에 커밋한다.

1. `generation` 이 다르면 `Generation_changed` 다. 지웠다 다시 만든 원고의 리비전 번호가 우연히 맞아도 섞이지 않는다.
2. `revision` 이 지금과 같으면 `Saved` 다.
3. 다르면 `expected.revision` 의 원문을 공통 조상으로, 새 원문과 지금 원문을 3-way 병합한다.
   겹치지 않으면 `Merged`, 겹치면 `Conflict` 다.

`Conflict` 는 지금 원고 전체(`current`)를 돌려준다. 호출자는 고른 결과를 `expected.revision = current.revision` 으로 다시 저장한다.
그사이 다른 저장이 끼어들었으면 3번이 다시 돈다. 끼어든 저장이 조용히 사라지는 길은 없다.

- 저장소는 원고 리비전마다 원문을 내용 주소 blob 으로 남긴다. 그래야 공통 조상을 언제든 읽는다.
- 리비전 원문은 원고를 지울 때 같이 지운다. 시간이 지났다는 이유로는 지우지 않는다.
- 병합은 줄 단위다. HTML 도 원문 텍스트로 병합한다. 병합한 HTML 이 게시 검증을 통과하는지는 게시할 때 지금처럼 본다.

### 4.2 댓글과 제안

`Artifact_discussion` 의 명령(comment·reply·resolve·reopen·accept·reject)과 사건 기록은 그대로 둔다.
위치만 Yjs 좌표에서 `{ quote; prefix; suffix }` 로 바꾼다.
받아들이면 그 자리를 다시 찾아 바꾼 원문을 4.1 의 저장으로 쓴다.
자리를 못 찾으면 `Anchor_lost` 로 남기고 사람이 고른다. 가장 비슷한 곳을 추측해 바꾸지 않는다.

### 4.3 Keeper 도구

#55387 뒤 `keeper_artifact_draft` 의 동작은 find·published·open·read·select·resolve·edit·discuss·checkpoint 다.
이 RFC 는 select 와 도구 동작 resolve 를 지운다. 둘 다 Yjs 위치를 다루던 동작이다.
토론 명령 resolve(스레드 닫기)는 discuss 안에 그대로 남는다.

| 동작 | 바뀌는 것 |
|---|---|
| find·published·open·read | 그대로. read 는 `revision` 과 `generation` 을 같이 돌려준다 |
| edit | `expected`(target·revision)를 받는다. 원문 전체(`content`) 또는 `replace { quote; prefix; suffix; replacement }` 중 하나를 받는다. 결과는 4.1 의 `save_result` 다 |
| discuss | 위치를 `{ quote; prefix; suffix }` 로 받는다 |
| checkpoint | 그대로. 게시는 지금처럼 `keeper_artifact_publish` 가 하고, checkpoint 가 원고의 출발 게시 리비전을 옮긴다 |

`Conflict` 를 받은 Keeper 는 다음 호출에서 고른 결과를 다시 저장한다. 재시도 상한은 두지 않는다.

### 4.4 Dashboard

- Markdown 원고는 [workspace-media-and-rich-embed](RFC-workspace-media-and-rich-embed.md) L4 의 Wiki 편집기를 쓴다.
  분할 미리보기, embed 고르기, 붙여넣기 업로드가 이미 거기 있다.
- HTML 원고는 원문 편집과, 지금 아티팩트 화면의 sandbox iframe 미리보기를 쓴다.
- 저장 결과가 `Conflict` 면 `hunks` 의 `Changed` 를 양쪽으로 보여 주고 고르게 한다.
- 댓글은 선택한 문장에 붙인다.
- 새 무거운 편집기 의존성은 들이지 않는다.

### 4.5 내보내기와 가져오기

내보내기는 [workspace-documents-arrive-as-pages-and-text](RFC-workspace-documents-arrive-as-pages-and-text.md) §3.2 의 변환기 이미지에서 돈다.
그 worker 에 `export` 동작을 더한다. 격리와 호스트 검증은 같다.

| 형식 | 경로 |
|---|---|
| DOCX | pandoc |
| PPTX | pandoc |
| PDF | pandoc → DOCX → `soffice --convert-to pdf`. LaTeX 엔진을 들이지 않는다 |
| XLSX | 원고 안 표마다 CSV 로 뽑아 LibreOffice 로 한 시트씩 만든다. 표가 없으면 `No_table` 으로 거절한다 |
| HWPX | rhwp v0.9.1 의 `build-from-ingest`(ingest JSON 과 그림 → HWPX). 원고를 ingest JSON 으로 옮길 수 있는지는 L5 가 schema(`rhwp capabilities --search build-from-ingest`)를 읽고 정한다. 표나 그림을 잃으면 HWPX 는 범위 밖으로 둔다 |

- 결과는 새 첨부로 저장한다. 첨부 meta 는 바꾸지 않는다. meta 는 내용 digest 로 찾는 값이라 출처를 담을 자리가 아니다.
- 원고 기록이 `exports : { format; attachment_id; draft_revision } list` 를 갖는다.
- 가져오기: 첨부 문서의 추출 글(`GET …/text`)로 새 원고를 연다. 원본 첨부는 그대로 둔다.

### 4.6 저장 형식

원고 저장은 hard cut 이다. 기존 `.masc/artifact_drafts/` 의 Yjs 상태는 읽지 않는다. 변환 reader 를 만들지 않는다.
토론 사건 기록은 원고 안에 있다(`artifact_discussion.mli:1-2`). 그래서 기존 원고의 댓글 스레드도 함께 없어진다.
배포 노트의 Fresh state 항목에 둘 다 적는다. 게시된 아티팩트 리비전은 영향이 없다.

## 5. HWP 를 HWP 로 고치는 트랙

사람이 HWP·HWPX 문서 카드에서 「편집」을 누르면 rhwp 편집기(`@rhwp/editor`, WASM)를 그때 불러온다.

- 첫 화면 `index.js` 에 들어가지 않는 별도 chunk 다. 읽기·미리보기 변환은 여기서 하지 않는다.
- 저장하면 새 HWP·HWPX 바이트가 새 첨부가 된다. 원본 첨부는 그대로다.
- 새 첨부는 원본이 실린 자리(채팅 대화, Board 항목)에 「<원본 이름> 편집본」으로 새로 실린다.
  원본과의 관계는 그 메시지·항목 기록이 갖는다. 첨부 meta 는 바꾸지 않는다.
- 이 문서는 원고가 아니므로 4.1 의 병합을 받지 않는다. 두 사람이 동시에 열면 저장마다 새 첨부가 된다. 덮어쓰지 않는다.
- Keeper 는 이 트랙에서 읽기(글·페이지)만 한다.
- Keeper 의 HWP 편집은 따로 정한다. 후보는 rhwp `run` 이다.
  선언적 편집 계획을 원자적으로 실행하고 기록을 남긴다. 계획에 적은 입력 SHA 가 다르면 아무것도 쓰지 않고 종료 코드 3 으로 끝난다.
  이 RFC 의 「덮어쓰지 않는다」와 맞는다. 표 칸·차트 값은 `csv-to-table`·`csv-to-chart` 가 있다.

## 6. 헌법과 맞추기

- `closed_sum_over_string`: 저장 결과, hunk, 댓글 위치 상태(`Anchored`·`Anchor_lost`)가 닫힌 합이다.
- `failure_keeps_evidence`: 충돌은 아무것도 쓰지 않고 지금 원고를 돌려준다. 조용히 한쪽을 버리지 않는다.
- `budget_gate`: 재시도 횟수·시간 상한이 없다. 엔진 선택을 숫자로 바꾸지 않는다.
- `legacy_residue`: Yjs 원고는 hard cut 이고 변환 코드가 없다. 쓰이지 않게 된 동작(select·resolve)은 지운다.
- `libraries`: diff3 는 검증된 구현을 가져온다. 없으면 시험 표와 함께 작게 둔다.

## 7. Stack 계획

#55383~#55387 병합 뒤 `main` 위에 쌓는다.

| 층 | 범위 | 확인 | 먼저 있어야 하는 것 |
|---|---|---|---|
| L1 | 이 RFC. 세 RFC 와 같은 PR 에서 옛 문서 넷을 지운다(§9) | `rfc-generate-index.py --check` | — |
| L2 | OCaml 원고 저장(리비전·blob·diff3·generation), 저장 결과 타입 | PR `type-check`, 병합·충돌·끼어든 저장 시험 표 | #55383~#55387 |
| L3 | 댓글 위치 교체, `keeper_artifact_draft` 동작 정리, Yjs 엔진 모듈과 설치 스크립트 삭제 | 위와 같음 | L2 |
| L4 | Dashboard 원고 편집·충돌 화면·댓글 | `pnpm typecheck`, vitest(보낸 요청·받은 결과) | L3 |
| L5 | 내보내기 `export` 동작과 `exports` 기록 | 변환 결과 파일을 PR 에 첨부 | 문서 RFC L3 |
| L6 | HWP 편집 chunk | 배포 자산 합계와 첫 화면 `index.js` gzip 비교, 저장 결과가 새 첨부인지 | 문서 RFC L6 |

## 8. 확인 방법

- 사람과 Keeper 가 같은 원고의 다른 문단을 동시에 고친다. 두 수정이 모두 남은 원문을 PR 에 남긴다.
- 같은 문장을 동시에 고친다. `Conflict` 가 나고 아무것도 쓰이지 않았고, 고른 결과가 저장된 기록을 남긴다.
- `Conflict` 를 고르는 사이 세 번째 저장이 끼어든다. 그 저장이 병합되거나 다시 충돌하는 기록을 남긴다.
- 새로 설치한 환경에서 `masc-artifact-document` 없이 원고 도구가 도는 것을 보인다.

## 9. 지우는 옛 문서와 닫는 이슈

아래 문서는 11-24 #54560 이 지운 브라우저 변환기와 Yjs 편집기를 「구현」 또는 「구현 설계」로 적고 있다.
코드와 맞지 않는 설명은 다음 작업자를 틀린 길로 보낸다. 이 RFC 묶음의 L1 에서 지운다.

- `docs/rfc/RFC-artifact-hwp-import.md`
- `docs/rfc/RFC-artifact-office-roundtrip.md`
- `docs/rfc/RFC-artifact-office-fidelity.md`
- `docs/design/artifact-document-export.md`

지워진 화면을 고치자는 열린 이슈도 같은 이유로 닫는다. 새 설계는 이 결함을 물려받지 않는다.

| 이슈 | 내용 | 대상 코드 |
|---|---|---|
| #53110 | 재연결 뒤 옛 위치 요청이 새 커서 전송을 막는다 | 실시간 공동 편집 화면(11-24 삭제), 위치 기록(#55387 삭제) |
| #53109 | heartbeat 가 끊겨도 연결된 것으로 보인다 | 실시간 공동 편집 스트림(11-24 삭제) |
| #52716 | 빈 값이 든 HWPX 차트를 RHWP 가 잘못 읽는다 | 브라우저 HWPX 내보내기(11-24 삭제) |
| #52637 | Core 0.9 로 다시 저장한 HWPX 의 차트 Excel 연결이 끊긴다 | 브라우저 HWPX 가져오기·내보내기(11-24 삭제) |

## 10. 범위 밖

- 원본 서식을 지키며 DOCX·XLSX·PPTX 를 그 자리에서 고치기. 원고로 가져오면 서식은 남지 않는다.
- 글자 단위 실시간 동시 편집과 참여자 커서.
