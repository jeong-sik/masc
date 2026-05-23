(** Dashboard HTTP compute-runtime bindings, extracted from
    [server_dashboard_http_core.ml]. Provides the
    [set_executor_pool] alias, [dashboard_runtime] constructor,
    the [run_dashboard_compute] dispatch wrapper, and the
    [state_dashboard_runtime_caps] state-decomposer. *)

open Server_dashboard_http_runtime_support

(** Executor pool for CPU-heavy dashboard compute.
    Pool reference is shared via [Executor_pool_ref] in masc_core. *)
let set_executor_pool = Server_dashboard_http_runtime_support.set_executor_pool

let dashboard_runtime ?net ?mono_clock (config : Coord.config)
  : Server_dashboard_http_runtime_support.runtime option
  =
  let _ = config in
  match net, mono_clock with
  | Some net, Some mono_clock -> Some { net; mono_clock }
  | Some _, None | None, Some _ | None, None -> None
;;

let run_dashboard_compute
      ?(mode = Offloaded_readonly)
      ?net
      ?mono_clock
      ~sw
      ~clock
      ~(config : Coord.config)
      compute
  =
  let runtime = dashboard_runtime ?net ?mono_clock config in
  Server_dashboard_http_runtime_support.run_dashboard_compute
    ~mode
    ?runtime
    ~sw
    ~clock
    ~config
    compute
;;

let state_dashboard_runtime_caps (state : Mcp_server.server_state) =
  state.Mcp_server.net, state.Mcp_server.mono_clock
;;
