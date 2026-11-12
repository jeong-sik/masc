module Owner = Server_dashboard_operator_snapshot_observation

module Completions = Server_workspace_invalidation.Make (struct
  type t = unit
  let compare () () = 0
end)

(* The original mutation callback runs after its lock is released. It only
   synchronizes the current owner and enqueues bounded source/publication debt. *)
let () = Dashboard_projection_cache.register_snapshot_generation_observer
    (fun _generation -> Owner.synchronize_invalidation ())

let start_operator_snapshot_refresh_loop ~state ~sw ~clock ~mono_clock =
  Server_observation_refresh.install_scoped ~state ~sw ~install:(fun ~scope ~sw ~is_current ->
    let owner = Owner.owner_for_scope ~state scope in
    let target = Sse.Scoped_runtime_observers (Sse.observer_scope
        ~runtime_authority:(Sse.runtime_authority_exn ~base_path:scope.config.base_path)
        ~instance_id:(Server_observer_scope.instance_id scope)) in
    let query = Server_dashboard_http_core_operator_query.operator_snapshot_default_query () in
    let changes = Eio.Stream.create 1 in
    let changes_mu = Stdlib.Mutex.create () in
    let changed () = Stdlib.Mutex.protect changes_mu (fun () ->
      if Eio.Stream.is_empty changes then Eio.Stream.add changes ()) in
    let enqueue = ref (fun () -> ()) in
    let retain_if_superseded publication = match Owner.publication_status owner publication with
      | Owner.Superseded -> !enqueue ()
      | Current | Source_pending | Retired -> () in
    let publish () =
      let publication = Owner.publication owner in
      match Owner.publication_status owner publication with
      | Owner.Current ->
          let encoded = Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
            let payload = Owner.publication_json publication in
            Sse_wire.encode_json (`Assoc ["type", `String "operator_snapshot";
              "payload", payload; "ts_unix", `Float (Time_compat.now ())])) in
          if is_current () && Owner.publication_is_current owner publication then
            Sse.broadcast_encoded_to_with_receipts target
              ~on_fanout:(fun _ -> ()) ~on_committed:(fun _ -> ()) encoded
          else retain_if_superseded publication
      | Superseded -> !enqueue ()
      | Source_pending | Retired -> () in
    let publish_owed = Completions.start ~sw ~mono_clock ~publish:(fun () -> publish ()) in
    enqueue := (fun () -> publish_owed ());
    let unsubscribe = Owner.subscribe_completed owner (fun completion ->
      (match completion with
       | Owner.Installed Default_request | Failed Default_request | Source_changed | Invalidated -> changed ()
       | Installed Source_read | Failed Source_read -> ());
      publish_owed ()) in
    Eio.Switch.on_release sw unsubscribe;
    Server_observation_input.subscribe ~sw ~base_path:scope.config.base_path
      ~observer_instance_id:(Server_observer_scope.instance_id scope) (fun input ->
        if Server_observation_refresh.affects Operator_snapshot input then Owner.source_changed owner);
    publish_owed ();
    let latest_attempt = ref None in
    let interval_s = Server_dashboard_http_core_operator.operator_refresh_interval_s in
    Proactive_refresh.start_on_change_or_deadline ~sw ~clock ~changes
      ~config:{(Proactive_refresh.default_config ~label:"operator_snapshot" ~interval_s) with
        timeout_s = interval_s *. 0.8; warm_delay_s = 0.0;
        on_failure = Some (fun failure ->
          if is_current () then Option.iter (fun attempt ->
            ignore (Owner.publish_failure_message attempt (Proactive_refresh.failure_message failure)))
            !latest_attempt)}
      ~compute:(fun () ->
        let attempt = Owner.begin_attempt owner ~origin:Source_read in
        latest_attempt := Some attempt;
        try
          let observation = Server_dashboard_operator_snapshot_compute.observe_current
              ~state ~scope ~sw ~clock ~query ~actor:"dashboard" ~view:"summary"
              ~include_messages:true ~include_keepers:true ~include_summary_fields:false
              ~lightweight_summary:true () in
          ignore (Owner.publish_observation attempt observation);
          observation
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> ignore (Owner.publish_failure_message attempt (Printexc.to_string exn)); raise exn)
      ~on_result:(fun observation -> match observation.Dashboard_projection_read.completeness with
        | Complete -> () | Partial detail -> raise (Dashboard_projection_read.Incomplete_read detail))
      ~next_deadline:(fun _ -> Owner.next_deadline_unix owner))
