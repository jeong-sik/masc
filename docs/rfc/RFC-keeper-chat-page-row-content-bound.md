---
rfc: "keeper-chat-page-row-content-bound"
title: "대화 이력 페이지는 큰 tool 행 본문을 싣지 않는다"
status: Draft
created: 2026-10-11
updated: 2026-10-11
author: claude
supersedes: []
superseded_by: null
related: ["tui-lazy-block-projection"]
implementation_prs: []
---

# RFC: 대화 이력 페이지의 행 본문 상한

## 0. 요약

`/api/v1/keepers/<k>/chat/history/page` 응답에서 tool 행의 `content`가 상한을 넘으면
앞부분만 싣고, 잘렸다는 사실과 원래 길이를 필드로 내려준다. 전체 본문은 필요한 화면이
행 하나를 따로 받아 쓴다. 목적은 TUI에서 이전 페이지가 들어올 때 UI 스레드가
JSON 파싱과 디코드로 멈추는 시간을 줄이는 것이다.

이 문서는 설계 결정을 받기 위한 초안이다. 코드는 바꾸지 않는다.

## 1. 배경 (실측)

측정 조건: 한 대의 Mac(M3 Max), 60x200 PTY, `e-masc-the-leader` 키퍼, 2026-10-10.
TUI는 `perf/tui-older-apply`(최적화 스택 맨 위), 요청은 `limit=100`.

### 1.1 페이지 하나가 UI 스레드를 쓰는 시간

PageUp 80번 동안 받은 이전 페이지 15개:

| 항목 | 값 |
|---|---|
| 응답 크기 | 125KB ~ 1.5MB, 대부분 400~760KB |
| `Yojson.Safe.from_string` | 3.6 ~ 7.5ms (1.5MB 응답은 15.7ms) |
| `page_of_json` 디코드 | 3.1 ~ 5.8ms (1.5MB 응답은 12.8ms) |

파싱과 디코드는 fetch fiber에서 돌고, 이 fiber는 UI와 같은 Eio 도메인이다.
페이지 도착 직후 프레임은 `chat.blocks` 약 6ms, `chat.layout_entries` 약 10ms,
`chat.window` 약 3ms가 더 든다. 첫 PageUp의 입력→출력 p99는 35~50ms다(목표 20ms).

### 1.2 행 크기 분포

같은 키퍼의 이력 4563행(JSON 8.9MB)을 페이지 API로 전부 받은 샘플:

| 항목 | 값 |
|---|---|
| 행 크기 중앙값 / p90 | 1,017B / 3,192B |
| 역할별 바이트 | tool 5.6MB(3363행), assistant 2.3MB(462행), user 1.1MB(738행) |
| 가장 큰 행 1개 | 906KB, 전체의 10%. tool 행 `content`(파일 쓰기 인자 본문) |
| 큰 행 2~5위 | 23~46KB, 모두 tool 행 `content` |
| 큰 행 상위 5 / 25 / 50개 | 전체 바이트의 12% / 15% / 19% |

페이지 크기를 끌어올리는 건 소수의 큰 tool 행이다. 1.5MB 페이지는 906KB 행이 든
페이지로 보인다(행과 페이지의 대응은 확인하지 않았다).

## 2. 제안

### 2.1 응답 계약

tool 행 `content`가 상한 `ROW_CONTENT_PAGE_BYTES`를 넘으면 페이지 응답은 다음처럼
내려준다.

| 필드 | 값 |
|---|---|
| `content` | 앞쪽 `ROW_CONTENT_PAGE_BYTES` 이하(UTF-8 경계에서 자른다) |
| `content_truncated` | `true` (잘리지 않은 행에는 필드 없음) |
| `content_bytes` | 원래 바이트 수 |

상한 값은 이 문서에서 정하지 않는다. 후보는 16KB다. 1.2의 분포에서 p90(3.2KB)의
5배이고, 큰 행 2~5위(23~46KB)는 잘린다.

### 2.2 전체 본문

전체 본문이 필요한 화면은 행 하나를 id로 받는다. 현재 단건 조회 경로가 있는지는
확인하지 않았다(5의 열린 질문).

## 3. 제약: `args`는 JSON 문자열이다

TUI는 tool 행 `content`를 `args`로 받아 `Keeper_chat_tool_trail.tool_subject`에
넘기고, 이 함수가 인자 JSON에서 파일 경로 같은 대상을 뽑는다
(`bin/masc_tui_keeper_chat_transcript.ml` `subject_of`). 문자열 중간을 자르면
JSON이 깨져 대상 표시가 사라진다.

따라서 자르는 단위는 둘 중 하나여야 한다.

- A. 인자 JSON을 파싱해서 문자열 필드 값만 자르고 다시 직렬화한다. `content`는 항상
  유효한 JSON이다.
- B. 서버가 `subject`를 계산해 별도 필드로 내려주고, TUI는 잘린 `content`를 파싱하지
  않는다.

A는 서버가 행마다 파싱 비용을 낸다. B는 응답 계약을 하나 더 늘린다.
어느 쪽이든 "잘린 JSON 문자열을 클라이언트가 파싱한다"는 상태는 만들지 않는다.

## 4. 대안과 기각 이유

| 안 | 장점 | 단점 |
|---|---|---|
| 파싱을 워커 도메인으로 이동 | 응답 계약 불변 | TUI에는 도메인 풀이 없다. 마이너 GC 장벽이 공유돼서 이득이 불확실하다. 이득은 페이지당 약 10ms로 추정한다 |
| 페이지 행 수를 줄임 | 변경이 작다 | 큰 행 하나가 든 페이지는 그대로다. 요청 횟수가 늘어난다 |
| 행 위치와 무관한 마크다운 캐시 키 | 페이지가 붙을 때 프레임 약 20ms를 줄일 수 있다 | 응답 크기와 별개의 문제다. 오래된 렌더링이 남을 위험이 있어 따로 다룬다 |

## 5. 열린 질문

1. 전체 `content`를 쓰는 화면이 있는가. 대시보드 `keeper-chat-store.ts`,
   `schemas/keeper-chat-history.ts`가 같은 페이지 응답을 읽는지 확인이 필요하다.
2. 행 단건 조회 경로가 이미 있는가. 없으면 새 경로를 만든다.
3. 상한 값. 16KB가 TUI의 도구 행 표시에 충분한지는 확인하지 않았다.
4. 잘린 tool 행을 TUI가 어떻게 표시할지(`+906KB` 같은 꼬리표 등).
5. `/chat/history`(꼬리 창)도 같은 상한을 받아야 하는가. 이 문서의 측정은 페이지
   경로만 다룬다.

## 6. 검증 계획

- 서버: 상한 초과 행이 잘리고 `content_truncated`/`content_bytes`가 붙는 테스트,
  경계(상한 정확히, UTF-8 다바이트 중간)에서 유효한 UTF-8과 유효한 JSON이 남는 테스트.
- TUI: 잘린 행이 `tool_subject`를 잃지 않는 테스트.
- 재측정: 같은 PTY 드라이버와 키퍼로 페이지 크기 분포와 첫 PageUp p99를 다시 잰다.
  기대치는 정하지 않는다. 906KB 행이 든 페이지의 파싱+디코드가 줄어드는지만 본다.
