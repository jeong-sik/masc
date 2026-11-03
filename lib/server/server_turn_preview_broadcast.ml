(* RFC-0481 §7 decision 2 recommends a quarter second: the answering badge
   shows whole seconds and one status line. *)
let post_interval_s = 0.25

let announce ~base_path ~keeper_name =
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        [ "type", `String Keeper_turn_preview_signal.changed_event
        ; "name", `String keeper_name
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", keeper_name; "site", Keeper_turn_preview_signal.changed_event ]
      ();
    Log.Server.warn
      "turn preview broadcast: %s name=%s failed: %s"
      Keeper_turn_preview_signal.changed_event
      keeper_name
      (Printexc.to_string exn)
;;

let install ~sw ~clock =
  let wake = Eio.Stream.create 1 in
  let recorded_mu = Stdlib.Mutex.create () in
  let recorded : (string * string, unit) Hashtbl.t = Hashtbl.create 16 in
  Keeper_turn_preview_signal.install (fun ~base_path ~keeper_name ->
    Stdlib.Mutex.protect recorded_mu (fun () ->
      Hashtbl.replace recorded (base_path, keeper_name) ();
      if Eio.Stream.is_empty wake then Eio.Stream.add wake ()));
  let take_recorded () =
    Stdlib.Mutex.protect recorded_mu (fun () ->
      let keepers = Hashtbl.fold (fun keeper () taken -> keeper :: taken) recorded [] in
      Hashtbl.reset recorded;
      keepers)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec send_after_each_wake () =
      Eio.Stream.take wake;
      List.iter
        (fun (base_path, keeper_name) -> announce ~base_path ~keeper_name)
        (take_recorded ());
      Eio.Time.sleep clock post_interval_s;
      send_after_each_wake ()
    in
    send_after_each_wake ())
;;
