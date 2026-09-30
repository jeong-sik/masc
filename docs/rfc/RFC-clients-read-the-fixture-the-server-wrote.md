---
rfc: "clients-read-the-fixture-the-server-wrote"
title: "클라이언트 decoder 는 서버가 쓴 fixture 로 시험한다"
status: Draft
created: 2026-09-29
updated: 2026-09-30
author: claude
related: ["0079", "0057"]
---

# RFC: 클라이언트 decoder 는 서버가 쓴 fixture 로 시험한다

- 범위: 웹 대시보드(`dashboard/src/api`)와 TUI(`lib/tui_decode.ml`, `bin/masc_tui_loader.ml`)가 decode 하는 서버 JSON 응답의 테스트 방식. 응답 모양 자체는 바꾸지 않는다.
- 근거 기준: `origin/main` 91c24caa05 (2026-09-29). 줄 번호는 이 커밋 기준이다.
- 표시: **[사실]** 은 코드에서 확인한 것, **[제안]** 은 이 RFC 가 정하려는 것이다.

## 무슨 일이 있었나

09-22 ~ 09-29 주간 감사([기록](../audits/2026-09-29-week-audit-and-feature-matrix.md))에서 클라이언트가 서버와 다른 모양을 읽는 결함이 여럿 나왔다. 모두 테스트는 통과하고 있었다.

