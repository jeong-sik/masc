(* Server_runtime_startup_credentials — credential sync at server startup.
   Extracted from server_runtime_bootstrap.ml during godfile decomposition.
   Contains admin/internal token sync, bootable keeper credential sync,
   and shared token rotation. *)

let sync_admin_token_env ?(export_env = true) (state : Mcp_server.server_state) =
  let base_path = (Mcp_server.workspace_config state).base_path in
  let open Result.Syntax in
  let* raw_token, credential, source =
    Auth.prepare_startup_admin_token base_path
      ~raw_token:(Env_config_core.admin_token_opt ()) in
  if export_env then Unix.putenv Env_config_core.admin_token_env_key raw_token;
  let source = match source with
    | Auth.Stored_admin_token -> "stored"
    | Auth.Minted_admin_token -> "minted"
    | Auth.Supplied_admin_token -> "supplied" in
  Log.Server.info "startup Admin credential ready for %s (source=%s)"
    credential.agent_name source;
  Ok ()

(* [Auth.ensure_internal_keeper_token] keeps an inherited token and (when
   [export_env] is true) exports a generated one under the same name, so in
   single-user mode the variable is set once it returns; in multi-account mode
   it stays in memory and auth hash storage without leaking to child CLI
   processes. *)
let sync_internal_keeper_token_env ?(export_env = true) (state : Mcp_server.server_state) =
  let base_path = (Mcp_server.workspace_config state).base_path in
  let env_key = Auth.internal_keeper_token_env_key in
  let inherited =
    match Sys.getenv_opt env_key with
    | Some raw -> String.trim raw <> ""
    | None -> false
  in
  let (_ : string) = Auth.ensure_internal_keeper_token ~export_env base_path in
  let source = if inherited then "inherited" else "generated" in
  Log.Server.info
    "startup internal keeper MCP token synced via %s (source=%s)" env_key source;
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_startup_internal_keeper_token_sync
    ~labels:[("source", source)]
    ~delta:1.0
    ()

let sync_bootable_keeper_credentials ?(export_env = true) (state : Mcp_server.server_state) =
  let base_path = (Mcp_server.workspace_config state).base_path in
  let keeper_names =
    Keeper_runtime.bootable_keeper_names (Mcp_server.workspace_config state)
  in
  let excluded_keepers =
    Keeper_runtime.autoboot_excluded_keeper_reasons (Mcp_server.workspace_config state)
  in
  let synced_count, failed =
    List.fold_left
      (fun (synced_count, failed) (keeper_name, result) ->
        match result with
        | Ok _ -> (synced_count + 1, failed)
        | Error err ->
            ( synced_count,
              (keeper_name, Masc_domain.masc_error_to_string err) :: failed ))
      (0, [])
      (match Auth.ensure_keeper_credentials ~export_env base_path ~agent_names:keeper_names with
       | Ok results -> results
       | Error error -> List.map (fun name -> name, Error error) keeper_names)
  in
  if synced_count > 0 then
    Log.Server.info
      "startup verified %d bootable keeper credential(s)"
      synced_count;
  if excluded_keepers <> [] then (
    let rendered =
      excluded_keepers
      |> List.map (fun Keeper_runtime.{ keeper_name; reason } ->
        Printf.sprintf
          "%s=%s"
          keeper_name
          (Keeper_runtime.autoboot_exclusion_reason_to_string reason))
      |> String.concat ", "
    in
    Log.Server.info
      "startup skipped credential sync for %d non-bootable keeper(s): [%s]"
      (List.length excluded_keepers)
      rendered);
  List.rev failed
  |> List.iter (fun (keeper_name, detail) ->
         Log.Server.error
           "startup keeper credential sync failed for %s: %s"
           keeper_name detail);
  (* A keeper's credential lives under its keeper_name — the
     decorated agent alias and the #10440 short-form alias mirror it
     required are gone. *)
  match Auth.rotate_shared_tokens_for_agents base_path ~agent_names:keeper_names with
  | Error error ->
    Log.Server.error "#10304 shared keeper token rotation was not admitted or discovery failed: %s"
      (Masc_domain.masc_error_to_string error)
  | Ok rotation_outcomes ->
  List.iter
    (fun (outcome : Auth.rotation_outcome) ->
      let successes, failures =
        List.fold_left
          (fun (ok, failed) (agent_name, result) ->
             match result with
             | Ok () -> (agent_name :: ok, failed)
             | Error err ->
                 ( ok,
                   (agent_name, Auth.rotation_failure_to_string err) :: failed ))
          ([], []) outcome.rotated_agents
      in
      let success_count = List.length successes in
      if success_count > 0 then begin
        Otel_metric_store.inc_counter
          Otel_metric_store.metric_auth_credential_token_rotated
          ~labels:[
            ("token_hash_prefix", outcome.token_hash_prefix);
            ("scope", "bootable_keepers");
          ]
          ~delta:(float_of_int success_count)
          ();
        Log.Server.warn
          "#10304 rotated %d bootable keeper credential(s) out of shared \
           token group %s: [%s]"
          success_count outcome.token_hash_prefix
          (String.concat ", " (List.rev successes))
      end;
      List.rev failures
      |> List.iter (fun (agent_name, detail) ->
             Log.Server.error
               "#10304 failed to rotate shared keeper credential for %s \
                (token_hash_prefix=%s): %s"
               agent_name outcome.token_hash_prefix detail))
    rotation_outcomes
