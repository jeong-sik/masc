(* HIGH-RISK-UNREVIEWED: this module issues Service credentials and decides what
   a Service credential token acts as. A token it lets through acts as its
   service. *)

(** Service credentials against the writer zone (design 5.3 and 6.3, plan
    C4-6).

    The host CLI (plan C4-9) calls {!issue} and {!revoke} as the local
    operator: {!issue} writes the record of a new credential and hands back its
    token, the only time the secret leaves the host. {!authenticate} reads a
    token against one snapshot; the request gate of C4-8 calls it. A Service
    credential is [Not_pat]: grants and DelegatePolicy bound it (design 5.3). *)

type error =
  | Id_not_drawn of Authz_id.error
      (** [draw] gave a value that is not a credential id. *)
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

val error_to_string : error -> string

(** How many ids {!issue} draws before it gives up: an id that the snapshot
    already names is drawn again. *)
val attempts : int

(** Issues a credential for [service_id]. [draw ()] gives the credential id. *)
val issue
  :  Authz_zone.t
  -> service_id:Authz_types.Service_id.t
  -> draw:(unit -> string)
  -> (Authz_credential_token.Service_credential.t, error) result

(** What a credential acts as. *)
type signed_in =
  { service_id : Authz_types.Service_id.t
  ; credential_id : Authz_types.Service_credential_id.t
  }

(** Why a token does not act. *)
type refusal =
  | Unknown  (** No credential has the id of the token. *)
  | Ended  (** The credential was revoked. *)
  | Secret_differs
      (** The credential is there, and the secret of the token is not its own. *)
  | Revocation_pending
      (** A revocation of the credential was given up before it reached the
          log (design 8.3). *)

val refusal_to_string : refusal -> string

(** What a token acts as, in the state of one snapshot that the zone could be
    trusted for ({!Authz_zone.read}). *)
val authenticate
  :  Authz_zone.trusted
  -> Authz_credential_token.Service_credential.t
  -> (signed_in, refusal) result

(** Ends a credential. *)
val revoke : Authz_zone.t -> Authz_types.Service_credential_id.t -> (unit, error) result
