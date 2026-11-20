(** What a direct write does to Memory, as a pure function
    (RFC librarian-call-only-proposes §8.5).

    A direct write is a Keeper's [memory_write] or retraction, or an
    operator's edit. No model is asked. The same write can arrive twice, so
    every state of Memory has an answer here and none of them depends on a
    key carried by the write: a fact is named by its claim.

    {b The table.}

    - [Remember], claim not held: the claim is added.
    - [Remember], claim held with the same category and basis: only its
      [last_seen] moves.
    - [Remember], claim held with another category or basis: {!Already_held}.
      Nothing changes.
    - [Supersede], [old] held: [old] leaves as
      {!Librarian_effects.Superseded_by} and the claim is added, in one
      commit. A claim that is already held is only seen again.
    - [Supersede], [old] not held and the claim held: {!Already_done}.
    - [Supersede], neither held: [Refused Unknown_fact]. The claim is not
      added.
    - [Supersede], [old] is the claim itself: [Refused Supersedes_itself].
    - [Remember] or [Supersede] of a blank claim: [Refused Blank_claim]. The
      snapshot does not write one.
    - Any write on a blank trace: [Refused Blank_trace]. The snapshot names
      the trace of the write that made it, and is not read back without one.
    - [Retract], fact held: it leaves as {!Librarian_effects.Retracted}.
    - [Retract], fact not held: {!Already_absent}.

    {b Support.} After the write, a derived fact whose premises are gone
    leaves as {!Librarian_effects.Support_lost} in the same commit. The claim
    the write states has to be in Memory after that. If it is not, the write
    is refused with the premises it lacks and nothing changes: a claim derived
    from a fact Memory does not hold, or from the fact it supersedes. *)

open Keeper_memory_os_types

type write =
  | Remember of
      { claim : string
      ; category : category
      ; basis : basis
      }
  | Supersede of
      { old : string (** Memory id of the fact the claim replaces. *)
      ; claim : string
      ; category : category
      ; basis : basis
      }
  | Retract of
      { id : string (** Memory id. *)
      ; reason : string
      }

type refusal =
  | Unknown_fact
  | Supersedes_itself
  | Blank_claim
  | Blank_trace
  | Malformed_derivation
  (** The basis is derived and {!Keeper_memory_os_types.derived} does not
      accept its derivations. *)
  | Premises_missing of string list
  (** Memory ids the stated claim rests on that are not in Memory after the
      write. *)

type t =
  | Writes of
      { facts : fact list (** [Librarian_effects.apply ~at] of [effects]. *)
      ; effects : Librarian_effects.t
      }
  (** The one outcome that writes a commit line. *)
  | Already_held
  | Already_done
  | Already_absent (** Neither a success nor a refusal. *)
  | Refused of refusal

(** Stable token for a metric label or a log field. *)
val refusal_kind : refusal -> string

(** [facts] is Memory now. A fact the write adds is first seen at [at], is
    authored, and carries [trace_id] as its origin. [trace_id] is the trace
    the write arrived on: a Keeper's turn, or what an operator's route names
    its request. [by] is recorded on a retraction. *)
val plan
  :  by:Librarian_effects.actor
  -> at:float
  -> trace_id:string
  -> fact list
  -> write
  -> t
