(** Unit tests for the MCP module.
    Tests pure functions only — no subprocess spawning.

    After the SDK migration (mcp-protocol-sdk v0.10.0), JSON-RPC
    encoding/decoding and MCP type parsing are handled by the SDK.
    These tests cover the oas-specific bridge layer:
    - JSON Schema -> SDK tool_param conversion
    - MCP tool -> SDK Tool.t bridge
    - SDK Mcp_types.tool -> oas mcp_tool conversion *)

open Agent_sdk

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

(* ── JSON Schema -> SDK tool_param ───────────────────────────────── *)

let check_param_type = Alcotest.testable Types.pp_param_type (fun a b -> a = b)

let test_type_mapping () =
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
       Alcotest.check
         check_param_type
         input
         expected
         (Mcp.json_schema_type_to_param_type input))
    cases
;;

let test_type_mapping_unknown_fails () =
  match Mcp.json_schema_type_to_param_type_result "unknown_type" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected unknown JSON Schema type to fail"
;;

let test_json_schema_to_params () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {
      "city": {"type": "string", "description": "City name"},
      "units": {"type": "string", "description": "Temperature units"},
      "count": {"type": "integer", "description": "Result count"}
    },
    "required": ["city"]
  }|}
  in
  let params = Mcp.json_schema_to_params schema in
  Alcotest.(check int) "param count" 3 (List.length params);
  let city = List.hd params in
  Alcotest.(check string) "city name" "city" city.name;
  Alcotest.(check string) "city desc" "City name" city.description;
  Alcotest.check check_param_type "city type" Types.String city.param_type;
  Alcotest.(check bool) "city required" true city.required;
  let units = List.nth params 1 in
  Alcotest.(check bool) "units optional" false units.required;
  let count = List.nth params 2 in
  Alcotest.check check_param_type "count type" Types.Integer count.param_type
;;

let test_json_schema_empty () =
  let schema = Yojson.Safe.from_string {|{"type": "object"}|} in
  let params = Mcp.json_schema_to_params schema in
  Alcotest.(check int) "empty params" 0 (List.length params)
;;

let test_json_schema_no_required () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {
      "x": {"type": "number", "description": "X value"}
    }
  }|}
  in
  let params = Mcp.json_schema_to_params schema in
  Alcotest.(check int) "one param" 1 (List.length params);
  Alcotest.(check bool) "not required" false (List.hd params).required
;;

let test_json_schema_no_description () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {
      "flag": {"type": "boolean"}
    }
  }|}
  in
  let params = Mcp.json_schema_to_params schema in
  Alcotest.(check string) "default desc" "" (List.hd params).description;
  Alcotest.check check_param_type "bool type" Types.Boolean (List.hd params).param_type
;;

let test_json_schema_missing_property_type_is_not_projected () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {
      "payload": {"description": "Any payload"}
    }
  }|}
  in
  match Mcp.json_schema_to_params_result schema with
  | Error detail -> Alcotest.failf "valid untyped property rejected: %s" detail
  | Ok params ->
    Alcotest.(check int) "unprojectable property omitted" 0 (List.length params)
;;

let test_json_schema_nullable_union_uses_concrete_type () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {
      "label": {"type": ["null", "string"], "description": "Nullable label"}
    }
  }|}
  in
  let params = Mcp.json_schema_to_params schema in
  let label = List.hd params in
  Alcotest.(check string) "label name" "label" label.name;
  Alcotest.check check_param_type "nullable string" Types.String label.param_type
;;

let test_json_schema_union_unknown_type_fails () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {
      "value": {"type": ["string", "mystery"]}
    }
  }|}
  in
  match Mcp.json_schema_to_params_result schema with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected unknown union type to fail"
;;

let test_json_schema_union_null_only_is_not_projected () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {
      "nothing": {"type": ["null"]}
    }
  }|}
  in
  match Mcp.json_schema_to_params_result schema with
  | Error detail -> Alcotest.failf "valid null-only property rejected: %s" detail
  | Ok params -> Alcotest.(check int) "null-only property omitted" 0 (List.length params)
;;

let test_json_schema_union_multiple_concrete_types_is_not_projected () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {
      "value": {"type": ["string", "number", "null"]}
    }
  }|}
  in
  match Mcp.json_schema_to_params_result schema with
  | Error detail -> Alcotest.failf "valid multi-type property rejected: %s" detail
  | Ok params -> Alcotest.(check int) "multi-type property omitted" 0 (List.length params)
