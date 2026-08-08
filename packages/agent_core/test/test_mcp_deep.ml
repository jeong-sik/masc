(** Deep coverage tests for lib/protocol/mcp.ml.

    Targets the 116 uncovered lines (54.33% coverage).
    Focuses on pure functions that do not require Eio context:
    - text_of_tool_result: exact content block extraction
    - mcp_tool_of_json: JSON tool definition parsing
    - merge_env: environment variable merging *)

open Agent_sdk
module Sdk_types = Mcp_protocol.Mcp_types

let make_tool_result ?is_error ?structured_content content =
  let fields = [ "content", Sdk_types.tool_content_list_to_yojson content ] in
  let fields =
    match is_error with
    | Some b -> ("isError", `Bool b) :: fields
    | None -> fields
  in
  let fields =
    match structured_content with
    | Some json -> ("structuredContent", json) :: fields
    | None -> fields
  in
  match Sdk_types.tool_result_of_yojson (`Assoc fields) with
  | Ok result -> result
  | Error detail -> failwith ("tool_result_of_yojson failed: " ^ detail)
;;

(* ── text_of_tool_result tests ───────────────────────────────── *)

let test_text_single_text () =
  let result : Sdk_types.tool_result =
    make_tool_result
      [ Sdk_types.TextContent { type_ = "text"; text = "hello world"; annotations = None }
      ]
  in
  Alcotest.(check string) "single text" "hello world" (Mcp.text_of_tool_result result)
;;

let test_text_multiple_text_blocks () =
  let result : Sdk_types.tool_result =
    make_tool_result
      [ Sdk_types.TextContent { type_ = "text"; text = "line1"; annotations = None }
      ; Sdk_types.TextContent { type_ = "text"; text = "line2"; annotations = None }
      ; Sdk_types.TextContent { type_ = "text"; text = "line3"; annotations = None }
      ]
  in
  Alcotest.(check string)
    "multi text"
    "line1\nline2\nline3"
    (Mcp.text_of_tool_result result)
;;

let test_text_empty_content () =
  let result : Sdk_types.tool_result = make_tool_result [] in
  Alcotest.(check string) "empty" "" (Mcp.text_of_tool_result result)
;;

let test_text_image_only () =
  let result : Sdk_types.tool_result =
    make_tool_result
      [ Sdk_types.ImageContent
          { type_ = "image"
          ; data = "base64"
          ; mime_type = "image/png"
          ; annotations = None
          }
      ]
  in
  Alcotest.(check string) "image only" "" (Mcp.text_of_tool_result result)
;;

let test_text_large_exact () =
  let text = String.make 100_000 'x' in
  let result : Sdk_types.tool_result =
    make_tool_result
      [ Sdk_types.TextContent { type_ = "text"; text; annotations = None } ]
  in
  Alcotest.(check string) "large text exact" text (Mcp.text_of_tool_result result)
;;

(* ── mcp_tool_of_json tests ──────────────────────────────────── *)

let test_tool_json_complete () =
  let json =
    `Assoc
      [ "name", `String "search"
      ; "description", `String "Search things"
      ; ( "inputSchema"
        , `Assoc
            [ "type", `String "object"
            ; "properties", `Assoc [ "query", `Assoc [ "type", `String "string" ] ]
            ] )
      ]
  in
  match Mcp.mcp_tool_of_json json with
  | Some t ->
    Alcotest.(check string) "name" "search" t.name;
    Alcotest.(check string) "desc" "Search things" t.description
  | None -> Alcotest.fail "expected Some"
;;

let test_tool_json_no_name () =
  let json = `Assoc [ "description", `String "orphan" ] in
  Alcotest.(check bool) "None" true (Mcp.mcp_tool_of_json json = None)
;;

