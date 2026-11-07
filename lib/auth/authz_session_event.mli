(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   issues or revokes a browser session. A browser that holds the secret of an
   open session acts as its principal. *)

(** The body of a record of a browser session (design 5.2, plan C3): a session
    that was issued, or one that was revoked.

    {b Secret.} The log never holds the secret of a session, only
    {!Secret_digest.of_secret} of it. The writer draws the secret from the OS
    CSPRNG, so the digest needs no key: the secret cannot be guessed from it.

    {b Replaces.} A sign-in from a browser that already holds a session issues
    the new session and ends the old one in the same record ([replaces]), so
    no moment holds both (design 5.2).

    {b Body.} An object whose first member is [event]. An issued session is
    [{"event":"issued","session_id":...,"user_id":...,"secret_digest":...,"replaces":...}]
    and a revoked one is [{"event":"revoked","session_id":...}], with the
    members in this order. [replaces] is a session id or [null]. The labels are
    on disk and renaming one orphans every record written with it. A body with
    other members, the same members in another order, or a member of another
    type is refused.

    The session ends seven days after the time of the record that issued it
    (user decision 2026-11-07). The body carries no expiry: the state reads
    the time of the record.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor in which order the events may come. *)

(** SHA-256 of a session secret, as 64 lowercase hex characters. *)
module Secret_digest : sig
  type t

  (** The digest of a secret. The bytes hashed are
      ["masc-authz-browser-session-secret-v1\n"] followed by the secret, so the
      digest is not the SHA-256 of any other protocol's text. *)
  val of_secret : string -> t

  val of_hex : string -> t option
  val to_hex : t -> string

  (** Compares in a time that does not depend on where the digests differ. *)
  val equal : t -> t -> bool
end

type t =
  | Issued of
      { session_id : Authz_types.Session_id.t
      ; user_id : Authz_types.User_id.t
      ; secret_digest : Secret_digest.t
      ; replaces : Authz_types.Session_id.t option
          (** The session of the same browser that this one ends. *)
      }
  | Revoked of { session_id : Authz_types.Session_id.t }

val session_id : t -> Authz_types.Session_id.t
val equal : t -> t -> bool

(** The body of the record. The error cannot come from a value of {!t}: the
    labels, the ids, and the digest are ASCII. It is returned because
    {!Authz_body.t} can only be made through functions that check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of a session record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event, in their order:
          [replaces] a string or [null] and the others strings. *)
  | Invalid_session_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_secret_digest  (** Not 64 lowercase hex characters. *)
  | Invalid_replaces of Authz_id.error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, the
    session id is one, and then, for an issued session, the user id, the
    digest, and the replaced session id are ones. *)
val of_body : Authz_body.t -> (t, error) result
