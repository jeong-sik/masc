(** Oas_worker_named_cascade — Eio context, cascade resolution, runtime MCP policy.

    Extracted from oas_worker_named.ml (God file decomposition).
    Provides cascade profile defaults, Eio context validation,
    provider resolution, tool-support filtering, and cross-cascade fallback.

    @since God file decomposition *)

(* Cascade profile defaults (moved from Cascade module) *)

let default_config_path = Cascade_runtime.cascade_config_path
let default_model_strings ~cascade_name =
  Cascade_runtime.default_model_strings
    ~cascade_name:(Keeper_cascade_profile.Runtime_name cascade_name)

(* Named model execution *)

let require_eio ?sw ?net () =
  let sw = match sw with Some s -> Some s | None -> Eio_context.get_switch_opt () in
  let net = match net with Some n -> Some n | None -> Eio_context.get_net_opt () in
  match sw, net with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

let eio_context_error_to_sdk_error detail =
  Agent_sdk.Error.Config
    (Agent_sdk.Error.InvalidConfig { field = "eio_context"; detail })

let cascade_catalog_error_to_sdk_error detail =
  Agent_sdk.Error.Config
    (Agent_sdk.Error.InvalidConfig { field = "cascade_name"; detail })

(** Resolve cascade provider configs via MASC Cascade_config.
    Returns Provider_config.t list for the downstream OAS runtime,
    bypassing the old Model_spec facade. *)
let resolve_cascade_providers ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ?runtime_mcp_policy
    ~cascade_name () =
  Cascade_runtime.resolve_named_providers_result_strict ?provider_filter
    ?runtime_mcp_policy
    ~require_tool_choice_support ~require_tool_support ~cascade_name ()

(** Resolve from an explicit model string list (user-declared in keeper TOML).
    MASC parses the strings via its local [Cascade_config] and passes the
    resulting provider configs into OAS execution. *)
let resolve_providers_from_model_strings ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ?runtime_mcp_policy
    model_strings =
  Cascade_runtime.resolve_providers_from_model_strings ?provider_filter
    ?runtime_mcp_policy
    ~require_tool_choice_support ~require_tool_support model_strings

let keeper_agent_name_opt (keeper_name : string) =
  let keeper_name = String.trim keeper_name in
  if keeper_name = "" then None
  else Some (Keeper_types.keeper_agent_name keeper_name)

let runtime_mcp_policy_for_tools ~(keeper_name : string) (tools : Agent_sdk.Tool.t list)
    =
  let agent_name = keeper_agent_name_opt keeper_name in
  let runtime_tool_names =
    tools
    |> List.filter (fun (tool : Agent_sdk.Tool.t) ->
           Tool_catalog.is_public_mcp tool.schema.name
           ||
           (Option.is_some agent_name
            && Tool_catalog.is_on_surface Tool_catalog.Keeper_internal
                 tool.schema.name))
    |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
  in
  let has_keeper_internal =
    List.exists
      (Tool_catalog.is_on_surface Tool_catalog.Keeper_internal)
      runtime_tool_names
  in
  match
    Oas_worker_exec.runtime_mcp_policy_of_tool_names
      ?agent_name
      ~allow_keeper_internal:has_keeper_internal runtime_tool_names,
    agent_name
  with
  | Some policy, Some agent_name ->
      Some
        (Oas_worker_exec.runtime_mcp_policy_with_masc_agent_name
           ~agent_name policy)
  | Some policy, None -> Some policy
  | None, _ -> None

let runtime_mcp_policy_for_provider
    ~(keeper_name : string)
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option) =
  let agent_name =
    keeper_agent_name_opt keeper_name |> Option.value ~default:""
  in
  Oas_worker_exec.runtime_mcp_policy_for_provider
    ~provider_cfg ~agent_name policy_opt