let test_tool_json_name_is_int () =
  let json = `Assoc [ "name", `Int 42; "description", `String "bad name type" ] in
  Alcotest.(check bool) "None for int name" true (Mcp.mcp_tool_of_json json = None)
;;

let test_tool_json_not_assoc () =
  Alcotest.(check bool) "None for string" true (Mcp.mcp_tool_of_json (`String "hi") = None);
  Alcotest.(check bool) "None for list" true (Mcp.mcp_tool_of_json (`List []) = None);
  Alcotest.(check bool) "None for int" true (Mcp.mcp_tool_of_json (`Int 5) = None)
;;

let test_tool_json_no_description () =
  let json = `Assoc [ "name", `String "bare_tool"; "inputSchema", `Assoc [] ] in
  match Mcp.mcp_tool_of_json json with
  | Some t -> Alcotest.(check string) "empty desc" "" t.description
  | None -> Alcotest.fail "expected Some"
;;

let test_tool_json_input_schema_underscore () =
  let json =
    `Assoc [ "name", `String "t"; "input_schema", `Assoc [ "type", `String "object" ] ]
  in
  match Mcp.mcp_tool_of_json json with
  | Some t -> Alcotest.(check string) "name" "t" t.name
  | None -> Alcotest.fail "expected Some with input_schema"
;;

let test_tool_json_no_schema () =
  let json = `Assoc [ "name", `String "minimal" ] in
  match Mcp.mcp_tool_of_json json with
  | Some t ->
    Alcotest.(check string) "default schema" "minimal" t.name;
    (* Schema should default to empty Assoc *)
    Alcotest.(check bool) "schema is assoc" true (t.input_schema = `Assoc [])
  | None -> Alcotest.fail "expected Some"
;;

(* ── merge_env tests ─────────────────────────────────────────── *)

let test_merge_env_empty_extras () =
  let env = Mcp.merge_env [] in
  let current = Unix.environment () in
  Alcotest.(check int) "same length" (Array.length current) (Array.length env)
;;

let test_merge_env_adds_new () =
  let key = "OAS_TEST_MERGE_ENV_UNIQUE_KEY_12345" in
  let env = Mcp.merge_env [ key, "test_value" ] in
  let found =
    Array.to_list env |> List.exists (fun entry -> entry = key ^ "=test_value")
  in
  Alcotest.(check bool) "new key present" true found
;;

let test_merge_env_overrides () =
  let key = "PATH" in
  let env = Mcp.merge_env [ key, "/custom/path" ] in
  let matches =
    Array.to_list env
    |> List.filter (fun entry ->
      String.length entry >= String.length key + 1
      && String.sub entry 0 (String.length key + 1) = key ^ "=")
  in
  Alcotest.(check int) "exactly one PATH" 1 (List.length matches);
  Alcotest.(check string) "overridden" (key ^ "=/custom/path") (List.hd matches)
;;

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "MCP Deep"
    [ ( "text_of_tool_result"
      , [ Alcotest.test_case "single text" `Quick test_text_single_text
        ; Alcotest.test_case "multiple texts" `Quick test_text_multiple_text_blocks
        ; Alcotest.test_case "empty content" `Quick test_text_empty_content
        ; Alcotest.test_case "image only" `Quick test_text_image_only
        ; Alcotest.test_case "large exact" `Quick test_text_large_exact
        ] )
    ; ( "mcp_tool_of_json"
      , [ Alcotest.test_case "complete" `Quick test_tool_json_complete
        ; Alcotest.test_case "no name" `Quick test_tool_json_no_name
        ; Alcotest.test_case "name is int" `Quick test_tool_json_name_is_int
        ; Alcotest.test_case "not assoc" `Quick test_tool_json_not_assoc
        ; Alcotest.test_case "no description" `Quick test_tool_json_no_description
        ; Alcotest.test_case
            "input_schema underscore"
            `Quick
            test_tool_json_input_schema_underscore
        ; Alcotest.test_case "no schema" `Quick test_tool_json_no_schema
        ] )
    ; ( "merge_env"
      , [ Alcotest.test_case "empty extras" `Quick test_merge_env_empty_extras
        ; Alcotest.test_case "adds new" `Quick test_merge_env_adds_new
        ; Alcotest.test_case "overrides" `Quick test_merge_env_overrides
        ] )
    ]
;;
