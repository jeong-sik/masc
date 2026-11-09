val json :
  ?actor:string ->
  ?force:bool ->
  config:Workspace.config ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  unit ->
  Yojson.Safe.t

module For_test : sig
  val briefing_summary_of_briefing : Yojson.Safe.t -> (Yojson.Safe.t, string) result
  val compact_agent_json : Masc_domain.agent -> Yojson.Safe.t
  val reset_cache : unit -> unit
  val seed_cache :
    ?cached_at:float ->
    ?last_error:string ->
    ?refresh_in_flight:bool ->
    Yojson.Safe.t ->
    unit
  val collect_metadata_gaps :
    agents:Yojson.Safe.t list ->
    Yojson.Safe.t list
  val build_briefing_sections :
    briefing_summary_json:Yojson.Safe.t ->
    agents:Yojson.Safe.t list ->
    recent_messages:Yojson.Safe.t list ->
    metadata_gaps:Yojson.Safe.t list ->
    string * Yojson.Safe.t list
end


