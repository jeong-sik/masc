(* Stage 08 — named-provider resolution on top of [lookup_active_profile].
   Hosts the [resolve_named_providers] family (loose + strict + with
   secondary resolver), the RFC-0027 PR-9b dual-track lookup, and the
   per-profile scalar getters (inference params, strategy, max
   concurrent, selection trace).  All of these are pure over a
   snapshot — they do not mutate the cache or re-validate. *)

open Cascade_catalog_runtime_cache
module Resolve = Cascade_catalog_runtime_resolve

let candidate_key_of_cfg (cfg : Llm_provider.Provider_config.t) =
  Hashtbl.hash
    ( Llm_provider.Provider_config.string_of_provider_kind cfg.kind,
      cfg.model_id,
      cfg.base_url,
      cfg.request_path,
      cfg.api_key,
      cfg.headers,
      cfg.supports_tool_choice_override )

let direct_candidate_providers (profile : profile_snapshot) =
  List.map
    (fun (candidate : candidate_runtime) -> candidate.provider_cfg)
    profile.candidates

let direct_candidate_providers_ordered_by_entries
    (profile : profile_snapshot)
    (ordered_entries : Cascade_config_loader.weighted_entry list) =
  match profile.candidates with
  | [] -> []
  | candidates ->
      (* Index candidates by [model_string] into per-key FIFO queues so we
         drain them in declaration order; same model_string may appear
         multiple times in a profile (e.g. priority duplicates), and the
         runtime hot path treats this function as O(n) total work. *)
      let index : (string, candidate_runtime Queue.t) Hashtbl.t =
        Hashtbl.create (List.length candidates)
      in
      List.iter
        (fun (candidate : candidate_runtime) ->
          let q =
            match Hashtbl.find_opt index candidate.model_string with
            | Some q -> q
            | None ->
                let q = Queue.create () in
                Hashtbl.add index candidate.model_string q;
                q
          in
          Queue.add candidate q)
        candidates;
      let take_candidate model_string =
        match Hashtbl.find_opt index model_string with
        | Some q when not (Queue.is_empty q) ->
            let candidate = Queue.pop q in
            Some candidate.provider_cfg
        | _ -> None
      in
      let ordered =
        List.filter_map
          (fun (entry : Cascade_config_loader.weighted_entry) ->
            take_candidate entry.model)
          ordered_entries
      in
      if List.length ordered = List.length candidates then ordered
      else direct_candidate_providers profile

let provider_configs_of_ordered_entries ~(profile : profile_snapshot)
    ~cascade_name:_
    (ordered_entries : Cascade_config_loader.weighted_entry list) =
  direct_candidate_providers_ordered_by_entries profile ordered_entries

let resolve_named_providers ?sw ?net ?clock ?provider_filter
    ?(require_tool_choice_support = false) ?(require_tool_support = false)
    ?runtime_mcp_policy ~cascade_name () =
  match Resolve.lookup_active_profile ?sw ?net ?clock cascade_name with
  | Error _ as e ->
      Cascade_metrics.on_resolve_failure ~cascade:cascade_name
        ~reason:"lookup_failed";
      e
  | Ok (_snapshot, normalized, profile) ->
      let provider_label (c : Llm_provider.Provider_config.t) =
        Printf.sprintf "%s:%s"
          (Llm_provider.Provider_config.string_of_provider_kind c.kind)
          (String.trim c.model_id)
      in
      let ordered_entries =
        Cascade_config.order_weighted_entries ~rotation_scope:normalized
          ~cascade:normalized profile.weighted_entries
      in
      let parsed_declared_providers =
        provider_configs_of_ordered_entries ~profile
          ~cascade_name:normalized ordered_entries
      in
      let filtered_declared_providers =
        Cascade_config.apply_provider_filter ~provider_filter
          ~label:normalized parsed_declared_providers
      in
      let providers =
        Provider_tool_support.apply_required_tool_use_filter
          ?runtime_mcp_policy ~require_tool_choice_support
          ~require_tool_support ~label:normalized
          filtered_declared_providers
      in
      if providers = [] then (
        Cascade_metrics.on_resolve_failure ~cascade:normalized
          ~reason:"no_callable_providers";
        Error
          (Printf.sprintf "cascade %s resolved to no callable providers"
             normalized))
      else (
        (* Observability for cascade-name -> runtime-provider divergence.
           Compare against the profile after provider:auto expansion,
           canonical provider parsing, and provider_filter fallback.  The
           raw declared strings can be aliases such as
           [codex_cli:auto] or [custom:model@url], while Provider_config
           carries concrete/canonical labels.
           See memory/handoff-2026-04-24-masc-runtime-mcp-auth-resolved.md *)
        let declared = List.map provider_label filtered_declared_providers in
        let returned = List.map provider_label providers in
        let leaked =
          List.filter (fun m -> not (List.mem m declared)) returned
        in
        Cascade_metrics.on_resolve_provider_leak ~cascade:normalized
          ~leak_count:(List.length leaked);
        (if leaked <> [] then
           Log.warn ~ctx:"CascadeCatalog"
             "resolve_named_providers(%s): %d providers NOT in parsed \
              declared profile (parsed_declared=[%s] returned=[%s] \
              leaked=[%s])"
             normalized (List.length leaked)
             (String.concat ", " declared)
             (String.concat ", " returned)
             (String.concat ", " leaked)
         else
           Log.debug ~ctx:"CascadeCatalog"
             "resolve_named_providers(%s) -> [%s]" normalized
             (String.concat ", " returned));
        Ok providers)

