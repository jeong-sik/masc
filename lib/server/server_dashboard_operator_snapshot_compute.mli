val observe_current :
  state:Mcp_server.server_state -> scope:Mcp_server.workspace_scope ->
  sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t ->
  query:Yojson.Safe.t -> ?actor:string -> ?view:string ->
  include_messages:bool -> include_keepers:bool -> include_summary_fields:bool ->
  lightweight_summary:bool -> unit -> Dashboard_projection_read.observation
(** One actual Current Snapshot read in the captured scope. The original
    rows, typed completeness and semantic deadline travel together through
    the single registered Snapshot reader. Parameterized request flags retain
    their own actor/query ownership. No lane action or provider call is used. *)
