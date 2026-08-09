(** Path SSOT for the Agent Core.

    Centralises the remaining cwd probe so library code does not call
    [Sys.getcwd] directly. Runtime/session/catalog roots must be supplied
    explicitly or through their documented [AGENT_CORE_*] variables. *)

(** Current working directory at the time of the call.

    Raises [Sys_error] only if the cwd cannot be determined at all; callers
    that need a graceful fallback should catch and substitute ["."]. *)
val cwd : unit -> string
