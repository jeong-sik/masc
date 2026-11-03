let row_changed_event = "keeper_row_changed"
let roster_changed_event = "keeper_roster_changed"

let announce ~base_path ~event ~label fields =
  let report exn =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", label; "site", event ]
      ();
    Log.Keeper.warn
      "keeper_row_broadcast: %s keeper=%s failed: %s"
      event
      label
      (Printexc.to_string exn)
  in
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        (("type", `String event) :: fields
         @ [ "ts_unix", `Float (Time_compat.now ()) ]))
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    Eio.Fiber.check ();
    report exn
  | exception exn -> report exn
;;

let changed ~base_path ~keeper_name =
  announce ~base_path ~event:row_changed_event ~label:keeper_name
    [ "name", `String keeper_name ]
;;

(* The failure counter is labelled by Keeper; a roster change names none. *)
let roster_label = "roster"

let roster_changed ~base_path =
  announce ~base_path ~event:roster_changed_event ~label:roster_label []
;;
