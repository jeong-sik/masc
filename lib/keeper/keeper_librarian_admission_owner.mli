(** Production explicit-candidate Librarian owner on the existing Memory lane.
    The Addon executes only the original raw model proposal; host authority
    retains input, absorption, locked disposition and receipt-backed ACK. *)
type outcome =
  | Disabled | Idle | Recheck_new_input | Settled of { has_more : bool }
  | Pending of string | Unavailable of string
val run : base_path:string -> keeper_name:string -> outcome
(** Strictly discover the complete original forest/executions/gates before new
    work. Resume original IDs without resubmitting unknown work. Fresh Memory
    is captured separately at each runnable part's actual turn. Semantic
    Deferred and positively size-refused singletons retain their gaps and let
    untouched siblings run; ordinary failures stop this pass. Only typed whole
    host execution evidence permits disjoint two-child partition. Addon Off
    prevents new calls while completed original proof/commit/ACK can recover.
    Pending returns promptly; existing server owner events wake the same lane.
    [Settled] requires an actual receipt-backed commit, and [has_more] names
    only input appended beyond the original frontier. *)