let resolve_named_providers_strict ?sw ?net ?clock ?provider_filter
    ?(require_tool_choice_support = false) ?(require_tool_support = false)
    ?runtime_mcp_policy ~cascade_name () =
  match Resolve.lookup_active_profile ?sw ?net ?clock cascade_name with
  | Error _ as e ->
      Cascade_metrics.on_resolve_failure ~cascade:cascade_name
        ~reason:"lookup_failed";
      e
  | Ok (_snapshot, normalized, profile) ->
      let ordered_entries =
        Cascade_config.order_weighted_entries ~rotation_scope:normalized
          ~cascade:normalized profile.weighted_entries
      in
      let parsed_declared_providers =
        provider_configs_of_ordered_entries ~profile
          ~cascade_name:normalized ordered_entries
      in
      let filtered_declared_providers =
        match
          Cascade_config.apply_provider_filter_strict ~provider_filter
            ~label:normalized parsed_declared_providers
        with
        | Error rejection ->
            Error
              (Cascade_config.provider_filter_rejection_to_string
                 rejection)
        | Ok ps -> Ok ps
      in
      (match filtered_declared_providers with
       | Error _ as e ->
           Cascade_metrics.on_resolve_failure ~cascade:normalized
             ~reason:"provider_filter_rejected";
           e
       | Ok filtered ->
         let providers =
           Provider_tool_support.apply_required_tool_use_filter
             ?runtime_mcp_policy ~require_tool_choice_support
             ~require_tool_support ~label:normalized filtered
         in
         if providers = [] then (
           Cascade_metrics.on_resolve_failure ~cascade:normalized
             ~reason:"no_callable_providers";
           Error
             (Printf.sprintf
                "cascade %s resolved to no callable providers" normalized))
         else Ok providers)

type secondary_resolution = {
  providers : Llm_provider.Provider_config.t list;
  secondary_resolver :
    int ->
    Llm_provider.Provider_config.t ->
    Llm_provider.Provider_config.t option;
}

let provider_filter_allows_single ~provider_filter ~label provider =
  match provider_filter with
  | None | Some [] -> true
  | Some _ -> (
      match
        Cascade_config.apply_provider_filter_strict ~provider_filter
          ~label [ provider ]
      with
      | Ok [ _ ] -> true
      | Ok _ | Error _ -> false)

