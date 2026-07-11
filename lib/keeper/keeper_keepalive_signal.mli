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
  model_id:string ->
  context_window:int ->
  approx_body_bytes:int ->
  system_prompt_bytes:int ->
  tool_defs_bytes:int ->
  messages_bytes:int ->
  message_count:int ->
  role_counts:(string * int) list ->
  tool_count:int ->
  has_compact_happened:bool ->
  unit

val register_record_wake_payload :
  (keeper_name:string ->
   trace_id:string ->
   turn_index:int ->
   model_id:string ->
   context_window:int ->
   approx_body_bytes:int ->
   system_prompt_bytes:int ->
   tool_defs_bytes:int ->
   messages_bytes:int ->
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
    branches of the polling loop, so callers can react to "woken by an
    external signal" distinctly from "slept the full duration".

    Closing the [Skip_idle] half of the [MissedWakeup] gap (see
    [specs/keeper-state-machine/KeeperHeartbeat.tla]) requires
    discriminating [`Woken`] from [`Timeout`] at the call site — sibling
    fix #10078 covered [Skip_busy] without exposing this distinction. *)
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

    When [?stimulus] is given, the stimulus is appended to the keeper's
    Event Layer queue ([Keeper_registry_event_queue.enqueue]) before the wakeup
    flag flips. Callers that have a real payload (board post, mention,
    operator directive) should pass it; callers that only need to break
    the keeper out of [interruptible_sleep] may omit it and the call
    behaves as before. See RFC-0020 §3 (data channel vs hint signal). *)
val wakeup_keeper :
  ?base_path:string ->
  ?stimulus:Keeper_event_queue.stimulus ->
  string -> unit

(** Wake up all running keepers. [None] preserves legacy global wakeup. *)
val wakeup_all_keepers : ?base_path:string -> unit -> unit

(** Board-reactive debounce interval (seconds), from runtime config. *)
val board_reactive_debounce_sec : float

(** Connector-reactive (ambient connector message) debounce interval, seconds.
    RFC-connector-ambient-attention-wake P4. *)
val connector_reactive_debounce_sec : float

val connector_reactive_wakeup_allowed :
  base_path:string -> keeper_name:string -> channel_id:string -> bool
(** Whether an ambient connector message on [channel_id] may wake [keeper_name]
    now. Reuses the board-reactive primitive: the RFC-0246 tombstone gate (a
    latched no-progress keeper is not re-woken) plus a per-channel debounce
    ({!connector_reactive_debounce_sec}). Returns [false] within the debounce
    window so a chatty channel wakes the keeper at most once per window; the
    keeper then sees every accumulated message in its chat history. Records the
    wakeup timestamp as a side effect when it returns [true]. *)

val board_reactive_wakeup_max : int

(** [board_wakeup_dedup_key] is the content fingerprint a board wakeup is
    deduped under (RFC-0239 R4): normalized (author,title,content), or the
    [post_id] when title+content are empty. Exposed for testing. *)
val board_wakeup_dedup_key :
  post_id:string -> author:string -> title:string -> content:string -> string

(** Check if a board-reactive wakeup is allowed for [keeper_name] given the
    incoming [signal]. Debounced on the signal's content fingerprint
    (RFC-0239 R4), not its post_id, so identical re-posts collapse. *)
val board_reactive_wakeup_allowed :
  base_path:string
  -> keeper_name:string
  -> signal:Board_dispatch.board_signal
  -> bool

(** True when a paused keeper may be resumed by board-reactive wakeup.
    Operator-owned pauses have [auto_resume_after_sec = None] and are not
    resumed implicitly by board posts or comments. *)
val paused_meta_allows_board_auto_resume : keeper_meta -> bool

(** Select which keepers wake for a board signal (RFC-0020). Explicit
    mentions short-circuit and wake unconditionally; thread-reply/reaction
    followups compete for [?total_limit] immediate-wake slots in candidate
    order. [None] reasons receive nothing (no deterministic address).
    Semantic relatedness is not a deterministic board wake reason; it belongs
    behind an LLM/Judge attention boundary.

    RFC-0334 W1: returns [(selected, deferred)] — the wake budget bounds
    wakes, not delivery. [deferred] carries every addressed followup beyond
    the budget (cap overflow, or all followups when an explicit mention
    short-circuits); the caller appends the stimulus to their mailboxes. *)
val select_board_wakeup_candidates :
  ?total_limit:int ->
  ('a * Keeper_world_observation_board_signal.wake_reason option) list ->
  ('a * Keeper_world_observation_board_signal.wake_reason) list
  * ('a * Keeper_world_observation_board_signal.wake_reason) list

(** Routing outcome for a single board-signal candidate. [Immediate] wakes
    now; [Mailbox_only] enqueues the stimulus without waking (a paused
    keeper whose operator-granted auto-resume is disallowed, addressed by
    an explicit mention); [Excluded] does neither. Exposed for testing. *)
type board_signal_wake_lane =
  | Immediate of Keeper_world_observation_board_signal.wake_reason
  | Mailbox_only of Keeper_world_observation_board_signal.wake_reason
  | Excluded

(** [board_signal_wake_lane ~phase ~auto_resume_allowed wake_reason] routes
    a candidate given its phase and whether an explicit mention is entitled
    to auto-resume it. RFC-0334 W1: a deterministic address
    ([Explicit_mention]) is never [Excluded] outright — a paused keeper
    without auto-resume still gets [Mailbox_only] rather than a silent
    drop. Non-explicit followups on a paused keeper stay [Excluded]: pause
    is an operator opt-out from implicit wake, not from addressed
    mentions. Defensively [Excluded] for phases other than Running/Paused
    (unreachable given {!board_signal_entry_is_wakeup_candidate}'s
    pre-filter, but total over all 13 phases). *)
val board_signal_wake_lane :
  phase:Keeper_state_machine.phase
  -> auto_resume_allowed:bool
  -> Keeper_world_observation_board_signal.wake_reason option
  -> board_signal_wake_lane

val wakeup_relevant_keeper_for_board_signal :
  config:Workspace.config -> Board_dispatch.board_signal -> unit

(** Per-stage timing accumulator for Phase 0 profiling. *)
type stage_timing = {
  presence_ms : float;
  snapshot_ms : float;
  board_ms : float;
  turn_ms : float;
  recurring_ms : float;
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
