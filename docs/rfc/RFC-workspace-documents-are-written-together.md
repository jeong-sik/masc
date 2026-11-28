---
rfc: "workspace-documents-are-written-together"
title: "Workspace Documents Are Written Together"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: vincent
related: ["workspace-documents-arrive-as-pages-and-text", "workspace-chat-media-renders-where-it-is-written", "workspace-media-and-rich-embed"]
---

# RFC workspace-documents-are-written-together: 사람과 Keeper 여럿이 같은 문서를 함께 쓴다

## 0. 요약

지금 사람은 Dashboard 에서 아티팩트를 읽고, 복사하고, 내려받을 수만 있다. 고칠 수는 없다.
Keeper 는 `keeper_artifact_draft` 로 원고를 고친다. #55387 본문 기준으로 10-28~11-27 에 462번 불렸다.
그 원고의 상태는 Yjs CRDT 다. Yjs 를 다루는 외부 실행 파일 `masc-artifact-document` 의 소스는 11-24 #54560 에서 지워졌다.
이 맥에는 11-02 에 설치한 묶음(`artifact-document.mjs`, 579 KB)이 남아 있어서 도구가 돈다.
새로 설치한 곳에서는 그 실행 파일을 만들 수 없다.

stack #55383~#55387 은 부르는 화면이 없는 원고 HTTP 라우트, 실시간 방, Keeper 편집 위치를 지운다.
이 RFC 는 그 stack 이 병합된 뒤를 전제로, 공동 작성을 처음부터 다시 정한다.

목표는 사람과 Keeper 여럿이 함께 쓰는 리치 문서다.

- 문서는 표·그림·체크리스트·접기 같은 블록으로 이루어진다.
- 여러 Keeper 가 서로 다른 블록을 동시에 고쳐도 부딪히지 않는다.
- 사람이 댓글에서 `@<Keeper>` 를 부르면 그 Keeper 가 같은 스레드에 답하고, 필요하면 문서를 고친다.

## 1. 결과

- 사람이 Dashboard 에서 원고를 열어 블록 단위로 고친다. Keeper 여럿이 같은 원고를 도구로 고친다.
- 다른 블록을 고친 저장은 서로 건드리지 않는다.
- 같은 블록을 동시에 고치면 그 블록 안에서 3-way 병합한다. 겹치는 줄이 있으면 아무것도 쓰지 않고 양쪽을 돌려준다.
  사람은 화면에서 고르고, Keeper 는 다음 도구 호출에서 고른다. 조용히 한쪽을 덮어쓰지 않는다.
- 다른 사람이나 Keeper 가 저장하면 열어 둔 Dashboard 화면에 바뀐 블록이 바로 보인다. 블록마다 마지막으로 고친 이가 보인다.
- 댓글 스레드는 블록의 문장에 붙는다.
  - 댓글의 `@<Keeper>` 는 그 Keeper 의 queue 에 일반 메시지로 들어간다.
  - Keeper 는 같은 스레드에 답한다. 문서를 고치면 그 수정이 어느 스레드에 대한 답인지 기록이 남는다.
- 게시하면 지금처럼 바뀌지 않는 리비전(Markdown)이 된다.
- DOCX·XLSX·PPTX·PDF 로 내보낸다. HWPX 내보내기는 §4.7 의 확인 결과에 달렸다.
- HWP 원본을 HWP 그대로 고치는 길은 §5 의 별도 트랙이다.

## 2. 무엇이 실제로 동시에 일어나나

동시 편집 방식을 고르기 전에 실제 쓰임을 본다.

- Keeper 의 수정은 도구 호출 단위다. 글자 단위로 타이핑하지 않는다. 한 호출은 「이 블록을 이것으로」나 「이 뒤에 표를 넣는다」다.
- 사람의 수정은 블록 편집을 마칠 때 한 덩어리로 도착한다.
- 여러 Keeper 가 한 문서를 쓰면 보통 절을 나눠 맡는다. 같은 블록을 같은 순간에 고치는 일은 드물다.

