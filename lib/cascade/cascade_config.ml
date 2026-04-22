(** Cascade configuration: named provider profiles with JSON hot-reload
    and discovery-aware health filtering.

    Provider defaults are sourced from {!Provider_registry} (SSOT).

    @since 0.59.0
    @since 0.92.0 decomposed into Cascade_model_resolve, Cascade_throttle,
    Cascade_config_loader *)

(* ── Re-exports from extracted modules ─────────────── *)

(* Model resolution *)
let resolve_auto_model = Cascade_model_resolve.resolve_auto_model
let resolve_glm_model_id = Cascade_model_resolve.resolve_glm_model_id
let resolve_auto_model_id = Cascade_model_resolve.resolve_auto_model_id
let parse_custom_model = Cascade_model_resolve.parse_custom_model

(* Config loader *)
let load_json = Cascade_config_loader.load_json
let load_profile = Cascade_config_loader.load_profile

type inference_params = Cascade_config_loader.inference_params = {
  temperature: float option;
  max_tokens: int option;
}

let resolve_inference_params = Cascade_config_loader.resolve_inference_params
let resolve_api_key_env = Cascade_config_loader.resolve_api_key_env

(* ── Provider registry (SSOT: Provider_registry) ─────── *)

let default_registry = Llm_provider.Provider_registry.default ()

(* Build headers list with Authorization when api_key is present.
   Anthropic uses x-api-key; OpenAI-compat (including GLM) uses Bearer. *)
let headers_with_auth ~(kind : Llm_provider.Provider_config.provider_kind) ~api_key =
  let base = [("Content-Type", "application/json")] in
  if api_key = "" then base
  else match kind with
    | Anthropic ->
        ("x-api-key", api_key)
        :: ("anthropic-version", "2023-06-01")
        :: base
    | OpenAI_compat | Ollama | Gemini | Glm | Claude_code ->
        ("Authorization", "Bearer " ^ api_key) :: base
    | Gemini_cli | Codex_cli -> []

(* ── String splitting helper ──────────────────────────────── *)

(** Split a "provider:model_id" string at the first colon.
    Returns [None] if the colon is missing, at position 0, or at the end. *)
let split_provider_model (s : string) : (string * string) option =
  match String.index_opt s ':' with
  | None -> None
  | Some idx ->
    if idx = 0 || idx >= String.length s - 1 then None
    else
      let provider_name =
        String.sub s 0 idx |> String.trim |> String.lowercase_ascii
      in
      let model_id =
        String.sub s (idx + 1) (String.length s - idx - 1) |> String.trim
      in
      if model_id = "" then None
      else Some (provider_name, model_id)

(* ── Shared config construction helpers ──────────────────── *)

(** Build a {!Llm_provider.Provider_config.t} for "custom:model@url" specs. *)
let make_custom_config ~temperature ~max_tokens ?system_prompt
    ?supports_tool_choice_override model_id =
  let actual_model, base_url = parse_custom_model model_id in
  if actual_model = "" then None
  else Some (Llm_provider.Provider_config.make
               ~kind:OpenAI_compat
               ~model_id:actual_model
               ~base_url
               ~request_path:"/v1/chat/completions"
               ~temperature
               ~max_tokens
               ?system_prompt
               ?supports_tool_choice_override
               ())

(** Resolve the effective API key env var name for a provider.

    Checks [api_key_env_overrides] first (exact provider name, then
    wildcard ["*"]), then falls back to the provider registry default.

    Empty-string entries are treated as absent so a user-provided
    [{"glm": ""}] falls through to the wildcard and registry default
    instead of silently disabling auth. *)
let resolve_effective_api_key_env
    ~(api_key_env_overrides : (string * string) list)
    ~(provider_name : string)
    ~(registry_default : string) =
  let find_non_empty key =
    match List.assoc_opt key api_key_env_overrides with
    | Some v when v <> "" -> Some v
    | _ -> None
  in
  match find_non_empty provider_name with
  | Some env -> env
  | None ->
    match find_non_empty "*" with
    | Some env -> env
    | None -> registry_default

