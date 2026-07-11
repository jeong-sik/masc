let records_dir (config : Workspace.config) =
  Filename.concat (Workspace.keepers_runtime_dir config) ".shutdown-continuations"
;;

let path ~config (record : Keeper_shutdown_types.interrupted_turn) =
  let filename =
    Printf.sprintf
      "%s-%s-turn-%d.json"
      record.keeper_name
      (Keeper_id.Trace_id.to_string record.trace_id)
      record.turn_id
  in
  Filename.concat (records_dir config) filename
;;

let outcome_to_json = function
  | Keeper_shutdown_types.Continuation_required ->
    `Assoc [ "kind", `String "continuation_required" ]
  | Keeper_shutdown_types.Ambiguous_result
      { committed_mutating_tools; event_bus_integrity_error } ->
    `Assoc
      [ "kind", `String "ambiguous_result"
      ; ( "committed_mutating_tools"
        , `List (List.map (fun name -> `String name) committed_mutating_tools) )
      ; ( "event_bus_integrity_error"
        , match event_bus_integrity_error with
          | Some error -> `String error
          | None -> `Null )
      ]
;;

let to_json (record : Keeper_shutdown_types.interrupted_turn) =
  `Assoc
    [ "schema_version", `Int 1
    ; "keeper_name", `String record.keeper_name
    ; "trace_id", `String (Keeper_id.Trace_id.to_string record.trace_id)
    ; "turn_id", `Int record.turn_id
    ; ( "current_task_id"
      , match record.current_task_id with
        | Some task_id -> `String (Keeper_id.Task_id.to_string task_id)
        | None -> `Null )
    ; "interrupted_at", `Float record.interrupted_at
    ; "outcome", outcome_to_json record.outcome
    ]
;;

let persist ~config record =
  let record_path = path ~config record in
  Keeper_fs.save_json_atomic record_path (to_json record)
  |> Result.map (fun () ->
       Keeper_shutdown_types.persisted_interrupted_turn
         ~record
         ~path:record_path)
  |> Result.map_error (fun error ->
       Printf.sprintf
         "failed to persist Keeper shutdown continuation %s: %s"
         record_path
         error)
;;