let codex_cli_cannot_carry_keeper_bound_runtime_mcp
    ~(keeper_name : string)
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option) =
  match provider_cfg.kind, keeper_agent_name_opt keeper_name, policy_opt with
  | Llm_provider.Provider_config.Codex_cli, Some agent_name, Some policy
    when Option.is_some (Keeper_identity.keeper_name_from_agent_name agent_name)
    ->
      List.exists Oas_worker_exec.runtime_mcp_tool_requires_bound_actor
        policy.allowed_tool_names
  | _ -> false

(* #10681: per-provider rejection reason produced by the cascade filter.
   When the filter empties the cascade, operators previously saw only a
   flat list of provider names; root-cause classification required
   re-running each predicate by hand. The reason is now attached to the
   provider in the WARN log so the next [no_tool_capable_provider] event
   pinpoints the failing check on the first read.

   Order of preference (mirrors the filter's short-circuit):
   1. [Codex_keeper_bound_actor_required] — codex_cli cannot carry a
      runtime MCP policy that requires bound-actor tools (keeper-scoped).
   2. [Tool_lane_unsupported] — [resolve_tool_lane_for_oas_tools]
      returned [Error], typically transport/auth/capability mismatch
      surfaced by [Oas_worker_exec].
   3. [Required_tool_use { reason }] — the inline-tool-choice / runtime
      MCP capability gate from [Provider_tool_support]. Re-uses the
      existing [rejection_reason] so dashboards stay consistent with
      [masc_cascade_filter_rejection_total]. *)
type filter_rejection_reason =
  | Codex_keeper_bound_actor_required
  | Tool_lane_unsupported
  | Required_tool_use of Provider_tool_support.rejection_reason

let filter_rejection_reason_label = function
  | Codex_keeper_bound_actor_required -> "codex_keeper_bound_actor_required"
  | Tool_lane_unsupported -> "tool_lane_unsupported"
  | Required_tool_use r ->
      Provider_tool_support.rejection_reason_label r

let codex_keeper_bound_skip_seen : (string, float) Hashtbl.t =
  Hashtbl.create 16

let codex_keeper_bound_skip_seen_mutex = Mutex.create ()

let codex_keeper_bound_skip_restate_sec = 3600.0

let codex_keeper_bound_skip_should_emit ~label ~provider_label ~keeper_name
    ~reason_label =
  let key =
    Printf.sprintf "%s|%s|%s|%s" label provider_label keeper_name reason_label
  in
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

let codex_keeper_bound_skip_log_message
    ~label ~keeper_name provider_cfg reason =
  match reason with
  | Codex_keeper_bound_actor_required ->
      Some
        (Printf.sprintf "cascade %s: skipped provider=%s for keeper=%s reason=%s"
           label
           (Provider_tool_support.provider_debug_label provider_cfg)
           keeper_name
           (filter_rejection_reason_label reason))
  | Tool_lane_unsupported | Required_tool_use _ -> None

let log_codex_keeper_bound_skip ~label ~keeper_name provider_cfg reason =
  match
    codex_keeper_bound_skip_log_message ~label ~keeper_name provider_cfg reason
  with
  | None -> ()
  | Some message ->
      let provider_label =
        Provider_tool_support.provider_debug_label provider_cfg
      in
      let reason_label = filter_rejection_reason_label reason in
      if
        codex_keeper_bound_skip_should_emit ~label ~provider_label ~keeper_name
          ~reason_label
      then
        Log.Misc.info
          "%s; repeated identical skip decisions demoted to DEBUG for the next %.0fs"
          message codex_keeper_bound_skip_restate_sec
      else Log.Misc.debug "%s" message

let classify_filter_rejection
    ~(keeper_name : string)
    ?runtime_mcp_policy
    ?(tools = [])
    ~require_tool_choice_support
    ~require_tool_support
    (provider_cfg : Llm_provider.Provider_config.t)
  : filter_rejection_reason option =
  if codex_cli_cannot_carry_keeper_bound_runtime_mcp
       ~keeper_name ~provider_cfg runtime_mcp_policy
  then Some Codex_keeper_bound_actor_required
  else
    let normalized_runtime_mcp_policy =
      runtime_mcp_policy_for_provider
        ~keeper_name ~provider_cfg runtime_mcp_policy
    in
    let tool_lane_supported =
      match tools with
      | [] -> true
      | _ -> (
          match
            Oas_worker_exec.resolve_tool_lane_for_oas_tools
              ?agent_name:(keeper_agent_name_opt keeper_name)
              ~tool_requirement:
                (if require_tool_choice_support || require_tool_support
                 then `Required
                 else `Optional)
              ~provider_cfg ~tools ()
          with
          | Ok _ -> true
          | Error _ -> false)
    in
    if not tool_lane_supported then Some Tool_lane_unsupported
    else
      match
        Provider_tool_support.classify_rejection
          ?runtime_mcp_policy:normalized_runtime_mcp_policy
          ~require_tool_choice_support ~require_tool_support
          provider_cfg
      with
      | Some reason -> Some (Required_tool_use reason)
      | None -> None

(* #11060: cascade-empty WARN dedupe.

   When the tool-use gate empties a cascade (every configured
   provider rejected — e.g. [keeper_unified] with only [codex_cli]
   providers under a keeper-bound runtime MCP policy), the WARN
   fires once per filtering invocation. Field log: 18 identical
   WARN events / 49 min for a single misconfigured cascade — the
   genuine signal (operator must edit cascade.toml) drowns in its
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
let cascade_empty_warn_seen : (string, float) Hashtbl.t =
  Hashtbl.create 16

let cascade_empty_warn_seen_mutex = Mutex.create ()

let cascade_empty_warn_restate_sec = 3600.0

let signature_of_rejected_providers rejected =
  rejected
  |> List.map (fun (cfg, reason) ->
       Printf.sprintf "%s:%s"
         (Provider_tool_support.provider_debug_label cfg)
         (filter_rejection_reason_label reason))
  |> List.sort String.compare
  |> String.concat ","

let cascade_empty_should_emit_first ~label ~signature =
  let key = label ^ "|" ^ signature in
  let now = Unix.gettimeofday () in
  Mutex.lock cascade_empty_warn_seen_mutex;
  let first =
    match Hashtbl.find_opt cascade_empty_warn_seen key with
    | None -> true
    | Some last -> now -. last >= cascade_empty_warn_restate_sec
  in
  if first then Hashtbl.replace cascade_empty_warn_seen key now;
  Mutex.unlock cascade_empty_warn_seen_mutex;
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
      [cascade_empty:<reason>] capability_drop already covers this case).
    The function is total and never raises; secondary parsing errors are
    surfaced as [None] by the resolver. *)
