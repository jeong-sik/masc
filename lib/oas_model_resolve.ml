(** OAS model label resolution — resolve model labels to max_context and
    API key availability via OAS Cascade_config and Provider_registry.

    Context resolution delegates to OAS {!Llm_provider.Cascade_config.resolve_label_context}
    which uses the same routing logic as cascade execution.
    API key availability is checked via {!Llm_provider.Provider_registry}.
    MASC does NOT guess routing — OAS owns resolution end-to-end.

    @since 2.135.0 — inference-to-oas migration (Phase 1) *)

let default_registry = Llm_provider.Provider_registry.default ()

(** Extract provider name from a "provider:model_id" label string.
    Returns None if the label has no colon or is malformed. *)
let provider_name_of_label (label : string) : string option =
  match String.index_opt label ':' with
  | None -> None
  | Some idx ->
    if idx = 0 then None
    else Some (String.sub label 0 idx |> String.trim |> String.lowercase_ascii)

let labels_require_local_discovery (labels : string list) : bool =
  List.exists
    (fun label ->
      match provider_name_of_label label with
      | Some pname -> Provider_adapter.requires_discovery pname
      | None -> false)
    labels

let refresh_local_discovery_if_possible ?sw ?net (labels : string list) : bool =
  if not (labels_require_local_discovery labels) then false
  else
    let sw =
      match sw with Some value -> Some value | None -> Eio_context.get_switch_opt ()
    in
    let net =
      match net with Some value -> Some value | None -> Eio_context.get_net_opt ()
    in
    match sw, net with
    | Some sw, Some net ->
        let before = Llm_provider.Provider_registry.discovered_max_context () in
        (try
           ignore
             (Llm_provider.Provider_registry.refresh_llama_endpoints ~sw ~net ());
           let after = Llm_provider.Provider_registry.discovered_max_context () in
           (match before, after with
            | Some prev, Some next when prev <> next ->
                Log.info ~ctx:"OasModelResolve"
                  "refreshed local runtime context: %d -> %d" prev next
            | None, Some next ->
                Log.info ~ctx:"OasModelResolve"
                  "refreshed local runtime context: unset -> %d" next
            | _ -> ());
           true
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
             Log.warn ~ctx:"OasModelResolve"
               "local runtime discovery refresh failed: %s"
               (Printexc.to_string exn);
             false)
    | _ -> false

(** Minimum acceptable discovered per-slot context.  Below this floor
    the discovered value is assumed to be a misconfigured endpoint
    (e.g. llama-server with default [-c 8192] and 1 slot).  Legitimate
    multi-slot setups (131K / 4 = 32K per slot) pass this threshold. *)
let context_floor = 4_096

(** Apply {!context_floor}: return [discovered] when it is at least
    [context_floor]; otherwise fall back to [static_ctx]. *)
let effective_discovered_ctx ~static_ctx ~(discovered : int option) : int =
  match discovered with
  | Some ctx when ctx >= context_floor -> ctx
  | _ -> static_ctx

(** Resolve max_context for a model label.
    Delegates routing to OAS {!Llm_provider.Cascade_config.resolve_label_context} —
    MASC does not guess which endpoint serves the request.  Discovered
    values below {!context_floor} fall back to the static registry.

    Resolution chain:
    1. OAS {!Llm_provider.Cascade_config.resolve_label_context} (model-aware
       endpoint lookup for local providers, round-robin fallback).
    2. Apply {!context_floor} guard on the discovered value.
    3. If OAS returns [None], use static registry entry's [max_context].
    4. Final fallback: [128_000]. *)
let max_context_of_label (label : string) : int =
  let static_ctx =
    match provider_name_of_label label with
    | None -> 128_000
    | Some pname ->
      match Llm_provider.Provider_registry.find default_registry pname with
      | Some entry -> entry.max_context
      | None -> 128_000
  in
  match Llm_provider.Cascade_config.resolve_label_context label with
  | Some ctx -> effective_discovered_ctx ~static_ctx ~discovered:(Some ctx)
  | None -> static_ctx

(** Resolve context for a label if its provider is available; returns [None]
    if the provider is unknown, unavailable, or the label is malformed.
    Applies {!context_floor} to discovered values. *)
let context_if_available (label : string) : int option =
  match provider_name_of_label label with
  | None -> None
  | Some pname ->
    match Llm_provider.Provider_registry.find default_registry pname with
    | None -> None
    | Some entry ->
      if entry.is_available () then
        let static_ctx = entry.max_context in
        let ctx =
          match Llm_provider.Cascade_config.resolve_label_context label with
          | Some discovered -> effective_discovered_ctx ~static_ctx ~discovered:(Some discovered)
          | None -> static_ctx
        in
        Some ctx
      else None

(** Resolve max_context for the first available model in a label list.
    "Available" means the provider's API key env var is set (or not required).
    Per-label context resolved by OAS — no routing guess in MASC.
    Applies {!context_floor} to discovered values.
    Falls back to 128_000 if no model is available. *)
let resolve_primary_max_context (labels : string list) : int =
  match List.find_map context_if_available labels with
  | Some ctx -> ctx
  | None -> 128_000

(** Maximum context across all available models in a label list.
    Returns the largest context window that any model in the cascade can
    handle.  This is the value MASC should use for [max_input_tokens]:
    OAS cascade will try providers in order — if the primary overflows,
    the cascade fails over to the next provider that can handle the
    prompt size.  Falls back to [128_000] if no model is available. *)
let resolve_max_cascade_context (labels : string list) : int =
  match List.filter_map context_if_available labels with
  | [] -> 128_000
  | ctxs -> List.fold_left max 0 ctxs

