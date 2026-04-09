(** Transport Layer - Protocol Bindings Abstraction

    Provides a unified interface for multiple transport protocols:
    - JSON-RPC 2.0 (MCP standard)
    - REST (OpenAPI compatible)
    - gRPC (Phase 4)
    - SSE (Server-Sent Events for streaming)

    Based on A2A Protocol bindings specification.
*)

(** Request/Response types *)
type request = {
  id: string option;          (* Request ID for correlation *)
  method_name: string;        (* Method/tool name *)
  params: Yojson.Safe.t;      (* Parameters as JSON *)
  headers: (string * string) list;  (* Transport headers *)
}

type response = {
  id: string option;
  success: bool;
  result: Yojson.Safe.t option;
  error: error option;
}

and error = {
  code: int;
  message: string;
  data: Yojson.Safe.t option;
}

(** Protocol type *)
type protocol =
  | JsonRpc
  | Rest
  | Grpc
  | Sse
  | Ws
  | Webrtc

let protocol_to_string = function
  | JsonRpc -> "json-rpc"
  | Rest -> "rest"
  | Grpc -> "grpc"
  | Sse -> "sse"
  | Ws -> "ws"
  | Webrtc -> "webrtc"

let protocol_of_string = function
  | "json-rpc" | "jsonrpc" -> Some JsonRpc
  | "rest" -> Some Rest
  | "grpc" -> Some Grpc
  | "sse" -> Some Sse
  | "ws" | "websocket" -> Some Ws
  | "webrtc" -> Some Webrtc
  | _ -> None

(** Transport binding configuration *)
type binding = {
  protocol: protocol;
  url: string;
  options: (string * string) list;
}

(** Standard JSON-RPC 2.0 error codes *)
module ErrorCodes = struct
  let parse_error = -32700
  let invalid_request = -32600
  let method_not_found = -32601
  let invalid_params = -32602
  let internal_error = -32603
  (* Server errors: -32000 to -32099 *)
  let server_error = -32000
  let not_initialized = -32001
  let task_not_found = -32002
  let permission_denied = -32003
end

(** Create error response *)
let make_error ?id ?(data=None) ~code ~message () : response =
  { id; success = false; result = None; error = Some { code; message; data } }

(** Create success response *)
let make_success ?id ~result () : response =
  { id; success = true; result = Some result; error = None }

