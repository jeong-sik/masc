(** Workspace identity helpers — session id, hostname, tty, and
    agent-name resolution. *)


val generate_session_id : unit -> string
(** Generate a 128-bit cryptographically random lowercase hex session ID.
    Existing shorter persisted session IDs remain readable as opaque text. *)
val get_hostname : unit -> string option
val get_tty : unit -> string option
val resolve_agent_name : Workspace_utils_backend_setup.config -> string -> string
