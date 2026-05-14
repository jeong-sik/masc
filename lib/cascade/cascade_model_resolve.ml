(** Model ID resolution: aliases and auto-detection for cloud providers.

    Pure functions that map user-facing aliases to concrete API model IDs.
    No side effects beyond reading environment variables.

    @since 0.92.0 extracted from Cascade_config *)

(* ── GLM model catalog ──────────────────────────────── *)

(** Resolve GLM alias to concrete model ID.
    ZhipuAI serves all models on one endpoint; the "model" field
    must be an exact ID from their catalog.

    Catalog (2026-03, updated):
    {b Text}: glm-5.1, glm-5, glm-5-turbo, glm-4.7, glm-4.7-flashx,
              glm-4.6, glm-4.5, glm-4.5-air, glm-4.5-airx,
              glm-4.5-flash, glm-4.5-x, glm-4-32b-0414-128k
    {b Vision}: glm-4.6v, glm-4.6v-flashx, glm-4.6v-flash, glm-4.5v
    {b Audio}: glm-asr-2512
    {b Image gen}: cogview-4, glm-image

    All text/vision models support function calling.
    glm-5.1 supports reasoning (reasoning_content field). *)
type model_selector =
  | Concrete of string
  | Auto

let model_selector_of_string s =
  if String.equal (String.lowercase_ascii (String.trim s)) "auto"
  then Auto
  else Concrete s
;;

type model_resolution_provenance =
  | Explicit_input
  | Alias of string
  | Env_default of string
  | Catalog_default
  | Discovery
  | Unresolved_auto

type model_resolution =
  { requested_model_id : string
  ; resolved_model_id : string
  ; provenance : model_resolution_provenance
  }

module Runtime_binding = Agent_sdk.Provider_runtime_binding
module PConfig = Llm_provider.Provider_config

type model_family =
  | Generic
  | Glm_general
  | Glm_coding

let env_value_opt ?(getenv = Sys.getenv_opt) var =
  match getenv var with
  | Some v ->
    let trimmed = String.trim v in
    if String.equal trimmed "" then None else Some trimmed
  | None -> None
;;

let explicit_resolution requested_model_id resolved_model_id =
  { requested_model_id; resolved_model_id; provenance = Explicit_input }
;;

let unresolved_auto requested_model_id =
  { requested_model_id
  ; resolved_model_id = requested_model_id
  ; provenance = Unresolved_auto
  }
;;

let normalize_runtime_provider_label value =
  String.trim value
  |> String.lowercase_ascii
  |> String.map (fun c -> if c = '_' then '-' else c)

let runtime_binding_for_provider_label provider_name =
  match Runtime_binding.find provider_name with
  | Some _ as binding -> binding
  | None -> Runtime_binding.find (normalize_runtime_provider_label provider_name)

let binding_env_fragment (binding : Runtime_binding.t) =
  binding.Runtime_binding.id
  |> String.map (function
       | 'a' .. 'z' as c -> Char.uppercase_ascii c
       | 'A' .. 'Z' | '0' .. '9' as c -> c
       | _ -> '_')

let binding_endpoint_url (binding : Runtime_binding.t) =
  let trimmed = String.trim binding.Runtime_binding.base_url in
  if String.equal trimmed "" then None else Some trimmed

let binding_base_url_is_loopback binding =
  match binding_endpoint_url binding with
  | None -> false
  | Some base_url ->
    Uri.of_string base_url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt

let binding_auth_is_no_auth (binding : Runtime_binding.t) =
  match binding.Runtime_binding.auth with
  | Runtime_binding.No_auth -> true
  | Runtime_binding.Api_key_env _
  | Runtime_binding.Cli_cached_login
  | Runtime_binding.Oauth_cached_login
  | Runtime_binding.Setup_token_env _
  | Runtime_binding.File _
  | Runtime_binding.Exec _ -> false

let binding_is_local (binding : Runtime_binding.t) =
  match binding.Runtime_binding.kind with
  | PConfig.Ollama -> binding_auth_is_no_auth binding && binding_base_url_is_loopback binding
  | PConfig.OpenAI_compat ->
    binding_auth_is_no_auth binding
    && (binding_base_url_is_loopback binding
        || String.equal binding.Runtime_binding.id "llama")
  | PConfig.Anthropic
  | PConfig.Kimi
  | PConfig.Glm
  | PConfig.DashScope
  | PConfig.Gemini
  | PConfig.Claude_code
  | PConfig.Codex_cli
  | PConfig.Gemini_cli
  | PConfig.Kimi_cli -> false

let binding_default_model_id (binding : Runtime_binding.t) =
  match binding.Runtime_binding.default_model with
  | Some raw when String.trim raw <> "" -> Some (String.trim raw)
  | Some _ | None ->
    (match binding.Runtime_binding.capabilities.supported_models with
     | Some (model :: _) when String.trim model <> "" -> Some (String.trim model)
     | Some _ | None -> None)

let model_family_of_binding (binding : Runtime_binding.t) =
  match binding.Runtime_binding.kind, binding.Runtime_binding.id with
  | PConfig.Glm, "glm-coding" -> Glm_coding
  | PConfig.Glm, _ -> Glm_general
  | _ -> Generic

let default_resolution_from_binding ?getenv binding ~requested_model_id =
  let env_var = "MASC_" ^ binding_env_fragment binding ^ "_DEFAULT_MODEL" in
  match env_value_opt ?getenv env_var with
  | Some resolved_model_id ->
    { requested_model_id; resolved_model_id; provenance = Env_default env_var }
  | None ->
    (match binding_default_model_id binding with
     | Some resolved_model_id ->
       { requested_model_id; resolved_model_id; provenance = Catalog_default }
     | None -> unresolved_auto requested_model_id)

