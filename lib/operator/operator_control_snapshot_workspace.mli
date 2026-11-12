(** Operator dashboard workspace descriptor extracted from [Operator_control_snapshot]. *)

val workspace_observation : Workspace.config -> Dashboard_projection_read.observation
(** The workspace summary and its same-read backlog completeness. Readable
    recovery rows remain visible but retain the primary authority failure.
    Workspace counts have no elapsed-time deadline. *)
