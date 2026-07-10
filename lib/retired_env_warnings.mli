(** Runtime warnings for removed environment knobs that operators may still
    carry in shell profiles or deployment manifests. *)

val report_shell_ir_path_jail_if_set : ?source:string -> unit -> unit
(** Warn and emit telemetry once per process when the retired
    [MASC_SHELL_IR_PATH_JAIL_ENABLED] env var is still configured. *)

val report_memory_os_librarian_global_slot_if_set : ?source:string -> unit -> unit
(** Warn and emit telemetry once per process when the retired
    [MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT] env var is still configured. *)

module For_testing : sig
  val shell_ir_path_jail_env_key : string
  val memory_os_librarian_global_slot_env_key : string

  val shell_ir_path_jail_env_configured :
    ?getenv:(string -> string option) -> unit -> bool

  val memory_os_librarian_global_slot_env_configured :
    ?getenv:(string -> string option) -> unit -> bool
end