(** Build a {!Llm_provider.Provider_config.t} from a registry entry. *)
let make_registry_config ~temperature ~max_tokens ?system_prompt
    ?(api_key_env_overrides=[]) ?supports_tool_choice_override
    ~provider_name ~model_id (entry : Llm_provider.Provider_registry.entry) =
  let defaults = entry.defaults in
  let effective_api_key_env =
    resolve_effective_api_key_env
      ~api_key_env_overrides ~provider_name
      ~registry_default:defaults.api_key_env
  in
  let api_key =
    if effective_api_key_env = "" then ""
    else Sys.getenv_opt effective_api_key_env |> Option.value ~default:""
  in
  let headers = headers_with_auth ~kind:defaults.kind ~api_key in
  (* Keep runtime model selection on the same resolution path as the
     provenance helpers in [Cascade_model_resolve]. Local providers still
     inject provider-specific discovery so routing stays isolated by
     endpoint (e.g. ollama:auto must not pick up llama-server models). *)
  let discover =
    match provider_name with
    | "ollama" ->
        Some
          (fun () ->
            Llm_provider.Discovery.first_discovered_model_id_for_url
              defaults.base_url)
    | "llama" -> Some Llm_provider.Discovery.first_discovered_model_id
    | _ -> None
  in
  let model_resolution =
    resolve_auto_model ?discover provider_name model_id
  in
  let resolved_model_id = model_resolution.resolved_model_id in
  let base_url =
    if provider_name = "llama" then
      (* Route to the endpoint that has this model; round-robin fallback *)
      match Llm_provider.Discovery.endpoint_for_model resolved_model_id with
      | Some url -> url
      | None -> Llm_provider.Provider_registry.next_llama_endpoint ()
    else defaults.base_url
  in
  (* Resolve max_context: per-model capabilities override registry default *)
  let max_context =
    let caps =
      Option.value ~default:entry.capabilities
        (Llm_provider.Capabilities.for_model_id resolved_model_id)
    in
    match caps.max_context_tokens with
    | Some n -> n
    | None -> entry.max_context
  in
  Llm_provider.Provider_config.make
    ~kind:defaults.kind
    ~model_id:resolved_model_id
    ~base_url
    ~api_key ~headers
    ~request_path:defaults.request_path
    ~temperature
    ~max_tokens
    ~max_context
    ?system_prompt
    ?supports_tool_choice_override
    ()

(* ── Model string parsing ──────────────────────────────── *)

let parse_model_string
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?(max_tokens = Llm_provider.Constants.Inference.default_max_tokens)
    ?system_prompt ?(api_key_env_overrides = [])
    ?supports_tool_choice_override
    (s : string) : Llm_provider.Provider_config.t option =
  match split_provider_model (String.trim s) with
  | None -> None
  | Some ("custom", model_id) ->
    make_custom_config ~temperature ~max_tokens ?system_prompt
      ?supports_tool_choice_override model_id
  | Some (provider_name, model_id) ->
    match Llm_provider.Provider_registry.find default_registry provider_name with
    | None -> None
    | Some entry when not (entry.is_available ()) -> None
    | Some entry ->
      Some (make_registry_config ~temperature ~max_tokens ?system_prompt
              ~api_key_env_overrides ?supports_tool_choice_override
              ~provider_name ~model_id entry)

(** Parse a {!Cascade_config_loader.weighted_entry} into a
    {!Llm_provider.Provider_config.t}, forwarding the entry's
    [supports_tool_choice] override. The [weight] is not part of the
    Provider_config; it drives cascade ordering separately. *)
let parse_weighted_entry
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?(max_tokens = Llm_provider.Constants.Inference.default_max_tokens)
    ?system_prompt ?(api_key_env_overrides = [])
    (entry : Cascade_config_loader.weighted_entry)
  : Llm_provider.Provider_config.t option =
  parse_model_string ~temperature ~max_tokens ?system_prompt
    ~api_key_env_overrides
    ?supports_tool_choice_override:entry.supports_tool_choice
    entry.model

