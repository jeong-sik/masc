(** MASC-owned cascade runtime resolution helpers.

    This module is the SSOT for:
    - named cascade fallback defaults
    - cascade-name -> model-label resolution
    - model-label -> provider/runtime context resolution
    - model-label -> provider config conversion for execution

    OAS-facing modules should consume this module rather than owning
    cascade/profile resolution themselves.

    @stability Internal *)

val fallback_context_window : int
val cascade_config_path : unit -> string option
val provider_name_of_label : string -> string option
val labels_require_local_discovery : string list -> bool

val refresh_local_discovery_if_possible
  :  ?sw:Eio.Switch.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> string list
  -> bool

val effective_discovered_ctx : static_ctx:int -> discovered:int option -> int
val max_context_of_label : string -> int
val resolve_primary_max_context : string list -> int
val resolve_max_cascade_context : string list -> int
val labels_are_pure_local : string list -> bool
val clamp_context_for_pure_local_labels : labels:string list -> max_context:int -> int
val resolve_primary_model_id : string list -> string
val default_local_model_label_and_id : unit -> string * string
val ensure_api_keys_for_labels : string list -> (unit, string) result
val default_model_strings : cascade_name:string -> string list
val models_of_cascade_name_result : string -> (string list, string) result
val models_of_cascade_name : string -> string list

val resolve_named_providers_result
  :  ?provider_filter:string list
  -> ?require_tool_choice_support:bool
  -> ?require_tool_support:bool
  -> ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy
  -> cascade_name:string
  -> unit
  -> (Llm_provider.Provider_config.t list, string) result

val resolve_named_providers
  :  ?provider_filter:string list
  -> ?require_tool_choice_support:bool
  -> ?require_tool_support:bool
  -> ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy
  -> cascade_name:string
  -> unit
  -> Llm_provider.Provider_config.t list

val resolve_providers_from_model_strings
  :  ?provider_filter:string list
  -> ?require_tool_choice_support:bool
  -> ?require_tool_support:bool
  -> ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy
  -> string list
  -> Llm_provider.Provider_config.t list