;;

let test_json_schema_integer_number_union_uses_number () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {"value": {"type": ["integer", "number"]}},
    "required": ["value"]
  }|}
  in
  match Mcp.json_schema_to_params_result schema with
  | Error detail -> Alcotest.failf "representable numeric union rejected: %s" detail
  | Ok [ param ] ->
    Alcotest.check check_param_type "integer plus number" Types.Number param.param_type
  | Ok params ->
    Alcotest.failf "expected one projected parameter, got %d" (List.length params)
;;

(* The [enum] route reaches the same decision as the [type] array above. It once
   carried its own copy of the rule without the numeric pair, so a mixed numeric
   enum dropped the property and took its description and required flag with
   it — the parameter view lost a parameter the schema declares. *)
let test_json_schema_mixed_numeric_enum_uses_number () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {
      "ratio": {"enum": [1, 2.5], "description": "Sampling ratio"}
    },
    "required": ["ratio"]
  }|}
  in
  match Mcp.json_schema_to_params_result schema with
  | Error detail -> Alcotest.failf "representable numeric enum rejected: %s" detail
  | Ok [ param ] ->
    Alcotest.check check_param_type "integer plus number" Types.Number param.param_type;
    Alcotest.(check string) "name kept" "ratio" param.name;
    Alcotest.(check string) "description kept" "Sampling ratio" param.description;
    Alcotest.(check bool) "required kept" true param.required
  | Ok params ->
    Alcotest.failf "expected one projected parameter, got %d" (List.length params)
;;

(* Boundary for the rule above: narrowing applies to the numeric pair only, so
   an enum spanning unrelated JSON types stays unrepresentable. *)
let test_json_schema_heterogeneous_enum_omits_property () =
  let schema =
    Yojson.Safe.from_string
      {|{
    "type": "object",
    "properties": {"mixed": {"enum": [1, "a"]}}
  }|}
  in
  match Mcp.json_schema_to_params_result schema with
  | Error detail -> Alcotest.failf "heterogeneous enum rejected: %s" detail
  | Ok params -> Alcotest.(check int) "heterogeneous enum omitted" 0 (List.length params)
;;

(* ── Tool bridge ────────────────────────────────────────────────── *)

let test_mcp_tool_to_sdk_tool () =
  let mcp_tool : Mcp.mcp_tool =
    { name = "echo"
    ; description = "Echoes input"
    ; input_schema =
        Yojson.Safe.from_string
          {|{
      "type": "object",
      "properties": {
        "text": {"type": "string", "description": "Text to echo"}
      },
      "required": ["text"]
    }|}
    }
  in
  let call_fn input : Types.tool_result =
    let open Yojson.Safe.Util in
    let text = input |> member "text" |> to_string in
    Ok { content = "echo: " ^ text; _meta = None }
  in
  let sdk_tool = Mcp.mcp_tool_to_sdk_tool ~call_fn mcp_tool in
  Alcotest.(check string) "tool name" "echo" sdk_tool.schema.name;
  Alcotest.(check string) "tool desc" "Echoes input" sdk_tool.schema.description;
  Alcotest.(check int) "param count" 1 (List.length sdk_tool.schema.parameters);
  let input = `Assoc [ "text", `String "hello" ] in
  let result = Tool.execute sdk_tool input in
  match result with
  | Ok { content; _meta = _ } -> Alcotest.(check string) "execution" "echo: hello" content
  | Error _ -> Alcotest.fail "expected Ok"
;;

