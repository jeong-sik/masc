(* HIGH-RISK-UNREVIEWED: see the interface. *)

module A = Mcp_request_admission
module H = Server_mcp_transport_http_headers
module P = Mcp_transport_protocol
module R = Login_routes

let path = "/mcp"

(* What "method not found" calls this endpoint. *)
let endpoint = "person"

(* A tool call carries what a route of a person reads as its body, as a JSON
   value inside the message. Four times the body of such a route leaves room
   for the envelope and for the escapes of the value. *)
let max_message_bytes = 4 * 16 * 1024

type installation =
  { zone : Authz_zone.t
  ; env : Eio_unix.Stdenv.base
  ; base_path : string
  }

type caller =
  { trusted : Authz_zone.trusted
  ; now_ms : int
  ; gate : Auth_gate.request
  }

let admitted { trusted; now_ms; gate } =
  match Auth_gate.decide trusted ~now_ms Route_access.Read_auth gate with
  | Ok (Auth_gate.Authenticated (_ : Auth_gate.authenticated)) -> Ok ()
  | Ok (Auth_gate.Anonymous | Auth_gate.Judged_by_route) | Error (_ : Auth_gate.reason) ->
    (* The who-am-I route makes the same judgment on the same snapshot, so
       its answer is the refusal of this one. *)
    Error (Auth_preview.whoami trusted ~now_ms gate)
;;

(* ---- the tools ---- *)

type tool =
  | Whoami
  | Runtimes
  | Keepers
  | Keeper_create
  | Keeper_assign
  | Keeper_turn
  | Keeper_conversation_new
  | Keeper_conversation

let tools =
  [ Whoami
  ; Runtimes
  ; Keepers
  ; Keeper_create
  ; Keeper_assign
  ; Keeper_turn
  ; Keeper_conversation_new
  ; Keeper_conversation
  ]
;;

let name_of = function
  | Whoami -> "masc_whoami"
  | Runtimes -> "masc_my_runtimes"
  | Keepers -> "masc_my_keepers"
  | Keeper_create -> "masc_my_keeper_create"
  | Keeper_assign -> "masc_my_keeper_assign"
  | Keeper_turn -> "masc_my_keeper_turn"
  | Keeper_conversation_new -> "masc_my_keeper_conversation_new"
  | Keeper_conversation -> "masc_my_keeper_conversation"
;;

(* Decoded when the module starts, as every tool definition the binary
   publishes is: a binary that lacks one does not start. *)
let definition_of =
  let load tool = Tool_definition_embedded.load (name_of tool) in
  let whoami = load Whoami in
  let runtimes = load Runtimes in
  let keepers = load Keepers in
  let keeper_create = load Keeper_create in
  let keeper_assign = load Keeper_assign in
  let keeper_turn = load Keeper_turn in
  let keeper_conversation_new = load Keeper_conversation_new in
  let keeper_conversation = load Keeper_conversation in
  function
  | Whoami -> whoami
  | Runtimes -> runtimes
  | Keepers -> keepers
  | Keeper_create -> keeper_create
  | Keeper_assign -> keeper_assign
  | Keeper_turn -> keeper_turn
  | Keeper_conversation_new -> keeper_conversation_new
  | Keeper_conversation -> keeper_conversation
;;

let definitions = List.map (fun tool -> tool, definition_of tool) tools

let tool_json ((_ : tool), { Tool_definition_toml.schema; title; _ }) =
  `Assoc
    ([ "name", `String schema.Masc_domain.name ]
     @ (match title with
        | Some title -> [ "title", `String title ]
        | None -> [])
     @ [ "description", `String schema.Masc_domain.description
       ; "inputSchema", schema.Masc_domain.input_schema
       ])
;;

(* The state of the snapshot that judges the request, as a route of a person
   reads it. *)
let state { trusted; now_ms = (_ : int); gate = (_ : Auth_gate.request) } =
  (trusted :> Authz_zone.snapshot).Authz_zone.state