| 결함 | 운영자가 본 것 | 테스트가 통과한 이유 |
|---|---|---|
| 웹 Gate 승인 행(TU-F01, #39991) | 승인 대기가 하나도 안 보임 | fixture 에 서버가 #29256 에서 뺀 `goal_ids` 가 있었다 |
| runtime-probe 상태(TU-F02, #39996) | fleet 이 건강할 때 schema drift 예외 | fixture 가 옛 상태 단어를 썼다 |
| Schedules 다음 일정(TU-F04, #39998) | `Next due:` 가 한 번도 안 그려짐 | fixture 가 TUI 쪽 철자 `next_due_at_iso` 를 썼다 |
| async-requests(TU-F17), 채팅 delivery kind(TU-F18) | 요청이 있으면 목록이 실패, 도구 행이 사라짐 | fixture 에 새 필드·새 kind 가 없었다 |

TUI 감사는 이번 주 `fix(tui)` 중 wire 이름·모양 수정을 약 15건으로 셌다. 예: #38312 #38224 #38147 #38179 #38050 #39262 #39052 #39091 #39504 #39361.
공통점은 하나다. **클라이언트 테스트의 입력을 사람이 손으로 쓴다.** 그래서 decoder 와 fixture 가 같이 틀리면 테스트는 초록이다.

## 이미 있는 틀

**[사실]** 같은 문제를 이미 두 번 이 방법으로 막았다.

- `dashboard/src/api/fixtures/scheduled-automation-lookup-found.json`
  - `test/test_dashboard_http_core.ml:1779-` `test_schedule_exact_lookup_found_matches_the_dashboard_fixture` 가 서버 projection 으로 응답을 만들어 파일과 비교한다. 모든 깊이의 키와 값 종류를 본다.
  - 대시보드 decoder 테스트가 같은 파일을 읽는다.
  - 계기: #32273 이 wake 이력을 더했는데 대시보드는 몰랐고, 그 뒤 모든 found 응답이 "모르는 키"로 거절됐다(#38510).
- `dashboard/src/api/fixtures/turn-record-writer.jsonl`
  - `test/test_turn_record.ml:327-` `test_dashboard_writer_fixture_roundtrip` 가 파일의 각 줄을 `Turn_record.of_json` 으로 읽고, `to_json` 이 같은 JSON 을 내는지 본다. usage scope 는 variant 순서대로 한 줄씩 있어야 한다.

두 곳에서는 이 문제가 다시 나지 않았다. 나머지 endpoint 에는 이 틀이 없다.

**[사실]** decoder 는 대부분 테스트에서 부를 수 있는 곳에 있다.

- TUI decoder 는 `lib/tui_decode.ml` 에 약 231개, `bin/masc_tui_loader.ml` 에 15개 있다. OCaml 테스트는 bin 모듈을 링크하지 않는다. 그래서 `bin` 쪽 decoder 는 지금 PTY 시나리오로만 시험된다(`test/test_tui_keyboard_input.py` 등의 인라인 dict).
- 웹 decoder 는 `dashboard/src/api/**` 에 있고 vitest 로 시험한다.

## 제안

### 규칙

**[제안]** TUI 나 웹이 decode 하는 JSON 응답마다 fixture 파일 하나를 둔다. 이 파일을 만드는 것은 서버 인코더이고, 두 클라이언트의 테스트는 이 파일을 읽는다.

1. **자리.** `dashboard/src/api/fixtures/<endpoint>.json` 에 둔다. 이미 있는 두 파일과 같은 곳이다. 이름은 route 를 따른다. 예: `dashboard-gate-snapshot.json`, `dashboard-schedules.json`.
2. **서버 쪽 테스트.** 실제 인코더로 응답을 만든다. 테스트 전용 인코더나 손으로 쓴 `Assoc` 를 쓰지 않는다. 그 결과를 파일과 `Yojson.Safe.equal` 로 비교한다. 다르면 인코더의 JSON 전체를 실패 메시지에 싣는다. 작성자는 CI 로그의 그 JSON 으로 파일을 바꾼다. 로컬 빌드는 필요 없다.
3. **값 종류를 다 담는다.** 인코더가 닫힌 합타입을 쓰면(상태 단어, kind, phase) 파일에 모든 생성자가 한 번씩 나오게 한다. 타입에 `all` 목록이 있으면 그것으로 만든다. 한 가지 모양만 고정하면 F02 같은 결함은 못 잡는다.
4. **웹 쪽 테스트.** vitest 가 파일을 import 해서 decoder 에 넣고, 모든 행이 받아들여지는지 본다. 클라이언트가 소비하는 각 필드의 디코딩 결과를 fixture 의 기대값과 대조한다. 성공 여부만 확인하지 않고, 값·상태 생성자·중첩 필드·목록의 내용과 순서·선택 값의 유무를 확인한다. 이어서 "모르는 키 하나 더하기", "필수 키 하나 빼기" 두 변형이 거절되는지 본다.
5. **TUI 쪽 테스트.**
   - `lib/tui_decode.ml` 의 decoder 는 OCaml 테스트가 같은 파일을 읽어 decode 하고, 웹과 같이 소비하는 각 필드의 결과를 fixture 의 기대값과 대조한다. `Ok` 나 `None` 을 반환했다는 사실만으로 통과시키지 않는다.
   - 예를 들어 `fsm.next_due_at` 에 일정 시각이 있는 서버 fixture 는 TUI 의 다음 일정 값이 그 시각을 담은 `Some` 인지 확인한다. `fsm.next_due_at` 이 `null` 인 fixture 는 `None` 인지 별도로 확인한다. 필드를 무시해서 두 입력 모두 `Ok None` 으로 읽는 decoder 는 실패해야 한다.
   - `bin/masc_tui_loader.ml` 의 decoder 는 `Tui_decode` 로 옮긴 뒤 같은 방식으로 시험한다. 옮기는 것이 이 RFC 의 선행 작업이다.
   - PTY 시나리오가 그 endpoint 의 응답이 필요하면 파일을 `json.load` 로 읽는다. 그리고 시나리오가 다루는 필드만 바꾼다. 인라인 dict 로 응답 전체를 새로 쓰지 않는다.
6. **가드가 잡는지 확인한다.** 새 fixture 를 더하는 PR 은 인코더에서 키 하나를 지우면 서버 쪽 테스트가 실패한다는 것을 한 번 보인다. 클라이언트가 소비하는 필드 하나를 decoder 가 무시하거나 다른 값으로 읽게 바꿨을 때도 그 클라이언트 테스트가 실패해야 한다. 통과하는 가드가 잡는 가드는 아니다.

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

- **좋은 점.** 서버가 키를 더하거나 빼면 그 PR 의 CI 가 빨개진다. 운영자가 화면에서 발견하기 전이다. 두 클라이언트가 같은 입력을 읽으므로, TUI 와 웹이 같은 응답을 다르게 읽는 일(TU-F07, S7)도 테스트에서 드러난다.
- **비용.** 인코더를 바꾸는 PR 이 fixture 파일과 두 decoder 를 같이 바꿔야 한다. 이 결합이 이 RFC 가 노리는 것이다. 파일은 endpoint 당 수 KB 이고, 10개면 수십 KB 다.
- **한계.** fixture 는 테스트가 만든 표본이다. 실제 운영 데이터의 모든 조합을 담지 못한다. 그래서 3번 규칙(생성자를 다 담기)이 필요하다. 표본을 만드는 함수는 서버 테스트의 기존 sample builder 를 쓴다.
- **선행 작업.** `bin/masc_tui_loader.ml` 의 decoder 15개를 `Tui_decode` 로 옮겨야 TUI 쪽 OCaml 테스트가 붙는다. 3번(schedules)이 그 첫 대상이다.

## 관련

- TUI 읽기 상태 통일(TU-F56, `Masc_tui_fetched` 로 59쌍 이동)과 키 바인딩에 동작 싣기(TU-F57)는 별도 RFC 로 다룬다. 이 RFC 는 wire 모양만 다룬다.
- 헌법 `strict_parse_no_default`: 파서는 모르는 입력에 조용한 기본값을 주지 않는다. 이 RFC 는 그 규칙을 클라이언트 decoder 에도 시험으로 걸어 둔다.
