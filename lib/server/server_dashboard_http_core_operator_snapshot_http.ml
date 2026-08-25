(** Authoritative operator-snapshot HTTP projection.

    The default summary reads the current publication while it is fresh. A
    stale publication is synchronously recomputed and replaced before the
    response is returned. Parameterized requests are computed directly. Store
    or projection failures therefore cannot return an earlier approval row. *)

open Server_utils
open Server_auth
include Server_dashboard_http_cache

module Core_runtime = Server_dashboard_http_core_runtime
module Core_cache = Server_dashboard_http_core_cache
module Core_operator = Server_dashboard_http_core_operator
module Core_operator_query = Server_dashboard_http_core_operator_query

(* Constructors for [dashboard_compute_mode] (Inline_shared,
   Offloaded_readonly) — same constructor-scope trap as the refresh
   loop siblings (#17358/#17384) and the digest handler sibling (#17389). *)
open Server_dashboard_http_runtime_support

let operator_snapshot_http_json ~state ~sw ~clock ~broadcast_snapshot request =
  let workspace_scope = Mcp_server.workspace_scope state in
  let config = workspace_scope.config in
  let proc_mgr = state.Mcp_server.proc_mgr in
  let net, mono_clock = Core_runtime.state_dashboard_runtime_caps state in
  let actor =
    dashboard_actor_for_request ~base_path:config.base_path request
  in
  let view = query_param request "view" in
  let default_summary_request =
    actor = None
    && query_param request "include_messages" = None
    && query_param request "include_keepers" = None
    &&
    match view with
    | None -> true
    | Some raw -> String.equal (String.lowercase_ascii (String.trim raw)) "summary"
  in
  let compute_default_summary () =
    let started_at = Unix.gettimeofday () in
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
         Operator_control.snapshot_json
           ~actor:"dashboard"
           ~view:"summary"
           ~include_messages:true
           ~include_keepers:true
           ~include_summary_fields:false
           ~lightweight_summary:true
           ctx)
    |> Core_cache.with_projection_diagnostics
         ~surface:"operator_snapshot"
         ~started_at
         ~extra:(Core_operator.operator_snapshot_extra ())
    |> Core_operator_query.with_operator_snapshot_metadata
         ~config
         ~query:(Core_operator_query.operator_snapshot_default_query ())
  in
  if default_summary_request
  then (
    let attach
          (publication : Core_operator.operator_snapshot_publication)
      =
      Core_operator.operator_snapshot_publication_json publication
    in
    let current, is_fresh =
      Core_operator.operator_snapshot_publication_with_freshness ()
    in
    if is_fresh
    then attach current
    else (
      let compute = Core_operator.begin_operator_snapshot_compute () in
      try
        let json = compute_default_summary () in
        let publication =
          match Core_operator.publish_operator_snapshot_if_current ~compute json with
          | Some publication -> publication
          | None -> Core_operator.operator_snapshot_publication ()
        in
        attach publication
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        let publication =
          match Core_operator.mark_operator_snapshot_error_if_current ~compute exn with
          | Some publication ->
            broadcast_snapshot publication;
            publication
          | None -> Core_operator.operator_snapshot_publication ()
        in
        attach publication))
  else (
    let started_at = Unix.gettimeofday () in
    let include_messages =
      match query_param request "include_messages" with
      | Some ("0" | "false" | "no") -> false
      | _ -> true
    in
    let include_keepers =
      match query_param request "include_keepers" with
      | Some ("0" | "false" | "no") -> false
      | _ -> true
    in
    let lightweight_summary =
      match view with
      | Some raw -> String.equal (String.lowercase_ascii (String.trim raw)) "summary"
      | None -> false
    in
    let query =
      Core_operator_query.operator_snapshot_query_json
        ~actor
        ~view
        ~include_messages
        ~include_keepers
        ~lightweight_summary
        ~default_summary_request
    in
    let mode = if lightweight_summary then Inline_shared else Offloaded_readonly in
    let compute () =
      match
        Eio.Time.with_timeout clock Core_cache.dashboard_request_timeout_s (fun () ->
          Ok
            (Core_runtime.run_dashboard_compute
               ~mode
               ?net
               ?mono_clock
               ~sw
               ~clock
               ~config
               (fun ~config ~sw ->
                  let ctx : _ Operator_control.context =
                    { config
                    ; agent_name = Option.value ~default:"dashboard" actor
                    ; sw
                    ; clock
                    ; proc_mgr
                    ; net = state.Mcp_server.net
                    ; delegated_dispatch = None
                    ; mcp_session_id = None
                    }
                  in
                  Operator_control.snapshot_json
                    ?actor
                    ?view
                    ~include_messages
                    ~include_keepers
                    ~include_summary_fields:(not lightweight_summary)
                    ~lightweight_summary
                    ctx)))
      with
      | Ok json ->
        Core_cache.with_projection_diagnostics
          ~surface:"operator_snapshot"
          ~started_at
          ~extra:
            [ "readonly_pool", Workspace_utils.domain_local_pg_backend_diagnostics_json () ]
          json
      | Error `Timeout ->
        `Assoc
          [ "error", `String "timeout"
          ; "message", `String "Operator snapshot timed out after 30s"
         ; "generated_at", `String (Masc_domain.now_iso ())
         ]
    in
    compute ()
    |> Core_operator_query.with_operator_snapshot_metadata ~config ~query)
;;
