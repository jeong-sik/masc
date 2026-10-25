open Agent_types

let _log = Log.create ~module_name:"agent_checkpoint_sink" ()

let persist_caller_owned agent stage ~pending_input state =
  match agent.checkpoint_sink with
  | None -> Ok ()
  | Some sink ->
    let checkpoint =
      Agent_checkpoint.build_checkpoint
        ~pending_input
        ~state
        ~tools:agent.tools
        ~context:agent.context
        ~mcp_clients:agent.options.mcp_clients
        ()
    in
    let timestamp = checkpoint.created_at in
    let turn = state.turn_count in
    let stage_label = checkpoint_stage_to_string stage in
    let snapshot = { stage; turn; checkpoint; timestamp } in
    (match sink snapshot with
     | Ok () ->
       (* Three checkpoint stages per turn are bookkeeping, not events an
          operator reads: at Info they were 493 of 9,119 lines in 41 minutes
          (2026-09-09), three lines under every turn summary. The sink
          failure below stays at Error. *)
       Log.debug
         _log
         "turn checkpoint persisted"
         [ S ("stage", stage_label)
         ; I ("turn", turn)
         ; I ("messages", List.length checkpoint.messages)
         ];
       Ok ()
     | Error detail ->
       Log.error
         _log
         "turn checkpoint sink failed"
         [ S ("stage", stage_label); I ("turn", turn); S ("detail", detail) ];
       Error
         (Error.Internal
            (Printf.sprintf "checkpoint sink failed at %s: %s" stage_label detail)))
;;

let persist_for_state agent stage ~pending_input state =
  match agent.checkpoint_sink with
  | Some _ -> persist_caller_owned agent stage ~pending_input state
  | None ->
    match Execution_context.agent_scope () with
    | None -> Ok ()
    | Some scope ->
      let open Result_syntax in
      let checkpoint=Agent_checkpoint.build_checkpoint ~pending_input ~state
          ~tools:agent.tools ~context:agent.context ~mcp_clients:agent.options.mcp_clients () in
      let* fact=Checkpoint_snapshot.create ~stage checkpoint
          |> Result.map_error (fun error -> Error.Internal (Checkpoint_snapshot.error_to_string error)) in
      Execution_agent_scope.record_checkpoint scope fact
      |> Result.map_error (fun error -> Error.Internal (Execution_agent_scope.error_to_string error))
;;
