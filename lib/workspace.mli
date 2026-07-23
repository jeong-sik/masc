include module type of struct
  include Workspace_core
end

val process_timeout_metric : string
val distributed_lock_acquire_failed_metric : string

val record_process_timeout :
  program:string -> timeout_sec:float -> origin:Timeout_origin.t -> unit

val record_distributed_lock_acquire_failed :
  key:string -> attempts:int -> unit
