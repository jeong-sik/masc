type source = Chat_operation | Event_queue | Approval_count | Approval_detail

let health_change_observer : (base_path:string -> unit) Atomic.t =
  Atomic.make (fun ~base_path:_ -> ())

let install_health_change_observer observer =
  Atomic.set health_change_observer observer
;;

let source_to_string = function
  | Chat_operation -> "chat_operation"
  | Event_queue -> "event_queue"
  | Approval_count -> "approval_count"
  | Approval_detail -> "approval_detail"
;;

let notify_health_change ~base_path =
  let report exn =
    Log.Keeper.warn "waiting inventory health observer failed: %s"
      (Printexc.to_string exn) in
  match (Atomic.get health_change_observer) ~base_path with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    (match Fs_compat.execution_context () with
     | Eio_fiber -> Eio.Fiber.check ()
     | Non_eio -> ());
    report exn
  | exception exn -> report exn
;;

let changed ~base_path ~keeper_name ~source =
  (match source with
   | Approval_count -> notify_health_change ~base_path
   | Chat_operation | Event_queue | Approval_detail -> ());
  try
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        [ "type", `String "keeper_waiting_inventory_changed"
        ; "keeper_name", `String keeper_name
        ; "queue_kind", `String (source_to_string source)
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", keeper_name; "site", "waiting_inventory_changed" ]
      ();
    Log.Keeper.warn
      "keeper_waiting_inventory_broadcast: changed name=%s failed: %s"
      keeper_name
      (Printexc.to_string exn)
;;
