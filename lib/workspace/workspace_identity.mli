(** Workspace identity helpers — session id, hostname, tty, and
    agent-name resolution. *)

open Workspace_utils

val generate_session_id : unit -> string
val get_hostname : unit -> string option
val get_tty : unit -> string option
val resolve_agent_name : Workspace_utils_backend_setup.config -> string -> string
