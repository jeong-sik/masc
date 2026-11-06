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

    {b Membership.} The same record makes the person a member of the workspace
    of the installation, with a namespace for their provider account homes
    (design 4.1, plan B3c-4). The writer draws the namespace from the OS
    CSPRNG, as it does the user id, and no two members ever get the same one.

    {b Body.}
    [{"user_id":...,"identity":...,"invite_id":...,"membership":{"workspace_id":...,"account_home_namespace":...}}],
    in this order. [identity] is the member of {!Authz_external_identity.to_body}.
    A body with other members, the same members in another order, or a member
    of another type is refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor whether the invitation, the identity,
    or the id is free. *)

type membership =
  { workspace_id : Authz_types.Workspace_id.t
  ; account_home_namespace : Authz_types.Account_home_namespace.t
  }

type t =
  { user_id : Authz_types.User_id.t
  ; identity : Authz_external_identity.t
  ; invite_id : Authz_types.Invite_id.t
  ; membership : membership
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
          [identity], an object, [invite_id], a string, and [membership], an
          object of the strings [workspace_id] and [account_home_namespace], in
          this order. *)
  | Invalid_user_id of Authz_id.error
  | Invalid_identity of Authz_external_identity.body_error
  | Invalid_invite_id of Authz_id.error
  | Invalid_workspace_id of Authz_id.error
  | Invalid_account_home_namespace of Authz_id.error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its members are those of the body, and then the user id, the identity, the
    invite id, the workspace id, and the namespace are each one. *)
val of_body : Authz_body.t -> (t, error) result
