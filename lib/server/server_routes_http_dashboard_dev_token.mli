(** Dashboard dev-token file and role-aware rotation helpers. *)

type request_error =
  | Non_loopback_request_host of string
  | Token_operation_failed of token_error

and token_error =
  | Token_file_read_failed of { path : string; detail : string }
  | Credential_lookup_failed of Masc_domain.masc_error
  | Rotation_journal_read_failed of { path : string; detail : string }
  | Rotation_journal_invalid of { path : string }
  | Rotation_journal_write_failed of { path : string; detail : string }
  | Credential_revocation_failed of { agent_name : string; detail : string }
  | Credential_rotation_failed of Masc_domain.masc_error
  | Token_file_write_failed of { path : string; detail : string }
  | Rotation_finalize_failed of { path : string; detail : string }

type dashboard_dev_token =
  { raw : string
  ; actor : string
  ; role : Masc_domain.agent_role
  }

val dashboard_dev_token_path : string -> string
val dashboard_dev_token_pending_path : string -> string
val token_error_to_string : token_error -> string
val request_error_status : request_error -> Httpun.Status.t
val request_error_code : request_error -> string
val request_error_to_string : request_error -> string

val ensure_dashboard_dev_token :
  ?load:(string -> string) ->
  ?write:(string -> string -> (unit, string) result) ->
  string -> (dashboard_dev_token, token_error) result
(** Return the reusable Admin token or resume/create one role-aware rotation.
    The loopback dev-token is the local operator's own session, so the
    dashboard credential is issued as Admin; a stored token whose credential
    role differs rotates. Rotation is serialized across Eio and non-Eio
    callers and is protected against cancellation after the durable
    transaction starts. Optional I/O functions are scoped to this call so
    failure-path tests do not mutate process-global credential behavior. *)

val ensure_dashboard_dev_token_for_authority :
  request_authority:Server_request_authority.authority ->
  base_path:string ->
  (dashboard_dev_token, request_error) result
(** Enforce the endpoint's loopback-only policy on an authority already
    admitted at request entry, before token or credential I/O. *)
