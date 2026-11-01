---
rfc: "0479"
title: 대화 자원 목록은 현재 작업에서 확인된 자원만 나열한다
status: Draft
created: 2026-11-01
updated: 2026-11-01
author: vincent
supersedes: []
superseded_by: null
related: ["0378", "0478"]
---

# RFC-0479 — 대화 자원 목록은 현재 작업에서 확인된 자원만 나열한다

## 0. 한 줄 요약

Keeper와 나눈 대화에서 다룬 artifact·wiki·파일을 늘 보이게 하는 "대화 자원 목록"을,
새 저장소 없이 도구 호출 기록의 순수 함수로 제안한다. 목록은 권위 저장소에서 식별이
확인된 자원만 오르고, 판단 규칙(휴리스틱)은 어떤 형태로도 쓰지 않는다.

## 1. 문제

운영자 요청: Keeper와 대화할 때 그 대화에서 다룬 artifact·wiki·파일이 목록에 늘
남아 있으면 좋겠다. 단 무한히 쌓이는 건 원하지 않는다. 논의는 board 글
`p-4bfd4e181eebe251e66e7ef3eaa20b90`(2026-11-01)에서 시작했다.

이 요청이 남기는 결정은 하나다 — 목록에서 빠지는 기준. 시간 창, 개수 상한 단독,
빈도 점수는 모두 "왜 이 항목이 빠졌는지"에 대한 설명을 못 만든다. "작업을 바꿔서
빠졌다"는 설명이 되고 "3일 지나서 빠졌다"는 변명이다.

두 번째 요구는 운영자가 확정했다: 휴리스틱은 절대 금지. "선언된 정책이니 허용"이라는
중간 지대도 없다. 이 문서의 모든 규칙은 그 기준으로 쓰였다.

## 2. 원칙

기록과 노출을 분리한다.

- 기록은 이미 있다. 도구 호출 로그(`lib/keeper_tool_call_log.ml`, Dated_jsonl)와
  관측 버스의 tool_event가 tool_name·turn_id·keeper_id·귀속을 남긴다.
  RFC-0378 §5.1이 소비자는 파싱된 값만 받도록 이미 강제한다.
- 목록은 그 기록에서 매번 계산하는 투영이다. 별도 저장소, 캐시 재저장, 멤버십
  상태를 만들지 않는다. 가시성은 authority가 아닌 projection으로 제공한다는
  헌법 원칙의 적용이다.
- 목록에서 빠진 항목은 사라지지 않는다. 기록은 그대로 있으니 검색으로 다시 나온다.

## 3. 파생 규칙

파생은 순수 함수다. 같은 로그와 같은 task_id를 넣으면 누가 계산해도 같은 목록이
나온다.

**스코프: 현재 작업(task) 경계.**

`lib/keeper/keeper_own_recent_actions.mli`의 provenance가 이미
`{ task_id : string option; trace_id : string option }`을 싣고 있고,
`task_relation : current_task_id -> provenance -> Selected_task | Other_task | Unknown_task`
분류기가 이미 존재한다. 이 조인 위에 목록을 얹는다. task_id는 증거에 있고 lane은
없으므로, lane 스코프는 새 증거를 요구하는 별도 제안이 되어야 한다(§8).

**멤버십: 권위 저장소에서 식별이 확인된 자원만 오른다. 호출 성패는 무관하다.**

| 자원 종류 | 신원 (typed) | 식별 확인 (권위 대조) |
|---|---|---|
| 파일 | 귀속의 `Addressed` 경로 | 코드베이스로 귀속됐는가 |
| artifact | typed 인자·`retained_artifacts`의 `artifact_ref` | artifact 저장소에 존재하는가 |
| wiki | `Wiki_page_name.t` | 위키 저장소에 문서가 존재하는가 |

이 규칙이 갈래를 없애는 방식이 이 제안의 핵심이다:

- **실패한 호출이라는 갈래가 없다.** 성패를 보지 않으므로 "실패는 언제 포함하나"라는
  판단 규칙이 필요 없어진다. 일시적 오류로 실패한 artifact_read도 저장소에 있으면
  목록에 오르고, 존재하지 않는 대상을 가리킨 참조는 안 오른다.
- **귀속 실패 파일은 자원이 아니다.** `unaddressed`의 `attempted_path`는 감식 기록이지
  다시 찾아갈 자원이 아니다. 제외되며, 제외 사실은 `Unaddressed` variant로 드러난다.
- **스코프 밖은 분류기 variant 그대로다.** `Other_task`·`Unknown_task`는 목록에서
  제외되고, 그 사실은 이미 exhaustive한 분류기가 드러낸다.

