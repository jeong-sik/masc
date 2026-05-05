(** Pure-function unit tests for [Briefing_json_helpers].

    Audit P2 follow-up (2026-04-29 §3.1.2) — listed in the
    "테스트 완전 부재 모듈 10건" with the note that all four
    briefing_*.ml modules ship without unit tests.  Closes the
    smallest of the four (82 LOC impl, 14 LOC mli) with property
    pins on every exposed helper. *)

module B = Masc_mcp.Briefing_json_helpers

(* Diagnostic helper — prints the actual JSON value when a
   pattern-match fallback fires, instead of bare [assert false].
   Keeps the runner [assert]-driven for consistency with sibling
   test suites while improving failure messages. *)
let unexpected_json ~where j =
  failwith
    (Printf.sprintf "%s: unexpected JSON %s" where
       (Yojson.Safe.to_string j))

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

(* ─── string_json ──────────────────────────────────────────── *)

let test_string_json_passthrough () =
  match B.string_json (`String "hello") with
  | `String s -> assert (s = "hello")
  | _ -> assert false

let test_string_json_empty_uses_default () =
  match B.string_json ~default:"FALLBACK" (`String "") with
  | `String s -> assert (s = "FALLBACK")
  | _ -> assert false

let test_string_json_non_string_uses_default () =
  match B.string_json ~default:"FB" (`Int 7) with
  | `String s -> assert (s = "FB")
  | _ -> assert false

let test_string_json_default_default () =
  (* implicit default = "unknown" *)
  match B.string_json `Null with
  | `String s -> assert (s = "unknown")
  | other -> unexpected_json ~where:"string_json_default_default" other

(* ─── string_list_json ─────────────────────────────────────── *)

let test_string_list_filters_blanks () =
  let input =
    `List [ `String "a"; `String ""; `String "  "; `String "b" ]
  in
  match B.string_list_json input with
  | `List items ->
      let strs =
        List.map
          (function `String s -> s | _ -> assert false)
          items
      in
      assert (strs = [ "a"; "b" ])
  | _ -> assert false

let test_string_list_drops_non_strings () =
  let input =
    `List [ `String "a"; `Int 1; `Bool true; `String "b" ]
  in
  match B.string_list_json input with
  | `List items -> assert (List.length items = 2)
  | _ -> assert false

let test_string_list_non_list_returns_empty () =
  match B.string_list_json (`String "scalar") with
  | `List [] -> ()
  | _ -> assert false

let test_string_list_trims_entries () =
  let input = `List [ `String "  hi  " ] in
  match B.string_list_json input with
  | `List [ `String "hi" ] -> ()
  | _ -> assert false

(* ─── int_json ─────────────────────────────────────────────── *)

let test_int_json_int_passthrough () =
  assert (B.int_json (`Int 42) = `Int 42)

let test_int_json_intlit_parses () =
  assert (B.int_json (`Intlit "100") = `Int 100)

let test_int_json_intlit_garbage_uses_default () =
  assert (B.int_json ~default:7 (`Intlit "not_a_number") = `Int 7)

let test_int_json_float_truncates () =
  assert (B.int_json (`Float 3.7) = `Int 3)

let test_int_json_other_uses_default () =
  assert (B.int_json ~default:9 (`String "5") = `Int 9);
  assert (B.int_json ~default:0 `Null = `Int 0)

(* ─── float_json ───────────────────────────────────────────── *)

let test_float_json_float_passthrough () =
  assert (B.float_json (`Float 1.5) = `Float 1.5)

let test_float_json_int_promotes () =
  assert (B.float_json (`Int 7) = `Float 7.0)

let test_float_json_intlit_parses () =
  (* Use exactly-representable doubles to avoid float-literal
     parsing edge cases. *)
  assert (B.float_json (`Intlit "1.5") = `Float 1.5);
  assert (B.float_json (`Intlit "0.25") = `Float 0.25)

let test_float_json_intlit_garbage_uses_default () =
  assert (
    B.float_json ~default:9.5 (`Intlit "junk") = `Float 9.5)

let test_float_json_other_uses_default () =
  assert (B.float_json ~default:8.0 `Null = `Float 8.0);
  assert (B.float_json ~default:0.0 (`String "1.0") = `Float 0.0)

(* ─── int_field ────────────────────────────────────────────── *)

let test_int_field_int () =
  let j = `Assoc [ ("count", `Int 5) ] in
  assert (B.int_field "count" j = 5)

let test_int_field_intlit_parses () =
  let j = `Assoc [ ("count", `Intlit "12345") ] in
  assert (B.int_field "count" j = 12345)

let test_int_field_intlit_garbage_uses_default () =
  let j = `Assoc [ ("count", `Intlit "gibberish") ] in
  assert (B.int_field ~default:99 "count" j = 99)

let test_int_field_float_truncates () =
  let j = `Assoc [ ("count", `Float 2.9) ] in
  assert (B.int_field "count" j = 2)

let test_int_field_missing () =
  let j = `Assoc [] in
  assert (B.int_field ~default:42 "missing" j = 42)

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
  match B.option_string_json (Some "hello") with
  | `String "hello" -> ()
  | _ -> assert false

let test_option_string_json_some_blank () =
  (* Behaviour contract: blank/whitespace-only strings are
     trimmed to "" and projected to `Null. *)
  assert (B.option_string_json (Some "   ") = `Null);
  assert (B.option_string_json (Some "") = `Null)

let test_option_string_json_none () =
  assert (B.option_string_json None = `Null)

let test_option_string_json_trims () =
  match B.option_string_json (Some "  trimmed  ") with
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
  test_string_json_passthrough ();
  test_string_json_empty_uses_default ();
  test_string_json_non_string_uses_default ();
  test_string_json_default_default ();
  test_string_list_filters_blanks ();
  test_string_list_drops_non_strings ();
  test_string_list_non_list_returns_empty ();
  test_string_list_trims_entries ();
  test_int_json_int_passthrough ();
  test_int_json_intlit_parses ();
  test_int_json_intlit_garbage_uses_default ();
  test_int_json_float_truncates ();
  test_int_json_other_uses_default ();
  test_float_json_float_passthrough ();
  test_float_json_int_promotes ();
  test_float_json_intlit_parses ();
  test_float_json_intlit_garbage_uses_default ();
  test_float_json_other_uses_default ();
  test_int_field_int ();
  test_int_field_intlit_parses ();
  test_int_field_intlit_garbage_uses_default ();
  test_int_field_float_truncates ();
  test_int_field_missing ();
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
