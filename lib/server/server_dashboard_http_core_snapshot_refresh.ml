(** Operator-snapshot proactive refresh loop, extracted from
    [server_dashboard_http_core.ml] (godfile decomp).

    [start_operator_snapshot_refresh_loop] wires the cached
    [operator_snapshot] surface into [Proactive_refresh.start] with
    the dashboard runtime's offloaded-readonly compute path. Each
    cycle invokes [Operator_control.snapshot_json] under a fresh
    [Operator_control.context], decorates the result with
    [with_projection_diagnostics] / [with_operator_snapshot_metadata],
    and republishes via [!operator_snapshot_broadcast_ref].

    Pure helper move (no callback injection). All cross-module
    references reach existing siblings or top-level libraries — no
    sibling -> parent dependency. *)

include Server_dashboard_http_cache
(* Constructors for [dashboard_compute_mode] (Inline_shared,
   Offloaded_readonly) live in the runtime-support sibling.  Without
   this [open], the [Offloaded_readonly] tag below is unbound — even
   though [server_dashboard_http_core.ml] re-exports the type as a
   transparent alias, the constructors are scoped to the defining
   module. *)
open Server_dashboard_http_runtime_support

module Core_runtime = Server_dashboard_http_core_runtime
module Core_cache = Server_dashboard_http_core_cache
module Core_operator = Server_dashboard_http_core_operator
module Core_operator_query = Server_dashboard_http_core_operator_query

let start_operator_snapshot_refresh_loop ~state ~sw ~clock =
  let workspace_scope = Mcp_server.workspace_scope state in
  let config = workspace_scope.config in
  let proc_mgr = state.Mcp_server.proc_mgr in
  let net, mono_clock = Core_runtime.state_dashboard_runtime_caps state in
  let compute () =
    mark_cached_surface_attempt Core_operator.operator_snapshot_cache;
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
           let t_snapshot = Unix.gettimeofday () in
           let json =
             Operator_control.snapshot_json
               ~actor:"dashboard"
               ~view:"summary"
               ~include_messages:true
               ~include_keepers:true
               ~include_summary_fields:false
               ~lightweight_summary:true
               ctx
           in
           let dt_snapshot = Unix.gettimeofday () -. t_snapshot in
           let dt_total = Unix.gettimeofday () -. started_at in
           if dt_total >= 5.0
           then
             Log.Dashboard.warn
               "[operator_snapshot profile] total=%.1fs snapshot=%.1fs"
               dt_total
               dt_snapshot;
           json
           |> Core_cache.with_projection_diagnostics
                ~surface:"operator_snapshot"
                ~started_at
                ~extra:(Core_operator.operator_snapshot_extra ()))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      mark_cached_surface_error Core_operator.operator_snapshot_cache exn;
      raise exn
  in
  Proactive_refresh.start
    ~sw
    ~clock
    ~config:
      { (Proactive_refresh.default_config
           ~label:"operator_snapshot"
           ~interval_s:Core_operator.operator_refresh_interval_s)
        with
        timeout_s = Core_operator.operator_refresh_interval_s *. 0.8
      ; on_error = Some (mark_cached_surface_error Core_operator.operator_snapshot_cache)
      ; warm_delay_s = 120.0
      }
    ~compute
    ~on_result:(fun json ->
      mark_cached_surface_success Core_operator.operator_snapshot_cache json;
      !Core_operator.operator_snapshot_broadcast_ref
        (cached_surface_json Core_operator.operator_snapshot_cache
         |> Core_operator_query.with_operator_snapshot_metadata
              ~config
              ~query:(Core_operator_query.operator_snapshot_default_query ())))
;;
