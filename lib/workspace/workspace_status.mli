(** Workspace status snapshot — render the workspace/agent state as a
    human-readable string for the [masc_status] tool. *)


val status : Workspace_utils_backend_setup.config -> string
