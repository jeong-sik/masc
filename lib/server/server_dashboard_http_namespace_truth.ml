(** Namespace-truth read model and SSE snapshot broadcasting. *)

open Server_dashboard_http_core
open Server_dashboard_http_cache

module Execution_surfaces = Server_dashboard_http_execution_surfaces
module Namespace_truth_support = Server_dashboard_http_namespace_truth_support

let namespace_truth_shell_refreshing : bool Atomic.t = Atomic.make false

(* RFC-0138 Phase 3 Step 4 — fallback timeouts are now module constants. Step
   3 (#16738) wired /project-snapshot through [Dashboard_snapshot], so request
   paths use stale-while-revalidate after the first seed. The async refresh must
   still exceed the inner dashboard shell timeout; otherwise a 5s outer timeout
   cancels the shell render before its timeout fallback can log the active
   projection labels (#16287). *)
let namespace_truth_cold_safety_margin_s = 4.0

let namespace_truth_shell_refresh_timeout_s =
  Env_config_runtime.Dashboard.shell_timeout_sec
  +. namespace_truth_cold_safety_margin_s

let namespace_truth_warm_escape_s = 90.0
let namespace_truth_warm_timeout_s = 8.0
let namespace_truth_cold_timeout_s = 15.0
let namespace_truth_shell_fiber_timeout_s = 12.0

let namespace_truth_bootstrap_shell_json () =
  let generated_at = Masc_domain.now_iso () in
  `Assoc
    [
      ( "status",
        `Assoc
          [
            ("project", `String "initializing");
            ("generated_at", `String generated_at);
          ] );
      ( "counts",
        `Assoc
          [
            ("agents", `Int 0);
            ("tasks", `Int 0);
            ("keepers", `Int 0);
            ("total_runtimes", `Int 0);
      ] );
      ("configured_keepers", `Int 0);
    ]

let shell_json_matches_config ~(config : Workspace.config) json =
  match json_assoc_field "paths" json |> json_string_field_opt "effective_base_path" with
  | Some base_path -> String.equal base_path config.base_path
  | None -> false

let last_good_shell_for_config config =
  match Atomic.get last_good_shell with
  | `Assoc [] -> None
  | json when shell_json_matches_config ~config json -> Some json
  | _ -> None

let cached_shell_json_for_namespace ~config =
  match last_good_shell_for_config config with
  | Some json -> json
  | None -> namespace_truth_bootstrap_shell_json ()

let schedule_namespace_truth_shell_refresh ~sw ~clock config =
  if Atomic.compare_and_set namespace_truth_shell_refreshing false true then (
    Eio.Fiber.fork ~sw (fun () ->
        Eio_guard.protect
          ~finally:(fun () -> Atomic.set namespace_truth_shell_refreshing false)
          (fun () ->
             let timeout_s = namespace_truth_shell_refresh_timeout_s in
             let t0 = Time_compat.now () in
             try
               let result =
                 match
                   Eio.Time.with_timeout clock timeout_s (fun () ->
                       Ok (dashboard_shell_http_json ~clock config))
                 with
                 | Ok json -> json
                 | Error `Timeout ->
                   Log.Dashboard.warn
                     "project-snapshot async shell refresh timed out \
                      (outer=%.1fs shell=%.1fs)"
                     timeout_s
                     Env_config_runtime.Dashboard.shell_timeout_sec;
                   `Assoc []
               in
               if result <> `Assoc [] && not (is_dashboard_cache_timeout_json result)
               then (
                 Atomic.set last_good_shell result;
                 Atomic.set shell_warmed true;
                 Log.Dashboard.debug
                   "project-snapshot async shell refresh completed: %.0fms"
                   ((Time_compat.now () -. t0) *. 1000.0))
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
                 Log.Dashboard.warn
                   "project-snapshot async shell refresh failed: %s"
                   (Printexc.to_string exn))))

