open Agent_sdk

let expect_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Error.to_string error)
;;

let expect_invalid_config ~field = function
  | Error (Error.Config (Error.InvalidConfig { field = actual; _ })) ->
    Alcotest.(check string) "invalid field path" field actual
  | Error error ->
    Alcotest.fail
      (Printf.sprintf "expected InvalidConfig(%s), got %s" field (Error.to_string error))
  | Ok _ -> Alcotest.fail (Printf.sprintf "expected InvalidConfig(%s)" field)
;;

let jsonrpc_interface url =
  Agent_card.create_supported_interface
    ~url
    ~protocol_binding:"JSONRPC"
    ~protocol_version:"1.0"
    ()
  |> expect_ok
;;

let jsonrpc_interfaces url = Agent_card.supported_interfaces (jsonrpc_interface url) []

let base_info : Agent_card.agent_info =
  { agent_name = "test-agent"
  ; agent_description = Some "A test agent"
  ; version = Agent_sdk.Sdk_version.version
  ; config =
      { (Types.default_config ~model:"test-model") with
        name = "test-agent"
      ; enable_thinking = Some true
      }
  ; tool_schemas =
      [ Types.tool_schema_of_params
          ~name:"get_weather"
          ~description:"Get weather"
          ~parameters:
            [ { Types.name = "city"
              ; description = "City"
              ; param_type = String
              ; required = true
              }
            ]
          ()
      ]
  ; supported_providers = []
  ; mcp_clients_count = 0
  ; has_elicitation = false
  ; skills = []
  ; supported_interfaces = jsonrpc_interfaces "https://agent.example/a2a"
  }
;;

let test_of_info_basic () =
  let card = Agent_card.of_info base_info in
  Alcotest.(check string) "name" "test-agent" card.name;
  Alcotest.(check (option string)) "description" (Some "A test agent") card.description;
  Alcotest.(check string) "version" Agent_sdk.Sdk_version.version card.version
;;

let test_capabilities_tools () =
  let card = Agent_card.of_info base_info in
  Alcotest.(check bool) "has Tools" true (Agent_card.has_capability card Agent_card.Tools)
;;

let test_capabilities_streaming () =
  let card = Agent_card.of_info base_info in
  Alcotest.(check bool)
    "has Streaming"
    true
    (Agent_card.has_capability card Agent_card.Streaming)
;;

let test_capabilities_thinking () =
  let card = Agent_card.of_info base_info in
  Alcotest.(check bool)
    "has Thinking"
    true
    (Agent_card.has_capability card Agent_card.Thinking)
;;

let test_capabilities_no_thinking () =
  let info =
    { base_info with config = { base_info.config with enable_thinking = None } }
  in
  let card = Agent_card.of_info info in
  Alcotest.(check bool)
    "no Thinking"
    false
    (Agent_card.has_capability card Agent_card.Thinking)
;;

let test_capabilities_mcp () =
  let info = { base_info with mcp_clients_count = 2 } in
  let card = Agent_card.of_info info in
  Alcotest.(check bool) "has MCP" true (Agent_card.has_capability card Agent_card.MCP)
;;

let test_capabilities_elicitation () =
  let info = { base_info with has_elicitation = true } in
  let card = Agent_card.of_info info in
  Alcotest.(check bool)
    "has Elicitation"
    true
    (Agent_card.has_capability card Agent_card.Elicitation)
;;

let test_capabilities_no_elicitation () =
  let card = Agent_card.of_info base_info in
  Alcotest.(check bool)
    "no Elicitation"
    false
    (Agent_card.has_capability card Agent_card.Elicitation)
;;

let test_can_handle_tool () =
  let card = Agent_card.of_info base_info in
  Alcotest.(check bool)
    "can handle get_weather"
    true
    (Agent_card.can_handle_tool card "get_weather");
  Alcotest.(check bool)
    "cannot handle unknown"
    false
    (Agent_card.can_handle_tool card "unknown_tool")
;;

