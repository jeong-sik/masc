open Result.Syntax

module Store = Server_mcp_transport_session_store

let mcp_protocol_versions = Mcp_transport_protocol.supported_protocol_versions
let mcp_protocol_version_default = Mcp_transport_protocol.default_protocol_version

let is_valid_protocol_version version =
  Mcp_transport_protocol.is_supported_protocol_version version
;;

let is_known_session ~sessions session_id =
  Option.is_some (Store.find_active sessions ~session_id)
;;

let mcp_session_owner ~sessions session_id =
  Option.map
    (fun (session : Store.session) -> session.owner)
    (Store.find_active sessions ~session_id)
;;

let same_owner
      (left : Server_transport_admission.identity)
      (right : Server_transport_admission.identity)
  =
  String.equal left.agent_name right.agent_name
;;

let owner_mismatch_message ~session_id =
  Printf.sprintf
    "Session %s is not owned by the authenticated credential."
    session_id
;;

let validate_mcp_session_owner_for_request ~sessions ~session_id ~requester =
  match mcp_session_owner ~sessions session_id with
  | Some owner when same_owner owner requester -> Ok ()
  | Some _ -> Error (owner_mismatch_message ~session_id)
  | None -> Ok ()
;;

let authorize_mcp_session_delete ~sessions ~session_id ~requester =
  match mcp_session_owner ~sessions session_id with
  | Some owner when same_owner owner requester -> Ok ()
  | Some _ when requester.Server_transport_admission.role = Masc_domain.Admin -> Ok ()
  | Some _ -> Error (owner_mismatch_message ~session_id)
  | None when requester.Server_transport_admission.role = Masc_domain.Admin -> Ok ()
  | None ->
    Error
      (Printf.sprintf
         "Session %s has no active credential owner metadata; only Admin may delete it."
         session_id)
;;

let ensure_sse_backing_session_for_known_transport_session
      ~sessions
      ~transport_session_id
      ~sse_session_id
  =
  if is_known_session ~sessions transport_session_id
  then begin
    let (_ : Session.McpSessionStore.mcp_session) =
      Session.McpSessionStore.get_or_create ~id:sse_session_id ()
    in
    ()
  end
;;

type initialize_commit_result =
  | Not_initialize
  | Initialized

let unique_field name fields =
  match List.filter_map (fun (key, value) -> if String.equal key name then Some value else None) fields with
  | [ value ] -> Some value
  | [] | _ :: _ :: _ -> None
;;

let initialize_request body =
  try
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      (match
         ( unique_field "jsonrpc" fields
         , unique_field "method" fields
         , unique_field "id" fields
         , unique_field "params" fields )
       with
       | ( Some (`String "2.0")
         , Some (`String "initialize")
         , Some request_id
         , Some (`Assoc params) ) ->
         (match unique_field "protocolVersion" params with
          | Some (`String protocol_version)
            when is_valid_protocol_version protocol_version ->
            Some (request_id, protocol_version)
          | Some _ | None -> None)
       | _ -> None)
    | _ -> None
  with
  | Yojson.Json_error _ -> None
;;

let response_is_success_for_request ~request_id = function
  | `Assoc fields ->
    (match
       ( unique_field "jsonrpc" fields
       , unique_field "id" fields
       , unique_field "result" fields )
     with
     | Some (`String "2.0"), Some response_id, Some _ ->
       response_id = request_id
       && not (List.exists (fun (key, _) -> String.equal key "error") fields)
     | _ -> false)
  | _ -> false
;;

let commit_successful_initialize
      ~sessions
      ~session_id
      ~profile
      ~requester
      ~otel_transport_context
      ~request_body
      ~response_json
  =
  match initialize_request request_body with
  | Some (request_id, protocol_version)
    when response_is_success_for_request ~request_id response_json ->
    let initialized_at = Time_compat.now () in
    let session : Store.session =
      { session_id
      ; protocol_version
      ; tool_profile = profile
      ; owner = requester
      ; started_at = initialized_at
      ; transport_context = otel_transport_context
      }
    in
    let+ () = Store.initialize sessions session in
    Initialized
  | Some _ | None -> Ok Not_initialize
;;

let profile_label = function
  | Server_mcp_transport_http_types.Full -> "/mcp"
  | Server_mcp_transport_http_types.Managed_agent -> "/mcp/managed"
  | Server_mcp_transport_http_types.Operator_remote -> "/mcp/operator"
;;

let validate_mcp_session_profile ~sessions ~profile session_id =
  match Store.find_active sessions ~session_id with
  | None -> Ok ()
  | Some session when session.Store.tool_profile = profile -> Ok ()
  | Some session ->
    Error
      (Printf.sprintf
         "Session %s belongs to %s, not %s."
         session_id
         (profile_label session.tool_profile)
         (profile_label profile))
