(** Due scanner, generic wake-signal feed, and optional consumer dispatch for
    scheduled automation.

    This module refreshes due schedule state and emits durable generic schedule
    signals. When a consumer is installed, dispatch remains consumer-opaque and
    the store records only generic wake evidence. *)

type signal_kind =
  | Due_candidate

type wake_signal =
  { occurrence_id : Schedule_occurrence_id.t
  ; kind : signal_kind
  ; schedule_instance_id : string
  ; schedule_id : string
  ; emitted_at : float
  ; due_at : float
  ; payload_digest : string
  ; payload : Yojson.Safe.t
  }

type hold_reason =
  | Previous_occurrence_unconsumed
      (** The target still holds this schedule's previous occurrence (#36213). *)
  | Target_intake_fenced of
      { target : string
      ; fence_owner : string
      }
      (** The target refuses intake while [fence_owner] holds its intake
          fence. The occurrence stays due and is reconsidered next tick
          (#34642). *)

type held =
  { signal : wake_signal
  ; reason : hold_reason
  }

type pending_settlement
(** Immutable, process-local intent for a started attempt's returned rejection.
    Keeps the exact attempt, original recurrence clock and first successful
    finish-clock observation. An unavailable authority or failed publication
    keeps the intent and excludes that same definition from fresh admission
    for as long as the error persists. There is no expiry or automatic discard;
    progress requires successful original settlement or positive supersession
    evidence from the authoritative store. Unrelated definitions remain eligible.
    Cancellation/process death are outside retention. *)

type settlement_failure =
  | Finish_clock_raised of string
  | Store_settlement_error of Schedule_store.store_error
  | Store_settlement_raised of string

type settlement_error =
  { occurrence_id : Schedule_occurrence_id.t
  ; schedule_id : string
  ; failure : settlement_failure
  }

val settlement_error_to_string : settlement_error -> string

type tick_result =
  { due_changed : int
  ; emitted : wake_signal list
  ; rescheduled : int
  ; dispatches : dispatch_result list
  ; held : held list
      (** Due candidates the consumer held back this tick ([defer_wake]):
          no signal was appended and nothing was dispatched, so they are not
          dispatch results. A held occurrence keeps its identity from tick to
          tick until its target consumes the previous one (#37912). *)
  ; held_at : float
      (** When this tick decided [held]: the clock right after it asked every
          due candidate whether to hold, before it emitted or dispatched
          anything. Dispatch can take seconds, so this is earlier than the
          tick's finish (#38411). *)
  ; pending_settlements : pending_settlement list
  ; settlement_errors : settlement_error list
      (** This cadence's failed settlement observations. Replays are not new
          consumer dispatches or receipts. *)
  }

and dispatch_status =
  | Dispatch_succeeded
  | Dispatch_failed
  | Dispatch_unsupported
  | Dispatch_start_rejected

and dispatch_result =
  { occurrence_id : Schedule_occurrence_id.t
  ; schedule_id : string
  ; status : dispatch_status
  ; detail : Yojson.Safe.t option
  ; error : string option
  }

type consumer_dispatch_error =
  | Retryable_dispatch_failure of string
  | Occurrence_dispatch_rejection of string
      (** This wake cannot be delivered; a future recurrence remains valid. *)
  | Terminal_dispatch_rejection of string
      (** The schedule itself cannot dispatch, including invalid payloads. *)

type acceptance_commit
(** Opaque proof that the schedule ledger accepted the durable consumer work.
    A consumer obtains it only from the runner-provided commit callback. *)

type consumer_dispatch_result =
  | Work_accepted of
      { detail : Yojson.Safe.t
      ; acceptance_commit : acceptance_commit
      }
(** Proof that the wake message is durable. Keeper work results are outside the
    scheduler contract. *)

type consumer =
  { accepts : Schedule_domain.schedule_request -> (unit, string) result
  ; dispatch :
      Workspace_utils.config ->
      now:float ->
      wake_signal ->
      Schedule_domain.schedule_request ->
      commit_acceptance:
        (Yojson.Safe.t ->
         (acceptance_commit, consumer_dispatch_error) result) ->
      (consumer_dispatch_result, consumer_dispatch_error) result
  ; defer_wake :
      Workspace_utils.config ->
      occurrence_id:Schedule_occurrence_id.t ->
      Schedule_domain.schedule_request -> hold_reason option
      (** [Some reason] leaves this due schedule unfired this tick. A pure
          judgment: acting on a reason's owner belongs to the caller of
          [tick], after it returns.
          Self-clock: [Some Previous_occurrence_unconsumed] leaves this due schedule unfired this tick — no
          signal, no dispatch, no advance — because its target still holds the
          previous, unconsumed occurrence. The current [occurrence_id] is a
          retry, not a new wake, and must remain eligible for reconciliation.
          Emission then tracks consumption
          rather than wall-clock, bounding a slow keeper to one pending
          occurrence per instance (#36213). A schedule whose every occurrence is
          distinct work returns [None] and fires on every due. *)
  }

type runner_error =
  | Service_error of Schedule_service.service_error
  | Signal_store_error of string
  | Tick_raised of string

type tick_failure =
  { error : runner_error
  ; pending_settlements : pending_settlement list
  ; settlement_errors : settlement_error list
  }

val runner_error_to_string : runner_error -> string
val tick_failure_to_string : tick_failure -> string

val signal_kind_to_string : signal_kind -> string
val dispatch_status_to_string : dispatch_status -> string

val signals_dir : Workspace_utils.config -> string

val signal_store : Workspace_utils.config -> Dated_jsonl.t
(** The wake signal store under {!signals_dir}. *)

val wake_signal_of_yojson : Yojson.Safe.t -> (wake_signal, string) result

val hold_reason_to_json : hold_reason -> Yojson.Safe.t
(** [{"kind": "previous_occurrence_unconsumed"}] or
    [{"kind": "target_intake_fenced", "target": _, "fence_owner": _}]. *)

val newly_held : previous:held list -> held list -> held list
(** The held occurrences that were not held in [previous], by occurrence
    identity and reason. A hold is a state that lasts until its reason clears, so a caller reports it when it starts rather than on
    every tick that re-observes it (#37912). *)

val tick :
  ?consumer:consumer ->
  ?clock:(unit -> float) ->
  Workspace_utils.config ->
  pending_settlements:pending_settlement list ->
  now:float ->
  retention_days:int ->
  (tick_result, tick_failure) result
(** Refresh due state and append at-most-once generic wake signals for newly
    observable due work. A durable consumer acceptance completes that wake
    occurrence immediately. Consumer payload rejection is terminal. A retryable
    dispatch failure finishes only its current wake attempt and leaves the
    schedule [Due] for the next tick.

    [now] decides what is due and anchors recurrence; [clock] stamps each
    wake's [started_at] and [finished_at] as the attempt actually begins and
    ends. Without [clock] both stamps copy [now], so a wake reads as
    instantaneous whatever the dispatch cost.

    Incoming pending intents replay only store settlement; their definitions
    (schedule instance and public id) are excluded from fresh admission in this
    cadence, including their next recurrence. A replacement instance remains
    eligible. Failed replay never blocks unrelated
    due work. The first newly unresolved post-start settlement returns the
    batch progress immediately, so later callbacks cannot discard that intent.
    Existing replay precedes fresh work, so new failures cannot postpone old
    intents. Both [Ok] and [Error] carry the resulting immutable progress,
    including newly observed finish stamps. Non-cancellation exceptions become
    [Tick_raised] failures with that progress. Capture returned intents before
    fallible postprocessing. Cancellation still propagates without an envelope.

    Pre-start unsupported-payload rejection remains Due after a failed write
    and is reconsidered normally; it is outside these post-start intents.
    No acceptance intent is replayed: a failed acceptance callback can have
    caused the consumer to roll its work back.

    [retention_days] goes straight to {!Schedule_store.refresh_due}: how long a
    finished schedule stays in the ledger. *)
