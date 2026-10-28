(* HIGH-RISK-UNREVIEWED: OAuth scope challenge on the MCP request path. *)

let tools_call_name body =
  let module Protocol = Mcp_transport_protocol in
  match Yojson.Safe.from_string body with
  | json when Protocol.is_jsonrpc_v2 json && Protocol.has_unique_jsonrpc_fields json ->
    (match Protocol.jsonrpc_request_of_yojson json with
     | Ok request
       when String.equal request.method_ "tools/call"
            && not (Protocol.is_notification request)
            && Protocol.is_valid_request_id (Protocol.get_id request) ->
       (match
          Protocol.classify_request_protocol
            ~require_stateless:false ~method_:request.method_ ~params:request.params
        with
        | Ok (Protocol.Stateless_protocol _)
          when Protocol.request_has_continuation_fields request.params -> None
        | Error _ -> None
        | Ok (Protocol.Legacy_protocol | Protocol.Stateless_protocol _) ->
          (match Masc.Mcp_server_eio_call_request.decode request.params with
           | Ok call -> Some (Masc.Mcp_server_eio_call_request.requested_name call)
           | Error _ -> None))
     | Ok _ | Error _ -> None)
  | _ -> None
  | exception Yojson.Json_error _ -> None
;;

(* The narrowest supported scope whose role grants [permission]. The role a
   scope grants is [Auth_oauth.effective_role] on an Admin approval, the only
   approval that can grant every supported scope. *)
let scope_granting permission =
  List.find_opt
    (fun scope ->
      match Auth_oauth.effective_role ~bootstrap_role:Masc_domain.Admin [ scope ] with
      | Ok role -> Masc_domain.has_permission role permission
      | Error _ -> false)
    Auth_oauth.scopes_supported
;;

let required_scope ~base_path ~auth_token ~allowed_tool ~body =
  match auth_token with
  | None -> None
  | Some _ when not (Auth.is_auth_enabled base_path) -> None
  | Some token ->
    (match tools_call_name body with
     | None -> None
     (* The dispatcher audits non-public calls, including denied ones. Keep
        those requests on that path rather than bypassing its audit. *)
     | Some tool_name when not (Tool_catalog.is_public_mcp tool_name) -> None
     | Some tool_name ->
       (match Tool_catalog.registered_metadata tool_name with
        | None -> None
        | Some metadata ->
          (match Auth_oauth.find_access_credential ~base_path ~token with
           | Error _ | Ok None -> None
           | Ok (Some credential) ->
             if Masc_domain.has_permission credential.role metadata.required_permission
                || not (allowed_tool tool_name)
             then None
             else scope_granting metadata.required_permission)))
;;