;;

(* The one a tool acts for, judged by [gate] as the route of the tool judges.
   A request that does not pass gets the answer of that route. *)
let judged gate { trusted; now_ms; gate = request } f =
  match gate trusted ~now_ms request with
  | Error answer -> answer
  | Ok who -> f who
;;

(* The body that the route function of a tool reads: the arguments [names],
   in the order the function takes them. The definition of the tool requires
   each as a string, so one that is missing here answers a 400 as a route
   does for a body it cannot read. *)
let with_body names arguments f =
  let fields =
    match arguments with
    | `Assoc fields -> fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []
  in
  let members =
    List.fold_right
      (fun name members ->
        match members, List.assoc_opt name fields with
        | Ok members, Some (`String value) -> Ok ((name, `String value) :: members)
        | Ok (_ : (string * Yojson.Safe.t) list), (Some _ | None) -> Error name
        | (Error (_ : string) as missing), (Some _ | None) -> missing)
      names
      (Ok [])
  in
  match members with
  | Ok members -> f ~body:(Yojson.Safe.to_string (`Assoc members))
  | Error name ->
    R.json R.Bad_request_400 [ "error", `String (Printf.sprintf "The argument %s must be a string." name) ]
;;

(* The query that the read of a conversation takes: the Keeper, and the
   conversation when the arguments name one. The definition of the tool
   allows no other argument. *)
let conversation_query arguments =
  let fields =
    match arguments with
    | `Assoc fields -> fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []
  in
  let text name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Ok (Some value)
    | None -> Ok None
    | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) -> Error name
  in
  match text "keeper_id", text "conversation_id" with
  | Ok (Some keeper), Ok None -> Ok [ "keeper_id", keeper ]
  | Ok (Some keeper), Ok (Some conversation) ->
    Ok [ "keeper_id", keeper; "conversation_id", conversation ]
  | Ok None, (Ok (_ : string option) | Error (_ : string)) -> Error "keeper_id"
  | Error name, (Ok (_ : string option) | Error (_ : string)) -> Error name
  | Ok (Some (_ : string)), Error name -> Error name
;;