수정이 블록 단위의 덩어리로 오므로, 글자 단위 CRDT 가 아니어도 덮어쓰기를 막을 수 있다.
블록마다 리비전을 두면 다른 블록을 고친 저장끼리는 아예 비교하지 않아도 된다.

## 3. 결정: 블록 리비전과 블록 안 3-way 병합

11-28 에 운영자가 정했다. 3-way 병합을 바탕에 두고, 여러 Keeper 가 함께 쓰는 리치 문서로 간다.

| | 블록 리비전 + 블록 안 3-way 병합 (택함) | Yjs 변환기를 되살림 (택하지 않음) |
|---|---|---|
| 정본 | 타입이 있는 블록 목록, 블록마다 리비전 | Yjs 상태(바이너리) |
| 동시 수정 | 다른 블록은 그대로 둘 다 들어간다. 같은 블록은 3-way 병합, 겹치면 충돌을 돌려준다 | CRDT 가 자동 병합한다. 겹쳐도 한 결과로 수렴한다 |
| 실행 | OCaml 안. 외부 프로세스 없음 | Node 실행 파일. 30초 상한의 외부 프로세스(`artifact_document_engine.ml:55`) |
| 화면 갱신 | 저장 사건을 SSE 로 보내 바뀐 블록만 다시 읽는다 | 문서 상태를 실시간으로 동기화한다 |
| 비용 | 블록 타입과 저장소, 블록 편집 화면 | JS 빌드와 설치 경로가 돌아온다. 11-24 에 뺀 의존성의 일부도 돌아온다 |

겹치는 수정을 조용히 수렴시키지 않고 보여 준다. 그 편이 「덮어쓰지 않는다」에 맞다.
글자 단위 실시간 동시 편집이 필요하다는 기록이 쌓이면 그때 CRDT 를 다시 본다. 런타임에 숫자로 방식을 바꾸는 게이트는 두지 않는다.

## 4. 설계

### 4.1 블록

블록 종류는 닫힌 합이다. 블록 안의 글은 Markdown inline 문법(굵게·기울임·코드·링크·멘션)이다.

```ocaml
type inline = string            (* Markdown inline. cmarkit 으로 읽는다 *)

type block_body =
  | Heading of { level : int; text : inline }               (* level 1..3, 생성자가 막는다 *)
  | Paragraph of inline
  | Bullets of inline list
  | Numbered of inline list
  | Checklist of { checked : bool; text : inline } list
  | Table of { header : inline list; rows : inline list list }   (* 행마다 열 수가 같다 *)
  | Code of { language : string option; text : string }
  | Quote of inline
  | Callout of { tone : callout_tone; text : inline }
  | Toggle of { summary : inline; body : block list }
  | Media of { attachment : string; caption : inline }      (* att_<64hex>. 이미지·동영상·오디오·MIDI·문서 *)
  | Youtube of Wiki_link.youtube_embed
  | Math of string
  | Divider

and block =
  { id : Block_id.t             (* UUIDv7 *)
  ; revision : int              (* 이 블록을 바꾼 저장마다 1 증가 *)
  ; body : block_body
  ; edited_by : string
  ; edited_at : string }

and callout_tone = Note | Warning | Decision
```

- `Media` 는 [workspace-chat-media-renders-where-it-is-written](RFC-workspace-chat-media-renders-where-it-is-written.md) 의 카드와,
  [workspace-documents-arrive-as-pages-and-text](RFC-workspace-documents-arrive-as-pages-and-text.md) 의 문서 카드로 그린다.
