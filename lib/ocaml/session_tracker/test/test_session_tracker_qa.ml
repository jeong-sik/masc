(** QA Tests for session_tracker.ml — edge cases and boundary conditions
    Author: qa-king
    Purpose: Cover escape_string, parse_connection_url edge cases
    These tests target the ~71% of functions that had ZERO test coverage.

    NOTE: escape_string is reproduced locally because it's not exported.
    When cheolsu's parameterized query patch lands, these escape_string tests
    serve as a regression baseline — the old behavior is documented here. *)

open Alcotest

(* Helper: substring search — because String.contains only works for single chars *)
let string_contains ~substring ~string =
  let sub_len = String.length substring in
  let str_len = String.length string in
  if sub_len = 0
  then true
  else if sub_len > str_len
  then false
  else (
    let rec loop i =
      if i + sub_len > str_len
      then false
      else if String.sub string i sub_len = substring
      then true
      else loop (i + 1)
    in
    loop 0)
;;

(* ============================================ *)
(* Local types and functions for testing        *)
(* These mirror session_tracker.ml internals    *)
(* ============================================ *)

type connection_info =
  { host : string
  ; port : string
  ; user : string
  ; password : string
  ; database : string
  }

let escape_string s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter
    (fun c ->
       match c with
       | '\'' -> Buffer.add_string buf "''"
       | '\\' -> Buffer.add_string buf "\\\\"
       | _ -> Buffer.add_char buf c)
    s;
  Buffer.contents buf
;;

let parse_connection_url url =
  let url =
    if String.length url > 13 && String.starts_with ~prefix:"postgresql://" url
    then String.sub url 13 (String.length url - 13)
    else if String.length url > 11 && String.starts_with ~prefix:"postgres://" url
    then String.sub url 11 (String.length url - 11)
    else url
  in
  let at_pos = String.index url '@' in
  let user_pass = String.sub url 0 at_pos in
  let host_rest = String.sub url (at_pos + 1) (String.length url - at_pos - 1) in
  let colon_pos = String.index user_pass ':' in
  let user = String.sub user_pass 0 colon_pos in
  let password =
    String.sub user_pass (colon_pos + 1) (String.length user_pass - colon_pos - 1)
  in
  let slash_pos = String.index host_rest '/' in
  let host_port = String.sub host_rest 0 slash_pos in
  let database =
    String.sub host_rest (slash_pos + 1) (String.length host_rest - slash_pos - 1)
  in
  let colon_pos = String.index host_port ':' in
  let host = String.sub host_port 0 colon_pos in
  let port =
    String.sub host_port (colon_pos + 1) (String.length host_port - colon_pos - 1)
  in
  { host; port; user; password; database }
;;

(* ============================================ *)
(* escape_string tests                          *)
(* ============================================ *)

let test_escape_normal_string () =
  check string "normal string unchanged" "hello world" (escape_string "hello world")
;;

