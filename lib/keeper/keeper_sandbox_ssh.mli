(** OpenSSH endpoint resolution for the [Remote_ssh] keeper sandbox profile.
    Execution goes through {!Keeper_sandbox_remote}. *)

val resolve_endpoint_name :
  base_path:string -> name:string -> (Exec_ssh_endpoint.t, string) result
(** Resolve one explicit endpoint name against runtime.toml. *)

val configured_endpoints :
  base_path:string -> (Exec_ssh_endpoint.t list, string) result
(** Read the effective runtime endpoint registry without connecting, probing,
    creating a runner or changing readiness state. An unavailable or invalid
    registry is an error, distinct from a successfully read empty registry. *)

val resolve_endpoint :
  base_path:string ->
  keeper_name:string ->
  (Exec_ssh_endpoint.t, string) result
(** Resolve the keeper manifest's [remote_endpoint] against runtime.toml.
    Missing configuration and unknown names fail closed. *)

val openssh_configuration :
  ?ssh_bin:string ->
  base_path:string ->
  endpoint:Exec_ssh_endpoint.t ->
  unit ->
  Keeper_sandbox_remote.openssh
(** Resolve the transport's binary and credential path references
    exactly as {!create} does. This does not validate, read key
    contents, create directories, start a runner or contact an endpoint. *)

val create :
  ?ssh_bin:string ->
  base_path:string ->
  keeper_name:string ->
  endpoint:Exec_ssh_endpoint.t ->
  unit ->
  (Keeper_sandbox_remote.t, string) result
(** Validate the destination and build the endpoint value the runner and
    preflight take. Every SSH invocation authenticates a fresh connection,
    without a ControlMaster socket. Relative identity
    and known-hosts paths resolve against [base_path]. *)

val sandbox_endpoint :
  base_path:string -> Exec_ssh_endpoint.t -> Masc_exec.Sandbox_target.ssh_endpoint
(** The endpoint as the Shell IR target carries it, with the key paths
    resolved the same way {!create} resolves them. *)

module For_testing : sig
  val set_ssh_bin_override : string option -> unit
end
