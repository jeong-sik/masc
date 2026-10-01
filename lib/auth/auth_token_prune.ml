type reason = Expired | Orphaned_redirect
type mode = Preview | Retire
type outcome = Would_retire | Retired | Failed of Masc_domain.masc_error
type entry = { agent_name : string; reason : reason; outcome : outcome }

let run_admitted ~after_snapshot ~base_path ~now ~mode =
  Auth_credential_base.with_credential_transaction base_path (fun transaction ->
    let ( let* ) = Result.bind in
    let* snapshot = Auth_credential_base.credential_prune_snapshot_in_transaction transaction in
    let expired = snapshot.credentials
        |> List.filter (fun (credential, _) ->
          Auth_token_inventory.is_expired (Auth_token_inventory.classify ~now credential))
        |> List.map (fun (_, retirement) -> retirement, Expired) in
    let orphaned = List.map (fun retirement -> retirement, Orphaned_redirect) snapshot.orphaned_redirects in
    let retire ((retirement : Auth_credential_base.credential_prune_retirement), reason) =
      let outcome = match mode with
        | Preview -> Would_retire
        | Retire ->
          (match Auth_credential_base.retire_prune_credential_in_transaction transaction retirement with
           | Ok () -> Retired
           | Error error -> Failed error) in
      { agent_name = retirement.retiring_agent_name; reason; outcome }
    in
    after_snapshot ();
    Ok (List.map retire (expired @ orphaned)))
  |> Result.join


let run ~base_path ~now ~mode =
  match mode with
  | Retire -> run_admitted ~after_snapshot:(fun () -> ()) ~base_path ~now ~mode
  | Preview ->
      (* A nonexistent store has nothing to classify. Do not create either
         its directories or its admission file just to report an empty plan. *)
      (match Auth_credential_base.credential_path_exists
               (Auth_credential_base.agents_dir base_path) with
       | Error _ as error -> error
       | Ok false -> Ok []
       | Ok true -> run_admitted ~after_snapshot:(fun () -> ()) ~base_path ~now ~mode)

module For_testing = struct
  let run_after_snapshot ~base_path ~now ~after_snapshot =
    run_admitted ~after_snapshot ~base_path ~now ~mode:Retire
end
