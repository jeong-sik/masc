(* Who sits at the shared machine (RFC play-link-for-the-shared-machine §2.6,
   §2.8). *)

let keeper_names config =
  Result.map
    (fun persisted ->
      List.sort_uniq String.compare (persisted @ Keeper_meta_store.configured_keeper_names config))
    (Keeper_meta_store.keeper_names_result config)

let participants ~base_path ~keepers ~now =
  let seated (cred : Masc_domain.agent_credential) =
    match cred.role with
    | Masc_domain.Admin | Masc_domain.Player ->
      (match Play_invite.expired ~now cred with
       | Ok false -> Some cred.agent_name
       | Ok true -> None
       | Error (Masc_domain.Credential_expiry.Invalid_timestamp stamp) ->
         Log.Auth.warn "Play seat cannot read credential expiry for %s: %S" cred.agent_name stamp;
         None)
    | Masc_domain.Worker -> None
  in
  List.sort_uniq String.compare
    (keepers @ List.filter_map seated (Auth.list_credentials base_path))

let hand_to config ~now =
  Result.bind (keeper_names config) (fun keepers ->
    match participants ~base_path:config.Workspace.base_path ~keepers ~now with
    | names -> Ok names
    | exception Sys_error detail -> Error ("cannot list credentials: " ^ detail))