- `Youtube` 는 chat-media RFC §3.1 의 `youtube_embed` 를 그대로 쓴다.
- 멘션은 `@<Keeper 이름>` 이다. 저장할 때 Keeper 목록에 있는 이름만 멘션으로 읽는다. 없는 이름은 평범한 글이다.
- 게시할 때 블록 목록을 Markdown 으로 바꾼다. Markdown 으로 가져올 때는 `cmarkit`(이미 의존성)으로 블록을 만든다.
  `Callout`·`Toggle`·`Math` 처럼 CommonMark 에 없는 블록은 정해진 Markdown 표기로 바꾼다. 같은 시험 표로 왕복을 확인한다.

### 4.2 원고와 저장

```ocaml
type target = { artifact_id : string; generation : string }   (* 지금 Artifact_draft.target 과 같다 *)

type draft = private
  { target : target
  ; revision : int              (* 저장마다 1 증가 *)
  ; base_publication : int      (* 이 원고가 출발한 게시 리비전 *)
  ; blocks : block list }

type op =
  | Insert of { after : Block_id.t option; body : block_body }        (* None 이면 맨 앞 *)
  | Update of { id : Block_id.t; expected : int; body : block_body }  (* expected: 읽었을 때의 블록 리비전 *)
  | Delete of { id : Block_id.t; expected : int }
  | Move of { id : Block_id.t; after : Block_id.t option }

type hunk =
  | Same of string
  | Changed of { base : string; ours : string; theirs : string }

type block_conflict =
  | Overlap of { current : block; hunks : hunk list }   (* 같은 블록, 겹치는 줄 *)
  | Kind_changed of { current : block }                 (* 다른 쪽이 블록 종류를 바꿨다 *)
  | Deleted_meanwhile of { id : Block_id.t }            (* 고치려던 블록을 다른 쪽이 지웠다 *)
  | Updated_meanwhile of { current : block }            (* 지우려던 블록을 다른 쪽이 고쳤다 *)
  | Anchor_missing of { after : Block_id.t }            (* 넣을 자리의 앞 블록이 없다 *)

type save_result =
  | Saved of { draft : draft; merged_blocks : Block_id.t list }   (* 병합한 블록이 있으면 적는다 *)
  | Conflict of { current : draft; conflicts : block_conflict list }   (* 아무것도 쓰지 않았다 *)
  | Generation_changed of { current : target }
```

저장은 `ops` 묶음 하나를 원고 하나에 대해 원자적으로 커밋한다. 묶음은 전부 들어가거나 하나도 안 들어간다.

1. `generation` 이 다르면 `Generation_changed` 다. 지웠다 다시 만든 원고의 리비전이 우연히 맞아도 섞이지 않는다.
2. `Update` 의 `expected` 가 그 블록의 지금 리비전과 같으면 그대로 바꾼다.
3. 다르면 그 블록의 `expected` 판 글을 공통 조상으로, 새 글과 지금 글을 줄 단위로 3-way 병합한다.
   겹치지 않으면 합친 글을 쓰고 `merged_blocks` 에 적는다. 겹치면 `Overlap` 이다.
   `Table`·`Checklist` 는 행 하나를 한 줄로 보고 병합한다.
4. 다른 블록을 고친 저장끼리는 비교하지 않는다. 여러 Keeper 가 절을 나눠 쓰면 충돌이 나지 않는다.
5. 같은 블록 뒤에 동시에 넣은 블록은 커밋 순서대로 놓인다. 나중에 커밋한 블록이 그 블록 바로 뒤에 온다.

`Conflict` 는 지금 원고 전체를 돌려준다. 호출자는 고른 결과를 지금 블록 리비전으로 다시 저장한다.
그사이 다른 저장이 끼어들었으면 3번이 다시 돈다. 끼어든 저장이 조용히 사라지는 길은 없다.

- 저장소는 블록 리비전마다 블록 내용을 내용 주소 blob 으로 남긴다. 그래야 공통 조상을 언제든 읽는다.
- 원고를 지울 때 리비전 blob 도 같이 지운다. 시간이 지났다는 이유로는 지우지 않는다.

### 4.3 화면 갱신과 「누가 고치는 중」