let labels_are_pure_local (labels : string list) : bool =
  labels <> []
  &&
  List.for_all
    (fun label ->
       match provider_name_of_label label with
       | Some pname -> Provider_adapter.is_local_provider pname
       | None -> false)
    labels

let clamp_context_for_pure_local_labels ~(labels : string list) ~(max_context : int)
    : int =
  if labels_are_pure_local labels
  then min max_context Env_config.ContextCompact.small_local_floor
  else max_context

(** Resolve model_id for the first available model in a label list.
    Returns the model_id portion of "provider:model_id".
    Falls back to empty string if no model is available. *)
let resolve_primary_model_id (labels : string list) : string =
  let model_id_of_label label =
    match String.index_opt label ':' with
    | None -> ""
    | Some idx ->
      if idx >= String.length label - 1 then ""
      else String.sub label (idx + 1) (String.length label - idx - 1) |> String.trim
  in
  let rec find = function
    | [] -> ""
    | label :: rest ->
      match provider_name_of_label label with
      | None -> find rest
      | Some pname ->
        match Llm_provider.Provider_registry.find default_registry pname with
        | None -> find rest
        | Some entry ->
          if entry.is_available () then model_id_of_label label
          else find rest
  in
  find labels

(** Resolve the default local model label and model_id.
    Uses Provider_adapter for configured label, then validates via OAS registry.
    Returns (label, model_id) or falls back to first available provider. *)
let default_local_model_label_and_id () : string * string =
  let fallback = ("auto", "auto") in
  let try_label label =
    match provider_name_of_label label with
    | None -> None
    | Some pname ->
      match Llm_provider.Provider_registry.find default_registry pname with
      | None -> None
      | Some entry ->
        if entry.is_available () then
          let model_id = match String.index_opt label ':' with
            | None -> ""
            | Some idx ->
              String.sub label (idx + 1) (String.length label - idx - 1) |> String.trim
          in
          Some (label, model_id)
        else None
  in
  (* Try configured default first *)
  match Provider_adapter.configured_default_model_label_result () with
  | Ok label -> (
    match try_label label with
    | Some pair -> pair
    | None ->
      (* Try execution fallback chain *)
      let labels = Provider_adapter.preferred_execution_model_labels () in
      match List.find_map try_label labels with
      | Some pair -> pair
      | None -> fallback)
  | Error _ ->
    let labels = Provider_adapter.preferred_execution_model_labels () in
    match List.find_map try_label labels with
    | Some pair -> pair
    | None -> fallback

(** Check that at least one model label in the list has its API key available.
    Returns [Ok ()] if at least one is available or the list is empty.
    Returns [Error msg] listing the missing env vars if none are available. *)
let ensure_api_keys_for_labels (labels : string list) : (unit, string) result =
  if labels = [] then Ok ()
  else
    let any_available = List.exists (fun label ->
      match provider_name_of_label label with
      | None ->
          (* Label without "provider:model" format (e.g. cascade name "default").
             Treat as available — the cascade resolves providers at runtime. *)
          true
      | Some pname ->
        if Provider_adapter.is_local_provider pname then
          (* Self-hosted / local runtime; always considered available *)
          true
        else
          match Llm_provider.Provider_registry.find default_registry pname with
          | None -> false
          | Some entry -> entry.is_available ()
    ) labels in
    if any_available then Ok ()
    else
      let missing = List.filter_map (fun label ->
        match provider_name_of_label label with
        | None -> None
        | Some pname ->
          if Provider_adapter.is_local_provider pname then None
          else
            match Llm_provider.Provider_registry.find default_registry pname with
            | None -> Some (Printf.sprintf "%s (unknown provider)" pname)
            | Some entry ->
              if entry.defaults.api_key_env = "" then None
              else if entry.is_available () then None
              else Some entry.defaults.api_key_env
      ) labels in
      Error (Printf.sprintf "No valid/available model specs for labels: %s (missing: %s)"
        (String.concat ", " labels)
        (String.concat ", " missing))

(* ── Cascade model resolution ──────────────────────────── *)

let cascade_config_path () : string option =
  Config_dir_resolver.log_warnings ~context:"OasModelResolve" ();
  Config_dir_resolver.cascade_path_opt ()

(* JSON loading and profile resolution delegated to OAS Cascade_config.
   OAS maintains an Eio.Mutex-protected, mtime-based cache. *)

(** Resolve model label strings from a cascade name by reading cascade.json.
    Delegates to OAS Cascade_config for JSON loading and profile resolution.
    Falls back to "default_models" then preferred_execution_model_labels if absent. *)
let models_of_cascade_name (cascade_name : string) : string list =
  let cascade_name = Keeper_cascade_profile.canonicalize cascade_name in
  let defaults =
    match Provider_adapter.preferred_execution_model_labels () with
    | [] -> [Provider_adapter.default_local_fallback_label ()]
    | labels -> labels
  in
  let config_path = cascade_config_path () in
  (* Cascade_config uses Eio.Mutex internally.  When called outside
     Eio_main.run (e.g. unit tests) this raises Effect.Unhandled on
     the first call and Eio.Mutex.Poisoned on subsequent calls.
     Fall back to defaults in both cases. *)
  try
    Llm_provider.Cascade_config.resolve_model_strings
      ?config_path
      ~name:cascade_name
      ~defaults
      ()
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.warn ~ctx:"OasModelResolve"
      "cascade config resolve failed for %s, using defaults: %s"
      cascade_name (Printexc.to_string exn);
    defaults

(* filter_by_providers removed — provider filtering now handled by
   OAS Cascade_config.complete_named ~provider_filter parameter.
   See masc-mcp#6001. *)
