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
val validate_runtime_context_marks : Runtime_instance.t list -> (unit, Runtime_config_error.load_failure) result
(** Refuse a high-water mark above the materialized context window. *)

val validate_muse_prompt_ceilings : Runtime_instance.t list -> (unit, Runtime_config_error.load_failure) result
(** Refuse a Muse window below its host overhead. *)
