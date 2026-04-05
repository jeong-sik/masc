(** OAS model label resolution — resolve model labels to max_context and
    API key availability using OAS Provider_registry directly.

    Replaces Model_spec convenience accessors for callers that only need
    scalar values (max_context, model_id) from model label strings.
    Goes through OAS Cascade_config.parse_model_string which uses
    Provider_registry as SSOT, bypassing Model_spec.model_spec entirely.

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

(** Absolute minimum acceptable discovered context size.
    llama-server defaults to [-c 8192]; keeper conversations need 64K+ for
    multi-turn interactions with tool calls.  Below this floor we ignore the
    discovered value and use the static registry value instead. *)
let context_floor = 65_536

(** Return [discovered] when it meets or exceeds {!context_floor};
    otherwise return [static_ctx].  Pure — callers that need diagnostic
    logging should inspect the result separately. *)
let effective_discovered_ctx ~static_ctx ~(discovered : int option) : int =
  match discovered with
  | Some ctx when ctx >= context_floor -> ctx
  | _ -> static_ctx

let provider_name_of_cfg label (cfg : Llm_provider.Provider_config.t) =
  match provider_name_of_label label with
  | Some pname -> pname
  | None ->
      Llm_provider.Provider_config.(match cfg.kind with
        | Anthropic -> "claude" | OpenAI_compat -> "openai"
        | Gemini -> "gemini" | Glm -> "glm" | Claude_code -> "claude_code")

let is_loopback_url url =
  match Uri.host (Uri.of_string url) with
  | Some "localhost" | Some "127.0.0.1" -> true
  | _ -> false

let uses_local_discovery pname (cfg : Llm_provider.Provider_config.t) =
  Provider_adapter.requires_discovery pname ||
  (pname = "openai" && is_loopback_url cfg.base_url)

(** Resolve max_context for a model label.
    Prefers discovered per-slot context (from live /props probe) for local
    providers.  Discovered values below {!context_floor} are treated as
    server misconfiguration and replaced by the static registry value with
    a WARN log. *)
let max_context_of_label (label : string) : int =
  match Llm_provider.Cascade_config.parse_model_string label with
  | None -> 128_000
  | Some cfg ->
    let pname = provider_name_of_cfg label cfg in
    let static_ctx = cfg.max_tokens in
    if uses_local_discovery pname cfg then begin
      let discovered = Llm_provider.Provider_registry.discovered_max_context () in
      (match discovered with
       | Some low_ctx when low_ctx < context_floor ->
         Log.warn ~ctx:"OasModelResolve"
           "discovered context %d < floor %d for %s; using static value. \
            Increase llama-server -c flag."
           low_ctx context_floor pname
       | _ -> ());
      effective_discovered_ctx ~static_ctx ~discovered
    end
    else static_ctx

(** Resolve max_context for the first available model in a label list.
    "Available" means the provider's API key env var is set (or not required).
    Prefers discovered per-slot context for local providers; silently falls
    back to the static registry value when the discovered context is below
    {!context_floor}.  Falls back to 128_000 if no model is available. *)
let resolve_primary_max_context (labels : string list) : int =
  let discovered = Llm_provider.Provider_registry.discovered_max_context () in
  let rec find = function
    | [] -> 128_000
    | label :: rest ->
      match Llm_provider.Cascade_config.parse_model_string label with
      | None -> find rest
      | Some cfg ->
        let pname = provider_name_of_cfg label cfg in
        let local_discovery = uses_local_discovery pname cfg in
        let is_available =
          if local_discovery then true
          else
            match Llm_provider.Provider_registry.find default_registry pname with
            | Some entry -> entry.is_available ()
            | None -> false
        in
        if not is_available then find rest
        else if local_discovery then
          effective_discovered_ctx ~static_ctx:cfg.max_tokens ~discovered
        else cfg.max_tokens
  in
  find labels

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
  with exn ->
    Log.warn ~ctx:"OasModelResolve"
      "cascade config resolve failed for %s, using defaults: %s"
      cascade_name (Printexc.to_string exn);
    defaults
