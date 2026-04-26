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
  keep_alive: string option;
  num_ctx: int option;
}

let resolve_inference_params = Cascade_config_loader.resolve_inference_params
let resolve_api_key_env = Cascade_config_loader.resolve_api_key_env

(* ── Provider registry (SSOT: Provider_registry) ─────── *)

let default_registry = Llm_provider.Provider_registry.default ()

(* Build headers list with Authorization when api_key is present.
   Anthropic/Kimi use x-api-key; OpenAI-compat (including GLM) uses Bearer. *)
let headers_with_auth ~(kind : Llm_provider.Provider_config.provider_kind) ~api_key =
  let base = [("Content-Type", "application/json")] in
  if api_key = "" then base
  else match kind with
    | Anthropic | Kimi ->
        ("x-api-key", api_key)
        :: ("anthropic-version", "2023-06-01")
        :: base
    | OpenAI_compat | Ollama | Gemini | Glm | Claude_code | DashScope ->
        ("Authorization", "Bearer " ^ api_key) :: base
    | Gemini_cli | Kimi_cli | Codex_cli -> []

let trim_trailing_slash path =
  if String.length path > 1 && String.ends_with ~suffix:"/" path then
    String.sub path 0 (String.length path - 1)
  else path

let normalize_openai_compat_request_path ~base_url ~request_path =
  let request_path =
    match String.trim request_path with
    | "" -> Masc_network_defaults.openai_chat_completions_path
    | path -> path
  in
  let base_path =
    Uri.path (Uri.of_string base_url) |> trim_trailing_slash
  in
  if base_path = "" || base_path = "/" then
    request_path
  else
    let duplicated_prefix = base_path ^ "/" in
    if String.starts_with ~prefix:duplicated_prefix request_path then
      let suffix_start = String.length base_path + 1 in
      "/"
      ^ String.sub request_path suffix_start
          (String.length request_path - suffix_start)
    else request_path

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
    ?supports_tool_choice_override ?keep_alive ?num_ctx model_id =
  let actual_model, base_url = parse_custom_model model_id in
  if actual_model = "" then None
  else Some (Llm_provider.Provider_config.make
               ~kind:OpenAI_compat
               ~model_id:actual_model
               ~base_url
               ~request_path:
                 (normalize_openai_compat_request_path
                    ~base_url
                    ~request_path:Masc_network_defaults.openai_chat_completions_path)
               ~temperature
               ~max_tokens
               ?system_prompt
               ?supports_tool_choice_override
               ?keep_alive
               ?num_ctx
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

let nonempty_env name =
  match Sys.getenv_opt name with
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
  | None -> None

let env_url_or ~env ~default =
  match nonempty_env env with
  | Some url -> url
  | None -> default

let kimi_provider_name = "kimi"
let moonshot_base_url_env = "KIMI_BASE_URL"
let moonshot_api_key_env = "KIMI_API_KEY_SB"
let moonshot_default_base_url = "https://api.moonshot.ai/v1"

(* #9953: Resolve Kimi max_context from the OAS capabilities SSOT.

   Prior code hard-coded [256_000] here, which drifted from the
   OAS [Capabilities.kimi_capabilities.max_context_tokens] value
   of [262_144] (the canonical 256 KiB binary context window).
   Same-label [kimi] turns therefore recorded two different
   [context_max] values depending on which config builder ran —
   one symptom of the 3-way [claude_code:auto] drift documented
   in the issue.

   Resolution order:
   1. Per-model capabilities override ({!Capabilities.for_model_id}
      resolved id) — allows future per-variant overrides to take
      effect without touching this file.
   2. Provider-level [kimi_capabilities.max_context_tokens] from
      the OAS SSOT.
   3. Registry entry default (safety net for exotic configs).
*)
let resolve_kimi_max_context resolved_model_id =
  let open Llm_provider in
  let from_model =
    Option.bind
      (Capabilities.for_model_id resolved_model_id)
      (fun c -> c.Capabilities.max_context_tokens)
  in
  match from_model with
  | Some n -> n
  | None ->
    (match Capabilities.kimi_capabilities.max_context_tokens with
     | Some n -> n
     | None ->
       (* OAS SSOT has always populated this; fall through to
          registry entry only if OAS removes the field. *)
       (match Provider_registry.find (Provider_registry.default ())
                kimi_provider_name with
        | Some entry -> entry.Provider_registry.max_context
        | None -> 0))

let is_kimi_provider provider_name =
  String.equal provider_name kimi_provider_name

let moonshot_api_url () =
  env_url_or ~env:moonshot_base_url_env ~default:moonshot_default_base_url

let moonshot_request_path () =
  normalize_openai_compat_request_path
    ~base_url:(moonshot_api_url ())
    ~request_path:Masc_network_defaults.openai_chat_completions_path

let resolve_kimi_api_key_env ~api_key_env_overrides =
  resolve_effective_api_key_env
    ~api_key_env_overrides
    ~provider_name:kimi_provider_name
    ~registry_default:moonshot_api_key_env

let kimi_is_available ~api_key_env_overrides =
  match resolve_kimi_api_key_env ~api_key_env_overrides with
  | "" -> false
  | env_name -> Option.is_some (nonempty_env env_name)
    || Option.is_some (nonempty_env "KIMI_API_KEY")

let make_kimi_config ~temperature ~max_tokens ?system_prompt
    ?(api_key_env_overrides = []) ?supports_tool_choice_override
    ?keep_alive ?num_ctx model_id =
  let effective_api_key_env =
    resolve_kimi_api_key_env ~api_key_env_overrides
  in
  let api_key =
    match nonempty_env effective_api_key_env with
    | Some value -> value
    | None ->
      (match nonempty_env "KIMI_API_KEY" with
       | Some value -> value
       | None -> "")
  in
  let headers = headers_with_auth ~kind:OpenAI_compat ~api_key in
  let resolved_model_id =
    resolve_auto_model_id kimi_provider_name model_id
  in
  Llm_provider.Provider_config.make
    ~kind:OpenAI_compat
    ~model_id:resolved_model_id
    ~base_url:(moonshot_api_url ())
    ~api_key
    ~headers
    ~request_path:(moonshot_request_path ())
    ~temperature
    ~max_tokens
    ~max_context:(resolve_kimi_max_context resolved_model_id)
    ?system_prompt
    ?supports_tool_choice_override
    ?keep_alive
    ?num_ctx
    ()

(** Build a {!Llm_provider.Provider_config.t} from a registry entry. *)
let make_registry_config ~temperature ~max_tokens ?system_prompt
    ?(api_key_env_overrides=[]) ?supports_tool_choice_override
    ?keep_alive ?num_ctx
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
  let request_path =
    match defaults.kind with
    | OpenAI_compat ->
      normalize_openai_compat_request_path
        ~base_url
        ~request_path:defaults.request_path
    | _ -> defaults.request_path
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
    ~request_path
    ~temperature
    ~max_tokens
    ~max_context
    ?system_prompt
    ?supports_tool_choice_override
    ?keep_alive
    ?num_ctx
    ()

(* ── Model string parsing ──────────────────────────────── *)

let parse_model_string
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?(max_tokens = Llm_provider.Constants.Inference.default_max_tokens)
    ?system_prompt ?(api_key_env_overrides = [])
    ?supports_tool_choice_override
    ?keep_alive ?num_ctx
    (s : string) : Llm_provider.Provider_config.t option =
  let trimmed = String.trim s in
  match split_provider_model trimmed with
  | Some ("custom", model_id) ->
    (match make_custom_config ~temperature ~max_tokens ?system_prompt
             ?supports_tool_choice_override ?keep_alive ?num_ctx
             model_id with
     | Some cfg -> Some cfg
     | None -> None)
  | Some (provider_name, model_id) when is_kimi_provider provider_name ->
    if kimi_is_available ~api_key_env_overrides then
      Some
        (make_kimi_config ~temperature ~max_tokens ?system_prompt
           ~api_key_env_overrides ?supports_tool_choice_override
           ?keep_alive ?num_ctx
           model_id)
    else None
  | _ ->
  (* Kind classification goes through [Provider_kind_resolver] — a sum-typed
     resolver that consults Provider_registry as SSOT and never flattens
     unknown specs to [OpenAI_compat]. This keeps ["gemini:gemini-2.5-flash"]
     from being misclassified by any downstream substring heuristic
     (issue #8159). *)
    match Provider_kind_resolver.resolve s with
    | Unknown _ -> None
    | Custom_url _ -> None
    | Registered { provider_name; model_id; kind = resolved_kind } ->
      match Llm_provider.Provider_registry.find default_registry provider_name with
      | None -> None  (* registry lookup race or unloaded entry *)
      | Some entry when not (entry.is_available ()) -> None
      | Some entry ->
        (* Defensive invariant: the resolver and the registry must agree on
           the kind. If they diverge we have a registry bug or a resolver
           bug; fail closed rather than emit a degraded config. *)
        if entry.defaults.kind <> resolved_kind then None
        else
          Some (make_registry_config ~temperature ~max_tokens ?system_prompt
                  ~api_key_env_overrides ?supports_tool_choice_override
                  ?keep_alive ?num_ctx
                  ~provider_name ~model_id entry)

(** Parse a {!Cascade_config_loader.weighted_entry} into a
    {!Llm_provider.Provider_config.t}, forwarding the entry's
    [supports_tool_choice] override. The [weight] is not part of the
    Provider_config; it drives cascade ordering separately. *)
let parse_weighted_entry
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?(max_tokens = Llm_provider.Constants.Inference.default_max_tokens)
    ?system_prompt ?(api_key_env_overrides = [])
    ?keep_alive ?num_ctx
    (entry : Cascade_config_loader.weighted_entry)
  : Llm_provider.Provider_config.t option =
  parse_model_string ~temperature ~max_tokens ?system_prompt
    ~api_key_env_overrides
    ?supports_tool_choice_override:entry.supports_tool_choice
    ?keep_alive ?num_ctx
    entry.model

(** Categorised diagnostic for a failed weighted-entry parse. *)
type weighted_entry_drop =
  | Drop_unregistered_scheme of { model : string; scheme : string }
  | Drop_unavailable_scheme of { model : string; scheme : string }
  | Drop_invalid_syntax of string

(** Parse a weighted entry, distinguishing why it was rejected (unregistered
    scheme, unavailable scheme, invalid syntax). Used by
    {!parse_weighted_entries} to produce actionable load-time diagnostics
    instead of silently discarding entries via [List.filter_map]. *)
let parse_weighted_entry_diag
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?(max_tokens = Llm_provider.Constants.Inference.default_max_tokens)
    ?system_prompt ?(api_key_env_overrides = [])
    ?keep_alive ?num_ctx
    (entry : Cascade_config_loader.weighted_entry)
  : (Llm_provider.Provider_config.t, weighted_entry_drop) result =
  let raw = String.trim entry.model in
  match split_provider_model raw with
  | None -> Error (Drop_invalid_syntax raw)
  | Some ("custom", model_id) ->
    (match make_custom_config ~temperature ~max_tokens ?system_prompt
             ?supports_tool_choice_override:entry.supports_tool_choice
             ?keep_alive ?num_ctx model_id with
     | Some c -> Ok c
     | None -> Error (Drop_invalid_syntax raw))
  | Some (provider_name, model_id) when is_kimi_provider provider_name ->
    if kimi_is_available ~api_key_env_overrides then
      Ok
        (make_kimi_config ~temperature ~max_tokens ?system_prompt
           ~api_key_env_overrides
           ?supports_tool_choice_override:entry.supports_tool_choice
           ?keep_alive ?num_ctx
           model_id)
    else
      Error (Drop_unavailable_scheme { model = raw; scheme = provider_name })
  | Some (provider_name, model_id) ->
    match Llm_provider.Provider_registry.find default_registry provider_name with
    | None ->
      Error (Drop_unregistered_scheme { model = raw; scheme = provider_name })
    | Some reg_entry when not (reg_entry.is_available ()) ->
      Error (Drop_unavailable_scheme { model = raw; scheme = provider_name })
    | Some reg_entry ->
      Ok (make_registry_config ~temperature ~max_tokens ?system_prompt
            ~api_key_env_overrides
            ?supports_tool_choice_override:entry.supports_tool_choice
            ?keep_alive ?num_ctx
            ~provider_name ~model_id reg_entry)

(** Expand provider:auto specs that map to multiple models.
    "glm:auto" expands to ["glm:glm-5.1"; "glm:glm-5-turbo"; ...].
    CLI-backed transports expand too, so a single [gemini_cli:auto] can
    cascade through concrete CLI model overrides instead of delegating to
    the CLI's interactive/default model picker. Other specs pass through
    as-is. *)
let rotate_list_by offset items =
  if offset <= 0 then items
  else
    let rec split i acc = function
      | xs when i <= 0 -> (List.rev acc, xs)
      | [] -> (List.rev acc, [])
      | x :: rest -> split (i - 1) (x :: acc) rest
    in
    let head, tail = split offset [] items in
    tail @ head

let maybe_rotate_auto_models ?rotation_scope ~spec models =
  match rotation_scope, models with
  | Some scope, _ :: _ :: _ ->
    let cursor =
      Cascade_state.rotate_round_robin
        ~cascade:(Printf.sprintf "auto-expand:%s:%s"
                    scope (String.lowercase_ascii spec))
        ~bound:(List.length models)
    in
    rotate_list_by cursor models
  | _ -> models

let maybe_rotate_weighted_entries
    ?rotation_scope
    (entries : Cascade_config_loader.weighted_entry list) =
  match rotation_scope, entries with
  | Some scope, _ :: _ :: _
    when List.for_all
        (fun (e : Cascade_config_loader.weighted_entry) -> e.weight = 1)
        entries ->
    let cursor =
      Cascade_state.rotate_round_robin
        ~cascade:(Printf.sprintf "entry-order:%s" scope)
        ~bound:(List.length entries)
    in
    rotate_list_by cursor entries
  | _ -> entries

let expand_provider_auto ?rotation_scope ~spec provider models =
  maybe_rotate_auto_models ?rotation_scope ~spec models
  |> List.map (fun model -> provider ^ ":" ^ model)

let expand_auto_model_string ?rotation_scope (s : string) : string list =
  let trimmed = String.trim s in
  match split_provider_model trimmed with
  | Some (provider_name, model_id)
    when String_util.equals_ci model_id "auto" -> (
      match Provider_adapter.auto_models_for_cascade_prefix provider_name with
      | Some models when models <> [] ->
          expand_provider_auto ?rotation_scope ~spec:trimmed provider_name models
      | _ -> [ trimmed ])
  | _ -> [ trimmed ]

let expand_auto_models (strs : string list) : string list =
  List.concat_map expand_auto_model_string strs

let expand_weighted_auto_entries
    ?rotation_scope
    (entries : Cascade_config_loader.weighted_entry list) =
  List.concat_map
    (fun (entry : Cascade_config_loader.weighted_entry) ->
       expand_auto_model_string ?rotation_scope entry.model
       |> List.map (fun model -> { entry with model }))
    entries

(** Parse a list of weighted entries, dropping ones that cannot produce a
    provider config. Load-time drops are logged once per call with
    categorised reasons so upstream drift (e.g. a cascade.json entry
    referencing an unregistered provider scheme due to library/binary
    version skew) surfaces as ERROR rather than silently filtering away.

    If [cascade_name] is supplied it appears in the log message. *)
let parse_weighted_entries
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?(max_tokens = Llm_provider.Constants.Inference.default_max_tokens)
    ?system_prompt ?(api_key_env_overrides = [])
    ?(cascade_name = "")
    (entries : Cascade_config_loader.weighted_entry list)
  : Llm_provider.Provider_config.t list =
  let entries = expand_weighted_auto_entries entries in
  let parsed, unregistered, unavailable, invalid =
    List.fold_left
      (fun (acc, unr, unv, inv) entry ->
         match parse_weighted_entry_diag ~temperature ~max_tokens
                 ?system_prompt ~api_key_env_overrides entry with
         | Ok c -> (c :: acc, unr, unv, inv)
         | Error (Drop_unregistered_scheme { model; scheme }) ->
           (acc, (model, scheme) :: unr, unv, inv)
         | Error (Drop_unavailable_scheme { model; scheme }) ->
           (acc, unr, (model, scheme) :: unv, inv)
         | Error (Drop_invalid_syntax s) -> (acc, unr, unv, s :: inv))
      ([], [], [], [])
      entries
  in
  let label =
    if cascade_name = "" then "cascade" else Printf.sprintf "cascade %S" cascade_name
  in
  let render_drops drops =
    String.concat ", "
      (List.map (fun (model, scheme) ->
         Printf.sprintf "%s (scheme=%s)" model scheme) drops)
  in
  (if unregistered <> [] then
     Log.Misc.error
       "%s: dropped %d entry/entries referencing unregistered provider \
        scheme(s): [%s]. Likely library/binary drift or cascade.json typo \
        — rebuild or fix the config entry."
       label (List.length unregistered) (render_drops unregistered));
  (if invalid <> [] then
     Log.Misc.error
       "%s: dropped %d invalid-syntax entry/entries: [%s]"
       label (List.length invalid) (String.concat ", " invalid));
  (if unavailable <> [] then
     Log.Misc.warn
       "%s: skipped %d unavailable entry/entries (missing credential or \
        CLI binary): [%s]"
       label (List.length unavailable) (render_drops unavailable));
  (if parsed = [] && entries <> [] then
     Log.Misc.error
       "%s: all %d configured entries filtered out — cascade will \
        produce no responses until at least one entry resolves"
       label (List.length entries));
  List.rev parsed

let parse_model_string_result
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
  | Some (provider_name, model_id) when is_kimi_provider provider_name ->
    if kimi_is_available ~api_key_env_overrides:[] then
      Ok (make_kimi_config ~temperature ~max_tokens ?system_prompt model_id)
    else
      Error
        (Printf.sprintf "provider %S unavailable (missing env var %S)"
           provider_name
           (resolve_kimi_api_key_env ~api_key_env_overrides:[]))
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
  |> fun lst -> List.fold_left (fun acc s -> acc ^ s) "" lst

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
(* Shared weighted-shuffle RNG.  Protect draws because [Random.State.int]
   mutates the state and this path can be hit from concurrent server fibers.
   Use [Stdlib.Mutex], not [Eio.Mutex]: selection-trace/dashboard helpers are
   also exercised from non-Eio contexts where [Eio.Mutex] raises
   [Effect.Unhandled(Cancel.Get_context)].  The critical section is a single
   RNG draw, so blocking briefly is acceptable. *)
let weighted_shuffle_rng = Random.State.make_self_init ()
let weighted_shuffle_rng_mu = Stdlib.Mutex.create ()

let weighted_random_int bound =
  Stdlib.Mutex.protect weighted_shuffle_rng_mu (fun () ->
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
    ?rotation_scope
    (entries : Cascade_config_loader.weighted_entry list) =
  let entries = maybe_rotate_weighted_entries ?rotation_scope entries in
  let entries = expand_weighted_auto_entries ?rotation_scope entries in
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
              used by the cascade runtime (cfg.model_id; see
              cascade_runtime.ml + cascade_strategy.ml). *)
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
  display_model_string : string;
  provider_name : string option;
  display_provider_name : string option;
  runtime_kind : string option;
  expanded_models : string list;
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

let display_model_string s =
  match split_provider_model s with
  | Some (provider_name, model_id) ->
      Printf.sprintf "%s:%s"
        (Provider_adapter.display_provider_name provider_name)
        model_id
  | None -> s

let runtime_kind_of_provider_name provider_name =
  match Provider_adapter.resolve_direct_adapter provider_name with
  | Some adapter -> Some (Provider_adapter.string_of_runtime_kind adapter.runtime_kind)
  | None -> None

(** Build a [candidate_info] for a model string given its config weight.
    Reads current health tracker state for [success_rate] / [in_cooldown]
    / [effective_weight], so the trace reflects state at call time. *)
let candidate_info_of_weighted (e : Cascade_config_loader.weighted_entry) =
  let health = Cascade_health_tracker.global in
  let expanded_raw_models = expand_auto_model_string e.model in
  let provider_keys = List.map provider_key_of_model_string expanded_raw_models in
  let health_rows =
    List.map
      (fun provider_key ->
         let success_rate =
           Cascade_health_tracker.success_rate health ~provider_key
         in
         let in_cooldown =
           Cascade_health_tracker.is_in_cooldown health ~provider_key
         in
         let effective_weight =
           Cascade_health_tracker.effective_weight health
             ~provider_key ~config_weight:e.weight
         in
         (success_rate, in_cooldown, effective_weight))
      provider_keys
  in
  let success_rate =
    let preferred =
      health_rows
      |> List.filter_map (fun (rate, cooled_down, _weight) ->
             if cooled_down then None else Some rate)
    in
    let source =
      match preferred with
      | _ :: _ -> preferred
      | [] -> List.map (fun (rate, _cooled_down, _weight) -> rate) health_rows
    in
    List.fold_left Float.max 0.0 source
  in
  let in_cooldown =
    match health_rows with
    | [] -> false
    | rows -> List.for_all (fun (_rate, cooled_down, _weight) -> cooled_down) rows
  in
  let effective_weight =
    List.fold_left
      (fun acc (_rate, _cooled_down, weight) -> Int.max acc weight)
      0
      health_rows
  in
  let provider_name, display_provider_name, runtime_kind =
    match split_provider_model e.model with
    | Some (provider_name, _model_id) ->
        let display_name = Provider_adapter.display_provider_name provider_name in
        (Some provider_name, Some display_name,
         runtime_kind_of_provider_name provider_name)
    | None -> (None, None, None)
  in
  {
    model_string = e.model;
    display_model_string = display_model_string e.model;
    provider_name;
    display_provider_name;
    runtime_kind;
    expanded_models = List.map display_model_string expanded_raw_models;
    config_weight = e.weight;
    effective_weight;
    success_rate;
    in_cooldown;
  }

let selection_trace_of_weighted_entries
    ?(source = Named)
    (entries : Cascade_config_loader.weighted_entry list) : selection_trace =
  let ordered = order_weighted_entries entries in
  let candidates = List.map candidate_info_of_weighted ordered in
  { candidates; source }

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

let expand_model_strings_for_execution ?rotation_scope (items : string list) =
  items
  |> List.concat_map (expand_auto_model_string ?rotation_scope)
  |> dedupe_stable

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

let warn_unknown_strategy ~name ~raw ~msg ~fallback_kind =
  let key = (name, raw) in
  if not (Hashtbl.mem strategy_warned key) then begin
    Hashtbl.add strategy_warned key ();
    Printf.eprintf
      "[warn] cascade %s: %s; falling back to %s\n%!"
      name msg (Cascade_strategy.kind_to_string fallback_kind)
  end

let invalid_priority_tier_warned : (string * string, unit) Hashtbl.t =
  Hashtbl.create 4

let warn_invalid_priority_tier ~name ~msg ~fallback_kind =
  let key = (name, msg) in
  if not (Hashtbl.mem invalid_priority_tier_warned key) then begin
    Hashtbl.add invalid_priority_tier_warned key ();
    Printf.eprintf
      "[warn] cascade %s: %s; falling back to %s\n%!"
      name msg (Cascade_strategy.kind_to_string fallback_kind)
  end

let default_strategy_kind ?config_path ~name () =
  match config_path with
  | None -> Cascade_strategy.Failover
  | Some path ->
    (match Cascade_config_loader.load_catalog ~config_path:path with
     | Ok entries ->
       (match
          List.find_opt
            (fun (entry : Cascade_config_loader.catalog_entry) ->
               String.equal entry.name name)
            entries
        with
        | Some entry when entry.keeper_assignable ->
            Cascade_strategy.Round_robin
        | _ -> Cascade_strategy.Failover)
     | Error _ -> Cascade_strategy.Failover)

let parse_kind_or_default ~name ~default_kind = function
  | None -> default_kind
  | Some raw ->
    match Cascade_strategy.parse_kind raw with
    | Ok k -> k
    | Error msg ->
      warn_unknown_strategy ~name ~raw ~msg ~fallback_kind:default_kind;
      default_kind

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

let model_ids_of_specs (specs : string list) : string list =
  specs
  |> List.concat_map expand_auto_model_string
  |> List.filter_map (fun spec ->
         match split_provider_model spec with
         | Some (_, model_id) when model_id <> "" -> Some model_id
         | _ -> None)
  |> List.sort_uniq String.compare

let normalize_priority_tiers ~config_path ~name raw_tiers =
  let configured_model_ids =
    Cascade_config_loader.load_profile_weighted ~config_path ~name
    |> List.map (fun (entry : Cascade_config_loader.weighted_entry) -> entry.model)
    |> model_ids_of_specs
  in
  if configured_model_ids = [] then
    Error "priority_tier has no configured models to validate against"
  else
    let normalized =
      raw_tiers
      |> List.filter_map (fun tier ->
             let tier_model_ids =
               model_ids_of_specs tier
               |> List.filter (fun model_id ->
                      List.mem model_id configured_model_ids)
             in
             if tier_model_ids = [] then None else Some tier_model_ids)
    in
    if normalized = [] then
      Error
        "priority_tier tiers did not match any configured candidate model ids"
    else
      Ok normalized

let resolve_strategy ?config_path ~name () =
  match config_path with
  | None -> Cascade_strategy.failover
  | Some path ->
    let default_kind = default_strategy_kind ~config_path:path ~name () in
    let cfg = Cascade_config_loader.resolve_strategy_config
                ~config_path:path ~name in
    let parsed_kind =
      parse_kind_or_default ~name ~default_kind cfg.kind
    in
    let cycle = cycle_policy_from_loader cfg in
    let kind, tiers =
      match parsed_kind with
      | Cascade_strategy.Priority_tier ->
          let result =
            match cfg.tiers with
            | Some raw_tiers ->
                normalize_priority_tiers ~config_path:path ~name raw_tiers
            | None ->
                Error
                  "priority_tier requires a non-empty <name>_tiers configuration"
          in
          (match result with
           | Ok tiers -> (parsed_kind, tiers)
           | Error msg ->
               warn_invalid_priority_tier
                 ~name ~msg ~fallback_kind:default_kind;
               (default_kind, []))
      | _ -> (parsed_kind, [])
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