- 저장이 커밋되면 서버가 기존 SSE stream 에 `draft.changed { target; revision; changed : Block_id.t list; actor }` 를 보낸다.
  열어 둔 Dashboard 는 바뀐 블록만 다시 읽는다.
- 사람이 편집 중인 블록이 바뀌었으면 덮어쓰지 않는다. 「다른 쪽이 이 블록을 고쳤어요」를 띄우고, 저장할 때 4.2 의 병합을 탄다.
- 블록 옆의 「마지막으로 고친 이」는 블록의 `edited_by`·`edited_at` 이다. 따로 저장하는 presence 상태는 없다.
  가시성은 authority 가 아니라 projection 이다.

### 4.4 댓글, 제안, 멘션

`Artifact_discussion` 의 명령(comment·reply·resolve·reopen·accept·reject)과 사건 기록은 그대로 둔다.

- 위치를 Yjs 좌표에서 `{ block : Block_id.t; quote; prefix; suffix }` 로 바꾼다.
  받아들이면 그 블록에서 자리를 다시 찾아 4.2 의 `Update` 로 쓴다.
  자리를 못 찾으면 `Anchor_lost` 로 남기고 사람이 고른다. 가장 비슷한 곳을 추측해 바꾸지 않는다.
- 댓글 본문의 `@<Keeper>` 는 기존 `Workspace_broadcast` 멘션 전달로 그 Keeper 의 queue 에 넣는다.
  메시지에는 원고·스레드·블록을 가리키는 값이 들어간다. 전달 결과(`Accepted`·`Deferred`·`Rejected`)는 댓글 옆에 보인다.
- 이 메시지는 계약이 아니다. 답할 의무, 기다림, 재시도를 만들지 않는다. Keeper 가 무엇을 할지는 Keeper 가 고른다.
- Keeper 가 그 스레드 때문에 원고를 고치면 저장에 `answering : thread_id` 를 붙인다.
  스레드에는 「이 수정으로 답함」이 사건으로 남는다.

### 4.5 Keeper 도구

#55387 뒤 `keeper_artifact_draft` 의 동작은 find·published·open·read·select·resolve·edit·discuss·checkpoint 다.
이 RFC 는 select 와 도구 동작 resolve 를 지운다. 둘 다 Yjs 위치를 다루던 동작이다.
토론 명령 resolve(스레드 닫기)는 discuss 안에 그대로 남는다.

| 동작 | 바뀌는 것 |
|---|---|
| find·published·open | 그대로 |
| read | 원고를 블록 목록으로 돌려준다. 블록마다 id·리비전·종류·마지막으로 고친 이가 있다. `blocks` 로 일부만 읽을 수 있다 |
| edit | `ops` 묶음과 `target` 을 받는다. 선택으로 `answering` 을 받는다. 결과는 4.2 의 `save_result` 다 |
| discuss | 위치를 `{ block; quote; prefix; suffix }` 로 받는다 |
| checkpoint | 그대로. 게시는 지금처럼 `keeper_artifact_publish` 가 하고, checkpoint 가 원고의 출발 게시 리비전을 옮긴다 |

`Conflict` 를 받은 Keeper 는 다음 호출에서 고른 결과를 다시 저장한다. 재시도 상한은 두지 않는다.

### 4.6 Dashboard

- 블록 편집기: 블록마다 편집 상태가 따로다. 블록을 고르면 그 블록만 편집 칸이 된다. 「/」로 블록 종류를 고르고, 표는 칸 단위로 고친다.
- 그림·파일은 붙여넣기와 끌어 놓기로 올린다. 첨부 저장소에 올린 뒤 `Media` 블록이 된다.
- 충돌이면 `Changed` hunk 를 양쪽으로 보여 주고 고르게 한다.
- 오른쪽에 블록에 붙은 댓글 스레드가 있다. 멘션 입력은 Keeper 이름을 자동 완성한다.
- 편집기는 원고를 열 때 불러오는 chunk 다. 첫 화면 `index.js` 는 늘지 않는다.
  편집기 부품을 라이브러리로 쓸지 직접 만들지는 L5 가 chunk 크기를 재서 정한다.