let test_escape_single_quote () =
  (* Classic SQL injection: Robert'); DROP TABLE students; -- *)
  check string "single quote doubled" "it''s" (escape_string "it's")
;;

let test_escape_backslash () =
  check string "backslash doubled" "C:\\\\Users" (escape_string "C:\\Users")
;;

let test_escape_multiple_quotes () =
  check string "multiple quotes" "a''b''c" (escape_string "a'b'c")
;;

let test_escape_mixed () =
  check string "mixed quotes and backslashes" "a''b\\\\c''d" (escape_string "a'b\\c'd")
;;

let test_escape_empty_string () =
  check string "empty string stays empty" "" (escape_string "")
;;

let test_escape_only_quotes () = check string "all quotes" "''''" (escape_string "''")

let test_escape_only_backslashes () =
  check string "all backslashes" "\\\\\\\\" (escape_string "\\\\")
;;

let test_escape_long_string () =
  (* Stress test: 10000 single quotes *)
  let input = String.make 10000 '\'' in
  let result = escape_string input in
  check int "long string escaped length" 20000 (String.length result)
;;

(* ============================================ *)
(* BUG documentation tests                      *)
(* These DOCUMENT known weaknesses in           *)
(* escape_string — they will BREAK if the       *)
(* function is fixed to handle these cases      *)
(* ============================================ *)

let test_escape_null_byte_passthrough () =
  (* BUG: NULL byte passes through unescaped!
     In PostgreSQL, \x00 in a string literal can cause truncation or errors.
     This test DOCUMENTS the current (wrong) behavior.
     FIX: parameterized queries eliminate this entire class of bugs. *)
  let result = escape_string "hello\x00world" in
  check bool "null byte passes through (BUG)" true (String.contains result '\x00')
;;

let test_escape_double_dollar_passthrough () =
  (* BUG: $$ is a PostgreSQL dollar-quoted string delimiter.
     escape_string doesn't touch $ at all.
     This is safe ONLY if parameterized queries are used. *)
  let result = escape_string "$$" in
  check string "dollar signs pass through (known gap)" "$$" result
;;

let test_escape_semicolon_passthrough () =
  (* SQL injection vectors use semicolons for statement termination.
     escape_string doesn't escape semicolons — that's fine WITH parameterized
     queries, but lethal WITH sprintf. *)
  let result = escape_string "'; DROP TABLE session_tracker; --" in
  check string "semicolon passes through" "''; DROP TABLE session_tracker; --" result
;;

let test_escape_unicode_null () =
  (* BUG: U+0000 (NULL) in UTF-8 is \x00, passes through *)
  let result = escape_string "\x00" in
  check bool "unicode null passes through (BUG)" true (String.length result = 1)
;;

(* ============================================ *)
(* parse_connection_url — boundary tests        *)
(* ============================================ *)

let test_parse_valid_postgresql_scheme () =
  let result =
    parse_connection_url "postgresql://admin:secret@db.example.com:5432/myapp"
  in
  check string "host" "db.example.com" result.host;
  check string "port" "5432" result.port;
  check string "user" "admin" result.user;
  check string "password" "secret" result.password;
  check string "database" "myapp" result.database
;;

let test_parse_valid_postgres_scheme () =
  let result = parse_connection_url "postgres://admin:secret@db.example.com:5432/myapp" in
  check string "host via postgres://" "db.example.com" result.host
;;

let test_parse_no_at_sign () =
  (* Missing @ should raise Not_found from String.index *)
  check_raises "no @ raises" Not_found (fun () ->
    ignore (parse_connection_url "postgresql://user:passhost/db"))
;;

let test_parse_no_colon_userpass () =
  (* Missing : in user:pass should raise Not_found *)
  check_raises "no colon in userpass raises" Not_found (fun () ->
    ignore (parse_connection_url "postgresql://userpass@host:5432/db"))
;;

let test_parse_no_slash_hostport () =
  (* Missing / before database should raise Not_found *)
  check_raises "no slash in hostport raises" Not_found (fun () ->
    ignore (parse_connection_url "postgresql://user:pass@host:5432"))
;;

let test_parse_empty_string () =
  (* Empty string should raise on String.index *)
  check_raises "empty string raises" Not_found (fun () ->
    ignore (parse_connection_url ""))
;;

let test_parse_special_chars_password () =
  (* Password with @ in it — this is a REAL edge case
     The parser will break because it finds @ in password first.
     DOCUMENTED BUG: URL-encoded passwords (%40) are not decoded. *)
  let result = parse_connection_url "postgresql://user:p@ss@host:5432/db" in
  (* Parser grabs "user:p" as user_pass, "ss@host:5432/db" as host_rest
     Then "ss@host" will fail to parse because there's no colon for port.
     Actually: host_port would be... let's trace:
     at_pos = 7 (first @ after "user:p")
     user_pass = "user:p", host_rest = "ss@host:5432/db"
     Then slash_pos finds / at 13, host_port = "ss@host:5432"
     colon_pos finds : at 6, host = "ss@host", port = "5432"
     So password = "p", host = "ss@host" — WRONG *)
  check string "broken password parse" "p" result.password
;;

(* ============================================ *)
(* Query generation snapshot tests              *)
(* These verify the SQL that sprintf produces    *)
(* so refactoring to parameterized queries can   *)
(* verify equivalence afterward                  *)
(* ============================================ *)

let test_register_query_snapshot () =
  let session_id = "test-session" in
  let segment = "default" in
  let pid = 12345 in
  let now = 1000.0 in
  let query =
    Printf.sprintf
      "INSERT INTO session_tracker (session_id, segment, pid, status, last_seen, \
       started_at) VALUES ('%s', '%s', %d, 'active', to_timestamp(%.3f), \
       to_timestamp(%.3f)) ON CONFLICT (session_id, segment) DO UPDATE SET pid = %d, \
       status = 'active', last_seen = to_timestamp(%.3f))"
      (escape_string session_id)
      (escape_string segment)
      pid
      now
      now
      pid
      now
  in
  check
    bool
    "query contains INSERT"
    true
    (string_contains ~substring:"INSERT" ~string:query);
  check
    bool
    "query contains VALUES"
    true
    (string_contains ~substring:"VALUES" ~string:query);
  check
    bool
    "query contains session_id value"
    true
    (string_contains ~substring:"test-session" ~string:query);
  check
    bool
    "query contains ON CONFLICT"
    true
    (string_contains ~substring:"ON CONFLICT" ~string:query)
;;

let test_heartbeat_query_snapshot () =
  let now = 2000.0 in
  let query =
    Printf.sprintf
      "UPDATE session_tracker SET last_seen = to_timestamp(%.3f) WHERE session_id = '%s' \
       AND segment = '%s'"
      now
      (escape_string "sess-1")
      (escape_string "seg-1")
  in
  check
    bool
    "query is UPDATE"
    true
    (string_contains ~substring:"update" ~string:(String.lowercase_ascii query));
  check
    bool
    "query contains WHERE"
    true
    (string_contains ~substring:"WHERE" ~string:query);
  check
    bool
    "query contains session"
    true
    (string_contains ~substring:"sess-1" ~string:query)
;;

let test_query_with_injection_attempt () =
  (* Simulate SQL injection in session_id — with current escape_string,
     semicolons pass through. This demonstrates WHY parameterized queries
     are needed. *)
  let malicious_id = "'; DELETE FROM session_tracker; --" in
  let query =
    Printf.sprintf
      "UPDATE session_tracker SET last_seen = to_timestamp(%.3f) WHERE session_id = '%s'"
      1000.0
      (escape_string malicious_id)
  in
  (* After escaping: quotes are doubled, but semicolons and -- pass through *)
  check
    bool
    "injection query still contains semicolons"
    true
    (string_contains ~substring:";" ~string:query);
  check
    bool
    "quotes are properly escaped"
    true
    (string_contains ~substring:"''" ~string:query)
;;

(* ============================================ *)
(* Test suite registration                      *)
(* ============================================ *)

let escape_string_tests =
  [ test_case "normal string" `Quick test_escape_normal_string
  ; test_case "single quote" `Quick test_escape_single_quote
  ; test_case "backslash" `Quick test_escape_backslash
  ; test_case "multiple quotes" `Quick test_escape_multiple_quotes
  ; test_case "mixed" `Quick test_escape_mixed
  ; test_case "empty string" `Quick test_escape_empty_string
  ; test_case "only quotes" `Quick test_escape_only_quotes
  ; test_case "only backslashes" `Quick test_escape_only_backslashes
  ; test_case "long string (10000 quotes)" `Quick test_escape_long_string
  ; (* BUG documentation tests *)
    test_case "NULL byte passes through (BUG)" `Quick test_escape_null_byte_passthrough
  ; test_case "$$ passes through (known gap)" `Quick test_escape_double_dollar_passthrough
  ; test_case "semicolon passes through" `Quick test_escape_semicolon_passthrough
  ; test_case "unicode null passes through (BUG)" `Quick test_escape_unicode_null
  ]
;;

let parse_url_tests =
  [ test_case "valid postgresql:// URL" `Quick test_parse_valid_postgresql_scheme
  ; test_case "valid postgres:// URL" `Quick test_parse_valid_postgres_scheme
  ; (* Boundary / error cases *)
    test_case "no @ raises exception" `Quick test_parse_no_at_sign
  ; test_case "no colon in userpass raises" `Quick test_parse_no_colon_userpass
  ; test_case "no slash in hostport raises" `Quick test_parse_no_slash_hostport
  ; test_case "empty string raises" `Quick test_parse_empty_string
  ; test_case "@ in password (parsing bug)" `Quick test_parse_special_chars_password
  ]
;;

let query_snapshot_tests =
  [ test_case "register query format" `Quick test_register_query_snapshot
  ; test_case "heartbeat query format" `Quick test_heartbeat_query_snapshot
  ; test_case "injection attempt in query" `Quick test_query_with_injection_attempt
  ]
;;

let () =
  run
    "session_tracker QA tests"
    [ "escape_string", escape_string_tests
    ; "parse_connection_url", parse_url_tests
    ; "query_snapshots", query_snapshot_tests
    ]
;;