let test_no_tools () =
  let info = { base_info with tool_schemas = [] } in
  let card = Agent_card.of_info info in
  Alcotest.(check bool)
    "no Tools cap"
    false
    (Agent_card.has_capability card Agent_card.Tools)
;;

let test_providers_empty_stays_empty () =
  let card = Agent_card.of_info base_info in
  Alcotest.(check (list string)) "no invented provider" [] card.supported_providers
;;

let test_providers_custom () =
  let info = { base_info with supported_providers = [ "openai-compat" ] } in
  let card = Agent_card.of_info info in
  Alcotest.(check (list string))
    "openai-compat provider"
    [ "openai-compat" ]
    card.supported_providers
;;

let test_skills_from_registry () =
  let skill : Agent_card.skill_meta = { name = "greet"; description = Some "Hello" } in
  let info = { base_info with skills = [ skill ] } in
  let card = Agent_card.of_info info in
  Alcotest.(check int) "1 skill" 1 (List.length card.skills);
  Alcotest.(check bool) "has greet" true (Agent_card.has_skill card "greet")
;;

let test_json_roundtrip () =
  let card = Agent_card.of_info base_info in
  let json = Agent_card.to_json card in
  match Agent_card.of_json json with
  | Ok card2 ->
    Alcotest.(check string) "name preserved" card.name card2.name;
    Alcotest.(check string) "version preserved" card.version card2.version;
    Alcotest.(check int)
      "caps count"
      (List.length card.capabilities)
      (List.length card2.capabilities);
    Alcotest.(check int) "tools preserved" 1 (List.length card2.tools);
    (match Agent_card.supported_interfaces_to_list card2.supported_interfaces with
     | [ interface ] ->
       Alcotest.(check string)
         "interface URL preserved"
         "https://agent.example/a2a"
         interface.url
     | interfaces ->
       Alcotest.failf "expected one interface, got %d" (List.length interfaces))
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_to_json_structure () =
  let card = Agent_card.of_info base_info in
  let json = Agent_card.to_json card in
  let open Yojson.Safe.Util in
  let name = json |> member "name" |> to_string in
  let caps = json |> member "capabilities" |> to_list in
  let tools = json |> member "tools" |> to_list in
  let interfaces = json |> member "supportedInterfaces" |> to_list in
  Alcotest.(check string) "json name" "test-agent" name;
  Alcotest.(check bool) "no top-level url" true (json |> member "url" = `Null);
  Alcotest.(check bool)
    "no top-level protocol version"
    true
    (json |> member "protocolVersion" = `Null);
  Alcotest.(check bool) "has caps" true (List.length caps > 0);
  Alcotest.(check int) "1 tool" 1 (List.length tools);
  Alcotest.(check int) "one declared interface" 1 (List.length interfaces)
;;

let test_to_json_uses_declared_supported_interface () =
  let card : Agent_card.agent_card =
    { name = "explicit-interface-agent"
    ; description = None
    ; version = "1.0"
    ; authentication = None
    ; supported_interfaces = jsonrpc_interfaces "https://agent.example/a2a"
    ; capabilities = []
    ; tools = []
    ; skills = []
    ; supported_providers = []
    ; metadata = []
    }
  in
  let json = Agent_card.to_json card in
  let open Yojson.Safe.Util in
  let interfaces = json |> member "supportedInterfaces" |> to_list in
  Alcotest.(check int) "declared interface count" 1 (List.length interfaces);
  let iface = List.hd interfaces in
  Alcotest.(check string)
    "url"
    "https://agent.example/a2a"
    (iface |> member "url" |> to_string);
  Alcotest.(check string)
    "binding"
    "JSONRPC"
    (iface |> member "protocolBinding" |> to_string);
  Alcotest.(check string)
    "protocol version"
    "1.0"
    (iface |> member "protocolVersion" |> to_string)
;;

