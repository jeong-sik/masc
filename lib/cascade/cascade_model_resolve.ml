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
type model_resolution_provenance =
  | Explicit_input
  | Alias of string
  | Env_default of string
  | Hardcoded_default
  | Discovery
  | Unresolved_auto

type model_resolution = {
  requested_model_id : string;
  resolved_model_id : string;
  provenance : model_resolution_provenance;
}

type provider_default_spec = {
  env_var : string;
  hardcoded_default : string option;
}

let env_value_opt ?(getenv = Sys.getenv_opt) var =
  match getenv var with
  | Some v ->
      let trimmed = String.trim v in
      if String.equal trimmed "" then None else Some trimmed
  | None -> None

let provider_default_spec = function
  | "glm" ->
      Some { env_var = "ZAI_DEFAULT_MODEL"; hardcoded_default = Some "glm-5.1" }
  | "glm-coding" ->
      Some
        {
          env_var = "ZAI_CODING_DEFAULT_MODEL";
          hardcoded_default = Some "glm-5.1";
        }
  | "llama" | "ollama" ->
      Some { env_var = "OLLAMA_DEFAULT_MODEL"; hardcoded_default = None }
  | "gemini" | "gemini_cli" ->
      Some
        {
          env_var = "GEMINI_DEFAULT_MODEL";
          hardcoded_default = Some "gemini-3-flash-preview";
        }
  | "claude" ->
      Some
        {
          env_var = "ANTHROPIC_DEFAULT_MODEL";
          hardcoded_default = Some "claude-sonnet-4-6-20250514";
        }
  | "openai" ->
      Some { env_var = "OPENAI_DEFAULT_MODEL"; hardcoded_default = Some "gpt-4.1" }
  | "openrouter" ->
      Some { env_var = "OPENROUTER_DEFAULT_MODEL"; hardcoded_default = None }
  | "kimi" ->
      Some
        {
          env_var = "MOONSHOT_DEFAULT_MODEL";
          hardcoded_default = Some "kimi-k2.5";
        }
  | _ -> None

let explicit_resolution requested_model_id resolved_model_id =
  { requested_model_id; resolved_model_id; provenance = Explicit_input }

let default_resolution ?getenv provider_name ~requested_model_id =
  match provider_default_spec provider_name with
  | Some { env_var; hardcoded_default } -> (
      match env_value_opt ?getenv env_var with
      | Some resolved_model_id ->
          { requested_model_id; resolved_model_id; provenance = Env_default env_var }
      | None -> (
          match hardcoded_default with
          | Some resolved_model_id ->
              { requested_model_id; resolved_model_id; provenance = Hardcoded_default }
          | None ->
              {
                requested_model_id;
                resolved_model_id = requested_model_id;
                provenance = Unresolved_auto;
              }))
  | None ->
      {
        requested_model_id;
        resolved_model_id = requested_model_id;
        provenance = Unresolved_auto;
      }

let csv_items raw =
  raw
  |> String.split_on_char ','
  |> List.filter_map (fun item ->
         let item = String.trim item in
         if item = "" then None else Some item)

let env_csv_or default var =
  match env_value_opt var with
  | Some raw -> (
      match csv_items raw with
      | [] -> default
      | items -> items)
  | None -> default

(** Default GLM auto-cascade order: quality-first, then speed.
    glm-5.1 = best quality (reasoning), glm-5-turbo = fast tool calling,
    glm-4.7 = stable general, glm-4.7-flashx = fastest/cheapest.
    Configurable via ZAI_AUTO_MODELS env var (comma-separated). *)
let glm_auto_models = Llm_provider.Zai_catalog.glm_auto_models
let glm_coding_auto_models = Llm_provider.Zai_catalog.glm_coding_auto_models

let gemini_cli_default_auto_models = [
  "gemini-3-flash-preview";
  "gemini-3.1-flash-lite-preview";
  "gemini-2.5-flash";
  "gemini-2.5-flash-lite";
  "gemini-3.1-pro-preview";
  "gemini-2.5-pro";
]

let gemini_cli_auto_models () =
  match env_value_opt "MASC_GEMINI_CLI_AUTO_MODELS" with
  | Some raw -> (
      match csv_items raw with
      | [] -> gemini_cli_default_auto_models
      | items -> items)
  | None -> (
      match env_value_opt "GEMINI_DEFAULT_MODEL" with
      | Some model -> [ model ]
      | None -> gemini_cli_default_auto_models)

(* Mirrors the Codex CLI models observed locally on 2026-04-20, reordered
   light-to-heavy by generation (5.1 -> 5.4). Keep this operator-tunable
   because hosted model menus drift.

   2026-04-21: probe the ChatGPT-backed Codex CLI (v0.122.0) before setting
   defaults. gpt-5.1-codex-mini, gpt-5.1-codex-max, and gpt-5.2-codex all
   returned runtime 400 unsupported-model errors, while gpt-5.2,
   gpt-5.3-codex-spark, gpt-5.3-codex, gpt-5.4-mini, and gpt-5.4 executed
   successfully. Keep the default rotation to the supported set; operators can
   still opt into a different list explicitly through
   MASC_CODEX_CLI_AUTO_MODELS when their environment supports it. *)
let codex_cli_default_auto_models = [
  "gpt-5.2";
  "gpt-5.3-codex-spark";
  "gpt-5.3-codex";
  "gpt-5.4-mini";
  "gpt-5.4";
]

