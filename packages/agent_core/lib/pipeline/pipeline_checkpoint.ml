open Agent_types

let _log = Log.create ~module_name:"pipeline_checkpoint" ()

let persist_for_state agent stage state =
  match agent.checkpoint_sink with
  | None -> Ok ()
  | Some sink ->
    let checkpoint =
      Agent_checkpoint.build_checkpoint
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
       (match agent.options.journal with
        | Some journal ->
          Agent_execution_event_writer.append
            journal
            (Checkpoint_saved
               { checkpoint_id = Printf.sprintf "%s-%d" stage_label turn; timestamp })
        | None -> ());
       Log.info
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