let test_of_json_invalid () =
  Agent_card.of_json (`String "bad") |> expect_invalid_config ~field:"agent_card"
;;

(* ── capability_to/of_string roundtrip ──────────────────── *)

let test_capability_roundtrip () =
  let caps =
    [ Agent_card.Tools
    ; Streaming
    ; Thinking
    ; StructuredOutput
    ; Handoff
    ; Checkpoint
    ; MCP
    ; Elicitation
    ; Custom_cap "my_cap"
    ]
  in
  List.iter
    (fun cap ->
       let s = Agent_card.capability_to_string cap in
       let decoded = Agent_card.capability_of_string s in
       Alcotest.(check bool) ("roundtrip " ^ s) true (cap = decoded))
    caps
;;

(* ── to_json/of_json with authentication ───────────────── *)

let test_json_with_authentication () =
  let card : Agent_card.agent_card =
    { name = "auth-agent"
    ; description = Some "with auth"
    ; version = "1.0"
    ; authentication =
        Some
          { schemes = [ "bearer"; "api-key" ]; credential_ref = Env "AGENT_CARD_API_KEY" }
    ; supported_interfaces = jsonrpc_interfaces "https://agent.example:8080"
    ; capabilities = [ Tools; Streaming ]
    ; tools = []
    ; skills = []
    ; supported_providers = [ "anthropic" ]
    ; metadata = [ "env", `String "test" ]
    }
  in
  let json = Agent_card.to_json card in
  match Agent_card.of_json json with
  | Ok card2 ->
    Alcotest.(check string) "name" "auth-agent" card2.name;
    (match card2.authentication with
     | Some auth ->
       Alcotest.(check (list string)) "schemes" [ "bearer"; "api-key" ] auth.schemes;
       Alcotest.(check bool)
         "credential_ref env"
         true
         (auth.credential_ref = Agent_card.Env "AGENT_CARD_API_KEY")
     | None -> Alcotest.fail "expected auth");
    Alcotest.(check int)
      "interface count"
      1
      (List.length (Agent_card.supported_interfaces_to_list card2.supported_interfaces));
    Alcotest.(check int) "metadata" 1 (List.length card2.metadata)
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_json_no_auth_no_metadata () =
  let card : Agent_card.agent_card =
    { name = "simple"
    ; description = None
    ; version = "0.1"
    ; authentication = None
    ; supported_interfaces = jsonrpc_interfaces "https://simple.example/a2a"
    ; capabilities = []
    ; tools = []
    ; skills = []
    ; supported_providers = []
    ; metadata = []
    }
  in
  let json = Agent_card.to_json card in
  match Agent_card.of_json json with
  | Ok card2 ->
    Alcotest.(check (option string)) "no desc" None card2.description;
    Alcotest.(check bool) "no auth" true (Option.is_none card2.authentication);
    Alcotest.(check (list string)) "no metadata" [] (List.map fst card2.metadata)
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_json_rejects_literal_credentials () =
  let json =
    `Assoc
      [ "name", `String "bad-agent"
      ; "version", `String "1.0"
      ; ( "supportedInterfaces"
        , `List
            [ `Assoc
                [ "url", `String "https://bad-agent.example/a2a"
                ; "protocolBinding", `String "JSONRPC"
                ; "protocolVersion", `String "1.0"
                ]
            ] )
      ; "capabilities", `List []
      ; "tools", `List []
      ; "skills", `List []
      ; "supported_providers", `List []
      ; ( "authentication"
        , `Assoc
            [ "schemes", `List [ `String "bearer" ]
            ; "credentials", `String "super-secret"
            ] )
      ]
  in
  match Agent_card.of_json json with
  | Ok _ -> Alcotest.fail "expected error for literal credentials"
  | Error (Error.Config (InvalidConfig { field; _ }))
    when String.equal field "authentication.credentials" ->
    Alcotest.(check bool) "rejects literal credentials" true true
  | Error e ->
    Alcotest.fail
      (Printf.sprintf
         "expected InvalidConfig(authentication.credentials), got %s"
         (Error.to_string e))
;;

