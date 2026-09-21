(** A saved working state and its exact conversation coverage, per runtime Keeper.
    Memory progress and queued-input pockets do not authorize this frontier. *)
type prepared
val path : config:Workspace.config -> keeper_name:string -> string
val read : config:Workspace.config -> keeper_name:string ->
  (Librarian_continuity_snapshot.t option, string) result
val prepare : ?end_atom:int -> config:Workspace.config -> keeper_name:string -> trace_id:string -> unit ->
  (prepared option, string) result
(** Read boundaries before the locked checkpoint. Supply previous valid state
    plus the new suffix, or an explicitly captured checkpoint prefix. Pending
    in-flight atoms are excluded. [None] means no new complete coverage. *)
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
(** Select the largest nonempty whole-atom prefix accepted by [fits], checking
    the original range first. The predicate must be monotone in the endpoint
    for this frozen input and account for the complete rendered request.
    Source bytes, prior state, and the Memory recovery range remain unchanged.
    An exact recovery range is either accepted whole or returns [None]. *)
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