let attempt_secondary_swap
    ~keeper_name ?runtime_mcp_policy ~tools
    ~require_tool_choice_support ~require_tool_support
    ~(secondary_resolver :
        int ->
        Llm_provider.Provider_config.t ->
        Llm_provider.Provider_config.t option)
    ~(provider_index : int)
    (primary, primary_reason)
  : (Llm_provider.Provider_config.t,
     Llm_provider.Provider_config.t * filter_rejection_reason) Either.t =
  match secondary_resolver provider_index primary with
  | None -> Either.Right (primary, primary_reason)
  | Some secondary -> (
      (* RFC-0027 PR-9c: per-secondary accounting label.
         The secondary's [provider_kind] is a closed enum from
         [Llm_provider.Provider_config.string_of_provider_kind] so
         label cardinality stays bounded (≤ kind count). This lets
         dashboards split [dual_track_swap] swap volume by which
         backend the cascade is actually leaning on (CLI vs Direct
         API), without inflating the [detail] axis. The lookup of
         the matching [Keeper_provider_token_bucket] for the
         secondary continues to flow through the keeper admission
         router, which is provider-name keyed and lazy-creates a
         distinct bucket per concrete provider — so accounting
         already separates primary and secondary draws as a
         consequence of [provider_kind] differing. *)
      let secondary_kind_label =
        Llm_provider.Provider_config.string_of_provider_kind secondary.kind
      in
      match
        classify_filter_rejection
          ~keeper_name ?runtime_mcp_policy ~tools
          ~require_tool_choice_support ~require_tool_support
          secondary
      with
      | None ->
          Llm_metric_bridge.emit_fallback_triggered
            ~kind:"dual_track_swap"
            ~detail:(Printf.sprintf "swapped:%s" secondary_kind_label);
          Either.Left secondary
      | Some secondary_reason ->
          (* Both primary and secondary rejected: keep the primary in
             rejected so the cascade-empty WARN signature stays anchored
             on the user-declared model. The secondary's rejection is
             surfaced as a separate metric so operators can audit which
             dual-track entries are uselessly configured. The kind label
             rides on the rejection detail too, so the same
             [secondary_kind] series is queryable across swap success /
             swap failure outcomes. *)
          Llm_metric_bridge.emit_fallback_triggered
            ~kind:"dual_track_swap"
            ~detail:(Printf.sprintf "rejected:%s:%s"
                       secondary_kind_label
                       (filter_rejection_reason_label secondary_reason));
          Either.Right (primary, primary_reason))