let test_json_auth_no_credentials () =
  let card : Agent_card.agent_card =
    { name = "auth-noc"
    ; description = None
    ; version = "1.0"
    ; authentication = Some { schemes = [ "oauth" ]; credential_ref = No_credential }
    ; supported_interfaces = jsonrpc_interfaces "https://auth.example/a2a"
    ; capabilities = []
    ; tools = []
    ; skills = []
    ; supported_providers = []
    ; metadata = []
    }
  in
  let json = Agent_card.to_json card in
  match Agent_card.of_json json with
  | Ok card2 ->
    (match card2.authentication with
     | Some auth ->
       Alcotest.(check bool)
         "no credential_ref"
         true
         (auth.credential_ref = Agent_card.No_credential)
     | None -> Alcotest.fail "expected auth")
  | Error e -> Alcotest.fail (Error.to_string e)
;;

(* ── has_capability / has_skill ─────────────────────────── *)

let test_has_capability_false () =
  let card = Agent_card.of_info base_info in
  Alcotest.(check bool) "no checkpoint" false (Agent_card.has_capability card Checkpoint)
;;

let test_has_skill_false () =
  let card = Agent_card.of_info base_info in
  Alcotest.(check bool) "no skill" false (Agent_card.has_skill card "nonexistent")
;;

(* ── to_json with skills ─────────────────────────────────── *)

let test_to_json_with_skills () =
  let card : Agent_card.agent_card =
    { name = "skill-agent"
    ; description = None
    ; version = "1.0"
    ; authentication = None
    ; supported_interfaces = jsonrpc_interfaces "https://skill.example/a2a"
    ; capabilities = []
    ; tools = []
    ; skills =
        [ { Agent_card.name = "greet"; description = Some "Say hi" }
        ; { Agent_card.name = "deploy"; description = None }
        ]
    ; supported_providers = []
    ; metadata = []
    }
  in
  let json = Agent_card.to_json card in
  let open Yojson.Safe.Util in
  let skills = json |> member "skills" |> to_list in
  Alcotest.(check int) "2 skills" 2 (List.length skills);
  let first = List.hd skills in
  Alcotest.(check string) "skill name" "greet" (first |> member "name" |> to_string)
;;

let test_legacy_only_json_is_rejected () =
  let legacy_json =
    `Assoc
      [ "name", `String "legacy-agent"
      ; "description", `String "legacy"
      ; "version", `String "0.9"
      ; "url", `String "http://legacy.local/a2a"
      ; "capabilities", `List []
      ; "tools", `List []
      ; "skills", `List []
      ; "supported_providers", `List []
      ]
  in
  Agent_card.of_json legacy_json |> expect_invalid_config ~field:"agent_card.url"
;;

let test_interface_requires_protocol_version () =
  let json =
    `Assoc
      [ "name", `String "v1-agent"
      ; "version", `String "1.2.3"
      ; ( "supportedInterfaces"
        , `List
            [ `Assoc
                [ "url", `String "https://agent.example/a2a"
                ; "protocolBinding", `String "JSONRPC"
                ]
            ] )
      ; "capabilities", `List []
      ; "tools", `List []
      ; "skills", `List []
      ; "supported_providers", `List []
      ]
  in
  Agent_card.of_json json
  |> expect_invalid_config ~field:"supportedInterfaces[0].protocolVersion"
;;

let test_interface_rejects_type_alias () =
  let json =
    `Assoc
      [ "name", `String "v1-agent"
      ; "version", `String "1.2.3"
      ; ( "supportedInterfaces"
        , `List
            [ `Assoc
                [ "url", `String "https://agent.example/a2a"
                ; "type", `String "JSONRPC"
                ; "protocolVersion", `String "1.0"
                ]
            ] )
      ; "capabilities", `List []
      ; "tools", `List []
      ; "skills", `List []
      ; "supported_providers", `List []
      ]
  in
  Agent_card.of_json json |> expect_invalid_config ~field:"supportedInterfaces[0].type"
;;

let test_supported_interfaces_rejects_empty () =
  Agent_card.supported_interfaces_of_list []
  |> expect_invalid_config ~field:"supported_interfaces"
;;

