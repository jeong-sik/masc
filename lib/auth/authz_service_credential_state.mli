(* HIGH-RISK-UNREVIEWED: this is what the Service credential records of the
   authorization log add up to. A credential that this module holds open lets
   the holder of its token act as its service. *)

(** The Service credentials that the [internal_service_credential] records of
    [authz.jsonl] add up to (design 5.3 and 6.3, plan C4-4). {!Authz_state}
    keeps one of these as its field and hands it every such record of a
    bootstrapped log.

    {b Who may write.} The local operator issues and revokes every credential:
    the host CLI does it for the services the host starts (user decision
    2026-11-07). A principal and the system authors write none.

    {b One id.} A credential id names one credential for good: a revoked
    credential keeps its id.

    {b Service.} The first credential issued for a service makes its principal
    [Service service_id]: no other record does. A service may hold several
    credentials over time. A credential has no expiry; a revoke ends it. *)

type status =
  | Open
  | Revoked

type credential = private
  { service_id : Authz_types.Service_id.t
  ; secret_digest : Authz_credential_token.Service_credential.Digest.t
  ; issued_at_ms : int  (** The time of the record that issued it. *)
  ; status : status
  }

type t

val empty : t
val find : t -> Authz_types.Service_credential_id.t -> credential option

(** Why a credential does not act. *)
type inactive =
  | Unknown  (** No credential has this id. *)
  | Ended  (** It was revoked. *)

val find_active
  :  t
  -> Authz_types.Service_credential_id.t
  -> (credential, inactive) result

type refusal =
  | Already_issued of Authz_types.Service_credential_id.t
      (** The id names a credential, open or not. *)
  | Not_issued of Authz_types.Service_credential_id.t
  | Already_revoked of Authz_types.Service_credential_id.t
  | Not_a_credential_author of Authz_records.Author.t
      (** A principal or a system author, which {!Authz_record.admits} does not
          let write a Service credential record. *)

val refusal_to_string : refusal -> string

(** What one Service credential record does to the credentials. [at_ms] is
    the time of the record. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> at_ms:int
  -> Authz_service_credential_event.t
  -> (t, refusal) result
