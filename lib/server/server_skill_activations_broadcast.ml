let site = Keeper_skill_activations_changed_event.event_type

let count_failure ~reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string SseBroadcastFailures)
    ~labels:[ "site", site; "reason", reason ]
    ()
;;

let keeper_of_trace entries trace_id =
  List.find_map
    (fun (entry : Keeper_registry.registry_entry) ->
       if Keeper_id.Trace_id.equal entry.meta.runtime.trace_id trace_id
       then Some entry.name
       else None)
    entries
;;

let announce (base_path, trace_id) =
  match keeper_of_trace (Keeper_registry.all ~base_path ()) trace_id with
  | None -> count_failure ~reason:"unnamed_trace"
  | Some name ->
    (match
       let authority = Sse.runtime_authority_exn ~base_path in
       Sse.broadcast_to (Sse.Runtime_observers authority)
         (Keeper_skill_activations_changed_event.json ~name
            ~trace_id:(Keeper_id.Trace_id.to_string trace_id) ~ts_unix:(Time_compat.now ()))
     with
     | () -> ()
     | exception (Eio.Cancel.Cancelled _ as e) -> raise e
     | exception exn ->
       count_failure ~reason:"broadcast";
       Log.Server.warn "skill activations: broadcast %s for %s failed: %s" site name
         (Printexc.to_string exn))
;;

let install ~sw =
  let wake = Eio.Stream.create 1 in
  let pending_mu = Stdlib.Mutex.create () in
  let pending : (string * string, string * Keeper_id.Trace_id.t) Hashtbl.t = Hashtbl.create 8 in
  let observer ~(config : Workspace.config) ~trace_id =
    Stdlib.Mutex.protect pending_mu (fun () ->
      Hashtbl.replace pending
        (config.base_path, Keeper_id.Trace_id.to_string trace_id)
        (config.base_path, trace_id);
      if Eio.Stream.is_empty wake then Eio.Stream.add wake ())
  in
  let take_pending () =
    Stdlib.Mutex.protect pending_mu (fun () ->
      let changed = Hashtbl.fold (fun _ value acc -> value :: acc) pending [] in
      Hashtbl.reset pending;
      changed)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      Eio.Stream.take wake;
      List.iter announce (take_pending ());
      loop ()
    in
    loop ());
  Keeper_skill_activation_ledger.install_commit_observer observer
;;
