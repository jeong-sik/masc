---
rfc: "clients-read-the-fixture-the-server-wrote"
title: "클라이언트 decoder 는 서버가 쓴 fixture 로 시험한다"
status: Draft
created: 2026-09-29
updated: 2026-10-01
author: claude
related: ["0079", "0057"]
---

# RFC: 클라이언트 decoder 는 서버가 쓴 fixture 로 시험한다

- 범위: 웹 대시보드(`dashboard/src/api`)와 TUI(`lib/tui_decode.ml`, `bin/masc_tui_loader.ml`)가 decode 하는 서버 JSON 응답의 테스트 방식. 응답 모양 자체는 바꾸지 않는다.
- 근거 기준: `origin/main` 91c24caa05 (2026-09-29). 줄 번호는 이 커밋 기준이다.
- 표시: **[사실]** 은 코드에서 확인한 것, **[제안]** 은 이 RFC 가 정하려는 것이다.

## 무슨 일이 있었나

서버와 클라이언트의 wire 이름·상태가 어긋난 변경 사례는 [소스 근거](../audits/2026-09-30-client-fixture-source-evidence.md)에 정리했다. 이 기록은 해당 PR의 소스 변경을 확인한 것이며 주간 감사 전체나 테스트 실행 결과를 재구성한 기록은 아니다.

