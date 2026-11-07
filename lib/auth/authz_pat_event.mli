(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   issues or revokes a scoped PAT. A caller that holds the token of a live PAT
   acts as its Human within the scope of the PAT. *)

(** The body of a record of a scoped PAT (design 4.4 and 5.3, plan C4-1c): a
    PAT that was issued, or one that was revoked.

    {b Secret.} The log never holds the secret of a PAT, only
    {!Authz_credential_token.Pat.secret_digest} of the token.

    {b Scope.} An issued PAT holds the scope its Human chose, as
    {!Authz_scope_body} writes it, and the instant it expires, if any. The
    expiry is milliseconds since the epoch, as the time of a record is. A PAT
    has expired when the clock is not before it (design 4.4). Whether a scope
    or an expiry may be issued is decided before the record is written.

    {b Body.} An object whose first member is [event]. An issued PAT is
    [{"event":"issued","pat_id":...,"user_id":...,"secret_digest":...,"scope":...,"expires_at_ms":...}]
    and a revoked one is [{"event":"revoked","pat_id":...}], with the members
    in this order. [scope] is an object of {!Authz_scope_body}, and
    [expires_at_ms] an integer or [null]. The labels are on disk and renaming
    one orphans every record written with it. A body with other members, the
    same members in another order, or a member of another type is refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor in which order the events may come. *)

type t =
  | Issued of
      { pat_id : Authz_types.Pat_id.t
      ; user_id : Authz_types.User_id.t
      ; secret_digest : Authz_credential_token.Pat.Digest.t
      ; scope : Authz_types.Authorization_scope.t
      ; expires_at_ms : int option
      }
  | Revoked of { pat_id : Authz_types.Pat_id.t }

val pat_id : t -> Authz_types.Pat_id.t
val equal : t -> t -> bool

(** The body of the record. [Integer_out_of_range] comes from an
    [expires_at_ms] outside the range of {!Authz_body.int}; no other error can
    come from a value of {!t}. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of a PAT record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event, in their order:
          [scope] an object, [expires_at_ms] an integer or [null], and the
          others strings. *)
  | Invalid_pat_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_secret_digest  (** Not 64 lowercase hex characters. *)
  | Invalid_scope of Authz_scope_body.error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, the
    PAT id is one, and then, for an issued PAT, the user id, the digest, and
    the scope are ones. *)
val of_body : Authz_body.t -> (t, error) result
