(** OpenSSH endpoint resolution for the [Remote_ssh] keeper sandbox profile.
    Execution goes through {!Keeper_sandbox_remote}. *)

val resolve_endpoint_name :
  base_path:string -> name:string -> (Exec_ssh_endpoint.t, string) result
(** Resolve one explicit endpoint name against runtime.toml. *)

val resolve_endpoint :
  base_path:string ->
  keeper_name:string ->
  (Exec_ssh_endpoint.t, string) result
(** Resolve the keeper manifest's [remote_endpoint] against runtime.toml.
    Missing configuration and unknown names fail closed. *)

val create :
  ?ssh_bin:string ->
  base_path:string ->
  keeper_name:string ->
  endpoint:Exec_ssh_endpoint.t ->
  unit ->
  (Keeper_sandbox_remote.t, string) result
(** Validate the destination, create the 0700 ControlPath directory, and
    build the endpoint value the runner and preflight take. Relative identity
    and known-hosts paths resolve against [base_path]. *)

val sandbox_endpoint :
  base_path:string -> Exec_ssh_endpoint.t -> Masc_exec.Sandbox_target.ssh_endpoint
(** The endpoint as the Shell IR target carries it, with the key paths
    resolved the same way {!create} resolves them. *)

module For_testing : sig
  val set_ssh_bin_override : string option -> unit
end