| 사례 | PR 작성자가 보고한 증상 | 소스에서 확인한 변경 |
|---|---|---|
| 웹 Gate 승인 행(TU-F01, #39991) | 승인 대기가 하나도 안 보임 | decoder와 fixture에서 `goal_ids`를 함께 제거 |
| runtime-probe 상태(TU-F02, #39996) | fleet이 건강할 때 schema drift 예외 | decoder와 fixture의 health 상태 단어를 서버에 맞춤 |
| Schedules 다음 일정(TU-F04, #39998) | `Next due:`가 보이지 않음 | decoder와 fixture의 요약 키를 `next_due_at`으로 변경 |
| async-requests(TU-F17), 채팅 delivery kind(TU-F18) | 요청 목록 실패·도구 행 누락 | `request_context`와 delivery kind 세 개를 추가 |

공통점은 하나다. **클라이언트 테스트의 입력을 사람이 손으로 쓴다.** 그래서 decoder 와 fixture 가 같이 틀리면 테스트는 초록이다.

## 이미 있는 틀

**[사실]** 서버와 클라이언트가 같은 fixture를 읽는 기존 사례가 두 곳 있다.

- `dashboard/src/api/fixtures/scheduled-automation-lookup-found.json`
  - `test/test_dashboard_http_core.ml:1779-` `test_schedule_exact_lookup_found_matches_the_dashboard_fixture` 가 서버 projection 으로 응답을 만들어 파일과 비교한다. 모든 깊이의 키와 값 종류를 본다.
  - 대시보드 decoder 테스트가 같은 파일을 읽는다.
  - 계기: #32273 이 wake 이력을 더했는데 대시보드는 몰랐고, 그 뒤 모든 found 응답이 "모르는 키"로 거절됐다(#38510).
- `dashboard/src/api/fixtures/turn-record-writer.jsonl`
  - `test/test_turn_record.ml:327-` `test_dashboard_writer_fixture_roundtrip` 가 파일의 각 줄을 `Turn_record.of_json` 으로 읽고, `to_json` 이 같은 JSON 을 내는지 본다. usage scope 는 variant 순서대로 한 줄씩 있어야 한다.

위 두 사례의 공유 fixture 패턴을 제안의 출발점으로 삼는다. 다른 endpoint의 적용 범위는 아래 순서에 따라 확인한다.

**[사실]** decoder 는 대부분 테스트에서 부를 수 있는 곳에 있다.

- TUI decoder 는 `lib/tui_decode.ml` 에 약 231개, `bin/masc_tui_loader.ml` 에 15개 있다. 이 loader 모듈은 OCaml 테스트에 직접 링크되지 않아 그 decoder는 PTY 시나리오로 시험된다(`test/test_tui_keyboard_input.py` 등의 인라인 dict).
- `bin/masc_tui_keeper_chat_history.ml`의 `memory_rows_of_json`과 `bin/masc_tui_keeper_spend.ml`의 `decode_reading`도 대상이다. 두 라이브러리는 이미 `test_tui_keeper_chat_history`와 `test_tui_keeper_spend`에 링크되므로 같은 fixture를 기존 OCaml 테스트에서 읽는다.
- 웹 decoder 는 `dashboard/src/api/**` 에 있고 vitest 로 시험한다.

## 제안

### 규칙

**[제안]** TUI 나 웹이 decode 하는 JSON 응답마다 서버 인코더가 만든 응답 사례 모음을 둔다. 두 클라이언트는 각 사례의 실제 응답을 읽는다.

1. **자리와 형식.** `dashboard/src/api/fixtures/<endpoint>.json`에 `[{"case": "found", "response": 실제_인코더_응답}, ...]` 형태로 사례를 모은다. `case`는 테스트의 고유 이름이고 decoder에는 `response`만 넣는다. 서버는 각 사례를 따로 인코딩하므로 서로 배타적인 최상위 응답을 하나의 서버 payload에 섞지 않는다. 기존 단일 응답/JSONL fixture도 해당 endpoint를 옮기는 PR에서 이 형식으로 정리한다.
2. **서버 쪽 테스트.** 각 사례의 도메인 입력으로 실제 인코더를 부르고, 해당 `response`와 `Yojson.Safe.equal`로 비교한다. 테스트 전용 인코더나 손으로 쓴 응답 `Assoc`를 쓰지 않는다. 시각·UUID·경로처럼 실행마다 달라지는 입력은 테스트 sample builder 또는 주입 가능한 생산자의 clock·ID 생성기에서 고정한다. 인코더 결과나 클라이언트 입력에서 그 필드를 삭제·정규화하지 않는다. 생성자를 고정할 수 없는 endpoint는 그 입력 경계를 마련한 뒤 옮긴다. 사례 이름의 중복·누락과 응답 차이를 실패로 보고, 실제 인코더 JSON을 로그에 싣는다. 로컬 빌드는 필요 없다.
3. **값 종류를 다 담는다.** 인코더가 닫힌 합타입을 쓰면(상태 단어, kind, phase) 사례 모음 전체에서 모든 생성자가 한 번씩 나오게 한다. 타입에 `all` 목록이 있으면 사례 이름/생성자 목록과 대조해 누락을 거절한다. `Found | Not_found | Unavailable | Invalid_id`처럼 최상위 응답이 배타적이면 각각 따로 인코딩한 네 사례를 둔다. 중첩 상태와 선택 필드도 값 있음·null/없음 계약을 각각 다룬다.
4. **웹 쪽 테스트.** vitest가 사례 모음을 import하고 각 `response`를 decoder에 넣는다. 클라이언트가 소비하는 각 필드의 디코딩 결과를 fixture 의 기대값과 대조한다. 성공 여부만 확인하지 않고, 값·상태 생성자·중첩 필드·목록의 내용과 순서·선택 값의 유무를 확인한다. 이어서 각 사례에서 "모르는 키 하나 더하기", "필수 키 하나 빼기" 변형이 거절되는지 본다. 소비하는 모든 닫힌 합타입의 discriminator(중첩 `status`·`kind`·`phase` 포함)를 모르는 값으로 바꾼 사례도 반드시 거절해야 한다. 기본 생성자로 읽거나 필드를 무시해 통과시키지 않는다.
5. **TUI 쪽 테스트.**
   - `lib/tui_decode.ml` 의 decoder 는 OCaml 테스트가 같은 사례 모음의 각 `response`를 decode하고, 웹과 같이 소비하는 각 필드의 결과를 fixture 의 기대값과 대조한다. `Ok` 나 `None` 을 반환했다는 사실만으로 통과시키지 않는다.
   - 예를 들어 `fsm.next_due_at` 에 일정 시각이 있는 서버 fixture 는 TUI 의 다음 일정 값이 그 시각을 담은 `Some` 인지 확인한다. `fsm.next_due_at` 이 `null` 인 fixture 는 `None` 인지 별도로 확인한다. 필드를 무시해서 두 입력 모두 `Ok None` 으로 읽는 decoder 는 실패해야 한다.
   - 이미 OCaml 테스트에 링크된 별도 `bin` decoder는 현재 소유 모듈에서 같은 사례를 검증한다. 라이브러리 링크가 없는 loader decoder만 실제 모델 소유 모듈로 옮긴다.
   - PTY 시나리오가 그 endpoint의 응답이 필요하면 파일을 `json.load`로 읽고 이름으로 사례의 `response`를 고른다. 그리고 시나리오가 다루는 필드만 바꾼다. 인라인 dict 로 응답 전체를 새로 쓰지 않는다.
6. **가드가 잡는지 확인한다.** 새 fixture 를 더하는 PR 은 인코더에서 키 하나를 지우면 서버 쪽 테스트가 실패한다는 것을 한 번 보인다. 클라이언트가 소비하는 필드 하나를 decoder가 무시하거나 다른 값으로 읽게 바꿨을 때, 또는 모르는 discriminator를 기본 생성자로 바꾸도록 했을 때도 그 클라이언트 테스트가 실패해야 한다. 통과하는 가드가 잡는 가드는 아니다.

### 실행 시점

소스 리뷰와 P0·P1·P2 해소를 먼저 한다. 리더가 변경된 endpoint에 필요한 계약 검사를 선택하고 명시적으로 실행한다. PR·branch push·주기 실행을 계기로 자동 CI를 시작하지 않으며, 일반 PR의 승인에 fixture 검사 run이나 변이 시험 결과를 일괄 필수 조건으로 추가하지 않는다. 위 규칙은 실제 응답의 값과 오류 계약을 검증하는 시험 내용이며 숫자·문구·snapshot 휴리스틱 게이트가 아니다. Full CI는 헌법의 Release/Tag 단계에서 실행한다.

### 순서

이번 주에 실제로 틀린 곳부터 한다. 한 PR 에 endpoint 하나다.

| 순서 | endpoint | 읽는 쪽 | 이번 주 결함 |
|---|---|---|---|
| 1 | Gate snapshot 의 `approval_queue` 행 | 웹, TUI | TU-F01 |
| 2 | runtime probe | 웹 | TU-F02 |
| 3 | schedules snapshot(`fsm` 포함) | TUI, 웹 | TU-F04 |
| 4 | async requests | 웹 | TU-F17 |
| 5 | keeper chat `delivery_key` | 웹, TUI | TU-F18 |
| 6 | keeper costs | 웹, TUI | TU-F19 |
| 7 | memory journal | TUI, 웹 | TU-F05 |
| 8 | goals overview | TUI | TU-F07 |
| 9 | Gate lane mode | TUI | TU-F08 |
| 10 | 거절 응답 envelope | 둘 다 | TU-F11. 모양을 하나로 맞춘 뒤 |

나머지 endpoint 는 그 응답을 고치는 PR 이 같이 옮긴다. 새 endpoint 는 처음부터 이 규칙을 따른다.

### 하지 않는 것

- schema 언어나 TS 타입 생성은 하지 않는다. RFC-0057(tool descriptor codegen)과는 목적이 다르다. 여기서는 "지금 서버가 쓰는 바이트"를 고정할 뿐이다.
- 옛 모양을 읽는 호환 reader 를 두지 않는다. fixture 가 바뀌면 decoder 도 같은 PR 에서 바뀐다.
- 라이브 서버에서 응답을 떠 오지 않는다. 라이브 데이터는 운영자 것이고 매번 다르다.

## 트레이드오프

- **좋은 점.** 서버가 키를 더하거나 빼서 응답 계약이 달라지면, 해당 계약 검사를 명시적으로 실행했을 때 차이를 발견할 수 있다. 두 클라이언트가 같은 입력을 읽으므로, TUI 와 웹이 같은 응답을 다르게 읽는 일(TU-F07, S7)도 테스트에서 드러난다.
- **비용.** 인코더를 바꾸는 PR 이 fixture 파일과 두 decoder 를 같이 바꿔야 한다. 이 결합이 이 RFC 가 노리는 것이다. 파일은 endpoint 당 수 KB 이고, 10개면 수십 KB 다.
- **한계.** fixture 는 테스트가 만든 표본이다. 실제 운영 데이터의 모든 조합을 담지 못한다. 그래서 3번 규칙(생성자를 다 담기)이 필요하다. 표본을 만드는 함수는 서버 테스트의 기존 sample builder 를 쓴다.
- **선행 작업.** 직접 링크되지 않은 `bin/masc_tui_loader.ml` decoder는 해당 응답 모델을 소유하는 라이브러리로 옮겨 OCaml 테스트에서 부른다. `Tui_decode`가 모델을 소유할 때는 그 모듈을 쓴다. 이미 링크된 별도 `bin` 라이브러리는 현재 소유자를 유지한다. 3번(schedules)이 loader 분리의 첫 대상이다.

## 관련

- TUI 읽기 상태 통일(TU-F56, `Masc_tui_fetched` 로 59쌍 이동)과 키 바인딩에 동작 싣기(TU-F57)는 별도 RFC 로 다룬다. 이 RFC 는 wire 모양만 다룬다.
- 헌법 `strict_parse_no_default`: 파서는 모르는 입력에 조용한 기본값을 주지 않는다. 이 RFC 는 그 규칙을 클라이언트 decoder 에도 시험으로 걸어 둔다.
