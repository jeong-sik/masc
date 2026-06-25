(* Vision_analyze tests — the analyze_image pure contract.
   RFC-keeper-vision-delegation-tool §2.2.

   Locks the failure contract: an empty or truncated vision reply is a typed
   error, never Ok "". The truncated case encodes the measured 2026-06-25 gemma4
   cause (done_reason=length with empty content). *)

module V = Multimodal.Vision_analyze

let is_error = function
  | Error _ -> true
  | Ok _ -> false

(* ── make_request: boundary validation, fail closed ── *)

let test_make_request_ok () =
  match
    V.make_request ~query:"what is this?" ~image_media_type:"image/png"
      ~image_bytes:"\x89PNG"
  with
  | Ok r ->
    assert (String.equal r.V.query "what is this?");
    assert (String.equal r.V.image_media_type "image/png");
    assert (String.equal r.V.image_bytes "\x89PNG")
  | Error e -> failwith e

let test_make_request_rejects_blank_query () =
  assert (is_error (V.make_request ~query:"   " ~image_media_type:"image/png" ~image_bytes:"x"))

let test_make_request_rejects_empty_bytes () =
  assert (is_error (V.make_request ~query:"q" ~image_media_type:"image/png" ~image_bytes:""))

let test_make_request_rejects_blank_media_type () =
  assert (is_error (V.make_request ~query:"q" ~image_media_type:"" ~image_bytes:"x"))

(* ── done_reason normalization ── *)

let test_done_reason_of_string () =
  assert (V.done_reason_of_string "stop" = V.Stop);
  assert (V.done_reason_of_string "end_turn" = V.Stop);
  assert (V.done_reason_of_string "  STOP " = V.Stop);
  assert (V.done_reason_of_string "length" = V.Length);
  assert (V.done_reason_of_string "max_tokens" = V.Length);
  match V.done_reason_of_string "content_filter" with
  | V.Other s -> assert (String.equal s "content_filter")
  | _ -> assert false

(* ── classify: the contract ── *)

let test_classify_non_empty_is_ok () =
  match V.classify ~done_reason:V.Stop ~content:"  Crimson  " with
  | Ok t -> assert (String.equal t "Crimson")
  | Error _ -> assert false

(* partial-but-present text under a length cap is still usable -> Ok, not error. *)
let test_classify_non_empty_under_length_is_ok () =
  match V.classify ~done_reason:V.Length ~content:"a red square, partially" with
  | Ok t -> assert (String.equal t "a red square, partially")
  | Error _ -> assert false

(* the gemma4 case: empty content + length -> truncated, not empty. *)
let test_classify_empty_length_is_truncated () =
  assert (V.classify ~done_reason:V.Length ~content:"" = Error V.Truncated_extraction)

let test_classify_whitespace_length_is_truncated () =
  assert (V.classify ~done_reason:V.Length ~content:"  \n " = Error V.Truncated_extraction)

(* empty content with a normal stop -> empty_extraction (model produced nothing). *)
let test_classify_empty_stop_is_empty () =
  assert (V.classify ~done_reason:V.Stop ~content:"" = Error V.Empty_extraction)

let test_classify_empty_other_is_empty () =
  assert (
    V.classify ~done_reason:(V.Other "content_filter") ~content:""
    = Error V.Empty_extraction)

(* never Ok "" — the failure class this RFC targets. *)
let test_classify_never_ok_empty () =
  List.iter
    (fun dr ->
      match V.classify ~done_reason:dr ~content:"" with
      | Ok s -> assert (String.length s > 0)
      | Error _ -> ())
    [ V.Stop; V.Length; V.Other "x" ]

let test_string_of_error () =
  assert (String.equal (V.string_of_error V.Empty_extraction) "empty_extraction");
  assert (String.equal (V.string_of_error V.Truncated_extraction) "truncated_extraction")

let () =
  test_make_request_ok ();
  test_make_request_rejects_blank_query ();
  test_make_request_rejects_empty_bytes ();
  test_make_request_rejects_blank_media_type ();
  test_done_reason_of_string ();
  test_classify_non_empty_is_ok ();
  test_classify_non_empty_under_length_is_ok ();
  test_classify_empty_length_is_truncated ();
  test_classify_whitespace_length_is_truncated ();
  test_classify_empty_stop_is_empty ();
  test_classify_empty_other_is_empty ();
  test_classify_never_ok_empty ();
  test_string_of_error ();
  print_endline "test_vision_analyze: all assertions passed"