(** Parse a list of weighted entries, discarding unavailable providers. *)
let parse_weighted_entries
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?(max_tokens = Llm_provider.Constants.Inference.default_max_tokens)
    ?system_prompt ?(api_key_env_overrides = [])
    (entries : Cascade_config_loader.weighted_entry list)
  : Llm_provider.Provider_config.t list =
  List.filter_map
    (parse_weighted_entry ~temperature ~max_tokens ?system_prompt
       ~api_key_env_overrides)
    entries

let parse_model_string_exn
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?(max_tokens = Llm_provider.Constants.Inference.default_max_tokens)
    ?system_prompt (s : string) : (Llm_provider.Provider_config.t, string) result =
  let s = String.trim s in
  match split_provider_model s with
  | None ->
    Error (Printf.sprintf "invalid model spec %S: expected \"provider:model_id\"" s)
  | Some ("custom", model_id) ->
    (match make_custom_config ~temperature ~max_tokens ?system_prompt model_id with
     | Some cfg -> Ok cfg
     | None ->
       Error (Printf.sprintf "invalid custom model spec %S: empty model after @" s))
  | Some (provider_name, model_id) ->
    match Llm_provider.Provider_registry.find default_registry provider_name with
    | None ->
      Error (Printf.sprintf "unknown provider %S in model spec %S" provider_name s)
    | Some entry when not (entry.is_available ()) ->
      Error (Printf.sprintf "provider %S unavailable (missing env var %S)"
               provider_name entry.defaults.api_key_env)
    | Some entry ->
      Ok (make_registry_config ~temperature ~max_tokens ?system_prompt
            ~provider_name ~model_id entry)

(** Expand provider:auto specs that map to multiple models.
    "glm:auto" expands to ["glm:glm-5.1"; "glm:glm-5-turbo"; ...].
    Other specs pass through as-is. *)
let expand_auto_models (strs : string list) : string list =
  List.concat_map (fun s ->
    let trimmed = String.trim s in
    match split_provider_model trimmed with
    | Some ("glm", model_id)
      when String.lowercase_ascii model_id = "auto" ->
      Cascade_model_resolve.glm_auto_models ()
      |> List.map (fun m -> "glm:" ^ m)
    | Some ("glm-coding", model_id)
      when String.lowercase_ascii model_id = "auto" ->
      Cascade_model_resolve.glm_coding_auto_models ()
      |> List.map (fun m -> "glm-coding:" ^ m)
    | _ -> [ trimmed ]
  ) strs

let parse_model_strings
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?(max_tokens = Llm_provider.Constants.Inference.default_max_tokens)
    ?system_prompt ?(api_key_env_overrides = [])
    (strs : string list) : Llm_provider.Provider_config.t list =
  let expanded = expand_auto_models strs in
  List.filter_map
    (parse_model_string ~temperature ~max_tokens ?system_prompt
       ~api_key_env_overrides)
    expanded

(* Health filtering (extracted to Cascade_health_filter) *)
let is_local_provider = Cascade_health_filter.is_local_provider
let filter_healthy = Cascade_health_filter.filter_healthy

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
  match split_provider_model (String.trim label) with
  | None -> None
  | Some ("custom", model_id) ->
    let _, url = parse_custom_model model_id in
    Llm_provider.Discovery.discovered_context_for_url url
  | Some ("llama", model_id) ->
    (* Model-aware: find the endpoint that has this model loaded *)
    (match Llm_provider.Discovery.context_for_model model_id with
     | Some (_url, ctx) -> Some ctx
     | None ->
       (* Fallback: round-robin endpoint (backward compat for "auto" etc.) *)
       let url = Llm_provider.Provider_registry.current_llama_endpoint () in
       if url = "" then None
       else Llm_provider.Discovery.discovered_context_for_url url)
  | Some (_, _) ->
    (* Cloud providers: no discovery-based per-slot context *)
    None

