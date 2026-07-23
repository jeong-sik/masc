(** Operator-digest proactive refresh loop, extracted from
    [server_dashboard_http_core.ml] (godfile decomp). Pairs with the
    snapshot refresh sibling (#17358).

    [start_operator_digest_refresh_loop] wires the cached
    [operator_digest] surface into [Proactive_refresh.start] with the
    dashboard runtime's offloaded-readonly compute path. Each cycle
    invokes [Operator_control.digest_json ~actor:"dashboard"
    ~target_type:"workspace"] under a fresh [Operator_control.context],
    decorates the result with [with_projection_diagnostics] /
    [with_operator_digest_metadata], and republishes via
    [!operator_digest_broadcast_ref].

    Pure helper move (no callback injection). All cross-module
    references reach existing siblings or top-level libraries — no
    sibling -> parent dependency.

    The digest path differs from the snapshot path in two ways:
    - [Operator_control.digest_json] returns [Result.t]; an [Error]
      becomes [invalid_arg ...] inside the compute closure (preserves
      the original behavior where Proactive_refresh sees an exception).
    - [warm_delay_s = 150.0] (vs 120.0 for snapshot) — digest is
      heavier and starts later so it does not race the snapshot's
      first warm-up. *)

include Server_dashboard_http_cache
(* Constructors for [dashboard_compute_mode] (Inline_shared,
   Offloaded_readonly) live in the runtime-support sibling.  Same
   constructor-scope trap as the snapshot sibling (#17358): even
   though the parent re-exports the type as a transparent alias, the
   constructors are scoped to the defining module and need an [open]
   here. *)
open Server_dashboard_http_runtime_support

module Core_runtime = Server_dashboard_http_core_runtime
module Core_cache = Server_dashboard_http_core_cache
module Core_operator = Server_dashboard_http_core_operator
module Core_operator_query = Server_dashboard_http_core_operator_query

let start_operator_digest_refresh_loop ~state ~sw ~clock =
  let workspace_scope = Mcp_server.workspace_scope state in
  let config = workspace_scope.config in
  let proc_mgr = state.Mcp_server.proc_mgr in
  let net, mono_clock = Core_runtime.state_dashboard_runtime_caps state in
  let compute () =
    mark_cached_surface_attempt Core_operator.operator_digest_cache;
    let started_at = Unix.gettimeofday () in
    try
      Core_runtime.run_dashboard_compute
        ~mode:Offloaded_readonly
        ?net
        ?mono_clock
        ~sw
        ~clock
        ~config
        (fun ~config ~sw ->
           let ctx : _ Operator_control.context =
             { config
             ; agent_name = "dashboard"
             ; sw
             ; clock
             ; proc_mgr
             ; net = None
             ; delegated_dispatch = None
             ; mcp_session_id = None
             }
           in
           match
             Operator_control.digest_json ~actor:"dashboard" ~target_type:"workspace" ctx
           with
           | Ok json ->
             Core_cache.with_projection_diagnostics
               ~surface:"operator_digest"
               ~started_at
               ~extra:(Core_operator.operator_snapshot_extra ())
               json
           | Error err ->
             invalid_arg ("server_dashboard_http_core: operator digest failed: " ^ err))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      mark_cached_surface_error Core_operator.operator_digest_cache exn;
      raise exn
  in
  Proactive_refresh.start
    ~sw
    ~clock
    ~config:
      { (Proactive_refresh.default_config
           ~label:"operator_digest"
           ~interval_s:Core_operator.operator_refresh_interval_s)
        with
        timeout_s = Core_operator.operator_refresh_interval_s *. 0.8
      ; on_error = Some (mark_cached_surface_error Core_operator.operator_digest_cache)
      ; warm_delay_s = 150.0
      }
    ~compute
    ~on_result:(fun json ->
      mark_cached_surface_success Core_operator.operator_digest_cache json;
      !Core_operator.operator_digest_broadcast_ref
        (cached_surface_json Core_operator.operator_digest_cache
         |> Core_operator_query.with_operator_digest_metadata
              ~config
              ~query:(Core_operator_query.operator_digest_default_query ())))
;;
