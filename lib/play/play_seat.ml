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

let connected_credentials ~transaction ~base_path credentials =
  let ( let* ) = Result.bind in
  let rec collect found departed = function
    | [] -> Ok (List.rev found, departed)
    | credential :: rest ->
        let* participation = Play_participation.read ~transaction ~base_path credential
          |> Result.map_error (fun detail -> Masc_domain.System (Masc_domain.System_error.IoError detail)) in
        (match participation with
         | Connected -> collect (credential :: found) departed rest
         | Departed -> collect found (credential.agent_name :: departed) rest) in
  collect [] [] credentials

let participants_in_transaction ~transaction ~base_path ~keepers ~now =
  let ( let* ) = Result.bind in
  let* credentials = Auth.list_current_credentials_in_transaction transaction in
  let* credentials, departed = connected_credentials ~transaction ~base_path credentials in
  let keepers = List.filter (fun name -> not (List.mem name departed)) keepers in
  Ok (participant_names ~keepers ~now credentials)

let participants ~base_path ~keepers ~now =
  Auth.with_credential_transaction base_path (fun transaction ->
    participants_in_transaction ~transaction ~base_path ~keepers ~now) |> Result.join

let hand_to config ~now =
  Result.bind (keeper_names config) (fun keepers ->
    participants ~base_path:config.Workspace.base_path ~keepers ~now
    |> Result.map_error (fun error -> "cannot list credentials: " ^ Masc_domain.masc_error_to_string error))

let hand_to_in_transaction ~transaction config ~now =
  Result.bind (keeper_names config) (fun keepers ->
    participants_in_transaction ~transaction ~base_path:config.Workspace.base_path ~keepers ~now
    |> Result.map_error (fun error -> "cannot list credentials: " ^ Masc_domain.masc_error_to_string error))
