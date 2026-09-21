(** A saved working state and its exact conversation coverage, per runtime Keeper.
    Memory progress and queued-input pockets do not authorize this frontier. *)
type prepared
val path : config:Workspace.config -> keeper_name:string -> string
val read : config:Workspace.config -> keeper_name:string ->
  (Librarian_continuity_snapshot.t option, string) result
val prepare : config:Workspace.config -> keeper_name:string -> trace_id:string ->
  (prepared option, string) result
(** Read boundaries before the locked checkpoint. Supply previous valid state
    plus the complete new suffix, or the witnessed complete prefix. Pending
    in-flight atoms are excluded. [None] means no new complete coverage. *)
val prepare_committed : config:Workspace.config -> keeper_name:string -> trace_id:string ->
  (prepared option, string) result
(** Context-only bootstrap requires a Memory WAL receipt for the same exact
    completed frontier. A read cursor alone is not commit evidence. *)
val prompt_json : prepared -> Yojson.Safe.t
val commit : config:Workspace.config -> keeper_name:string -> prepared:prepared ->
  working_state:string -> (Librarian_continuity_snapshot.t, string) result
(** Generation and exact prefix bytes are captured before inference. A stale
    writer cannot overwrite another committed pair. Publication requires a
    verified Memory WAL receipt for the exact same trace, history generation,
    endpoint row, atom, and digest. No read cursor changes. *)
