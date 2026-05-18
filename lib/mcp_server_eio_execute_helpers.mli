(** Shared helpers for {!Mcp_server_eio_execute}. *)

val log_mcp_exn : label:string -> exn -> unit

val wait_for_message_eio :
  clock:_ Eio.Time.clock ->
  Session.registry ->
  agent_name:string ->
  timeout:float ->
  Yojson.Safe.t option

val agent_runtime_root : string

val resolve_join_state :
  room_initialized:bool ->
  join_required:bool ->
  agent_name:string ->
  base_path:string ->
  check_join:(string -> bool) ->
  bool

val silent_auth_token_error_kind : Masc_domain.masc_error -> string

val should_read_legacy_persisted_agent_name :
  has_explicit_agent_name:bool ->
  agent_name:string ->
  bool

val caller_agent_name_from_arguments : Yojson.Safe.t -> string option

val read_mcp_session_agent :
  mcp_session_id:string option ->
  unit ->
  string option

val write_mcp_session_agent :
  mcp_session_id:string option ->
  agent_name:string ->
  unit

val read_term_session_agent :
  mcp_session_id:string option ->
  unit ->
  string option

val persisted_agent_name :
  mcp_session_id:string option ->
  has_explicit_agent_name:bool ->
  agent_name:string ->
  unit ->
  string option

val direct_call_block_message : string -> string

val cleanup_internal_keeper_runtime_resource :
  during_exception:bool -> label:string -> (unit -> unit) -> unit

val run_with_cleanup_preserving_primary :
  cleanup:(during_exception:bool -> unit -> unit) -> (unit -> 'a) -> 'a
