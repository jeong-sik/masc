(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   registers an identity on the allowlist or removes it. The first sign-in of a
   registered identity makes a Member of the installation. *)

(** The body of a record of the allowlist (plan C2d): an identity that an Admin
    registered, or a registration that an Admin removed.

    {b Body.} An object whose first member is [event]. A registration is
    [{"event":"registered","registration_id":...,"identity":...}] and a removal
    is [{"event":"removed","registration_id":...}], with the members in this
    order. [identity] is the member of {!Authz_external_identity.to_body}. The
    labels are on disk and renaming one orphans every record written with it. A
    body with other members, the same members in another order, or a member of
    another type is refused.

    A registration carries no role: the person it admits is a Member. An Admin
    is admitted through an invitation only.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor in which order the events may come. *)

type t =
  | Registered of
      { registration_id : Authz_types.Registration_id.t
      ; identity : Authz_external_identity.t
      }
  | Removed of { registration_id : Authz_types.Registration_id.t }

val registration_id : t -> Authz_types.Registration_id.t
val equal : t -> t -> bool

(** The body of the record. The error cannot come from a value of {!t}. It is
    returned because {!Authz_body.t} can only be made through functions that
    check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of an allowlist record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event, in their order:
          [registration_id] a string and [identity] an object. *)
  | Invalid_registration_id of Authz_id.error
  | Invalid_identity of Authz_external_identity.body_error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, the
    registration id is one, and then, for a registration, the identity is
    one. *)
val of_body : Authz_body.t -> (t, error) result