let filter_candidate_providers_for_tool_support
    ~(keeper_name : string)
    ?runtime_mcp_policy
    ?(tools = [])
    ~require_tool_choice_support
    ~require_tool_support
    ?secondary_resolver
    ~label
    (provider_cfgs : Llm_provider.Provider_config.t list) =
  if not require_tool_choice_support && not require_tool_support then
    provider_cfgs
  else
    let kept_rev, rejected_rev, _ =
      List.fold_left
        (fun (kept, rejected, provider_index) provider_cfg ->
           match
             classify_filter_rejection
               ~keeper_name ?runtime_mcp_policy ~tools
               ~require_tool_choice_support ~require_tool_support
               provider_cfg
           with
           | None -> (provider_cfg :: kept, rejected, provider_index + 1)
           | Some reason ->
               log_codex_keeper_bound_skip ~label ~keeper_name provider_cfg
                 reason;
               let swap =
                 match secondary_resolver with
                 | None -> Either.Right (provider_cfg, reason)
                 | Some resolver ->
                     attempt_secondary_swap
                       ~keeper_name ?runtime_mcp_policy ~tools
                       ~require_tool_choice_support ~require_tool_support
                       ~secondary_resolver:resolver
                       ~provider_index
                       (provider_cfg, reason)
               in
               (match swap with
                | Either.Left secondary ->
                    (secondary :: kept, rejected, provider_index + 1)
                | Either.Right rejected_provider ->
                    (kept, rejected_provider :: rejected, provider_index + 1)))
        ([], [], 0)
        provider_cfgs
    in
    let kept = List.rev kept_rev in
    let rejected = List.rev rejected_rev in
    if kept = [] && provider_cfgs <> [] then begin
      let signature = signature_of_rejected_providers rejected in
      (* Forward each rejection to the Prometheus capability_drop counter so
         operators can alert on cascade-empty silently dropping requests.
         The WARN log below describes the systemic cause; the per-rejection
         metric records every provider lost so dashboards can attribute
         which provider/reason combination drove the drop. *)
      List.iter
        (fun (provider_cfg, reason) ->
          let reason_label = filter_rejection_reason_label reason in
          Llm_metric_bridge.emit_capability_drop
            ~model_id:provider_cfg.Llm_provider.Provider_config.model_id
            ~field:(Printf.sprintf "cascade_empty:%s" reason_label);
          (* §7.3.2 Zero Silent Failure: also feed the unified
             fallback counter so the dashboard panel sees a single
             numerator across all fallback classes. *)
          Llm_metric_bridge.emit_fallback_triggered
            ~kind:"cascade_empty"
            ~detail:reason_label)
        rejected;
      if cascade_empty_should_emit_first ~label ~signature then
        Log.Misc.error
          "[#11060/#11356] cascade %s: provider-normalized tool-use gate \
           removed all providers (rejections=[%s]) — operator action: add a \
           runtime-MCP-capable fallback provider to this cascade in \
           cascade.toml. Verified-capable providers: claude_code, kimi_cli, \
           anthropic, glm, openrouter (any non-cli direct API). Note: \
           gemini_cli and codex_cli reject request-scoped runtime MCP HTTP \
           headers (gemini-cli upstream lacks --mcp-config flag; codex_cli \
           strips most per-request headers) — they cannot satisfy this gate. \
           Alternatively detach the keeper from this cascade. Subsequent \
           identical-signature rejections demoted to DEBUG for the next %.0fs"
          label signature cascade_empty_warn_restate_sec
      else
        Log.Misc.debug
          "[#11060] cascade %s: repeated all-providers-rejected (rejections=[%s])"
          label signature
    end;
    kept

