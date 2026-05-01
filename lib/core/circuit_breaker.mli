(** Circuit_breaker — failure-based protection for MASC agents.

    Threshold-driven state machine: 3 failures inside a 1-minute
    window opens the breaker for 5 minutes (HalfOpen probe at the
    end of the cooldown).  Defaults are tunable per-instance via
    {!create}.

    {b Concurrency}: all breaker records are immutable; the single
    mutable field [breakers] in the instance is protected by a
    private {!Eio.Mutex}.  Safe to call from any fiber.

    {b Research basis}: Trust-Vulnerability Paradox (TVP)
    [arxiv:2510.18563v1]; the "3+ failures/min" threshold is from
    operational experience.

    @since 0.6.0 — MASC Social v4 Tier 1.

    Internal: [StringMap], [with_lock], [put_breaker],
    [get_or_create_breaker], [prune_old_failures] stay private —
    callers do not need Map / mutex / pruning primitives. *)

(** {1 State machine} *)

(** Breaker state — closed (normal), open (cooldown), half-open
    (recovery probe). *)
type state =
  | Closed
      (** Normal operation — calls flow through. *)
  | Open of {
      until : float;
          (** Unix timestamp at which to retry. *)
      reason : string;
          (** Last failure reason that triggered open. *)
      failure_count : int;
          (** Number of failures inside the window when opening. *)
    }
      (** Cooldown — calls return [Error _] without invoking the
          underlying function. *)
  | HalfOpen
      (** Probe state — single call permitted; success -> closed,
          failure -> back to open with fresh cooldown. *)

(** {1 Records (concrete — for introspection)} *)

type failure_record = {
  timestamp : float;
  reason : string;
}

type breaker = {
  agent_id : string;
  state : state;
  failures : failure_record list;
  last_check : float;
}

(** {1 Instance (abstract)} *)

type t
(** Opaque per-instance handle.  Construct via {!create} or use the
    pre-built {!global}.  Fields ([breakers], [mutex],
    [failure_threshold], [failure_window_sec], [cooldown_sec]) are
    private — callers should not need them. *)

(** {1 Defaults} *)

val default_failure_threshold : int
(** [3] — failures inside the window before opening. *)

val default_failure_window : float
(** [60.0] (1 minute). *)

val default_cooldown : float
(** [300.0] (5 minutes). *)

(** {1 Construction} *)

val create :
  ?failure_threshold:int ->
  ?failure_window:float ->
  ?cooldown:float ->
  unit ->
  t
(** [create ?failure_threshold ?failure_window ?cooldown ()] returns
    a fresh instance with an empty breaker map.  Defaults match
    the [default_*] constants above. *)

val create_default : unit -> t
(** [create_default ()] creates an instance with all defaults.
    Pinned at the contract seam — future config-driven overrides
    reuse this entry without breaking callers. *)

(** {1 Lifecycle} *)

val record_failure : t -> agent_id:string -> reason:string -> unit
(** [record_failure t ~agent_id ~reason] appends a {!failure_record}
    to the agent's failure list.  When the count inside
    [t.failure_window_sec] reaches [t.failure_threshold], opens
    the breaker for [t.cooldown_sec] seconds. *)

val record_success : t -> agent_id:string -> unit
(** [record_success t ~agent_id] clears the agent's failure list.
    If the breaker was [HalfOpen], transitions to [Closed]. *)

val check : t -> agent_id:string -> (unit, string) result
(** [check t ~agent_id] is the gate query:

    - [Closed] -> [Ok ()].
    - [Open] past [until] -> transition to [HalfOpen], [Ok ()].
    - [Open] before [until] ->
      [Error "Circuit open until <iso> (<reason>)"].
    - [HalfOpen] -> [Ok ()] (probe permitted). *)

(** {1 Admin override} *)

val force_open :
  t -> agent_id:string -> reason:string -> duration_sec:float -> unit
(** [force_open t ~agent_id ~reason ~duration_sec] manually opens
    the breaker for [duration_sec] seconds with the supplied
    [reason].  Used by operators to quarantine misbehaving agents. *)

val force_close : t -> agent_id:string -> unit
(** [force_close t ~agent_id] manually closes the breaker and
    clears any pending failures.  Used by operators to override a
    cooldown after manual intervention. *)

(** {1 Introspection} *)

type breaker_status = {
  agent_id : string;
  state_name : string;
      (** ["closed"] / ["open"] / ["half_open"]. *)
  recent_failures : int;
      (** Failures inside [t.failure_window_sec], post-prune. *)
  open_until : float option;
      (** [Some _] iff [state_name = "open"]. *)
  open_reason : string option;
      (** [Some _] iff [state_name = "open"]. *)
}

val get_status : t -> agent_id:string -> breaker_status
(** [get_status t ~agent_id] returns the current snapshot.  When
    no breaker exists for [agent_id], returns a synthetic "closed"
    status (no side effects). *)

val status_to_json : breaker_status -> Yojson.Safe.t
(** Hand-written serialiser.  Output schema:

    {[
      \{
        "agent_id": <string>,
        "state": <"closed"|"open"|"half_open">,
        "recent_failures": <int>,
        "open_until": <float|null>,
        "open_reason": <string|null>
      \}
    ]} *)

val list_all_breakers : t -> breaker_status list
(** [list_all_breakers t] returns one {!breaker_status} per
    registered agent.  Side effect: prunes expired failures from
    each breaker (in-place). *)

(** {1 Maintenance} *)

val cleanup : t -> older_than_seconds:int -> int
(** [cleanup t ~older_than_seconds] removes [Closed] breakers
    whose [last_check] is older than [older_than_seconds].
    Returns the number removed.  Open / half-open breakers are
    preserved regardless of age. *)

(** {1 Wrappers (combined check + execute + record)} *)

val wrap :
  t ->
  agent_id:string ->
  (unit -> ('a, string) result) ->
  ('a, string) result
(** [wrap t ~agent_id f] composes [check] + [f] + record:

    + [check] open -> [Error _] (f not called).
    + [f ()] returns [Ok _] -> [record_success], pass through.
    + [f ()] returns [Error msg] -> [record_failure ~reason:msg],
      pass through. *)

val wrap_result :
  t -> agent_id:string -> (unit -> 'a) -> ('a, string) result
(** [wrap_result t ~agent_id f] is the exception-catching variant.
    Re-raises {!Eio.Cancel.Cancelled} (cooperative cancellation
    must propagate); other exceptions are converted to
    [Error (Printexc.to_string exn)] with [record_failure]. *)

(** {1 Global instance}

    Lazy-initialised singleton.  Uses {!Eio.Lazy} (not
    {!Stdlib.Lazy}) because [Lazy.force] is not fiber-safe —
    concurrent forcing would raise
    {!CamlinternalLazy.Undefined}.  {!Eio.Lazy} blocks the second
    caller until init completes.  [cancel:`Protect] ensures init
    finishes even when the forcing fiber is cancelled. *)

val global : t Eio.Lazy.t
(** Global circuit-breaker instance.  Force via [Eio.Lazy.force]
    or use the [*_global] helpers below. *)

val check_global : agent_id:string -> (unit, string) result
val record_failure_global : agent_id:string -> reason:string -> unit
val record_success_global : agent_id:string -> unit
val force_open_global :
  agent_id:string -> reason:string -> duration_sec:float -> unit
val force_close_global : agent_id:string -> unit
val get_status_global : agent_id:string -> breaker_status
