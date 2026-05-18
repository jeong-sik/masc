(** Cascade model-string parsing + provider config construction.

    Extracted from [cascade_config.ml]. Owns the path from a raw
    ["provider:model"] (or [{!Cascade_config_loader.weighted_entry}])
    string to a {!Llm_provider.Provider_config.t}.

    Diagnostic types ({!weighted_entry_drop}) are defined here and aliased
    by {!Cascade_config} so the surface stays unchanged.

    @stability Internal *)

val split_provider_model : string -> (string * string) option
(** Split a ["provider:model_id"] string at the first colon. Returns
    [None] when the colon is missing or at an edge position. *)

val make_custom_config :
  temperature:float ->
  max_tokens:int ->
  ?system_prompt:string ->
  ?supports_tool_choice_override:bool ->
  ?keep_alive:string ->
  ?num_ctx:int ->
  string ->
  Llm_provider.Provider_config.t option

val resolve_provider_model_max_context :
  provider_name:string -> string -> int

val make_registry_config :
  temperature:float ->
  max_tokens:int ->
  ?system_prompt:string ->
  ?api_key_env_overrides:(string * string) list ->
  ?supports_tool_choice_override:bool ->
  ?keep_alive:string ->
  ?num_ctx:int ->
  provider_name:string ->
  model_id:string ->
  Llm_provider.Provider_registry.entry ->
  Llm_provider.Provider_config.t

val parse_model_string :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  ?api_key_env_overrides:(string * string) list ->
  ?supports_tool_choice_override:bool ->
  ?keep_alive:string ->
  ?num_ctx:int ->
  string -> Llm_provider.Provider_config.t option

type weighted_entry_drop =
  | Drop_unregistered_scheme of { model : string; scheme : string }
  | Drop_unavailable_scheme of { model : string; scheme : string }
  | Drop_invalid_syntax of string

val parse_weighted_entry_diag :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  ?api_key_env_overrides:(string * string) list ->
  ?keep_alive:string ->
  ?num_ctx:int ->
  Cascade_config_loader.weighted_entry ->
  (Llm_provider.Provider_config.t, weighted_entry_drop) result

val parse_weighted_entry_with_drop_metric :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  ?api_key_env_overrides:(string * string) list ->
  ?keep_alive:string ->
  ?num_ctx:int ->
  cascade:string ->
  Cascade_config_loader.weighted_entry ->
  Llm_provider.Provider_config.t option

val expand_auto_model_string :
  ?rotation_scope:string -> string -> string list

val expand_auto_models : string list -> string list

val expand_weighted_auto_entries :
  ?rotation_scope:string ->
  Cascade_config_loader.weighted_entry list ->
  Cascade_config_loader.weighted_entry list

val maybe_rotate_weighted_entries :
  ?rotation_scope:string ->
  Cascade_config_loader.weighted_entry list ->
  Cascade_config_loader.weighted_entry list
(** Round-robin rotation across uniform-weight entries when
    [rotation_scope] is supplied. Exposed so {!Cascade_config_selection}
    can apply the same rotate-then-expand sequence as the original
    godfile. *)

val parse_weighted_entries :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  ?api_key_env_overrides:(string * string) list ->
  ?cascade_name:string ->
  Cascade_config_loader.weighted_entry list ->
  Llm_provider.Provider_config.t list

val parse_model_string_result :
  ?temperature:float ->
  ?max_tokens:int ->
  ?system_prompt:string ->
  string -> (Llm_provider.Provider_config.t, string) result
