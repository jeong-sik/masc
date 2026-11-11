(* HIGH-RISK-UNREVIEWED: this module issues and revokes Service credentials as
   the host-local operator. A token it hands back acts as its service. *)

(** The host side of Service credentials (plan C4-9): [masc auth
    service-credential issue], [revoke] and [list] on an installation a boot
    finds active for multi-account use. Each call opens the writer zone of the
    base path, so the caller holds the lease of the base path, as [masc auth
    invite] does. *)

type error =
  | Not_active of Authz_activation.invite_error
      (** No installation here is active for multi-account use. *)
  | Zone_not_opened of Authz_zone.open_error
  | Service_id_invalid of Authz_id.error
  | Credential_id_invalid of Authz_id.error
  | Not_issued of Authz_service_credential.error
  | Not_revoked of Authz_service_credential.error
      (** The log has no credential of this id, or it is revoked already. *)

val error_to_string : error -> string

(** Issues a credential for the service named [service]. The token holds the
    secret: this is the only time the secret leaves the host. *)
val issue
  :  base_path:string
  -> config_dir:string option
  -> anonymous_mutations:bool
  -> now_ms:(unit -> int)
  -> service:string
  -> (Authz_credential_token.Service_credential.t, error) result

(** Ends the credential with the id [credential]. *)
val revoke
  :  base_path:string
  -> config_dir:string option
  -> anonymous_mutations:bool
  -> now_ms:(unit -> int)
  -> credential:string
  -> (unit, error) result

(** A credential as the list shows it, with no secret and no digest. *)
type listed =
  { credential_id : Authz_types.Service_credential_id.t
  ; service_id : Authz_types.Service_id.t
  ; issued_at_ms : int
  ; status : Authz_service_credential_state.status
  }

(** Every credential of the log, in the order of the ids. *)
val list
  :  base_path:string
  -> config_dir:string option
  -> anonymous_mutations:bool
  -> now_ms:(unit -> int)
  -> (listed list, error) result
