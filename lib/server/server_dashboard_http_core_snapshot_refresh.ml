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
  let default_cache_key generation =
    Core_cache.dashboard_cache_key
      config
      "operator_snapshot"
      (Printf.sprintf "default-summary:g%d" generation)
  in
  let compute () =
    let compute = Core_operator.begin_operator_snapshot_compute () in
    let started_at = Unix.gettimeofday () in
    let started_mono = Eio.Time.now clock in
    try
      let json =
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
             let t_snapshot = Eio.Time.now clock in
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
             let finished_mono = Eio.Time.now clock in
             let dt_snapshot = finished_mono -. t_snapshot in
             let dt_total = finished_mono -. started_mono in
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
                  ~extra:(Core_operator.operator_snapshot_extra ())
             |> Core_operator_query.with_operator_snapshot_metadata
                  ~config
                  ~cache_key:(default_cache_key compute.generation)
                  ~query:(Core_operator_query.operator_snapshot_default_query ()))
      in
      compute, json
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      (match
         Core_operator.mark_operator_snapshot_error_if_current
           ~compute
           exn
       with
       | None -> ()
       | Some publication ->
         !Core_operator.operator_snapshot_broadcast_ref publication);
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
      ; warm_delay_s = 120.0
      }
    ~compute
    ~on_result:(fun (compute, json) ->
      match
        Core_operator.publish_operator_snapshot_if_current ~compute json
      with
      | None -> ()
      | Some publication ->
        !Core_operator.operator_snapshot_broadcast_ref publication)
;;
