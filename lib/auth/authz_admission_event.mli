(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   lets a person into the installation. The record binds an identity to a new
   principal and spends an invitation. *)

(** The body of a record of kind {!Authz_record.Kind.Admission} (plan B3c-2):
    one person joins through one invitation.

    One record holds the whole admission: the invitation it spends, the identity
    it binds, and the principal it makes, so no crash leaves part of it in the
    log (plan B3c). If the invitation has the role [Admin], the same record makes
    the person an Admin. The role is read from the invitation, not from this
    body, so the body cannot ask for more than the invitation gave.

    {b Body.} [{"user_id":...,"identity":...,"invite_id":...}], in this order.
    [identity] is the member of {!Authz_external_identity.to_body}. A body with
    other members, the same members in another order, or a member of another
    type is refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor whether the invitation, the identity,
    or the id is free. *)

type t =
  { user_id : Authz_types.User_id.t
  ; identity : Authz_external_identity.t
  ; invite_id : Authz_types.Invite_id.t
  }

val equal : t -> t -> bool

(** The body of the record. The error cannot come from a value of {!t}. It is
    returned because {!Authz_body.t} can only be made through functions that
    check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

type error =
  | Not_an_object
  | Wrong_members
      (** An object, but not exactly the members [user_id], a string,
          [identity], an object, and [invite_id], a string, in this order. *)
  | Invalid_user_id of Authz_id.error
  | Invalid_identity of Authz_external_identity.body_error
  | Invalid_invite_id of Authz_id.error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its members are those of the body, and then the user id, the identity, and
    the invite id are each one. *)
val of_body : Authz_body.t -> (t, error) result
