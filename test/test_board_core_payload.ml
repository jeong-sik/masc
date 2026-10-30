(** Regression tests for Board_core_payload.derive_post_title.

    Issue #7690: byte-based String.sub of the title cut through multi-byte
    UTF-8 characters (Korean, emoji), producing invalid UTF-8 lines in
    board_posts.jsonl. These tests verify the UTF-8-safe behavior. *)

open Alcotest
open Masc
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

(* Regression: malformed meta_json must surface as a typed parse error
   instead of being silently coerced to an empty meta object. Prior to
   2026-05-15 the catch-all at board_core_payload.ml:73 mapped any
   non-[`Assoc] payload to [fields = []], hiding structural drift. *)

let test_normalize_meta_json_none_is_ok_none () =
  match BP.normalize_meta_json None with
  | Ok None -> ()
  | Ok (Some _) -> fail "expected None for absent meta"
  | Error _ -> fail "absent meta must not be a parse error"

let test_normalize_meta_json_assoc_is_ok_some () =
  let meta = `Assoc [ ("k", `String "v") ] in
  match BP.normalize_meta_json (Some meta) with
  | Ok (Some (`Assoc [ ("k", `String "v") ])) -> ()
  | Ok _ -> fail "expected the original Assoc to round-trip"
  | Error _ -> fail "well-formed Assoc must not error"

let test_normalize_meta_json_string_payload_is_error () =
  let payload = `String "not an object" in
  match BP.normalize_meta_json (Some payload) with
  | Error (BP.Meta_not_assoc p) when p = payload -> ()
  | Error (BP.Meta_not_assoc _) -> fail "wrong payload in Meta_not_assoc"
  | Ok _ ->
      fail
        "non-[`Assoc] meta_json must now be Error Meta_not_assoc, not Ok []"

let test_normalize_meta_json_int_payload_is_error () =
  match BP.normalize_meta_json (Some (`Int 42)) with
  | Error (BP.Meta_not_assoc (`Int 42)) -> ()
  | Error _ -> fail "wrong payload in Meta_not_assoc"
  | Ok _ -> fail "non-[`Assoc] meta_json must error"

let test_normalize_meta_json_list_payload_is_error () =
  match BP.normalize_meta_json (Some (`List [ `Int 1 ])) with
  | Error (BP.Meta_not_assoc (`List _)) -> ()
  | Error _ -> fail "wrong payload in Meta_not_assoc"
  | Ok _ -> fail "non-[`Assoc] meta_json must error"

let () =
  run "Board_core_payload"
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
            test_derive_korean_with_json_roundtrip ] );
      ( "meta-not-assoc-typed-parse",
        [ test_case "None meta -> Ok None" `Quick
            test_normalize_meta_json_none_is_ok_none;
          test_case "Assoc meta -> Ok Some" `Quick
            test_normalize_meta_json_assoc_is_ok_some;
          test_case "`String payload -> Error Meta_not_assoc" `Quick
            test_normalize_meta_json_string_payload_is_error;
          test_case "`Int payload -> Error Meta_not_assoc" `Quick
            test_normalize_meta_json_int_payload_is_error;
          test_case "`List payload -> Error Meta_not_assoc" `Quick
            test_normalize_meta_json_list_payload_is_error ] ) ]
