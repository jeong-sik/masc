let link_if_needed ~config ~keeper_name ~task_id ~trace_id =
  match task_id with
  | None -> ()
  | Some task_id ->
    let task_id_str = Keeper_id.Task_id.to_string task_id in
    let trace_id_str = Keeper_id.Trace_id.to_string trace_id in
    if
      Keeper_agent_run_turn_helpers.task_link_already_recorded
        ~keeper:keeper_name
        ~task_id:task_id_str
        ~trace_id:trace_id_str
    then ()
    else (
      let session_id = Some trace_id_str in
      let operation_id = Some trace_id_str in
      let result =
        try
          Coord.link_task_execution_artifacts_r
            config
            ~task_id:task_id_str
            ?session_id
            ?operation_id
            ()
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Error
            (Masc_domain.System
               (Masc_domain.System_error.IoError (Printexc.to_string exn)))
      in
      match result with
      | Ok _ ->
        Keeper_agent_run_turn_helpers.mark_task_link
          ~keeper:keeper_name
          ~task_id:task_id_str
          ~trace_id:trace_id_str
      | Error err ->
        Log.Keeper.warn
          "keeper:%s link_task_execution_artifacts failed for task=%s: %s"
          keeper_name
          task_id_str
          (Masc_domain.masc_error_to_string err))
;;
