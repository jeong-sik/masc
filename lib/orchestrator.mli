(** MASC Orchestrator - Self-sustaining agent coordination *)

(** Orchestrator configuration *)
type config = {
  check_interval_s: float;
  min_priority: int;
  agent_timeout_s: int;
  orchestrator_agent: string;
  enabled: bool;
  port: int;
}

val default_config : config

(** Load config from environment or use defaults *)
val load_config : unit -> config
val make_orchestrator_prompt : port:int -> string
val should_orchestrate : min_priority:int -> Coord.config -> bool

(** Start the orchestrator background services using Pulse.
    Returns a cancel function to gracefully stop both Pulse engines. *)
val start :
  sw:Eio.Switch.t ->
  proc_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  ?domain_mgr:_ Eio.Domain_manager.t ->
  Coord.config ->
  (unit -> unit)
