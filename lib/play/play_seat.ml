(* Who sits at the shared machine (RFC play-link-for-the-shared-machine §2.6,
   §2.8). *)

let keeper_names config =
  Result.map
    (fun persisted ->
      List.sort_uniq String.compare (persisted @ Keeper_meta_store.configured_keeper_names config))
    (Keeper_meta_store.keeper_names_result config)

let participants ~base_path ~keepers ~now =
  let now_iso = Masc_domain.iso8601_of_unix_seconds now in
  let seated (cred : Masc_domain.agent_credential) =
    match cred.role with
    | Masc_domain.Admin -> Some cred.agent_name
    | Masc_domain.Player ->
      (match cred.expires_at with
       | Some expires_at when String.compare now_iso expires_at > 0 -> None
       | Some _ | None -> Some cred.agent_name)
    | Masc_domain.Worker -> None
  in
  List.sort_uniq String.compare
    (keepers @ List.filter_map seated (Auth.list_credentials base_path))