(* The function of the person's route, with the judgment that route makes. *)
let run installation caller tool ~arguments =
  match tool with
  | Whoami -> Auth_preview.whoami caller.trusted ~now_ms:caller.now_ms caller.gate
  | Runtimes ->
    judged Auth_preview.person caller (fun person ->
      let base_path = installation.base_path in
      let config = Result.to_option (Server_runtime_setup_actions.config ~base_path) in
      Auth_preview.provider_accounts ~base_path ~config (state caller) person)
  | Keepers -> judged Auth_preview.keeper_owner caller (Auth_preview_keeper.list (state caller))
  | Keeper_create ->
    judged Auth_preview.keeper_owner caller (fun user_id ->
      with_body [ "keeper_id" ] arguments (Auth_preview_keeper.make installation.zone user_id))
  | Keeper_assign ->
    judged Auth_preview.keeper_owner caller (fun user_id ->
      with_body [ "keeper_id"; "runtime_id" ] arguments (Auth_preview_keeper.assign installation.zone user_id))
  | Keeper_turn ->
    (* The turn starts the client of the person's account on a home under
       their namespace, inside the scope of the token that authenticated the
       request, so its judgment gives both. *)
    judged
      Auth_preview.keeper_turn_caller
      caller
      (fun { Auth_preview.person = { Auth_preview.user_id; namespace }; pat } ->
         with_body
           [ "keeper_id"; "message" ]
           arguments
           (Server_preview_keeper_turn.run
              ~env:installation.env
              ~person:{ Server_setup_account_login.zone = installation.zone; user_id; namespace }
              ~pat
              ~base_path:installation.base_path))
  | Keeper_conversation_new ->
    (* The conversation is recorded under the namespace of the person, which
       this judgment gives. Starting one calls no model, so the token is not
       read. *)
    judged
      Auth_preview.keeper_turn_caller
      caller
      (fun
          { Auth_preview.person = { Auth_preview.user_id; namespace }
          ; pat = (_ : Authz_types.Pat_binding.t)
          }
        ->
         with_body
           [ "keeper_id" ]
           arguments
           (Server_preview_keeper_conversation.start
              ~env:installation.env
              ~person:{ Server_setup_account_login.zone = installation.zone; user_id; namespace }
              ~base_path:installation.base_path))
  | Keeper_conversation ->
    judged
      Auth_preview.keeper_conversation_reader
      caller
      (fun { Auth_preview.user_id; namespace } ->
         match conversation_query arguments with
         | Ok query ->
           Server_preview_keeper_conversation.read
             ~person:{ Server_setup_account_login.zone = installation.zone; user_id; namespace }
             ~base_path:installation.base_path
             ~query
         | Error name ->
           R.json
             R.Bad_request_400
             [ "error", `String (Printf.sprintf "The argument %s must be a string." name) ])
;;

let succeeded = function
  | R.Ok_200 | R.No_content_204 -> true
  | R.See_other_303
  | R.Bad_request_400
  | R.Unauthorized_401
  | R.Forbidden_403
  | R.Not_found_404
  | R.Conflict_409
  | R.Too_many_requests_429
  | R.Internal_error_500
  | R.Bad_gateway_502
  | R.Service_unavailable_503
  | R.Gateway_timeout_504 -> false
;;

let tool_result ~is_error text =
  `Assoc
    [ "content", `List [ `Assoc [ "type", `String "text"; "text", `String text ] ]
    ; "isError", `Bool is_error
    ]
;;

(* The body of the route's answer is the text of the result. Its headers are
   those of an HTTP answer to a browser, which a tool result is not. *)
let result_of_answer { R.status; headers = (_ : (string * string) list); body } =
  tool_result ~is_error:(not (succeeded status)) body
;;

type call =
  { tool : tool
  ; arguments : Yojson.Safe.t
  }

let call_of_params = function
  | Some (`Assoc fields) ->
    (match List.assoc_opt "name" fields with
     | Some (`String name) ->
       (match List.find_opt (fun tool -> String.equal (name_of tool) name) tools with
        | None -> Error (Printf.sprintf "Unknown tool: %s" name)
        | Some tool ->
          (match List.assoc_opt "arguments" fields with
           | None -> Ok { tool; arguments = `Assoc [] }
           | Some (`Assoc (_ : (string * Yojson.Safe.t) list) as arguments) -> Ok { tool; arguments }
           | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
             Error "Invalid params: arguments must be an object"))
     | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) | None ->
       Error "Invalid params: name must be a string")
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) | None ->
    Error "Invalid params: expected an object with a name"
;;

let call installation caller { tool; arguments } =
  let { Tool_definition_toml.schema; _ } = definition_of tool in
  match
    Tool_input_contract.check_arguments
      ~contract:Tool_input_contract.Host_tool
      ~schema:(Some schema.Masc_domain.input_schema)
      ~name:schema.Masc_domain.name
      ~args:arguments
  with
  | Error { Tool_input_contract.message; _ } -> tool_result ~is_error:true message
  | Ok (arguments, (_ : Tool_input_contract.accepted)) ->
    result_of_answer (run installation caller tool ~arguments)
;;

(* ---- the methods ---- *)

let method_allowed = function
  | "server/discover" | "initialize" | "notifications/initialized" | "ping" | "tools/list" | "tools/call" -> true
  | _ -> false
;;

(* The endpoint has tools and nothing else, and no stream to say on that the
   list changed. *)
let capabilities = `Assoc [ "tools", `Assoc [ "listChanged", `Bool false ] ]

let initialize ~id params =
  match P.initialize_protocol_version params with
  | Error message -> A.error ~id Mcp_error_code.Invalid_params message
  | Ok requested ->
    P.make_response
      ~id
      (`Assoc
          [ "protocolVersion", `String (P.negotiate_legacy_protocol_version requested)
          ; "serverInfo", Mcp_server.server_info
          ; "capabilities", capabilities
          ])
;;

let discover ~id =
  P.make_response
    ~id
    (`Assoc
        ([ "supportedVersions", `List (List.map (fun version -> `String version) P.supported_protocol_versions)
         ; "capabilities", capabilities
         ; "serverInfo", Mcp_server.server_info
         ]
         @ Mcp_server.(cache_hint_fields static_catalogue_cache_hint)))
;;

(* Every tool is on the one page, so the endpoint issues no cursor and takes
   none. *)
let list_tools ~id params =
  let cursor =
    match params with
    | Some (`Assoc fields) -> List.assoc_opt "cursor" fields
    | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) | None -> None
  in
  match cursor with
  | Some (_ : Yojson.Safe.t) ->
    A.error ~id Mcp_error_code.Invalid_params "Invalid params: this endpoint issued no cursor"
  | None ->
    P.make_response
      ~id
      (`Assoc
          ([ "tools", `List (List.map tool_json definitions) ]
           @ Mcp_server.(cache_hint_fields static_catalogue_cache_hint)))
;;

let call_tool installation caller ~id params =
  match call_of_params params with
  | Error message -> A.error ~id Mcp_error_code.Invalid_params message
  | Ok call_ -> P.make_response ~id (call installation caller call_)
;;

let result installation caller ~id (request : P.jsonrpc_request) =
  match request.method_ with
  | "server/discover" -> discover ~id
  | "initialize" -> initialize ~id request.params
  | "ping" -> P.make_response ~id (`Assoc [])
  | "tools/list" -> list_tools ~id request.params
  | "tools/call" -> call_tool installation caller ~id request.params
  | method_ ->
    (* [method_allowed] let it through, and no arm above takes it: a
       notification method sent with an id. *)
    A.error ~id Mcp_error_code.Method_not_found ("Method not found: " ^ method_)
;;

(* ---- the answer ---- *)

type answer =
  { status : Httpun.Status.t
  ; headers : (string * string) list
  ; body : string
  }

let no_store = "cache-control", "no-store"
let json_headers = [ "content-type", P.Http_negotiation.json_content_type; no_store ]

(* A revision that selects its protocol per request is named back on the
   answer, as the single-user endpoint does. *)
let version_headers = function
  | P.Stateless_protocol version -> H.protocol_version_headers version
  | P.Legacy_protocol -> []
;;

let bad_request body = { status = `Bad_request; headers = json_headers; body }

let json_answer ?(headers = []) request ~body json =
  let status =
    match H.modern_response_http_error_status ~request ~body_str:body json with
    | Some status -> status
    | None -> if Mcp_error_code.is_http_error_response json then `Bad_request else `OK
  in
  { status; headers = json_headers @ headers; body = Yojson.Safe.to_string json }
;;

let answer installation caller request ~body =
  match H.classify_mcp_accept request with
  | P.Http_negotiation.Rejected ->
    bad_request
      (Server_mcp_transport_http_session.correlate_error_body_to_request
         ~request_body:body
         (Mcp_error_code.jsonrpc_error_body
            Mcp_error_code.Invalid_request
            ~message:Server_mcp_request_context.invalid_accept_message))
  | P.Http_negotiation.Streamable ->
    (match H.validate_2026_request_headers request body with
     | Error rejection -> bad_request (H.header_rejection_body body rejection)
     | Ok () ->
       (match A.admit ~method_allowed ~endpoint body with
        | A.Answer `Null | A.Notification (_ : P.jsonrpc_request) ->
          { status = `Accepted; headers = [ no_store ]; body = "" }
        | A.Answer json -> json_answer request ~body json
        | A.Request { id; message = (_ : Yojson.Safe.t); request = message; protocol } ->
          json_answer
            ~headers:(version_headers protocol)
            request
            ~body
            (result installation caller ~id message)))
;;