let resolve_named_providers_strict_with_secondary_resolver ?sw ?net ?clock
    ?provider_filter ~cascade_name () =
  match Resolve.lookup_active_profile ?sw ?net ?clock cascade_name with
  | Error _ as e ->
      (* Iter 10 [on_resolve_failure] also covered the base
         [resolve_named_providers_strict]; this wrapper is the actual
         entry point that keeper_turn_driver:127 hits, so its three
         Error returns were the most common silent cause of keeper
         turn failures going unobserved.  Same metric + same reason
         labels (no [function] dimension) so dashboards aggregate
         "resolve failures per cascade" across both call sites. *)
      Cascade_metrics.on_resolve_failure ~cascade:cascade_name
        ~reason:"lookup_failed";
      e
  | Ok (_snapshot, normalized, profile) ->
      let ordered_entries =
        Cascade_config.order_weighted_entries ~rotation_scope:normalized
          ~cascade:normalized profile.weighted_entries
      in
      let parsed_pairs =
        let direct_pairs =
          direct_candidate_providers_ordered_by_entries profile
            ordered_entries
          |> List.map (fun cfg -> (cfg, None))
        in
        direct_pairs
      in
      let primaries = List.map fst parsed_pairs in
      (match
         Cascade_config.apply_provider_filter_strict ~provider_filter
           ~label:normalized primaries
       with
       | Error rejection ->
           Cascade_metrics.on_resolve_failure ~cascade:normalized
             ~reason:"provider_filter_rejected";
           Error
             (Cascade_config.provider_filter_rejection_to_string rejection)
       | Ok _filtered_primaries ->
         let provider_filter_allows =
           provider_filter_allows_single ~provider_filter ~label:normalized
         in
         let filtered_pairs =
           parsed_pairs
           |> List.filter (fun (primary, _) ->
                  provider_filter_allows primary)
           |> List.map (fun (primary, secondary) ->
                  let secondary =
                    match secondary with
                    | Some cfg when provider_filter_allows cfg -> Some cfg
                    | _ -> None
                  in
                  (primary, secondary))
         in
         let providers = List.map fst filtered_pairs in
         if providers = [] then (
           Cascade_metrics.on_resolve_failure ~cascade:normalized
             ~reason:"no_callable_providers";
           Error
             (Printf.sprintf
                "cascade %s resolved to no callable providers" normalized))
         else
           let slots = Array.of_list filtered_pairs in
           let secondary_resolver provider_index primary =
             if
               provider_index < 0
               || provider_index >= Array.length slots
             then None
             else
               let indexed_primary, secondary = slots.(provider_index) in
               if
                 candidate_key_of_cfg indexed_primary
                 = candidate_key_of_cfg primary
               then secondary
               else None
           in
           Ok { providers; secondary_resolver })

(* Deprecated compatibility hook for RFC-0027 PR-9b dual-track resolution.
   Declarative cascade execution now carries typed [Provider_config]
   candidates from TOML materialization. Runtime no longer re-parses
   weighted-entry model strings to recover secondary providers; callers
   that need secondaries should consume the precomputed resolver from
   [resolve_named_providers_strict_with_secondary_resolver]. *)
let resolve_secondary_provider_for_primary ?sw ?net ?clock ~cascade_name
    ~(primary : Llm_provider.Provider_config.t) () =
  let _ = (sw, net, clock, cascade_name, primary) in
  None

let resolve_inference_params ?sw ?net ?clock ~name () =
  match Resolve.lookup_active_profile ?sw ?net ?clock name with
  | Ok (_snapshot, _normalized, profile) -> Ok profile.inference_params
  | Error _ as e -> e

let resolve_strategy ?sw ?net ?clock ~name () =
  match Resolve.lookup_active_profile ?sw ?net ?clock name with
  | Ok (_snapshot, _normalized, profile) -> Ok profile.strategy
  | Error _ as e -> e

let resolve_ollama_max_concurrent ?sw ?net ?clock ~name () =
  match Resolve.lookup_active_profile ?sw ?net ?clock name with
  | Ok (_snapshot, _normalized, profile) -> Ok profile.ollama_max_concurrent
  | Error _ as e -> e

let resolve_cli_max_concurrent ?sw ?net ?clock ~name () =
  match Resolve.lookup_active_profile ?sw ?net ?clock name with
  | Ok (_snapshot, _normalized, profile) -> Ok profile.cli_max_concurrent
  | Error _ as e -> e

let resolve_selection_trace ?sw ?net ?clock ~name () =
  match Resolve.lookup_active_profile ?sw ?net ?clock name with
  | Error _ as e -> e
  | Ok (_snapshot, _normalized, profile) ->
      Ok
        (Cascade_config.selection_trace_of_weighted_entries
           ~source:Cascade_config.Named profile.weighted_entries)