(** JSON-RPC 2.0 serialization *)
module JsonRpc = struct
  let version = "2.0"

  (** Parse JSON-RPC request *)
  let parse_request (json : Yojson.Safe.t) : (request, string) result =
    let module U = Yojson.Safe.Util in
    try
      let jsonrpc = json |> U.member "jsonrpc" |> U.to_string in
      if jsonrpc <> version then
        Error (Printf.sprintf "Invalid JSON-RPC version: %s" jsonrpc)
      else
        let id = json |> U.member "id" |> U.to_string_option in
        let method_name = json |> U.member "method" |> U.to_string in
        let params = json |> U.member "params" in
        Ok { id; method_name; params; headers = [] }
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (Printexc.to_string e)

  (** Serialize JSON-RPC response *)
  let serialize_response (resp : response) : Yojson.Safe.t =
    let base = [("jsonrpc", `String version)] in
    let with_id = match resp.id with
      | Some id -> base @ [("id", `String id)]
      | None -> base @ [("id", `Null)]
    in
    if resp.success then
      `Assoc (with_id @ [("result", match resp.result with Some r -> r | None -> `Null)])
    else
      let error_obj = match resp.error with
        | Some e ->
            let base_err = [("code", `Int e.code); ("message", `String e.message)] in
            let with_data = match e.data with
              | Some d -> base_err @ [("data", d)]
              | None -> base_err
            in
            `Assoc with_data
        | None -> `Assoc [("code", `Int ErrorCodes.internal_error); ("message", `String "Unknown error")]
      in
      `Assoc (with_id @ [("error", error_obj)])

  (** Create JSON-RPC request *)
  let make_request ?id ~method_name ~params () : Yojson.Safe.t =
    let base = [
      ("jsonrpc", `String version);
      ("method", `String method_name);
      ("params", params);
    ] in
    let with_id = match id with
      | Some i -> base @ [("id", `String i)]
      | None -> base
    in
    `Assoc with_id
end

(** REST API helpers *)
module Rest = struct
  (** HTTP method type *)
  type http_method = GET | POST | PUT | DELETE | PATCH

  let method_to_string = function
    | GET -> "GET"
    | POST -> "POST"
    | PUT -> "PUT"
    | DELETE -> "DELETE"
    | PATCH -> "PATCH"

  let method_json_key method_ =
    String.lowercase_ascii (method_to_string method_)

  let list_json values =
    `List (List.map (fun value -> `String value) values)

  let actual_rest_bindings_for_operation = function
    | "masc_status" -> [ (GET, "/api/v1/status") ]
    | "masc_tasks" -> [ (GET, "/api/v1/tasks") ]
    | "masc_who" -> [ (GET, "/api/v1/agents") ]
    | "masc_messages" -> [ (GET, "/api/v1/messages") ]
    | "masc_operator_snapshot" -> [ (GET, "/api/v1/operator") ]
    | "masc_operator_digest" -> [ (GET, "/api/v1/operator/digest") ]
    | "masc_operator_action" -> [ (POST, "/api/v1/operator/action") ]
    | "masc_operator_confirm" -> [ (POST, "/api/v1/operator/confirm") ]
    | "masc_websocket_discovery" -> [ (GET, "/ws") ]
    | "masc_webrtc_offer" -> [ (POST, "/webrtc/offer") ]
    | "masc_webrtc_answer" -> [ (POST, "/webrtc/answer") ]
    | "masc_broadcast" -> [ (POST, "/api/v1/broadcast") ]
    | "masc_agent_card" -> [ (GET, "/.well-known/agent.json") ]
    | _ -> []

  let find_schema name =
    List.find_opt
      (fun (schema : Types.tool_schema) -> String.equal schema.name name)
      Config.raw_all_tool_schemas

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
            })

  let tags_for_operation name =
    if
      String.equal name "masc_transport_status"
      || String.equal name "masc_websocket_discovery"
      || String.equal name "masc_webrtc_offer"
      || String.equal name "masc_webrtc_answer"
    then
      [ "transport" ]
    else if
      String.equal name "masc_status"
      || String.equal name "masc_tasks"
      || String.equal name "masc_add_task"
      || String.equal name "masc_batch_add_tasks"
      || String.equal name "masc_transition"
      || String.equal name "masc_claim_next"
    then
      [ "tasks" ]
    else if
      String.equal name "masc_plan_init"
      || String.equal name "masc_plan_get"
      || String.equal name "masc_plan_update"
      || String.equal name "masc_note_add"
      || String.equal name "masc_deliver"
    then
      [ "planning" ]
    else if
      String.equal name "masc_broadcast"
      || String.equal name "masc_messages"
      || String.equal name "masc_a2a_delegate"
      || String.equal name "masc_a2a_subscribe"
      || String.equal name "masc_poll_events"
    then
      [ "messaging" ]
    else if
      String.equal name "decision_create"
      || String.equal name "decision_finalize"
      || String.equal name "decision_status"
      || String.equal name "masc_petition_submit"
      || String.equal name "masc_case_brief_submit"
      || String.equal name "masc_cases"
      || String.equal name "masc_case_status"
      || String.equal name "masc_ruling_status"
      || String.equal name "masc_execution_orders"
    then
      [ "decision" ]
    else
      [ "masc" ]

  let parameters_from_schema (schema : Yojson.Safe.t) =
    let required = Sdk_tool_contract.required_names schema in
    Sdk_tool_contract.property_map schema
    |> List.map (fun (name, property_schema) ->
           let description =
             Sdk_tool_contract.string_member "description" property_schema
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

  let operation_catalog_entry name (schema : Types.tool_schema) =
    let entry = help_entry name in
    let aliases =
      Sdk_tool_contract.sdk_aliases_for_operation name
      |> List.map Sdk_tool_contract.sdk_alias_json
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
        ("x-agent-sdk", `Assoc [ ("aliases", `List aliases) ]);
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

  let rest_operation_json name method_ (schema : Types.tool_schema) =
    let entry = help_entry name in
    let base_fields =
      [
        ("summary", `String entry.short_description);
        ("description", `String entry.when_to_use);
        ("tags", list_json (tags_for_operation name));
        ("x-canonical-operation", `String name);
      ]
    in
    let request_fields =
      match method_ with
      | GET | DELETE ->
          let params = parameters_from_schema schema.input_schema in
          if params = [] then
            base_fields
          else
            ("parameters", `List params) :: base_fields
      | POST | PUT | PATCH ->
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
               [
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
               ] )
         :: request_fields ))

  let generate_openapi_document
      ?(host = Env_config_core.masc_host ())
      ?(port = Env_config_core.masc_http_port_int ()) () :
      Yojson.Safe.t =
    let operation_entries =
      Sdk_tool_contract.core_remote_operation_names
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
    let sdk_tools =
      List.map Sdk_tool_contract.sdk_alias_json
        Sdk_tool_contract.sdk_bindings
    in
    let components_schemas =
      operation_entries
      |> List.map (fun (name, (schema : Types.tool_schema)) ->
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
        actual_rest_bindings_for_operation name
        |> List.iter (fun (method_, path) ->
               add_path_method path (method_json_key method_)
                 (rest_operation_json name method_ schema)))
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
              [
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
              ] );
          ("x-mcp-operations", `List operation_catalog);
          ("x-agent-sdk-tools", `List sdk_tools);
        ]);
    let path_entries =
      Hashtbl.to_seq path_table
      |> List.of_seq
      |> List.sort (fun (a, _) (b, _) -> String.compare a b)
      |> List.map (fun (path, methods) -> (path, `Assoc (List.rev methods)))
    in
    let server_url =
      if String.trim host = "" || port <= 0 then "/"
      else Printf.sprintf "http://%s:%d" host port
    in
    `Assoc
      [
        ("openapi", `String "3.1.0");
        ( "info",
          `Assoc
            [
              ("title", `String "MASC Agent Control Contract");
              ("version", `String Version.version);
              ( "description",
                `String
                  "Internal OAS export for MASC MCP agent control. Use x-mcp-operations for canonical MCP operation metadata and x-agent-sdk-tools for the current SDK-facing aliases." );
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
        ("components", `Assoc [ ("schemas", `Assoc components_schemas) ]);
      ]

  (** Compatibility helper. Returns a concrete REST route when one exists;
      otherwise fall back to the truthful MCP transport entrypoint. *)
  let tool_to_endpoint = function
    | operation_id -> (
        match actual_rest_bindings_for_operation operation_id with
        | (method_, path) :: _ -> (method_, path)
        | [] -> (POST, "/mcp"))

  (** Parse REST request to internal request *)
  let parse_request ~http_method ~path ~query_params ~body : request =
    let method_name =
      (* Try to reverse map from path to tool name *)
      match http_method, path with
      | "GET", "/" | "GET", "/api/v1/status" -> "masc_status"
      | "GET", "/ws" -> "masc_websocket_discovery"
      | "POST", "/webrtc/offer" -> "masc_webrtc_offer"
      | "POST", "/webrtc/answer" -> "masc_webrtc_answer"
      | "GET", "/api/v1/tasks" -> "masc_tasks"
      | "GET", "/api/v1/agents" -> "masc_who"
      | "GET", "/api/v1/operator" -> "masc_operator_snapshot"
      | "GET", "/api/v1/operator/digest" -> "masc_operator_digest"
      | "POST", "/api/v1/operator/action" -> "masc_operator_action"
      | "POST", "/api/v1/operator/confirm" -> "masc_operator_confirm"
      | "POST", "/api/v1/broadcast" | "POST", "/broadcast" -> "masc_broadcast"
      | "GET", "/.well-known/agent.json"
      | "GET", "/.well-known/agent-card.json" -> "masc_agent_card"
      | _, p when String.length p > 14 && String.sub p 0 14 = "/api/v1/tools/" ->
          String.sub p 14 (String.length p - 14)
      | _ -> "unknown"
    in
    let params = match body with
      | "" -> `Assoc query_params
      | s -> (match Safe_ops.parse_json_safe ~context:"http_transport" s with
              | Ok json -> json | Error _ -> `Assoc query_params)
    in
    { id = None; method_name; params; headers = [] }

  (** Generate OpenAPI-style endpoint documentation *)
  let generate_openapi_paths () : Yojson.Safe.t =
    match generate_openapi_document () with
    | `Assoc fields -> (
        match List.assoc_opt "paths" fields with
        | Some paths -> paths
        | None -> `Assoc [])
    | _ -> `Assoc []
end

(** Get available bindings for current MASC instance *)
let get_bindings ~host ~port : binding list =
  let base_url = Printf.sprintf "http://%s:%d" host port in
  let bindings =
    [
      { protocol = Sse; url = Printf.sprintf "%s/sse" base_url; options = [] };
      { protocol = JsonRpc; url = Printf.sprintf "%s/mcp" base_url; options = [] };
      { protocol = Rest; url = Printf.sprintf "%s/api/v1" base_url; options = [] };
    ]
  in
  let bindings =
    if Masc_grpc_server.is_enabled () then
      bindings
      @ [
          {
            protocol = Grpc;
            url =
              Printf.sprintf "grpc://%s:%d" host
                (Masc_grpc_server.configured_port ());
            options = [ ("health_service", Masc_grpc_server.health_service_name) ];
          };
        ]
    else
      bindings
  in
  let bindings =
    if Server_ws_standalone.is_enabled () then
      bindings
      @ [
          {
            protocol = Ws;
            url =
              Printf.sprintf "ws://%s:%d/" host
                (Server_ws_standalone.configured_port ());
            options = [ ("mode", "standalone"); ("discovery_path", "/ws") ];
          };
        ]
    else
      bindings
  in
  if Server_webrtc_transport.is_enabled () then
    bindings
    @ [
        {
          protocol = Webrtc;
          url = Printf.sprintf "%s/webrtc" base_url;
          options =
            [ ("offer_path", "/webrtc/offer"); ("answer_path", "/webrtc/answer") ];
        };
      ]
  else
    bindings

(** Bindings to JSON (for Agent Card) *)
let bindings_to_json (bindings : binding list) : Yojson.Safe.t =
  `List (List.map (fun b ->
    `Assoc [
      ("protocol", `String (protocol_to_string b.protocol));
      ("url", `String b.url);
    ]
  ) bindings)

(** Atomic statistics for monitoring *)
module Stats = struct
  let total_requests = Atomic.make 0
  let successful_requests = Atomic.make 0
  let failed_requests = Atomic.make 0
  let total_latency_ms = Atomic.make 0

  let record_request ~success ~latency_ms =
    Atomic.incr total_requests;
    if success then Atomic.incr successful_requests
    else Atomic.incr failed_requests;
    Atomic.fetch_and_add total_latency_ms latency_ms |> ignore

  let get_stats () =
    let total = Atomic.get total_requests in
    let success = Atomic.get successful_requests in
    let failed = Atomic.get failed_requests in
    let latency = Atomic.get total_latency_ms in
    `Assoc [
      ("total_requests", `Int total);
      ("successful_requests", `Int success);
      ("failed_requests", `Int failed);
      ("avg_latency_ms", `Int (if total > 0 then latency / total else 0));
    ]

  let reset () =
    Atomic.set total_requests 0;
    Atomic.set successful_requests 0;
    Atomic.set failed_requests 0;
    Atomic.set total_latency_ms 0
end
