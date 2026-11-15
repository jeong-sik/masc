(** Transport protocol names and the OpenAPI document of the REST surface. *)

(** Protocol type *)
type protocol =
  | JsonRpc
  | Rest
  | Grpc
  | Sse
  | Ws

let protocol_to_string = function
  | JsonRpc -> "json-rpc"
  | Rest -> "rest"
  | Grpc -> "grpc"
  | Sse -> "sse"
  | Ws -> "ws"

(** REST API helpers *)
module Rest = struct
  (** HTTP method type *)
  type http_method = GET | POST

  let method_to_string = function
    | GET -> "GET"
    | POST -> "POST"

  let method_json_key method_ =
    String.lowercase_ascii (method_to_string method_)

  let list_json values =
    `List (List.map (fun value -> `String value) values)

  type auth_mode =
    | Public
    | Conditional_bearer
    | Bearer_required

  let auth_mode_name = function
    | Public -> "public"
    | Conditional_bearer -> "conditional_bearer"
    | Bearer_required -> "bearer_required"

  let auth_mode_description = function
    | Public ->
        "No bearer token is required for this route."
    | Conditional_bearer ->
        "Bearer token auth is required when workspace auth/token enforcement is active; loopback-local development may allow access without a bearer."
    | Bearer_required ->
        "Authorization: Bearer <token> is required for this route."

  let openapi_bearer_security =
    `List [ `Assoc [ ("bearerAuth", `List []) ] ]

  let auth_mode_of_mcp_path () = Conditional_bearer

  type rest_binding = {
    operation : string;
    auth_mode : auth_mode;
    routes : (http_method * string) list;
  }

  (** Each REST-bound operation carries its auth mode on the same row, so the
      OpenAPI projection never meets a bound operation without a mode. *)
  let operation_rest_bindings =
    [
      { operation = "masc_status"; auth_mode = Conditional_bearer;
        routes = [ (GET, "/api/v1/status") ] };
      { operation = "masc_tasks"; auth_mode = Conditional_bearer;
        routes = [ (GET, "/api/v1/tasks") ] };
      { operation = "masc_messages"; auth_mode = Conditional_bearer;
        routes = [ (GET, "/api/v1/messages") ] };
      { operation = "masc_operator_snapshot"; auth_mode = Conditional_bearer;
        routes = [ (GET, "/api/v1/operator") ] };
      { operation = "masc_operator_digest"; auth_mode = Conditional_bearer;
        routes = [ (GET, "/api/v1/operator/digest") ] };
      { operation = "masc_operator_action"; auth_mode = Bearer_required;
        routes = [ (POST, "/api/v1/operator/action") ] };
      { operation = "masc_operator_confirm"; auth_mode = Bearer_required;
        routes = [ (POST, "/api/v1/operator/confirm") ] };
      { operation = "masc_websocket_discovery"; auth_mode = Public;
        routes = [ (GET, "/ws") ] };
      { operation = "masc_broadcast"; auth_mode = Bearer_required;
        routes = [ (POST, "/api/v1/broadcast") ] };
      { operation = "masc_agent_card"; auth_mode = Conditional_bearer;
        routes = [ (GET, "/.well-known/agent.json") ] };
    ]

  let rest_binding_of_operation name =
    List.find_opt
      (fun (binding : rest_binding) -> String.equal binding.operation name)
      operation_rest_bindings

  let actual_rest_bindings_for_operation name =
    match rest_binding_of_operation name with
    | Some binding -> binding.routes
    | None -> []

  let auth_response_entries mode =
    match mode with
    | Public -> []
    | Conditional_bearer | Bearer_required ->
        [
          ( "401",
            `Assoc
              [ ("description", `String "Authentication required or invalid bearer token") ] );
          ( "403",
            `Assoc
              [ ("description", `String "Authenticated caller lacks permission") ] );
        ]

  let auth_fields_for_mode mode =
    let base =
      [
        ("x-auth-mode", `String (auth_mode_name mode));
        ("x-auth-description", `String (auth_mode_description mode));
      ]
    in
    match mode with
    | Public -> base
    | Conditional_bearer | Bearer_required ->
        ("security", openapi_bearer_security) :: base

  let find_schema name =
    match
      List.find_opt
        (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
        Config.raw_all_tool_schemas
    with
    | Some schema -> Some schema
    | None ->
      Agent_core_tool_contract.agent_core_bindings
      |> List.find_opt (fun (binding : Agent_core_tool_contract.agent_core_tool_binding) ->
             String.equal binding.canonical_operation name)
      |> Option.map (fun (binding : Agent_core_tool_contract.agent_core_tool_binding) ->
             { Masc_domain.name
             ; description = binding.description
             ; input_schema = binding.input_schema
             })

  let help_entry name =
    match Tool_help_registry.find_entry Config.raw_all_tool_schemas name with
    | Some entry -> entry
    | None -> (
        match find_schema name with
        | Some schema -> Tool_help_registry.entry_of_schema schema
        | None ->
            {
              Tool_help_registry.name = name;
              short_description = name;
              when_to_use = "Use when you need this operation.";
              key_constraints = [];
              details_markdown = name;
              doc_refs = [];
              prompt_hints = [];
              examples = [];
              alternatives = [];
            })

  let operation_tag_groups =
    [
      ( "transport",
        [
          "masc_transport_status";
          "masc_websocket_discovery";
        ] );
      ( "tasks",
        [
          "masc_status";
          "masc_tasks";
          "masc_add_task";
          "masc_batch_add_tasks";
          "masc_transition";
        ] );
      ( "planning",
        [
        ] );
      ( "messaging",
        [
          "masc_broadcast";
          "masc_messages";
        ] );
      ( "operator",
        [
          "masc_operator_snapshot";
          "masc_operator_digest";
          "masc_operator_action";
          "masc_operator_confirm";
        ] );
    ]

  let tags_for_operation name =
    operation_tag_groups
    |> List.find_map (fun (tag, operations) ->
           if List.exists (String.equal name) operations then Some [ tag ]
           else None)
    |> Option.value ~default:[ "masc" ]

  let parameters_from_schema (schema : Yojson.Safe.t) =
    let required = Agent_core_tool_contract.required_names schema in
    Agent_core_tool_contract.property_map schema
    |> List.map (fun (name, property_schema) ->
           let description =
             Agent_core_tool_contract.string_member "description" property_schema
             |> Option.value
                  ~default:(Printf.sprintf "%s parameter" name)
           in
           `Assoc
             [
               ("name", `String name);
               ("in", `String "query");
               ("required", `Bool (List.mem name required));
               ("description", `String description);
               ("schema", property_schema);
             ])

  let operation_catalog_entry name (schema : Masc_domain.tool_schema) =
    let entry = help_entry name in
    let aliases =
      Agent_core_tool_contract.agent_core_aliases_for_operation name
      |> List.map Agent_core_tool_contract.agent_core_alias_json
    in
    let rest_bindings =
      actual_rest_bindings_for_operation name
      |> List.map (fun (method_, path) ->
             `Assoc
               [
                 ("method", `String (method_to_string method_));
                 ("path", `String path);
               ])
    in
    `Assoc
      [
        ("name", `String name);
        ("operationId", `String name);
        ("summary", `String entry.short_description);
        ("description", `String entry.details_markdown);
        ("inputSchema", schema.input_schema);
        ("tags", list_json (tags_for_operation name));
        ("x-mcp-tool", `Assoc (Tool_catalog.metadata_to_fields name));
        ("x-agent-core", `Assoc [ ("aliases", `List aliases) ]);
        ("x-rest-bindings", `List rest_bindings);
      ]

  let mcp_request_schema () =
    `Assoc
      [
        ("type", `String "object");
        ( "properties",
          `Assoc
            [
              ( "jsonrpc",
                `Assoc
                  [
                    ("type", `String "string");
                    ("const", `String "2.0");
                  ] );
              ( "method",
                `Assoc
                  [
                    ("type", `String "string");
                    ("const", `String "tools/call");
                  ] );
              ( "params",
                `Assoc
                  [
                    ("type", `String "object");
                    ( "properties",
                      `Assoc
                        [
                          ("name", `Assoc [ ("type", `String "string") ]);
                          ("arguments", `Assoc [ ("type", `String "object") ]);
                        ] );
                    ("required", `List [ `String "name"; `String "arguments" ]);
                  ] );
              ( "id",
                `Assoc
                  [
                    ( "oneOf",
                      `List
                        [
                          `Assoc [ ("type", `String "integer") ];
                          `Assoc [ ("type", `String "string") ];
                          `Assoc [ ("type", `String "null") ];
                        ] );
                  ] );
            ] );
        ( "required",
          `List
            [ `String "jsonrpc"; `String "method"; `String "params"; `String "id" ] );
      ]

  let success_response_schema =
    `Assoc
      [
        ("type", `String "object");
        ("description", `String "JSON-RPC success or error envelope.");
      ]

  let rest_operation_json ~auth_mode name method_ (schema : Masc_domain.tool_schema) =
    let entry = help_entry name in
    let base_fields =
      [
        ("summary", `String entry.short_description);
        ("description", `String entry.when_to_use);
        ("tags", list_json (tags_for_operation name));
        ("x-canonical-operation", `String name);
      ]
      @ auth_fields_for_mode auth_mode
    in
    let request_fields =
      match method_ with
      | GET ->
          let params = parameters_from_schema schema.input_schema in
          if params = [] then
            base_fields
          else
            ("parameters", `List params) :: base_fields
      | POST ->
          ( "requestBody",
            `Assoc
              [
                ("required", `Bool true);
                ( "content",
                  `Assoc
                    [
                      ( "application/json",
                        `Assoc [ ("schema", schema.input_schema) ] );
                    ] );
              ] )
          :: base_fields
    in
    `Assoc
      (List.rev
         ( ( "responses",
             `Assoc
               ([
                  ( "200",
                    `Assoc
                      [
                        ("description", `String "Success");
                        ( "content",
                          `Assoc
                            [
                              ( "application/json",
                                `Assoc
                                  [ ("schema", success_response_schema) ] );
                            ] );
                      ] );
                ]
                @ auth_response_entries auth_mode) )
         :: request_fields ))

  let generate_openapi_document
      ~scheme
      ?(host = Env_config_core.masc_host ())
      ?(port = Env_config_core.masc_http_port_int ()) () :
      Yojson.Safe.t =
    let mcp_auth_mode = auth_mode_of_mcp_path () in
    let operation_entries =
      Agent_core_tool_contract.core_remote_operation_names
      |> List.filter_map (fun name ->
             match find_schema name with
             | Some schema -> Some (name, schema)
             | None -> None)
    in
    let operation_catalog =
      List.map
        (fun (name, schema) -> operation_catalog_entry name schema)
        operation_entries
    in
    let agent_core_tools =
      List.map Agent_core_tool_contract.agent_core_alias_json
        Agent_core_tool_contract.agent_core_bindings
    in
    let components_schemas =
      operation_entries
      |> List.map (fun (name, (schema : Masc_domain.tool_schema)) ->
             (name ^ "Input", schema.input_schema))
    in
    let path_table : (string, (string * Yojson.Safe.t) list) Hashtbl.t =
      Hashtbl.create 32
    in
    let add_path_method path method_key operation_json =
      let existing =
        Hashtbl.find_opt path_table path |> Option.value ~default:[]
      in
      Hashtbl.replace path_table path ((method_key, operation_json) :: existing)
    in
    List.iter
      (fun (name, schema) ->
        match rest_binding_of_operation name with
        | None -> ()
        | Some binding ->
            List.iter
              (fun (method_, path) ->
                add_path_method path (method_json_key method_)
                  (rest_operation_json ~auth_mode:binding.auth_mode name method_
                     schema))
              binding.routes)
      operation_entries;
    add_path_method "/mcp" "post"
      (`Assoc
        [
          ("operationId", `String "mcp_tools_call");
          ("summary", `String "Call MASC MCP tools over JSON-RPC 2.0.");
          ( "description",
            `String
              "Primary control transport for internal agents. The canonical operation catalog is exposed through x-mcp-operations." );
          ( "requestBody",
            `Assoc
              [
                ("required", `Bool true);
                ( "content",
                  `Assoc
                    [
                      ( "application/json",
                        `Assoc [ ("schema", mcp_request_schema ()) ] );
                    ] );
              ] );
          ( "responses",
            `Assoc
              ([
                 ( "200",
                   `Assoc
                     [
                       ("description", `String "JSON-RPC response envelope");
                       ( "content",
                         `Assoc
                           [
                             ( "application/json",
                               `Assoc
                                 [ ("schema", success_response_schema) ] );
                           ] );
                     ] );
               ]
               @ auth_response_entries mcp_auth_mode) );
          ("x-auth-mode", `String (auth_mode_name mcp_auth_mode));
          ("x-auth-description", `String (auth_mode_description mcp_auth_mode));
          ("security", openapi_bearer_security);
          ("x-mcp-operations", `List operation_catalog);
          ("x-agent-core-tools", `List agent_core_tools);
        ]);
    let path_entries =
      Hashtbl.to_seq path_table
      |> List.of_seq
      |> List.sort (fun (a, _) (b, _) -> String.compare a b)
      |> List.map (fun (path, methods) -> (path, `Assoc (List.rev methods)))
    in
    let server_url =
      (* "servers" is the address a reader of this document dials, and [host]
         defaults to MASC_HOST -- the server's bind setting, whose own help
         text offers 0.0.0.0. Fold it the way every other advertised address
         is folded (#30383). The HTTP callers pass a Host header instead,
         which a client is equally free to send as "0.0.0.0:8935". [scheme]
         is the listener's: the document the TLS listener serves points its
         reader at https (#50025). *)
      let advertised = Masc_network_defaults.normalize_advertised_host host in
      if advertised = "" || port <= 0 then "/"
      else
        Printf.sprintf
          "%s://%s:%d"
          scheme
          Masc_network_defaults.(url_host_to_string (url_host_of_string advertised))
          port
    in
    `Assoc
      [
        ("openapi", `String "3.1.0");
        ( "info",
          `Assoc
            [
              ("title", `String "MASC Agent Control Contract");
              ("version", `String Runtime_build_version.current);
              ( "description",
                `String
                  "Internal AGENT_CORE export for MASC MCP agent control. Use x-mcp-operations for canonical MCP operation metadata and x-agent-core-tools for the current agent-core projections." );
            ] );
        ( "servers",
          `List
            [
              `Assoc
                [
                  ("url", `String server_url);
                ];
            ] );
        ("paths", `Assoc path_entries);
        ( "components",
          `Assoc
            [
              ("schemas", `Assoc components_schemas);
              ( "securitySchemes",
                `Assoc
                  [
                    ( "bearerAuth",
                      `Assoc
                        [
                          ("type", `String "http");
                          ("scheme", `String "bearer");
                          ("bearerFormat", `String "opaque-token");
                          ( "description",
                            `String
                              "MASC workspace bearer token. Some loopback-local routes may additionally permit same-origin browser access." );
                        ] );
                  ] );
            ] );
      ]
end
