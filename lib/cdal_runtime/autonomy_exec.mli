(** Autonomy_exec — external execution primitive for autonomy loops.

    This module intentionally stays below any AutoResearch-specific policy.
    It provides argv-only process execution with timeout, bounded capture,
    env allowlisting, and optional wrapper prefixes for container/sandbox
    launchers such as Docker or Bubblewrap.

    @since 0.92.1

    @stability Evolving
    @since 0.93.1 *)

type backend =
  | Direct
  | Argv_prefix of string list

type kill_scope =
  | Single_process
  | Process_group
  (** Requires a wrapper that creates a dedicated process group
          (for example: [setsid], [docker run], [bwrap]). *)

type config =
  { backend : backend
  ; cwd : string option
  ; env_allowlist : string list
  ; extra_env : (string * string) list
  ; stdout_limit_bytes : int
  ; stderr_limit_bytes : int
  ; kill_scope : kill_scope
  }

val default_env_allowlist : string list
val default_config : config

type exit_status =
  | Exit_code of int
  | Exit_signal of int
  | Timed_out of int option

type output =
  { effective_argv : string list
  ; status : exit_status
  ; stdout : string
  ; stderr : string
  ; stdout_truncated : bool
  ; stderr_truncated : bool
  ; elapsed_s : float
  }

(** Shell-quoted rendering for logs and diagnostics. *)
val argv_to_string : string list -> string

(** Compose backend prefix and cwd wrapper into the final argv list. *)
val effective_argv
  :  config:config
  -> argv:string list
  -> (string list, Error.sdk_error) result

(** Build the child environment from inherited allowlisted vars and overrides. *)
val build_env : config:config -> string array

val status_to_string : exit_status -> string

val run
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> config:config
  -> argv:string list
  -> timeout_s:float
  -> (output, Error.sdk_error) result
