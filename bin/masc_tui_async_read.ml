type source =
  | Keeper_turns
  | Standalone_lanes
  | Connectors
  | Keeper_schedule
  | Resource_read

let source_prefix = function
  | Keeper_turns -> "keeper turns load failed: "
  | Standalone_lanes -> "standalone lanes load failed: "
  | Connectors -> "connector load failed: "
  | Keeper_schedule -> "keeper schedule load failed: "
  | Resource_read -> "resource read: "

let attribute source result =
  Result.map_error
    (fun detail -> source_prefix source ^ detail)
    result

let launch ?source ?on_not_run ~deliver read =
  let deliver result =
    match source with
    | None -> deliver result
    | Some source -> deliver (attribute source result)
  in
  let not_run cause =
    Option.iter (fun release -> release ()) on_not_run;
    deliver (Error cause)
  in
  match Eio_context.get_switch_opt () with
  | None -> not_run "Eio switch is unavailable"
  | Some sw ->
      Masc_tui_fork_guard.launch ~sw ~on_sync_failure:not_run (fun () ->
          let result =
            try read () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn -> Error (Printexc.to_string exn)
          in
          deliver result;
          `Stop_daemon)
