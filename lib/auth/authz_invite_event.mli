(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   issues or revokes an invitation. A person who holds the token of an open
   invitation joins the installation, and an Admin invitation makes an Admin. *)

(** The body of a record of kind {!Authz_record.Kind.Invite} (design 5.1-2b and
    5.1-4): an invitation that was issued, or one that was revoked.

    {b Token.} The log never holds the token of an invitation, only
    {!Token_digest.of_token} of it. The writer that issues an invitation makes a
    token of at least 128 bits from the OS CSPRNG, so the digest needs no key:
    the token cannot be guessed from it.

    {b Body.} An object whose first member is [event]. An issued invitation is
    [{"event":"issued","invite_id":...,"token_digest":...,"expires_at_ms":...,"role":...}]
    and a revoked one is [{"event":"revoked","invite_id":...}], with the members
    in this order. The labels are on disk and renaming one orphans every record
    written with it. A body with other members, the same members in another
    order, or a member of another type is refused. [expires_at_ms] is not
    range-checked: whether an invitation has expired is for the writer that
    consumes it to say with its clock, and the replay of the log reads no
    clock.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor in which order the events may come. *)

type role =
  | Member
  | Admin
      (** The person who consumes the invitation becomes an Admin in the same
          record (plan B3c). *)

val roles : role list

(** The label on disk: [member] or [admin]. *)
val role_label : role -> string

val role_of_label : string -> role option

(** SHA-256 of an invitation token, as 64 lowercase hex characters. *)
module Token_digest : sig
  type t

  (** The digest of a token. The bytes hashed are ["masc-authz-invite-token-v1\n"]
      followed by the token, so the digest is not the SHA-256 of any other
      protocol's text. *)
  val of_token : string -> t

  val of_hex : string -> t option
  val to_hex : t -> string
  val equal : t -> t -> bool
end

type t =
  | Issued of
      { invite_id : Authz_types.Invite_id.t
      ; token_digest : Token_digest.t
      ; expires_at_ms : int  (** Wall clock in milliseconds. *)
      ; role : role
      }
  | Revoked of { invite_id : Authz_types.Invite_id.t }

val invite_id : t -> Authz_types.Invite_id.t
val equal : t -> t -> bool

(** The body of the record. [Integer_out_of_range] comes from an
    [expires_at_ms] that {!Authz_body.int} refuses. The other errors cannot come
    from a value of {!t}: the labels, the ids, and the digest are ASCII. They
    are returned because {!Authz_body.t} can only be made through functions that
    check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of an invite record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event, in their order,
          with their types. *)
  | Invalid_invite_id of Authz_id.error
  | Invalid_token_digest  (** Not 64 lowercase hex characters. *)
  | Unknown_role of string

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, the
    invite id is one, and then, for an issued invitation, the digest is one and
    the role is one. *)
val of_body : Authz_body.t -> (t, error) result
