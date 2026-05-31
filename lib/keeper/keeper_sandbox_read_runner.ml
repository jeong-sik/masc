module type Backend = sig
  val should_route_read : meta:Keeper_meta_contract.keeper_meta -> bool

  val container_path_of_host :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    host_path:string ->
    (string, string) result

  val read_file :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    host_path:string ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (string, string) result

  val run_command_with_status :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    ?ok_exit_codes:int list ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    command_argv:string list ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (Unix.process_status * string, string) result

  val run_command :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    ?ok_exit_codes:int list ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    command_argv:string list ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (string, string) result
end

module type S = sig
  val host_via : string
  val backend_via : string
  val should_route_read : meta:Keeper_meta_contract.keeper_meta -> bool

  val container_path_of_host :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    host_path:string ->
    (string, string) result

  val read_file :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    host_path:string ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (string, string) result

  val run_command_with_status :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    ?ok_exit_codes:int list ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    command_argv:string list ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (Unix.process_status * string, string) result

  val run_command :
    ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
    ?ok_exit_codes:int list ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    command_argv:string list ->
    max_bytes:int ->
    timeout_sec:float ->
    unit ->
    (string, string) result
end

module Make (Backend : Backend) = struct
  let host_via = Keeper_sandbox_runner.route_label Keeper_sandbox_runner.Host
  let backend_via =
    Keeper_sandbox_runner.route_label Keeper_sandbox_runner.Sandbox_backend

  let should_route_read = Backend.should_route_read
  let container_path_of_host = Backend.container_path_of_host
  let read_file = Backend.read_file
  let run_command_with_status = Backend.run_command_with_status
  let run_command = Backend.run_command
end

module Docker_backend = struct
  let should_route_read = Keeper_sandbox_read_backend.should_route_read
  let container_path_of_host = Keeper_sandbox_read_backend.container_path_of_host
  let read_file = Keeper_sandbox_read_backend.read_file
  let run_command_with_status =
    Keeper_sandbox_read_backend.run_command_with_status
  let run_command = Keeper_sandbox_read_backend.run_command
end

include Make (Docker_backend)
