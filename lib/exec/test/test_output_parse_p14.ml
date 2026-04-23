(* P14 tests: new parsers + UTF-8 boundary truncation *)

let ck_int ctx expected actual = Alcotest.(check int) ctx expected actual
let ck_str ctx expected actual = Alcotest.(check string) ctx expected actual

(* --- UTF-8 truncation tests --- *)

let test_utf8_ascii () =
  let s = "hello world" in
  let truncated = Masc_exec.Exec_buffer.utf8_truncate s 5 in
  ck_str "ascii" "hello" truncated

let test_utf8_korean () =
  (* "안녕하세요" = 5 Korean chars, each 3 bytes = 15 bytes total *)
  let s = "안녕하세요" in
  ck_int "korean_bytes" 15 (String.length s);
  (* Truncate at 7 bytes — would split "하" (bytes 6-8).
     Should yield "안녕" (6 bytes) to avoid splitting. *)
  let truncated = Masc_exec.Exec_buffer.utf8_truncate s 7 in
  ck_int "korean_truncated_bytes" 6 (String.length truncated);
  ck_str "korean_truncated" "안녕" truncated

let test_utf8_mixed () =
  (* "hi안" = 2 ASCII + 1 Korean = 2 + 3 = 5 bytes *)
  let s = "hi안" in
  ck_int "mixed_bytes" 5 (String.length s);
  (* Truncate at 4 bytes — "hi" + incomplete "안" *)
  let truncated = Masc_exec.Exec_buffer.utf8_truncate s 4 in
  ck_str "mixed_truncated" "hi" truncated

let test_utf8_no_truncation () =
  let s = "abc" in
  let truncated = Masc_exec.Exec_buffer.utf8_truncate s 10 in
  ck_str "no_trunc" "abc" truncated

let test_utf8_emoji () =
  (* "🎉" = U+1F389 = 4 bytes in UTF-8 *)
  let s = "hi🎉" in
  ck_int "emoji_bytes" 6 (String.length s);
  let truncated = Masc_exec.Exec_buffer.utf8_truncate s 3 in
  ck_str "emoji_truncated" "hi" truncated

(* --- gh pr list parser tests --- *)

let test_gh_pr_list_basic () =
  let output = "NUMBER\tTITLE\tSTATE\n123\tFix bug\tOPEN\n456\tAdd feature\tMERGED\n" in
  (match Masc_exec.Output_parse.try_parse
     ~cmd:"gh pr list"
     ~status:(Unix.WEXITED 0)
     ~output
   with
   | None -> Alcotest.fail "gh pr list should parse"
   | Some json ->
     (match json with
      | `Assoc l ->
        let count = List.assoc_opt "count" l in
        (match count with
         | Some (`Int 2) -> ()
         | v -> Alcotest.fail (Printf.sprintf "expected count 2, got %s"
             (Yojson.Safe.to_string (Option.value ~default:(`String "none") v))))
      | _ -> Alcotest.fail "expected assoc"))

let test_gh_pr_list_empty () =
  let output = "NUMBER\tTITLE\tSTATE\n" in
  (match Masc_exec.Output_parse.try_parse
     ~cmd:"gh pr list"
     ~status:(Unix.WEXITED 0)
     ~output
   with
   | None -> ()  (* no PRs = None, correct *)
   | Some _ -> Alcotest.fail "empty gh pr list should return None")

(* --- pytest parser tests --- *)

let test_pytest_passed_failed () =
  let output = "test_api.py ....F.\n\n2 passed, 1 failed in 1.23s\n" in
  (match Masc_exec.Output_parse.try_parse
     ~cmd:"pytest"
     ~status:(Unix.WEXITED 1)
     ~output
   with
   | None -> Alcotest.fail "pytest should parse"
   | Some json ->
     (match json with
      | `Assoc l ->
        (match List.assoc_opt "passed" l, List.assoc_opt "failed" l with
         | Some (`Int 2), Some (`Int 1) -> ()
         | _ -> Alcotest.fail "pytest counts mismatch")
      | _ -> Alcotest.fail "expected assoc"))

let test_pytest_all_passed () =
  let output = "test_main.py ....\n4 passed in 0.5s\n" in
  (match Masc_exec.Output_parse.try_parse
     ~cmd:"pytest"
     ~status:(Unix.WEXITED 0)
     ~output
   with
   | None -> Alcotest.fail "pytest should parse all passed"
   | Some json ->
     (match json with
      | `Assoc l ->
        (match List.assoc_opt "passed" l with
         | Some (`Int 4) -> ()
         | _ -> Alcotest.fail "pytest passed count mismatch")
      | _ -> Alcotest.fail "expected assoc"))

(* --- cargo test parser tests --- *)

let test_cargo_test_ok () =
  let output = "running 3 tests\ntest test_a ... ok\ntest test_b ... ok\ntest test_c ... ok\n\ntest result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n" in
  (match Masc_exec.Output_parse.try_parse
     ~cmd:"cargo test"
     ~status:(Unix.WEXITED 0)
     ~output
   with
   | None -> Alcotest.fail "cargo test should parse"
   | Some json ->
     (match json with
      | `Assoc l ->
        (match List.assoc_opt "passed" l, List.assoc_opt "failed" l with
         | Some (`Int 3), Some (`Int 0) -> ()
         | _ -> Alcotest.fail "cargo test counts mismatch")
      | _ -> Alcotest.fail "expected assoc"))

let test_cargo_test_failures () =
  let output = "test result: FAILED. 2 passed; 1 failed; 0 ignored\n" in
  (match Masc_exec.Output_parse.try_parse
     ~cmd:"cargo test"
     ~status:(Unix.WEXITED 101)
     ~output
   with
   | None -> Alcotest.fail "cargo test should parse with failures"
   | Some json ->
     (match json with
      | `Assoc l ->
        (match List.assoc_opt "passed" l, List.assoc_opt "failed" l with
         | Some (`Int 2), Some (`Int 1) -> ()
         | _ -> Alcotest.fail "cargo test failure counts mismatch")
      | _ -> Alcotest.fail "expected assoc"))

(* --- existing parsers still work --- *)

let test_git_status_unchanged () =
  let output = "M lib/foo.ml\n?? lib/bar.ml\n" in
  (match Masc_exec.Output_parse.try_parse
     ~cmd:"git status --porcelain"
     ~status:(Unix.WEXITED 0)
     ~output
   with
   | None -> Alcotest.fail "git status should still parse"
   | Some (`Assoc l) ->
     (match List.assoc_opt "untracked" l with
      | Some (`List xs) -> ck_int "untracked_count" 1 (List.length xs)
      | _ -> Alcotest.fail "untracked missing")
   | Some _ -> Alcotest.fail "expected assoc")

let () =
  test_utf8_ascii ();
  test_utf8_korean ();
  test_utf8_mixed ();
  test_utf8_no_truncation ();
  test_utf8_emoji ();
  test_gh_pr_list_basic ();
  test_gh_pr_list_empty ();
  test_pytest_passed_failed ();
  test_pytest_all_passed ();
  test_cargo_test_ok ();
  test_cargo_test_failures ();
  test_git_status_unchanged ();
  print_endline "test_output_parse_p14: 12/12 passed"
