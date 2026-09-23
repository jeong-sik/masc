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

type tick_result =
  { due_changed : int
  ; emitted : wake_signal list
  ; rescheduled : int
  ; dispatches : dispatch_result list
  ; held : wake_signal list
      (** Due candidates the consumer held back this tick ([defer_wake]):
          no signal was appended and nothing was dispatched, so they are not
          dispatch results. A held occurrence keeps its identity from tick to
          tick until its target consumes the previous one (#37912). *)
  ; held_at : float
      (** When this tick decided [held]: the clock right after it asked every
          due candidate whether to hold, before it emitted or dispatched
          anything. Dispatch can take seconds, so this is earlier than the
          tick's finish (#38411). *)
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
  | Terminal_dispatch_rejection of string

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
      Schedule_domain.schedule_request -> bool
      (** Self-clock: [true] leaves this due schedule unfired this tick — no
          signal, no dispatch, no advance — because its target still holds the
          previous, unconsumed occurrence. The current [occurrence_id] is a
          retry, not a new wake, and must remain eligible for reconciliation.
          Emission then tracks consumption
          rather than wall-clock, bounding a slow keeper to one pending
          occurrence per instance (#36213). A schedule whose every occurrence is
          distinct work returns [false] and fires on every due. *)
  }

type runner_error =
  | Service_error of Schedule_service.service_error
  | Signal_store_error of string

val runner_error_to_string : runner_error -> string

val signal_kind_to_string : signal_kind -> string
val dispatch_status_to_string : dispatch_status -> string

val signals_dir : Workspace_utils.config -> string

val wake_signal_of_yojson : Yojson.Safe.t -> (wake_signal, string) result

val newly_held : previous:wake_signal list -> wake_signal list -> wake_signal list
(** The held occurrences that were not held in [previous], by occurrence
    identity. A hold is a state that lasts until the target consumes its
    earlier occurrence, so a caller reports it when it starts rather than on
    every tick that re-observes it (#37912). *)

val tick :
  ?consumer:consumer ->
  ?clock:(unit -> float) ->
  Workspace_utils.config ->
  now:float ->
  retention_days:int ->
  (tick_result, runner_error) result
(** Refresh due state and append at-most-once generic wake signals for newly
    observable due work. A durable consumer acceptance completes that wake
    occurrence immediately. Consumer payload rejection is terminal. A retryable
    dispatch failure finishes only its current wake attempt and leaves the
    schedule [Due] for the next tick.

    [now] decides what is due and anchors recurrence; [clock] stamps each
    wake's [started_at] and [finished_at] as the attempt actually begins and
    ends. Without [clock] both stamps copy [now], so a wake reads as
    instantaneous whatever the dispatch cost.

    [retention_days] goes straight to {!Schedule_store.refresh_due}: how long a
    finished schedule stays in the ledger. *)
