type source =
  | Keeper_turns
  | Standalone_lanes
  | Connectors
  | Keeper_schedule

let source_name = function
  | Keeper_turns -> "keeper turns"
  | Standalone_lanes -> "standalone lanes"
  | Connectors -> "connector"
  | Keeper_schedule -> "keeper schedule"

let attribute source result =
  Result.map_error
    (fun detail -> source_name source ^ " load failed: " ^ detail)
    result

let launch_with ?on_not_run ~boundary_error ~deliver read =
  let not_run cause =
    Option.iter (fun release -> release ()) on_not_run;
    deliver (Error (boundary_error cause))
  in
  match Eio_context.get_switch_opt () with
  | None -> not_run "Eio switch is unavailable"
  | Some sw ->
      Masc_tui_fork_guard.launch ~sw ~on_sync_failure:not_run (fun () ->
          let result =
            try read () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn -> Error (boundary_error (Printexc.to_string exn))
          in
          deliver result;
          `Stop_daemon)

let launch ?source ?on_not_run ~deliver read =
  let deliver result =
    match source with
    | None -> deliver result
    | Some source -> deliver (attribute source result)
  in
  launch_with ?on_not_run ~boundary_error:Fun.id ~deliver read
