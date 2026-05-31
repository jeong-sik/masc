(** Runtime_oas_runner — Eio context, runtime resolution, runtime MCP policy.

    Extracted from oas_worker_named.ml (God file decomposition).
    Provides runtime profile defaults, Eio context validation,
    provider resolution, and tool-support filtering.

    @since God file decomposition *)

(* Runtime profile defaults (moved from Runtime module) *)

let default_config_path = Runtime.config_path

let default_model_strings ~runtime_id =
  Provider_runtime_projection.default_execution_model_strings runtime_id

(* Named model execution *)

let require_eio ?sw ?net () =
  let sw =
    match sw with
    | Some s -> Some s
    | None -> Eio_context.get_switch_opt ()
  in
  let net =
    match net with
    | Some n -> Some n
    | None -> Eio_context.get_net_opt ()
  in
  match sw, net with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

let eio_context_error_to_sdk_error detail =
  Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field = "eio_context"; detail })

let runtime_catalog_error_to_sdk_error detail =
  Agent_sdk.Error.Config
    (Agent_sdk.Error.InvalidConfig { field = "runtime_id"; detail })

(** Resolve runtime provider configs via MASC Runtime_config.
    Returns Provider_config.t list for the downstream OAS runtime,
    bypassing the old Model_spec facade. *)
let resolve_runtime_providers
      ?provider_filter:_
      ?(require_tool_choice_support = false)
      ?(require_tool_support = false)
      ?runtime_mcp_policy
      ~runtime_id:_
      ()
  =
  (* RFC-0206 single-binding: runtime catalog resolution removed. The providers
     are the default runtime's single provider_config, passed through the same
     required tool-use gate so require_tool_support is honored (a non-tool
     default is filtered out, not silently used). [provider_filter] is moot with
     one provider. *)
  match Runtime.get_default_runtime () with
  | None -> Error "no default runtime configured"
  | Some rt ->
    Ok
      (Provider_tool_support.apply_required_tool_use_filter
         ?runtime_mcp_policy
         ~require_tool_choice_support
         ~require_tool_support
         ~label:rt.Runtime.id
         [ rt.Runtime.provider_config ])

let keeper_agent_name_opt (keeper_name : string) =
  let keeper_name = String.trim keeper_name in
  if keeper_name = "" then None else Some (Keeper_identity.keeper_agent_name keeper_name)

let runtime_mcp_policy_for_tools ~(keeper_name : string) (tools : Agent_sdk.Tool.t list) =
  let agent_name = keeper_agent_name_opt keeper_name in
  let runtime_tool_names =
    tools
    |> List.filter (fun (tool : Agent_sdk.Tool.t) ->
      Tool_catalog.is_public_mcp tool.schema.name
      || (Option.is_some agent_name
          && Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool.schema.name))
    |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
  in
  let has_keeper_internal =
    List.exists
      (Tool_catalog.is_on_surface Tool_catalog.Keeper_internal)
      runtime_tool_names
  in
  match
    ( Runtime_agent.runtime_mcp_policy_of_tool_names
        ?agent_name
        ~allow_keeper_internal:has_keeper_internal
        runtime_tool_names
    , agent_name )
  with
  | Some policy, Some agent_name ->
    Some (Runtime_agent.runtime_mcp_policy_with_masc_agent_name ~agent_name policy)
  | Some policy, None -> Some policy
  | None, _ -> None

let keeper_internal_tool_names_for_runtime_surface
      ~(keeper_name : string)
      (tools : Agent_sdk.Tool.t list)
  =
  match keeper_agent_name_opt keeper_name with
  | None -> []
  | Some _ ->
    tools
    |> List.filter (fun (tool : Agent_sdk.Tool.t) ->
      Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool.schema.name)
    |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
    |> List.sort_uniq String.compare

let keeper_internal_tools_require_materialized_runtime_surface
      ~(keeper_name : string)
      (tools : Agent_sdk.Tool.t list)
  =
  keeper_internal_tool_names_for_runtime_surface ~keeper_name tools <> []

