(* Who sits at the shared machine (RFC play-link-for-the-shared-machine §2.6,
   §2.8). *)

let keeper_names config =
  Result.map
    (fun persisted ->
      List.sort_uniq String.compare (persisted @ Keeper_meta_store.configured_keeper_names config))
    (Keeper_meta_store.keeper_names_result config)

let participant_names ~keepers ~now credentials =
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
  List.sort_uniq String.compare (keepers @ List.filter_map seated credentials)

let participants ~base_path ~keepers ~now =
  Auth.list_current_credentials base_path |> Result.map (participant_names ~keepers ~now)

let hand_to config ~now =
  Result.bind (keeper_names config) (fun keepers ->
    participants ~base_path:config.Workspace.base_path ~keepers ~now
    |> Result.map_error (fun error -> "cannot list credentials: " ^ Masc_domain.masc_error_to_string error))

let hand_to_in_transaction ~transaction config ~now =
  Result.bind (keeper_names config) (fun keepers ->
    Auth.list_current_credentials_in_transaction transaction
    |> Result.map (participant_names ~keepers ~now)
    |> Result.map_error (fun error -> "cannot list credentials: " ^ Masc_domain.masc_error_to_string error))
