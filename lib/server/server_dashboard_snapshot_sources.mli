(** Source-driven owners of the immutable Shell, Tools and telemetry components. *)

val install :
  state:Mcp_server.server_state -> sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  on_shell_published:(scope:Mcp_server.workspace_scope ->
    shell:Yojson.Safe.t -> shell_light:Yojson.Safe.t -> unit) -> unit
(** Subscribe before the initial reads. Each component has independent bounded
    read debt and failure retry; only telemetry's real freshness transitions
    create healthy deadlines. The captured epoch owns every subscription,
    worker and publisher. Raw commit owners are resolved outside the writer.
    Completion is announced after the immutable value is installed and never
    reclassified as source input. [on_shell_published] installs both successful
    Shell projections into the canonical namespace owner's cache. *)

module For_testing : sig
  type readers = {
    shell : light:bool -> Workspace.config -> Yojson.Safe.t;
    tools : Workspace.config -> Dashboard_snapshot.tools_result;
    telemetry : now:float -> Workspace.config -> Telemetry_unified.summary_observation;
  }
  val with_readers : readers -> (unit -> 'a) -> 'a
end