let default_resolution ?getenv provider_name ~requested_model_id =
  match runtime_binding_for_provider_label provider_name with
  | Some binding ->
    default_resolution_from_binding ?getenv binding ~requested_model_id
  | None -> unresolved_auto requested_model_id

let cascade_prefix_of_provider_label label =
  match runtime_binding_for_provider_label label with
  | Some binding -> binding.Runtime_binding.id
  | None -> label
;;

(** Default GLM auto-cascade order: quality-first, then speed.
    glm-5.1 = best quality (reasoning), glm-5-turbo = fast tool calling,
    glm-4.7 = stable general, glm-4.7-flashx = fastest/cheapest.
    Configurable via ZAI_AUTO_MODELS env var (comma-separated). *)
let glm_auto_models = Llm_provider.Zai_catalog.glm_auto_models

let glm_coding_auto_models = Llm_provider.Zai_catalog.glm_coding_auto_models

let first_nonempty_model models =
  List.find_map
    (fun model ->
       let trimmed = String.trim model in
       if String.equal trimmed "" then None else Some trimmed)
    models

let with_catalog_default requested_model_id models resolution =
  match resolution.provenance, String.lowercase_ascii resolution.resolved_model_id with
  | Unresolved_auto, "auto" ->
    (match first_nonempty_model models with
     | Some resolved_model_id ->
       { requested_model_id; resolved_model_id; provenance = Catalog_default }
     | None -> resolution)
  | _ -> resolution

let resolve_glm_model ?getenv selector =
  let model_id =
    match selector with
    | Concrete s -> s
    | Auto -> "auto"
  in
  let default_model =
    default_resolution
      ?getenv
      (cascade_prefix_of_provider_label "glm")
      ~requested_model_id:model_id
    |> with_catalog_default model_id (glm_auto_models ())
  in
  let resolved_model_id =
    Llm_provider.Zai_catalog.resolve_glm_alias
      ~default_model:default_model.resolved_model_id
      model_id
  in
  match selector with
  | Auto -> { default_model with resolved_model_id }
  | Concrete _ ->
    if String.equal resolved_model_id model_id
    then explicit_resolution model_id resolved_model_id
    else { requested_model_id = model_id; resolved_model_id; provenance = Alias model_id }
;;

let resolve_glm_coding_model ?getenv selector =
  let model_id =
    match selector with
    | Concrete s -> s
    | Auto -> "auto"
  in
  let default_model =
    default_resolution
      ?getenv
      (cascade_prefix_of_provider_label "glm-coding")
      ~requested_model_id:model_id
    |> with_catalog_default model_id (glm_coding_auto_models ())
  in
  let resolved_model_id =
    Llm_provider.Zai_catalog.resolve_glm_coding_alias
      ~default_model:default_model.resolved_model_id
      model_id
  in
  match selector with
  | Auto -> { default_model with resolved_model_id }
  | Concrete _ ->
    if String.equal resolved_model_id model_id
    then explicit_resolution model_id resolved_model_id
    else { requested_model_id = model_id; resolved_model_id; provenance = Alias model_id }
;;

let resolve_glm_model_id model_id =
  (resolve_glm_model (model_selector_of_string model_id)).resolved_model_id
;;

let resolve_glm_coding_model_id model_id =
  (resolve_glm_coding_model (model_selector_of_string model_id)).resolved_model_id
;;

(** Resolve "auto" and aliases to concrete model IDs.
    Cloud APIs generally require concrete model names, and local
    providers (llama, ollama) also cannot accept the literal "auto" model ID.

    For local providers, "auto" is resolved via {!Llm_provider.Discovery.first_discovered_model_id}
    which returns models from the last endpoint probe. Callers should
    resolve the model_id before invoking [Llm_provider.Discovery.endpoint_for_model]
    to avoid routing mismatches. *)
let resolve_auto_model
      ?getenv
      ?(discover = Llm_provider.Discovery.first_discovered_model_id)
      provider_name
      selector
  =
  let model_id =
    match selector with
    | Concrete s -> s
    | Auto -> "auto"
  in
  match runtime_binding_for_provider_label provider_name with
  | Some binding when binding_is_local binding ->
    (match selector with
     | Auto ->
       (match discover () with
        | Some resolved_model_id ->
          { requested_model_id = model_id; resolved_model_id; provenance = Discovery }
        | None -> default_resolution ?getenv provider_name ~requested_model_id:model_id)
     | Concrete _ -> explicit_resolution model_id model_id)
  | Some binding ->
    (match model_family_of_binding binding with
     | Glm_general -> resolve_glm_model ?getenv selector
     | Glm_coding -> resolve_glm_coding_model ?getenv selector
     | Generic ->
    (match selector with
     | Auto -> default_resolution ?getenv provider_name ~requested_model_id:model_id
       | Concrete _ -> explicit_resolution model_id model_id))
  | None ->
    (match selector with
     | Auto -> unresolved_auto model_id
     | Concrete _ -> explicit_resolution model_id model_id)
;;

let resolve_auto_model_id provider_name model_id =
  (resolve_auto_model provider_name (model_selector_of_string model_id)).resolved_model_id
;;

let parse_custom_model model_id =
  match String.index_opt model_id '@' with
  | Some at_idx ->
    let model = String.sub model_id 0 at_idx in
    let url = String.sub model_id (at_idx + 1) (String.length model_id - at_idx - 1) in
    model, url
  | None ->
    let url =
      match env_value_opt "CUSTOM_LLM_BASE_URL" with
      | Some u -> u
      | None -> Llm_provider.Discovery.default_endpoint
    in
    model_id, url
;;
