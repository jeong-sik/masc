(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   issues or revokes a Service credential. A caller that holds the token of a
   live one acts as its service. *)

(** The body of a record of a Service credential (design 5.3 and 6.3, plan
    C4-1d): a credential that was issued, or one that was revoked.

    {b Secret.} The log never holds the secret of a credential, only
    {!Authz_credential_token.Service_credential.secret_digest} of the token.

    {b Lifetime.} A credential has no expiry: it acts until a record revokes
    it. The host CLI issues and revokes it as [Local_operator] (design 6.3,
    user decision 2026-11-07). The first credential of a service makes its
    principal [Service service_id]; the state decides that (plan C4-4).

    {b Body.} An object whose first member is [event]. An issued credential is
    [{"event":"issued","credential_id":...,"service_id":...,"secret_digest":...}]
    and a revoked one is [{"event":"revoked","credential_id":...}], with the
    members in this order, all strings. The labels are on disk and renaming one
    orphans every record written with it. A body with other members, the same
    members in another order, or a member of another type is refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor in which order the events may come. *)

type t =
  | Issued of
      { credential_id : Authz_types.Service_credential_id.t
      ; service_id : Authz_types.Service_id.t
      ; secret_digest : Authz_credential_token.Service_credential.Digest.t
      }
  | Revoked of { credential_id : Authz_types.Service_credential_id.t }

val credential_id : t -> Authz_types.Service_credential_id.t
val equal : t -> t -> bool

(** The body of the record. The error cannot come from a value of {!t}: the
    labels, the ids, and the digest are ASCII. It is returned because
    {!Authz_body.t} can only be made through functions that check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of a Service credential record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event, in their order,
          all strings. *)
  | Invalid_credential_id of Authz_id.error
  | Invalid_service_id of Authz_id.error
  | Invalid_secret_digest  (** Not 64 lowercase hex characters. *)

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, the
    credential id is one, and then, for an issued credential, the service id
    and the digest are ones. *)
val of_body : Authz_body.t -> (t, error) result
