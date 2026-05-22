(** Slot/pool/phase variants + wait-timeout payload for the keeper
    turn slot machinery. *)

type slot_pool =
  | Turn_pool
  | Autonomous_pool
  | Reactive_pool

val slot_pool_to_string : slot_pool -> string

exception Semaphore_wait_timeout of float

type semaphore_wait_phase =
  | Autonomous_queue_head
  | Autonomous_slot
  | Reactive_slot
  | Turn_slot

val semaphore_wait_phase_to_string : semaphore_wait_phase -> string

type semaphore_wait_timeout =
  { timeout_wait_sec : float
  ; timeout_phase : semaphore_wait_phase
  ; timeout_autonomous_available : int
  ; timeout_reactive_available : int
  ; timeout_turn_available : int
  ; timeout_queue_depth : int
  ; timeout_queue_ahead : int option
  ; timeout_holders : (string * float) list
  }

val int_of_env_default :
  primary:string -> default:int -> min_v:int -> max_v:int -> int
