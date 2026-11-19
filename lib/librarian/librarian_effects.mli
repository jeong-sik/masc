(** What one commit does to a Keeper's Memory
    (RFC librarian-call-only-proposes §8.1).

    The effects are complete: Memory after the commit is {!apply} of Memory
    before it, so a snapshot can be rewritten from the snapshot before it and
    the commit line. *)

open Keeper_memory_os_types

(** Why a fact left Memory. The fact itself stays on the commit line, so a
    removed claim can be found later together with what replaced it.

    These are the removals an answer can cause. The two a Keeper's direct
    write causes ([Superseded_by], [Retracted] in the RFC) are added with the
    writer. *)
type removal =
  | Dropped of { reason : string }
  | Merged_into of string (** Memory id of the fact that now says it. *)
  | Revised_into of string
  | Support_lost of { missing : string list }
  (** A derived fact whose premises are no longer in Memory. *)

(** Why one op of an answer was left out. The other ops still apply. *)
type why_not =
  | Unknown_ref (** A name the question did not give, or a fact not in Memory. *)
  | Ref_used_twice (** An earlier op of the same answer already named this fact. *)
  | Source_outside_question (** A unit name the question did not give. *)
  | Removed_during_flight of { seq : int }
  (** A direct write removed the fact after the question was made. [seq] is
      the commit that removed it. *)
  | Not_valid_alone
  (** The answer saw one item and no Memory, and tried to remove a fact. *)
  | Successor_unsupported
  (** The fact the op stated or saw again is not in Memory after the answer: it is a
      derived fact, and its premises are not there. Usually the same answer
      removed them. A fact whose premises were already gone before the
      answer is recorded the same way when an op states it. *)

type t =
  { added : fact list
  ; touched : string list (** Only [last_seen] moves. *)
  ; removed : (fact * removal) list
  ; not_applied : (int * why_not * Librarian_answer.new_fact option) list
  (** Op number in the answer counted from 0, the reason, and the claim it
      carried. Ascending by op number. *)
  ; sources : (string * int list) list
  (** For a fact an op stated or saw again: the turn log offsets of the units
      it named. *)
  }

val empty : t

(** Stable token for a metric label or a log field. *)
val why_not_kind : why_not -> string

(** Memory after the commit made at [at]: removed facts leave, touched facts
    are seen at [at], added facts follow in order. *)
val apply : at:float -> fact list -> t -> fact list
