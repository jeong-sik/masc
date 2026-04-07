(** Team_context_oas_adapter — collaboration context bridge for team sessions.

    Lossy projection from MASC team session (47 fields) to
    opaque collaboration JSON for OAS swarm_config.collaboration_context.

    @since 2.114.0 *)

val collaboration_of_session :
  base_path:string ->
  Team_session_types.session ->
  Yojson.Safe.t

type runtime_health = {
  base_path_exists : bool;
  room_initialized : bool;
  session_running : bool;
}

val with_runtime_health :
  Yojson.Safe.t ->
  runtime_health ->
  Yojson.Safe.t
