(** Pure validation of declared references and materialized runtime capacity. *)

type reference_domain = Runtime_only | Lane_then_runtime

type runtime_reference =
  { site : string
  ; shape : Runtime_config_error.reference_shape
  ; id : string
  ; domain : reference_domain
  }

val find_declared_lane : Runtime_lane.t list -> string -> Runtime_lane.t option
(** [None] means no declared lane has this exact id. *)

val validate_no_dangling_bindings :
  dropped_bindings:(string * Runtime_config_error.drop_reason) list ->
  (unit, Runtime_config_error.load_failure) result
val validate_runtime_references :
  dropped_bindings:(string * Runtime_config_error.drop_reason) list ->
  Runtime_instance.t list -> Runtime_lane.t list -> runtime_reference list ->
  (unit, Runtime_config_error.load_failure) result
val assignment_references : (string * string) list -> runtime_reference list
val media_failover_references : string list -> runtime_reference list
val validate_lanes :
  dropped_bindings:(string * Runtime_config_error.drop_reason) list ->
  Runtime_instance.t list -> Runtime_schema.lane_decl list ->
  (unit, Runtime_config_error.load_failure) result
val lanes_of_decls :
  dropped_bindings:(string * Runtime_config_error.drop_reason) list ->
  Runtime_instance.t list -> Runtime_schema.lane_decl list ->
  (Runtime_lane.t list, Runtime_config_error.load_failure) result
val validate_runtime_max_context : Runtime_instance.t list -> (unit, Runtime_config_error.load_failure) result
val validate_runtime_thinking_requests :
  Runtime_instance.t list -> (unit, Runtime_config_error.load_failure) result
(** Refuse every [Agent_core] runtime whose model row decides its own thinking
    request ({!Runtime_schema.thinking_request} is [Some _]) when the request it
    builds, with {!Runtime_thinking_seed} applied as a turn applies it, is one
    {!Llm_provider.Complete_common.request_admission} refuses. A row that
    decides nothing leaves [enable_thinking] to the turn's caller, so it is not
    judged here. *)
