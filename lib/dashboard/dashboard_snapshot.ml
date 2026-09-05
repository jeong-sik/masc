(** See [dashboard_snapshot.mli] for the public contract.

    RFC-0138 Phase 3 implementation.  The refresh fiber populates all
    four projections ([shell], [tools], [namespace_truth],
    [telemetry_summary]) and publishes via the lock-free atomic
    [slot].  Handler wiring lives in [Server_dashboard_shell_snapshot]
    (renamed to [Server_dashboard_snapshot_select] in #16761). *)

type t = {
  generated_at : float;
  shell : Yojson.Safe.t;
  shell_light : Yojson.Safe.t;
  (* RFC-0204 section 8.3 ("A"): the [~light] projection of the shell,
     published alongside [shell] so a [shell?light=true] read serves it
     wait-free instead of recomputing.  Light is a DIFFERENT shape from
     [shell] (skips belief/tension evaluation, uses the light agent-count /
     runtime projections), so it is stored separately rather than derived. *)
  tools : Yojson.Safe.t;
  namespace_truth : Yojson.Safe.t;
  telemetry_summary : Yojson.Safe.t;
  activity_events_default : Yojson.Safe.t;
  (* RFC-0201 Step 1 — see [.mli] for contract. *)
  activity_graph_default : Yojson.Safe.t;
  activity_swimlane_default : Yojson.Safe.t;
  (* RFC-0201 Step 2 + 3 — see [.mli] for contract.  Returned as-is to
     default-shape callers; results are aggregated and not sliceable. *)
}

(* Lock-free publish slot.  Holds [None] before the first publish so
   readers can distinguish "not yet warmed" from a real empty snapshot
   (the latter never occurs in normal operation). *)
let slot : t option Atomic.t = Atomic.make None

let current () = Atomic.get slot

type projection_cache_entry =
  { refreshed_at : float
  ; value : Yojson.Safe.t
  }

type projection_cache = projection_cache_entry option Atomic.t

let make_projection_cache () : projection_cache = Atomic.make None

let should_reuse_projection ~now ~ttl ~refreshed_at =
  let age = now -. refreshed_at in
  age >= 0.0 && age < ttl
;;

let refresh_projection ~now ~ttl ~(cache : projection_cache) compute =
  let started_at = now () in
  match Atomic.get cache with
  | Some entry
    when should_reuse_projection
           ~now:started_at
           ~ttl
           ~refreshed_at:entry.refreshed_at ->
    entry.value
  | previous ->
    (match compute () with
     | value ->
       Atomic.set cache (Some { refreshed_at = now (); value });
       value
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn ->
       (match previous with
        | Some entry -> entry.value
        | None -> raise exn))
;;

type activity_defaults_entry =
  { refreshed_at : float
  ; value : Activity_graph.default_projections
  }

type activity_defaults_cache = activity_defaults_entry option Atomic.t

let make_activity_defaults_cache () : activity_defaults_cache = Atomic.make None

let refresh_activity_defaults ~now ~ttl ~(cache : activity_defaults_cache) compute =
  let started_at = now () in
  match Atomic.get cache with
  | Some entry
    when should_reuse_projection
           ~now:started_at
           ~ttl
           ~refreshed_at:entry.refreshed_at ->
    entry.value
  | previous ->
    (match compute () with
     | value ->
       Atomic.set cache (Some { refreshed_at = now (); value });
       value
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn ->
       (match previous with
        | Some entry -> entry.value
        | None -> raise exn))
;;

let dashboard_shell_payload_json_ref :
  (?light:bool -> Workspace.config -> Yojson.Safe.t) ref =
  ref (fun ?light:_ _config -> `Null)

let register_dashboard_shell_payload_json fn =
  dashboard_shell_payload_json_ref := fn

let dashboard_tools_http_json_ref =
  ref (fun (_config : Workspace.config) -> `Null)

let register_dashboard_tools_http_json fn =
  dashboard_tools_http_json_ref := fn

let namespace_truth_snapshot_callback =
  ref (fun (_state : Mcp_server.server_state) -> None)

let register_namespace_truth_snapshot fn =
  namespace_truth_snapshot_callback := fn

(* RFC-0138 Phase 3: refresh loop optionally accepts [~state] so it
   can populate [namespace_truth] from the cached refs that
   [Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches]
   exposes.  That function reads only process-local refs (no PG I/O,
   no fiber timeouts), so it is safe in a background fiber.  Moving
   the read here is what allowed Step 4 (#16752) to retire the four
   [MASC_NAMESPACE_TRUTH_*_TIMEOUT_S] env knobs from the request
   path. *)
let refresh_loop
      ~sw:_ ~clock ~config ?state ~interval_sec ()
  =
  let log_failure label exn =
    Log.Dashboard.warn
      "dashboard_snapshot refresh: %s failed (last good retained): %s"
      label (Printexc.to_string exn)
  in
  let shell_cache = make_projection_cache () in
  let shell_light_cache = make_projection_cache () in
  let tools_cache = make_projection_cache () in
  let telemetry_cache = make_projection_cache () in
  let namespace_truth_cache = make_projection_cache () in
  let activity_defaults_cache = make_activity_defaults_cache () in
  let cached_activity_defaults ~ttl ~cache label f =
    (* NDT-OK: wall time only gates cache freshness; it is not durable output. *)
    refresh_activity_defaults ~now:Unix.gettimeofday ~ttl ~cache (fun () ->
      (* NDT-OK: wall time only measures operator diagnostics. *)
      let started_at = Unix.gettimeofday () in
      let allocated_before = Gc.allocated_bytes () in
      match f () with
      | value ->
        (* NDT-OK: elapsed time only selects diagnostic log severity. *)
        let elapsed_s = Unix.gettimeofday () -. started_at in
        let allocated_mb =
          (Gc.allocated_bytes () -. allocated_before) /. 1_048_576.0
        in
        if elapsed_s >= 5.0 || allocated_mb >= 256.0
        then
          Log.Dashboard.warn
            "dashboard_snapshot heavy refresh: component=%s elapsed_s=%.3f allocated_mb=%.1f ttl_s=%.0f"
            label elapsed_s allocated_mb ttl
        else
          Log.Dashboard.debug
            "dashboard_snapshot refreshed: component=%s elapsed_s=%.3f allocated_mb=%.1f ttl_s=%.0f"
            label elapsed_s allocated_mb ttl;
        value
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception exn ->
        log_failure label exn;
        raise exn)
  in
  let cached_projection ~ttl ~cache label f =
    (* NDT-OK: wall time only gates cache freshness; it is not durable output. *)
    refresh_projection ~now:Unix.gettimeofday ~ttl ~cache (fun () ->
      (* NDT-OK: wall time only measures operator diagnostics. *)
      let started_at = Unix.gettimeofday () in
      let allocated_before = Gc.allocated_bytes () in
      match f () with
      | value ->
        (* NDT-OK: elapsed time only selects diagnostic log severity. *)
        let elapsed_s = Unix.gettimeofday () -. started_at in
        let allocated_mb =
          (Gc.allocated_bytes () -. allocated_before) /. 1_048_576.0
        in
        if elapsed_s >= 5.0 || allocated_mb >= 256.0
        then
          Log.Dashboard.warn
            "dashboard_snapshot heavy refresh: component=%s elapsed_s=%.3f allocated_mb=%.1f ttl_s=%.0f"
            label elapsed_s allocated_mb ttl
        else
          Log.Dashboard.debug
            "dashboard_snapshot refreshed: component=%s elapsed_s=%.3f allocated_mb=%.1f ttl_s=%.0f"
            label elapsed_s allocated_mb ttl;
        value
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception exn ->
        log_failure label exn;
        raise exn)
  in
  let compute () =
    let shell =
      (* [shell] intentionally omits [~light]: the snapshot publishes the FULL
         shell.  Its non-light path uses Eio.Fiber.all, which is safe on the
         Executor_pool worker domain this [compute] runs on -- each worker
         opens its own Switch.run and forks the job as a fiber (eio
         executor_pool.ml run_worker), so Fiber.all resolves against the
         worker's context, not the main domain's.  Do not "fix" this to
         [~light:true]; that would change [shell] to the light shape. *)
      cached_projection ~ttl:30.0 ~cache:shell_cache "shell" (fun () ->
        (!dashboard_shell_payload_json_ref) config)
    in
    let shell_light =
      (* RFC-0204 section 8.3 ("A"): publish the light projection too so
         [shell?light=true] reads it wait-free. *)
      cached_projection ~ttl:0.0 ~cache:shell_light_cache "shell_light"
        (fun () -> (!dashboard_shell_payload_json_ref) ~light:true config)
    in
    let tools =
      cached_projection ~ttl:60.0 ~cache:tools_cache "tools" (fun () ->
        (!dashboard_tools_http_json_ref) config)
    in
    let telemetry_summary =
      cached_projection ~ttl:30.0 ~cache:telemetry_cache "telemetry_summary" (fun () ->
        let base_path = config.base_path in
        let masc_root = Workspace.masc_root_dir config in
        let keeper_keepalive_interval_s =
          Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec
          |> float_of_int
        in
        let keeper_metric_producer_active =
          Keeper_status_runtime.keeper_metric_producer_active ~base_path
        in
        Telemetry_unified.summary_json
          ~keeper_keepalive_interval_s
          ~keeper_metric_producer_active
          ~base_path
          ~masc_root
          ())
    in
    let namespace_truth =
      cached_projection ~ttl:0.0 ~cache:namespace_truth_cache
        "namespace_truth" (fun () ->
          match state with
          | None -> `Null
          | Some state ->
            (match (!namespace_truth_snapshot_callback) state with
             | Some json -> json
             | None -> `Null))
    in
    let activity_defaults =
      (* RFC-0201 / RFC-0204: compute all three default activity projections
         (events, graph, swimlane) in a single pass over the recent events store,
         avoiding 3x redundant re-parsing and scanning on every 10s tick. *)
      cached_activity_defaults ~ttl:10.0 ~cache:activity_defaults_cache
        "activity_defaults" (fun () ->
        Activity_graph.default_projections config)
    in
    {
      generated_at = Unix.gettimeofday ();
      shell;
      shell_light;
      tools;
      namespace_truth;
      telemetry_summary;
      activity_events_default = activity_defaults.events_default;
      activity_graph_default = activity_defaults.graph_default;
      activity_swimlane_default = activity_defaults.swimlane_default;
    }
  in
  let rec loop () =
    (match
       (* Offload the snapshot compute to a worker domain (RFC-0204 sections 8-9
          Phase 2).  The projection build (shell board scan + 3 activity
          graphs) is CPU-heavy and previously ran inline on the main Eio
          domain, contending with WS dispatch and keeper fibers under host
          load.  [submit_cpu_or_inline] reserves a full worker slot
          (weight 1.0, matching the per-surface refresh loops'
          [run_dashboard_compute ~mode:Offloaded_readonly]) and falls back to
          inline before the pool is installed at boot.  Every shared cell
          [compute] touches is an [Atomic] ([slot]), so
          it is cross-domain safe; the publish ([Atomic.set slot]) stays on
          this fiber.  If the whole compute path fails (an exception escapes a
          [safe] wrapper), keep the previous snapshot live. *)
       try Some (Domain_pool_ref.submit_cpu_or_inline compute) with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         log_failure "compute" exn;
         None
     with
     | Some t -> Atomic.set slot (Some t)
     | None -> ());
    Eio.Time.sleep clock interval_sec;
    loop ()
  in
  loop ()
;;

let publish_for_test t = Atomic.set slot (Some t)

let make_for_test ~shell ?(shell_light = `Null) ~tools ~namespace_truth
      ~telemetry_summary
      ?(activity_events_default = `Null)
      ?(activity_graph_default = `Null)
      ?(activity_swimlane_default = `Null) () =
  {
    generated_at = Unix.gettimeofday ();
    shell;
    shell_light;
    tools;
    namespace_truth;
    telemetry_summary;
    activity_events_default;
    activity_graph_default;
    activity_swimlane_default;
  }
;;

let reset_for_test () = Atomic.set slot None

module For_testing = struct
  type cache = projection_cache
  type activity_cache = activity_defaults_cache

  let make_cache = make_projection_cache
  let refresh_projection = refresh_projection
  let make_activity_cache = make_activity_defaults_cache
  let refresh_activity_defaults = refresh_activity_defaults
  let should_reuse_projection = should_reuse_projection
end
