(** Dashboard dev-token file and minting helpers for dashboard routes. *)

type request_error =
  | Non_loopback_request_host of string
  | Token_operation_failed of string

type dashboard_dev_token_state =
  | Reused_worker_credential
  | Reused_legacy_admin_credential
  | Minted_worker_credential

type ensured_dashboard_dev_token = {
  token : string;
  state : dashboard_dev_token_state;
}

val dashboard_dev_token_path : string -> string
val request_error_status : request_error -> Httpun.Status.t
val request_error_code : request_error -> string
val request_error_to_string : request_error -> string
val ensure_dashboard_dev_token : string -> (string, string) result

val ensure_dashboard_dev_token_with_state :
  string -> (ensured_dashboard_dev_token, string) result
(** Return the bearer together with its typed migration state.  A legacy
    persisted Admin credential is reused without rewriting either the raw
    token file or credential file; {!Auth.credential_authority} caps its
    effective authority to Worker. *)

val set_dashboard_dev_token_load_for_testing : (string -> string) -> unit
(** Replace the dev-token file reader for focused failure-path tests. *)

val reset_dashboard_dev_token_load_for_testing : unit -> unit
(** Restore the production dev-token file reader. *)

val ensure_dashboard_dev_token_for_authority :
  request_authority:Server_request_authority.authority ->
  base_path:string ->
  (string, request_error) result
(** Enforce the dev-token endpoint's loopback-only policy on an authority
    already admitted at request entry, before token or credential I/O. *)
