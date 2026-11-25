let changed_event = "keeper_turn_changed"

let publish ~base_path ~keeper_name ~event fields =
  (* The write is already committed, often under the caller's lock or in its
     finally block. A cancellation raised here would skip the caller's own
     bookkeeping, so it is reported like any failure; the caller's next
     suspension point still sees it. *)
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        ([ "type", `String event
         ; "name", `String keeper_name
         ; "ts_unix", `Float (Time_compat.now ())
         ] @ fields))
  with
  | () -> ()
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", keeper_name; "site", event ]
      ();
    Log.Keeper.warn
      "keeper_turn_broadcast: %s name=%s failed: %s"
      event
      keeper_name
      (Printexc.to_string exn)
;;

let changed ~base_path ~keeper_name =
  publish ~base_path ~keeper_name ~event:changed_event []
;;

let succeeded ~base_path ~keeper_name ~elapsed_ms =
  publish ~base_path ~keeper_name ~event:"keeper_turn_succeeded"
    [ "elapsed_ms", `Int elapsed_ms ]
;;
