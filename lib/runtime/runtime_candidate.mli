type t

type context_window_hint =
  { context_window : int
  ; is_local_model : bool
  }

type attempt_timeout_resolution =
  { timeout_s : float option
  ; source : string
  }

val of_provider_config :
  max_concurrent:int option -> Llm_provider.Provider_config.t -> t
val of_provider_configs : (Llm_provider.Provider_config.t * int option) list -> t list

val max_concurrent : t -> int option
val provider_cfg : t -> Llm_provider.Provider_config.t

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
val runtime_label_for_active_id : configured_labels:string list -> active:string -> string
val runtime_health_keys_of_labels : string list -> string list
val resolve_reported_runtime_id : labels:string list -> reported_runtime_id:string -> string
val context_window_hint_of_labels : string list -> context_window_hint
val threshold_multipliers_of_runtime_id : string -> float * float

val health_key : t -> string
val model_health_key : t -> string
val health_keys : t -> string list
val provider_label : t -> string
val default_config :
  name:string ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  t ->
  Runtime_agent.config
val first_health_cooldown : t -> (string * string) option
val has_recovery_evidence : t -> bool

val effective_attempt_timeout_resolution :
  is_last:bool -> configured_timeout_s:float option -> t -> attempt_timeout_resolution

val effective_attempt_timeout_s :
  is_last:bool -> configured_timeout_s:float option -> t -> float option

val capacity_key : t -> string
val capacity_keys : t list -> string list
val declared_client_capacity : t -> int option
val register_declared_client_capacity : t -> unit
val runtime_urls : t list -> string list
val local_runtime_urls : t list -> string list
val filter_unhealthy_local_runtime_urls :
  endpoint_health:(string * bool) list -> t list -> t list * string list
val http_probe_urls : t list -> string list
val register_http_probe_capable : max_concurrent:int option -> t -> unit
