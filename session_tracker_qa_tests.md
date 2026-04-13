# QA 테스트 제안: session_tracker.ml escape_string + parse_connection_url Edge Cases

**작성자**: qa-king  
**대상**: `/Users/dancer/me/lib/ocaml/session_tracker/test/test_session_tracker.ml`

> ⚠️ session_tracker는 masc-mcp 레포가 아닌 별도 프로젝트(`lib/ocaml/session_tracker/`)에 있음.
> 이 파일은 테스트 코드 제안서. 담당자가 직접 `test_session_tracker.ml`에 반영 바람.

---

## 1. `escape_string` 테스트 (SQL Injection 방어 핵심 함수)

```ocaml
(* ============================================ *)
(* escape_string edge case tests — qa-king      *)
(* ============================================ *)

(* 기본 케이스: 작은따옴표 이스케이프 *)
let test_escape_single_quote () =
  let result = Session_tracker.escape_string "it's" in
  check string "single quote escaped" "it''s" result

(* 기본 케이스: 백슬래시 이스케이프 *)
let test_escape_backslash () =
  let result = Session_tracker.escape_string "path\\to\\file" in
  check string "backslash escaped" "path\\\\to\\\\file" result

(* 빈 문자열 *)
let test_escape_empty () =
  let result = Session_tracker.escape_string "" in
  check string "empty string unchanged" "" result

(* 이스케이프 불필요한 문자열 *)
let test_escape_no_special () =
  let result = Session_tracker.escape_string "normal text 123" in
  check string "normal text unchanged" "normal text 123" result

(* 혼합 특수문자 *)
let test_escape_mixed () =
  let result = Session_tracker.escape_string "it's a \\path\\ here" in
  check string "mixed escaped" "it''s a \\\\path\\\\ here" result

(* 연속 작은따옴표 *)
let test_escape_consecutive_quotes () =
  let result = Session_tracker.escape_string "'''" in
  check string "consecutive quotes" "''''''" result

(* 연속 백슬래시 *)
let test_escape_consecutive_backslashes () =
  let result = Session_tracker.escape_string "\\\\" in
  check string "consecutive backslashes" "\\\\\\\\" result

(* ⚠️ NULL 바이트 — 현재 구현은 통과시킴 (보안 이슈) *)
let test_escape_null_byte () =
  let result = Session_tracker.escape_string "before\000after" in
  (* 현재 동작: NULL 바이트가 그대로 통과 → SQL injection 벡터 가능 *)
  (* 이 테스트는 현재 동작을 기록하는 것. 파라미터화된 쿼리 전환 후에는 무의미해짐 *)
  check string "null byte passes through (KNOWN ISSUE)" "before\000after" result

(* ⚠️ PostgreSQL 특수 시퀀스 $$ — 현재 구현은 통과시킴 *)
let test_escape_dollar_quote () =
  let result = Session_tracker.escape_string "$$drop table$$" in
  (* $$...$$ 는 PostgreSQL의 다른 인용 방식. escape_string은 처리 안 함 *)
  check string "dollar quote passes through (KNOWN ISSUE)" "$$drop table$$" result

(* SQL injection 시도 패턴 *)
let test_escape_sql_injection_attempt () =
  let result = Session_tracker.escape_string "'; DROP TABLE sessions;--" in
  check string "sql injection escaped" "''; DROP TABLE sessions;--" result

(* 이미 이스케이프된 입력 — double escape 발생 *)
let test_escape_already_escaped () =
  let result = Session_tracker.escape_string "it''s" in
  (* 주의: 이미 이스케이프된 ''가 ''''''로 다시 이스케이프됨 → double escape 버그 *)
  check string "double escape bug" "it''''''s" result

(* 매우 긴 문자열 *)
let test_escape_long_string () =
  let long = String.make 10000 'A' in
  let result = Session_tracker.escape_string long in
  check int "long string length preserved" 10000 (String.length result)
```

## 2. `parse_connection_url` Edge Case 테스트

```ocaml
(* ============================================ *)
(* parse_connection_url edge cases — qa-king     *)
(* ============================================ *)

(* 특수문자 포함 password — @ 문자가 password에 있으면 파싱 깨짐 *)
let test_parse_url_special_password () =
  (* 현재 구현: String.index url '@'로 첫 @를 찾음
     password에 @가 있으면 host를 잘못 파싱함 *)
  let url = "postgresql://user:p@ss@host:5432/db" in
  (* 이건 Not_found 예외를 던지거나 잘못된 결과를 반환할 것 *)
  (* 현재 동작을 확인하는 테스트 — 버그 리포트 목적 *)
  (try
    let _ = Session_tracker.parse_connection_url url in
    (* 파싱이 성공하면 host가 "ss@host"가 아닌지 확인 *)
    assert false (* 예외가 없으면 이 테스트가 실패해야 함 *)
  with Not_found ->
    () (* 예상된 실패: @가 여러 개면 첫 번째 @에서 자르므로 host 파싱 오류 *)
  )

(* 포트 없는 URL *)
let test_parse_url_no_port () =
  (* 현재 구현: String.index host_rest ':'로 포트를 찾음
     포트가 없으면 Not_found *)
  let url = "postgresql://user:pass@host/db" in
  (try
    let _ = Session_tracker.parse_connection_url url in
    assert false (* 포트 없으면 실패해야 함 *)
  with Not_found ->
    ()
  )

(* 빈 문자열 *)
let test_parse_url_empty () =
  (try
    let _ = Session_tracker.parse_connection_url "" in
    assert false
  with Not_found ->
    ()
  )

(* 프로토콜만 있는 URL *)
let test_parse_url_protocol_only () =
  (try
    let _ = Session_tracker.parse_connection_url "postgresql://" in
    assert false
  with Not_found ->
    ()
  )

(* user:pass 없는 URL *)
let test_parse_url_no_credentials () =
  let url = "postgresql://host:5432/db" in
  (try
    let _ = Session_tracker.parse_connection_url url in
    assert false
  with Not_found ->
    ()
  )
```

## 3. 커버리지 요약

| 추가 테스트 | 수량 | 목적 |
|---|---|---|
| `escape_string` edge cases | 11개 | SQL injection 방어 검증 + 알려진 이슈 기록 |
| `parse_connection_url` edge cases | 5개 | 입력 검증 + 예외 처리 검증 |
| **총 추가** | **16개** | |

### 기대 효과
- 파라미터화된 쿼리 전환 전 **현재 동작 고정** → 회귀 방지
- `escape_string`의 알려진 취약점(NULL byte, $$, double escape)을 테스트로 명시
- `parse_connection_url`의 입력 검증 부재를 테스트로 증명

### 우선순위
1. 🔴 `escape_string` SQL injection 시도 패턴 테스트 — 즉시
2. 🔴 `escape_string` NULL byte / $$ 테스트 — 즉시  
3. 🟡 `parse_connection_url` 예외 케이스 — 중기
4. 🟢 `is_pid_alive` boundary 테스트 — 장기 (DB 없이 테스트 어려움)
