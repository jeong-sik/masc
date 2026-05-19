(** See [server_dashboard_shell_snapshot.mli] for the contract. *)

let select_shell_json
      ?clock ?request ?timing ?(light = false) (config : Coord.config)
  : Yojson.Safe.t
  =
  let timing_obj =
    match timing with
    | Some t -> t
    | None -> Server_timing.create ()
  in
  if light
  then
    Server_dashboard_http_core.dashboard_shell_http_json
      ?clock ?request ~timing:timing_obj ~light config
  else (
    match Dashboard_snapshot.current () with
    | Some snap ->
      Server_timing.measure
        timing_obj
        (Server_timing.Custom "snapshot_read")
        (fun () -> snap.shell)
    | None ->
      Server_dashboard_http_core.dashboard_shell_http_json
        ?clock ?request ~timing:timing_obj ~light config)
;;
