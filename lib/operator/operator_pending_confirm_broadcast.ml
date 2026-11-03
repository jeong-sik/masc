let changed_event = "pending_confirms_changed"

let changed ~base_path =
  (* A reader woken by this reads the operator snapshot, which is cached for
     a while; dropping the cache first makes that read compute the change
     (RFC-0480 §3.4). *)
  Operator_control_snapshot_cache.invalidate_snapshot_cache ();
  try Sse.broadcast (`Assoc [ "type", `String changed_event ]) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.warn
      "pending confirms: broadcast %s for %s failed: %s"
      changed_event
      base_path
      (Printexc.to_string exn)
;;
