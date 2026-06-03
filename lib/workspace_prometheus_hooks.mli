(** Prometheus adapter for neutral Workspace metric hooks. *)

val fsm_drift_metric : string
val record_fsm_drift : variant:string -> force:bool -> unit

val fsm_drift_per_agent_metric : string
val record_fsm_drift_with_agent :
  variant:string -> force:bool -> agent_name:string -> unit

val distributed_lock_acquire_failed_metric : string
val record_distributed_lock_acquire_failed : key:string -> attempts:int -> unit

val process_timeout_metric : string
val record_process_timeout :
  program:string -> timeout_sec:float -> origin:Timeout_origin.t -> unit

val install : unit -> unit
