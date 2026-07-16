(** Failure_observation records MASC agent outcomes.

    Recorded failures are immutable diagnostic facts. They do not classify,
    gate, delay, or suspend Keeper participation.

    {b Concurrency}: all breaker records are immutable; the single
    mutable field [observations] in the instance is protected by a
    private {!Eio.Mutex}.  Safe to call from any fiber.

    @since 0.6.0 — MASC Social v4 Tier 1.

    Internal: [StringMap], [with_lock], [put_observation], and
    [get_or_create_observation] stay private. *)

(** {1 Records} *)

type failure_record = {
  timestamp : float;
  reason : string;
}

type observation = {
  agent_id : string;
  failure_count : int;
  last_failure : failure_record option;
  last_success_at : float option;
}

(** {1 Instance (abstract)} *)

type t
(** Opaque per-instance handle.  Construct via {!create} or use the
    pre-built {!global}. *)


(** {1 Construction} *)

val create : unit -> t
(** [create ()] returns a fresh instance with no observations. *)

(** {1 Lifecycle} *)

val record_failure : t -> agent_id:string -> reason:string -> unit
(** [record_failure t ~agent_id ~reason] appends a {!failure_record}
    to the agent's failure history. *)

val record_success : t -> agent_id:string -> unit
(** [record_success t ~agent_id] records the successful observation time.
    It does not erase prior failure facts. *)

(** {1 Introspection} *)

val get_observation : t -> agent_id:string -> observation
(** Returns the current immutable snapshot. Missing agents have a zero count
    and no recorded outcome. This read has no side effects. *)

val list_all : t -> observation list

(** {1 Global instance}

    Memoized singleton.  Uses Atomic+Stdlib.Mutex rather than {!Eio.Lazy}
    because tests and startup paths can touch the helpers before an Eio
    scheduler exists. *)

val record_failure_global : agent_id:string -> reason:string -> unit
val record_success_global : agent_id:string -> unit
val get_observation_global : agent_id:string -> observation
