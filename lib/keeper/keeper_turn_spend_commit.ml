type error =
  | Keeper_removed
  | Commit_rejected of Keeper_owner_registry.command_error

let error_to_string = function
  | Keeper_removed -> "Keeper Owner removed metadata during the turn commit"
  | Commit_rejected error -> Keeper_owner_registry.command_error_to_string error
;;

let count_turn (meta : Keeper_meta_contract.keeper_meta) =
  { meta with
    updated_at = Keeper_meta_contract.now_iso ()
  ; runtime =
      { meta.runtime with
        usage =
          { meta.runtime.usage with
            total_turns = meta.runtime.usage.total_turns + 1
          ; last_turn_ts = Time_compat.now ()
          }
      }
  }
;;

let commit ~config ~keeper_turn_id ~(before : Keeper_meta_contract.keeper_meta) ~attempt_spend
      after
  =
  let resolved, usage_cursor =
    Keeper_turn_spend.resolve
      ~cursor:before.runtime.usage_cursor
      ~observed_at:(Time_compat.now ())
      attempt_spend
  in
  let after = Keeper_unified_metrics.with_attempt_spend after ~resolved ~usage_cursor in
  match
    Keeper_owner_registry.commit_turn_runtime
      ~base_path:config.Workspace.base_path
      ~keeper_name:before.name
      ~before
      ~after
  with
  | Error error -> Error (Commit_rejected error)
  | Ok None -> Error Keeper_removed
  | Ok (Some committed) ->
    Keeper_turn_spend_ledger.write
      ~masc_root:(Common.masc_dir_from_base_path ~base_path:config.Workspace.base_path)
      ~agent_name:before.name
      ~task_id:(Option.map Keeper_id.Task_id.to_string before.current_task_id)
      ~trace_id:(Keeper_id.Trace_id.to_string before.runtime.trace_id)
      ~keeper_turn_id
      resolved;
    Ok committed
;;
