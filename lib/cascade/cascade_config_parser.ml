(** Cascade model-string parsing + provider config construction.

    Extracted from [cascade_config.ml]. The facade {!Cascade_config}
    re-exports every public binding so external callers keep their
    existing API. *)

module Binding = Cascade_config_provider_binding
module Runtime_binding = Binding.Runtime_binding

let default_registry = Llm_provider.Provider_registry.default ()

(* ── String splitting helper ─────────────────────────────── *)

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
  let actual_model, base_url = Cascade_model_resolve.parse_custom_model model_id in
  if actual_model = "" then None
  else Some (Llm_provider.Provider_config.make
               ~kind:OpenAI_compat
               ~model_id:actual_model
               ~base_url
               ~request_path:
                 (Binding.normalize_openai_compat_request_path
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

(* #9953: Resolve provider/model max_context from OAS runtime binding truth.

   Resolution order:
   1. Per-model capabilities override ({!Capabilities.for_model_id}
      resolved id) — allows future per-variant overrides to take
      effect without touching this file.
   2. Provider-level capability exposed by [Provider_runtime_binding].
   3. Registry entry default (safety net for exotic configs).
*)
let resolve_provider_model_max_context ~provider_name resolved_model_id =
  let open Llm_provider in
  let from_model =
    Option.bind
      (Capabilities.for_model_id resolved_model_id)
      (fun c -> c.Capabilities.max_context_tokens)
  in
  match from_model with
  | Some n -> n
  | None ->
    (match
       Option.bind
         (Agent_sdk.Provider_runtime_binding.find provider_name)
         (fun binding ->
            binding.Agent_sdk.Provider_runtime_binding.capabilities.max_context_tokens)
     with
     | Some n -> n
     | None ->
       (match Provider_registry.find (Provider_registry.default ())
                provider_name with
        | Some entry -> entry.Provider_registry.max_context
        | None -> 0))

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
  let headers = Binding.headers_with_auth ~kind:defaults.kind ~api_key in
  (* Keep runtime model selection on the same resolution path as the
     provenance helpers in [Cascade_model_resolve]. Local providers still
     inject provider-specific discovery so routing stays isolated by
     endpoint (e.g. ollama:auto must not pick up llama-server models). *)
  let discover =
    if Binding.provider_name_matches_kind_default provider_name Ollama then
      Some
        (fun () ->
          Llm_provider.Discovery.first_discovered_model_id_for_url
            defaults.base_url)
    else if Binding.provider_name_matches_default_local_openai_runtime provider_name then
      Some Llm_provider.Discovery.first_discovered_model_id
    else None
  in
  let model_resolution =
    Cascade_model_resolve.resolve_auto_model ?discover provider_name
      (Cascade_model_resolve.model_selector_of_string model_id)
  in
  let resolved_model_id = model_resolution.resolved_model_id in
  let base_url =
    if Binding.provider_name_matches_default_local_openai_runtime provider_name then
      (* Route to the endpoint that has this model; round-robin fallback *)
      match Llm_provider.Discovery.endpoint_for_model resolved_model_id with
      | Some url -> url
      | None -> Llm_provider.Provider_registry.next_llama_endpoint ()
    else defaults.base_url
  in
  let request_path =
    match defaults.kind with
    | OpenAI_compat ->
      Binding.normalize_openai_compat_request_path
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
  | _ ->
  (* Kind classification goes through [Provider_kind_resolver] — a sum-typed
     resolver that consults Provider_registry as SSOT and never flattens
     unknown specs to [OpenAI_compat]. This keeps ["gemini:gemini-3-flash-preview"]
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

(* RFC-0058 iter 21 cleanup: the plain [parse_weighted_entry] that
   returned a silent [None] was removed.  All callers migrated to
   [parse_weighted_entry_with_drop_metric] in iter 14 — the wrapper
   that delegates to [parse_weighted_entry_diag] and ticks the iter-6
   candidate-drop counter on rejection.  The plain function was
   external-API-exported with zero external callers (audit at iter 14).
   Removed in iter 21 to prevent regression to silent-None paths in
   future code. *)

(** Categorised diagnostic for a failed weighted-entry parse. *)
type weighted_entry_drop =
  | Drop_unregistered_scheme of { model : string; scheme : string }
  | Drop_unavailable_scheme of { model : string; scheme : string }
  | Drop_invalid_syntax of string

let weighted_entry_drop_reason_label = function
  | Drop_unregistered_scheme _ -> "unregistered_scheme"
  | Drop_unavailable_scheme _ -> "unavailable_scheme"
  | Drop_invalid_syntax _ -> "invalid_syntax"

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

(** Resolve-path wrapper around {!parse_weighted_entry_diag} that
    returns an [option] AND ticks the iter-6
    [Cascade_metrics.on_profile_candidate_drop] counter on drop.
    Replaces the iter-21-removed [parse_weighted_entry] which
    silently swallowed the drop reason: the resolve path surfaced
    drops only as [providers = []] downstream with no WHY.  Use
    when a [cascade] context exists, so the drop rate is observable
    per cascade alongside the validation-time
    [profile_candidate_drop] counter. *)
let parse_weighted_entry_with_drop_metric
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?(max_tokens = Llm_provider.Constants.Inference.default_max_tokens)
    ?system_prompt ?(api_key_env_overrides = [])
    ?keep_alive ?num_ctx
    ~cascade
    (entry : Cascade_config_loader.weighted_entry)
  : Llm_provider.Provider_config.t option =
  match
    parse_weighted_entry_diag
      ~temperature ~max_tokens ?system_prompt
      ~api_key_env_overrides
      ?keep_alive ?num_ctx
      entry
  with
  | Ok cfg -> Some cfg
  | Error drop ->
    Cascade_metrics.on_profile_candidate_drop
      ~cascade
      ~reason:(weighted_entry_drop_reason_label drop);
    None

(** Expand provider:auto specs that map to multiple models.
    Direct API providers project their candidate list from OAS runtime
    bindings. CLI-backed transports can use operator-provided override
    lists instead of delegating to an interactive/default model picker.
    Other specs pass through as-is. *)
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
      match Cascade_model_resolve.auto_models_for_cascade_prefix provider_name with
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
    categorised reasons so upstream drift (e.g. a cascade.toml entry
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
        scheme(s): [%s]. Likely library/binary drift or cascade.toml typo \
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