### 4.7 내보내기와 가져오기

내보내기는 [workspace-documents-arrive-as-pages-and-text](RFC-workspace-documents-arrive-as-pages-and-text.md) §3.2 의 변환기 이미지에서 돈다.
그 worker 에 `export` 동작을 더한다. 격리와 호스트 검증은 같다. 입력은 4.1 의 규칙으로 만든 Markdown 이다.

| 형식 | 경로 |
|---|---|
| DOCX | pandoc |
| PPTX | pandoc. `Heading` level 1 마다 슬라이드 한 장 |
| PDF | pandoc → DOCX → `soffice --convert-to pdf`. LaTeX 엔진을 들이지 않는다 |
| XLSX | `Table` 블록마다 CSV 로 뽑아 LibreOffice 로 한 시트씩 만든다. `Table` 이 없으면 `No_table` 으로 거절한다 |
| HWPX | rhwp v0.9.1 의 `build-from-ingest`(ingest JSON 과 그림 → HWPX). 블록을 ingest JSON 으로 옮길 수 있는지는 L6 이 schema(`rhwp capabilities --search build-from-ingest`)를 읽고 정한다. 표나 그림을 잃으면 HWPX 는 범위 밖으로 둔다 |

- 결과는 새 첨부로 저장한다. 첨부 meta 는 바꾸지 않는다. meta 는 내용 digest 로 찾는 값이라 출처를 담을 자리가 아니다.
- 원고 기록이 `exports : { format; attachment_id; draft_revision } list` 를 갖는다.
- 가져오기: 첨부 문서의 추출 글(`GET …/text`)을 `cmarkit` 으로 블록으로 바꿔 새 원고를 연다. 원본 첨부는 그대로 둔다.

### 4.8 저장 형식

원고 저장은 hard cut 이다. 기존 `.masc/artifact_drafts/` 의 Yjs 상태는 읽지 않는다. 변환 reader 를 만들지 않는다.
토론 사건 기록은 원고 안에 있다(`artifact_discussion.mli:1-2`). 그래서 기존 원고의 댓글 스레드도 함께 없어진다.
배포 노트의 Fresh state 항목에 둘 다 적는다. 게시된 아티팩트 리비전은 영향이 없다.

## 5. HWP 를 HWP 로 고치는 트랙

사람이 HWP·HWPX 문서 카드에서 「편집」을 누르면 rhwp 편집기(`@rhwp/editor`, WASM)를 그때 불러온다.

- 첫 화면 `index.js` 에 들어가지 않는 별도 chunk 다. 읽기·미리보기 변환은 여기서 하지 않는다.
- 저장하면 새 HWP·HWPX 바이트가 새 첨부가 된다. 원본 첨부는 그대로다.
- 새 첨부는 원본이 실린 자리(채팅 대화, Board 항목)에 「<원본 이름> 편집본」으로 새로 실린다.
  원본과의 관계는 그 메시지·항목 기록이 갖는다. 첨부 meta 는 바꾸지 않는다.
- 이 문서는 블록 원고가 아니므로 4.2 의 병합을 받지 않는다. 두 사람이 동시에 열면 저장마다 새 첨부가 된다. 덮어쓰지 않는다.
- Keeper 는 이 트랙에서 읽기(글·페이지)만 한다.
- Keeper 의 HWP 편집은 따로 정한다. 후보는 rhwp `run` 이다.
  선언적 편집 계획을 원자적으로 실행하고 기록을 남긴다. 계획에 적은 입력 SHA 가 다르면 아무것도 쓰지 않고 종료 코드 3 으로 끝난다.
  이 RFC 의 「덮어쓰지 않는다」와 맞는다. 표 칸·차트 값은 `csv-to-table`·`csv-to-chart` 가 있다.

