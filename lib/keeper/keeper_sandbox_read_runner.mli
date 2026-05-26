(** Backend-neutral runner for keeper read-side sandbox execution.

    Structured tool execute operations should depend on this facade instead of
    directly selecting the concrete Docker read backend. *)

module type Backend = sig
  val should_route_read : meta:Keeper_types.keeper_meta -> bool

  val container_path_of_host :
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    host_path:string ->
    (string, string) result

  val read_file :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    host_path:string ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (string, string) result

  val run_command_with_status :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    ?ok_exit_codes:int list ->
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    command_argv:string list ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (Unix.process_status * string, string) result

  val run_command :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    ?ok_exit_codes:int list ->
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    command_argv:string list ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (string, string) result
end

module type S = sig
  val host_via : string
  val backend_via : string
  val should_route_read : meta:Keeper_types.keeper_meta -> bool

  val container_path_of_host :
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    host_path:string ->
    (string, string) result

  val read_file :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    host_path:string ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (string, string) result

  val run_command_with_status :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    ?ok_exit_codes:int list ->
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    command_argv:string list ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (Unix.process_status * string, string) result

  val run_command :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    ?ok_exit_codes:int list ->
    config:Coord.config ->
    meta:Keeper_types.keeper_meta ->
    command_argv:string list ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (string, string) result
end

module Make : functor (Backend : Backend) -> S

include S