(* ── Capability-aware filtering ─────────────────────────── *)

let filter_by_capabilities ~(pred : Llm_provider.Capabilities.capabilities -> bool)
    (providers : Llm_provider.Provider_config.t list) =
  let satisfies (cfg : Llm_provider.Provider_config.t) =
    let caps = match Llm_provider.Capabilities.for_model_id cfg.model_id with
      | Some c -> c
      | None ->
        match Llm_provider.Provider_registry.find default_registry cfg.model_id with
        | Some entry -> entry.capabilities
        | None -> Llm_provider.Capabilities.default_capabilities
    in
    pred caps
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
  |> String.concat ""

(* ── Model resolution: named -> "default" -> hardcoded ─── *)

type cascade_source = Named | Default_fallback | Hardcoded_defaults

(** Weighted shuffle: pick first element by weighted random, then order
    remaining by descending weight.  This gives probabilistic distribution
    of first-attempt provider while maintaining a deterministic fallback
    chain.  Callers preserve backward-compatible fixed ordering by
    skipping shuffle when every weight is 1.

    Algorithm (LiteLLM simple-shuffle inspired):
    1. Compute cumulative weights
    2. Pick random value in [0, total_weight)
    3. Selected item becomes first; rest sorted by weight desc

    @since 0.137.0 *)
(* Shared weighted-shuffle RNG.  Protect draws with Stdlib.Mutex because
   [Random.State.int] mutates the state and this path can be hit from
   concurrent server fibers. *)
let weighted_shuffle_rng = Random.State.make_self_init ()
let weighted_shuffle_rng_mu = Mutex.create ()

let weighted_random_int bound =
  Mutex.protect weighted_shuffle_rng_mu (fun () ->
    Random.State.int weighted_shuffle_rng bound)

let weighted_shuffle
    ?(rand_int = weighted_random_int)
    (entries : Cascade_config_loader.weighted_entry list)
    : Cascade_config_loader.weighted_entry list =
  match entries with
  | [] | [_] -> entries
  | first :: rest ->
    let total_weight =
      List.fold_left (fun acc (e : Cascade_config_loader.weighted_entry) ->
          acc + e.weight) 0 entries
    in
    if total_weight <= 0 then entries
    else
      let r = rand_int total_weight in
      let default_selected, default_remaining = (first, rest) in
      (* Find the selected entry via cumulative weight *)
      let rec find_selected cumulative = function
        | [] -> (* fallback: first entry *)
          (default_selected, default_remaining)
        | (e : Cascade_config_loader.weighted_entry) :: rest ->
          let cumulative' = cumulative + e.weight in
          if r < cumulative' then (e, rest)
          else
            let selected, remaining = find_selected cumulative' rest in
            (selected, e :: remaining)
      in
      let selected, remaining = find_selected 0 entries in
      (* Sort remaining by descending weight for fallback priority.
         Use index as tiebreaker to preserve original config order
         among equal-weight entries (stable sort). *)
      let indexed = List.mapi (fun i e -> (i, e)) remaining in
      let sorted_remaining =
        List.sort (fun (i1, (a : Cascade_config_loader.weighted_entry))
                       (i2, (b : Cascade_config_loader.weighted_entry)) ->
            let cmp = compare b.weight a.weight in
            if cmp <> 0 then cmp else compare i1 i2
          ) indexed
        |> List.map snd
      in
      selected :: sorted_remaining

