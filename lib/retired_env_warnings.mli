(** Runtime warnings for removed environment knobs that operators may still
    carry in shell profiles or deployment manifests. *)

val report_shell_ir_path_jail_if_set : ?source:string -> unit -> unit
(** Warn and emit telemetry once per process when the retired
    [MASC_SHELL_IR_PATH_JAIL_ENABLED] env var is still configured. *)

module For_testing : sig
  val shell_ir_path_jail_env_configured :
    ?getenv:(string -> string option) -> unit -> bool
end