let dashboard_namespace_truth_http_json ~state ~sw ~clock _request =
  let config = (Mcp_server.workspace_config state) in
  (* Fast-path: if the proactive execution refresh hasn't produced a result
     yet, return "initializing" immediately instead of blocking for 15-20s
     on cold-start on-demand compute. The frontend retries every 3s via
     scheduleWarmRetry; the proactive refresh loop populates execution_cache
     in background. *)
  let warm_escape_s = namespace_truth_warm_escape_s in
  let proactive_first_cycle_pending =
    not (cached_surface_has_success Execution_surfaces.execution_cache)
    &&
    match Execution_surfaces.execution_cache.last_attempt_unix with
    | None -> true
    | Some attempt_ts ->
        let elapsed = Time_compat.now () -. attempt_ts in
        elapsed < warm_escape_s
        && Option.is_none Execution_surfaces.execution_cache.last_error_unix
  in
  if proactive_first_cycle_pending then
    Namespace_truth_support.compose_namespace_truth_initializing ~config
      ~message:
        "Execution snapshot is still warming up. The dashboard will retry automatically."
  else
    match last_good_shell_for_config config with
    | None ->
        (* No shell seed exists yet, so do one bounded synchronous attempt. Later
           requests use stale-while-revalidate and do not pay this cost. *)
        with_dashboard_timeout ~clock (fun () ->
        let started_at = Unix.gettimeofday () in
        let t0 = Time_compat.now () in
        (* Staged fetch: shell may still need a guarded refresh, while execution
           stays on the proactive cache to keep project-snapshot off the cold path. *)
        let shell_ref = ref (`Assoc []) in
        let execution_ref = ref (`Assoc []) in
        let command_ref = ref (`Assoc []) in
        (* Namespace-truth fiber timeouts.  Cold start uses higher defaults to
           allow shell/namespace reads to warm up.  Constants used to be
           tunable via [MASC_NAMESPACE_TRUTH_*_TIMEOUT_S] but Step 4 retires
           those knobs — see module-level [namespace_truth_*_timeout_s]
           bindings for the rationale. *)
        let warm_timeout_s = namespace_truth_warm_timeout_s in
        let cold_timeout_s = namespace_truth_cold_timeout_s in
        let is_cold =
          not (cached_surface_has_success Execution_surfaces.execution_cache)
        in
        let base_timeout_s = if is_cold then cold_timeout_s else warm_timeout_s in
        let fiber_with_timeout ?(timeout_s = base_timeout_s) label f fallback =
          try
            match Eio.Time.with_timeout clock timeout_s (fun () -> Ok (f ())) with
            | Ok v -> v
            | Error `Timeout ->
                Log.Dashboard.warn "project-snapshot fiber %s timed out (%.0fs)" label
                  timeout_s;
                fallback
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Log.Dashboard.warn "project-snapshot fiber %s failed: %s" label
                (Printexc.to_string exn);
              fallback
        in
        (* Shell fiber timeout: must exceed inner cache timeout
           (dashboard_shell_timeout_s, default 8s) to avoid the double-timeout
           race where the inner cache returns timeout-error JSON while the outer
           fiber also fires, discarding even stale data.  Fixes #5090. *)
        let shell_fiber_timeout_s = namespace_truth_shell_fiber_timeout_s in
        let cold_safety_margin_s = namespace_truth_cold_safety_margin_s in
        let shell_timeout_s =
          if Atomic.get shell_warmed then shell_fiber_timeout_s
          else Float.max cold_timeout_s (shell_fiber_timeout_s +. cold_safety_margin_s)
        in
        (* Graceful degradation: on timeout fall back to the last successful
           shell result rather than empty JSON, which would zero out namespace
           counts and focus data (61x/day under I/O contention). *)
        let shell_fallback = cached_shell_json_for_namespace ~config in
        (* Sequential fetch to avoid PG connection concurrent usage (#3305). *)
        shell_ref :=
          fiber_with_timeout ~timeout_s:shell_timeout_s "shell"
            (fun () -> dashboard_shell_http_json ~clock config)
            shell_fallback;
        execution_ref := cached_surface_json Execution_surfaces.execution_cache;
        command_ref := `Assoc [];
        let shell_json = !shell_ref in
        (* Update last-known-good shell on success. *)
        if shell_json <> `Assoc [] && shell_json <> shell_fallback then
          Atomic.set last_good_shell shell_json;
        if (not (Atomic.get shell_warmed)) && shell_json <> `Assoc [] then
          Atomic.set shell_warmed true;
        let execution_json = !execution_ref in
        let command_summary_json = !command_ref in
        let parallel_ms = (Time_compat.now () -. t0) *. 1000.0 in
        if parallel_ms >= 100.0 then
          Log.Dashboard.info "project-snapshot fetch: %.0fms" parallel_ms
        else
          Log.Dashboard.debug "project-snapshot fetch: %.0fms" parallel_ms;
        let execution_cache_state =
          json_assoc_field "projection_diagnostics" execution_json
          |> json_string_field_opt "cache_state"
        in
        Namespace_truth_support.compose_namespace_truth_snapshot ~config
          ~initialized:(Workspace.is_initialized config) ~shell_json ~execution_json
          ~command_summary_json
        |> with_projection_diagnostics ~surface:"namespace_truth" ~started_at
             ~extra:
               [
                 ("parallel_ms", `Int (int_of_float parallel_ms));
                 ( "execution_cache_state",
                   Json_util.string_opt_to_json execution_cache_state );
               ])
    | Some shell_json ->
        schedule_namespace_truth_shell_refresh ~sw ~clock config;
        (* NDT-OK: projection diagnostics timestamp only; snapshot content comes
           from cached read models. *)
        let started_at = Unix.gettimeofday () in
        let execution_json = cached_surface_json Execution_surfaces.execution_cache in
      let execution_cache_state =
        json_assoc_field "projection_diagnostics" execution_json
        |> json_string_field_opt "cache_state"
      in
      Namespace_truth_support.compose_namespace_truth_snapshot ~config
        ~initialized:(Workspace.is_initialized config)
        ~shell_json ~execution_json
        ~command_summary_json:(`Assoc [])
      |> with_projection_diagnostics ~surface:"namespace_truth" ~started_at
           ~extra:
             [
               ("parallel_ms", `Int 0);
               ("cache_mode", `String "stale_while_revalidate");
               ("shell_source", `String "last_good_shell");
               ( "shell_refresh_inflight",
                 `Bool (Atomic.get namespace_truth_shell_refreshing) );
               ( "execution_cache_state",
                 Json_util.string_opt_to_json execution_cache_state );
             ]

(** Assemble a lightweight namespace-truth snapshot from cached refs only.
    No PG I/O — reads proactive caches for execution and command, and
    the TTL-cached shell. Returns None when the execution cache has not
    produced its first successful result (cold start). *)
let namespace_truth_snapshot_from_caches (state : Mcp_server.server_state) :
    Yojson.Safe.t option =
  if not (cached_surface_has_success Server_dashboard_http_execution_surfaces.execution_cache) then
    None
  else
    let config = (Mcp_server.workspace_config state) in
    let shell_json = cached_shell_json_for_namespace ~config in
    let execution_json =
      (* Broadcast path reads the cached surface's raw [json] — a stable ref
         retained until the next successful refresh — instead of
         [cached_surface_json]. The latter rebuilds an [Assoc] tree carrying
         volatile fields ([cache_state], [stale_age_ms], [last_success_at]) on
         every call via [extend_projection_diagnostics]. But
         [compose_namespace_truth_snapshot] consumes only the structural
         fields of the execution surface ([execution_queue],
         [operation_briefs], [summary], [keepers], [tasks]) and never the
         projection-diagnostics fields, so reading the stable raw [json] skips
         that per-broadcast-check allocation entirely without changing the
         composed snapshot. The HTTP path
         ([dashboard_namespace_truth_http_json]) keeps [cached_surface_json]
         where clients render cache_state/stale_age_ms. *)
      Server_dashboard_http_execution_surfaces.execution_cache.json
    in
    let command_summary_json = `Assoc [] in
    Some
      (Namespace_truth_support.compose_namespace_truth_snapshot ~config
         ~initialized:(Workspace.is_initialized config) ~shell_json ~execution_json
         ~command_summary_json)

let last_namespace_truth_snapshot_hash : Digestif.SHA256.t option ref =
  ref None

let namespace_truth_snapshot_hash_mu = Eio.Mutex.create ()

let hash_namespace_truth_snapshot (snapshot : Yojson.Safe.t) : Digestif.SHA256.t =
  (* Incremental SHA256 over the snapshot structure, skipping the volatile
     [generated_at]/[generated_at_iso] fields (they change every compose but
     must not trigger a broadcast). Replaces the prior normalize-copy +
     [Yojson.Safe.to_string] + [digest_string], which allocated a normalized
     Yojson tree AND a full serialized string on every broadcast check. This
     walks the structure once, feeding [Digestif.SHA256.feed_string] directly:
     one O(n) pass, no intermediate Yojson or string allocation.

     The hash value differs from the old string-hash (different bytes fed),
     but it is deterministic for a given structure and is used only for change
     detection (compare current to previous, both via this walker), so the
     broadcast semantics are preserved. Type tags (S/I/F/...) prevent prefix
     collisions between scalar kinds. *)
  let rec walk (ctx : Digestif.SHA256.ctx) (json : Yojson.Safe.t) :
      Digestif.SHA256.ctx =
    match json with
    | `Assoc fields ->
        let ctx = Digestif.SHA256.feed_string ctx "{" in
        let ctx =
          List.fold_left
            (fun ctx (key, value) ->
               if String.equal key "generated_at" || String.equal key "generated_at_iso"
               then ctx
               else
                 let ctx = Digestif.SHA256.feed_string ctx key in
                 let ctx = Digestif.SHA256.feed_string ctx ":" in
                 walk ctx value)
            ctx fields
        in
        Digestif.SHA256.feed_string ctx "}"
    | `List values ->
        let ctx = Digestif.SHA256.feed_string ctx "[" in
        let ctx = List.fold_left walk ctx values in
        Digestif.SHA256.feed_string ctx "]"
    | `String s ->
        (* Length-prefix variable-length string fields so distinct JSON
           payloads cannot collide in the hash stream (e.g. ["aS","b"] vs
           ["a","Sb"]). The exact separator format is internal to this hash. *)
        let ctx = Digestif.SHA256.feed_string ctx (Printf.sprintf "S%d:" (String.length s)) in
        Digestif.SHA256.feed_string ctx s
    | `Int n ->
        let ctx = Digestif.SHA256.feed_string ctx "I" in
        Digestif.SHA256.feed_string ctx (string_of_int n)
    | `Intlit s ->
        let ctx = Digestif.SHA256.feed_string ctx "L" in
        Digestif.SHA256.feed_string ctx s
    | `Float f ->
        let ctx = Digestif.SHA256.feed_string ctx "F" in
        Digestif.SHA256.feed_string ctx (string_of_float f)
    | `Bool b -> Digestif.SHA256.feed_string ctx (if b then "Bt" else "Bf")
    | `Null -> Digestif.SHA256.feed_string ctx "N"
  in
  Digestif.SHA256.get (walk Digestif.SHA256.empty snapshot)

let should_broadcast_namespace_truth_snapshot (snapshot : Yojson.Safe.t) =
  let hash = hash_namespace_truth_snapshot snapshot in
  Eio.Mutex.use_rw ~protect:true namespace_truth_snapshot_hash_mu (fun () ->
      match !last_namespace_truth_snapshot_hash with
      | Some prev when Digestif.SHA256.equal prev hash -> false
      | _ ->
          last_namespace_truth_snapshot_hash := Some hash;
          true)

(** Broadcast current namespace-truth snapshot to all Observer SSE sessions.
    Called after proactive cache refreshes and keeper lifecycle events.
    Safe to call from any fiber — reads only from cached refs. *)
let broadcast_namespace_truth_snapshot (state : Mcp_server.server_state) : unit =
  match namespace_truth_snapshot_from_caches state with
  | None -> ()
  | Some snapshot when should_broadcast_namespace_truth_snapshot snapshot ->
      let namespace_sse_json =
        `Assoc
          [
            ("type", `String "project_snapshot");
            ("payload", snapshot);
            ("ts_unix", `Float (Time_compat.now ()));
          ]
      in
      let namespace_alias_sse_json =
        `Assoc
          [
            ("type", `String "namespace_truth_snapshot");
            ("payload", snapshot);
            ("ts_unix", `Float (Time_compat.now ()));
          ]
      in
      Sse.broadcast_to Observers namespace_sse_json;
      Sse.broadcast_to Observers namespace_alias_sse_json;
      (* Snapshot broadcasts are normal dashboard fanout. The cache/update
         failures around this path are logged separately. *)
      Log.Dashboard.routine "project-snapshot pushed via SSE"
  | Some _ ->
      Log.Dashboard.routine "project-snapshot unchanged, skipping SSE broadcast"

let () =
  Execution_surfaces.broadcast_namespace_truth_ref :=
    broadcast_namespace_truth_snapshot
