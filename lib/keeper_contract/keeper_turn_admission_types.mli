(** Holder pool and wait-timeout payload for keeper turn admission. *)

type holder_pool =
  | Turn_holder
  | Autonomous_holder
  | Reactive_holder

val holder_pool_to_string : holder_pool -> string

exception Semaphore_wait_timeout of float

type admission_wait_phase =
  | Autonomous_queue_head
  | Autonomous_admission
  | Reactive_admission
  | Global_admission

val admission_wait_phase_to_string : admission_wait_phase -> string

type semaphore_wait_timeout =
  { timeout_wait_sec : float
  ; timeout_phase : admission_wait_phase
  ; timeout_autonomous_available : int
  ; timeout_reactive_available : int
  ; timeout_turn_available : int
  ; timeout_queue_depth : int
  ; timeout_queue_ahead : int option
  ; timeout_holders : (string * float) list
  }

val int_of_env_default :
  primary:string -> default:int -> min_v:int -> max_v:int -> int
