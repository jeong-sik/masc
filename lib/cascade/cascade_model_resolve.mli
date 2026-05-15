(** Model ID resolution through OAS runtime provider bindings.

    Pure functions that map [auto] to runtime binding defaults or local
    discovery. Provider-specific alias/catalog truth belongs upstream in OAS.

    @since 0.92.0 extracted from Cascade_config

    @stability Internal
    @since 0.93.1 *)

type model_selector =
  | Concrete of string
  | Auto

val model_selector_of_string : string -> model_selector

type model_resolution_provenance =
  | Explicit_input
  | Env_default of string
  | Binding_default
  | Discovery
  | Unresolved_auto

type model_resolution =
  { requested_model_id : string
  ; resolved_model_id : string
  ; provenance : model_resolution_provenance
  }

(** Resolve provider:auto expansion for any registered cascade provider. *)
val auto_models_for_cascade_prefix
  :  ?getenv:(string -> string option)
  -> string
  -> string list option

(** Resolve ["auto"] for any provider. Local providers resolve ["auto"] via
    {!Llm_provider.Discovery.first_discovered_model_id}; non-local providers
    use OAS runtime binding defaults. *)
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
