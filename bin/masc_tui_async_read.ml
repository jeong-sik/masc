type source =
  | Keeper_turns
  | Standalone_lanes
  | Connectors

let source_name = function
  | Keeper_turns -> "keeper turns"
  | Standalone_lanes -> "standalone lanes"
  | Connectors -> "connector"

let attribute source result =
  Result.map_error
    (fun detail -> source_name source ^ " load failed: " ^ detail)
    result

let launch ~source ~switch ~on_sync_failure ~deliver ~read () =
  let deliver result = deliver (attribute source result) in
  let failed_before_read detail =
    on_sync_failure ();
    deliver (Error detail)
  in
  let run () =
    let result =
      try read () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    deliver result
  in
  match switch with
  | None -> failed_before_read "Eio switch is unavailable"
  | Some sw ->
    Masc_tui_fork_guard.launch ~sw ~on_sync_failure:failed_before_read
      (fun () ->
        run ();
        `Stop_daemon)
