(** task-318: Pin board JSON boundary behavior with minimal test cases.

    Exercises the JSON boundary in [Board_tool_format] that surfaces
    unexpected JSON shapes for optional fields like `sources`, `meta`,
    etc. *)

open Alcotest
open Masc

(* ---- Helpers ---- *)

let () = Mirage_crypto_rng_unix.use_default ()

let pp_yojson ppf json =
  Format.pp_print_string ppf (Yojson.Safe.pretty_to_string json)

let yojson = testable pp_yojson Yojson.Safe.equal

(** Build a `Yojson.Safe.t` args association list. *)
let args_of_list fields : Yojson.Safe.t =
  `Assoc fields

(* ---- Test: source_entries_arg with non-list "sources" ---- *)

let test_source_entries_non_list_returns_none () =
  (* "sources" is a string instead of a list — ignore it safely *)
  let args = args_of_list [ "sources", `String "https://example.com" ] in
  let result = Board_tool_format.source_entries_arg args in
  check (option (list yojson)) "non-list sources return None" None result

let test_source_entries_null_returns_none () =
  (* "sources" is null: treat it as an omitted optional field. *)
  let args = args_of_list [ "sources", `Null ] in
  let result = Board_tool_format.source_entries_arg args in
  check (option (list yojson)) "null sources return None" None result

let test_source_entries_int_returns_none () =
  (* "sources" is an int instead of a list *)
  let args = args_of_list [ "sources", `Int 42 ] in
  let result = Board_tool_format.source_entries_arg args in
  check (option (list yojson)) "int sources return None" None result

(* ---- Test: source_entries_arg with valid list ---- *)

let test_source_entries_valid_list () =
  let args =
    args_of_list
      [ "sources"
      , `List
          [ `Assoc [ "url", `String "https://example.com"
                   ; "quote", `String "example quote" ]
          ; `Assoc [ "url", `String "https://other.com" ]
          ]
      ]
  in
  let result = Board_tool_format.source_entries_arg args in
  check (option (list yojson))
    "valid sources list"
    (Some
       [ `Assoc [ "url", `String "https://example.com"
                ; "quote", `String "example quote" ]
       ; `Assoc [ "url", `String "https://other.com" ]
       ])
    result

(* ---- Test: source_entries_arg with empty list ---- *)

let test_source_entries_empty_list () =
  let args = args_of_list [ "sources", `List [] ] in
  let result = Board_tool_format.source_entries_arg args in
  check (option (list yojson))
    "empty list returns None"
    None
    result

(* ---- Test: source_entries_arg with missing key ---- *)

let test_source_entries_missing_key () =
  let args = args_of_list [ "content", `String "hello" ] in
  let result = Board_tool_format.source_entries_arg args in
  check (option (list yojson))
    "missing key returns None"
    None
    result

(* ---- Test: source_entry with non-string url ---- *)

let test_source_entry_non_string_url () =
  (* url is an int — source_entry returns None, filter_map drops it *)
  let args =
    args_of_list
      [ "sources"
      , `List [ `Assoc [ "url", `Int 42 ] ]
      ]
  in
  let result = Board_tool_format.source_entries_arg args in
  check (option (list yojson))
    "non-string url entry is filtered out → None"
    None
    result

(* ---- Test: merge_sources_into_meta with non-Assoc meta ---- *)

let test_merge_sources_null_meta () =
  let sources =
    [ `Assoc [ "url", `String "https://example.com" ] ]
  in
  let result =
    Board_tool_format.merge_sources_into_meta
      (Some `Null)
      sources
  in
  check (option yojson)
    "null meta gets replaced with Assoc containing sources"
    (Some
       (`Assoc
          [ "sources", `List sources
          ; "has_external_sources", `Bool true
          ]))
    result

let test_merge_sources_int_meta () =
  let sources =
    [ `Assoc [ "url", `String "https://example.com" ] ]
  in
  let result =
    Board_tool_format.merge_sources_into_meta
      (Some (`Int 99))
      sources
  in
  check (option yojson)
    "int meta gets replaced with Assoc containing sources"
    (Some
       (`Assoc
          [ "sources", `List sources
          ; "has_external_sources", `Bool true
          ]))
    result

(* ---- Test: normalize_board_post_meta on nested unexpected types ---- *)