let runtime_mcp_policy_for_provider
      ~(keeper_name : string)
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option)
  =
  let agent_name = keeper_agent_name_opt keeper_name |> Option.value ~default:"" in
  Runtime_agent.runtime_mcp_policy_for_provider ~provider_cfg ~agent_name policy_opt

let cli_tool_a_cannot_carry_keeper_bound_runtime_mcp
      ~(keeper_name : string)
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option)
  =
  (* RFC-0058 §2.4: dispatch by local tool-delivery policy, not provider name. *)
  if
    not
      (Provider_tool_support
       .provider_requires_per_keeper_bridging_for_bound_actor_tools
         provider_cfg)
  then false
  else (
    match keeper_agent_name_opt keeper_name, policy_opt with
    | Some agent_name, Some policy
      when Option.is_some (Keeper_identity.keeper_name_from_agent_name agent_name) ->
      (not
         (Runtime_agent.cli_tool_a_can_auth_keeper_bound_runtime_mcp ~agent_name policy))
      && List.exists
           Runtime_agent.runtime_mcp_tool_requires_bound_actor
           policy.allowed_tool_names
    | _ -> false)

(* #10681: per-provider rejection reason produced by the runtime filter.
   When the filter empties the runtime, operators previously saw only a
   flat list of provider names; root-cause classification required
   re-running each predicate by hand. The reason is now attached to the
   provider in the WARN log so the next [no_tool_capable_provider] event
   pinpoints the failing check on the first read.

   Order of preference (mirrors the filter's short-circuit):
   0. [Capability_profile_mismatch profile] — the provider's declared
      capabilities do not satisfy the profile's
      [required_capability_profile] (e.g. [tool_strict] requiring
      [runtime_mcp_tools], [runtime_tool_events], [runtime_mcp_http_headers]).
   1. [Codex_keeper_bound_actor_required] — cli_tool_a cannot carry a
      runtime MCP policy that requires bound-actor tools (keeper-scoped).
   2. [Tool_lane_unsupported] — [resolve_tool_lane_for_oas_tools]
      returned [Error], typically transport/auth/capability mismatch
      surfaced by [Runtime_agent].
   3. [Required_tool_use { reason }] — the inline-tool-choice / runtime
      MCP capability gate from [Provider_tool_support]. Re-uses the
      existing [rejection_reason] so dashboards stay consistent with
      [masc_runtime_filter_rejection_total]. *)
type filter_rejection_reason =
  | Capability_profile_mismatch of string
  | Codex_keeper_bound_actor_required
  | Tool_lane_unsupported
  | Required_tool_use of Provider_tool_support.rejection_reason

let filter_rejection_reason_label = function
  | Capability_profile_mismatch profile ->
    Printf.sprintf "capability_profile_mismatch:%s" profile
  | Codex_keeper_bound_actor_required -> "codex_keeper_bound_actor_required"
  | Tool_lane_unsupported -> "tool_lane_unsupported"
  | Required_tool_use r -> Provider_tool_support.rejection_reason_label r

let codex_keeper_bound_skip_seen : (string, float) Hashtbl.t = Hashtbl.create 16
let codex_keeper_bound_skip_seen_mutex = Mutex.create ()
let codex_keeper_bound_skip_restate_sec = Masc_time_constants.hour

let codex_keeper_bound_skip_should_emit ~label ~provider_label ~keeper_name ~reason_label =
  let key = Printf.sprintf "%s|%s|%s|%s" label provider_label keeper_name reason_label in
  let now = Unix.gettimeofday () in
  Mutex.lock codex_keeper_bound_skip_seen_mutex;
  let first =
    match Hashtbl.find_opt codex_keeper_bound_skip_seen key with
    | None -> true
    | Some last -> now -. last >= codex_keeper_bound_skip_restate_sec
  in
  if first then Hashtbl.replace codex_keeper_bound_skip_seen key now;
  Mutex.unlock codex_keeper_bound_skip_seen_mutex;
  first

let codex_keeper_bound_skip_log_message ~label ~keeper_name provider_cfg reason =
  match reason with
  | Codex_keeper_bound_actor_required ->
    Some
      (Printf.sprintf
         "runtime %s: skipped provider=%s for keeper=%s reason=%s"
         label
         (Provider_tool_support.provider_debug_label provider_cfg)
         keeper_name
         (filter_rejection_reason_label reason))
  | Capability_profile_mismatch _ | Tool_lane_unsupported | Required_tool_use _ -> None

let log_codex_keeper_bound_skip ~label ~keeper_name provider_cfg reason =
  match codex_keeper_bound_skip_log_message ~label ~keeper_name provider_cfg reason with
  | None -> ()
  | Some message ->
    let provider_label = Provider_tool_support.provider_debug_label provider_cfg in
    let reason_label = filter_rejection_reason_label reason in
    if
      codex_keeper_bound_skip_should_emit
        ~label
        ~provider_label
        ~keeper_name
        ~reason_label
    then
      Log.Misc.info
        "%s; repeated identical skip decisions demoted to DEBUG for the next %.0fs"
        message
        codex_keeper_bound_skip_restate_sec
    else Log.Misc.debug "%s" message

let classify_filter_rejection
      ~(keeper_name : string)
      ?runtime_mcp_policy
      ?(tools = [])
      ?required_capability_profile
      ~require_tool_choice_support
      ~require_tool_support
      (provider_cfg : Llm_provider.Provider_config.t)
  : filter_rejection_reason option
  =
  let profile_mismatch =
    match required_capability_profile with
    | None -> None
    | Some _profile -> None
  in
  match profile_mismatch with
  | Some _ -> profile_mismatch
  | None ->
    if
      cli_tool_a_cannot_carry_keeper_bound_runtime_mcp
        ~keeper_name
        ~provider_cfg
        runtime_mcp_policy
    then Some Codex_keeper_bound_actor_required
    else (
      let normalized_runtime_mcp_policy =
        runtime_mcp_policy_for_provider ~keeper_name ~provider_cfg runtime_mcp_policy
      in
      let tool_lane_supported =
        match tools with
        | [] -> true
        | _ ->
          (match
             Runtime_agent.resolve_tool_lane_for_oas_tools
               ?agent_name:(keeper_agent_name_opt keeper_name)
               ~tool_requirement:
                 (if require_tool_choice_support || require_tool_support
                  then `Required
                  else `Optional)
               ~provider_cfg
               ~tools
               ()
           with
           | Ok _ -> true
           | Error _ -> false)
      in
      if not tool_lane_supported
      then Some Tool_lane_unsupported
      else (
        match
          Provider_tool_support.classify_rejection
            ?runtime_mcp_policy:normalized_runtime_mcp_policy
            ~require_tool_choice_support
            ~require_tool_support
            provider_cfg
        with
        | Some reason -> Some (Required_tool_use reason)
        | None -> None))

(* #11060: runtime-empty WARN dedupe.

   When the tool-use gate empties a runtime (every configured
   provider rejected — e.g. [keeper_unified] with only [cli_tool_a]
   providers under a keeper-bound runtime MCP policy), the WARN
   fires once per filtering invocation. Field log: 18 identical
   WARN events / 49 min for a single misconfigured runtime — the
   genuine signal (operator must edit keeper_runtime.toml) drowns in its
   own repeats and shares the WARN level with normal degraded-mode
   noise.

   This dedupe boosts the first occurrence per
   [(label, rejection_signature)] to ERROR with an operator-action
   hint, and demotes subsequent identical signatures to DEBUG. The
   one-hour [restate_sec] period re-emits the ERROR if the
   misconfiguration persists, so an operator who missed the first
   alert still sees the gap. The signature is sorted so the same
   rejection set in different argument order does not bypass the
   cache. *)
let runtime_empty_warn_seen : (string, float) Hashtbl.t = Hashtbl.create 16
let runtime_empty_warn_seen_mutex = Mutex.create ()
let runtime_empty_warn_restate_sec = Masc_time_constants.hour

let signature_of_rejected_providers rejected =
  rejected
  |> List.map (fun (cfg, reason) ->
    Printf.sprintf
      "%s:%s"
      (Provider_tool_support.provider_debug_label cfg)
      (filter_rejection_reason_label reason))
  |> List.sort String.compare
  |> String.concat ","

let runtime_empty_should_emit_first ~label ~signature =
  let key = label ^ "|" ^ signature in
  let now = Unix.gettimeofday () in
  Mutex.lock runtime_empty_warn_seen_mutex;
  let first =
    match Hashtbl.find_opt runtime_empty_warn_seen key with
    | None -> true
    | Some last -> now -. last >= runtime_empty_warn_restate_sec
  in
  if first then Hashtbl.replace runtime_empty_warn_seen key now;
  Mutex.unlock runtime_empty_warn_seen_mutex;
  first

(** RFC-0027 PR-9b dual-track swap. When the tool-use gate rejects a
    primary provider and the caller supplied a [secondary_resolver],
    invoke it to obtain a candidate fallback provider. The fallback is
    re-classified through the same gate; on pass it replaces the primary
    in [kept], on failure (or when no secondary is configured) the
    primary stays in [rejected].

    Observability:
    - Successful swap -> [emit_fallback_triggered ~kind:"dual_track_swap" ~detail:"swapped"]
    - Secondary also rejected -> [emit_fallback_triggered ~kind:"dual_track_swap" ~detail:"<secondary_reason>"]
    - No secondary configured -> no extra metric (the caller's existing
      [runtime_empty:<reason>] capability_drop already covers this case).
    The function is total and never raises; secondary parsing errors are
    surfaced as [None] by the resolver. *)
let attempt_secondary_swap
      ~keeper_name
      ?runtime_mcp_policy
      ?required_capability_profile
      ~tools
      ~require_tool_choice_support
      ~require_tool_support
      ~(secondary_resolver :
         int -> Llm_provider.Provider_config.t -> Llm_provider.Provider_config.t option)
      ~(provider_index : int)
      (primary, primary_reason)
  : ( Llm_provider.Provider_config.t
      , Llm_provider.Provider_config.t * filter_rejection_reason )
      Either.t
  =
  match secondary_resolver provider_index primary with
  | None -> Either.Right (primary, primary_reason)
  | Some secondary ->
    (* RFC-0027 PR-9c: per-secondary accounting label. The secondary's
       [provider_kind] is a closed enum from
       [Llm_provider.Provider_config.string_of_provider_kind], so label
       cardinality stays bounded without putting concrete model ids on the
       metric axis. *)
    let secondary_kind_label =
      Llm_provider.Provider_config.string_of_provider_kind secondary.kind
    in
    (match
       classify_filter_rejection
         ~keeper_name
         ?runtime_mcp_policy
         ?required_capability_profile
         ~tools
         ~require_tool_choice_support
         ~require_tool_support
         secondary
     with
     | None ->
       Llm_metric_bridge.emit_fallback_triggered
         ~kind:"dual_track_swap"
         ~detail:(Printf.sprintf "swapped:%s" secondary_kind_label);
       Either.Left secondary
     | Some secondary_reason ->
       (* Both primary and secondary rejected: keep the primary in
             rejected so the runtime-empty WARN signature stays anchored
             on the user-declared model. The secondary's rejection is
             surfaced as a separate metric so operators can audit which
             dual-track entries are uselessly configured. The kind label
             rides on the rejection detail too, so the same
             [secondary_kind] series is queryable across swap success /
             swap failure outcomes. *)
       Llm_metric_bridge.emit_fallback_triggered
         ~kind:"dual_track_swap"
         ~detail:
           (Printf.sprintf
              "rejected:%s:%s"
              secondary_kind_label
              (filter_rejection_reason_label secondary_reason));
       Either.Right (primary, primary_reason))

let filter_candidate_providers_for_tool_support
      ~(keeper_name : string)
      ?runtime_mcp_policy
      ?(tools = [])
      ~require_tool_choice_support
      ~require_tool_support
      ?required_capability_profile
      ?secondary_resolver
      ~label
      (provider_cfgs : Llm_provider.Provider_config.t list)
  =
  if (not require_tool_choice_support) && not require_tool_support
     && Option.is_none required_capability_profile
  then provider_cfgs
  else (
    let kept_rev, rejected_rev, _ =
      List.fold_left
        (fun (kept, rejected, provider_index) provider_cfg ->
           match
             classify_filter_rejection
               ~keeper_name
               ?runtime_mcp_policy
               ?required_capability_profile
               ~tools
               ~require_tool_choice_support
               ~require_tool_support
               provider_cfg
           with
           | None -> provider_cfg :: kept, rejected, provider_index + 1
           | Some reason ->
             log_codex_keeper_bound_skip ~label ~keeper_name provider_cfg reason;
             let swap =
               match secondary_resolver with
               | None -> Either.Right (provider_cfg, reason)
               | Some resolver ->
                 attempt_secondary_swap
                   ~keeper_name
                   ?runtime_mcp_policy
                   ?required_capability_profile
                   ~tools
                   ~require_tool_choice_support
                   ~require_tool_support
                   ~secondary_resolver:resolver
                   ~provider_index
                   (provider_cfg, reason)
             in
             (match swap with
              | Either.Left secondary -> secondary :: kept, rejected, provider_index + 1
              | Either.Right rejected_provider ->
                kept, rejected_provider :: rejected, provider_index + 1))
        ([], [], 0)
        provider_cfgs
    in
    let kept = List.rev kept_rev in
    let rejected = List.rev rejected_rev in
    if kept = [] && provider_cfgs <> []
    then (
      let signature = signature_of_rejected_providers rejected in
      (* Forward each rejection to the Prometheus capability_drop counter so
         operators can alert on runtime-empty silently dropping requests.
         The WARN log below describes the systemic cause; the per-rejection
         metric records every provider lost so dashboards can attribute
         which provider/reason combination drove the drop. *)
      List.iter
        (fun (provider_cfg, reason) ->
           let reason_label = filter_rejection_reason_label reason in
           Llm_metric_bridge.emit_capability_drop
             ~model_id:provider_cfg.Llm_provider.Provider_config.model_id
             ~field:(Printf.sprintf "runtime_empty:%s" reason_label);
           (* §7.3.2 Zero Silent Failure: also feed the unified
             fallback counter so the dashboard panel sees a single
             numerator across all fallback classes. *)
           Llm_metric_bridge.emit_fallback_triggered
             ~kind:"runtime_empty"
             ~detail:reason_label)
        rejected;
      if runtime_empty_should_emit_first ~label ~signature
      then
        Log.Misc.error
          "[#11060/#11356] runtime %s: provider-normalized tool-use gate removed all \
           providers (rejections=[%s]) — operator action: edit keeper_runtime.toml so \
           this runtime has at least one candidate whose declared capabilities satisfy \
           the required tool-use gate, or relax the keeper's required tool surface. \
           Required gate accepts inline tool_choice support or a compatible runtime-MCP \
           lane. Alternatively detach the keeper from this runtime. Subsequent \
           identical-signature rejections demoted to DEBUG for the next %.0fs"
          label
          signature
          runtime_empty_warn_restate_sec
      else
        Log.Misc.debug
          "[#11060] runtime %s: repeated all-providers-rejected (rejections=[%s])"
          label
          signature);
    kept)
