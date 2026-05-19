(** task-318: Pin board JSON boundary behavior with minimal test cases.

    Exercises the JSON boundary in [Tool_board_format] that surfaces
    unexpected JSON shapes for optional fields like `sources`, `meta`,
    etc. *)

open Alcotest
open Masc_mcp

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
  let result = Tool_board_format.source_entries_arg args in
  check (option (list yojson)) "non-list sources return None" None result

let test_source_entries_null_returns_none () =
  (* "sources" is null instead of a list *)
  let args = args_of_list [ "sources", `Null ] in
  let result = Tool_board_format.source_entries_arg args in
  check (option (list yojson)) "null sources return None" None result

let test_source_entries_int_returns_none () =
  (* "sources" is an int instead of a list *)
  let args = args_of_list [ "sources", `Int 42 ] in
  let result = Tool_board_format.source_entries_arg args in
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
  let result = Tool_board_format.source_entries_arg args in
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
  let result = Tool_board_format.source_entries_arg args in
  check (option (list yojson))
    "empty list returns None"
    None
    result

(* ---- Test: source_entries_arg with missing key ---- *)

let test_source_entries_missing_key () =
  let args = args_of_list [ "content", `String "hello" ] in
  let result = Tool_board_format.source_entries_arg args in
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
  let result = Tool_board_format.source_entries_arg args in
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
    Tool_board_format.merge_sources_into_meta
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
    Tool_board_format.merge_sources_into_meta
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
      let _ = Tool_board_format.normalize_board_post_meta args in
      false
    with Yojson.Safe.Util.Type_error _ -> true
  in
  check bool "string meta must not raise Type_error" false raises

let test_normalize_board_post_meta_list_meta () =
  (* meta field is a list — normalize should not crash *)
  let args = args_of_list [ "meta", `List [ `String "a" ] ] in
  let raises =
    try
      let _ = Tool_board_format.normalize_board_post_meta args in
      false
    with Yojson.Safe.Util.Type_error _ -> true
  in
  check bool "list meta must not raise Type_error" false raises

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
    ]
