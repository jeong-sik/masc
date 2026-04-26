(** Tests for Masc_core.String_util UTF-8-safe truncation. *)

open Alcotest
module SU = String_util

(* Regression fixture: the exact byte sequence that caused board_posts.jsonl
   corruption (Issue #7690). `나머지 리뷰` = 15 bytes UTF-8. *)
let korean_title = "나머지 리뷰"

(* Emoji test: each 😀 is 4 bytes in UTF-8 (\xf0\x9f\x98\x80). *)
let three_smileys = "😀😀😀"

let is_valid_utf8 s =
  (* Use Yojson's string encoder as a UTF-8 validator proxy:
     Yojson.Safe.to_string accepts any OCaml string, but decoding
     back and round-tripping confirms UTF-8 validity. *)
  try
    let encoded = Yojson.Safe.to_string (`String s) in
    let decoded = Yojson.Safe.from_string encoded in
    match decoded with
    | `String s' -> s' = s
    | _ -> false
  with _ -> false

(* ---- utf8_char_boundary ---- *)

let test_boundary_ascii_in_bounds () =
  (* ASCII: any index is a boundary *)
  let s = "hello" in
  check int "mid-ASCII" 3 (SU.utf8_char_boundary s 3);
  check int "end" 5 (SU.utf8_char_boundary s 5);
  check int "past-end clamped" 5 (SU.utf8_char_boundary s 99);
  check int "zero" 0 (SU.utf8_char_boundary s 0)

let test_boundary_korean_cuts_back () =
  (* "나" = \xeb\x82\x98 (3 bytes), "머" = \xeb\xa8\xb8 (3 bytes) *)
  let s = korean_title in
  (* byte 0: start of "나" (lead) — clean boundary *)
  check int "start" 0 (SU.utf8_char_boundary s 0);
  (* byte 3: start of "머" — clean boundary *)
  check int "after na" 3 (SU.utf8_char_boundary s 3);
  (* byte 1: middle of "나" (continuation) — cut back to 0 *)
  check int "mid-na-1" 0 (SU.utf8_char_boundary s 1);
  (* byte 2: still in "나" — cut back to 0 *)
  check int "mid-na-2" 0 (SU.utf8_char_boundary s 2);
  (* byte 4: middle of "머" — cut back to 3 *)
  check int "mid-meo-1" 3 (SU.utf8_char_boundary s 4)

let test_boundary_emoji_4byte () =
  (* Each 😀 is 4 bytes: F0 9F 98 80 *)
  let s = three_smileys in
  check int "start" 0 (SU.utf8_char_boundary s 0);
  check int "after-first" 4 (SU.utf8_char_boundary s 4);
  (* Any byte inside a 😀 sequence cuts back to nearest boundary *)
  check int "mid-first-1" 0 (SU.utf8_char_boundary s 1);
  check int "mid-first-2" 0 (SU.utf8_char_boundary s 2);
  check int "mid-first-3" 0 (SU.utf8_char_boundary s 3);
  check int "mid-second-5" 4 (SU.utf8_char_boundary s 5)

(* ---- utf8_safe (the main variant API) ---- *)

let test_safe_untouched_short () =
  match SU.utf8_safe ~max_bytes:100 ~suffix:"..." "hi" with
  | Untouched s -> check string "identity" "hi" s
  | Truncated _ -> fail "unexpected truncation"

let test_safe_truncated_ascii () =
  match SU.utf8_safe ~max_bytes:8 ~suffix:"..." "abcdefghijklmno" with
  | Untouched _ -> fail "should have truncated"
  | Truncated { prefix; suffix; dropped_bytes } ->
      check string "prefix" "abcde" prefix;
      check string "suffix" "..." suffix;
      check int "dropped_bytes" 10 dropped_bytes;
      check bool "total <= max" true
        (String.length prefix + String.length suffix <= 8)

let test_safe_truncated_korean_is_valid_utf8 () =
  (* Budget 10 bytes incl. "..." (3 bytes) → prefix budget 7 bytes.
     Korean chars are 3 bytes each, so prefix can fit 2 chars = 6 bytes.
     (The 7th byte would be a lead byte we cannot complete.)
     Result: valid UTF-8 "나머..." *)
  match SU.utf8_safe ~max_bytes:10 ~suffix:"..." korean_title with
  | Untouched _ -> fail "should have truncated"
  | Truncated { prefix; _ } as t ->
      let s = SU.to_string t in
      check bool "result valid UTF-8" true (is_valid_utf8 s);
      (* prefix must be valid on its own *)
      check bool "prefix valid UTF-8" true (is_valid_utf8 prefix);
      (* Budget respected *)
      check bool "within budget" true (String.length s <= 10)

let test_safe_utf8_suffix () =
  (* Use horizontal-ellipsis char (… = 3 bytes UTF-8) as suffix *)
  let ellipsis = "\xe2\x80\xa6" in
  match SU.utf8_safe ~max_bytes:12 ~suffix:ellipsis korean_title with
  | Untouched _ -> fail "should have truncated"
  | Truncated _ as t ->
      let s = SU.to_string t in
      check bool "combined valid UTF-8" true (is_valid_utf8 s);
      check bool "within budget" true (String.length s <= 12)

let test_safe_emoji_4byte_boundary () =
  (* Budget 5 bytes, 😀 is 4 bytes. Suffix "." (1 byte) leaves 4 bytes
     for prefix. One 😀 fits exactly. *)
  match SU.utf8_safe ~max_bytes:5 ~suffix:"." three_smileys with
  | Untouched _ -> fail "should have truncated"
  | Truncated { prefix; dropped_bytes; _ } ->
      check string "prefix is one emoji" "😀" prefix;
      check int "dropped_bytes" 8 dropped_bytes

let test_safe_empty_string () =
  match SU.utf8_safe ~max_bytes:10 ~suffix:"..." "" with
  | Untouched s -> check string "identity empty" "" s
  | Truncated _ -> fail "empty should be untouched"

let test_safe_zero_budget () =
  (* max_bytes=0 with non-empty input → Truncated with empty prefix and
     suffix as-is. to_string yields just the suffix. *)
  match SU.utf8_safe ~max_bytes:0 ~suffix:"X" "abc" with
  | Untouched _ -> fail "should have truncated"
  | Truncated { prefix; suffix; dropped_bytes } ->
      check string "empty prefix" "" prefix;
      check string "suffix kept" "X" suffix;
      check int "dropped all 3" 3 dropped_bytes

let test_safe_suffix_longer_than_budget () =
  (* Suffix 5 bytes but max 3. budget becomes 0 → prefix empty. *)
  match SU.utf8_safe ~max_bytes:3 ~suffix:"....." "abcdefg" with
  | Untouched _ -> fail "should have truncated"
  | Truncated { prefix; _ } ->
      check string "empty prefix when suffix>=max" "" prefix

let test_was_truncated_and_to_string () =
  let short = SU.utf8_safe ~max_bytes:100 ~suffix:"..." "hi" in
  let long = SU.utf8_safe ~max_bytes:3 ~suffix:"..." "abcdefg" in
  check bool "short not truncated" false (SU.was_truncated short);
  check bool "long truncated" true (SU.was_truncated long);
  check string "to_string short" "hi" (SU.to_string short)

let test_safe_invalid_utf8_best_effort () =
  (* Construct: valid "A" + lone lead byte \xe0 + some cont bytes.
     Budget 2 bytes forces a cut. Any result must be valid UTF-8 or at
     least not introduce new invalid sequences beyond the input. *)
  let orphan = "A\xe0\x80\x80" in
  match SU.utf8_safe ~max_bytes:2 ~suffix:"" orphan with
  | Untouched _ -> fail "should have truncated"
  | Truncated { prefix; _ } ->
      (* Best-effort: ASCII "A" should be preserved, orphan dropped *)
      check string "best-effort keeps ASCII" "A" prefix

(* ---- find_substring ---- *)

let check_int_option = check (option int)

let test_find_substring_basic () =
  check_int_option "first occurrence" (Some 0)
    (SU.find_substring "abcabc" "abc");
  check_int_option "respects pos" (Some 3)
    (SU.find_substring ~pos:1 "abcabc" "abc");
  check_int_option "absent" None
    (SU.find_substring "abcabc" "z")

let test_find_substring_boundaries () =
  check_int_option "match at last valid index" (Some 2)
    (SU.find_substring ~pos:2 "aaaa" "aa");
  check_int_option "pos past last valid index" None
    (SU.find_substring ~pos:3 "aaaa" "aa");
  check_int_option "pos at end" None
    (SU.find_substring ~pos:4 "aaaa" "a")

let test_find_substring_empty_needle () =
  check_int_option "empty returns pos" (Some 2)
    (SU.find_substring ~pos:2 "abc" "");
  check_int_option "empty can return end" (Some 3)
    (SU.find_substring ~pos:3 "abc" "")

let test_find_substring_rejects_negative_pos () =
  check_raises "negative pos" (Invalid_argument
    "String_util.find_substring: negative position")
    (fun () -> ignore (SU.find_substring ~pos:(-1) "abc" "a"))

(* ---- substring containment ---- *)

let test_contains_substring_basic () =
  check bool "middle" true (SU.contains_substring "hello world" "lo wo");
  check bool "exact" true (SU.contains_substring "abc" "abc");
  check bool "absent" false (SU.contains_substring "abc" "xyz");
  check bool "needle longer" false (SU.contains_substring "ab" "abc")

let test_contains_substring_empty_needle () =
  check bool "empty needle" true (SU.contains_substring "abc" "");
  check bool "both empty" true (SU.contains_substring "" "")

let test_contains_substring_literal_metacharacters () =
  check bool "regex chars are literal" true
    (SU.contains_substring "literal .* needle" ".*");
  check bool "regex wildcard is not magic" false
    (SU.contains_substring "literal abc needle" ".*")

let test_contains_substring_utf8_bytes () =
  check bool "Korean substring" true (SU.contains_substring korean_title "머지");
  check bool "emoji substring" true (SU.contains_substring three_smileys "😀")

let test_contains_substring_ci_ascii () =
  check bool "ASCII case-insensitive" true
    (SU.contains_substring_ci "Keeper Board POST" "board post");
  check bool "mixed-case needle" true
    (SU.contains_substring_ci "sandbox profile" "BOX PRO");
  check bool "absent" false
    (SU.contains_substring_ci "sandbox profile" "keeper")

let test_contains_substring_ci_empty_and_literal () =
  check bool "empty needle stays false" false
    (SU.contains_substring_ci "abc" "");
  check bool "regex chars are literal" true
    (SU.contains_substring_ci "literal .* needle" ".*");
  check bool "regex wildcard is not magic" false
    (SU.contains_substring_ci "literal abc needle" ".*")

let test_starts_with_ci_basic () =
  check bool "exact case" true
    (SU.starts_with_ci ~prefix:"Bearer " "Bearer abc123");
  check bool "lowercase prefix vs mixed value" true
    (SU.starts_with_ci ~prefix:"bearer " "Bearer abc123");
  check bool "uppercase prefix vs lowercase value" true
    (SU.starts_with_ci ~prefix:"BEARER " "bearer abc123");
  check bool "mismatch" false
    (SU.starts_with_ci ~prefix:"Bearer " "Basic abc123")

let test_starts_with_ci_boundaries () =
  check bool "empty prefix matches anything" true
    (SU.starts_with_ci ~prefix:"" "anything");
  check bool "empty prefix matches empty string" true
    (SU.starts_with_ci ~prefix:"" "");
  check bool "prefix longer than string" false
    (SU.starts_with_ci ~prefix:"hello" "hi");
  check bool "exact length equal" true
    (SU.starts_with_ci ~prefix:"abc" "ABC")

let test_equals_ci_basic () =
  check bool "exact" true (SU.equals_ci "Content-Type" "Content-Type");
  check bool "case insensitive" true (SU.equals_ci "Content-Type" "content-type");
  check bool "mixed case" true (SU.equals_ci "X-Trace-Id" "x-TRACE-id");
  check bool "different content" false (SU.equals_ci "Content-Type" "Accept");
  check bool "length mismatch" false (SU.equals_ci "abc" "abcd");
  check bool "empty equals empty" true (SU.equals_ci "" "");
  check bool "empty vs non-empty" false (SU.equals_ci "" "x")


(* ---- Test runner ---- *)

let () =
  run "string_util"
    [ ( "utf8_char_boundary",
        [ test_case "ASCII in-bounds" `Quick test_boundary_ascii_in_bounds;
          test_case "Korean cuts back" `Quick test_boundary_korean_cuts_back;
          test_case "Emoji 4-byte" `Quick test_boundary_emoji_4byte ] );
      ( "utf8_safe",
        [ test_case "short untouched" `Quick test_safe_untouched_short;
          test_case "ASCII truncated" `Quick test_safe_truncated_ascii;
          test_case "Korean UTF-8 valid" `Quick
            test_safe_truncated_korean_is_valid_utf8;
          test_case "UTF-8 suffix (ellipsis)" `Quick test_safe_utf8_suffix;
          test_case "emoji 4-byte boundary" `Quick
            test_safe_emoji_4byte_boundary;
          test_case "empty string" `Quick test_safe_empty_string;
          test_case "zero budget" `Quick test_safe_zero_budget;
          test_case "suffix >= budget" `Quick
            test_safe_suffix_longer_than_budget;
          test_case "was_truncated + to_string" `Quick
            test_was_truncated_and_to_string;
          test_case "invalid UTF-8 best-effort" `Quick
            test_safe_invalid_utf8_best_effort ] );
      ( "find_substring",
        [ test_case "basic" `Quick test_find_substring_basic;
          test_case "boundaries" `Quick test_find_substring_boundaries;
          test_case "empty needle" `Quick test_find_substring_empty_needle;
          test_case "negative pos rejected" `Quick
            test_find_substring_rejects_negative_pos ] );
      ( "contains_substring",
        [ test_case "basic" `Quick test_contains_substring_basic;
          test_case "empty needle" `Quick
            test_contains_substring_empty_needle;
          test_case "literal metacharacters" `Quick
            test_contains_substring_literal_metacharacters;
          test_case "UTF-8 bytes" `Quick test_contains_substring_utf8_bytes ] );
      ( "contains_substring_ci",
        [ test_case "ASCII" `Quick test_contains_substring_ci_ascii;
          test_case "empty and literal" `Quick
            test_contains_substring_ci_empty_and_literal ] );
      ( "starts_with_ci",
        [ test_case "basic" `Quick test_starts_with_ci_basic;
          test_case "boundaries" `Quick test_starts_with_ci_boundaries ] );
      ( "equals_ci",
        [ test_case "basic" `Quick test_equals_ci_basic ] ) ]
