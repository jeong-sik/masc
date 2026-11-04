(** Pure-function unit tests for [Briefing_json_helpers].

    Audit P2 follow-up (2026-04-29 §3.1.2) — listed in the
    "테스트 완전 부재 모듈 10건" with the note that all four
    briefing_*.ml modules ship without unit tests.  Closes the
    smallest of the four (82 LOC impl, 14 LOC mli) with property
    pins on every exposed helper. *)

module B = Briefing_json_helpers

(* ─── compact_text ─────────────────────────────────────────── *)

let test_compact_text_empty () =
  assert (B.compact_text "" = "");
  assert (B.compact_text "   " = "")

let test_compact_text_passthrough () =
  assert (B.compact_text "hello" = "hello")

let test_compact_text_collapses_newlines () =
  assert (B.compact_text "line1\nline2" = "line1 line2")

let test_compact_text_trims_outer () =
  assert (B.compact_text "  hello  " = "hello")

let test_compact_text_preserves_internal_spaces () =
  assert (B.compact_text "a  b   c" = "a  b   c")

(* ─── member_assoc ─────────────────────────────────────────── *)

let test_member_assoc_present () =
  let j = `Assoc [ ("k", `String "v"); ("n", `Int 42) ] in
  assert (B.member_assoc "k" j = `String "v");
  assert (B.member_assoc "n" j = `Int 42)

let test_member_assoc_missing () =
  let j = `Assoc [ ("k", `String "v") ] in
  assert (B.member_assoc "missing" j = `Null)

let test_member_assoc_non_assoc () =
  assert (B.member_assoc "k" (`String "scalar") = `Null);
  assert (B.member_assoc "k" `Null = `Null);
  assert (B.member_assoc "k" (`List []) = `Null)

(* ─── string_field ─────────────────────────────────────────── *)

let test_string_field_present () =
  let j = `Assoc [ ("name", `String "alice") ] in
  assert (B.string_field "name" j = "alice")

let test_string_field_default () =
  let j = `Assoc [ ("other", `String "x") ] in
  assert (B.string_field ~default:"D" "missing" j = "D");
  assert (B.string_field "missing" j = "")  (* implicit default = "" *)

let test_string_field_wrong_type () =
  let j = `Assoc [ ("count", `Int 5) ] in
  assert (B.string_field ~default:"fallback" "count" j = "fallback")

(* ─── take ─────────────────────────────────────────────────── *)

let test_take_zero () =
  assert (B.take 0 [ 1; 2; 3 ] = [])

let test_take_negative () =
  assert (B.take (-1) [ 1; 2; 3 ] = [])

let test_take_more_than_length () =
  assert (B.take 10 [ 1; 2 ] = [ 1; 2 ])

let test_take_partial () =
  assert (B.take 2 [ 1; 2; 3; 4 ] = [ 1; 2 ])

let test_take_empty () =
  assert (B.take 5 [] = [])

(* ─── option_string_json ───────────────────────────────────── *)

let test_option_string_json_some () =
  match Json_util.string_opt_to_json_trimmed (Some "hello") with
  | `String "hello" -> ()
  | _ -> assert false

let test_option_string_json_some_blank () =
  (* Behaviour contract: blank/whitespace-only strings are
     trimmed to "" and projected to `Null. *)
  assert (Json_util.string_opt_to_json_trimmed (Some "   ") = `Null);
  assert (Json_util.string_opt_to_json_trimmed (Some "") = `Null)

let test_option_string_json_none () =
  assert (Json_util.string_opt_to_json_trimmed None = `Null)

let test_option_string_json_trims () =
  match Json_util.string_opt_to_json_trimmed (Some "  trimmed  ") with
  | `String "trimmed" -> ()
  | _ -> assert false

(* ─── runner ───────────────────────────────────────────────── *)

let () =
  test_compact_text_empty ();
  test_compact_text_passthrough ();
  test_compact_text_collapses_newlines ();
  test_compact_text_trims_outer ();
  test_compact_text_preserves_internal_spaces ();
  test_member_assoc_present ();
  test_member_assoc_missing ();
  test_member_assoc_non_assoc ();
  test_string_field_present ();
  test_string_field_default ();
  test_string_field_wrong_type ();
  test_take_zero ();
  test_take_negative ();
  test_take_more_than_length ();
  test_take_partial ();
  test_take_empty ();
  test_option_string_json_some ();
  test_option_string_json_some_blank ();
  test_option_string_json_none ();
  test_option_string_json_trims ();
  print_endline "test_briefing_json_helpers: all assertions passed"
