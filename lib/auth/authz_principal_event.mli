(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   disables, enables, or deletes a person of the installation. A disabled or
   deleted principal acts no more. *)

(** The body of a record of kind {!Authz_record.Kind.Principal} (design 4.1 and
    5.1-5, plan B3c-5): a human principal is disabled, enabled again, or
    deleted.

    {b Deletion.} A deleted principal has no record left, and its user id is
    never given again (design 4.1). The deletion carries the identity the
    principal was bound to: design 4.1 puts the external identity only in the
    events of [authz.jsonl], and the admission already holds the same value, so
    the deletion adds no new one.

    {b Body.} [{"event":"disabled","user_id":...}],
    [{"event":"enabled","user_id":...}], or
    [{"event":"deleted","user_id":...,"identity":...}], with the members in this
    order. [identity] is the member of {!Authz_external_identity.to_body}. The
    labels are on disk and renaming one orphans every record written with it. A
    body with other members, the same members in another order, or a member of
    another type is refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor whether the principal exists. *)

type t =
  | Disabled of { user_id : Authz_types.User_id.t }
  | Enabled of { user_id : Authz_types.User_id.t }
  | Deleted of
      { user_id : Authz_types.User_id.t
      ; identity : Authz_external_identity.t  (** The identity it was bound to. *)
      }

(** The principal the event is about. *)
val user_id : t -> Authz_types.User_id.t

val equal : t -> t -> bool

(** The body of the record. The error cannot come from a value of {!t}. It is
    returned because {!Authz_body.t} can only be made through functions that
    check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
      (** An object whose first member is a known [event], but not exactly the
          members of that event, each of its type, in order. *)
  | Invalid_user_id of Authz_id.error
  | Invalid_identity of Authz_external_identity.body_error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object
    whose first member is [event], the event is known, its members are those of
    the event, and then the user id and the identity are each one. *)
val of_body : Authz_body.t -> (t, error) result
