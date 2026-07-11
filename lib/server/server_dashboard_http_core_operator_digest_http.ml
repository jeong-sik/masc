(** Operator-digest HTTP handler, extracted from
    [server_dashboard_http_core.ml] (godfile decomp).

    [operator_digest_http_json] is the GET handler backing the
    operator dashboard's digest surface. Two paths:

    1. **Default workspace request** (no actor, no target_id, no
       include_workers override, target_type omitted or [workspace]) — serves the cached
       [operator_digest_cache] surface immediately (0ms), decorated
       with the default query metadata.

    2. **Parameterized request** — computes on-demand with a 5s SWR
       cache. Cache key is the colon-delimited concatenation of
       [actor | effective_target_type | target_id | include_workers]
       so distinct query shapes are cached independently. The compute
       closure runs [Operator_control.digest_json] inside
       [run_dashboard_compute ~mode:Offloaded_readonly] and decorates
       with [with_projection_diagnostics ~surface:"operator_digest"].
       Validation errors are surfaced as `{error, message, generated_at}`
       JSON; the outer [Eio.Time.with_timeout] enforces
       [dashboard_request_timeout_s] and surfaces `Error \`Timeout`
       as `{error:"timeout", message:"Operator digest timed out
       after 30s", generated_at}`.

    Pure helper move (no callback injection). All references reach
    existing siblings or top-level libraries. *)

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
   loop siblings (#17358/#17384). *)
open Server_dashboard_http_runtime_support

let operator_digest_http_json ~state ~sw ~clock request =
  let config = (Mcp_server.workspace_config state) in
  let net, mono_clock = Core_runtime.state_dashboard_runtime_caps state in
  let actor =
    dashboard_actor_for_request ~base_path:config.base_path request
  in
  let target_type = query_param request "target_type" in
  let target_id = query_param request "target_id" in
  let include_workers =
    match query_param request "include_workers" with
    | Some ("0" | "false" | "no") -> Some false
    | Some ("1" | "true" | "yes") -> Some true
    | _ -> None
  in
  let workspace_target_type value =
    match Option.map (fun raw -> String.lowercase_ascii (String.trim raw)) value with
    | None -> true
    | Some raw ->
      (match Operator_action_constants.target_type_of_string raw with
       | Some Operator_action_constants.Workspace -> true
       | Some Operator_action_constants.Keeper
       | Some Operator_action_constants.Goal
       | None -> false)
  in
  let effective_target_type =
    Option.value
      ~default:Operator_action_constants.workspace_target_type
      target_type
  in
  let default_namespace_request =
    actor = None
    && target_id = None
    && include_workers = None
    && workspace_target_type target_type
  in
  let query =
    Core_operator_query.operator_digest_query_json
      ~actor
      ~target_type
      ~target_id
      ~include_workers
      ~effective_target_type
      ~default_namespace_request
  in
  if default_namespace_request
  then
    Ok
      (cached_surface_json Core_operator.operator_digest_cache
       |> Core_operator_query.with_operator_digest_metadata ~config ~query)
  else (
    let started_at = Unix.gettimeofday () in
    let cache_key =
      Printf.sprintf
        "operator_digest:param:%s|%s|%s|%s|%s"
        (Option.value ~default:"" actor)
        effective_target_type
        (Option.value ~default:"" target_id)
        (match include_workers with
         | None -> ""
         | Some true -> "1"
         | Some false -> "0")
        ""
    in
    let compute () =
      match
        Eio.Time.with_timeout clock Core_cache.dashboard_request_timeout_s (fun () ->
          Ok
            (Core_runtime.run_dashboard_compute
               ~mode:Offloaded_readonly
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
                    ; proc_mgr = state.Mcp_server.proc_mgr
                    ; net = state.Mcp_server.net
                    ; mcp_session_id = None
                    }
                  in
                  match
                    Operator_control.digest_json
                      ?actor
                      ~target_type:effective_target_type
                      ?target_id
                      ?include_workers
                      ctx
                  with
                  | Ok json -> json
                  | Error err ->
                    `Assoc
                      [ "error", `String "validation_error"
                      ; "message", `String err
                      ; "generated_at", `String (Masc_domain.now_iso ())
                      ])))
      with
      | Ok json ->
        Core_cache.with_projection_diagnostics
          ~surface:"operator_digest"
          ~started_at
          ~extra:
            [ "readonly_pool", Workspace_utils.domain_local_pg_backend_diagnostics_json () ]
          json
      | Error `Timeout ->
        `Assoc
          [ "error", `String "timeout"
          ; "message", `String "Operator digest timed out after 30s"
          ; "generated_at", `String (Masc_domain.now_iso ())
          ]
    in
    (* See [operator_snapshot_http_json] above for the parameterized-cache
       rationale.  Same 5s SWR window applies to operator/digest views. *)
    Ok
      (Dashboard_cache.get_or_compute_with_timeout
         cache_key
         ~ttl:standard_cache_ttl_s
         ~clock
         ~timeout_sec:Core_cache.dashboard_request_timeout_s
         compute
       |> Core_operator_query.with_operator_digest_metadata ~config ~cache_key ~query))
;;
