(** Model ID resolution through AGENT_CORE runtime provider bindings.

    Pure functions that map [auto] to runtime binding defaults or local
    discovery. Provider-specific alias/catalog truth belongs upstream in AGENT_CORE.

    @since 0.92.0 extracted from Runtime_config

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

(** Resolve ["auto"] for any provider. Local providers resolve ["auto"] via
    {!Llm_provider.Discovery.first_discovered_model_id}; non-local providers
    use AGENT_CORE runtime binding defaults. *)
val resolve_auto_model
  :  ?getenv:(string -> string option)
  -> ?discover:(unit -> string option)
  -> string
  -> model_selector
  -> model_resolution

type custom_model_error =
  | Missing_endpoint
  | Empty_model
  | Invalid_endpoint

val custom_model_error_to_string : custom_model_error -> string

(** Parse an explicit [model@url] custom HTTP model selection.
    Both model and an absolute HTTP(S) endpoint are required. No process
    environment or discovery state supplies an omitted endpoint. An explicit
    numeric port must survive parsing and lie within the TCP port range 1–65535.
    The model
    and URL are trimmed at the boundary; URL path/query bytes are preserved. *)
val parse_custom_model : string -> (string * string, custom_model_error) result
