(** Extended MCP coverage tests — targets uncovered paths in mcp.ml.

    Focuses on:
    - mcp_tool_of_json edge cases (missing description, numeric name)
    - exact text_of_tool_result extraction with EmbeddedResource content *)

open Agent_core

(* ── Helpers ──────────────────────────────────────────────── *)

let make_tool_result ?is_error ?structured_content content =
  let fields =
    [ "content", Mcp_protocol.Mcp_types.tool_content_list_to_yojson content ]
  in
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
  match Mcp_protocol.Mcp_types.tool_result_of_yojson (`Assoc fields) with
  | Ok result -> result
  | Error detail -> failwith ("tool_result_of_yojson failed: " ^ detail)
;;

(* ── mcp_tool_of_json extended ────────────────────────────── *)

let test_mcp_tool_of_json_no_description () =
  let json =
    `Assoc
      [ "name", `String "nodesc_tool"
      ; "inputSchema", `Assoc [ "type", `String "object" ]
      ]
  in
  match Mcp.mcp_tool_of_json json with
  | Some t ->
    Alcotest.(check string) "name" "nodesc_tool" t.name;
    Alcotest.(check string) "empty desc" "" t.description
  | None -> Alcotest.fail "expected Some"
;;

let test_mcp_tool_of_json_integer_name () =
  (* name must be string *)
  let json = `Assoc [ "name", `Int 42; "inputSchema", `Assoc [] ] in
  match Mcp.mcp_tool_of_json json with
  | None -> () (* expected — name is not a string *)
  | Some _ -> Alcotest.fail "expected None for non-string name"
;;

let test_mcp_tool_of_json_null () =
  match Mcp.mcp_tool_of_json `Null with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for null"
;;

let test_mcp_tool_of_json_list () =
  match Mcp.mcp_tool_of_json (`List [ `String "a" ]) with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for list"
;;

(* ── text_of_tool_result extended ─────────────────────────── *)

let test_text_of_tool_result_resource_content () =
  let result : Mcp_protocol.Mcp_types.tool_result =
    make_tool_result
      [ Mcp_protocol.Mcp_types.ResourceContent
          { type_ = "resource"
          ; resource =
              { uri = "file:///test.txt"
              ; mime_type = Some "text/plain"
              ; text = Some "resource text"
              ; blob = None
              }
          ; annotations = None
          }
      ]
  in
  let text = Mcp.text_of_tool_result result in
  (* ResourceContent is filtered out by text_of_tool_result (only TextContent passes) *)
  Alcotest.(check string) "resource not included" "" text
;;

let test_text_of_tool_result_single_text () =
  let result : Mcp_protocol.Mcp_types.tool_result =
    make_tool_result
      [ Mcp_protocol.Mcp_types.TextContent
          { type_ = "text"; text = "single line"; annotations = None }
      ]
  in
  let text = Mcp.text_of_tool_result result in
  Alcotest.(check string) "single text" "single line" text
;;

(* ── json_schema_type_to_param_type extended ──────────────── *)

let test_type_mapping_all () =
  let cases =
    [ "string", Types.String
    ; "integer", Types.Integer
    ; "number", Types.Number
    ; "boolean", Types.Boolean
    ; "array", Types.Array
    ; "object", Types.Object
    ]
  in
  List.iter
    (fun (input, expected) ->
       let result = Mcp.json_schema_type_to_param_type input in
       Alcotest.(check bool) (Printf.sprintf "type %s" input) true (result = expected))
    cases;
  List.iter
    (fun input ->
       match Mcp.json_schema_type_to_param_type_result input with
       | Error _ -> ()
       | Ok _ -> Alcotest.failf "expected unknown type %S to fail" input)
    [ "null"; ""; "custom" ]
;;

(* ── Suite ────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "MCP_coverage"
    [ ( "mcp_tool_of_json"
      , [ Alcotest.test_case "no description" `Quick test_mcp_tool_of_json_no_description
        ; Alcotest.test_case "integer name" `Quick test_mcp_tool_of_json_integer_name
        ; Alcotest.test_case "null input" `Quick test_mcp_tool_of_json_null
        ; Alcotest.test_case "list input" `Quick test_mcp_tool_of_json_list
        ] )
    ; ( "text_of_tool_result"
      , [ Alcotest.test_case
            "resource content"
            `Quick
            test_text_of_tool_result_resource_content
        ; Alcotest.test_case "single text" `Quick test_text_of_tool_result_single_text
        ] )
    ; "type_mapping", [ Alcotest.test_case "all types" `Quick test_type_mapping_all ]
    ]
;;
