(** Dashboard dev-token file and minting helpers for dashboard routes. *)

type request_error =
  | Request_host_rejected of Server_auth.request_host_rejection
  | Token_operation_failed of string

val dashboard_dev_token_path : string -> string
val request_error_status : request_error -> Httpun.Status.t
val request_error_code : request_error -> string
val request_error_to_string : request_error -> string
val ensure_dashboard_dev_token : string -> (string, string) result

val ensure_dashboard_dev_token_for_request :
  request:Httpun.Request.t ->
  base_path:string ->
  (string, request_error) result
(** Admit an exact loopback request Host before token or credential I/O. *)