let order_weighted_entries
    ?(rand_int = weighted_random_int)
    (entries : Cascade_config_loader.weighted_entry list) =
  let has_weights = List.exists
      (fun (e : Cascade_config_loader.weighted_entry) -> e.weight <> 1)
      entries
  in
  if not has_weights then entries
  else
    let health = Cascade_health_tracker.global in
    let health_adjusted = List.map
        (fun (e : Cascade_config_loader.weighted_entry) ->
           (* Extract model_id from "provider:model_id" to match the key
              used by cascade_executor (cfg.model_id). *)
           let provider_key = match String.split_on_char ':' e.model with
             | _ :: rest when rest <> [] -> String.concat ":" rest
             | _ -> e.model
           in
           let ew = Cascade_health_tracker.effective_weight health
               ~provider_key ~config_weight:e.weight in
           { e with weight = ew })
        entries
    in
    (* Filter out zero-weight (cooled-down) providers, but keep at least one *)
    let active = List.filter
        (fun (e : Cascade_config_loader.weighted_entry) -> e.weight > 0)
        health_adjusted
    in
    let effective = if active = [] then entries else active in
    weighted_shuffle ~rand_int effective

let resolve_model_strings_traced_with
    ~rand_int ?config_path ~name ~defaults () =
  match config_path with
  | Some path ->
    let from_file_weighted =
      Cascade_config_loader.load_profile_weighted ~config_path:path ~name in
    if from_file_weighted <> [] then
      let ordered = order_weighted_entries ~rand_int from_file_weighted in
      let models = List.map
          (fun (e : Cascade_config_loader.weighted_entry) -> e.model) ordered in
      (models, Named)
    else
      let fallback_weighted =
        Cascade_config_loader.load_profile_weighted
          ~config_path:path ~name:"default" in
      if fallback_weighted <> [] then
        let ordered = order_weighted_entries ~rand_int fallback_weighted in
        let models = List.map
            (fun (e : Cascade_config_loader.weighted_entry) -> e.model)
            ordered in
        (models, Default_fallback)
      else (defaults, Hardcoded_defaults)
  | None -> (defaults, Hardcoded_defaults)

let resolve_model_strings_traced ?config_path ~name ~defaults () =
  resolve_model_strings_traced_with
    ~rand_int:weighted_random_int
    ?config_path ~name ~defaults ()

let resolve_model_strings ?config_path ~name ~defaults () =
  fst (resolve_model_strings_traced ?config_path ~name ~defaults ())

(* ── Selection trace (observability) ─────────────────── *)

type candidate_info = {
  model_string : string;
  config_weight : int;
  effective_weight : int;
  success_rate : float;
  in_cooldown : bool;
}

type selection_trace = {
  candidates : candidate_info list;
  source : cascade_source;
}

(** Extract the provider_key the health tracker uses for a "provider:model"
    string. Mirrors the derivation in {!order_weighted_entries}. *)
let provider_key_of_model_string s =
  match String.split_on_char ':' s with
  | _ :: rest when rest <> [] -> String.concat ":" rest
  | _ -> s

(** Build a [candidate_info] for a model string given its config weight.
    Reads current health tracker state for [success_rate] / [in_cooldown]
    / [effective_weight], so the trace reflects state at call time. *)
let candidate_info_of_weighted (e : Cascade_config_loader.weighted_entry) =
  let health = Cascade_health_tracker.global in
  let key = provider_key_of_model_string e.model in
  let success_rate = Cascade_health_tracker.success_rate health ~provider_key:key in
  let in_cooldown = Cascade_health_tracker.is_in_cooldown health ~provider_key:key in
  let effective_weight =
    Cascade_health_tracker.effective_weight health
      ~provider_key:key ~config_weight:e.weight
  in
  {
    model_string = e.model;
    config_weight = e.weight;
    effective_weight;
    success_rate;
    in_cooldown;
  }

