(** Structured roots for current and historical recall artifacts. Both kinds
    share the existing dated Keeper recall retention policy, with separate
    current pins so one recall plane cannot release the other. *)
type kind = Memory_os | Librarian
val retain : config:Workspace.config -> keeper_id:string -> kind:kind ->
  now:float -> Tool_output.artifact_ref -> (unit, string) result
(** Fsync dated history before replacing the current pin. Errors prevent
    publication; cancellation propagates. Filesystem exceptions may propagate. *)
