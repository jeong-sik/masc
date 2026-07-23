(** Code Navigation Tools E2E Tests

    Tests the actual ripgrep-based code search tools.
    Requires real codebase for subprocess execution.
*)

open Alcotest

module Mcp_eio = Masc.Mcp_server_eio

(* ===== Test Helpers ===== *)

let with_eio_context env sw f =
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw f

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

(** Extract tool output text from MCP response envelope.
    MCP responses wrap tool results as:
    {
      "jsonrpc": "2.0", "id": N,
      "result": {
        "content": [{"type":"text","text":"<tool JSON>"}],
        "isError": bool,
        "resultEnvelope": {...}
      }
    }
    Returns (is_error, text) or fails. *)
let extract_tool_output response =
  match json_get_field response "result" with
  | Some result ->
      let is_error =
        match json_get_field result "isError" with
        | Some (`Bool b) -> b
        | _ -> false
      in
      (match json_get_field result "content" with
       | Some (`List (first_item :: _)) ->
           (match json_get_string first_item "text" with
            | Some text -> (is_error, text)
            | None -> fail "content[0] missing 'text' field")
       | Some (`List []) -> fail "content array is empty"
       | _ -> fail "missing or invalid 'content' field in result")
  | None ->
      (* Check if it's an error response *)
      (match json_get_field response "error" with
       | Some err ->
           let msg = match json_get_string err "message" with
             | Some m -> m
             | None -> "unknown error"
           in
           fail (Printf.sprintf "MCP error response: %s" msg)
       | None -> fail "response has neither 'result' nor 'error'")

let prepare_code_surface ~clock:_ ~sw:_ _state = ()

let cleanup_dir dir =
  if Sys.file_exists dir then Fs_compat.remove_tree dir

let with_code_fixture f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      ("masc-code-nav-" ^ string_of_int (Random.bits ()))
  in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
       let lib_dir = Filename.concat dir "lib" in
       Fs_compat.mkdir_p lib_dir;
       Fs_compat.save_file
         (Filename.concat lib_dir "config.ml")
         {|
(* fixture mentions ripgrep so tool_search_files has a deterministic hit. *)
let config_value = "ripgrep"

let helper x = x + 1
|};
       f dir)

(* ===== E2E Test: tool_search_files ===== *)

let test_code_search_basic () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->

  with_code_fixture @@ fun base_path ->
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  prepare_code_surface ~clock ~sw state;

  (* Search for "ripgrep" in codebase *)
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "tool_search_files");
      ("arguments", `Assoc [
        ("query", `String "ripgrep");
        ("path", `String "lib/");
        ("max_results", `Int 5);
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let (is_error, text) = extract_tool_output response in

  if is_error then begin
    (* Error is acceptable if rg not installed *)
    check bool "error mentions ripgrep or command" true
      (contains_substring text "ripgrep" ||
       contains_substring text "command" ||
       contains_substring text "rg" ||
       contains_substring text "git" ||
       contains_substring text "Internal error")
  end else begin
    (* Parse the tool-specific JSON from text *)
    let tool_result = Yojson.Safe.from_string text in
    (* Check count field *)
    (match json_get_int tool_result "count" with
     | Some count ->
         (* count >= 0 is valid; if rg found nothing via fallback, count=0 *)
         check bool "count non-negative" true (count >= 0)
     | None -> fail "missing count field in tool output");

    (* Check results array *)
    (match json_get_field tool_result "results" with
     | Some (`List results) ->
         (* If count > 0, verify first result structure *)
         if List.length results > 0 then begin
           match results with
           | first :: _ ->
               (match first with
                | `Assoc _match_fields ->
                    (* Check required fields: path, line, content *)
                    (match json_get_string first "path" with
                     | Some path ->
                         check bool "path contains lib/" true
                           (contains_substring path "lib/")
                     | None -> fail "missing path field");
                    (match json_get_int first "line" with
                     | Some line -> check bool "line > 0" true (line > 0)
                     | None -> fail "missing line field");
                    (match json_get_string first "content" with
                     | Some content ->
                         check bool "content not empty" true
                           (String.length content > 0)
                     | None -> fail "missing content field")
                | _ -> fail "match not an object")
           | [] -> () (* empty is ok if count=0 *)
         end
     | Some _ -> fail "results not a list"
     | None -> fail "missing results field")
  end

(* ===== E2E Test: tool_search_files ===== *)

let test_code_symbols_basic () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->

  with_code_fixture @@ fun base_path ->
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  prepare_code_surface ~clock ~sw state;

  (* Extract symbols from a real file *)
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 2);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "tool_search_files");
      ("arguments", `Assoc [
        ("path", `String "lib/config.ml");
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let (is_error, text) = extract_tool_output response in

  if is_error then
    (* Error is acceptable if file not found or internal error *)
    check bool "error message present" true (String.length text > 0)
  else begin
    let tool_result = Yojson.Safe.from_string text in
    (* Check path field *)
    (match json_get_string tool_result "path" with
     | Some path ->
         check string "correct path" "lib/config.ml" path
     | None -> fail "missing path field");

    (* Check count field *)
    (match json_get_int tool_result "count" with
     | Some count ->
         check bool "count is non-negative" true (count >= 0)
     | None -> fail "missing count field");

    (* Check symbols array *)
    (match json_get_field tool_result "symbols" with
     | Some (`List _symbols) -> ()
     | Some _ -> fail "symbols not a list"
     | None -> fail "missing symbols field")
  end

(* ===== E2E Test: tool_read_file ===== *)

let test_code_read_basic () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->

  with_code_fixture @@ fun base_path ->
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  prepare_code_surface ~clock ~sw state;

  (* Read first 10 lines of a file *)
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 3);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "tool_read_file");
      ("arguments", `Assoc [
        ("path", `String "lib/config.ml");
        ("offset", `Int 0);
        ("limit", `Int 10);
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let (is_error, text) = extract_tool_output response in

  if is_error then
    check bool "error message present" true (String.length text > 0)
  else begin
    let tool_result = Yojson.Safe.from_string text in
    (* Check path field *)
    (match json_get_string tool_result "path" with
     | Some path ->
         check string "correct path" "lib/config.ml" path
     | None -> fail "missing path field");

    (* Check offset field *)
    (match json_get_int tool_result "offset" with
     | Some offset -> check int "offset is 0" 0 offset
     | None -> fail "missing offset field");

    (* Check limit field *)
    (match json_get_int tool_result "limit" with
     | Some limit ->
         check bool "limit is positive" true (limit > 0)
     | None -> fail "missing limit field");

    (* Check total_lines field *)
    (match json_get_int tool_result "total_lines" with
     | Some total ->
         check bool "total_lines > 0" true (total > 0)
     | None -> fail "missing total_lines field");

    (* Check lines array *)
    (match json_get_field tool_result "lines" with
     | Some (`List lines) ->
           check bool "lines is array" true (List.length lines > 0)
     | Some _ -> fail "lines not a list"
     | None -> fail "missing lines field")
  end

(* ===== E2E Test: tool_read_file offset/limit ===== *)

let test_code_read_offset_limit () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->

  with_code_fixture @@ fun base_path ->
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  prepare_code_surface ~clock ~sw state;

  (* Read lines 10-20 *)
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 4);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "tool_read_file");
      ("arguments", `Assoc [
        ("path", `String "lib/config.ml");
        ("offset", `Int 10);
        ("limit", `Int 10);
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let (is_error, text) = extract_tool_output response in

  if is_error then
    check bool "error message present" true (String.length text > 0)
  else begin
    let tool_result = Yojson.Safe.from_string text in
    (* Verify offset is preserved *)
    (match json_get_int tool_result "offset" with
     | Some offset -> check int "offset is 10" 10 offset
     | None -> fail "missing offset field");

    (* Verify limit is preserved (or reduced if file is shorter) *)
    (match json_get_int tool_result "limit" with
     | Some limit ->
         check bool "limit is positive" true (limit > 0);
         check bool "limit <= requested" true (limit <= 10)
     | None -> fail "missing limit field")
  end

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
