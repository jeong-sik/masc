(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   takes the Admin assignment from a principal. An Admin manages the other
   people of the installation. *)

(** The body of a record of kind {!Authz_record.Kind.Admin_assignment} (design
    4.1, plan B3c-3): the Admin assignment of a principal is revoked.

    An Admin assignment is made by the admission that spends an Admin invitation
    ({!Authz_admission_event}), so this body has one event, the revocation.

    {b Cause.} Design 4.1 makes the cause of a revocation required. With
    [Security_incident], the same record puts the shares and the delegated
    grants that the Admin wrote in [Revocation_pending]; with [Operational],
    they stay in force. The first stage has no shares and no delegated grants
    (design 1.1), so the cause is recorded and changes nothing else yet.

    {b Body.} [{"event":"revoked","user_id":...,"cause":...}], in this order.
    The labels are on disk and renaming one orphans every record written with
    it. A body with other members, the same members in another order, or a
    member of another type is refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor whether the principal is an Admin. *)

type cause =
  | Security_incident
  | Operational

val causes : cause list

(** The label on disk: [security_incident] or [operational]. *)
val cause_label : cause -> string

val cause_of_label : string -> cause option

type t =
  | Revoked of
      { user_id : Authz_types.User_id.t  (** The principal that stops being an Admin. *)
      ; cause : cause
      }

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
  | Unknown_cause of string

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object
    whose first member is [event], the event is known, its members are those of
    the event, and then the user id and the cause are each one. *)
val of_body : Authz_body.t -> (t, error) result
