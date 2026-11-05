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
[@@deriving enumerate]

val to_id : t -> string
val of_id : string -> t option
(** Unknown wire identities are refused, never mapped to a current route. *)
val equal : t -> t -> bool
val label : t -> string
