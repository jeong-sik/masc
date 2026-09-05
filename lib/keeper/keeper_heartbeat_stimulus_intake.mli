(** Event-Layer stimulus intake for the keeper heartbeat loop.

    Admits every ready Event Layer stimulus from one durable snapshot. Payload
    families share queue order except for explicit owner-lane manual
    durable stimulus admission at persisted turn boundaries, and
    Connector attention, which admits only the first ready conversation. An
    unready input remains queued without blocking later ready work. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_execution

(** [pending_board_event_of_stimulus ~meta_after_triage stim] wraps a
    stimulus into a pending board event, threading the keeper meta's
    continuity summary. [Error unavailable] reports a failed board read
    (board-unavailable-result); this function only reports, it does not
    decide disposition — see [pending_board_events_of_stimulus_result] for
    the consuming layer's classify + drop/retain behavior. *)
val pending_board_event_of_stimulus
  :  meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus
  -> (Keeper_world_observation.pending_board_event option, Keeper_world_observation_board_signal.board_unavailable) result

(** Closed consumption result for an Event-Layer stimulus. A transient Board
    read cannot be represented as an empty successful rendering: it retains
    the exact pending queue selection for a later heartbeat. *)
type stimulus_intake_result =
  | Stimulus_consumed of Keeper_world_observation.pending_board_event list
  | Stimulus_retry_later of
      Keeper_world_observation_board_signal.board_unavailable

(** Pure disposition boundary for one rendered Board event. Permanent
    unavailability is consumed as an empty event; transient unavailability
    remains a typed retry. *)
val classify_pending_board_event_result
  :  (Keeper_world_observation.pending_board_event option, Keeper_world_observation_board_signal.board_unavailable) result
  -> stimulus_intake_result

(** [pending_board_events_of_stimulus_result ~meta_after_triage stim] renders
    [stim] into zero-or-one pending board events. On [Error unavailable] it
    classifies the failure via
    {!Keeper_world_observation_board_signal.disposition_of_unavailable},
    logs and counts it, and returns either [Stimulus_consumed []] for a
    permanent failure or [Stimulus_retry_later unavailable] for a transient
    failure. *)
val pending_board_events_of_stimulus_result
  :  meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus
  -> stimulus_intake_result

type event_queue_intake_error =
  | Pending_selection_failed of string
  | Transient_board_read of
      Keeper_world_observation_board_signal.board_unavailable

(** Map one durable event-queue payload to its typed turn trigger. A payload
    with no dedicated trigger returns [None]; completion-authority rejection
    has its own trigger and turn reason. *)
val event_queue_trigger_of_stimulus :
  Keeper_event_queue.stimulus -> Keeper_world_observation.event_queue_trigger option

val event_queue_intake_error_to_string : event_queue_intake_error -> string
val event_queue_intake_error_reason_label : event_queue_intake_error -> string

(** Only durable selection corruption/read failures count as a crashed cycle.
    A transient Board read is an expected retry condition: it retains the exact
    source without advancing Keeper failure state. Other admitted sources may
    still dispatch in the same turn. *)
val event_queue_intake_error_counts_as_cycle_failure :
  event_queue_intake_error -> bool

(** [record_event_queue_stimulus_turn_started ~ctx ~keeper_name stim] writes
    a generic [Turn_started] reaction for an event-queue stimulus after the
    heartbeat scheduler has admitted a real keeper turn. Logs and swallows
    errors except [Eio.Cancel.Cancelled]. *)
val record_event_queue_stimulus_turn_started
  :  ctx:_ context
  -> keeper_name:string
  -> Keeper_event_queue.stimulus
  -> unit

val record_event_queue_stimulus_turn_finished
  :  ctx:_ context
  -> keeper_name:string
  -> disposition:string
  -> Keeper_event_queue.stimulus
  -> unit
(** The closing half of {!record_event_queue_stimulus_turn_started}. A
    persistence failure is logged and does not abort the turn, for the same
    reason its opening half does not: the ledger records what happened and does
    not decide whether the keeper may continue. *)

(** Result of one heartbeat intake — accumulated pending board events
    after dedup and the number of stimuli consumed from the queue. *)
type heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  consumed_stimulus_count : int;
  consumed_stimuli : Keeper_event_queue.stimulus list;
  pending_selection : Keeper_event_queue_state.pending_selection option;
  consumed_selections : Keeper_event_queue_state.pending_selection list;
  event_queue_intake_error : event_queue_intake_error option;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

(** [consume_single_heartbeat_stimulus ~ctx ~meta_after_triage stim]
    increments Otel_metric_store and logs only after consumption is known.
    A transient Board read returns [Stimulus_retry_later] without incrementing
    the consumed counter.

    [?connector_attention_items] (RFC-0377 P1-1): for a [Connector_attention]
    stimulus, a preloaded (event_id, item) association to resolve [stim]'s
    recorded item from instead of a fresh
    {!Keeper_external_attention.load_events} scan. The caller supplies this
    when consuming a batch of Connector_attention stimuli (the primary plus
    same-conversation companions) so the whole batch costs one scan
    ({!Keeper_external_attention.recorded_items_by_event_ids}) rather than
    one scan per stimulus. Omitted (or [None]), this falls back to the
    original one-id-at-a-time lookup — unchanged for every non-batched
    call. Ignored for every other payload kind. *)
val consume_single_heartbeat_stimulus
  :  ctx:_ context
  -> meta_after_triage:keeper_meta
  -> ?connector_attention_items:(string * Keeper_external_attention.item) list
  -> Keeper_event_queue.stimulus
  -> stimulus_intake_result

(** [ready_hitl_resolution_peek ~base_path ~keeper_name] returns the first
    queued [Hitl_resolved] whose approval has left the pending map, without
    consuming the queue entry (#28809). A turn woken by a different stimulus
    projects this durable resolution as cycle context so the RFC-0356 host
    replay is not starved behind the queue position; the untouched entry is
    later retired by [reconcile_spent_selection] once its grant is spent. An
    approved resolution with no durable record behind it is not projected;
    its entry is retired when the queue reaches it. *)
val ready_hitl_resolution_peek
  :  base_path:string
  -> keeper_name:string
  -> Keeper_event_queue.hitl_resolution option

type spent_selection_reconciliation =
  | Selection_actionable
  | Spent_grant_replay_acknowledged
  | Absent_grant_retired of
      { approval_id : string
      ; absence : Keeper_approval_queue.resolution_absence
      }
      (** the store has no resolution behind the queued approval; the entry
          was acknowledged without a turn *)

val reconcile_spent_selection
  :  config:Workspace_utils.config
  -> keeper_name:string
  -> Keeper_event_queue_state.pending_selection
  -> (spent_selection_reconciliation, string) result
(** An approved Gate resolution is acknowledged once its one-shot grant is
    consumed, because the replay then authorizes nothing and a turn spent on it
    can only re-read the same entry. That path takes no lock: consumption is
    monotonic, so a consumed state cannot revert to usable. A read error leaves
    the selection actionable rather than discarding a possibly live grant. A
    store answer that says nothing stands behind the entry
    ([Keeper_approval_queue.resolution_absence]) retires it as
    [Absent_grant_retired]: reading again cannot change that answer, and a
    turn spent on it fails at the same replay lookup every cycle. *)

(** [heartbeat_event_intake ~ctx ~meta_after_triage
     ~pending_board_events] reads one exact durable queue snapshot and admits
    every ready selection in queue order.

    RFC-0377's routing boundary remains: only the first ready
    [Connector_attention] conversation is admitted, but all of its pending
    members are included. Other connector conversations remain queued; every
    ready non-connector source is included except that at most one
    [Hitl_resolved] is admitted because a turn carries one exact cycle grant.
    Later ready HITL resolutions remain queued for their own replay turns.
    [consumed_stimuli] and [consumed_selections] carry the full batch, while
    [pending_selection] is the first admitted selection for legacy
    primary-source diagnostics.

    The selected observations are merged with the [pending_board_events]
    already accumulated by the caller, deduplicating by [post_id] (the durable
    queue admits at most one pending payload for that identity). A
    [Hitl_resolved] stimulus remains queued until its exact approval id has
    left the pending map, while later ready stimuli can still be selected.
    A transient Board read keeps that exact source pending and sets
    [event_queue_intake_error]. It does not prevent other selections in the
    same snapshot from being admitted and dispatched. *)
val heartbeat_event_intake
  :  ctx:'a context
  -> meta_after_triage:keeper_meta
  -> pending_board_events:Keeper_world_observation.pending_board_event list
  -> heartbeat_event_intake

module For_testing : sig
  (** Force the next [count] Board stimulus reads to report a transient
      [Io_error], allowing the durable retry path to be exercised without a
      real store outage. *)
  val force_transient_board_reads : int -> unit
end
