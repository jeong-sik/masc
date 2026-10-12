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
(** Capture the persisted publication generation before authoritative recall
    reads. Current pins are strict generation/artifact envelopes or JSON null.
    Unversioned or malformed roots return errors and are not converted; their
    errors cannot authorize retirement. *)
val retire_current : config:Workspace.config -> keeper_id:string -> kind:kind ->
  pin_observation -> (unit, string) result
(** Atomically replace only the exact observed publication generation with
    an empty JSON root, serialized with [retain]. Every publication receives
    a fresh UUIDv7, so newer publications of the same artifact hash are
    preserved independently of inode reuse or timestamp precision. Absent or
    already-retired observations perform no mutation. Dated history and blob
    bytes are untouched. Cancellation and filesystem exceptions may propagate. *)
