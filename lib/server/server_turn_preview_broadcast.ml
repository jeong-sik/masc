(* A quarter second between posts: the answering badge shows whole seconds
   and one status line. *)
let post_interval_s = 0.25

let observation ~base_path ~keeper_name =
  let ( let* ) = Option.bind in
  let* owner =
    Result.to_option (Keeper_owner_registry.get ~base_path ~keeper_name)
  in
  let* turn = Keeper_owner.turn_in_flight owner in
  let* preview =
    Keeper_turn_preview.current_for_turn
      ~keeper_name ~interrupt_token:turn.interrupt_token
  in
  let owner_key =
    Sse_wire.keeper_turn_observation_key
      ~interrupt_token:(Keeper_interrupt_token.to_string turn.interrupt_token)
  in
  let* current = Keeper_owner.turn_in_flight owner in
  if not (Keeper_interrupt_token.equal current.interrupt_token turn.interrupt_token)
  then None
  else
    Some
      (`Assoc
         [ "owner_key", `String owner_key
         ; "preview", Keeper_turn_preview.to_json preview
         ])
;;

let announce ~base_path ~keeper_name =
  match
    observation ~base_path ~keeper_name
    |> Option.iter (fun observation ->
      let authority = Sse.runtime_authority_exn ~base_path in
      Sse.broadcast_to (Sse.Runtime_observers authority)
        (`Assoc
           [ "type", `String Keeper_turn_preview_signal.changed_event
           ; "name", `String keeper_name
           ; "ts_unix", `Float (Time_compat.now ())
           ; "observation", observation
           ]))
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