(* Cross-cascade health-aware fallback.
   When the current cascade has no tool-capable providers after filtering,
   search all other cascades for a healthy tool-capable provider using the
   health tracker's success rate and cooldown state. Returns the provider
   config and the source cascade name, or None if no suitable provider exists.

   Depth: 1 level only (no cross-cascade-of-cross-cascade).
   Scope: excludes the current cascade to avoid revisiting. *)
let resolve_tool_capable_provider_across_cascades
    ~sw ~net
    ~(keeper_name : string)
    ?runtime_mcp_policy
    ?(tools = [])
    ~require_tool_choice_support
    ~require_tool_support
    ~(exclude_cascade : string)
    () =
  match Cascade_catalog_runtime.known_profile_names ~sw ~net () with
  | Error _ -> None
  | Ok all_names ->
      let assignable_names =
        Keeper_cascade_profile.keeper_catalog_names ()
      in
      let assignable_set =
        List.fold_left (fun acc n -> n :: acc) [] assignable_names
      in
      let is_keeper_assignable name = List.mem name assignable_set in
      let scored_candidates =
        all_names
        |> List.filter (fun name -> name <> exclude_cascade)
        |> List.filter_map (fun cascade_name ->
             match Cascade_catalog_runtime.resolve_named_providers ~sw ~net
                     ~require_tool_choice_support ~require_tool_support
                     ?runtime_mcp_policy
                     ~cascade_name ()
             with
             | Error _ -> None
             | Ok providers ->
                 let secondary_resolver _provider_index primary =
                   Cascade_catalog_runtime
                   .resolve_secondary_provider_for_primary
                     ~sw ~net ~cascade_name ~primary ()
                 in
                 let filtered =
                   filter_candidate_providers_for_tool_support
                     ~keeper_name ?runtime_mcp_policy ~tools
                     ~require_tool_choice_support ~require_tool_support
                     ~secondary_resolver
                     ~label:cascade_name providers
                 in
                 match filtered with
                 | [] -> None
                 | _ -> Some (cascade_name, filtered))
        |> List.concat_map (fun (cascade_name, providers) ->
             let keeper_assignable = is_keeper_assignable cascade_name in
             let inventory_cascade_name =
               Keeper_cascade_profile.Runtime_name cascade_name
             in
             providers
             |> List.map (fun (provider : Llm_provider.Provider_config.t) ->
                  let score =
                    Cascade_inventory.score_provider
                      Cascade_health_tracker.global
                      ~exclude:[]
                      ~keeper_assignable
                      provider
                  in
                  Cascade_inventory.
                    { cascade_name = inventory_cascade_name; provider; score }))
      in
      (* The score_provider helper already collapses cooldown,
         keeper_assignable, and the success × latency composition into a
         single [0.0–1.0] number; best_runner_among picks the strict
         positive max with deterministic tie-break.  This replaces the
         pre-PR4 sort that ranked solely by success_rate (which left
         slow-but-alive providers indistinguishable from fast ones, and
         did not exclude non-keeper-assignable cascades like
         [governance_judge] from a regular keeper's fallback pool). *)
      Cascade_inventory.best_runner_among
        ~health:Cascade_health_tracker.global
        ~exclude:[]
        scored_candidates
      |> Option.map (fun (sp : Cascade_inventory.scored_provider) ->
           ( Keeper_cascade_profile.runtime_name_to_string sp.cascade_name,
             sp.provider ))
