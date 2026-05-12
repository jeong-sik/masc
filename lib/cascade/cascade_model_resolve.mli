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

(** {2 Removed in RFC-0058 Phase 5.3a}

    The per-provider [gemini_cli_auto_models], [codex_cli_auto_models],
    [claude_code_auto_models], and [kimi_cli_auto_models] thin wrappers
    have been deleted. They were unused in production — every routing
    call went through {!Provider_adapter.auto_models_for_cascade_prefix}
    directly. Hardcoded provider names were a §2.4 "code knows provider
    names" violation. Callers that need a specific provider's auto list
    use the generic API; per-provider env-override behaviour
    ([MASC_<PROVIDER>_AUTO_MODELS]) remains intact and is now exercised
    against the generic path in [test/test_cascade_model_resolve.ml]. *)

type model_selector =
  | Concrete of string
  | Auto

val model_selector_of_string : string -> model_selector

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

val resolve_glm_model
  :  ?getenv:(string -> string option)
  -> model_selector
  -> model_resolution

val resolve_glm_coding_model
  :  ?getenv:(string -> string option)
  -> model_selector
  -> model_resolution

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
val resolve_auto_model
  :  ?getenv:(string -> string option)
  -> ?discover:(unit -> string option)
  -> string
  -> model_selector
  -> model_resolution

val resolve_auto_model_id : string -> string -> string

(** Parse a "model@url" custom model spec.
    Returns [(model_id, base_url)].
    Without [@], uses [CUSTOM_LLM_BASE_URL] env or ["http://127.0.0.1:8080"]. *)
val parse_custom_model : string -> string * string
