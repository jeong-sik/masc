(** Model_spec — OAS-backed model identity and resolution.

    Types and parsing remain for MASC-specific alias resolution
    (Provider_adapter) and "default"/"default:override" forms.
    Metadata (URLs, API keys, context sizes, costs) is sourced
    from OAS Provider_registry and Pricing — single source of truth.

    Default/preset resolution delegates to OAS Cascade_config
    when [config/cascade.json] is present (hot-reloadable).

    @since 2.117.0 — original extraction from Cascade
    @since 2.123.0 — rewritten as OAS facade
    @since 2.129.0 — default resolution via Cascade_config *)

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

(** Human-readable provider name. *)
val string_of_provider : provider -> string

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

(** Preferred execution model labels.
    Consults OAS [Cascade_config.resolve_model_strings] with
    [config/cascade.json] when available, falling back to env-driven labels. *)
val default_execution_model_labels : unit -> string list

(** Preferred verifier model labels.
    Consults OAS [Cascade_config.resolve_model_strings] with
    [config/cascade.json] when available, falling back to env-driven labels. *)
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