;;

let validate_mcp_session_delete_profile ~sessions ~profile session_id =
  match profile with
  | Server_mcp_transport_http_types.Operator_remote ->
    (match Store.find_active sessions ~session_id with
     | Some { tool_profile = Server_mcp_transport_http_types.Operator_remote; _ } -> Ok ()
     | Some session ->
       Error
         (Printf.sprintf
            "Session %s belongs to %s, not %s."
            session_id
            (profile_label session.tool_profile)
            (profile_label profile))
     | None ->
       Error
         (Printf.sprintf
            "Session %s is not registered on %s."
            session_id
            (profile_label profile)))
  | Server_mcp_transport_http_types.Full
  | Server_mcp_transport_http_types.Managed_agent ->
    validate_mcp_session_profile ~sessions ~profile session_id
;;

let protocol_version_from_body body_str =
  Mcp_transport_protocol.protocol_version_from_body body_str
;;

let get_session_id_query target =
  match String.split_on_char '?' target with
  | [ _; query ] ->
    query
    |> String.split_on_char '&'
    |> List.find_map (fun param ->
      match String.split_on_char '=' param with
      | [ "session_id"; value ] | [ "sessionId"; value ] -> Some value
      | _ -> None)
  | _ -> None
;;

let capitalize_ascii (value : string) =
  if String.equal value ""
  then value
  else begin
    let first = Char.uppercase_ascii value.[0] |> String.make 1 in
    let rest =
      if String.length value > 1
      then
        String.sub value 1 (String.length value - 1) |> String.lowercase_ascii
      else ""
    in
    first ^ rest
  end
;;

let title_case_header_name (header_name : string) =
  header_name
  |> String.split_on_char '-'
  |> List.map capitalize_ascii
  |> String.concat "-"
;;

let get_header_any_case (headers : Httpun.Headers.t) (name : string) =
  match Httpun.Headers.get headers name with
  | Some _ as value -> value
  | None ->
    let title_case = title_case_header_name name in
    (match Httpun.Headers.get headers title_case with
     | Some _ as value -> value
     | None -> Httpun.Headers.get headers (String.uppercase_ascii name))
;;

let get_cookie_value (request : Httpun.Request.t) cookie_name =
  match get_header_any_case request.headers "cookie" with
  | None -> None
  | Some raw ->
    raw
    |> String.split_on_char ';'
    |> List.find_map (fun part ->
      match String.split_on_char '=' (String.trim part) with
      | key :: value_parts
        when String.equal
               (String.lowercase_ascii (String.trim key))
               (String.lowercase_ascii cookie_name) ->
        let value = String.concat "=" value_parts |> String.trim in
        if String.equal value "" then None else Some value
      | _ -> None)
;;

let get_session_id_any (request : Httpun.Request.t) =
  match get_session_id_query request.target with
  | Some _ as session_id -> session_id
  | None ->
    (match get_header_any_case request.headers "mcp-session-id" with
     | Some _ as session_id -> session_id
     | None -> get_cookie_value request "mcp-session-id")
;;

let get_protocol_version (request : Httpun.Request.t) =
  match get_header_any_case request.headers "mcp-protocol-version" with
  | Some version -> version
  | None -> mcp_protocol_version_default
;;

let get_protocol_version_header_opt (request : Httpun.Request.t) =
  get_header_any_case request.headers "mcp-protocol-version"
;;

let validate_protocol_version_continuity ~sessions ~session_id request =
  let validate_supported version =
    if is_valid_protocol_version version
    then Ok ()
    else Error (Printf.sprintf "Unsupported MCP-Protocol-Version: %s" version)
  in
  let provided = get_protocol_version_header_opt request in
  match Store.find_active sessions ~session_id with
  | Some session ->
    (match provided with
     | None -> Ok ()
     | Some version ->
       let* () = validate_supported version in
       if String.equal version session.Store.protocol_version
       then Ok ()
       else
         Error
           (Printf.sprintf
              "MCP-Protocol-Version mismatch for session %s: expected %s, got %s."
              session_id
              session.protocol_version
              version))
  | None ->
    (match provided with
     | Some version -> validate_supported version
     | None -> Ok ())
;;

let get_protocol_version_for_session ~sessions ?session_id request =
  match session_id with
  | Some session_id ->
    (match Store.find_active sessions ~session_id with
     | Some session -> session.Store.protocol_version
     | None -> get_protocol_version request)
  | None -> get_protocol_version request
;;

let query_param request key =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.get_query_param uri key
;;
