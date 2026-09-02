(** Process-local schedule runner status.

    The scheduler domain/store remain durable SSOTs for scheduled work. This
    module only tracks the currently running process' runner loop liveness so
    health/dashboard surfaces can answer whether the production caller has been
    ticking recently. *)

type tick_counts =
  { due_changed : int
  ; emitted : int
  ; rescheduled : int
  ; dispatch_succeeded : int
  ; dispatch_failed : int
  ; dispatch_unsupported : int
  ; dispatch_start_rejected : int
  ; wake_enqueued : int
  ; wake_skipped_no_keeper : int
  ; wake_skipped_missing_schedule : int
  ; wake_skipped_non_keeper_actor : int
  ; wake_skipped_unregistered_keeper : int
  ; wake_failed : int
  }

type wake_enqueue_counts =
  { wake_enqueued : int
  ; wake_skipped_no_keeper : int
  ; wake_skipped_missing_schedule : int
  ; wake_skipped_non_keeper_actor : int
  ; wake_skipped_unregistered_keeper : int
  ; wake_failed : int
  }

type snapshot =
  { tick_in_flight : bool
  ; tick_count : int
  ; success_count : int
  ; failure_count : int
  ; crash_count : int
  ; last_tick_started_at : float option
  ; last_tick_finished_at : float option
  ; last_success_at : float option
  ; last_error_at : float option
  ; last_error : string option
  ; last_duration_sec : float option
  ; last_counts : tick_counts option
  ; totals : tick_counts
      (** Sum of every successful tick's counts since this process started.
          [last_counts] answers "what did the newest tick do"; a burst of
          failed dispatches that a later tick retried to success is gone from
          it and still here. Process-local like the rest of this snapshot:
          the durable record of each attempt is the schedule store's wake
          list. *)
  }

val reset_for_test : unit -> unit

val record_tick_started : now:float -> unit
val empty_wake_enqueue_counts : wake_enqueue_counts
val record_tick_ok :
  ?wake_enqueue_counts:wake_enqueue_counts ->
  started_at:float ->
  finished_at:float ->
  Schedule_runner.tick_result ->
  unit
val record_tick_error :
  started_at:float -> finished_at:float -> string -> unit
val record_tick_crash :
  started_at:float -> finished_at:float -> string -> unit

val snapshot : unit -> snapshot

val snapshot_to_yojson :
  ?now:float -> ?stale_after_sec:float -> snapshot -> Yojson.Safe.t
(** Render a stable JSON status. [stale_after_sec] is supplied by the caller
    that owns the runner cadence; this module does not guess runtime policy. *)
