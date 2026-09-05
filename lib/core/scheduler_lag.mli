(** Scheduler_lag — how late a ready fiber runs on one Eio domain.

    A probe fiber sleeps for a fixed interval on the monotonic clock and
    records how much later than that it actually woke up. That overshoot is
    the time the domain's scheduler could not run a ready fiber: a fiber that
    computed without yielding, a stop-the-world GC section, a blocking call on
    the scheduler thread, or the OS descheduling that thread. Every HTTP
    handler, SSE write, and keeper step on the same domain waits exactly that
    long, so the number is what the TUI and dashboard experience.

    Samples live in a fixed ring. The probe fiber is the only writer; readers
    are diagnostics such as [/health], which may run on another domain, so
    each slot and the cursor are atomics. A reader can observe a slot mid
    overwrite and see either the old or the new sample, never a torn value. *)

type t

val default_interval_s : float
(** Probe period in seconds. *)

val default_window : int
(** Number of samples the ring keeps. With {!default_interval_s} that is the
    last minute. *)

val create : ?interval_s:float -> ?window:int -> unit -> t
(** [create ()] is an empty ring that has not started a probe.
    @raise Invalid_argument when [interval_s] or [window] is not positive. *)

val global : t
(** The process-wide probe the server starts on its main domain. *)

type summary =
  { samples : int
  ; p50_ms : float
  ; p95_ms : float
  ; p99_ms : float
  ; max_ms : float
  ; mean_ms : float
  ; stalls : int  (** samples at or above [stall_threshold_s] *)
  }

val summarize : t -> summary option
(** Percentiles (nearest rank) over the samples currently in the ring, or
    [None] when nothing has been recorded. *)

type probe_state =
  | Not_started
  | Running
  | Stopped of string  (** the probe raised; the message *)
  | Cancelled  (** the switch that owned the probe was cancelled *)

val probe_state : t -> probe_state

val to_fields : t -> (string * Yojson.Safe.t) list
(** Wire shape used by [/health]. Always carries [probe] ("not_started",
    "running", "stopped" with [stopped_reason], or "cancelled"),
    [interval_ms], [window_s], [stall_threshold_ms] and [samples]; the
    percentile fields are present only when [samples > 0]. *)

val start : sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t -> t -> unit
(** Fork the probe fiber under [sw] on the calling domain; [probe_state] is
    [Running] when this returns. A second call on the same [t] does nothing.
    A failure inside the probe stops it and is reported through [to_fields];
    it never cancels [sw].

    The probe fiber is the ring's only writer. Nothing else may record into a
    started [t]: the ring stores a slot before advancing the cursor, which is
    what lets a reader on another domain trust every slot below the cursor. *)

module For_testing : sig
  val record : t -> lag_s:float -> unit
  (** Store one sample in seconds into a ring no probe has started. *)
end
