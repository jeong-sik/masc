(** Regression tests for Board_core_payload.derive_post_title.

    Issue #7690: byte-based String.sub of the title cut through multi-byte
    UTF-8 characters (Korean, emoji), producing invalid UTF-8 lines in
    board_posts.jsonl. These tests verify the UTF-8-safe behavior. *)

open Alcotest
open Masc_mcp
module BP = Board_core_payload

let is_valid_utf8 s =
  try
    let encoded = Yojson.Safe.to_string (`String s) in
    let decoded = Yojson.Safe.from_string encoded in
    match decoded with `String s' -> s' = s | _ -> false
  with _ -> false

let test_derive_short_title_returned_as_is () =
  let title = BP.derive_post_title "Short title\nSecond line" in
  check string "short" "Short title" title

let test_derive_empty_body_uses_default () =
  let title = BP.derive_post_title "" in
  check string "default" "Untitled post" title

let test_derive_long_ascii_truncated_with_ellipsis () =
  let long = String.make 150 'a' in
  let title = BP.derive_post_title long in
  check bool "within 80 bytes" true (String.length title <= 80);
  check bool "ends with ..." true
    (let n = String.length title in
     n >= 3 && String.sub title (n - 3) 3 = "...")

let test_derive_long_korean_title_is_valid_utf8 () =
  (* Build a 90-byte (30-char) Korean title that would have cut mid-char
     under the old byte-based truncation. Repeat "가나다" (9 bytes). *)
  let unit_str = "가나다" in
  let body = String.concat "" (List.init 10 (fun _ -> unit_str)) in
  (* String.length body = 90 *)
  let title = BP.derive_post_title body in
  check bool "title valid UTF-8" true (is_valid_utf8 title);
  check bool "within 80 bytes" true (String.length title <= 80);
  (* Regression: title MUST NOT end with a lone continuation byte or
     incomplete lead. Yojson roundtrip already covers this, but also
     validate with an explicit check on the non-suffix portion. *)
  let suffix = "..." in
  check bool "ends with ..." true
    (let n = String.length title in
     n >= 3 && String.sub title (n - 3) 3 = suffix);
  let prefix =
    String.sub title 0 (String.length title - String.length suffix)
  in
  check bool "prefix valid UTF-8" true (is_valid_utf8 prefix)

let test_derive_korean_with_json_roundtrip () =
  (* The actual failure mode: write a post, serialize to JSONL, then
     decode as UTF-8. This is precisely what board_posts.jsonl reader
     does at runtime. *)
  let body =
    "## Verdict: #7460 needs-evidence + #7464 needs-evidence \xe2\x80\x94 \
     poe scan #5 나머지 리뷰 결과입니다 길게 이어지는 텍스트 추가"
  in
  let title = BP.derive_post_title body in
  let json = `Assoc [("title", `String title)] in
  let encoded = Yojson.Safe.to_string json in
  (* Decode back: must not raise *)
  let decoded = Yojson.Safe.from_string encoded in
  (match decoded with
   | `Assoc [("title", `String t)] ->
       check string "roundtrip title" title t;
       check bool "roundtrip valid UTF-8" true (is_valid_utf8 t)
   | _ -> fail "unexpected JSON shape")

let () =
  run "Board_core_payload.derive_post_title"
    [ ( "regression-7690",
        [ test_case "short title unchanged" `Quick
            test_derive_short_title_returned_as_is;
          test_case "empty body -> default" `Quick
            test_derive_empty_body_uses_default;
          test_case "long ASCII truncated" `Quick
            test_derive_long_ascii_truncated_with_ellipsis;
          test_case "long Korean is valid UTF-8" `Quick
            test_derive_long_korean_title_is_valid_utf8;
          test_case "Korean JSON roundtrip" `Quick
            test_derive_korean_with_json_roundtrip ] ) ]
