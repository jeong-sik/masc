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

let last_good_shell_for_config ~state ~scope config =
  match Execution_surfaces.last_good_shell_for_scope ~state scope with
  | Some json when shell_json_matches_config ~config json -> Some json
  | Some _ | None -> None

let cached_shell_json_for_namespace ~state ~scope ~config =
  match last_good_shell_for_config ~state ~scope config with
  | Some json -> json
  | None -> namespace_truth_bootstrap_shell_json ()

let schedule_namespace_truth_shell_refresh ~state ~scope ~sw ~clock config =
  if Atomic.compare_and_set namespace_truth_shell_refreshing false true then (
    (* The reader answers from the cached shell; no request waits on this
       refresh (RFC-0204 3.4). *)
    Eio.Fiber.fork ~sw (fun () ->
        Pool_lane.with_background @@ fun () ->
        Eio_guard.protect
          ~finally:(fun () -> Atomic.set namespace_truth_shell_refreshing false)
          (fun () ->
             let timeout_s = namespace_truth_shell_refresh_timeout_s in
             let t0 = Time_compat.now () in
             try
               let result =
                 match
                   Watched_work.run
                     ~watcher:(fun () ->
                       Eio.Time.sleep clock timeout_s;
                       Error `Timeout)
                     (fun () -> Ok (dashboard_shell_http_json ~clock config))
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
               if result <> `Assoc [] && not (Dashboard_cache.is_timeout_envelope result)
               then (
                 Execution_surfaces.publish_shell_cache_success
                   ~state ~scope ~light:false result;
                 Log.Dashboard.debug
                   "project-snapshot async shell refresh completed: %.0fms"
                   ((Time_compat.now () -. t0) *. 1000.0))
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
                 Log.Dashboard.warn
                   "project-snapshot async shell refresh failed: %s"
                   (Printexc.to_string exn))))

let with_observer_instance ~scope = function
  | `Assoc fields -> `Assoc (("observer_instance_id", `String (Server_observer_scope.instance_id scope))
      :: List.remove_assoc "observer_instance_id" fields)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as json -> json
;;

let dashboard_namespace_truth_for_scope ~state ~(scope : Mcp_server.workspace_scope) ~sw ~clock _request =
  let config = scope.config in
  let execution_cache = Execution_surfaces.execution_cache_for_scope ~state scope in
  (* Fast-path: if the proactive execution refresh hasn't produced a result
     yet, return "initializing" immediately instead of blocking for 15-20s
     on cold-start on-demand compute. The client retains its warm debt until
     the source worker or an actual HTTP fill publishes canonical completion.
     Initializing is not a successful read and needs no periodic HTTP retry. *)
  let warm_escape_s = namespace_truth_warm_escape_s in
  let proactive_first_cycle_pending =
    not (cached_surface_has_success execution_cache)
    &&
    match
      (Server_dashboard_http_cache.snapshot execution_cache)
        .last_attempt_unix
    with
    | None -> true
    | Some attempt_ts ->
        let elapsed = Time_compat.now () -. attempt_ts in
        elapsed < warm_escape_s
        && Option.is_none
             (Server_dashboard_http_cache.snapshot
                execution_cache)
               .last_error_unix
  in
  if proactive_first_cycle_pending then
    Namespace_truth_support.compose_namespace_truth_initializing ~config
      ~message:
        "Execution snapshot is still warming up. The dashboard will update when it is ready."
  else
    match last_good_shell_for_config ~state ~scope config with
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
        (* Namespace-truth fiber timeouts.  Cold start uses higher defaults to
           allow shell/namespace reads to warm up.  The values are the
           module-level [namespace_truth_*_timeout_s] bindings; see them for the
           rationale. *)
        let warm_timeout_s = namespace_truth_warm_timeout_s in
        let cold_timeout_s = namespace_truth_cold_timeout_s in
        let is_cold =
          not (cached_surface_has_success execution_cache)
        in
        let base_timeout_s = if is_cold then cold_timeout_s else warm_timeout_s in
        let fiber_with_timeout ?(timeout_s = base_timeout_s) label f fallback =
          try
            (* A fiber that finished as its window closed is the result, not
               the fallback. *)
            match
              Watched_work.run
                ~watcher:(fun () ->
                  Eio.Time.sleep clock timeout_s;
                  Error `Timeout)
                (fun () -> Ok (f ()))
            with
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
        let shell_fallback = cached_shell_json_for_namespace ~state ~scope ~config in
        (* Sequential fetch to avoid PG connection concurrent usage (#3305). *)
        shell_ref :=
          fiber_with_timeout ~timeout_s:shell_timeout_s "shell"
            (fun () -> dashboard_shell_http_json ~clock config)
            shell_fallback;
        execution_ref := cached_surface_json execution_cache;
        let shell_json = !shell_ref in
        (* Update last-known-good shell on success. *)
        if shell_json <> `Assoc [] && shell_json <> shell_fallback
           && not (Dashboard_cache.is_timeout_envelope shell_json) then
          Execution_surfaces.publish_shell_cache_success ~state ~scope ~light:false shell_json;
        let execution_json = !execution_ref in
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
        |> Server_dashboard_http_core_cache.with_projection_diagnostics
             ~surface:"namespace_truth" ~started_at
             ~extra:
               [
                 ("parallel_ms", `Int (int_of_float parallel_ms));
                 ( "execution_cache_state",
                   Json_util.string_opt_to_json execution_cache_state );
               ])
    | Some shell_json ->
        schedule_namespace_truth_shell_refresh ~state ~scope ~sw ~clock config;
        (* NDT-OK: projection diagnostics timestamp only; snapshot content comes
           from cached read models. *)
        let started_at = Unix.gettimeofday () in
        let execution_json = cached_surface_json execution_cache in
      let execution_cache_state =
        json_assoc_field "projection_diagnostics" execution_json
        |> json_string_field_opt "cache_state"
      in
      Namespace_truth_support.compose_namespace_truth_snapshot ~config
        ~initialized:(Workspace.is_initialized config)
        ~shell_json ~execution_json
      |> Server_dashboard_http_core_cache.with_projection_diagnostics
           ~surface:"namespace_truth" ~started_at
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

let dashboard_namespace_truth_http_json ~state ~sw ~clock request =
  let scope = Mcp_server.workspace_scope state in
  dashboard_namespace_truth_for_scope ~state ~scope ~sw ~clock request
  |> with_observer_instance ~scope
;;

(** Assemble a lightweight namespace-truth snapshot from cached refs only.
    No PG I/O — reads proactive caches for execution and command, and
    the TTL-cached shell. Returns None when the execution cache has not
    produced its first successful result (cold start). *)
type namespace_publication = {
  scope : Mcp_server.workspace_scope;
  cache : Server_dashboard_http_cache.cached_surface;
  execution_source : Server_dashboard_http_cache.surface_snapshot;
  shell_source : Yojson.Safe.t option;
  completion_revision : int;
  json : Yojson.Safe.t;
}

let namespace_publication_for_scope ~state (scope : Mcp_server.workspace_scope) =
  let cache = Execution_surfaces.execution_cache_for_scope ~state scope in
  let completion_revision = Execution_surfaces.namespace_cache_revision ~state scope in
  let execution_source = Server_dashboard_http_cache.snapshot cache in
  match execution_source.last_success_unix with
  | None -> None
  | Some _ ->
      let shell_source = Execution_surfaces.last_good_shell_for_scope ~state scope in
      let shell_json = match shell_source with
        | Some json when shell_json_matches_config ~config:scope.config json -> json
        | Some _ | None -> namespace_truth_bootstrap_shell_json () in
      let json = Namespace_truth_support.compose_namespace_truth_snapshot
          ~config:scope.config ~initialized:(Workspace.is_initialized scope.config)
          ~shell_json ~execution_json:execution_source.json
        |> with_observer_instance ~scope in
      Some {scope; cache; execution_source; shell_source; completion_revision; json}
;;

let namespace_publication_is_current ~state publication =
  Mcp_server.Workspace_scope_epoch.equal publication.scope.epoch
    (Mcp_server.workspace_scope state).epoch
  && publication.execution_source == Server_dashboard_http_cache.snapshot publication.cache
  && publication.shell_source == Execution_surfaces.last_good_shell_for_scope ~state publication.scope
  && publication.completion_revision = Execution_surfaces.namespace_cache_revision ~state publication.scope
;;

let namespace_truth_snapshot_from_caches state =
  let scope = Mcp_server.workspace_scope state in
  match namespace_publication_for_scope ~state scope with
  | Some publication when Mcp_server.Workspace_scope_epoch.equal scope.epoch
      (Mcp_server.workspace_scope state).epoch -> Some publication.json
  | Some _ | None -> None
;;

let last_namespace_truth_snapshot_hash : Agent_core_sha256.t option ref =
  ref None

let last_namespace_truth_scope : Mcp_server.Workspace_scope_epoch.t option ref = ref None

let namespace_truth_snapshot_hash_mu = Stdlib.Mutex.create ()
let last_namespace_truth_revision : int option ref = ref None
let last_namespace_truth_receipt : (Mcp_server.Workspace_scope_epoch.t * int) option ref = ref None

let hash_namespace_truth_snapshot (snapshot : Yojson.Safe.t) : Agent_core_sha256.t =
  (* Incremental SHA256 over the snapshot structure, skipping the volatile
     [generated_at]/[generated_at_iso] fields (they change every compose but
     must not trigger a broadcast). Replaces the prior normalize-copy +
     [Yojson.Safe.to_string] + [digest_string], which allocated a normalized
     Yojson tree AND a full serialized string on every broadcast check. This
     walks the structure once, feeding [Agent_core_sha256.feed_string] directly:
     one O(n) pass, no intermediate Yojson or string allocation.

     The hash value differs from the old string-hash (different bytes fed),
     but it is deterministic for a given structure and is used only for change
     detection (compare current to previous, both via this walker), so the
     broadcast semantics are preserved. Type tags (S/I/F/...) prevent prefix
     collisions between scalar kinds. *)
  let rec walk (ctx : Agent_core_sha256.ctx) (json : Yojson.Safe.t) :
      Agent_core_sha256.ctx =
    match json with
    | `Assoc fields ->
        let ctx = Agent_core_sha256.feed_string ctx "{" in
        let ctx =
          List.fold_left
            (fun ctx (key, value) ->
               if String.equal key "generated_at" || String.equal key "generated_at_iso"
               then ctx
               else
                 let ctx = Agent_core_sha256.feed_string ctx key in
                 let ctx = Agent_core_sha256.feed_string ctx ":" in
                 walk ctx value)
            ctx fields
        in
        Agent_core_sha256.feed_string ctx "}"
    | `List values ->
        let ctx = Agent_core_sha256.feed_string ctx "[" in
        let ctx = List.fold_left walk ctx values in
        Agent_core_sha256.feed_string ctx "]"
    | `String s ->
        (* Length-prefix variable-length string fields so distinct JSON
           payloads cannot collide in the hash stream (e.g. ["aS","b"] vs
           ["a","Sb"]). The exact separator format is internal to this hash. *)
        let ctx = Agent_core_sha256.feed_string ctx (Printf.sprintf "S%d:" (String.length s)) in
        Agent_core_sha256.feed_string ctx s
    | `Int n ->
        let ctx = Agent_core_sha256.feed_string ctx "I" in
        Agent_core_sha256.feed_string ctx (string_of_int n)
    | `Intlit s ->
        let ctx = Agent_core_sha256.feed_string ctx "L" in
        Agent_core_sha256.feed_string ctx s
    | `Float f ->
        let ctx = Agent_core_sha256.feed_string ctx "F" in
        Agent_core_sha256.feed_string ctx (string_of_float f)
    | `Bool b -> Agent_core_sha256.feed_string ctx (if b then "Bt" else "Bf")
    | `Null -> Agent_core_sha256.feed_string ctx "N"
  in
  Agent_core_sha256.get (walk Agent_core_sha256.empty snapshot)

let should_broadcast_namespace_truth_snapshot (snapshot : Yojson.Safe.t) =
  let hash = hash_namespace_truth_snapshot snapshot in
  Stdlib.Mutex.protect namespace_truth_snapshot_hash_mu (fun () ->
      match !last_namespace_truth_snapshot_hash with
      | Some prev when Agent_core_sha256.equal prev hash -> false
      | _ ->
          last_namespace_truth_snapshot_hash := Some hash;
          true)

(** Broadcast current namespace-truth snapshot to all Observer SSE sessions.
    Called after proactive cache refreshes and keeper lifecycle events.
    Safe to call from any fiber — reads only from cached refs. *)
let broadcast_namespace_truth_snapshot (state : Mcp_server.server_state) : unit =
  let scope = Mcp_server.workspace_scope state in
  let scope_is_current () = Mcp_server.Workspace_scope_epoch.equal scope.epoch
      (Mcp_server.workspace_scope state).epoch in
  match namespace_publication_for_scope ~state scope with
  | None -> ()
  | Some publication ->
      let snapshot = publication.json in
      let is_current () = scope_is_current () && namespace_publication_is_current ~state publication in
      let target = Sse.Scoped_runtime_observers (Sse.observer_scope
        ~runtime_authority:(Sse.runtime_authority_exn ~base_path:scope.config.base_path)
        ~instance_id:(Server_observer_scope.instance_id scope)) in
      let hash = hash_namespace_truth_snapshot snapshot in
      let changed = Stdlib.Mutex.protect namespace_truth_snapshot_hash_mu (fun () ->
        is_current () && not (
          Option.exists (Mcp_server.Workspace_scope_epoch.equal scope.epoch) !last_namespace_truth_scope
          && Option.exists (Agent_core_sha256.equal hash) !last_namespace_truth_snapshot_hash
          && !last_namespace_truth_revision = Some publication.completion_revision)) in
      if changed && is_current () then (
        let encoded = Sse_wire.encode_json (`Assoc ["type", `String "project_snapshot";
          "payload", snapshot; "ts_unix", `Float (Time_compat.now ())]) in
        let on_committed event_id =
          Stdlib.Mutex.protect namespace_truth_snapshot_hash_mu (fun () ->
            let newest = match !last_namespace_truth_receipt with
              | Some (epoch, previous) when Mcp_server.Workspace_scope_epoch.equal epoch scope.epoch ->
                  event_id > previous || Option.is_none !last_namespace_truth_snapshot_hash
              | Some _ | None -> true in
            if newest && is_current () then (
              last_namespace_truth_scope := Some scope.epoch;
              last_namespace_truth_snapshot_hash := Some hash;
              last_namespace_truth_revision := Some publication.completion_revision;
              last_namespace_truth_receipt := Some (scope.epoch, event_id)))
        in
        (* A failed replay insertion leaves completion owed. Advancing dedup
           before a receipt would turn the publisher's retry into a no-op. *)
        if is_current () then Sse.broadcast_encoded_to_with_receipts target
          ~on_fanout:(fun _ -> ()) ~on_committed encoded)

let () =
  Execution_surfaces.broadcast_namespace_truth_ref :=
    broadcast_namespace_truth_snapshot
