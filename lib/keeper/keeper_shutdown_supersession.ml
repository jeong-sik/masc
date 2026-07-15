type t =
  | No_shutdown_admission_token
  | Operator_metadata_update_token of
      Keeper_shutdown_store.operator_metadata_supersession_token

type committed =
  | No_shutdown_admission
  | Shutdown_superseded of Keeper_shutdown_types.t

type error =
  | Preflight_failed of Keeper_shutdown_store.error
  | Multiple_durable_shutdown_operations of
      Keeper_shutdown_types.Operation_id.t list
  | Metadata_committed_supersession_failed of Keeper_shutdown_store.error
  | Metadata_committed_admission_owned_by_other of
      Keeper_shutdown_types.Operation_id.t

let error_to_string = function
  | Preflight_failed error ->
    Printf.sprintf
      "keeper update refused before metadata commit: %s"
      (Keeper_shutdown_store.error_to_string error)
  | Multiple_durable_shutdown_operations operation_ids ->
    Printf.sprintf
      "keeper update refused before metadata commit: multiple durable shutdown operations require admission: %s"
      (operation_ids
       |> List.map Keeper_shutdown_types.Operation_id.to_string
       |> String.concat ",")
  | Metadata_committed_supersession_failed error ->
    Printf.sprintf
      "keeper metadata was updated, but blocked shutdown supersession failed; retry the explicit keeper update: %s"
      (Keeper_shutdown_store.error_to_string error)
  | Metadata_committed_admission_owned_by_other operation_id ->
    Printf.sprintf
      "keeper metadata was updated and the old shutdown was superseded, but a newer shutdown operation owns admission; retry only after resolving operation %s"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
;;

let preflight ~config ~keeper_name ~actor =
  let snapshot =
    Keeper_turn_admission.snapshot_for
      ~base_path:config.Workspace.base_path
      ~keeper_name
  in
  match snapshot.snapshot_shutdown_operation_id with
  | Some operation_id ->
    Keeper_shutdown_store.prepare_operator_metadata_supersession
      ~config
      ~keeper_name
      ~operation_id
      ~actor
    |> Result.map (fun token -> Operator_metadata_update_token token)
    |> Result.map_error (fun error -> Preflight_failed error)
  | None ->
    (match Keeper_shutdown_store.list_for_keeper ~config ~keeper_name with
     | Error error -> Error (Preflight_failed error)
     | Ok operations ->
       let requiring_fence =
         List.filter
           Keeper_shutdown_types.requires_admission_fence
           operations
       in
       (match requiring_fence with
        | [] -> Ok No_shutdown_admission_token
        | [ operation ] ->
          Keeper_shutdown_store.prepare_operator_metadata_supersession
            ~config
            ~keeper_name
            ~operation_id:operation.operation_id
            ~actor
          |> Result.map (fun token -> Operator_metadata_update_token token)
          |> Result.map_error (fun error -> Preflight_failed error)
        | operations ->
          Error
            (Multiple_durable_shutdown_operations
               (List.map
                  (fun operation -> operation.Keeper_shutdown_types.operation_id)
                  operations))))
;;

let commit_after_metadata_update ~config = function
  | No_shutdown_admission_token -> Ok No_shutdown_admission
  | Operator_metadata_update_token token ->
    (match
       Keeper_shutdown_store.supersede_blocked_operator_stop
         ~config
         ~token
         ~now:Masc_domain.now_iso
     with
     | Error error -> Error (Metadata_committed_supersession_failed error)
     | Ok
         ( Keeper_shutdown_store.Superseded_persisted operation
         | Keeper_shutdown_store.Superseded_already_persisted operation ) ->
       let operation_id =
         Keeper_shutdown_store.supersession_token_operation_id token
       in
       (match
          Keeper_turn_admission.rollback_shutdown
            ~base_path:config.Workspace.base_path
            ~keeper_name:operation.keeper_name
            ~operation_id
        with
        | Keeper_turn_admission.Shutdown_rolled_back
        | Keeper_turn_admission.Shutdown_not_reserved ->
          Ok (Shutdown_superseded operation)
        | Keeper_turn_admission.Shutdown_reserved_by_other existing ->
          Error (Metadata_committed_admission_owned_by_other existing)))
;;
