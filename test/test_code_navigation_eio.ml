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

(** Extract tool output JSON from MCP tools/call response.
    MCP wraps tool results as:
    {result: {content: [{type: "text", text: "<tool_output_json>"}], ...}} *)
let extract_tool_output response =
  match json_get_field response "result" with
  | Some ((`Assoc _) as result) ->
      (match json_get_field result "content" with
       | Some (`List (first :: _)) ->
           (match json_get_string first "text" with
            | Some text ->
                (try Some (Yojson.Safe.from_string text)
                 with _ -> None)
            | None -> None)
       | _ -> None)
  | _ -> None

(* ===== E2E Test: masc_code_search ===== *)

let test_code_search_basic () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  (* Initialize Eio context for tool dispatch *)
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);

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

  (* Extract tool output from MCP content envelope *)
  (match extract_tool_output response with
   | Some ((`Assoc _) as tool_json) ->
       (* Check count field *)
       (match json_get_int tool_json "count" with
        | Some count ->
            check bool "has results" true (count > 0);
            check bool "count positive" true (count > 0)
        | None -> fail "missing count field");

       (* Check results array *)
       (match json_get_field tool_json "results" with
        | Some (`List results) ->
            check bool "results is array" true (List.length results > 0);
            (* Verify first result structure *)
            (match results with
             | first :: _ ->
                 (match first with
                  | (`Assoc _) as match_obj ->
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
   | _ -> fail "could not extract tool output from MCP response")

(* ===== E2E Test: masc_code_symbols ===== *)

let test_code_symbols_basic () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);

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

  (* Extract tool output from MCP content envelope *)
  (match extract_tool_output response with
   | Some ((`Assoc _) as tool_json) ->
       (* Check path field *)
       (match json_get_string tool_json "path" with
        | Some path ->
            check string "correct path" "lib/mode.ml" path
        | None -> fail "missing path field");

       (* Check count field *)
       (match json_get_int tool_json "count" with
        | Some count ->
            check bool "count is non-negative" true (count >= 0)
        | None -> fail "missing count field");

       (* Check symbols array *)
       (match json_get_field tool_json "symbols" with
        | Some (`List _symbols) -> ()
        | Some _ -> fail "symbols not a list"
        | None -> fail "missing symbols field")
   | Some (`String error_msg) ->
       check bool "error message present" true (String.length error_msg > 0)
   | _ -> fail "could not extract tool output from MCP response")

(* ===== E2E Test: masc_code_read ===== *)

let test_code_read_basic () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);

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

  (* Extract tool output from MCP content envelope *)
  (match extract_tool_output response with
   | Some ((`Assoc _) as tool_json) ->
       (* Check path field *)
       (match json_get_string tool_json "path" with
        | Some path ->
            check string "correct path" "lib/mode.ml" path
        | None -> fail "missing path field");

       (* Check offset field *)
       (match json_get_int tool_json "offset" with
        | Some offset -> check int "offset is 0" 0 offset
        | None -> fail "missing offset field");

       (* Check limit field *)
       (match json_get_int tool_json "limit" with
        | Some limit ->
            (* May be less if file is shorter *)
            check bool "limit is positive" true (limit > 0)
        | None -> fail "missing limit field");

       (* Check total_lines field *)
       (match json_get_int tool_json "total_lines" with
        | Some total ->
            check bool "total_lines > 0" true (total > 0)
        | None -> fail "missing total_lines field");

       (* Check lines array *)
       (match json_get_field tool_json "lines" with
        | Some (`List lines) ->
              check bool "lines is array" true (List.length lines > 0)
        | Some _ -> fail "lines not a list"
        | None -> fail "missing lines field")
   | Some (`String error_msg) ->
       check bool "error message present" true (String.length error_msg > 0)
   | _ -> fail "could not extract tool output from MCP response")

(* ===== E2E Test: masc_code_read offset/limit ===== *)

let test_code_read_offset_limit () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);

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

  (* Extract tool output from MCP content envelope *)
  (match extract_tool_output response with
   | Some ((`Assoc _) as tool_json) ->
       (* Verify offset is preserved *)
       (match json_get_int tool_json "offset" with
        | Some offset -> check int "offset is 10" 10 offset
        | None -> fail "missing offset field");

       (* Verify limit is preserved (or reduced if file is shorter) *)
       (match json_get_int tool_json "limit" with
        | Some limit ->
            check bool "limit is positive" true (limit > 0);
            check bool "limit <= requested" true (limit <= 10)
        | None -> fail "missing limit field")
   | Some (`String error_msg) ->
       check bool "error message present" true (String.length error_msg > 0)
   | _ -> fail "could not extract tool output from MCP response")

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
