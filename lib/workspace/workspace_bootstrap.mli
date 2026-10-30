(** The state a workspace starts with, and the boot repair of its message
    counter. [Workspace.init] uses both. *)


val default_workspace_state : Workspace_utils_backend_setup.config -> Masc_domain.workspace_state
val empty_backlog : unit -> Masc_domain.backlog
val reconcile_message_seq : Workspace_utils_backend_setup.config -> string -> unit
(** [reconcile_message_seq config state_path] raises the [message_seq]
    recorded at [state_path] to the highest filed message when it is behind,
    and leaves it alone otherwise. It reads the store first, then holds the
    lock [next_seq] takes on [state_path] from reading the counter to
    writing it. *)
