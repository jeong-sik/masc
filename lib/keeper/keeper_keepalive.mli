open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** Inject the shared Event_bus for keeper snapshot publishing. *)
val set_bus : Agent_sdk.Event_bus.t -> unit

(** Retrieve the shared Event_bus, if set. *)
val get_bus : unit -> Agent_sdk.Event_bus.t option

val register_grpc_heartbeat_starter : Keeper_keepalive_signal.grpc_heartbeat_starter_fn -> unit

(** Process a single directive string from a gRPC HeartbeatAck.
    Supported: "pause", "resume", "wakeup", "claim:<task_id>". *)
val process_directive : agent_name:string -> string -> unit

(** Test-visible helper for the [current_task_id] sent in gRPC heartbeats.
    This may reconcile registry state against the task backlog before reading
    the value, and returns an empty string when reconciliation cannot be trusted. *)
val current_task_id_for_agent : config:Workspace.config -> string -> string

(** Wake up a specific keeper immediately. Used by broadcast notification
    when a @mention targets a running keeper.

    [?stimulus] appends the payload to the keeper's Event Layer queue
    before flipping the wakeup flag. See RFC-0020 §3. *)
val wakeup_keeper :
  ?base_path:string ->
  ?stimulus:Keeper_event_queue.stimulus ->
  string -> unit

(** Wake up all running keepers. Used for @@all broadcast mentions
    or system-wide events. *)
val wakeup_all_keepers : ?base_path:string -> unit -> unit

(** Diagnostic: keepers currently holding a slot in each pool, paired
    with how long (in seconds, relative to [now]) they have held it.
    Sorted by descending hold time.

    [~now] MUST come from {!Time_compat.now} to match the clock used
    by {!Keeper_turn_holders} when recording [acquired_at]. Passing
    [Unix.gettimeofday ()] or any other clock can produce nonsense
    hold-time values. *)
val turn_holders : now:float -> (string * float) list
val autonomous_holders : now:float -> (string * float) list
val reactive_holders : now:float -> (string * float) list

(** Force-release [keeper_name]'s holder rows after watchdog stale
    classification. Returns released diagnostic labels. *)
val force_release_stale_holder : keeper_name:string -> string list

(** Test-only: TTL used to bound orphaned force-release markers left behind
    when a cancelled stale fiber never reaches its finalizer. *)
val force_released_marker_ttl_sec_for_test : float

(** Test-only: count force-release markers still awaiting finalizer
    consumption or expiry pruning. *)
val force_released_marker_count_for_test : unit -> int

(** Test-only: inject a marker without touching live holder rows, so
    marker-retention behavior can be exercised without creating a
    double-release path. *)
val add_force_released_marker_for_test :
  label:Keeper_turn_holders.holder_pool ->
  keeper_name:string ->
  acquisition_id:int ->
  marked_at:float ->
  unit

(** Test-only: prune expired force-release markers using an injected clock. *)
val purge_force_released_markers_for_test : now:float -> unit

(** Test-only: clear force-release markers between tests. *)
val clear_force_released_markers_for_test : unit -> unit

(** Render a compact holder list such as [[keeper-a/181s, +2 more]].
    The input is expected to be sorted longest-first, as returned by the
    holder accessors above. *)
val format_holders : ?limit:int -> (string * float) list -> string

(** Operator-facing one-line summary of all holder pools. *)
val holders_summary : ?limit:int -> now:float -> unit -> string

(** Re-export of {!Keeper_turn_holders.force_release_holder_for} so the
    supervisor and tests have a single import point alongside the holder
    snapshot accessors. *)
val force_release_holder_for : keeper_name:string -> (string * float) list

(** Pure: whether a [Keeper_heartbeat_smart] decision should allow the
    keepalive cycle (presence/snapshot/board/turn/recurring) to run.

    Contract: [Skip_busy] -> [true] (cycle continues; broadcast may be
    debounced elsewhere). [Skip_idle] -> [false] (keeper idle, back
    off). [Emit] -> [true]. Regression guard for the claim-holding
    keeper starvation bug where [Skip_busy] was mis-used as a
    cycle-skip signal, blocking any keeper with a claimed task from
    ever running a turn. *)
val smart_heartbeat_cycle_continues : Keeper_heartbeat_smart.decision -> bool

