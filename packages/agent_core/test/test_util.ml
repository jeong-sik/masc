(** Unit tests for Util — pure helper functions extracted across the
    Agent Core. No IO, no Eio. *)

open Agent_core
open Alcotest

(* ── first_some ────────────────────────────────────────── *)

let test_first_some_left_some () =
  check (option int) "Some/Some → left" (Some 1) (Util.first_some (Some 1) (Some 2))
;;

let test_first_some_left_none () =
  check (option int) "None/Some → right" (Some 2) (Util.first_some None (Some 2))
;;

let test_first_some_both_none () =
  check (option int) "None/None → None" None (Util.first_some None None)
;;

(* ── string_contains ──────────────────────────────────── *)

let test_string_contains_present () =
  check bool "needle in haystack" true (Util.string_contains ~needle:"bar" "foobarbaz")
;;

let test_string_contains_absent () =
  check bool "needle missing" false (Util.string_contains ~needle:"qux" "foobarbaz")
;;

let test_string_contains_empty_needle () =
  check bool "empty needle → true" true (Util.string_contains ~needle:"" "abc")
;;

let test_string_contains_at_start () =
  check bool "at start" true (Util.string_contains ~needle:"foo" "foobar")
;;

let test_string_contains_at_end () =
  check bool "at end" true (Util.string_contains ~needle:"baz" "foobaz")
;;

let test_string_contains_needle_longer () =
  check
    bool
    "needle longer than haystack"
    false
    (Util.string_contains ~needle:"abcdef" "abc")
;;

(* ── snoc / snoc_list ─────────────────────────────────── *)

let test_snoc_empty () = check (list int) "snoc to empty" [ 1 ] (Util.snoc [] 1)

let test_snoc_nonempty () =
  check (list int) "snoc appends to end" [ 1; 2; 3 ] (Util.snoc [ 1; 2 ] 3)
;;

let test_snoc_list_empty_left () =
  check (list int) "snoc_list [] xs" [ 1; 2 ] (Util.snoc_list [] [ 1; 2 ])
;;

let test_snoc_list_concat () =
  check
    (list int)
    "snoc_list concatenates"
    [ 1; 2; 3; 4 ]
    (Util.snoc_list [ 1; 2 ] [ 3; 4 ])
;;

(* ── result_traverse ──────────────────────────────────── *)

let test_result_traverse_all_ok () =
  match Util.result_traverse ~f:(fun x -> Ok (x * 2)) [ 1; 2; 3 ] with
  | Ok [ 2; 4; 6 ] -> ()
  | Ok xs -> failf "got %s" (String.concat ";" (List.map string_of_int xs))
  | Error _ -> fail "expected Ok"
;;

let test_result_traverse_short_circuits () =
  let calls = ref 0 in
  let f x =
    incr calls;
    if x = 2 then Error "boom" else Ok x
  in
  match Util.result_traverse ~f [ 1; 2; 3 ] with
  | Error "boom" ->
    (* short-circuited at the second element — should not visit the third *)
    check int "stopped at first error" 2 !calls
  | _ -> fail "expected Error boom"
;;

let test_result_traverse_empty () =
  match Util.result_traverse ~f:(fun _ -> Error "never") [] with
  | Ok [] -> ()
  | _ -> fail "expected Ok []"
;;

(* ── clip ─────────────────────────────────────────────── *)

let test_clip_short () = check string "no change when shorter" "hi" (Util.clip "hi" 10)
let test_clip_exact () = check string "no change when equal" "hello" (Util.clip "hello" 5)

let test_clip_long () =
  check string "appends ellipsis" "abcde..." (Util.clip "abcdefghi" 5)
;;

(* ── safe_sub ─────────────────────────────────────────── *)

let test_safe_sub_normal () =
  check string "regular slice" "bcd" (Util.safe_sub "abcdef" 1 3)
;;

let test_safe_sub_past_end () =
  check string "len past end clamps" "ef" (Util.safe_sub "abcdef" 4 10)
;;

let test_safe_sub_negative () =
  check string "negative len → empty" "" (Util.safe_sub "abc" 0 (-1))
;;

let test_safe_sub_start_at_end () =
  check string "start at end → empty" "" (Util.safe_sub "abc" 3 5)
;;

(* ── contains_substring_ci ────────────────────────────── *)

let test_ci_match_lower () =
  check
    bool
    "needle in haystack lower"
    true
    (Util.contains_substring_ci ~haystack:"hello world" ~needle:"world")
;;

let test_ci_match_upper () =
  check
    bool
    "case insensitive"
    true
    (Util.contains_substring_ci ~haystack:"Hello World" ~needle:"WORLD")
;;

let test_ci_match_mixed () =
  check
    bool
    "mixed case haystack/needle"
    true
    (Util.contains_substring_ci ~haystack:"FoOBaR" ~needle:"oobar")
;;

let test_ci_no_match () =
  check bool "no match" false (Util.contains_substring_ci ~haystack:"abc" ~needle:"xyz")
;;

