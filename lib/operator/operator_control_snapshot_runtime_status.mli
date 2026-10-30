(** Context helpers for operator control snapshots. *)

val remote_confirm_ttl_seconds : float

val remote_client_type_of_context : 'a Operator_pending_confirm.context -> string
val operator_server_profile_json : Yojson.Safe.t
