(** Opaque execution candidate for keeper-managed runtime lanes.

    This module is the keeper-side boundary around OAS provider configuration.
    Keeper policy code should route and score [t] values by runtime keys and
    capability signals rather than inspecting provider/model fields directly.
    OAS dispatch details stay inside this module's adapter helpers. *)

type t

type context_window_hint =
  { context_window : int
  ; is_local_model : bool
  }

val of_provider_config : Llm_provider.Provider_config.t -> t
val of_provider_configs : Llm_provider.Provider_config.t list -> t list

val runtime_url_of_label : string -> string option

val label_matches_runtime_id : label:string -> runtime_id:string -> bool
val has_resolvable_runtime_label : string list -> bool
val runtime_id_of_label_or_raw : string -> string
val normalize_runtime_name_for_bucket : string -> string
val default_local_runtime_label : unit -> string
val local_runtime_label : string -> string
val labels_require_runtime_mcp_header_sync : string list -> bool
val unknown_runtime_label : string

val provider_label_of_runtime_label :
  ?provider_kind:Llm_provider.Provider_config.provider_kind -> string -> string

val is_structurally_unmetered_runtime_provider : string -> bool

val runtime_label_for_active_id :
  configured_labels:string list -> active:string -> string

val runtime_health_keys_of_labels : string list -> string list

val resolve_reported_runtime_id :
  labels:string list -> reported_runtime_id:string -> string

val context_window_hint_of_labels : string list -> context_window_hint

val threshold_multipliers_of_runtime_id : string -> float * float

val health_key : t -> string
val model_health_key : t -> string
val health_keys : t -> string list

val first_health_cooldown : t -> (string * string) option
val has_recovery_evidence : t -> bool

val effective_attempt_timeout_s :
  is_last:bool -> configured_timeout_s:float option -> t -> float option

val resolve_tool_lane_for_oas_tools :
  ?agent_name:string ->
  ?tool_requirement:[ `Optional | `Required ] ->
  tools:Agent_sdk.Tool.t list ->
  t ->
  ( Agent_sdk.Tool.t list
    * Llm_provider.Llm_transport.runtime_mcp_policy option,
    Agent_sdk.Error.sdk_error )
  result

val runtime_mcp_policy_for_agent :
  agent_name:string ->
  t ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  Llm_provider.Llm_transport.runtime_mcp_policy option

val default_config :
  name:string ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  t ->
  Cascade_runner.config

val enrich_sdk_error :
  cascade_name:Cascade_error_classify.cascade_name ->
  t ->
  Agent_sdk.Error.sdk_error ->
  Agent_sdk.Error.sdk_error

val tool_filter_rejection_label :
  keeper_name:string ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  tools:Agent_sdk.Tool.t list ->
  require_tool_choice_support:bool ->
  require_tool_support:bool ->
  t ->
  string option

val resolve_tool_capable_across_cascades :
  sw:Eio.Switch.t ->
  net:Eio_context.eio_net ->
  keeper_name:string ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  tools:Agent_sdk.Tool.t list ->
  require_tool_choice_support:bool ->
  require_tool_support:bool ->
  exclude_cascade:string ->
  unit ->
  (string * t) option

val capacity_key : t -> string
val capacity_keys : t list -> string list

val runtime_urls : t list -> string list
val http_probe_urls : t list -> string list
val register_http_probe_capable : max_concurrent:int -> t -> unit

val strategy_adapter : t Cascade_strategy.adapter
