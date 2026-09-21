(** A saved working state and its exact conversation coverage, per runtime Keeper.
    Memory progress and queued-input pockets do not authorize this frontier. *)
type prepared
val path : config:Workspace.config -> keeper_name:string -> string
val read : config:Workspace.config -> keeper_name:string ->
  (Librarian_continuity_snapshot.t option, string) result
val prepare : ?end_atom:int -> config:Workspace.config -> keeper_name:string -> trace_id:string -> unit ->
  (prepared option, string) result
(** Read boundaries before the locked checkpoint. Supply previous valid state
    plus the suffix through the next real completed turn. Capacity is a ceiling,
    not a reason to include later turns. An explicit [end_atom] selects a prefix;
    an unpublished exact Memory receipt takes precedence over either choice.
    Pending in-flight atoms are excluded. [None] means no new complete coverage. *)
val prompt_json : prepared -> Yojson.Safe.t
val commit : config:Workspace.config -> keeper_name:string -> prepared:prepared ->
  working_state:string -> (Librarian_continuity_snapshot.t, string) result
(** Publication requires an exact continuity-owned Memory receipt, or coverage
    within the serial ordinary consumer's genuinely read interval, and uses
    snapshot CAS. It never changes the durable consumer cursor. *)

val messages : prepared -> Agent_core.Types.message list
(** Exact new source atoms, including tool results, supplied to both Memory
    disposition and working-state inference. *)
val turn_ref : prepared -> Ids.Turn_ref.t
val end_atom : prepared -> int
val fit : fits:(prepared -> (bool, string) result) -> prepared ->
  (prepared option, string) result
(** Keep the selected work unit unchanged when it fits. Only an oversized unit
    is split at whole-atom midpoints, stopping at the first fitting part without
    growing it back toward the limit. Source bytes and prior state stay intact;
    an exact Memory recovery range cannot be split. *)
val narrow : prepared -> prepared option
(** Retry a refused source at the midpoint between whole atoms. Call only after
    a typed capacity refusal; [None] means one indivisible atom remains, or the exact range already has
    a Memory receipt that must be recovered without reapplying a smaller range. *)
val memory_range_id : config:Workspace.config -> keeper_name:string -> prepared ->
  (Keeper_memory_os_current.durable_range_id, string) result
(** Uses the continuity path as receipt scope. Never advances the ordinary
    completed-turn consumer's cursor or overwrites its proof. *)
val memory_committed : config:Workspace.config -> keeper_name:string -> prepared ->
  (bool, string) result
