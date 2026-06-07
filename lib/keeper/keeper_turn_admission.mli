(** Keeper runtime admission.

    Owns fleet policy and global runtime capacity. Keeper identity,
    autonomous/reactive provenance, waiter ordering, and holder diagnostics are
    not admission keys. Holder diagnostics stay in {!Keeper_turn_holders}. *)

type fleet_state =
  | Running
  | Paused
  | Stopped

type rejection =
  | Fleet_paused
  | Fleet_stopped
  | Global_inflight_exceeded

type throttle_source =
  | Env_override
  | Toml
  | Default

type fleet_policy =
  { fleet_state : fleet_state
  ; generation : int
  ; reason : string option
  ; updated_by : string option
  ; updated_at : string option
  }

type waiter_info =
  { ticket : int
  ; keeper_name : string
  ; runtime_profile : string
  ; channel : string
  ; enqueued_at : float
  }

type snapshot =
  { fleet_state : fleet_state
  ; global_inflight : int
  ; global_limit : int
  ; available : int
  ; queue_depth : int
  ; active_keepers : string list
  ; waiters : waiter_info list
  ; generation : int
  ; reason : string option
  ; updated_by : string option
  ; updated_at : string option
  }

type token

exception Fleet_stopped_by_operator

val fleet_state_to_string : fleet_state -> string
val rejection_to_string : rejection -> string
val throttle_source_to_string : throttle_source -> string

val keeper_turn_throttle_limit : int
val effective_turn_throttle_limit : int
val keeper_turn_throttle_source : throttle_source
val semaphore_wait_timeout_sec : float

val turn_concurrency_int_of_env_default_for_test :
  string -> default:int -> min_v:int -> max_v:int -> int

val read_policy : ?base_path:string -> unit -> fleet_policy
val pause_fleet : ?base_path:string -> ?reason:string -> ?updated_by:string -> unit -> fleet_policy
val resume_fleet : ?base_path:string -> ?reason:string -> ?updated_by:string -> unit -> fleet_policy
val stop_fleet : ?base_path:string -> ?reason:string -> ?updated_by:string -> unit -> fleet_policy

val snapshot : ?base_path:string -> ?limit:int -> unit -> snapshot
val snapshot_json : ?base_path:string -> ?limit:int -> unit -> Yojson.Safe.t
val global_inflight : unit -> int
val available_turns : limit:int -> int
val available_turns_for_channel : limit:int -> channel:string -> int

val acquire_turn :
  ?base_path:string ->
  limit:int ->
  timeout_s:float ->
  keeper_name:string ->
  runtime_profile:string ->
  channel:string ->
  unit ->
  ((token * int), rejection) result

val with_turn_admission :
  ?base_path:string ->
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  ( 'a
  , [> `Semaphore_wait_timeout of Keeper_turn_admission_types.semaphore_wait_timeout
    | `Turn_admission_rejected of rejection
    ] )
  result

val release_turn : token -> unit
val force_release_keeper : keeper_name:string -> bool

val token_cancel_p : token -> unit Eio.Promise.t
val token_keeper_name : token -> string
val token_acquired_at : token -> float
val token_id : token -> int

val reset_for_test : unit -> unit
