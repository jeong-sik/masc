(** Tests for keeper_exec_github.gh_not_found_hint.

    Verifies the not-found hint logic that detects hallucinated
    issue/PR numbers from gh CLI error output.

    Cases:
    1. WEXITED 1 + "Could not resolve..." -> hint present
    2. WEXITED 0 + any output            -> hint absent
    3. WEXITED 1 + unrelated error        -> hint absent
    4. Case-insensitive matching works
    5. Additional error phrases detected *)

open Alcotest

let hint = Masc_mcp.Keeper_gh_shared.gh_not_found_hint
let truncate = Masc_mcp.Keeper_gh_shared.truncate_gh_output
let max_gh_output_bytes = Masc_mcp.Keeper_gh_shared.max_gh_output_bytes

let has_hint result =
  List.exists (fun (k, _) -> k = "hint") result

(* --- WEXITED 1 + "Could not resolve" -> hint present --- *)

let test_exit1_could_not_resolve () =
  let result = hint
    ~st:(Unix.WEXITED 1)
    ~out:"Could not resolve to a pull request with the number 999" in
  check bool "hint present for Could not resolve"
    true (has_hint result)

(* --- WEXITED 0 -> hint absent regardless of output --- *)

let test_exit0_no_hint () =
  let result = hint
    ~st:(Unix.WEXITED 0)
    ~out:"Could not resolve to a pull request with the number 999" in
  check bool "hint absent when exit 0"
    false (has_hint result)

(* --- WEXITED 1 + unrelated error -> hint absent --- *)

let test_exit1_other_error () =
  let result = hint
    ~st:(Unix.WEXITED 1)
    ~out:"HTTP 502: Bad Gateway" in
  check bool "hint absent for unrelated error"
    false (has_hint result)

(* --- Case-insensitive: "could not resolve" (lowercase) --- *)

let test_case_insensitive_resolve () =
  let result = hint
    ~st:(Unix.WEXITED 1)
    ~out:"could not resolve to a pull request" in
  check bool "hint present for lowercase could not resolve"
    true (has_hint result)

(* --- Additional phrase: "Could not find" --- *)

let test_could_not_find () =
  let result = hint
    ~st:(Unix.WEXITED 1)
    ~out:"Could not find issue #12345" in
  check bool "hint present for Could not find"
    true (has_hint result)

(* --- Additional phrase: "No such issue" --- *)

let test_no_such_issue () =
  let result = hint
    ~st:(Unix.WEXITED 1)
    ~out:"No such issue exists in this repository" in
  check bool "hint present for No such issue"
    true (has_hint result)

(* --- Additional phrase: "not found" --- *)

let test_not_found () =
  let result = hint
    ~st:(Unix.WEXITED 1)
    ~out:"issue not found" in
  check bool "hint present for not found"
    true (has_hint result)

(* --- WEXITED 1 + empty output -> hint absent --- *)

let test_exit1_empty_output () =
  let result = hint
    ~st:(Unix.WEXITED 1)
    ~out:"" in
  check bool "hint absent for empty output"
    false (has_hint result)

(* --- Non-WEXITED status (e.g. WSIGNALED) + matching output -> hint present.
       Any non-zero/non-WEXITED(0) status is treated as failure. --- *)

let test_signaled_with_matching_output () =
  let result = hint
    ~st:(Unix.WSIGNALED 9)
    ~out:"Could not resolve to a pull request" in
  check bool "hint present for WSIGNALED with matching output"
    true (has_hint result)

(* --- Hint text content verification --- *)

let test_hint_text_content () =
  let result = hint
    ~st:(Unix.WEXITED 1)
    ~out:"Could not resolve to a pull request with the number 42" in
  match List.assoc_opt "hint" result with
  | Some (`String s) ->
    check bool "hint mentions issue list"
      true (String.length s > 0
            && (try ignore (Str.search_forward
                  (Str.regexp_string "issue list") s 0); true
                with Not_found -> false));
    check bool "hint mentions pr list"
      true (try ignore (Str.search_forward
                  (Str.regexp_string "pr list") s 0); true
            with Not_found -> false)
  | _ -> fail "expected hint key with string value"

let test_truncate_preserves_short_output () =
  let out = "short gh output" in
  let truncated, fields = truncate out in
  check string "unchanged output" out truncated;
  check int "no metadata" 0 (List.length fields)

let test_truncate_caps_total_length () =
  let out = String.make (max_gh_output_bytes + 512) 'a' in
  let truncated, fields = truncate out in
  check bool "marked truncated"
    true
    (List.mem_assoc "truncated" fields);
  check (option int) "original bytes recorded"
    (Some (String.length out))
    (match List.assoc_opt "original_bytes" fields with
     | Some (`Int n) -> Some n
     | _ -> None);
  check bool "shown bytes recorded"
    true
    (match List.assoc_opt "shown_bytes" fields with
     | Some (`Int n) -> n >= 0
     | _ -> false);
  check bool "total output is capped"
    true
    (String.length truncated <= max_gh_output_bytes)

let () =
  run "keeper_github_hint"
    [ "not_found_detection",
      [ test_case "exit1 + Could not resolve -> hint" `Quick
          test_exit1_could_not_resolve
      ; test_case "exit0 -> no hint" `Quick
          test_exit0_no_hint
      ; test_case "exit1 + other error -> no hint" `Quick
          test_exit1_other_error
      ; test_case "case insensitive resolve" `Quick
          test_case_insensitive_resolve
      ; test_case "Could not find" `Quick
          test_could_not_find
      ; test_case "No such issue" `Quick
          test_no_such_issue
      ; test_case "not found" `Quick
          test_not_found
      ; test_case "exit1 + empty -> no hint" `Quick
          test_exit1_empty_output
      ; test_case "WSIGNALED + match -> hint" `Quick
          test_signaled_with_matching_output
      ; test_case "hint text content" `Quick
          test_hint_text_content
      ; test_case "short output unchanged" `Quick
          test_truncate_preserves_short_output
      ; test_case "truncate caps total length" `Quick
          test_truncate_caps_total_length
      ]
    ]
