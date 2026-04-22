(** Model ID resolution: aliases and auto-detection for cloud providers.

    Pure functions that map user-facing aliases to concrete API model IDs.

    @since 0.92.0 extracted from Cascade_config

    @stability Internal
    @since 0.93.1 *)

(** GLM auto-cascade model list: quality-first, then speed.
    Returns the ordered list of models to try when [glm:auto] is specified.
    Configurable via [ZAI_AUTO_MODELS] env var (comma-separated).
    Default: [\["glm-5.1"; "glm-5-turbo"; "glm-4.7"; "glm-4.7-flashx"\]]. *)
val glm_auto_models : unit -> string list
val glm_coding_auto_models : unit -> string list

(** Ordered Gemini CLI candidates for [gemini_cli:auto].
    Configurable via [MASC_GEMINI_CLI_AUTO_MODELS] (comma-separated).
    When unset, [GEMINI_DEFAULT_MODEL] narrows the list to that single
    model for backward-compatible explicit override semantics. *)
val gemini_cli_auto_models : unit -> string list

(** Ordered Codex CLI candidates for [codex_cli:auto].
    Configurable via [MASC_CODEX_CLI_AUTO_MODELS] (comma-separated).
    Defaults to a light-to-heavy generation order (5.1 -> 5.4),
    including mini/spark variants. *)
val codex_cli_auto_models : unit -> string list

(** Ordered Claude Code candidates for [claude_code:auto].
    Configurable via [MASC_CLAUDE_CODE_AUTO_MODELS] (comma-separated).
    Defaults to [["auto"]] so the user's Claude Code default remains in
    control unless an operator opts into model rotation. *)
val claude_code_auto_models : unit -> string list

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

val resolve_glm_model :
  ?getenv:(string -> string option) -> string -> model_resolution
val resolve_glm_coding_model :
  ?getenv:(string -> string option) -> string -> model_resolution

(** Resolve a GLM model alias to the concrete API model ID.
    - ["auto"] -> env var [ZAI_DEFAULT_MODEL] or ["glm-5.1"]
    - ["flash"] -> ["glm-4.7-flashx"]
    - ["turbo"] -> ["glm-5-turbo"]
    - ["vision"] -> ["glm-4.6v"]
    - Concrete IDs pass through unchanged. *)
val resolve_glm_model_id : string -> string
val resolve_glm_coding_model_id : string -> string

(** Resolve "auto" and aliases to concrete model IDs for any provider.
    Cloud providers resolve aliases; local providers (llama, ollama) resolve
    "auto" via {!Llm_provider.Discovery.first_discovered_model_id}. *)
val resolve_auto_model :
  ?getenv:(string -> string option) ->
  ?discover:(unit -> string option) ->
  string ->
  string ->
  model_resolution
val resolve_auto_model_id : string -> string -> string

(** Parse a "model@url" custom model spec.
    Returns [(model_id, base_url)].
    Without [@], uses [CUSTOM_LLM_BASE_URL] env or ["http://127.0.0.1:8080"]. *)
val parse_custom_model : string -> string * string
