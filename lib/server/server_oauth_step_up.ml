(* HIGH-RISK-UNREVIEWED: OAuth scope challenge on the MCP request path. *)

let tools_call_name body =
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "method" fields, List.assoc_opt "params" fields with
     | Some (`String "tools/call"), Some (`Assoc params) ->
       (match List.assoc_opt "name" params with
        | Some (`String name) -> Some name
        | Some _ | None -> None)
     | (Some _ | None), (Some _ | None) -> None)
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

let required_scope ~base_path ~auth_token ~body =
  match auth_token with
  | None -> None
  | Some token ->
    (match tools_call_name body with
     | None -> None
     | Some tool_name ->
       (match Tool_catalog.registered_metadata tool_name with
        | None -> None
        | Some metadata ->
          (match Auth_oauth.find_access_credential ~base_path ~token with
           | Error _ | Ok None -> None
           | Ok (Some credential) ->
             if Masc_domain.has_permission credential.role metadata.required_permission
             then None
             else scope_granting metadata.required_permission)))
;;
