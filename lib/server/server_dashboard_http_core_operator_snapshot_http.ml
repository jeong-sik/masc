(** Operator-snapshot HTTP handler, extracted from
    [server_dashboard_http_core.ml] (godfile decomp).

    [operator_snapshot_http_json] is the GET handler backing the
    operator dashboard's snapshot surface. Two paths:

    1. **Default summary request** (no actor, no include_messages
       override, no include_keepers override; view omitted or
       "summary") — serves the cached `operator_snapshot_cache`
       surface via `cached_surface_or_first_success_json` with a 5s
       SWR window. Failures fall back through to a fresh compute
       under `Offloaded_readonly` mode.

    2. **Parameterized request** — on-demand compute with 5s SWR
       cache. Cache key is the colon-delimited concatenation of
       `actor | view | include_messages | include_keepers |
       lightweight_summary` so distinct query shapes are cached
       independently. The compute closure runs
       `Operator_control.snapshot_json` inside `run_dashboard_compute`
       (mode chosen by `lightweight_summary`: `Inline_shared` when
       lightweight, `Offloaded_readonly` otherwise) and decorates with
       `with_projection_diagnostics ~surface:"operator_snapshot"`.

    Timeout failures surface as `{error:"timeout", message:"Operator
    snapshot timed out after 30s", generated_at}` JSON.

    Pairs with `Server_dashboard_http_core_operator_digest_http`
    (#17389) for symmetric snapshot+digest handler extraction. *)

let standard_cache_ttl_s = Server_dashboard_http_core_cache.standard_cache_ttl_s

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

let operator_snapshot_http_json ~state ~sw ~clock request =
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
  in
  let default_cache_key =
    Core_cache.dashboard_cache_key config "operator_snapshot" "default-summary"
  in
  if default_summary_request
  then
    cached_surface_or_first_success_json
      Core_operator.operator_snapshot_cache
      ~cache_key:default_cache_key
      ~ttl:standard_cache_ttl_s
      ~clock
      ~timeout_sec:Core_cache.dashboard_request_timeout_s
      compute_default_summary
    |> Core_operator_query.with_operator_snapshot_metadata
         ~config
         ~cache_key:default_cache_key
         ~query:(Core_operator_query.operator_snapshot_default_query ())
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
    let cache_key =
      Printf.sprintf
        "operator_snapshot:param:%s|%s|%b|%b|%b"
        (Option.value ~default:"" actor)
        (Option.value ~default:"" view)
        include_messages
        include_keepers
        lightweight_summary
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
    (* Tier-A perf: parameterized [/api/v1/dashboard/operator/snapshot]
       requests previously bypassed the cache entirely — every keeper
       filter / actor view triggered a fresh [run_dashboard_compute]
       with a 30s timeout.  Under multi-tab dashboard load this was
       the single largest dashboard-side compute fan-out.  Wrap with
       a 5s SWR cache keyed on the full parameter tuple so rapid
       polling (Bond-Web 3s default) hits the cache; mutations
       continue to invalidate via the existing
       [Workspace_hooks.on_task_mutation_fn] path. *)
    Dashboard_cache.get_or_compute_with_timeout
      cache_key
      ~ttl:standard_cache_ttl_s
      ~clock
      ~timeout_sec:Core_cache.dashboard_request_timeout_s
      compute
    |> Core_operator_query.with_operator_snapshot_metadata ~config ~cache_key ~query)
;;
