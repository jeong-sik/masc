(** Structured roots for current and historical recall artifacts. Both kinds
    share the existing dated Keeper recall retention policy, with separate
    current pins so one recall plane cannot release the other. *)
type kind = Memory_os | Librarian
val retain : config:Workspace.config -> keeper_id:string -> kind:kind ->
  now:float -> Tool_output.artifact_ref -> (unit, string) result
(** Fsync dated history before replacing the current pin. Errors prevent
    publication; cancellation propagates. Filesystem exceptions may propagate. *)

type pin_observation
val observe_current : config:Workspace.config -> keeper_id:string -> kind:kind ->
  (pin_observation, string) result
(** Capture an owned regular-file observation before authoritative recall reads.
    Read errors cannot authorize retirement. *)
val retire_current : config:Workspace.config -> keeper_id:string -> kind:kind ->
  pin_observation -> (unit, string) result
(** Atomically replace only the exact observed current pin with an empty JSON
    root, serialized with [retain]. A newer publication, including the same
    artifact hash, is preserved. Dated history and blob bytes are untouched.
    Cancellation and filesystem exceptions may propagate. *)
