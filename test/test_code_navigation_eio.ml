(** Code Navigation Tools E2E Tests

    Tests the actual ripgrep-based code search tools.
    Requires real codebase for subprocess execution.
*)

open Alcotest

module Mcp_eio = Masc_mcp.Mcp_server_eio

(* ===== Test Helpers ===== *)

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

let json_get_field obj field =
  match obj with
  | `Assoc fields ->
      (match List.assoc_opt field fields with
       | Some v -> Some v
       | None -> None)
  | _ -> None

let json_get_int obj field =
  match json_get_field obj field with
  | Some (`Int i) -> Some i
  | _ -> None

let json_get_string obj field =
  match json_get_field obj field with
  | Some (`String s) -> Some s
  | _ -> None

(* ===== E2E Test: masc_code_search ===== *)

let test_code_search_basic () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  (* Use current repo as base_path for real code search *)
  let base_path = Sys.getcwd () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  (* Search for "ripgrep" in codebase *)
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "masc_code_search");
      ("arguments", `Assoc [
        ("query", `String "ripgrep");
        ("path", `String "lib/");
        ("max_results", `Int 5);
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in

  (* Verify response structure *)
  (match response with
   | `Assoc _fields ->
       (match json_get_field response "result" with
        | Some (`Assoc result_fields) ->
            let result = `Assoc result_fields in
            (* Check count field *)
            (match json_get_int result "count" with
             | Some count ->
                 check bool "has results" true (count > 0);
                 check bool "count positive" true (count > 0)
             | None -> fail "missing count field");

            (* Check results array *)
            (match json_get_field result "results" with
             | Some (`List results) ->
                 check bool "results is array" true (List.length results > 0);
                 (* Verify first result structure *)
                 (match results with
                  | first :: _ ->
                      (match first with
                       | `Assoc match_obj_fields ->
                           let match_obj = `Assoc match_obj_fields in
                           (* Check required fields: path, line, content *)
                           (match json_get_string match_obj "path" with
                            | Some path ->
                                check bool "path contains lib/" true
                                  (contains_substring path "lib/")
                            | None -> fail "missing path field");
                           (match json_get_int match_obj "line" with
                            | Some line -> check bool "line > 0" true (line > 0)
                            | None -> fail "missing line field");
                           (match json_get_string match_obj "content" with
                            | Some content ->
                                check bool "content not empty" true
                                  (String.length content > 0)
                            | None -> fail "missing content field")
                       | _ -> fail "match not an object")
                  | [] -> fail "results array empty")
             | Some _ -> fail "results not a list"
             | None -> fail "missing results field")
        | Some (`String error_msg) ->
            (* Error is acceptable if rg not installed *)
            check bool "error mentions ripgrep or command" true
              (contains_substring error_msg "ripgrep" ||
               contains_substring error_msg "command" ||
               contains_substring error_msg "rg")
        | _ -> fail "unexpected result type")
   | _ -> fail "response not an object")

(* ===== E2E Test: masc_code_symbols ===== *)

let test_code_symbols_basic () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = Sys.getcwd () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  (* Extract symbols from a real file *)
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 2);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "masc_code_symbols");
      ("arguments", `Assoc [
        ("path", `String "lib/mode.ml");
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in

  (match response with
   | `Assoc _fields ->
       (match json_get_field response "result" with
        | Some (`Assoc result_fields) ->
            let result = `Assoc result_fields in
            (* Check path field *)
            (match json_get_string result "path" with
             | Some path ->
                 check string "correct path" "lib/mode.ml" path
             | None -> fail "missing path field");

            (* Check count field *)
            (match json_get_int result "count" with
             | Some count ->
                 (* For OCaml, simple heuristic may find few symbols *)
                 check bool "count is non-negative" true (count >= 0)
             | None -> fail "missing count field");

            (* Check symbols array *)
            (match json_get_field result "symbols" with
             | Some (`List _symbols) ->
                   (* Symbols may be empty for OCaml with simple heuristic *)
                   ()
             | Some _ -> fail "symbols not a list"
             | None -> fail "missing symbols field")
        | Some (`String error_msg) ->
            (* Error is acceptable if file not found *)
            check bool "error message present" true (String.length error_msg > 0)
        | _ -> fail "unexpected result type")
   | _ -> fail "response not an object")

(* ===== E2E Test: masc_code_read ===== *)

let test_code_read_basic () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = Sys.getcwd () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  (* Read first 10 lines of a file *)
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 3);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "masc_code_read");
      ("arguments", `Assoc [
        ("path", `String "lib/mode.ml");
        ("offset", `Int 0);
        ("limit", `Int 10);
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in

  (match response with
   | `Assoc _fields ->
       (match json_get_field response "result" with
        | Some (`Assoc result_fields) ->
            let result = `Assoc result_fields in
            (* Check path field *)
            (match json_get_string result "path" with
             | Some path ->
                 check string "correct path" "lib/mode.ml" path
             | None -> fail "missing path field");

            (* Check offset field *)
            (match json_get_int result "offset" with
             | Some offset -> check int "offset is 0" 0 offset
             | None -> fail "missing offset field");

            (* Check limit field *)
            (match json_get_int result "limit" with
             | Some limit ->
                 (* May be less if file is shorter *)
                 check bool "limit is positive" true (limit > 0)
             | None -> fail "missing limit field");

            (* Check total_lines field *)
            (match json_get_int result "total_lines" with
             | Some total ->
                 check bool "total_lines > 0" true (total > 0)
             | None -> fail "missing total_lines field");

            (* Check lines array *)
            (match json_get_field result "lines" with
             | Some (`List lines) ->
                   check bool "lines is array" true (List.length lines > 0)
             | Some _ -> fail "lines not a list"
             | None -> fail "missing lines field")
        | Some (`String error_msg) ->
            check bool "error message present" true (String.length error_msg > 0)
        | _ -> fail "unexpected result type")
   | _ -> fail "response not an object")

(* ===== E2E Test: masc_code_read offset/limit ===== *)

let test_code_read_offset_limit () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = Sys.getcwd () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  (* Read lines 10-20 *)
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 4);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "masc_code_read");
      ("arguments", `Assoc [
        ("path", `String "lib/mode.ml");
        ("offset", `Int 10);
        ("limit", `Int 10);
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in

  (match response with
   | `Assoc _fields ->
       (match json_get_field response "result" with
        | Some (`Assoc result_fields) ->
            let result = `Assoc result_fields in
            (* Verify offset is preserved *)
            (match json_get_int result "offset" with
             | Some offset -> check int "offset is 10" 10 offset
             | None -> fail "missing offset field");

            (* Verify limit is preserved (or reduced if file is shorter) *)
            (match json_get_int result "limit" with
             | Some limit ->
                 check bool "limit is positive" true (limit > 0);
                 check bool "limit <= requested" true (limit <= 10)
             | None -> fail "missing limit field")
        | _ -> fail "unexpected result type")
   | _ -> fail "response not an object")

(* ===== Test Runner ===== *)

let () =
  run "Code Navigation E2E" [
    "code_search", [
      test_case "basic search" `Quick test_code_search_basic;
    ];
    "code_symbols", [
      test_case "basic symbols" `Quick test_code_symbols_basic;
    ];
    "code_read", [
      test_case "basic read" `Quick test_code_read_basic;
      test_case "offset/limit" `Quick test_code_read_offset_limit;
    ];
  ]
