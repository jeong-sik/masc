(** Circuit_breaker — failure observation for MASC agents.

    This intermediate status projection still groups failures by the legacy
    window, but exposes no execution gate, wrapper, or administrative
    suspension API. Recorded status never controls Keeper participation.

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
      (** Legacy cooldown observation. It does not suppress execution. *)
  | HalfOpen
      (** Legacy recovery observation. It does not grant execution. *)

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


(** {1 Maintenance} *)

val cleanup : t -> older_than_seconds:int -> int
(** [cleanup t ~older_than_seconds] removes [Closed] breakers
    whose [last_check] is older than [older_than_seconds].
    Returns the number removed.  Open / half-open breakers are
    preserved regardless of age. *)

(** {1 Global instance}

    Memoized singleton.  Uses Atomic+Stdlib.Mutex rather than {!Eio.Lazy}
    because tests and startup paths can touch the helpers before an Eio
    scheduler exists. *)

val global : unit -> t
(** Global circuit-breaker instance.  Prefer the [*_global] helpers below. *)

val record_failure_global : agent_id:string -> reason:string -> unit
val record_success_global : agent_id:string -> unit
val get_status_global : agent_id:string -> breaker_status
