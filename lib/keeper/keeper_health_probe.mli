(** Keeper health helpers.

    RFC-0041 Phase B2: migrated from per-runtime cache keys to
    per-keeper, per-item (string * string) keys. *)

(** Health status variants. *)
type health_status =
  | Unknown
  | Healthy
  | Unhealthy of string

(** Runtime pressure classes used to explain an unhealthy runtime.
    These labels are intentionally low-cardinality because they are
    persisted into skip observations and surfaced in fleet diagnostics. *)
type runtime_pressure_class =
  | Client_capacity_full
  | Runtime_admission_full
  | Provider_capacity
  | Provider_dns_failure
  | Provider_timeout
  | Provider_error
  | Turn_stale_timeout
  | Keeper_liveness_failure
  | Completion_contract_failure
  | Runtime_failure

val runtime_pressure_class_to_string : runtime_pressure_class -> string
val runtime_pressure_class_of_label : string -> runtime_pressure_class option

val runtime_pressure_class_of_failure_reason
  :  Keeper_registry.failure_reason option
  -> runtime_pressure_class option

(** {1 Per-item health (RFC-0041)} *)

(** [is_item_healthy ~keeper_name ~item_id] returns the cached health
    status for the specific keeper+item pair.
    Returns [false] when no probe result is available (Unknown) or
    the last probe reported Unhealthy. *)
val is_item_healthy : keeper_name:string -> item_id:string -> bool

(** [set_item_health ~keeper_name ~item_id status] updates the cache
    for a specific keeper+item pair. *)
val set_item_health : keeper_name:string -> item_id:string -> health_status -> unit

(** [record_item_result ~keeper_name ~item_id ~success] updates health
    state based on turn outcome. Success -> Healthy, Failure -> Unhealthy. *)
val record_item_result : keeper_name:string -> item_id:string -> success:bool -> unit

(** {1 Phase-based health predicate} *)

(** [is_terminal_unhealthy phase] returns true only for terminal
    unhealthy phases (Dead, Zombie, Crashed).  All other phases
    including Restarting are treated as healthy for runtime ratio
    purposes.  Exhaustive match ensures compiler catches omissions
    when new phase variants are added. *)
val is_terminal_unhealthy : Keeper_state_machine.phase -> bool

(** {1 Runtime health scan} *)

(** [max_failed_allowed_for_runtime ~total] returns the maximum number
    of terminal-unhealthy keepers (Dead/Zombie/Crashed) a runtime group of
    size [total] can hold while still being treated as healthy.
    Formula: [max 1 (total / 10)] — one keeper down is always allowed,
    larger runtimes scale at 10%.  Exposed so tests and other callers
    can derive the same health threshold without duplicating the
    arithmetic. *)
val max_failed_allowed_for_runtime : total:int -> int

(** [check_runtime_health ~base_path] scans the registry and computes
    the health status of each active runtime.  Returns a list of
    (runtime_id, is_healthy) pairs.  A keeper is counted as failed
    only when its phase is Dead, Zombie, or Crashed — not based on
    restart_count, which is monotonic and would cause permanent
    runtime pollution.  Healthy iff
    [failed <= max_failed_allowed_for_runtime ~total].  This function
    reads registry state and performs no runtime/provider calls. *)
val check_runtime_health : base_path:string -> (string * bool) list
