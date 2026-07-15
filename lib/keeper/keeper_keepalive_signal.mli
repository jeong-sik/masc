open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type grpc_heartbeat_starter_fn = {
  f : 'a. ctx:'a context -> m:keeper_meta -> stop:bool Atomic.t -> (unit -> unit) option;
}

val grpc_heartbeat_starter : ctx:'a context -> m:keeper_meta -> stop:bool Atomic.t -> (unit -> unit) option

val register_grpc_heartbeat_starter : grpc_heartbeat_starter_fn -> unit

val record_wake_payload :
  keeper_name:string ->
  trace_id:string ->
  turn_index:int ->
  context_window:int ->
  system_prompt_bytes:int ->
  tool_schema_json_bytes:int ->
  message_content_bytes:int ->
  message_count:int ->
  role_counts:(string * int) list ->
  tool_count:int ->
  has_compact_happened:bool ->
  unit

val register_record_wake_payload :
  (keeper_name:string ->
   trace_id:string ->
   turn_index:int ->
   context_window:int ->
   system_prompt_bytes:int ->
   tool_schema_json_bytes:int ->
   message_content_bytes:int ->
   message_count:int ->
   role_counts:(string * int) list ->
   tool_count:int ->
   has_compact_happened:bool ->
   unit) ->
  unit

val record_tool_skipped :
  keeper_name:string -> tool_name:string -> reason_code:string -> unit

val register_record_tool_skipped :
  (keeper_name:string -> tool_name:string -> reason_code:string -> unit) ->
  unit

val record_execute_output :
  keeper_name:string ->
  task_id:string option ->
  stdout:string ->
  stderr:string ->
  status:Yojson.Safe.t ->
  streamed:bool ->
  unit

val register_record_execute_output :
  (keeper_name:string ->
   task_id:string option ->
   stdout:string ->
   stderr:string ->
   status:Yojson.Safe.t ->
   streamed:bool ->
   unit) ->
  unit

val record_execute_stream_chunk :
  keeper_name:string -> stream:[ `Stdout | `Stderr ] -> string -> unit

val register_record_execute_stream_chunk :
  (keeper_name:string -> stream:[ `Stdout | `Stderr ] -> string -> unit) ->
  unit

val record_execute_stream_start :
  keeper_name:string -> task_id:string option -> unit

val register_record_execute_stream_start :
  (keeper_name:string -> task_id:string option -> unit) ->
  unit

val record_execute_stream_end :
  keeper_name:string -> task_id:string option -> status:Yojson.Safe.t -> unit

val register_record_execute_stream_end :
  (keeper_name:string -> task_id:string option -> status:Yojson.Safe.t -> unit) ->
  unit

(** FSM guard identity helpers (Cycle 43).
    Wrapped by [Keeper_fsm_guard_runtime.wrap_unit] at call sites. *)
val pre_turn_complete_heartbeat : turn_running:bool ref -> unit
val post_turn_complete_heartbeat : turn_running:bool ref -> unit
val post_wakeup_signal : wakeup:bool Atomic.t -> unit
val post_submit_task : meta:keeper_meta -> task_id:Keeper_id.Task_id.t -> unit
val post_heartbeat_tick : wakeup:bool Atomic.t -> unit

(** Outcome of an [interruptible_sleep] call. Mirrors the three terminal
    branches of the polling loop, so callers can distinguish an exact Keeper
    wake from the configured heartbeat cadence. *)
type sleep_outcome =
  | Stopped   (** [stop] atomic was observed [true] before the duration
                  elapsed. *)
  | Woken     (** [wakeup] atomic transitioned [true -> false] via CAS;
                  the caller should treat this as a [HeartbeatTick]
                  spec-action and dispatch a turn. *)
  | Timeout   (** Full [duration] elapsed without [stop] or [wakeup]. *)

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~chunk_sec instead of waiting for the full interval. *)
val interruptible_sleep :
  clock:'a Eio.Time.clock -> stop:bool Atomic.t -> wakeup:bool Atomic.t ->
  float -> sleep_outcome

(** Wake up a specific keeper immediately.

    When [?stimulus] is given, the stimulus is durably appended to the keeper's
    Event Layer queue ([Keeper_registry_event_queue.enqueue]) independently of
    lifecycle phase. Only the wake hint is restricted to [Running]. If no live
    registry entry exists, callers must supply [base_path] so the payload can
    be persisted for replay. Callers that only need to break the keeper out of
    [interruptible_sleep] may omit the stimulus. See RFC-0020 §3 (data channel
    vs hint signal). *)
val wakeup_keeper :
  ?base_path:string ->
  ?stimulus:Keeper_event_queue.stimulus ->
  string -> unit

(** Wake up all running keepers. [None] preserves legacy global wakeup. *)
val wakeup_all_keepers : ?base_path:string -> unit -> unit

val wakeup_relevant_keeper_for_board_signal :
  config:Workspace.config -> Board_dispatch.board_signal -> unit

(** Per-stage timing accumulator for Phase 0 profiling. *)
type stage_timing = {
  presence_ms : float;
  snapshot_ms : float;
  board_ms : float;
  turn_ms : float;
}

val stage_timing_ring_size : unit -> int

val percentile : float array -> float -> float

val stage_timing_to_json :
  ring:stage_timing array -> count:int ->
  [> `Null
  | `Assoc of
      (string *
       [> `Assoc of (string * [> `Float of float | `Int of int ]) list ])
      list
  ]

val format_since_last_scheduled_autonomous : int option -> string

val keepalive_entry_accepts_late_event :
  ctx:'a context -> keeper_name:string -> bool

val dispatch_keepalive_event :
  ctx:'a context -> keeper_name:string ->
  Keeper_state_machine.event -> unit

val dispatch_keepalive_event_with_audit :
  ctx:'a context -> keeper_name:string ->
  snapshot:Keeper_measurement.measurement_snapshot ->
  events_fired:Keeper_state_machine.event list ->
  selected_event:Keeper_state_machine.event ->
  Keeper_state_machine.event -> unit
