(** Closed identity for keeper prompt-assembly blocks that have a current
    producer.

    Each constructor names one injection site of the per-turn context
    assembly. Adding a new injection site without extending this variant
    is a compile-time error at the TurnRecord write site — that is the
    leverage that keeps the record honest.

    [Persona] is the rendered system prompt (keeper_prompt.ml).
    [Dynamic_context] is the composite soft-context string built by
    keeper_turn.ml/keeper_run_prompt.ml (continuity snapshot, skill
    route, worktree, telemetry feedback, turn instructions, recent
    failure memory). *)

type t =
  | Persona
  | Dynamic_context
  | Temporal_summary
  | Memory_os_recall

val equal : t -> t -> bool
val to_string : t -> string

val of_string : string -> (t, string) result
(** Decode the current wire contract. Unknown names fail closed. *)

val all : t list
(** Every current constructor. *)
