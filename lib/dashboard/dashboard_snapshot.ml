(** See [dashboard_snapshot.mli] for the public contract.

    RFC-0138 Phase 3 implementation.  The refresh fiber populates all
    four projections ([shell], [tools], [namespace_truth],
    [telemetry_summary]) and publishes via the lock-free atomic
    [slot].  Handler wiring lives in [Server_dashboard_shell_snapshot]
    (renamed to [Server_dashboard_snapshot_select] in #16761). *)

type t = {
  generated_at : float;
  generation : int;
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

(* Monotonic publish counter.  Independent atomic so a reader observing
   a fresh [t] always sees an increasing [generation] without contention
   on the slot atomic. *)
let generation_counter = Atomic.make 0

let next_generation () = Atomic.fetch_and_add generation_counter 1 + 1

let current () = Atomic.get slot

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

(* Bootstrap once: if no live snapshot exists, compute one synchronously
   and publish so subsequent readers do not pay the cost.  A second
   concurrent caller observing [None] races to compute; the
   [Atomic.compare_and_set] keeps only one winner and the loser's work
   is discarded.  Acceptable: bootstrap happens at most a few times per
   process lifetime. *)
let bootstrap ~(config : Workspace.config) : t =
  let shell =
    try
      (!dashboard_shell_payload_json_ref) config
    with exn ->
      Log.Dashboard.warn "dashboard_snapshot bootstrap shell failed: %s"
        (Printexc.to_string exn);
      `Null
  in
  let shell_light =
    try
      (!dashboard_shell_payload_json_ref) ~light:true config
    with exn ->
      Log.Dashboard.warn "dashboard_snapshot bootstrap shell_light failed: %s"
        (Printexc.to_string exn);
      `Null
  in
  let tools =
    try
      (!dashboard_tools_http_json_ref) config
    with exn ->
      Log.Dashboard.warn "dashboard_snapshot bootstrap tools failed: %s"
        (Printexc.to_string exn);
      `Null
  in
  let telemetry_summary =
    try
      let base_path = config.base_path in
      let masc_root = Workspace.masc_root_dir config in
      Telemetry_unified.summary_json ~base_path ~masc_root ()
    with exn ->
      Log.Dashboard.warn "dashboard_snapshot bootstrap telemetry_summary failed: %s"
        (Printexc.to_string exn);
      `Null
  in
  (* namespace_truth requires Eio context and cached refs; the
     bootstrap path is synchronous on the request fiber and cannot
     access them safely.  Bootstrap leaves it [`Null]; the refresh
     fiber populates the slot from
     [Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches]
     on its first interval (~2s after server start). *)
  let namespace_truth = `Null in
  (* RFC-0201: leave [activity_events_default] [`Null] in bootstrap.
     [Activity_graph.json_response] reads disk JSONL; we keep the
     bootstrap path light and let the refresh fiber populate on its
     first interval (~2s after start), same as [namespace_truth]. *)
  let activity_events_default = `Null in
  (* RFC-0201 Step 2 + 3 — same pattern as activity_events_default:
     leave [`Null] in bootstrap so the synchronous request-fiber
     path stays light; the refresh fiber populates on its first
     interval. *)
  let activity_graph_default = `Null in
  let activity_swimlane_default = `Null in
  let t =
    {
      generated_at = Unix.gettimeofday ();
      generation = next_generation ();
      shell;
      shell_light;
      tools;
      namespace_truth;
      telemetry_summary;
      activity_events_default;
      activity_graph_default;
      activity_swimlane_default;
    }
  in
  (* Publish only if the slot is still empty — never overwrite a
     refresh-fiber publish with a bootstrap value. *)
  ignore (Atomic.compare_and_set slot None (Some t));
  t
;;

let current_or_bootstrap ~config =
  match Atomic.get slot with
  | Some t -> t
  | None -> bootstrap ~config
;;

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
      "dashboard_snapshot refresh: %s failed (snapshot held at previous publish): %s"
      label (Printexc.to_string exn)
  in
  let safe label f =
    try f () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      log_failure label exn;
      `Null
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
      safe "shell" (fun () ->
        (!dashboard_shell_payload_json_ref) config)
    in
    let shell_light =
      (* RFC-0204 section 8.3 ("A"): publish the light projection too so
         [shell?light=true] reads it wait-free. *)
      safe "shell_light" (fun () ->
        (!dashboard_shell_payload_json_ref) ~light:true config)
    in
    let tools =
      safe "tools" (fun () ->
        (!dashboard_tools_http_json_ref) config)
    in
    let telemetry_summary =
      safe "telemetry_summary" (fun () ->
        let base_path = config.base_path in
        let masc_root = Workspace.masc_root_dir config in
        Telemetry_unified.summary_json ~base_path ~masc_root ())
    in
    let namespace_truth =
      match state with
      | None -> `Null
      | Some state ->
        safe "namespace_truth" (fun () ->
          match
            (!namespace_truth_snapshot_callback) state
          with
          | Some json -> json
          | None -> `Null)
    in
    let activity_events_default =
      (* RFC-0201 Step 1.  Snapshot the dashboard panel's default
         query at the API max [limit=1000]; handlers slice this list
         down to their requested limit per call.  The cost is paid
         once per [interval_sec] in this background fiber, not on the
         request path. *)
      safe "activity_events_default" (fun () ->
        Activity_graph.json_response config ~kinds:[] ~after_seq:0
          ~limit:1000 ())
    in
    let activity_graph_default =
      (* RFC-0201 Step 2.  Dashboard panel calls
         [fetchActivityGraph()] without query params (see
         dashboard/src/api/actions.ts:54), so the server applies the
         compute defaults: [kinds=[]], [limit=500],
         [timeline_limit=80], [since_ms=None].  Snapshot that
         exact shape; handlers return it as-is for matching queries
         (the result is aggregated and not sliceable). *)
      safe "activity_graph_default" (fun () ->
        Activity_graph.graph_json config ~kinds:[] ~limit:500
          ~timeline_limit:80 ())
    in
    let activity_swimlane_default =
      (* RFC-0201 Step 3.  Same shape as activity_graph_default —
         dashboard's [fetchSwimlane()] sends no params (actions.ts:77),
         so snapshot [limit=500], [since_ms=None]. *)
      safe "activity_swimlane_default" (fun () ->
        Activity_graph.agent_spans_json config ~limit:500 ())
    in
    {
      generated_at = Unix.gettimeofday ();
      generation = next_generation ();
      shell;
      shell_light;
      tools;
      namespace_truth;
      telemetry_summary;
      activity_events_default;
      activity_graph_default;
      activity_swimlane_default;
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
          [compute] touches is an [Atomic] ([slot], [generation_counter]), so
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
    generation = next_generation ();
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
