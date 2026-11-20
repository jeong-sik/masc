(** Logical identities of retained lane observations. An identity names the
    original work, not a current model route, installed Addon or permission to
    execute. Removing a builtin route must not remove its original records.
    Verifier records live in the Task/Goal registries. *)
type t =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Workspace_curator
  | Verifier
  | Candle_appraiser
  | Librarian_memory
  | Workspace_memory_curator
      (** The in-process World Memory curator's lane. [Workspace_curator] names
          the runs its Add-on predecessor recorded and is no model route. *)
[@@deriving enumerate]

val to_id : t -> string
val of_id : string -> t option
(** Unknown wire identities are refused, never mapped to a current route. *)
val equal : t -> t -> bool
val label : t -> string

val keeps_run_records : t -> bool
(** Whether any registry retains this identity's runs. [Librarian_memory]
    keeps none: the Librarian's Memory asks leave no per-ask record (RFC
    librarian-call-only-proposes: nothing grows per pass), so a screen offers
    no run history for it. [Workspace_memory_curator] keeps none either: the
    in-process curator registers no run, and what it committed is in the
    World Memory log and ledger. *)
