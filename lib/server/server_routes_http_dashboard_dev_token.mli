(** Dashboard dev-token file and minting helpers for dashboard routes. *)

type request_error =
  | Non_loopback_request_host of string
  | Token_operation_failed of string

val dashboard_dev_token_path : string -> string
val request_error_status : request_error -> Httpun.Status.t
val request_error_code : request_error -> string
val request_error_to_string : request_error -> string
val ensure_dashboard_dev_token : string -> (string, string) result

val ensure_dashboard_dev_token_for_authority :
  request_authority:Server_request_authority.authority ->
  base_path:string ->
  (string, request_error) result
(** Enforce the dev-token endpoint's loopback-only policy on an authority
    already admitted at request entry, before token or credential I/O. *)
