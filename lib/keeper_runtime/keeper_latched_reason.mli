(** Typed SSOT for a durable Keeper lifecycle latch.

    Ordinary failure observations never inhabit this type. Structural
    transcript corruption is a reset-required lifecycle latch because replaying
    the same checkpoint is unsafe. Retired or unknown latches are rejected
    explicitly. *)

type t =
  | Operator_paused of { operator_actor : operator_actor }
  | Dead_tombstone
  | Transcript_corruption_reset_required

and operator_actor =
  | Grpc_directive
  | Keeper_down

val to_wire : t -> string
val of_wire : string -> (t, string) result
val equal : t -> t -> bool
val hash : t -> int
val pp : Format.formatter -> t -> unit

val operator_actor_grpc_directive : operator_actor
val operator_actor_keeper_down : operator_actor
val operator_actor_to_wire : operator_actor -> string

(** {1 Strength ordering}

    The latch began as an annotation on the [paused] bit. It is now a decision
    input: admission denies by latch identity, and generic resume refuses
    [Transcript_corruption_reset_required] and [Dead_tombstone] outright. So
    replacing a persisted latch with a weaker one is a privilege change, not a
    relabel — it hands a keeper back a recovery path the stronger latch had
    denied.

    The ordering below is that constraint, made explicit. Before it existed,
    the same rule was stated in prose and re-implemented per site
    ([Keeper_meta_contract.mark_resumed]'s refusal match,
    [Keeper_meta_store.persist_transcript_corruption_pause]'s admission match),
    and omitted at the two operator-pause writers — which is how a
    reset-required latch could be silently downgraded to an ordinary pause. *)

type strength =
  | Resumable
      (** Generic resume clears it. [Operator_paused]. *)
  | Reset_required
      (** Recoverable, but not by generic resume: the underlying damage must be
          repaired first. [Transcript_corruption_reset_required]. *)
  | Terminal
      (** No resume path. The identity is recreated, not revived.
          [Dead_tombstone]. *)

val strength : t -> strength

val strength_to_wire : strength -> string
(** Stable projection for logs and metrics. Decisions must match on the typed
    value. *)

type replacement =
  | Replace of t
      (** The request is at least as strong as what is persisted. *)
  | Keep_stronger of
      { persisted : t
      ; rejected : t
      }
      (** The request would weaken the persisted latch. The persisted latch
          stands. Callers log this rather than dropping it silently: the
          keeper is still paused as the requester intended, but for a reason
          that constrains recovery more than they asked for. *)

val replace : persisted:t option -> requested:t -> replacement
(** Resolve a latch write against what is already persisted.

    [persisted = None] always yields [Replace] — there is no latch to weaken.
    A caller that must also honour a [paused = true] record carrying no latch
    (an unclassified pause) has to consult that bit itself; this module sees
    only the latch. Equal strength yields [Replace], so re-pausing under a
    different [operator_actor] is permitted. *)

module Stable : sig
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end
