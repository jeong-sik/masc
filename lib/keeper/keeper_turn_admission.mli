(** Keeper_turn_admission — per-keeper turn single-flight gate (RFC-0225 §3.1).

    Every keeper-turn entry path must pass this gate before reaching
    [Keeper_agent_run.run_turn]:

    - the chat lane ([Keeper_turn.handle_keeper_msg]; every transport —
      dashboard stream route, async [Keeper_msg_async] dispatch, direct
      [masc_keeper_msg_stream]) admits with [run_serialized];
    - the autonomous lane ([Keeper_heartbeat_loop_cycle.run_keeper_cycle])
      admits with [run_if_free].

    Without the gate the two lanes execute turns concurrently for the same
    keeper. Measured corruption (2026-06-10 voice-repeat RCA): checkpoint
    last-writer-wins clobber, [total_turns] regression 385→370, and
    tool_calls cross-attribution. *)

type lane =
  | Autonomous (** heartbeat-scheduled cycle; skips when the slot is busy *)
  | Chat (** operator/connector message turn; queues when the slot is busy *)

type in_flight_info =
  { lane : lane
  ; started_at : float (** Unix epoch seconds when the turn was admitted *)
  }

type rejection =
  { waiting : int (** chat requests already waiting on this keeper's slot *)
  ; in_flight : in_flight_info option
    (** the turn holding the slot, if observable at rejection time *)
  }

type slot_snapshot =
  { snapshot_keeper_name : string
  ; snapshot_slot_created : bool
  ; snapshot_in_flight : in_flight_info option
  ; snapshot_waiting : int
  ; snapshot_waiting_since : float option
  ; snapshot_waiting_cap : int
  ; snapshot_waiting_full : bool
  ; snapshot_rejected_chat_count : int
  }

type fleet_snapshot =
  { fleet_keeper_count : int
  ; fleet_waiting_keeper_count : int
  ; fleet_waiting_total : int
  ; fleet_waiting_full_keeper_count : int
  ; fleet_rejected_chat_total : int
  ; fleet_in_flight_keeper_count : int
  ; fleet_slots : slot_snapshot list
  }

val lane_to_string : lane -> string

val max_waiting_chat_requests : int
(** Upper bound on chat requests parked on one keeper's slot. Beyond this
    [run_serialized] rejects instead of queueing, so a message burst cannot
    pile up unbounded waiting fibers behind a long autonomous turn. The value
    comes from the keeper runtime policy surface:
    [MASC_KEEPER_TURN_CHAT_WAITING_CAP] / runtime.toml
    [turn.chat_waiting_cap]. *)

val run_if_free
  :  base_path:string
  -> keeper_name:string
  -> (unit -> 'a)
  -> [ `Ran of 'a | `Busy of in_flight_info option ]
(** Run [f] holding the keeper's turn slot, or return [`Busy] without
    blocking when another turn is in flight. The autonomous lane uses this:
    a busy slot skips the cycle and the next heartbeat retries naturally.
    [`Busy None] means the slot is held but the holder has not yet published
    its info (admission in progress on another fiber). Exceptions from [f]
    (including [Eio.Cancel.Cancelled]) release the slot and re-raise.

    Also returns [`Busy] without attempting the lock when a chat request is
    already parked on this slot ([chat_waiting] is true), or when a busy
    connector/dashboard receipt is active in [Keeper_chat_queue] for this
    keeper (pending or inflight). Eio.Mutex hands a released slot
    directly to the next parked waiter, so a new autonomous cycle would not
    overtake a queued chat regardless; these pre-checks make the yield
    explicit and keep a heartbeat-scheduled cycle from competing for a slot
    a dashboard/connector message is already waiting on or queued behind.
    The [Keeper_chat_queue] half closes the starvation gap where a long or
    back-to-back autonomous turn could otherwise busy-ACK a connector
    forever: the autonomous lane yields on the same backlog the consumer
    drains, so the consumer's [in_flight = None] window opens
    deterministically. Queue persistence/read errors fail closed rather than
    being mistaken for an empty queue. *)

val chat_waiting : base_path:string -> keeper_name:string -> bool
(** [true] when at least one chat request is parked on this keeper's slot
    (waiting in [run_serialized] for an in-flight turn to release). Read
    under the slot's state mutex; [false] for an unknown keeper (no slot,
    hence no waiters). The autonomous lane feeds this into the OAS agent
    loop's exit condition: an idle-filler turn that observes a parked chat
    stops at the next turn boundary so the slot releases and the chat admits
    via direct handoff, instead of the chat starving behind the autonomous
    turn's longer budget. Only counts *parked* waiters, never an already
    admitted (in-flight) turn — an admitted chat holds the slot and is no
    longer waiting. *)

val chat_waiting_since : base_path:string -> keeper_name:string -> float option
(** Unix epoch seconds for the oldest currently parked chat waiter on this
    keeper's slot, or [None] when no chat request is waiting or the keeper slot
    is unknown. *)

val run_serialized
  :  base_path:string
  -> keeper_name:string
  -> (unit -> 'a)
  -> [ `Ran of 'a | `Rejected of rejection ]
(** Run [f] holding the keeper's turn slot, waiting (fiber-cooperatively, in
    Eio.Mutex wakeup order) while another turn is in flight. The chat lane
    uses this: dashboard/connector messages queue rather than error. Returns
    [`Rejected] only when [max_waiting_chat_requests] chat requests are
    already waiting. Cancellation while waiting leaves the queue; exceptions
    from [f] release the slot and re-raise.

    Caller contract: a synchronous self-targeted call from inside the same
    keeper's admitted turn waits for its own turn to finish and is bounded
    only by the caller's turn budget — do not call this from within an
    admitted turn of the same keeper. *)

val run_chat_if_free
  :  base_path:string
  -> keeper_name:string
  -> (unit -> 'a)
  -> [ `Ran of 'a | `Busy of rejection ]
(** Run [f] holding the chat lane only if the keeper slot can be acquired
    immediately. Unlike [run_serialized], this never parks the caller behind an
    in-flight turn. Dashboard direct-stream callers use this to preserve live
    streaming for idle keepers while atomically routing busy keepers to the
    durable chat queue. Existing parked chat waiters have priority: when
    [chat_waiting] is true this returns [`Busy] without attempting the lock. *)

val in_flight
  :  base_path:string
  -> keeper_name:string
  -> in_flight_info option
(** Read-only snapshot of the turn currently holding the keeper's slot,
    or [None] when the slot is free or the keeper is unknown. Gating
    callers (e.g. the chat consumer leaving queued messages to coalesce
    while a turn runs) tolerate the narrow window where a holder has
    locked the slot but not yet published its info — a turn forked on a
    stale [None] simply waits at the slot. *)

val snapshot_for : base_path:string -> keeper_name:string -> slot_snapshot
(** Raw, read-only admission state for one keeper. Unknown keepers return a
    zero-valued snapshot with [snapshot_slot_created = false]; no slot is
    allocated by observation. *)

val fleet_snapshot : base_path:string -> keeper_names:string list -> fleet_snapshot
(** Fleet-level admission state for configured [keeper_names] plus any live
    slot already observed under [base_path]. This keeps dashboard/health
    observability from hiding an active slot simply because the meta/config
    scan missed it. *)

val slot_snapshot_to_yojson : slot_snapshot -> Yojson.Safe.t

val fleet_health_json :
  base_path:string -> keeper_names:string list -> Yojson.Safe.t
(** Health component for [/health] and dashboard runtime resolution. Waiting
    pressure is exposed as raw counts plus [snapshot_waiting_full]; no ratio
    or heuristic threshold is computed. Historical rejections are counters,
    while operator action is required only when a queue is currently full. *)

module For_testing : sig
  val reset : unit -> unit
  (** Drop every slot. Only safe when no turn is in flight. *)

  val peek
    :  base_path:string
    -> keeper_name:string
    -> (in_flight_info option * int) option
  (** [(info, waiting)] for the keeper's slot, or [None] if never created. *)
end
