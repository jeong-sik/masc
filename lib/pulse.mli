(** Pulse — the beating heart of any Space.

    A Space is an abstracted environment where agents exist and act.
    Keeper Autonomy (traces, no end) and TRPG (bounded, session ends) are both Spaces.
    The only axis of variation is lifecycle: when does the heart stop?

    The Pulse is a tick engine driven by two forces:
    - Rhythm: a timer that fires at adaptive intervals (the SA node)
    - Nudge: an external stimulus that demands an immediate beat (adrenaline)

    Consumers register callbacks and ride each beat. The Pulse doesn't know
    what its consumers do — it only knows when to beat and whom to notify.

    Concurrency model: Eio.Fiber.first races the timer fiber against
    the nudge-wait fiber. Whichever completes first triggers the next beat.

    @since 2.62.0 *)

(** {1 Core Types} *)

(** Why did this beat happen? *)
type trigger =
  | Rhythm                (** Regular interval elapsed *)
  | Nudge of string       (** External stimulus with reason *)
  | Demand                (** Forced immediate beat (startup, shutdown) *)

(** A single heartbeat event. *)
type beat = {
  seq     : int;          (** Monotonically increasing beat counter *)
  ts      : float;        (** Unix timestamp when this beat fired *)
  trigger : trigger;      (** What caused this beat *)
}

(** Adaptive rhythm configuration. *)
type rhythm = {
  base_s  : float;        (** Base interval in seconds *)
  min_s   : float;        (** Floor: never beat faster than this *)
  max_s   : float;        (** Ceiling: never beat slower than this *)
  quiet   : int * int;    (** (start_hour, end_hour) in KST — stretch interval during these hours *)
}

(** Space lifecycle. The only difference between spaces. *)
type lifecycle =
  | Always_on             (** Never stops (Keeper Autonomy). Runs until explicit shutdown. *)
  | Bounded of (beat -> bool)
    (** Stops when predicate returns true (TRPG session end, time limit, etc.) *)

(** Runtime statistics. *)
type stats = {
  total_beats   : int;
  total_nudges  : int;
  uptime_s      : float;
  avg_interval  : float;
}

(** {1 Consumer — who rides each beat} *)

(** A consumer is a first-class module that reacts to beats.
    The Pulse calls [should_act] to filter, then [on_beat] to execute.
    Consumers are fully decoupled — they don't know about each other. *)
module type Consumer = sig
  val name       : string
  val should_act : beat -> bool
  val on_beat    : beat -> (unit, string) result
end

(** {1 Consumer Recovery} *)

(** Recovery configuration for consumer failure tracking. *)
type recovery_config = {
  max_consecutive_failures : int;
}

val default_recovery_config : recovery_config

(** {1 Engine} *)

(** The Pulse engine. Opaque mutable state. *)
type t

(** Create a new Pulse engine.

    @param recovery Consumer failure recovery config (default: 3 consecutive failures to disable)
    @param clock Eio clock for sleeping and timestamps
    @param rhythm Adaptive rhythm configuration
    @param lifecycle Always_on or Bounded
    @param consumers First-class consumer modules to notify on each beat *)
val create :
  clock:_ Eio.Time.clock ->
  rhythm:rhythm ->
  lifecycle:lifecycle ->
  consumers:(module Consumer) list ->
  t

(** Start the pulse loop. Blocks the calling fiber until the lifecycle ends.
    Call this inside [Eio.Switch.run] or [Eio.Fiber.fork].

    @param sw Eio switch for managing child fibers *)
val run : sw:Eio.Switch.t -> t -> unit

(** Send an immediate nudge to the pulse from outside.
    Thread-safe. Can be called from any fiber. The next beat will fire
    immediately with [Nudge reason] as its trigger.

    @param reason Human-readable reason for the nudge *)
val nudge : t -> reason:string -> unit

(** Request a graceful shutdown. The current beat (if any) will complete,
    then the loop exits. For [Bounded] spaces, this is also called
    automatically when the predicate returns true. *)
val shutdown : t -> unit

(** Update the rhythm configuration. Takes effect on the next beat cycle.
    Non-yielding — safe to call from any fiber. *)
val set_rhythm : t -> rhythm -> unit

(** Current rhythm configuration. *)
val get_rhythm : t -> rhythm

(** {1 Queries} *)

(** Current runtime statistics. *)
val stats : t -> stats

(** The most recent beat, or [None] if the engine hasn't started. *)
val last_beat : t -> beat option

(** Is the engine currently running? *)
val is_alive : t -> bool

(** {1 Dynamic Consumer Management} *)

(** Add a consumer while the engine is running. Takes effect on the next beat. *)
val add_consumer : t -> (module Consumer) -> unit

(** Remove a consumer by name. Returns [true] if found and removed. *)
val remove_consumer : t -> string -> bool

(** {1 Consumer Recovery} *)

(** List consumers disabled due to consecutive failures. *)
val disabled_consumers : t -> string list

(** Re-enable a previously disabled consumer. Returns [true] if found. *)
val reenable_consumer : t -> string -> bool

(** {1 Defaults} *)

(** Default rhythm: 60s base, 30s min, 300s max, quiet 01:00-06:00 KST. *)
val default_rhythm : rhythm

(** {2 Testing helpers}

    Pure functions exposed for unit testing. Not for production use. *)
module For_testing : sig
  val is_quiet_hour_at : hour:int -> quiet_range:(int * int) -> bool
  (** [is_quiet_hour_at ~hour ~quiet_range] checks if [hour] (0-23) falls
      within the quiet range. Handles wrap-around (e.g., 22..6). *)

  val effective_interval_at : hour:int -> rhythm -> float
  (** [effective_interval_at ~hour rhythm] computes the interval in seconds.
      During quiet hours: base * 3.0, clamped to [min_s, max_s]. *)
end
