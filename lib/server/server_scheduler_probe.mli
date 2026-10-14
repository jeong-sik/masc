(** Server_scheduler_probe — Main-domain wake-up lag ring buffer and GC counter
    snapshot (`RFC-main-domain-scheduler-latency.md` Stage 0 & 0b).

    Shares the underlying atomic ring buffer in {!Scheduler_lag} so `/health`
    `.scheduler.lag` and `.scheduler.gc` always reflect the same samples. *)

type gc_snapshot = Scheduler_lag.gc_snapshot =
  { minor_collections : int
  ; major_collections : int
  ; compactions : int
  ; forced_major_collections : int
  ; heap_words : int
  ; top_heap_words : int
  ; minor_words : float
  ; major_words : float
  ; promoted_words : float
  }

type lag_percentiles = Scheduler_lag.lag_percentiles =
  { sample_count : int
  ; p50_ms : float
  ; p95_ms : float
  ; p99_ms : float
  ; max_ms : float
  ; over_50ms_count : int
  ; over_200ms_count : int
  }

type snapshot = Scheduler_lag.snapshot =
  { lag : lag_percentiles
  ; gc : gc_snapshot
  }

type t = Scheduler_lag.t

val default_capacity : int
(** Default ring buffer capacity (600 samples). *)

val default_interval_s : float
(** Default probe sleep interval (`0.020` = 20ms). *)

val create : ?capacity:int -> unit -> t
(** Create a fresh probe ring buffer.
    @raise Invalid_argument when [capacity <= 0]. *)

val global : t
(** Process-wide default probe instance wired into [/health]. *)

val default : t
(** Alias for {!global}. *)

val record_lag_ms : t -> float -> unit
(** Record a single wake-up lag measurement in milliseconds. Negative values
    are clamped to [0.0]. *)

val capture_gc : unit -> gc_snapshot
(** Read cumulative GC counters via [Gc.quick_stat ()]. *)

val compute_lag_percentiles : t -> lag_percentiles
(** Compute nearest-rank p50/p95/p99, max, and threshold counts over the
    samples currently in the ring. *)

val snapshot : t -> snapshot
(** Capture both {!compute_lag_percentiles} and {!capture_gc}. *)

val gc_snapshot_to_yojson : gc_snapshot -> Yojson.Safe.t
val lag_percentiles_to_yojson : lag_percentiles -> Yojson.Safe.t
val snapshot_to_yojson : snapshot -> Yojson.Safe.t

val run_probe_loop
  :  clock:_ Eio.Time.clock
  -> ?interval_s:float
  -> t
  -> unit
(** Cooperative Eio fiber loop that sleeps [interval_s] (default [0.020] =
    20ms) on [clock] and records [max 0.0 ((t1 -. t0 -. interval_s) *. 1000.0)]
    on each wake-up until cancelled. *)