let resolve_model_strings_with_trace ?config_path ~name ~defaults () =
  match config_path with
  | Some path ->
    let from_file_weighted =
      Cascade_config_loader.load_profile_weighted ~config_path:path ~name in
    if from_file_weighted <> [] then
      let ordered = order_weighted_entries from_file_weighted in
      let models = List.map
          (fun (e : Cascade_config_loader.weighted_entry) -> e.model) ordered in
      let candidates = List.map candidate_info_of_weighted ordered in
      (models, { candidates; source = Named })
    else
      let fallback_weighted =
        Cascade_config_loader.load_profile_weighted
          ~config_path:path ~name:"default" in
      if fallback_weighted <> [] then
        let ordered = order_weighted_entries fallback_weighted in
        let models = List.map
            (fun (e : Cascade_config_loader.weighted_entry) -> e.model) ordered in
        let candidates = List.map candidate_info_of_weighted ordered in
        (models, { candidates; source = Default_fallback })
      else
        let candidates =
          List.map (fun m ->
            candidate_info_of_weighted
              { Cascade_config_loader.model = m; weight = 1; supports_tool_choice = None })
            defaults
        in
        (defaults, { candidates; source = Hardcoded_defaults })
  | None ->
    let candidates =
      List.map (fun m ->
        candidate_info_of_weighted
          { Cascade_config_loader.model = m; weight = 1; supports_tool_choice = None })
        defaults
    in
    (defaults, { candidates; source = Hardcoded_defaults })

let dedupe_stable (items : string list) =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | item :: rest ->
      if List.mem item seen then loop seen acc rest
      else loop (item :: seen) (item :: acc) rest
  in
  loop [] [] items

let expand_model_strings_for_execution (items : string list) =
  let expand_one raw =
    let item = String.trim raw in
    if item = "" then []
    else
      match split_provider_model item with
      | Some ("glm", model_id)
        when String.lowercase_ascii model_id = "auto" ->
        [item; "glm:turbo"; "glm:flash"]
      | Some ("glm-coding", model_id)
        when String.lowercase_ascii model_id = "auto" ->
        [item; "glm-coding:glm-5-turbo"; "glm-coding:glm-5.1";
         "glm-coding:glm-4.5-air"]
      | _ -> [item]
  in
  items
  |> List.concat_map expand_one
  |> dedupe_stable

(* Filter providers by kind name (exact, case-insensitive).
   Valid filter values: "ollama", "glm", "anthropic", "gemini", "openai_compat", "claude_code".
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
      Eio.traceln "[CascadeConfig] provider_filter matched no providers (%s); \
        falling back to unfiltered (filter=[%s] providers=[%s])"
        label (String.concat "," filters)
        (String.concat "," (List.map (fun (p : Llm_provider.Provider_config.t) ->
          Llm_provider.Provider_config.string_of_provider_kind p.kind) providers));
      providers)
    else filtered

(* ── Local Capacity Query ──────────────────────────────── *)

type local_capacity = {
  total : int;
  process_active : int;
  process_available : int;
  process_queue_length : int;
  all_discovered : bool;
  endpoints_found : int;
}

let empty_capacity = {
  total = 0; process_active = 0; process_available = 0;
  process_queue_length = 0; all_discovered = true; endpoints_found = 0;
}

let local_capacity_for_selections ~sw ~net ?config_path selections =
  (* 1. Resolve each selection through the same path as complete_named *)
  let model_strings =
    selections
    |> List.concat_map (fun s ->
         resolve_model_strings ?config_path ~name:s ~defaults:[s] ())
    |> expand_model_strings_for_execution
    |> List.sort_uniq String.compare
  in
  (* 2. Parse to provider configs *)
  let providers = parse_model_strings model_strings in
  (* 3. Filter to local providers *)
  let local_urls =
    providers
    |> List.filter is_local_provider
    |> List.map (fun (cfg : Llm_provider.Provider_config.t) -> cfg.base_url)
    |> List.sort_uniq String.compare
  in
  if local_urls = [] then
    empty_capacity
  else begin
    (* 4. Probe endpoints not yet in throttle table (cold start) *)
    let need_probe =
      List.filter (fun url -> Cascade_throttle.lookup url = None) local_urls
    in
    if need_probe <> [] then begin
      let statuses = Llm_provider.Discovery.discover ~sw ~net ~endpoints:need_probe in
      Cascade_throttle.populate statuses
    end;
    (* 5. Aggregate capacity from throttle table *)
    let infos =
      List.filter_map (fun url -> Cascade_throttle.capacity url) local_urls
    in
    match infos with
    | [] -> empty_capacity
    | _ ->
      List.fold_left (fun acc (info : Cascade_throttle.capacity_info) ->
        { total = acc.total + info.total;
          process_active = acc.process_active + info.process_active;
          process_available = acc.process_available + info.process_available;
          process_queue_length = acc.process_queue_length + info.process_queue_length;
          all_discovered = acc.all_discovered
            && info.source = Llm_provider.Provider_throttle.Discovered;
          endpoints_found = acc.endpoints_found + 1;
        })
        { empty_capacity with all_discovered = true }
        infos
  end

