(* Pending confirmations change when their own deadline passes, even when no
   writer runs. This worker waits for that deadline, a store publication, or
   workspace retirement. Failed observations are retried with backoff; a
   healthy idle source is never scanned on an interval. *)
module Expiry_key = struct
  type t = string * string
  let compare = compare
end

module Expiry_set = Set.Make (Expiry_key)

type expiry_plan = {
  expired : Expiry_set.t;
  next : float option;
}

let expiry_plan ~now entries =
  List.fold_left (fun plan (entry : Operator_pending_confirm.pending_confirm) ->
    match entry.expires_at with
    | None -> plan
    | Some text ->
      (match Masc_domain.parse_iso8601_opt text with
       | None -> plan (* The store decoder already rejects this value. *)
       | Some at when Float.compare at now <= 0 ->
           { plan with expired = Expiry_set.add (entry.confirm_token, text) plan.expired }
       | Some at ->
           let next = match plan.next with
             | Some previous -> Some (Float.min previous at)
             | None -> Some at in
           { plan with next }))
    { expired = Expiry_set.empty; next = None } entries
;;

let retry_initial_s = 1.0
let retry_ceiling_s = 60.0
let next_retry delay = Float.min retry_ceiling_s (delay *. 2.0)

let start_with ~sw ~clock ~sleep_until ~sleep_retry
    ~(state : Mcp_server.server_state) ~read ~invalidate ~observation_changed ~restore =
  let wake = Eio.Stream.create 1 in
  let wake_mu = Stdlib.Mutex.create () in
  let source_generation = Atomic.make 0 in
  let observation = Atomic.make None in
  let active = Atomic.make true in
  let is_current scope =
    Mcp_server.Workspace_scope_epoch.equal scope.Mcp_server.epoch
      (Mcp_server.workspace_scope state).epoch in
  let observation_for_config config =
    if not (Atomic.get active) then Pending_confirm_observation.unmanaged
    else
      let scope = Mcp_server.workspace_scope state in
      let generation = Atomic.get source_generation in
      let status =
        match Config_dir_resolver.canonical_base_path config.Workspace.base_path,
              Config_dir_resolver.canonical_base_path scope.config.base_path with
        | Error _, _ | _, Error _ -> Pending_confirm_observation.Scope_unavailable
        | Ok source, Ok target when not (String.equal source target) ->
            Pending_confirm_observation.Workspace_unobserved
        | Ok _, Ok _ ->
          match Atomic.get observation with
          | Some (epoch, observed_generation, status, valid_before)
            when Mcp_server.Workspace_scope_epoch.equal epoch scope.epoch
                 && Int.equal observed_generation generation
                 && is_current scope ->
              (match status with
               | Pending_confirm_observation.Observed
                 when Option.exists (fun at -> Unix.gettimeofday () >= at) valid_before ->
                   Pending_confirm_observation.Initializing
               | Observed | Not_managed | Initializing | Source_unavailable
               | Deadline_unavailable | Workspace_unobserved | Scope_unavailable -> status)
          | Some _ | None -> Pending_confirm_observation.Initializing in
      Pending_confirm_observation.managed
        ~epoch:(Mcp_server.Workspace_scope_epoch.to_string scope.epoch)
        ~generation status in
  let previous_observation =
    Pending_confirm_observation.install observation_for_config in
  Eio.Switch.on_release sw (fun () ->
    Atomic.set active false;
    ignore (Pending_confirm_observation.restore_if_current
      ~current:observation_for_config ~previous:previous_observation));
  let publish_observation ?valid_before scope generation status =
    if is_current scope && generation = Atomic.get source_generation then begin
      let next = Some (scope.Mcp_server.epoch, generation, status, valid_before) in
      let previous = Atomic.exchange observation next in
      let changed = match previous with
        | Some (epoch, previous_generation, previous_status, previous_valid_before) ->
            not (Mcp_server.Workspace_scope_epoch.equal epoch scope.epoch
                 && Int.equal previous_generation generation
                 && previous_status = status
                 && previous_valid_before = valid_before)
        | None -> true in
      if changed then observation_changed ~base_path:scope.config.base_path
    end in
  let signal () =
    Stdlib.Mutex.protect wake_mu (fun () ->
      if Eio.Stream.is_empty wake then Eio.Stream.add wake ()) in
  let observer ~base_path =
    let current = Mcp_server.workspace_scope state in
    let may_match =
      match Config_dir_resolver.canonical_base_path base_path,
            Config_dir_resolver.canonical_base_path current.config.base_path with
      | Ok source, Ok target -> String.equal source target
      | Error _, _ | _, Error _ -> true in
    if may_match then begin
      ignore (Atomic.fetch_and_add source_generation 1);
      signal ()
    end;
    invalidate ~base_path in
  Operator_pending_confirm.install_change_observer observer;
  Eio.Switch.on_release sw (fun () ->
    ignore (Operator_pending_confirm.replace_change_observer_if_current
      ~current:observer ~replacement:restore));
  let await_next scope next ~on_armed =
    Eio.Fiber.first
      (fun () -> Eio.Promise.await (Mcp_server.workspace_scope_replaced scope); `Replaced)
      (fun () ->
        match next with
        | None -> Eio.Stream.take wake; `Changed
        | Some at ->
            Eio.Fiber.first
              (fun () ->
                match sleep_until ~on_armed at with
                | () -> `Deadline
                | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
                | exception _ -> `Timer_unavailable)
              (fun () -> Eio.Stream.take wake; `Changed)) in
  let await_retry scope delay =
    Eio.Fiber.first
      (fun () -> Eio.Promise.await (Mcp_server.workspace_scope_replaced scope); `Replaced)
      (fun () ->
        Eio.Fiber.first
          (fun () -> Eio.Stream.take wake; `Changed)
          (fun () -> sleep_retry delay; `Retry)) in
  let rec await_usable_next scope next ~generation ~failed ~delay =
    let on_armed () =
      publish_observation ?valid_before:next scope generation Pending_confirm_observation.Observed in
    match await_next scope next ~on_armed with
    | `Timer_unavailable ->
      publish_observation scope generation Pending_confirm_observation.Deadline_unavailable;
      if not failed then begin
        Log.Server.error "pending-confirm wall deadline unavailable";
        invalidate ~base_path:scope.Mcp_server.config.base_path
      end;
      (match await_retry scope delay with
       | `Replaced -> `Replaced
       | `Changed -> `Changed
       | `Retry ->
           await_usable_next scope next ~generation ~failed:true ~delay:(next_retry delay))
    | (`Replaced | `Changed | `Deadline) as result -> result in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec scan scope notified source_failed delay =
      let generation = Atomic.get source_generation in
      let result = Eio.Fiber.first
        (fun () -> `Read (read scope.Mcp_server.config))
        (fun () ->
          Eio.Promise.await (Mcp_server.workspace_scope_replaced scope);
          `Replaced) in
      match result with
      | `Replaced -> follow_current ()
      | `Read _ when not (is_current scope) -> follow_current ()
      | `Read _ when generation <> Atomic.get source_generation ->
          ignore (Eio.Stream.take_nonblocking wake);
          scan scope notified source_failed delay
      | `Read reading ->
        (match reading with
         | Error _ ->
             publish_observation scope generation Pending_confirm_observation.Source_unavailable;
             (* Store decoder errors may contain confirmation tokens. *)
             if not source_failed then begin
               Log.Server.warn "pending-confirm deadline observation failed";
               invalidate ~base_path:scope.config.base_path
             end;
             (match await_retry scope delay with
              | `Replaced -> follow_current ()
              | `Changed | `Retry -> scan scope notified true (next_retry delay))
         | Ok entries ->
             let plan = expiry_plan ~now:(Eio.Time.now clock) entries in
             (match plan.next with
              | None ->
                  publish_observation scope generation Pending_confirm_observation.Observed
              | Some _ -> ());
             if source_failed ||
                not (Expiry_set.is_empty (Expiry_set.diff plan.expired notified)) then
               invalidate ~base_path:scope.config.base_path;
             match await_usable_next scope plan.next ~generation ~failed:false ~delay:retry_initial_s with
             | `Replaced -> follow_current ()
             | `Changed ->
                 (* The previous deadline is no longer armed. Do not report
                    the observation as current while the next read waits. *)
                 publish_observation scope generation Pending_confirm_observation.Initializing;
                 scan scope plan.expired false retry_initial_s
             | `Deadline ->
                 (* Reads crossing the deadline must not inherit a later
                    observed status from the same source revision. *)
                 let generation = Atomic.fetch_and_add source_generation 1 + 1 in
                 publish_observation scope generation Pending_confirm_observation.Initializing;
                 scan scope plan.expired false retry_initial_s)
    and follow_current () =
      scan (Mcp_server.workspace_scope state) Expiry_set.empty false retry_initial_s in
    follow_current ())
;;

let read_storage config =
  try
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Ok (Operator_pending_confirm.raw_pending_confirms config))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Operator_pending_confirm.Store_error detail -> Error detail
  | exn -> Error (Printexc.to_string exn)
;;

let start ~sw ~clock ~mono_clock ~state =
  let publish ~base_path =
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to_sse_runtime_observers authority Pending_confirm_invalidation_event.json in
  let enqueue = Server_workspace_invalidation.start ~sw ~mono_clock ~publish in
  let restore = Server_routes_http_runtime.invalidate_full_health_snapshot_for_workspace in
  let invalidate ~base_path =
    enqueue ~base_path;
    restore ~base_path in
  start_with ~sw ~clock
    ~sleep_until:(fun ~on_armed at -> Wall_deadline.sleep_until ~on_armed at) ~state
    ~sleep_retry:(Eio.Time.Mono.sleep mono_clock) ~read:read_storage ~invalidate
    ~observation_changed:invalidate ~restore
;;

module For_testing = struct
  let start_with_sleep ~sleep_until ~sw ~clock ~state ~read ~invalidate =
    start_with ~sw ~clock
      ~sleep_until:(fun ~on_armed at -> on_armed (); sleep_until at)
      ~sleep_retry:(Eio.Time.sleep clock) ~state ~read ~invalidate
      ~observation_changed:(fun ~base_path:_ -> ()) ~restore:invalidate

  let start_with_observation ~sleep_until ~sleep_retry ~sw ~clock ~state ~read ~invalidate ~observation_changed =
    start_with ~sw ~clock ~sleep_until ~sleep_retry
      ~state ~read ~invalidate ~observation_changed ~restore:invalidate

  let start ~sw ~clock ~state ~read ~invalidate =
    start_with_sleep ~sleep_until:(Eio.Time.sleep_until clock)
      ~sw ~clock ~state ~read ~invalidate
end
