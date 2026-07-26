type publication =
  | Allocated of Keeper_lifecycle_nonce.replace Keeper_lifecycle_nonce.witness
  | Recovered of
      Keeper_lifecycle_nonce.recover_exact Keeper_lifecycle_nonce.witness

let ( let* ) result fn = match result with Ok value -> fn value | Error error -> Error error

let replace_or_recover_exact
      (permit : Keeper_lifecycle_admission.Durable_transaction.permit)
      ~(config : Workspace.config)
      (meta : Keeper_meta_contract.keeper_meta)
      ~expected_agent_name
  =
  if
    not
      (Keeper_lifecycle_admission.Durable_transaction.permit_matches
         permit
         ~base_path:config.Workspace.base_path
         meta.name)
  then Error "keeper identity transition lost durable lifecycle admission"
  else
  let previous_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let* source =
    Keeper_lifecycle_nonce.identity
      ~owner_id:previous_trace_id
      ~nonce:(Int64.of_int meta.runtime.nonce)
    |> Result.map_error Keeper_lifecycle_nonce.error_to_string
  in
  let new_trace_id_raw = Keeper_identity.generate_trace_id () in
  let publication =
    match
      Keeper_lifecycle_nonce.replace_settled
        permit
        ~base_path:config.base_path
        ~keeper_id:meta.name
        ~source
        ~owner_id:new_trace_id_raw
        ()
    with
    | Ok (Keeper_lifecycle_nonce.Settled_allocated witness) ->
      Ok (Allocated witness)
    | Ok (Keeper_lifecycle_nonce.Settled_recovered (witness, attention)) ->
      Option.iter
        (fun error ->
          Log.Keeper.warn
            "keeper identity replacement settled published authority \
             keeper=%s attention=%s"
            meta.name
            (Keeper_lifecycle_nonce.error_to_string error))
        attention;
      Ok (Recovered witness)
    | Error error -> Error error
  in
  let* publication =
    publication |> Result.map_error Keeper_lifecycle_nonce.error_to_string
  in
  let target =
    match publication with
    | Allocated witness -> Keeper_lifecycle_nonce.witness_target witness
    | Recovered witness -> Keeper_lifecycle_nonce.witness_target witness
  in
  let target_trace_id_raw = Keeper_lifecycle_nonce.identity_owner_id target in
  let* target_trace_id =
    Keeper_id.Trace_id.of_string target_trace_id_raw
    |> Result.map_error (fun detail ->
      Printf.sprintf
        "lifecycle nonce authority contains invalid trace identity for %s: %s"
        meta.name
        detail)
  in
  let* nonce =
    Keeper_lifecycle_nonce.runtime_int_of_nonce
      (Keeper_lifecycle_nonce.identity_nonce target)
    |> Result.map_error Keeper_lifecycle_nonce.error_to_string
  in
  let updated =
    { meta with
      agent_name = expected_agent_name
    ; updated_at = Keeper_meta_contract.now_iso ()
    ; runtime =
        { meta.runtime with
          trace_id = target_trace_id
        ; trace_history =
            Json_util.dedupe_keep_order
              (previous_trace_id :: meta.runtime.trace_history)
        ; nonce
        }
    }
  in
  let base_dir = Keeper_types_profile.session_base_dir config in
  let _session =
    Keeper_context_runtime.create_session
      ~session_id:target_trace_id_raw
      ~base_dir
  in
  let* () =
    match publication with
    | Allocated witness ->
      Keeper_meta_store.replace_meta
        permit
        witness
        config
        updated
    | Recovered witness ->
      Keeper_meta_store.recover_meta_exact
        permit
        witness
        config
        updated
  in
  Ok updated
;;