(* ── Pluggable strategy resolution (since 0.9.6) ─────── *)

(* One-time warning per (cascade name, raw value) pair so misspelled
   strategy fields do not flood the log on every keeper turn. *)
let strategy_warned : (string * string, unit) Hashtbl.t = Hashtbl.create 4

let warn_unknown_strategy ~name ~raw ~msg =
  let key = (name, raw) in
  if not (Hashtbl.mem strategy_warned key) then begin
    Hashtbl.add strategy_warned key ();
    Printf.eprintf
      "[warn] cascade %s: %s; falling back to failover\n%!" name msg
  end

let parse_kind_or_default ~name = function
  | None -> Cascade_strategy.Failover
  | Some raw ->
    match Cascade_strategy.parse_kind raw with
    | Ok k -> k
    | Error msg ->
      warn_unknown_strategy ~name ~raw ~msg;
      Cascade_strategy.Failover

let cycle_policy_from_loader (cfg : Cascade_config_loader.strategy_config) =
  let d = Cascade_strategy.default_cycle_policy in
  let max_cycles = match cfg.max_cycles with
    | Some n when n >= 1 -> n
    | _ -> d.max_cycles
  in
  let backoff_base_ms = match cfg.backoff_base_ms with
    | Some n when n >= 1 -> n
    | _ -> d.backoff_base_ms
  in
  let backoff_cap_ms = match cfg.backoff_cap_ms with
    | Some n when n >= backoff_base_ms -> n
    | Some _ -> backoff_base_ms       (* cap < base: clamp up *)
    | None -> max d.backoff_cap_ms backoff_base_ms
  in
  { Cascade_strategy.max_cycles; backoff_base_ms; backoff_cap_ms }

let resolve_strategy ?config_path ~name () =
  match config_path with
  | None -> Cascade_strategy.failover
  | Some path ->
    let cfg = Cascade_config_loader.resolve_strategy_config
                ~config_path:path ~name in
    let kind = parse_kind_or_default ~name cfg.kind in
    let cycle = cycle_policy_from_loader cfg in
    let tiers =
      match kind, cfg.tiers with
      | Cascade_strategy.Priority_tier, Some t -> t
      | Cascade_strategy.Priority_tier, None -> []  (* misconfig → empty tier *)
      | _, _ -> []
    in
    let sticky_ttl_ms =
      match kind, cfg.sticky_ttl_ms with
      | Cascade_strategy.Sticky, Some n -> n
      | Cascade_strategy.Sticky, None -> Cascade_strategy.default_sticky_ttl_ms
      | _, _ -> 0
    in
    { Cascade_strategy.kind; cycle; tiers; sticky_ttl_ms }

let resolve_ollama_max_concurrent ?config_path ~name () =
  match config_path with
  | None -> None
  | Some path ->
    let cfg = Cascade_config_loader.resolve_strategy_config
                ~config_path:path ~name in
    cfg.ollama_max_concurrent

let resolve_cli_max_concurrent ?config_path ~name () =
  match config_path with
  | None -> None
  | Some path ->
    let cfg = Cascade_config_loader.resolve_strategy_config
                ~config_path:path ~name in
    cfg.cli_max_concurrent
