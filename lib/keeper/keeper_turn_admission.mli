(** Keeper turn admission.

    Owns fleet policy, global turn capacity, per-keeper isolation, and waiter
    ordering. Holder diagnostics stay in {!Keeper_turn_slot}. *)

type fleet_state =
  | Running
  | Paused
  | Stopped

type rejection =
  | Fleet_paused
  | Fleet_stopped
  | Global_inflight_exceeded

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

val read_policy : ?base_path:string -> unit -> fleet_policy
val pause_fleet : ?base_path:string -> ?reason:string -> ?updated_by:string -> unit -> fleet_policy
val resume_fleet : ?base_path:string -> ?reason:string -> ?updated_by:string -> unit -> fleet_policy
val stop_fleet : ?base_path:string -> ?reason:string -> ?updated_by:string -> unit -> fleet_policy

val snapshot : ?base_path:string -> ?limit:int -> unit -> snapshot
val snapshot_json : ?base_path:string -> ?limit:int -> unit -> Yojson.Safe.t
val global_inflight : unit -> int
val available_turns : limit:int -> int

val acquire_turn :
  ?base_path:string ->
  limit:int ->
  timeout_s:float ->
  keeper_name:string ->
  runtime_profile:string ->
  channel:string ->
  unit ->
  ((token * int), rejection) result

val release_turn : token -> unit
val force_release_keeper : keeper_name:string -> bool

val token_cancel_p : token -> unit Eio.Promise.t
val token_keeper_name : token -> string
val token_acquired_at : token -> float
val token_id : token -> int

(** Compatibility hooks for older tests/callers. New code should use [acquire_turn]
    and [release_turn] with explicit tokens. *)
val acquire_global_slot : limit:int -> timeout_s:float -> unit -> (token * int, rejection) result
val release_global_slot : token -> unit
val reset_for_test : unit -> unit