let test_interface_rejects_non_https_url () =
  Agent_card.create_supported_interface
    ~url:"http://agent.example/a2a"
    ~protocol_binding:"JSONRPC"
    ~protocol_version:"1.0"
    ()
  |> expect_invalid_config ~field:"supported_interface.url"
;;

let test_interface_rejects_relative_url () =
  Agent_card.create_supported_interface
    ~url:"/a2a"
    ~protocol_binding:"JSONRPC"
    ~protocol_version:"1.0"
    ()
  |> expect_invalid_config ~field:"supported_interface.url"
;;

let test_interface_rejects_empty_binding () =
  Agent_card.create_supported_interface
    ~url:"https://agent.example/a2a"
    ~protocol_binding:""
    ~protocol_version:"1.0"
    ()
  |> expect_invalid_config ~field:"supported_interface.protocolBinding"
;;

let test_interface_rejects_empty_version () =
  Agent_card.create_supported_interface
    ~url:"https://agent.example/a2a"
    ~protocol_binding:"JSONRPC"
    ~protocol_version:""
    ()
  |> expect_invalid_config ~field:"supported_interface.protocolVersion"
;;

let replace_json_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> Alcotest.fail "test fixture must be an object"
;;

let valid_json () = Agent_card.of_info base_info |> Agent_card.to_json

let test_json_rejects_empty_interfaces () =
  valid_json ()
  |> replace_json_field "supportedInterfaces" (`List [])
  |> Agent_card.of_json
  |> expect_invalid_config ~field:"supportedInterfaces"
;;

let test_json_rejects_malformed_metadata () =
  valid_json ()
  |> replace_json_field "metadata" (`List [])
  |> Agent_card.of_json
  |> expect_invalid_config ~field:"metadata"
;;

let test_json_rejects_malformed_authentication () =
  valid_json ()
  |> replace_json_field "authentication" (`String "bearer")
  |> Agent_card.of_json
  |> expect_invalid_config ~field:"authentication"
;;

let test_json_rejects_incomplete_credential_ref () =
  let authentication =
    `Assoc
      [ "schemes", `List [ `String "bearer" ]
      ; "credential_ref", `Assoc [ "type", `String "env" ]
      ]
  in
  valid_json ()
  |> replace_json_field "authentication" authentication
  |> Agent_card.of_json
  |> expect_invalid_config ~field:"authentication.credential_ref.name"
;;

let test_json_rejects_unknown_top_level_field () =
  match valid_json () with
  | `Assoc fields ->
    Agent_card.of_json (`Assoc (("url", `String "https://legacy.example") :: fields))
    |> expect_invalid_config ~field:"agent_card.url"
  | _ -> Alcotest.fail "valid card must encode as an object"
;;

let test_json_rejects_duplicate_top_level_field () =
  match valid_json () with
  | `Assoc fields ->
    Agent_card.of_json (`Assoc (("name", `String "duplicate") :: fields))
    |> expect_invalid_config ~field:"agent_card.name"
  | _ -> Alcotest.fail "valid card must encode as an object"
;;

let test_json_rejects_unknown_interface_field () =
  let interface =
    `Assoc
      [ "url", `String "https://agent.example/a2a"
      ; "protocolBinding", `String "JSONRPC"
      ; "protocolVersion", `String "1.0"
      ; "type", `String "legacy"
      ]
  in
  valid_json ()
  |> replace_json_field "supportedInterfaces" (`List [ interface ])
  |> Agent_card.of_json
  |> expect_invalid_config ~field:"supportedInterfaces[0].type"
;;

let test_interface_rejects_empty_tenant () =
  Agent_card.create_supported_interface
    ~url:"https://agent.example/a2a"
    ~protocol_binding:"JSONRPC"
    ~protocol_version:"1.0"
    ~tenant:""
    ()
  |> expect_invalid_config ~field:"supported_interface.tenant"
;;

