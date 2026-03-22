(** Model_spec — OAS-backed model identity and resolution.

    Types and parsing remain for MASC-specific alias resolution
    (Provider_adapter) and "default"/"default:override" forms.
    Metadata (URLs, API keys, context sizes, costs) is sourced
    from OAS Provider_registry and Pricing — single source of truth.

    @since 2.117.0 — original extraction from Cascade
    @since 2.123.0 — rewritten as OAS facade *)

(** MODEL provider discriminator. *)
type provider =
  | Llama
  | Claude
  | OpenAI
  | Gemini
  | Glm_cloud
  | OpenRouter
  | Custom of string

(** Complete specification for an MODEL endpoint. *)
type model_spec = {
  provider : provider;
  model_id : string;
  max_context : int;
  api_url : string;
  api_key_env : string option;
  cost_per_1k_input : float;
  cost_per_1k_output : float;
}

(** Human-readable provider name (display-oriented, not necessarily round-trip safe). *)
val string_of_provider : provider -> string

(** Provider name for parseable labels (round-trips with {!model_spec_of_string}). *)
val label_provider : provider -> string

(** Build a parseable ["provider:model_id"] label from a model_spec.
    The result can be passed to {!model_spec_of_string} for round-trip. *)
val label_of_model_spec : model_spec -> string

(** {2 Preset specs} *)

val llama_default : model_spec
val claude_opus : model_spec
val claude_sonnet : model_spec
val openai_default : model_spec
val glm_cloud : model_spec
val gemini_pro : model_spec

(** {2 Parsing} *)

(** Parse a ["provider:model"] string into a {!model_spec}.
    Accepts ["default"] and ["default:override"] forms.
    Returns [Error msg] on unrecognised input. *)
val model_spec_of_string : string -> (model_spec, string) result

(** {2 Cascade config} *)

(** Locate [config/cascade.json] via CWD or ME_ROOT.
    Returns [Some path] when the file exists on disk. *)
val cascade_config_path : unit -> string option

(** {2 Default model labels} *)

(** Configured default model label from env, if any. *)
val configured_default_model_label : unit -> string option

(** Preferred execution model labels (env-driven via Provider_adapter). *)
val default_execution_model_labels : unit -> string list

(** Preferred verifier model labels (env-driven via Provider_adapter). *)
val default_verifier_model_labels : unit -> string list

(** {2 Filtering and resolution} *)

(** Parse a list of model strings, filter to those with available API keys. *)
val available_model_specs_of_strings : string list -> model_spec list

(** Return the first available spec from a label list, or [Error msg]. *)
val first_available_model_spec : string list -> (model_spec, string) result

(** Default execution model spec (first available from preferred chain). *)
val default_execution_model_spec : unit -> (model_spec, string) result

(** Default verifier model spec (first available from verifier chain). *)
val default_verifier_model_spec : unit -> (model_spec, string) result

(** Best-effort local model spec: configured default > execution chain > glm_cloud. *)
val default_local_model_spec : unit -> model_spec

(** Load cascade profile from OAS config file.
    Returns model label strings (e.g. ["llama:qwen3.5"; "glm:glm-4.7"]). *)
val load_cascade_profile : config_path:string -> name:string -> string list

(** {2 Convenience accessors (no model_spec in caller)} *)

(** Resolve model labels to the primary model's [max_context].
    Returns the default local model's max_context when no label resolves. *)
val resolve_primary_max_context : string list -> int

(** Resolve model labels to the primary model's [model_id].
    Returns the default local model's model_id when no label resolves. *)
val resolve_primary_model_id : string list -> string

(** Find the model_id that matches [model_used] from a label list.
    Strips [:latest] suffix before comparison.
    Returns the default local model's model_id when no match is found. *)
val find_model_id_for_used : labels:string list -> model_used:string -> string

(** Estimate cost in USD from token usage and a model_id string.
    Delegates to OAS [Llm_provider.Pricing]. *)
val cost_usd_of_model_id : model_id:string -> input_tokens:int -> output_tokens:int -> float

(** {2 OAS Migration Bridge (Phase 1)}

    Bidirectional conversions between MASC [model_spec] and OAS types.
    New callers should use OAS types directly
    ({!Llm_provider.Provider_config.t}, {!Llm_provider.Cascade_config}).
    Existing callers can migrate incrementally using these adapters. *)

(** Map MASC provider to OAS provider_kind.
    Glm_cloud maps to Glm. Llama, OpenAI, OpenRouter, Custom
    all map to OpenAI_compat. *)
val provider_kind_of_masc : provider -> Llm_provider.Provider_config.provider_kind

(** Map MASC provider to OAS registry name (e.g. Llama -> "llama"). *)
val registry_name_of_provider : provider -> string

(** Convert model_spec to OAS Provider_config.t.
    Forward migration path: callers holding a model_spec can obtain
    the OAS wire-level config. Fields not present in model_spec
    (temperature, top_p, etc.) use Provider_config.make defaults. *)
val to_provider_config : model_spec -> Llm_provider.Provider_config.t

(** Convert OAS Provider_config.t back to model_spec.
    Backward-compat path. [registry_name] disambiguates
    OpenAI_compat sub-families; omit to use kind-based default. *)
val of_provider_config :
  ?registry_name:string ->
  Llm_provider.Provider_config.t ->
  model_spec

(** Extract pricing for a model_spec as OAS Pricing.pricing.
    Prefer this over accessing cost_per_1k_* fields directly. *)
val pricing_of_spec : model_spec -> Llm_provider.Pricing.pricing

(** Extract max_context from a model_spec.
    Migration target: Provider_registry.entry.max_context
    or Capabilities.capabilities.max_context_tokens. *)
val max_context : model_spec -> int
