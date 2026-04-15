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
let env_or default var =
  match Sys.getenv_opt var with
  | Some v when String.trim v <> "" -> String.trim v
  | _ -> default

(** Default GLM auto-cascade order: quality-first, then speed.
    glm-5.1 = best quality (reasoning), glm-5-turbo = fast tool calling,
    glm-4.7 = stable general, glm-4.7-flashx = fastest/cheapest.
    Configurable via ZAI_AUTO_MODELS env var (comma-separated). *)
let glm_auto_models = Llm_provider.Zai_catalog.glm_auto_models
let glm_coding_auto_models = Llm_provider.Zai_catalog.glm_coding_auto_models

let resolve_glm_model_id model_id =
  Llm_provider.Zai_catalog.resolve_glm_alias
    ~default_model:(env_or "glm-5.1" "ZAI_DEFAULT_MODEL")
    model_id

let resolve_glm_coding_model_id model_id =
  Llm_provider.Zai_catalog.resolve_glm_coding_alias
    ~default_model:(env_or "glm-4.7" "ZAI_CODING_DEFAULT_MODEL")
    model_id

(** Resolve "auto" and aliases to concrete model IDs.
    Cloud APIs generally require concrete model names, and local
    providers (llama, ollama) also cannot accept the literal "auto" model ID.

    For local providers, "auto" is resolved via {!Llm_provider.Discovery.first_discovered_model_id}
    which returns models from the last endpoint probe.  Callers should
    resolve the model_id before invoking [Llm_provider.Discovery.endpoint_for_model]
    to avoid routing mismatches. *)
let resolve_auto_model_id provider_name model_id =
  match provider_name with
  | "llama" | "ollama" ->
    (* Local providers: "auto" resolved earlier via Discovery in
       cascade_config.ml.  If still "auto" here, try discovery then env var. *)
    if model_id = "auto" then
      match Llm_provider.Discovery.first_discovered_model_id () with
      | Some id -> id
      | None -> env_or model_id "OLLAMA_DEFAULT_MODEL"
    else model_id
  | "glm" -> resolve_glm_model_id model_id
  | "glm-coding" -> resolve_glm_coding_model_id model_id
  | "gemini" ->
    if model_id = "auto" then env_or "gemini-2.5-flash" "GEMINI_DEFAULT_MODEL"
    else model_id
  | "claude" ->
    if model_id = "auto" then env_or "claude-sonnet-4-6-20250514" "ANTHROPIC_DEFAULT_MODEL"
    else model_id
  | "openai" ->
    if model_id = "auto" then env_or "gpt-4.1" "OPENAI_DEFAULT_MODEL"
    else model_id
  | "openrouter" ->
    if model_id = "auto" then env_or model_id "OPENROUTER_DEFAULT_MODEL"
    else model_id
  | _ -> model_id

let parse_custom_model model_id =
  match String.index_opt model_id '@' with
  | Some at_idx ->
    let model = String.sub model_id 0 at_idx in
    let url = String.sub model_id (at_idx + 1) (String.length model_id - at_idx - 1) in
    (model, url)
  | None ->
    let url =
      match Sys.getenv_opt "CUSTOM_LLM_BASE_URL" with
      | Some u -> u
      | None -> Llm_provider.Discovery.default_endpoint
    in
    (model_id, url)
