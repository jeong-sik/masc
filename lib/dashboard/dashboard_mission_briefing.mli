val json :
  ?actor:string ->
  ?force:bool ->
  config:Coord.config ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  unit ->
  Yojson.Safe.t

module For_test : sig
  val compact_session_json : Yojson.Safe.t -> Yojson.Safe.t
  val compact_keeper_json : Yojson.Safe.t -> Yojson.Safe.t
  val compact_agent_json : Masc_domain.agent -> Yojson.Safe.t
  val reset_cache : unit -> unit
  val seed_cache :
    ?cached_at:float ->
    ?last_error:string ->
    ?refresh_in_flight:bool ->
    Yojson.Safe.t ->
    unit
  val relevant_sessions_for_briefing :
    current_namespace:string -> now_ts:float -> Yojson.Safe.t list -> Yojson.Safe.t list
  val collect_metadata_gaps :
    sessions:Yojson.Safe.t list ->
    keepers:Yojson.Safe.t list ->
    agents:Yojson.Safe.t list ->
    Yojson.Safe.t list
  val build_briefing_sections :
    mission_summary_json:Yojson.Safe.t ->
    sessions:Yojson.Safe.t list ->
    agents:Yojson.Safe.t list ->
    recent_messages:Yojson.Safe.t list ->
    metadata_gaps:Yojson.Safe.t list ->
    string * Yojson.Safe.t list
end