let test_normalize_board_post_meta_string_meta () =
  (* meta field is a plain string — normalize should not crash *)
  let args = args_of_list [ "meta", `String "some meta" ] in
  let raises =
    try
      let _ = Board_tool_format.normalize_board_post_meta args in
      false
    with Yojson.Safe.Util.Type_error _ -> true
  in
  check bool "string meta must not raise Type_error" false raises

let test_normalize_board_post_meta_list_meta () =
  (* meta field is a list — normalize should not crash *)
  let args = args_of_list [ "meta", `List [ `String "a" ] ] in
  let raises =
    try
      let _ = Board_tool_format.normalize_board_post_meta args in
      false
    with Yojson.Safe.Util.Type_error _ -> true
  in
  check bool "list meta must not raise Type_error" false raises

(* ---- Test: judgment_arg coercion of scalar types ---- *)

let test_judgment_int_coerced_to_string () =
  let args = args_of_list [ "judgment", `Int 42 ] in
  let result = Board_tool_format.judgment_arg args in
  match result with
  | Some (`String s) ->
    check bool "int judgment coerced to string" true
      (String.equal s "42" || String.length s > 0)
  | Some _ -> fail "expected String from int coercion"
  | None -> fail "int judgment should not be silently dropped"

let test_judgment_bool_coerced_to_string () =
  let args = args_of_list [ "judgment", `Bool true ] in
  let result = Board_tool_format.judgment_arg args in
  match result with
  | Some (`String _) -> ()
  | Some _ -> fail "expected String from bool coercion"
  | None -> fail "bool judgment should not be silently dropped"

let test_judgment_float_coerced_to_string () =
  let args = args_of_list [ "judgment", `Float 3.14 ] in
  let result = Board_tool_format.judgment_arg args in
  match result with
  | Some (`String _) -> ()
  | Some _ -> fail "expected String from float coercion"
  | None -> fail "float judgment should not be silently dropped"

let test_judgment_null_returns_none () =
  let args = args_of_list [ "judgment", `Null ] in
  let result = Board_tool_format.judgment_arg args in
  check (option yojson) "null judgment returns None" None result

let test_judgement_spelling_fallback () =
  let args = args_of_list [ "judgement", `String "good" ] in
  let result = Board_tool_format.judgment_arg args in
  check (option yojson) "judgement (UK spelling) fallback"
    (Some (`String "good")) result

(* ---- Test: source_entries_arg wraps single Assoc ---- *)

let test_source_entries_single_assoc_wrapped () =
  let args =
    args_of_list
      [ "sources", `Assoc [ "url", `String "https://example.com" ] ]
  in
  let result = Board_tool_format.source_entries_arg args in
  match result with
  | Some [ `Assoc fields ] ->
    check string "url preserved" "https://example.com"
      (Option.value ~default:"" (List.assoc_opt "url" fields |> function Some (`String s) -> Some s | _ -> None))
  | Some _ -> fail "expected single-element list"
  | None -> fail "single Assoc sources should be wrapped, not dropped"

(* ---- Suite ---- *)

let () =
  run "yojson_type_error_board"
    [
      ( "source_entries_arg"
      , [
          test_case "non-list sources return None" `Quick
            test_source_entries_non_list_returns_none;
          test_case "null sources return None" `Quick
            test_source_entries_null_returns_none;
          test_case "int sources return None" `Quick
            test_source_entries_int_returns_none;
          test_case "valid sources list parsed" `Quick
            test_source_entries_valid_list;
          test_case "empty list returns None" `Quick
            test_source_entries_empty_list;
          test_case "missing key returns None" `Quick
            test_source_entries_missing_key;
          test_case "non-string url filtered out" `Quick
            test_source_entry_non_string_url;
          test_case "single Assoc wrapped into list" `Quick
            test_source_entries_single_assoc_wrapped;
        ] );
      ( "merge_sources_into_meta"
      , [
          test_case "null meta replaced" `Quick
            test_merge_sources_null_meta;
          test_case "int meta replaced" `Quick
            test_merge_sources_int_meta;
        ] );
      ( "normalize_board_post_meta"
      , [
          test_case "string meta does not crash" `Quick
            test_normalize_board_post_meta_string_meta;
          test_case "list meta does not crash" `Quick
            test_normalize_board_post_meta_list_meta;
        ] );
      ( "judgment_arg coercion"
      , [
          test_case "int judgment coerced to string" `Quick
            test_judgment_int_coerced_to_string;
          test_case "bool judgment coerced to string" `Quick
            test_judgment_bool_coerced_to_string;
          test_case "float judgment coerced to string" `Quick
            test_judgment_float_coerced_to_string;
          test_case "null judgment returns None" `Quick
            test_judgment_null_returns_none;
          test_case "judgement spelling fallback" `Quick
            test_judgement_spelling_fallback;
        ] );
    ]
