(** RFC-0233 §2.2 — closed identity for keeper prompt-assembly blocks.

    Each constructor names one injection site of the per-turn context
    assembly. Adding a new injection site without extending this variant
    is a compile-time error at the TurnRecord write site — that is the
    leverage that keeps the record honest.

    [Persona] is the rendered system prompt (keeper_prompt.ml).
    [Dynamic_context] is the composite soft-context string built by
    keeper_turn.ml/keeper_run_prompt.ml (continuity snapshot, skill
    route, worktree, telemetry feedback, turn instructions, recent
    failure memory) — recorded as one block until a real producer
    introduces a typed decomposition. This is a closed current contract:
    constructors without a producer and forward-compatible catch-alls
    are intentionally excluded. *)

type t =
  | Persona
  | Dynamic_context
  | Temporal_summary
  | Memory_os_recall

val equal : t -> t -> bool
val to_string : t -> string

val of_string : string -> (t, string) result
(** Decode the closed current wire vocabulary. Unknown names are rejected. *)

val all_known : t list
(** Every current producer-backed constructor, for exhaustive codec tests. *)
