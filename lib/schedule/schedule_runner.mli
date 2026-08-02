(** Due scanner, generic wake-signal feed, and optional consumer dispatch for
    scheduled automation.

    This module refreshes due schedule state and emits durable generic schedule
    signals. When a consumer is installed, dispatch remains consumer-opaque and
    the store records only generic execution evidence. *)

type signal_kind =
  | Due_candidate

type wake_signal =
  { occurrence_id : Schedule_occurrence_id.t
  ; kind : signal_kind
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

type consumer_dispatch_result =
  | Work_completed of Yojson.Safe.t
  | Work_accepted of Yojson.Safe.t
  | Work_failed of
      { error : string
      ; detail : Yojson.Safe.t
      }

(** A consumer's answer about one occurrence it durably accepted.

    [Work_accepted] hands ownership of an occurrence to the consumer and the
    store keeps it [Execution_dispatched] until a correlated completion path
    settles it. That contract assumes the consumer can still find the work. When
    it cannot — its queue entry is gone and it holds no terminal evidence for
    the occurrence — nothing will ever settle it, because the settlement reader
    only runs while the occurrence is a dispatch candidate. This type lets the
    consumer say so. *)
type settlement_evidence =
  | Consumer_holds_occurrence
      (** The accepted work is still pending with the consumer. *)
  | Consumer_settled_occurrence
      (** The consumer has durable terminal evidence for this occurrence; its own
          settlement path owns the store write and this one must not race it. *)
  | Consumer_lost_occurrence of string
      (** Neither pending work nor terminal evidence exists for this occurrence.
          The payload is the durable reason, recorded as the failure. *)

type consumer =
  { accepts : Schedule_domain.schedule_request -> (unit, string) result
  ; dispatch :
      Workspace_utils.config ->
      now:float ->
      wake_signal ->
      Schedule_domain.schedule_request ->
      (consumer_dispatch_result, consumer_dispatch_error) result
  ; settlement :
      Workspace_utils.config ->
      Schedule_domain.schedule_request ->
      Schedule_domain.execution_record ->
      (settlement_evidence, string) result
        (** Asked about one [Execution_dispatched] occurrence. Must be derived
            from durable consumer state, never from elapsed time: a wall-clock
            deadline would make the scheduler judge whether the consumer's
            in-flight work is dead, which is the consumer's call. *)
  }

type runner_error =
  | Service_error of Schedule_service.service_error
  | Signal_store_error of string

val runner_error_to_string : runner_error -> string

val signal_kind_to_string : signal_kind -> string
val signal_kind_of_string : string -> (signal_kind, string) result
val dispatch_status_to_string : dispatch_status -> string

val signals_dir : Workspace_utils.config -> string
val signal_seen_path : Workspace_utils.config -> string

val wake_signal_to_yojson : wake_signal -> Yojson.Safe.t
val wake_signal_of_yojson : Yojson.Safe.t -> (wake_signal, string) result

val read_recent_signals :
  Workspace_utils.config -> int -> (wake_signal list, string) result
(** Read at most [n] recent durable wake signals in chronological order.
    Malformed persisted rows are returned as an explicit decode error. *)

val tick :
  ?consumer:consumer ->
  Workspace_utils.config ->
  now:float ->
  (tick_result, runner_error) result
(** Refresh due state and append at-most-once generic wake signals for newly
    observable due work. Recurring due work is advanced
    after the generic due signal path succeeds when no consumer is installed; a
    consumer dispatch can complete, durably accept, or fail the request.
    [Work_accepted] advances recurring intent but leaves the execution
    unfinished; a one-shot request remains [Running]. Consumer payload rejection
    is terminal. [Work_failed] finishes the exact occurrence; recurring intent
    advances while a one-shot request becomes [Failed]. A typed retryable
    dispatch failure finishes only its current execution attempt and leaves the
    schedule [Due] for the next tick. *)

type reclaim_outcome =
  { examined : int
  ; reclaimed : int
  ; held : int
  ; settled_elsewhere : int
  ; failures : (string * string) list
        (** occurrence id paired with the error that stopped its reclaim. *)
  }

val reclaim_lost_occurrences :
  consumer:consumer ->
  Workspace_utils.config ->
  now:float ->
  (reclaim_outcome, runner_error) result
(** Ask the consumer about every occurrence still [Execution_dispatched], and
    settle the ones it reports as lost through [fail_dispatched_occurrence].

    This is the reverse direction of the consumer-side reconciliation that
    already exists: that one removes a consumer's queue entry once the
    occurrence is terminal, this one terminalizes an occurrence once the
    consumer no longer has it. Both are needed because the two stores are
    written under separate locks and either side can outlive the other.

    Every verdict other than [Consumer_lost_occurrence] leaves the occurrence
    untouched, and a consumer error leaves it untouched as well: an occurrence
    is only ever settled on positive evidence that nothing else can settle it.
    Per-occurrence errors are collected rather than aborting the sweep, so one
    unreadable consumer cannot strand every other occurrence. *)