let test_mcp_tool_bridge_error () =
  let mcp_tool : Mcp.mcp_tool =
    { name = "fail"
    ; description = "Always fails"
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  in
  let call_fn _input : Types.tool_result =
    Error { message = "server error"; recoverable = true; error_class = None }
  in
  let sdk_tool = Mcp.mcp_tool_to_sdk_tool ~call_fn mcp_tool in
  let result = Tool.execute sdk_tool (`Assoc []) in
  match result with
  | Error { message; _ } -> Alcotest.(check string) "error" "server error" message
  | Ok _ -> Alcotest.fail "expected Error"
;;

(* ── SDK tool -> oas mcp_tool conversion ─────────────────────────── *)

let test_mcp_tool_of_sdk_tool () =
  let sdk_tool : Mcp_protocol.Mcp_types.tool =
    { name = "read_file"
    ; description = Some "Read a file"
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "path"
                  , `Assoc
                      [ "type", `String "string"; "description", `String "File path" ] )
                ] )
          ; "required", `List [ `String "path" ]
          ]
    ; title = None
    ; annotations = None
    ; icon = None
    ; output_schema = None
    ; execution = None
    }
  in
  let mcp_tool = Mcp.mcp_tool_of_sdk_tool sdk_tool in
  Alcotest.(check string) "name" "read_file" mcp_tool.name;
  Alcotest.(check string) "description" "Read a file" mcp_tool.description;
  let params = Mcp.json_schema_to_params mcp_tool.input_schema in
  Alcotest.(check int) "param count" 1 (List.length params);
  Alcotest.(check string) "param name" "path" (List.hd params).name;
  Alcotest.(check bool) "param required" true (List.hd params).required
;;

let test_mcp_tool_of_sdk_tool_no_description () =
  let sdk_tool : Mcp_protocol.Mcp_types.tool =
    { name = "bare"
    ; description = None
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    ; title = None
    ; annotations = None
    ; icon = None
    ; output_schema = None
    ; execution = None
    }
  in
  let mcp_tool = Mcp.mcp_tool_of_sdk_tool sdk_tool in
  Alcotest.(check string) "default desc" "" mcp_tool.description
;;

let test_text_of_tool_result () =
  let result : Mcp_protocol.Mcp_types.tool_result =
    make_tool_result
      [ Mcp_protocol.Mcp_types.TextContent
          { type_ = "text"; text = "line1"; annotations = None }
      ; Mcp_protocol.Mcp_types.TextContent
          { type_ = "text"; text = "line2"; annotations = None }
      ]
  in
  let text = Mcp.text_of_tool_result result in
  Alcotest.(check string) "concatenated" "line1\nline2" text
;;

let test_text_of_tool_result_empty () =
  let result : Mcp_protocol.Mcp_types.tool_result = make_tool_result [] in
  let text = Mcp.text_of_tool_result result in
  Alcotest.(check string) "empty content" "" text
;;

let test_text_of_tool_result_non_text_only () =
  let result : Mcp_protocol.Mcp_types.tool_result =
    make_tool_result
      [ Mcp_protocol.Mcp_types.ImageContent
          { type_ = "image"
          ; data = "base64..."
          ; mime_type = "image/png"
          ; annotations = None
          }
      ]
  in
  let text = Mcp.text_of_tool_result result in
  Alcotest.(check string) "non-text returns empty" "" text
;;

let test_text_of_tool_result_mixed () =
  let result : Mcp_protocol.Mcp_types.tool_result =
    make_tool_result
      [ Mcp_protocol.Mcp_types.TextContent
          { type_ = "text"; text = "hello"; annotations = None }
      ; Mcp_protocol.Mcp_types.ImageContent
          { type_ = "image"
          ; data = "base64..."
          ; mime_type = "image/png"
          ; annotations = None
          }
      ; Mcp_protocol.Mcp_types.TextContent
          { type_ = "text"; text = "world"; annotations = None }
      ]
  in
  let text = Mcp.text_of_tool_result result in
  Alcotest.(check string) "text only" "hello\nworld" text
;;

let test_text_of_tool_result_large_exact () =
  let text = String.make 100_000 'x' in
  let result : Mcp_protocol.Mcp_types.tool_result =
    make_tool_result
      [ Mcp_protocol.Mcp_types.TextContent { type_ = "text"; text; annotations = None } ]
  in
  Alcotest.(check string) "large exact" text (Mcp.text_of_tool_result result)
;;

(* ── mcp_tool_of_json tests ─────────────────────────────────── *)

