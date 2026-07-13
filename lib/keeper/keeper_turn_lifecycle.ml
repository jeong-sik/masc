(** Keeper lifecycle tools submit durable, non-blocking shutdown operations. *)

open Tool_args
open Keeper_types_profile

type tool_result = Keeper_types_profile.tool_result

let register_remove_pending_confirms_by_target =
  Keeper_shutdown_finalize.register_remove_pending_confirms_by_target
;;

let operation_json ~accepted operation =
  match Keeper_shutdown_store.to_json operation with
  | `Assoc fields ->
    `Assoc (("accepted", `Bool accepted) :: fields)
  | json -> json
;;

let active_operation ~config keeper_name =
  match Keeper_shutdown_store.list_for_keeper ~config ~keeper_name with
  | Error error -> Error (Keeper_shutdown_store.error_to_string error)
  | Ok operations ->
    let active =
      List.filter
        (fun operation ->
           match operation.Keeper_shutdown_types.phase with
           | Keeper_shutdown_types.Finalized _ -> false
           | Keeper_shutdown_types.Prepared
           | Keeper_shutdown_types.Joined_idle
           | Keeper_shutdown_types.Finalizing_tasks _
           | Keeper_shutdown_types.Cleanup_ready _
           | Keeper_shutdown_types.Reconciliation_required _
           | Keeper_shutdown_types.Blocked _ -> true)
        operations
    in
    (match active with
     | [] -> Ok None
     | [ operation ] -> Ok (Some operation)
     | _ -> Error "multiple non-terminal shutdown operations exist for one Keeper")
;;

let handle_keeper_down (ctx : _ context) args : tool_result =
  let requested_name = String.trim (get_string args "name" "") in
  if not (validate_name requested_name)
  then
    tool_result_error (invalid_name_error requested_name)
  else
    match Keeper_registry.get ~base_path:ctx.config.base_path requested_name with
    | None ->
      (match active_operation ~config:ctx.config requested_name with
       | Error detail ->
         Log.Keeper.error
           "Keeper shutdown inventory failed: keeper=%s error=%s"
           requested_name
           detail;
         tool_result_error detail
       | Ok (Some operation) ->
         Log.Keeper.info
           "Keeper shutdown operation observed: keeper=%s operation=%s"
           requested_name
           (Keeper_shutdown_types.Operation_id.to_string operation.operation_id);
         tool_result_ok_data (operation_json ~accepted:false operation)
       | Ok None ->
         (match Keeper_meta_store.read_meta_resolved ctx.config requested_name with
          | Error detail -> tool_result_error detail
          | Ok None ->
            Log.Keeper.info "Keeper shutdown found already absent: keeper=%s" requested_name;
            tool_result_ok_data
              (`Assoc
                 [ "name", `String requested_name
                 ; "already_absent", `Bool true
                 ])
          | Ok (Some _) ->
            Log.Keeper.error
              "Keeper shutdown refused metadata-only identity: keeper=%s"
              requested_name;
            tool_result_error
              "Keeper metadata exists without a live lane; refusing untracked cleanup"))
    | Some entry ->
      let request : Keeper_shutdown_prepare_join.request =
        { actor = ctx.agent_name
        ; cleanup_intent =
            { reason =
                (if get_bool args "remove_meta" false
                 then Keeper_shutdown_types.Operator_stop_remove_meta
                 else Keeper_shutdown_types.Operator_stop_retain_meta)
            ; remove_session = get_bool args "remove_session" false
            }
        }
      in
      (match
         Keeper_shutdown_runtime.submit
           ~config:ctx.config
           ~entry
           ~request
       with
       | Error error ->
         Log.Keeper.error
           "Keeper shutdown submission failed: keeper=%s error=%s"
           requested_name
           (Keeper_shutdown_runtime.submit_error_to_string error);
         tool_result_error (Keeper_shutdown_runtime.submit_error_to_string error)
       | Ok operation ->
         Log.Keeper.info
           "Keeper shutdown operation accepted: keeper=%s operation=%s"
           requested_name
           (Keeper_shutdown_types.Operation_id.to_string operation.operation_id);
         tool_result_ok_data (operation_json ~accepted:true operation))
;;

module For_testing = struct
  let remove_pending_confirms_by_target =
    Keeper_shutdown_finalize.For_testing.remove_pending_confirms_by_target
  ;;

  let reset_remove_pending_confirms_by_target =
    Keeper_shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target
  ;;
end