(** Pure: post-sleep refinement. Promotes [Skip_idle] to [true] iff the
    sleep ended with [Woken]. Closes the [MissedWakeup] gap in
    KeeperHeartbeat.tla left open by sibling fix #10078. *)
val cycle_continues_after_wake :
  Keeper_heartbeat_smart.decision -> Keeper_keepalive_signal.sleep_outcome -> bool

val visible_consumer_count : unit -> int

val visibility_gate_decision :
  visible_consumers:int ->
  has_pending_signal:bool ->
  now:float ->
  last_heartbeat_cycle_ts:float ->
  Keeper_heartbeat_smart.decision ->
  Keeper_heartbeat_smart.decision

val status_tick_usage_json : unit -> Yojson.Safe.t
(** Usage payload for heartbeat/status metrics rows.  Status ticks are not
    LLM calls, so all per-turn token counters are explicit zeroes while
    preserving the same cache-token field shape as turn snapshots. *)

(** Test-only: inject a callback immediately after an acquire flag is set
    and before the diagnostic holder row is recorded. *)
val set_after_acquire_flag_hook_for_test :
  (label:string -> keeper_name:string -> unit) option -> unit

(** PR-M (Leak 9): consecutive [provider_timeout] cycle FAILED strikes
    per keeper. The heartbeat loop routes the count through
    [Keeper_failure_policy] instead of treating the limit as keeper death.
    Reset on any successful turn.
    The in-process CAS map survives within a server lifetime. After
    restart, callers may hydrate the first bump from persisted
    [Provider_timeout_loop] state so multi-process loops still reach
    the policy gate. *)
val provider_timeout_strike_limit : int

type provider_timeout_strike_outcome =
  | Provider_timeout_warn
  | Provider_timeout_soft_backoff

val classify_provider_timeout_strike :
  strikes:int -> provider_timeout_strike_outcome

val bump_budget_exhaustion_seeded :
  keeper_name:string -> prior_strikes:int -> int
(** Increment the strike count for [keeper_name] and return the new
    count. If no in-memory count exists, [prior_strikes] is used as
    the non-negative starting point. Thread-safe under [Stdlib.Mutex]. *)

val bump_budget_exhaustion : keeper_name:string -> int
(** Increment the strike count for [keeper_name] and return the new
    count from the in-memory counter only. Thread-safe under [Stdlib.Mutex]. *)

val reset_budget_exhaustion : keeper_name:string -> unit
(** Drop any strike count for [keeper_name].  Idempotent. *)

val peek_budget_exhaustion_for_test : keeper_name:string -> int
(** Test-only: read current strike count without mutating. *)

val set_budget_exhaustion_for_test :
  keeper_name:string -> strikes:int -> unit
(** Test-only: pre-load strike count.  [strikes <= 0] is equivalent
    to [reset_budget_exhaustion]. *)

val with_recorded_turn_holder :
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (holder_wait_ms:int -> 'a) ->
  'a

(** Test-only wrapper for the in-turn liveness pulse lifecycle. *)
val with_in_turn_liveness_pulse_for_test :
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  interval_sec:float ->
  tick:(unit -> unit) ->
  (unit -> 'b) ->
  'b

(** Keepalive loop meta selection. Disk wins when it changed; otherwise
    fall back to the latest registry snapshot instead of the original boot
    meta so continuity/runtime fields do not regress across turns. *)
val effective_keepalive_meta :
  base_path:string ->
  fallback:keeper_meta ->
  disk_meta_opt:keeper_meta option ->
  keeper_meta

val wakeup_relevant_keeper_for_board_signal :
  config:Workspace.config -> Board_dispatch.board_signal -> unit

(** The heartbeat loop body, extracted for reuse by the supervisor.
    Runs synchronously in the calling fiber until [stop] becomes true. *)
val run_heartbeat_loop :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> bool Atomic.t ->
  wakeup:bool Atomic.t -> unit

(** Compute the p-th percentile of a float array.
    Returns 0.0 for empty arrays. Used by per-stage profiling. *)
val percentile : float array -> float -> float

val start_keepalive :
  ?proactive_warmup_sec:int -> 'a context -> keeper_meta -> unit
val stop_keepalive : ?base_path:string -> string -> unit
val stop_all_keepalives : unit -> unit