## 6. 헌법과 맞추기

- `closed_sum_over_string`: 블록 종류, op, 충돌, 저장 결과, 댓글 위치 상태(`Anchored`·`Anchor_lost`)가 닫힌 합이다.
- `strict_parse_no_default`: 없는 Keeper 이름은 멘션이 아니다. 자리를 잃은 댓글은 추측해 옮기지 않는다.
- `failure_keeps_evidence`: 충돌은 아무것도 쓰지 않고 지금 원고와 충돌 목록을 돌려준다.
- `budget_gate`: 재시도 횟수·시간 상한이 없다. 병합 방식을 숫자로 바꾸지 않는다.
- Keeper 사이 요청: 멘션은 대상 Keeper queue 의 일반 메시지다. 응답·대기·재시도 의무가 없다.
- 가시성: 「마지막으로 고친 이」는 블록 기록의 projection 이다. 새 presence authority 를 만들지 않는다.
- `legacy_residue`: Yjs 원고는 hard cut 이고 변환 코드가 없다. 쓰이지 않게 된 동작(select·resolve)은 지운다.
- `libraries`: Markdown 은 `cmarkit`, 내보내기는 pandoc·LibreOffice 를 쓴다. diff3 는 검증된 구현을 가져온다. 없으면 시험 표와 함께 작게 둔다.

## 7. Stack 계획

#55383~#55387 병합 뒤 `main` 위에 쌓는다.

| 층 | 범위 | 확인 | 먼저 있어야 하는 것 |
|---|---|---|---|
| L1 | 이 RFC. 세 RFC 와 같은 PR 에서 옛 문서 넷을 지운다(§9) | `rfc-generate-index.py --check` | — |
| L2 | 블록 타입, Markdown 왕복, 원고 저장(블록 리비전·blob·diff3·generation), 저장 결과 | PR `type-check`, 왕복·병합·충돌·끼어든 저장 시험 표 | #55383~#55387 |
| L3 | 댓글 위치 교체, 멘션 전달, `answering`, `draft.changed` SSE | PR `type-check`, 멘션 전달 결과 시험 | L2 |
| L4 | `keeper_artifact_draft` 동작 정리, Yjs 엔진 모듈과 설치 스크립트 삭제 | PR `type-check` | L3 |
| L5 | Dashboard 블록 편집기·충돌 화면·댓글·멘션·실시간 갱신 | `pnpm typecheck`, vitest(보낸 요청·받은 결과), 편집기 chunk 크기 | L4, chat-media L4 |
| L6 | 내보내기 `export` 동작과 `exports` 기록 | 변환 결과 파일을 PR 에 첨부 | 문서 RFC L3 |
| L7 | HWP 편집 chunk | 배포 자산 합계와 첫 화면 `index.js` gzip 비교, 저장 결과가 새 첨부인지 | 문서 RFC L6 |

## 8. 확인 방법

- Keeper 둘과 사람이 같은 원고의 다른 블록을 동시에 고친다. 세 수정이 모두 남은 블록 목록을 PR 에 남긴다.
- 같은 블록의 다른 줄을 동시에 고친다. `merged_blocks` 에 그 블록이 있고 두 수정이 모두 남은 기록을 남긴다.
- 같은 줄을 동시에 고친다. `Conflict` 가 나고 아무것도 쓰이지 않았고, 고른 결과가 저장된 기록을 남긴다.
- 충돌을 고르는 사이 세 번째 저장이 끼어든다. 그 저장이 병합되거나 다시 충돌하는 기록을 남긴다.
- 사람이 댓글에 `@<Keeper>` 를 쓴다. 그 Keeper queue 에 메시지가 들어간 기록과, Keeper 의 답과 `answering` 수정이 스레드에 남은 화면을 남긴다.
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
- HTML 아티팩트의 블록 편집. HTML 게시본은 지금처럼 읽기만 한다. 블록 원고는 Markdown 으로 게시한다.