let test_json_rejects_duplicate_metadata_field () =
  valid_json ()
  |> replace_json_field "metadata" (`Assoc [ "env", `String "a"; "env", `String "b" ])
  |> Agent_card.of_json
  |> expect_invalid_config ~field:"metadata.env"
;;

let () =
  let open Alcotest in
  run
    "Agent_card"
    [ ( "of_info"
      , [ test_case "basic" `Quick test_of_info_basic
        ; test_case "tools cap" `Quick test_capabilities_tools
        ; test_case "streaming cap" `Quick test_capabilities_streaming
        ; test_case "thinking cap" `Quick test_capabilities_thinking
        ; test_case "no thinking" `Quick test_capabilities_no_thinking
        ; test_case "mcp cap" `Quick test_capabilities_mcp
        ; test_case "elicitation cap" `Quick test_capabilities_elicitation
        ; test_case "no elicitation" `Quick test_capabilities_no_elicitation
        ; test_case "no tools" `Quick test_no_tools
        ] )
    ; ( "queries"
      , [ test_case "can_handle_tool" `Quick test_can_handle_tool
        ; test_case "providers empty stays empty" `Quick test_providers_empty_stays_empty
        ; test_case "providers custom" `Quick test_providers_custom
        ; test_case "skills from registry" `Quick test_skills_from_registry
        ; test_case "has_capability false" `Quick test_has_capability_false
        ; test_case "has_skill false" `Quick test_has_skill_false
        ] )
    ; "capabilities", [ test_case "roundtrip all" `Quick test_capability_roundtrip ]
    ; ( "json"
      , [ test_case "roundtrip" `Quick test_json_roundtrip
        ; test_case "to_json structure" `Quick test_to_json_structure
        ; test_case
            "to_json uses declared supported interface"
            `Quick
            test_to_json_uses_declared_supported_interface
        ; test_case "of_json invalid" `Quick test_of_json_invalid
        ; test_case "with auth" `Quick test_json_with_authentication
        ; test_case "no auth no meta" `Quick test_json_no_auth_no_metadata
        ; test_case "auth no creds" `Quick test_json_auth_no_credentials
        ; test_case
            "rejects literal credentials"
            `Quick
            test_json_rejects_literal_credentials
        ; test_case "with skills" `Quick test_to_json_with_skills
        ; test_case
            "legacy-only json is rejected"
            `Quick
            test_legacy_only_json_is_rejected
        ; test_case
            "interface requires protocol version"
            `Quick
            test_interface_requires_protocol_version
        ; test_case
            "interface rejects type alias"
            `Quick
            test_interface_rejects_type_alias
        ; test_case
            "supported interfaces reject empty"
            `Quick
            test_supported_interfaces_rejects_empty
        ; test_case
            "interface rejects non-HTTPS URL"
            `Quick
            test_interface_rejects_non_https_url
        ; test_case
            "interface rejects relative URL"
            `Quick
            test_interface_rejects_relative_url
        ; test_case
            "interface rejects empty binding"
            `Quick
            test_interface_rejects_empty_binding
        ; test_case
            "interface rejects empty version"
            `Quick
            test_interface_rejects_empty_version
        ; test_case
            "JSON rejects empty interfaces"
            `Quick
            test_json_rejects_empty_interfaces
        ; test_case
            "JSON rejects malformed metadata"
            `Quick
            test_json_rejects_malformed_metadata
        ; test_case
            "JSON rejects malformed authentication"
            `Quick
            test_json_rejects_malformed_authentication
        ; test_case
            "JSON rejects incomplete credential ref"
            `Quick
            test_json_rejects_incomplete_credential_ref
        ; test_case
            "JSON rejects unknown top-level field"
            `Quick
            test_json_rejects_unknown_top_level_field
        ; test_case
            "JSON rejects duplicate top-level field"
            `Quick
            test_json_rejects_duplicate_top_level_field
        ; test_case
            "JSON rejects unknown interface field"
            `Quick
            test_json_rejects_unknown_interface_field
        ; test_case
            "interface rejects empty tenant"
            `Quick
            test_interface_rejects_empty_tenant
        ; test_case
            "JSON rejects duplicate metadata field"
            `Quick
            test_json_rejects_duplicate_metadata_field
        ] )
    ]
;;
