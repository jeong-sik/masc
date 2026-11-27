(** Source-driven owners of the immutable Shell, Tools, telemetry and 24h cost components. *)

val install :
  state:Mcp_server.server_state -> sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  on_shell_published:(scope:Mcp_server.workspace_scope ->
    shell:Yojson.Safe.t -> shell_light:Yojson.Safe.t -> unit) -> unit
(** Subscribe before the initial reads. Each component has independent bounded
    read debt and failure retry; telemetry tracks its freshness transitions and
    the 24h cost warmer keeps the shared 1440-minute model-metrics cursor warm
    outside the Shell timeout budget. The captured epoch owns every subscription,
    worker and publisher. Raw commit, Goal and trajectory owners are resolved
    outside their writers; trajectory roots retain their original trace owner.
    Completion is announced after the immutable value is installed and never
    reclassified as source input. [on_shell_published] installs both successful
    Shell projections into the canonical namespace owner's cache. *)

module For_testing : sig
  type readers = {
    shell : light:bool -> Workspace.config -> Yojson.Safe.t;
    tools : Workspace.config -> Dashboard_snapshot.tools_result;
    telemetry : now:float -> Workspace.config -> Telemetry_unified.summary_observation;
    cost_24h : now:float -> Workspace.config -> Server_model_metrics_stream.cost_24h_observation;
  }
  val with_readers : readers -> (unit -> 'a) -> 'a
end
