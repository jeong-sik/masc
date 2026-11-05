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
  let trace = Keeper_id.Trace_id.to_string trace_id in
  (* The fiber outlives any one write; whatever fails here is counted and
     logged, and the fiber goes on to the next change. *)
  match
    match keeper_of_trace (Keeper_registry.all ~base_path ()) trace_id with
    | None -> `Unnamed
    | Some name ->
      let authority = Sse.runtime_authority_exn ~base_path in
      Sse.broadcast_to (Sse.Runtime_observers authority)
        (Keeper_skill_activations_changed_event.json ~name ~trace_id:trace
           ~ts_unix:(Time_compat.now ()));
      `Sent
  with
  | `Sent -> ()
  | `Unnamed ->
    count_failure ~reason:"unnamed_trace";
    Log.Server.debug "skill activations: no registry entry holds trace %s" trace
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception exn ->
    count_failure ~reason:"broadcast";
    Log.Server.warn "skill activations: announcing trace %s failed: %s" trace
      (Printexc.to_string exn)
;;

let start ~sw =
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
  observer
;;

let install ~sw =
  let observer = start ~sw in
  Keeper_skill_activation_ledger.install_commit_observer observer;
  (* Nothing drains the changes once the fiber's switch ends. *)
  Eio.Switch.on_release sw (fun () ->
    Keeper_skill_activation_ledger.withdraw_commit_observer observer)
;;
