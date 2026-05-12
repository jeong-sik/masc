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
  | Hardcoded_default
  | Discovery
  | Unresolved_auto

type model_resolution =
  { requested_model_id : string
  ; resolved_model_id : string
  ; provenance : model_resolution_provenance
  }

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

let default_resolution_from_policy
      ?getenv
      (policy : Provider_adapter.model_policy)
      ~requested_model_id
  =
  match policy.default_model_env with
  | Some env_var ->
    (match env_value_opt ?getenv env_var with
     | Some resolved_model_id ->
       { requested_model_id; resolved_model_id; provenance = Env_default env_var }
     | None ->
       (match policy.default_model_fallback with
        | Some resolved_model_id ->
          { requested_model_id; resolved_model_id; provenance = Hardcoded_default }
        | None -> unresolved_auto requested_model_id))
  | None ->
    (match policy.default_model_fallback with
     | Some resolved_model_id ->
       { requested_model_id; resolved_model_id; provenance = Hardcoded_default }
     | None -> unresolved_auto requested_model_id)
;;

let default_resolution ?getenv provider_name ~requested_model_id =
  match Provider_adapter.resolve_adapter_by_cascade_prefix provider_name with
  | Some adapter ->
    default_resolution_from_policy ?getenv adapter.model_policy ~requested_model_id
  | None -> unresolved_auto requested_model_id
;;

(** Default GLM auto-cascade order: quality-first, then speed.
    glm-5.1 = best quality (reasoning), glm-5-turbo = fast tool calling,
    glm-4.7 = stable general, glm-4.7-flashx = fastest/cheapest.
    Configurable via ZAI_AUTO_MODELS env var (comma-separated). *)
let glm_auto_models = Llm_provider.Zai_catalog.glm_auto_models

let glm_coding_auto_models = Llm_provider.Zai_catalog.glm_coding_auto_models

let resolve_glm_model ?getenv selector =
  let model_id =
    match selector with
    | Concrete s -> s
    | Auto -> "auto"
  in
  let default_model = default_resolution ?getenv "glm" ~requested_model_id:model_id in
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
    default_resolution ?getenv "glm-coding" ~requested_model_id:model_id
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

let resolve_kimi_model ?getenv selector =
  let model_id =
    match selector with
    | Concrete s -> s
    | Auto -> "auto"
  in
  let trimmed = String.trim model_id in
  match String.lowercase_ascii trimmed with
  | "auto" -> default_resolution ?getenv "kimi" ~requested_model_id:model_id
  | "kimi-for-coding" ->
    let default_model = default_resolution ?getenv "kimi" ~requested_model_id:model_id in
    { requested_model_id = model_id
    ; resolved_model_id = default_model.resolved_model_id
    ; provenance = Alias model_id
    }
  | _ -> explicit_resolution model_id trimmed
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
  match Provider_adapter.resolve_adapter_by_cascade_prefix provider_name with
  | Some { runtime_kind = Provider_adapter.Local; _ } ->
    (match selector with
     | Auto ->
       (match discover () with
        | Some resolved_model_id ->
          { requested_model_id = model_id; resolved_model_id; provenance = Discovery }
        | None -> default_resolution ?getenv provider_name ~requested_model_id:model_id)
     | Concrete _ -> explicit_resolution model_id model_id)
  | Some { model_policy = { family = Provider_adapter.Glm_general; _ }; _ } ->
    resolve_glm_model ?getenv selector
  | Some { model_policy = { family = Provider_adapter.Glm_coding; _ }; _ } ->
    resolve_glm_coding_model ?getenv selector
  | Some { model_policy = { family = Provider_adapter.Kimi_api_family; _ }; _ } ->
    resolve_kimi_model ?getenv selector
  | Some _ ->
    (match selector with
     | Auto -> default_resolution ?getenv provider_name ~requested_model_id:model_id
     | Concrete _ -> explicit_resolution model_id model_id)
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
