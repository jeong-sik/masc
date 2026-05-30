(** Cascade configuration facade — inlined from sub-modules. *)

include Cascade_model_resolve
include Cascade_config_loader
include Cascade_config_provider_binding
include Cascade_config_parser
include Cascade_config_selection
include Cascade_config_resolve
include Keeper_health_filter
include Cascade_config_strategy_resolve

(* ── Inlined from Cascade_config_provider_filter ───────────────── *)

let effective_max_context (entry : Llm_provider.Provider_registry.entry)
    (caps : Llm_provider.Capabilities.capabilities) =
  match caps.max_context_tokens with
  | Some n when n > 0 -> n
  | _ -> entry.max_context

let resolve_label_context (label : string) : int option =
  match split_provider_model (String.trim label) with
  | None -> None
  | Some ("custom", model_id) ->
    let _, url = parse_custom_model model_id in
    Llm_provider.Discovery.discovered_context_for_url url
  | Some (_, _) -> None

let filter_by_capabilities ~(pred : Llm_provider.Capabilities.capabilities -> bool)
    (providers : Llm_provider.Provider_config.t list) =
  let satisfies (cfg : Llm_provider.Provider_config.t) =
    pred (Runtime_binding.capabilities_for_provider_config cfg)
  in
  let filtered = List.filter satisfies providers in
  if filtered = [] then providers
  else filtered

let text_of_response (resp : Llm_provider.Types.api_response) : string =
  resp.content
  |> List.filter_map (function
    | Llm_provider.Types.Text t -> Some t
    | _ -> None)
  |> fun lst -> String.concat "" lst

type provider_filter_rejection =
  | Filter_matched_none of { filter : string list; available_kinds : string list }

let provider_filter_rejection_to_string = function
  | Filter_matched_none { filter; available_kinds } ->
    Printf.sprintf
      "provider_filter matched no providers: filter=[%s] available=[%s]"
      (String.concat "," filter)
      (String.concat "," available_kinds)

let apply_provider_filter ~provider_filter ~label providers =
  match provider_filter with
  | None | Some [] -> providers
  | Some filters ->
    let lc_filters = List.map String.lowercase_ascii filters in
    let matches (p : Llm_provider.Provider_config.t) =
      List.mem (Llm_provider.Provider_config.string_of_provider_kind p.kind) lc_filters
    in
    let filtered = List.filter matches providers in
    if filtered = [] then (
      Cascade_metrics.on_provider_filter_widening ~cascade:label;
      Log.warn ~ctx:"CascadeConfig"
        "provider_filter matched no providers (%s); \
         falling back to unfiltered (filter=[%s] providers=[%s])"
        label (String.concat "," filters)
        (String.concat "," (List.map (fun (p : Llm_provider.Provider_config.t) ->
          Llm_provider.Provider_config.string_of_provider_kind p.kind) providers));
      providers)
    else filtered

let apply_provider_filter_strict ~provider_filter ~label providers =
  match provider_filter with
  | None | Some [] -> Ok providers
  | Some filters ->
    let lc_filters = List.map String.lowercase_ascii filters in
    let matches (p : Llm_provider.Provider_config.t) =
      List.mem (Llm_provider.Provider_config.string_of_provider_kind p.kind) lc_filters
    in
    let filtered = List.filter matches providers in
    if filtered = [] then
      Error
        (Filter_matched_none
           { filter = filters
           ; available_kinds =
             providers
             |> List.map (fun (p : Llm_provider.Provider_config.t) ->
               Llm_provider.Provider_config.string_of_provider_kind p.kind)
             |> List.sort_uniq String.compare
           })
    else Ok filtered

(* ── End inlined section ─────────────────────────────────────────── *)

(* Strategy re-exports via include above. *)

