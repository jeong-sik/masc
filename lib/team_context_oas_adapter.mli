(** Team_context_oas_adapter — OAS Collaboration.t bridge for team context.

    Lossy projection from MASC team session (47 fields) to
    OAS {!Agent_sdk.Collaboration.t} (12 fields).
    MASC votes/artifacts are not in the session record, so those
    fields are empty in the result.  [shared_context] is populated
    from shared findings.

    @since 2.114.0 *)

val collaboration_of_session :
  base_path:string ->
  Team_session_types.session ->
  Agent_sdk.Collaboration.t

type runtime_health = {
  base_path_exists : bool;
  room_initialized : bool;
  session_running : bool;
}

val with_runtime_health :
  Agent_sdk.Collaboration.t ->
  runtime_health ->
  Agent_sdk.Collaboration.t
