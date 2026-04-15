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

(** Resolve a GLM model alias to the concrete API model ID.
    - ["auto"] -> env var [ZAI_DEFAULT_MODEL] or ["glm-5"]
    - ["flash"] -> ["glm-4.7-flashx"]
    - ["turbo"] -> ["glm-5-turbo"]
    - ["vision"] -> ["glm-4.6v"]
    - Concrete IDs pass through unchanged. *)
val resolve_glm_model_id : string -> string
val resolve_glm_coding_model_id : string -> string

(** Resolve "auto" and aliases to concrete model IDs for any provider.
    Cloud providers resolve aliases; local providers (llama, ollama) resolve
    "auto" via {!Llm_provider.Discovery.first_discovered_model_id}. *)
val resolve_auto_model_id : string -> string -> string

(** Parse a "model@url" custom model spec.
    Returns [(model_id, base_url)].
    Without [@], uses [CUSTOM_LLM_BASE_URL] env or ["http://127.0.0.1:8080"]. *)
val parse_custom_model : string -> string * string
