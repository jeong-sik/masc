(** Dashboard dev-token file and role-aware rotation helpers. *)

type error =
  | Request_host_rejected of Server_auth.request_host_rejection
  | Token_file_read_failed of { path : string; detail : string }
  | Credential_lookup_failed of Masc_domain.masc_error
  | Rotation_journal_read_failed of { path : string; detail : string }
  | Rotation_journal_invalid of { path : string }
  | Rotation_journal_write_failed of { path : string; detail : string }
  | Credential_revocation_failed of { agent_name : string; detail : string }
  | Credential_rotation_failed of Masc_domain.masc_error
  | Token_file_write_failed of { path : string; detail : string }
  | Rotation_finalize_failed of { path : string; detail : string }

val dashboard_dev_token_path : string -> string
val dashboard_dev_token_rotation_path : string -> string

val error_code : error -> string
val error_to_string : error -> string

val ensure_dashboard_dev_token :
  mutex:Eio.Mutex.t -> string -> (string, error) result
(** Return the reusable Worker token or resume/create one role-aware rotation.
    The caller-provided mutex scopes serialization to one server route set;
    the function performs I/O inside an Eio fiber. *)

val ensure_dashboard_dev_token_for_request :
  mutex:Eio.Mutex.t ->
  request:Httpun.Request.t ->
  base_path:string ->
  (string, error) result
(** Admit the request Host before any token or credential I/O, then delegate to
    {!ensure_dashboard_dev_token}. *)