let test_mcp_tool_of_json_valid () =
  let json =
    `Assoc
      [ "name", `String "my_tool"
      ; "description", `String "Does things"
      ; "inputSchema", `Assoc [ "type", `String "object" ]
      ]
  in
  match Mcp.mcp_tool_of_json json with
  | Some t ->
    Alcotest.(check string) "name" "my_tool" t.name;
    Alcotest.(check string) "desc" "Does things" t.description
  | None -> Alcotest.fail "expected Some"
;;

let test_mcp_tool_of_json_input_schema_underscore () =
  let json =
    `Assoc [ "name", `String "t2"; "input_schema", `Assoc [ "type", `String "object" ] ]
  in
  match Mcp.mcp_tool_of_json json with
  | Some t -> Alcotest.(check string) "name" "t2" t.name
  | None -> Alcotest.fail "expected Some for input_schema"
;;

let test_mcp_tool_of_json_missing_name () =
  (* After fix: tools without a name are skipped (returns None) *)
  let json = `Assoc [ "description", `String "no name"; "inputSchema", `Assoc [] ] in
  match Mcp.mcp_tool_of_json json with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for missing name"
;;

let test_mcp_tool_of_json_missing_schema () =
  let json = `Assoc [ "name", `String "bare" ] in
  match Mcp.mcp_tool_of_json json with
  | Some t ->
    (* Schema defaults to empty Assoc *)
    Alcotest.(check string) "name" "bare" t.name
  | None -> Alcotest.fail "expected Some"
;;

let test_mcp_tool_of_json_non_assoc () =
  match Mcp.mcp_tool_of_json (`String "not an object") with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for non-assoc"
;;

(* ── Test runner ────────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run
    "MCP"
    [ ( "schema_conversion"
      , [ test_case "type mapping" `Quick test_type_mapping
        ; test_case "unknown type fails" `Quick test_type_mapping_unknown_fails
        ; test_case "full schema" `Quick test_json_schema_to_params
        ; test_case "empty schema" `Quick test_json_schema_empty
        ; test_case "no required" `Quick test_json_schema_no_required
        ; test_case "no description" `Quick test_json_schema_no_description
        ; test_case
            "missing property type is not projected"
            `Quick
            test_json_schema_missing_property_type_is_not_projected
        ; test_case
            "nullable union uses concrete type"
            `Quick
            test_json_schema_nullable_union_uses_concrete_type
        ; test_case
            "union unknown type fails"
            `Quick
            test_json_schema_union_unknown_type_fails
        ; test_case
            "union null-only is not projected"
            `Quick
            test_json_schema_union_null_only_is_not_projected
        ; test_case
            "union multiple concrete types is not projected"
            `Quick
            test_json_schema_union_multiple_concrete_types_is_not_projected
        ; test_case
            "integer-number union uses number"
            `Quick
            test_json_schema_integer_number_union_uses_number
        ; test_case
            "mixed numeric enum uses number"
            `Quick
            test_json_schema_mixed_numeric_enum_uses_number
        ; test_case
            "heterogeneous enum omits property"
            `Quick
            test_json_schema_heterogeneous_enum_omits_property
        ] )
    ; ( "tool_bridge"
      , [ test_case "mcp_tool_to_sdk_tool" `Quick test_mcp_tool_to_sdk_tool
        ; test_case "bridge error propagation" `Quick test_mcp_tool_bridge_error
        ] )
    ; ( "sdk_bridge"
      , [ test_case "mcp_tool_of_sdk_tool" `Quick test_mcp_tool_of_sdk_tool
        ; test_case
            "sdk_tool no description"
            `Quick
            test_mcp_tool_of_sdk_tool_no_description
        ; test_case "text_of_tool_result" `Quick test_text_of_tool_result
        ; test_case "text_of_tool_result empty" `Quick test_text_of_tool_result_empty
        ; test_case
            "text_of_tool_result non-text only"
            `Quick
            test_text_of_tool_result_non_text_only
        ; test_case
            "text_of_tool_result mixed content"
            `Quick
            test_text_of_tool_result_mixed
        ; test_case
            "text_of_tool_result large exact"
            `Quick
            test_text_of_tool_result_large_exact
        ] )
    ; ( "mcp_tool_of_json"
      , [ test_case "valid" `Quick test_mcp_tool_of_json_valid
        ; test_case
            "input_schema underscore"
            `Quick
            test_mcp_tool_of_json_input_schema_underscore
        ; test_case "missing name" `Quick test_mcp_tool_of_json_missing_name
        ; test_case "missing schema" `Quick test_mcp_tool_of_json_missing_schema
        ; test_case "non-assoc" `Quick test_mcp_tool_of_json_non_assoc
        ] )
    ]
;;
