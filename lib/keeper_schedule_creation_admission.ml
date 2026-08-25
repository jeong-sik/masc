let run config ~keeper_name create =
  match
    Keeper_shutdown_intake_fence.run_durable_intake_if_open
      ~base_path:config.Workspace.base_path
      ~keeper_name
      (fun _intake_token -> create ())
  with
  | Keeper_shutdown_intake_fence.Intake_committed result -> result
  | Keeper_shutdown_intake_fence.Intake_shutdown_reserved operation_id ->
    Error
      (Schedule_service.Creation_rejected
         (Printf.sprintf
            "schedule creation rejected by Keeper shutdown fence keeper=%s operation=%s"
            keeper_name
            (Keeper_shutdown_types.Operation_id.to_string operation_id)))
;;
