(** OpenSSH transport for the [Remote_ssh] keeper sandbox profile. *)

type t

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
  (t, string) result
(** Build endpoint-local runner state and create the 0700 ControlPath
    directory. Relative identity and known-hosts paths resolve against
    [base_path]. *)

val ssh_argv : t -> string list
(** Exact pinned OpenSSH argv, including the fixed remote command
    [masc-exec-shim]. *)

val sandbox_endpoint : t -> Masc_exec.Sandbox_target.ssh_endpoint

val runner :
  timeout_sec:float ->
  t ->
  Masc_exec.Sandbox_target.runner
(** Construct a Shell IR runner. The local wall-clock budget includes the
    endpoint connect timeout and a bounded drain grace in addition to the
    remote payload timeout. *)

module For_testing : sig
  val set_ssh_bin_override : string option -> unit
end