**신원 추출은 도구 handler variant에 대한 exhaustive match로만 한다.**
`bin/masc_tui_keeper_chat_activity_projection.ml`이 이미
`Tool_artifact_read`·`Tool_artifact_publish`·`Tool_wiki_read`·`Tool_read_file` 등을
variant로 분류하고 있다. 파생도 같은 방식으로 쓴다. 새 도구가 추가되면 컴파일이
멈춘다 — 그것이 정상이다. string 부분 일치, 점수, 임계값, "비슷한 이름" 정규화는
금지한다.

## 4. 주입과 표시

소비자는 두 곳이고 같은 파생의 두 렌더더다.

**Keeper 주입(레이어).** `lib/keeper/keeper_context_layers.mli`의 layer_id에 새
variant(예: `Conversation_resources`)를 추가한다. 이 모듈은 렌더 순서를 `ordered`
SSOT로 관리하고, content_of를 exhaustive match로 강제한다. 레이어 추가는 variant
하나 + `ordered` 한 줄 + content_of 팔로 끝나는, 검토 가능한 typed 변경이다.
주입은 이름(경로·참조·문서명)만 하고 내용은 요청 시에 가져온다. 턴마다 다시 들어가므로
컨텍스트가 압축돼도 참조가 살아있는 것이 이 기능의 실질적 효과다.

**TUI 대화 패널.** 같은 파생으로 활동 요약 옆에 자원 목록을 표시한다. 화면은
스크롤 가능하므로 주입보다 넉넉한 상한을 쓸 수 있다.

**상한과 순서는 표시 상수다.** 멤버십에는 영향을 주지 않는다. 정렬은 마지막 참조
시간 순(최근 먼저)으로 정하고, 잘린 양은 "외 N건"으로 표시해 잘림이 드러나야 한다.
상한 수치 자체는 열린 질문이다(§9).

Recent_work·Own_recent_actions와의 경계: 저 둘은 "어떤 호출을 했나"(행위)를,
새 레이어는 "어떤 자원을 다뤘나"(대상)를 나열한다. 같은 로그의 서로 다른 투영이라
겹치지 않는다.

## 5. 구현 지점

| 변경 | 파일 |
|---|---|
| 레이어 variant·순서 | `lib/keeper/keeper_context_layers.ml` |
| 레이어 내용 생산 | `lib/keeper/keeper_unified_prompt.ml` (content_of 팔) |
| 파생(스코프 조인 재사용) | `lib/keeper/keeper_own_recent_actions.ml`의 provenance·task_relation |
| artifact 신원 | `lib/keeper_tool_call_log.ml`의 retained_artifacts(Tool_output.artifact_ref) |
| 파일 귀속 | RFC-0378 파이프라인(귀속 resolver) |
| TUI 표시 | `bin/masc_tui_keeper_chat_activity_projection.ml` 및 렌더 |
| 상한·정렬 상수 | 파생 모듈의 named constant |

## 6. 수용 기준

구현이 이 조항을 하나라도 어기면 병합하지 않는다.

1. 파생에 string 부분 일치, 점수, 임계값, 이름 정규화 추론이 없다.
2. 신원 추출은 handler variant exhaustive match이고, 새 도구 추가 시 컴파일이 실패한다.
3. 파생은 순수 함수이며 golden test가 같은 로그·같은 task_id로 같은 목록을 확인한다.
4. 상한·정렬은 named constant이고 멤버십에 영향을 주지 않으며, 잘림이 "외 N건"으로
   표시된다.
5. 목록을 위한 새 저장소·필드·주기적 재계산 작업이 없다. 매번 계산한다.

## 7. 비목표

- **고정(pin) v1 제외.** task 경계가 자연 상한이라 요청의 대부분이 해결된다.
  "작업을 넘어서도 계속 봐야 하는 자원" 요구가 실제로 생기면 그때 원장 이벤트
  하나로 추가한다. 필요하기 전에 쓰기 경로를 만들지 않는다. board 논의에서
  Bookmark(annotation_kind) 재사용은 기각했다 — Bookmark는 `lib/ide_memo`의 파일 내
  주석 문법으로 대상이 "파일의 한 줄"이지 "대화와 자원의 관계"가 아니다.
- **lane 스코프.** 증거에 lane 귀속이 없다. 요구가 생기면 별도 제안.
- **자원 내용 주입.** 이름만 준다. 내용은 Keeper가 요청할 때 가져온다.

## 8. 열린 질문

주입 상한 몇 건인가. 안: 10건 안팎 + "외 N건". board 토론에서 정한다.

## 9. 논의

- board 글 `p-4bfd4e181eebe251e66e7ef3eaa20b90` (2026-11-01) — 원제안, 소스 확인
  3건, 휴리스틱 절대 금지 조항. @context-reviewer·@e-masc-the-leader에게 의견을
  요청한 상태.
