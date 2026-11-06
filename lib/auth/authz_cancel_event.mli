(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   lifts the block of a given-up revocation. The block is what keeps a subject
   from acting while its revocation is unfinished. *)

(** The body of a record of kind [Revocation_cancel] (design 8.3, plan
    B2e-2b): an eligible Admin lifts the block of one given-up reduction. The
    reduction stays undone, so the subject keeps what it had before it.

    {b Body.} [{"aborted":...,"subject":...}], in this order. [aborted] is the
    [intended_next_record_digest] of the intent given up, as 64 lowercase hex
    characters. [subject] has the shape that {!Authz_external_store} writes for
    the subject of a change, so the log alone says what was let go: for
    example [{"type":"invite","id":"invite-1"}] or
    [{"type":"principal","principal":{"type":"human","id":"alice"}}]. A body
    with other members, the same members in another order, or a member of
    another type is refused. The labels are on disk, and renaming one orphans
    every record written with it.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor whether the block is held. *)

type t =
  { aborted : Authz_record.Hash.t
  ; subject : Authz_records.Subject.t
        (** The subject of the given-up change, which the record names so the
            log shows it. *)
  }

val equal : t -> t -> bool

(** The body of the record. The error cannot come from a value of {!t}. It is
    returned because {!Authz_body.t} can only be made through functions that
    check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

type error =
  | Not_an_object
  | Wrong_members
      (** Not exactly [aborted], a string, and [subject], an object, in this
          order. *)
  | Invalid_aborted  (** [aborted] is not 64 lowercase hex characters. *)
  | Invalid_subject  (** [subject] is not one of the shapes of a subject. *)

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result, in the order of the
    constructors of {!error}. *)
val of_body : Authz_body.t -> (t, error) result
