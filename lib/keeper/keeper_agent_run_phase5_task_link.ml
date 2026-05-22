(** Keeper_agent_run_phase5_task_link.ml — Phase 5 task link.

    Extracted from [Keeper_agent_run.run_turn] Step 8 body (RFC-0147 PR-9). *)

let run ~config ~(meta : Keeper_types.keeper_meta)
      ~(acc : Keeper_run_tools.hook_accumulator) ()
  =
  match acc.meta.current_task_id with
  | None -> ()
  | Some task_id ->
    let task_id_str = Keeper_id.Task_id.to_string task_id in
    let trace_id_str = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    if
      Keeper_agent_run_turn_helpers.task_link_already_recorded
        ~keeper:meta.name
        ~task_id:task_id_str
        ~trace_id:trace_id_str
    then ()
    else (
      (* Pass trace_id as both session_id and operation_id to match
         the existing keeper_run_tools.ml convention (session_id
         fields elsewhere are populated from trace_id). *)
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
          (* link takes a backlog file lock; an OS-level lock
             contention or transient I/O hiccup can raise before
             the function gets a chance to return Error. Convert
             that into a normal Error so the warn path below logs
             it instead of unwinding the whole keeper turn. *)
          Error
            (Masc_domain.System
               (Masc_domain.System_error.IoError (Printexc.to_string exn)))
      in
      match result with
      | Ok _ ->
        Keeper_agent_run_turn_helpers.mark_task_link
          ~keeper:meta.name
          ~task_id:task_id_str
          ~trace_id:trace_id_str
      | Error err ->
        Log.Keeper.warn
          "keeper:%s link_task_execution_artifacts failed for task=%s: %s"
          meta.name
          task_id_str
          (Masc_domain.masc_error_to_string err))
;;