let test_ci_empty_needle () =
  check
    bool
    "empty needle → true"
    true
    (Util.contains_substring_ci ~haystack:"abc" ~needle:"")
;;

let test_ci_needle_longer () =
  check
    bool
    "needle longer → false"
    false
    (Util.contains_substring_ci ~haystack:"abc" ~needle:"abcdef")
;;

let test_ci_literal_metacharacters () =
  check
    bool
    "regex metacharacters are literal"
    false
    (Util.contains_substring_ci ~haystack:"abc" ~needle:".*")
;;

(* ── regex_match ──────────────────────────────────────── *)

let test_regex_match_hit () =
  let re = Str.regexp "[0-9]+" in
  check bool "digits found" true (Util.regex_match re "abc 42 def")
;;

let test_regex_match_miss () =
  let re = Str.regexp "[0-9]+" in
  check bool "digits absent" false (Util.regex_match re "no numbers here")
;;

let test_regex_match_anchor () =
  let re = Str.regexp "^foo" in
  check bool "matches at anchor" true (Util.regex_match re "foobar")
;;

(* ── error constructors (smoke tests) ─────────────────── *)

let test_json_parse_error_shape () =
  match Util.json_parse_error "bad token" with
  | Error.Serialization (Error.JsonParseError { detail }) ->
    check string "detail preserved" "bad token" detail
  | _ -> fail "expected Serialization JsonParseError"
;;

let test_file_read_error_shape () =
  match Util.file_read_error ~path:"/tmp/x" ~detail:"ENOENT" with
  | Error.Io (Error.FileOpFailed { op; path; detail }) ->
    check string "op" "read" op;
    check string "path" "/tmp/x" path;
    check string "detail" "ENOENT" detail
  | _ -> fail "expected Io FileOpFailed read"
;;

let test_file_write_error_shape () =
  match Util.file_write_error ~path:"/tmp/y" ~detail:"EACCES" with
  | Error.Io (Error.FileOpFailed { op; path; detail }) ->
    check string "op" "write" op;
    check string "path" "/tmp/y" path;
    check string "detail" "EACCES" detail
  | _ -> fail "expected Io FileOpFailed write"
;;

let () =
  run
    "Util"
    [ ( "first_some"
      , [ test_case "left Some" `Quick test_first_some_left_some
        ; test_case "left None" `Quick test_first_some_left_none
        ; test_case "both None" `Quick test_first_some_both_none
        ] )
    ; ( "string_contains"
      , [ test_case "present" `Quick test_string_contains_present
        ; test_case "absent" `Quick test_string_contains_absent
        ; test_case "empty needle" `Quick test_string_contains_empty_needle
        ; test_case "at start" `Quick test_string_contains_at_start
        ; test_case "at end" `Quick test_string_contains_at_end
        ; test_case "needle longer" `Quick test_string_contains_needle_longer
        ] )
    ; ( "snoc"
      , [ test_case "snoc empty" `Quick test_snoc_empty
        ; test_case "snoc nonempty" `Quick test_snoc_nonempty
        ; test_case "snoc_list empty left" `Quick test_snoc_list_empty_left
        ; test_case "snoc_list concat" `Quick test_snoc_list_concat
        ] )
    ; ( "result_traverse"
      , [ test_case "all Ok" `Quick test_result_traverse_all_ok
        ; test_case "short-circuits" `Quick test_result_traverse_short_circuits
        ; test_case "empty list" `Quick test_result_traverse_empty
        ] )
    ; ( "clip"
      , [ test_case "shorter" `Quick test_clip_short
        ; test_case "equal" `Quick test_clip_exact
        ; test_case "longer" `Quick test_clip_long
        ] )
    ; ( "safe_sub"
      , [ test_case "normal" `Quick test_safe_sub_normal
        ; test_case "past end clamps" `Quick test_safe_sub_past_end
        ; test_case "negative len" `Quick test_safe_sub_negative
        ; test_case "start at end" `Quick test_safe_sub_start_at_end
        ] )
    ; ( "contains_substring_ci"
      , [ test_case "lower" `Quick test_ci_match_lower
        ; test_case "upper" `Quick test_ci_match_upper
        ; test_case "mixed" `Quick test_ci_match_mixed
        ; test_case "no match" `Quick test_ci_no_match
        ; test_case "empty needle" `Quick test_ci_empty_needle
        ; test_case "needle longer" `Quick test_ci_needle_longer
        ; test_case "literal metacharacters" `Quick test_ci_literal_metacharacters
        ] )
    ; ( "regex_match"
      , [ test_case "hit" `Quick test_regex_match_hit
        ; test_case "miss" `Quick test_regex_match_miss
        ; test_case "anchor" `Quick test_regex_match_anchor
        ] )
    ; ( "error constructors"
      , [ test_case "json_parse_error" `Quick test_json_parse_error_shape
        ; test_case "file_read_error" `Quick test_file_read_error_shape
        ; test_case "file_write_error" `Quick test_file_write_error_shape
        ] )
    ]
;;
