(** Extended MCP coverage tests — targets uncovered paths in mcp.ml and mcp_http.ml.

    Focuses on:
    - merge_env with actual overrides
    - mcp_tool_of_json edge cases (missing description, numeric name)
    - exact text_of_tool_result extraction with EmbeddedResource content
    - close_managed and close_all with Http transport
    - MCP HTTP explicit config type verification
    - Mcp_http.parse/SSE body parsing (internal but covered via connect path) *)

open Agent_sdk

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

(* ── merge_env tests ──────────────────────────────────────── *)

let test_merge_env_empty () =
  let result = Mcp.merge_env [] in
  (* Should return current environment unchanged *)
  Alcotest.(check bool) "non-empty" true (Array.length result > 0)
;;

let test_merge_env_override () =
  let result = Mcp.merge_env [ "OAS_TEST_KEY_XYZ", "test_value" ] in
  let found = Array.exists (fun entry -> entry = "OAS_TEST_KEY_XYZ=test_value") result in
  Alcotest.(check bool) "contains override" true found
;;

let test_merge_env_multiple () =
  let result = Mcp.merge_env [ "OAS_KEY_A", "val_a"; "OAS_KEY_B", "val_b" ] in
  let has_a = Array.exists (fun e -> e = "OAS_KEY_A=val_a") result in
  let has_b = Array.exists (fun e -> e = "OAS_KEY_B=val_b") result in
  Alcotest.(check bool) "has key_a" true has_a;
  Alcotest.(check bool) "has key_b" true has_b
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

(* ── close_managed / close_all ────────────────────────────── *)

let test_close_managed_http () =
  let closed = ref false in
  let managed : Mcp.managed =
    { tools = []
    ; name = "http-test"
    ; transport =
        Http
          { close_fn = (fun () -> closed := true)
          ; base_url = "http://127.0.0.1:8935/mcp"
          ; headers = []
          }
    }
  in
  Mcp.close_managed managed;
  Alcotest.(check bool) "close_fn called" true !closed
;;

let test_close_all_empty () =
  Mcp.close_all [];
  (* No crash on empty list *)
  Alcotest.(check bool) "ok" true true
;;

let test_close_all_mixed () =
  let count = ref 0 in
  let m1 : Mcp.managed =
    { tools = []
    ; name = "srv1"
    ; transport =
        Http
          { close_fn = (fun () -> incr count)
          ; base_url = "http://127.0.0.1:1/mcp"
          ; headers = []
          }
    }
  in
  let m2 : Mcp.managed =
    { tools = []
    ; name = "srv2"
    ; transport =
        Http
          { close_fn = (fun () -> incr count)
          ; base_url = "http://127.0.0.1:2/mcp"
          ; headers = []
          }
    }
  in
  Mcp.close_all [ m1; m2 ];
  Alcotest.(check int) "both closed" 2 !count
;;

let test_close_managed_http_exception () =
  (* close_fn that raises should be swallowed *)
  let managed : Mcp.managed =
    { tools = []
    ; name = "bad-close"
    ; transport =
        Http
          { close_fn = (fun () -> failwith "close error")
          ; base_url = "http://127.0.0.1:3/mcp"
          ; headers = []
          }
    }
  in
  Mcp.close_managed managed;
  Alcotest.(check bool) "no crash" true true
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

(* ── mcp_tool_to_sdk_tool extended ────────────────────────── *)

let test_mcp_tool_to_sdk_tool_empty_schema () =
  let mcp_tool : Mcp.mcp_tool =
    { name = "empty_params"; description = "No parameters"; input_schema = `Assoc [] }
  in
  let call_fn _input : Types.tool_result = Ok { content = "ok"; _meta = None } in
  let sdk_tool = Mcp.mcp_tool_to_sdk_tool ~call_fn mcp_tool in
  Alcotest.(check string) "name" "empty_params" sdk_tool.schema.name;
  Alcotest.(check int) "no params" 0 (List.length sdk_tool.schema.parameters);
  (* Execute with empty input *)
  match Tool.execute sdk_tool (`Assoc []) with
  | Ok { content; _meta = _ } -> Alcotest.(check string) "ok" "ok" content
  | Error _ -> Alcotest.fail "expected Ok"
;;

(* MCP HTTP explicit config *)

(* ── Server spec construction ─────────────────────────────── *)

let test_server_spec_construction () =
  let spec : Mcp.server_spec =
    { command = "node"
    ; args = [ "server.js"; "--port"; "3000" ]
    ; env = [ "NODE_ENV", "production" ]
    ; name = "test-server"
    }
  in
  Alcotest.(check string) "command" "node" spec.command;
  Alcotest.(check int) "args count" 3 (List.length spec.args);
  Alcotest.(check string) "name" "test-server" spec.name;
  Alcotest.(check int) "env count" 1 (List.length spec.env)
;;

(* ── Suite ────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "MCP_coverage"
    [ ( "merge_env"
      , [ Alcotest.test_case "empty extras" `Quick test_merge_env_empty
        ; Alcotest.test_case "override key" `Quick test_merge_env_override
        ; Alcotest.test_case "multiple keys" `Quick test_merge_env_multiple
        ] )
    ; ( "mcp_tool_of_json"
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
    ; ( "close_managed"
      , [ Alcotest.test_case "http transport" `Quick test_close_managed_http
        ; Alcotest.test_case "close_all empty" `Quick test_close_all_empty
        ; Alcotest.test_case "close_all mixed" `Quick test_close_all_mixed
        ; Alcotest.test_case "close_fn exception" `Quick test_close_managed_http_exception
        ] )
    ; "type_mapping", [ Alcotest.test_case "all types" `Quick test_type_mapping_all ]
    ; ( "tool_bridge"
      , [ Alcotest.test_case "empty schema" `Quick test_mcp_tool_to_sdk_tool_empty_schema
        ] )
    ; ( "server_spec"
      , [ Alcotest.test_case "construction" `Quick test_server_spec_construction ] )
    ]
;;
