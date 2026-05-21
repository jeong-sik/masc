(** Runtime-status alignment helpers for operator control snapshots. *)

val runtime_status_from_live_signal : Yojson.Safe.t -> string option
val health_state_allows_runtime_status_override : Yojson.Safe.t -> bool

val align_keeper_runtime_status :
     surface_status:string
  -> diagnostic:Yojson.Safe.t
  -> agent_status_json:Yojson.Safe.t
  -> keepalive_running:bool
  -> string

val remote_client_type_of_context : 'a Operator_pending_confirm.context -> string
val max_turns_override_source : int option -> string
val operator_server_profile_json : Yojson.Safe.t