let codex_cli_auto_models () =
  env_csv_or codex_cli_default_auto_models "MASC_CODEX_CLI_AUTO_MODELS"

let claude_code_auto_models () =
  env_csv_or [ "auto" ] "MASC_CLAUDE_CODE_AUTO_MODELS"

let resolve_glm_model ?getenv model_id =
  let default_model = default_resolution ?getenv "glm" ~requested_model_id:model_id in
  let resolved_model_id =
    Llm_provider.Zai_catalog.resolve_glm_alias
      ~default_model:default_model.resolved_model_id
      model_id
  in
  if String.equal model_id "auto" then
    { default_model with resolved_model_id }
  else if String.equal resolved_model_id model_id then
    explicit_resolution model_id resolved_model_id
  else
    { requested_model_id = model_id; resolved_model_id; provenance = Alias model_id }

let resolve_glm_coding_model ?getenv model_id =
  let default_model =
    default_resolution ?getenv "glm-coding" ~requested_model_id:model_id
  in
  let resolved_model_id =
    Llm_provider.Zai_catalog.resolve_glm_coding_alias
      ~default_model:default_model.resolved_model_id
      model_id
  in
  if String.equal model_id "auto" then
    { default_model with resolved_model_id }
  else if String.equal resolved_model_id model_id then
    explicit_resolution model_id resolved_model_id
  else
    { requested_model_id = model_id; resolved_model_id; provenance = Alias model_id }

let resolve_kimi_model ?getenv model_id =
  let trimmed = String.trim model_id in
  match String.lowercase_ascii trimmed with
  | "auto" ->
      default_resolution ?getenv "kimi" ~requested_model_id:model_id
  | "kimi-for-coding" ->
      let default_model = default_resolution ?getenv "kimi" ~requested_model_id:model_id in
      {
        requested_model_id = model_id;
        resolved_model_id = default_model.resolved_model_id;
        provenance = Alias model_id;
      }
  | _ -> explicit_resolution model_id trimmed

let resolve_glm_model_id model_id =
  (resolve_glm_model model_id).resolved_model_id

let resolve_glm_coding_model_id model_id =
  (resolve_glm_coding_model model_id).resolved_model_id

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
    provider_name model_id =
  match provider_name with
  | "llama" | "ollama" ->
      if String.equal model_id "auto" then
        match discover () with
        | Some resolved_model_id ->
            { requested_model_id = model_id; resolved_model_id; provenance = Discovery }
        | None -> default_resolution ?getenv provider_name ~requested_model_id:model_id
      else explicit_resolution model_id model_id
  | "glm" -> resolve_glm_model ?getenv model_id
  | "glm-coding" -> resolve_glm_coding_model ?getenv model_id
  | "kimi" -> resolve_kimi_model ?getenv model_id
  | "gemini" | "gemini_cli" ->
      (* Default bumped from gemini-2.5-flash to gemini-3-flash-preview on
         2026-04-16 (PR C Cadd follow-up). Capabilities are inherited via
         the `starts_with "gemini-3"` prefix matcher in
         oas/lib/llm_provider/capabilities.ml:269 (1M context, tools,
         parallel tool calls). Override with GEMINI_DEFAULT_MODEL if you
         still need the 2.5 line.

         2026-04-20: `gemini_cli` joined the same branch. Without this,
         `gemini_cli:auto` fell through to the wildcard tail and was
         forwarded as the literal string "auto" into OAS.
         `oas/lib/llm_provider/transport_gemini_cli.build_args` then
         omits `--model`, so the gemini CLI chose its internal default —
         `gemini-3.1-pro-preview` — whose quota is small enough that every
         fleet call 429'd with `MODEL_CAPACITY_EXHAUSTED`. Mapping to
         `gemini-3-flash-preview` (higher quota, 1M context, tool calls)
         restores throughput. *)
      if String.equal model_id "auto" then
        default_resolution ?getenv provider_name ~requested_model_id:model_id
      else explicit_resolution model_id model_id
  | "claude" ->
      if String.equal model_id "auto" then
        default_resolution ?getenv provider_name ~requested_model_id:model_id
      else explicit_resolution model_id model_id
  | "openai" ->
      if String.equal model_id "auto" then
        default_resolution ?getenv provider_name ~requested_model_id:model_id
      else explicit_resolution model_id model_id
  | "openrouter" ->
      if String.equal model_id "auto" then
        default_resolution ?getenv provider_name ~requested_model_id:model_id
      else explicit_resolution model_id model_id
  | _ ->
      if String.equal model_id "auto" then
        {
          requested_model_id = model_id;
          resolved_model_id = model_id;
          provenance = Unresolved_auto;
        }
      else explicit_resolution model_id model_id

let resolve_auto_model_id provider_name model_id =
  (resolve_auto_model provider_name model_id).resolved_model_id

let parse_custom_model model_id =
  match String.index_opt model_id '@' with
  | Some at_idx ->
      let model = String.sub model_id 0 at_idx in
      let url =
        String.sub model_id (at_idx + 1) (String.length model_id - at_idx - 1)
      in
      (model, url)
  | None ->
      let url =
        match env_value_opt "CUSTOM_LLM_BASE_URL" with
        | Some u -> u
        | None -> Llm_provider.Discovery.default_endpoint
      in
      (model_id, url)
