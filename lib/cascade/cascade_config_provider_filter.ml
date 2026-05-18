(** Provider-list filtering + context-window helpers.

    Extracted from [cascade_config.ml]. *)

module Binding = Cascade_config_provider_binding
module Parser = Cascade_config_parser
module Runtime_binding = Binding.Runtime_binding

let default_registry = Llm_provider.Provider_registry.default ()

(* ── Context window resolution ──────────────────────────── *)

let effective_max_context (entry : Llm_provider.Provider_registry.entry)
    (caps : Llm_provider.Capabilities.capabilities) =
  (* Defensive unwrap: treat [Some 0] / negative as absent rather than
     handing a broken value to downstream budget arithmetic. Aligns with
     the same guard in [Pipeline.proactive_context_window_tokens] (#815)
     and [Provider.resolve_max_context_tokens] (#823). *)
  match caps.max_context_tokens with
  | Some n when n > 0 -> n
  | _ -> entry.max_context

(** Resolve a model label to the per-slot context of the endpoint
    that would serve it.  Uses the same resolution logic as
    [make_registry_config]: [current_llama_endpoint] for "llama:*",
    parsed URL for "custom:*".  Cloud providers return [None].

    Does NOT advance the round-robin counter — safe to call for
    prompt sizing before the actual cascade request.

    @since 0.100.8 *)
let resolve_label_context (label : string) : int option =
  match Parser.split_provider_model (String.trim label) with
  | None -> None
  | Some ("custom", model_id) ->
    let _, url = Cascade_model_resolve.parse_custom_model model_id in
    Llm_provider.Discovery.discovered_context_for_url url
  | Some ("llama", model_id) ->
    (* Model-aware: find the endpoint that has this model loaded *)
    (match Llm_provider.Discovery.context_for_model model_id with
     | Some (_url, ctx) -> Some ctx
     | None ->
       (* Fallback: round-robin endpoint (backward compat for "auto" etc.).
          Iter 29 telemetry: requested model_id was not located on any
          registered endpoint — silently routing to whatever
          [current_llama_endpoint] happens to be.  Tick a counter so
          operators can alert on the silent intent loss. *)
       Cascade_metrics.on_llama_model_not_discovered ();
       let url = Llm_provider.Provider_registry.current_llama_endpoint () in
       if url = "" then None
       else Llm_provider.Discovery.discovered_context_for_url url)
  | Some (_, _) ->
    (* Cloud providers: no discovery-based per-slot context *)
    None

(* ── Capability-aware filtering ─────────────────────────── *)

let filter_by_capabilities ~(pred : Llm_provider.Capabilities.capabilities -> bool)
    (providers : Llm_provider.Provider_config.t list) =
  let legacy_capabilities_for_unbound_config (cfg : Llm_provider.Provider_config.t) =
    match Llm_provider.Capabilities.for_model_id cfg.model_id with
    | Some c -> c
    | None ->
      (match Llm_provider.Provider_registry.find default_registry cfg.model_id with
       | Some entry -> entry.capabilities
       | None -> Llm_provider.Capabilities.default_capabilities)
  in
  let capabilities_for_filter (cfg : Llm_provider.Provider_config.t) =
    match Runtime_binding.binding_for_provider_config cfg with
    | Some _ -> Runtime_binding.capabilities_for_provider_config cfg
    | None -> legacy_capabilities_for_unbound_config cfg
  in
  let satisfies (cfg : Llm_provider.Provider_config.t) =
    pred (capabilities_for_filter cfg)
  in
  let filtered = List.filter satisfies providers in
  if filtered = [] then providers
  else filtered

(* ── Helpers ────────────────────────────────────────────── *)

let text_of_response (resp : Llm_provider.Types.api_response) : string =
  resp.content
  |> List.filter_map (function
    | Llm_provider.Types.Text t -> Some t
    | _ -> None)
  |> fun lst -> String.concat "" lst

(* ── Provider filter rejection (strict mode) ───────────── *)

type provider_filter_rejection =
  | Filter_matched_none of { filter : string list; available_kinds : string list }

let provider_filter_rejection_to_string = function
  | Filter_matched_none { filter; available_kinds } ->
    Printf.sprintf
      "provider_filter matched no providers: filter=[%s] available=[%s]"
      (String.concat "," filter)
      (String.concat "," available_kinds)

(* Filter providers by kind name (exact, case-insensitive).
   Valid filter values: "ollama", "glm", "anthropic", "gemini", "openai_compat",
   "claude_code", "kimi", "kimi_cli", "gemini_cli", "codex_cli".
   Empty/None filter passes through unchanged. No-match falls back to unfiltered. *)
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
