(** RFC-0233 §2.2 — closed identity for keeper prompt-assembly blocks.

    Each constructor names one injection site of the per-turn context
    assembly. Adding a new injection site without extending this variant
    is a compile-time error at the TurnRecord write site — that is the
    leverage that keeps the record honest.

    [Keeper_instructions] is the rendered system prompt (keeper_prompt.ml).
    [Dynamic_context] is the composite soft-context string built by
    keeper_turn.ml/keeper_run_prompt.ml (continuity snapshot, skill
    route, worktree, telemetry feedback, turn instructions, recent
    failure memory) — recorded as one block until a real producer
    introduces a typed decomposition. This is a closed current contract:
    constructors without a producer and forward-compatible catch-alls
    are intentionally excluded. *)

type t =
  | Keeper_instructions
  | Dynamic_context
  | Temporal_summary
  | Memory_os_recall
  | Operator_note

val equal : t -> t -> bool
val to_string : t -> string

val of_string : string -> (t, string) result
(** Decode the closed current wire vocabulary. Unknown names are rejected. *)

val all_known : t list
(** Every current producer-backed constructor, for exhaustive codec tests. *)

val injected_on_post_tool_round : t -> bool
(** Whether the per-turn context assembly re-injects this block on a
    provider round that follows tool results.

    The assembly rides the wire as a trailing User-role message, so on a
    post-tool round it reads to the model as "someone spoke again" — the
    documented DeepSeek and GLM tool loops end such a request with the tool
    result instead, and re-broadcasting the world state there made models
    re-answer it on every round (task-514, 2026-08-24). Recurring state
    blocks therefore stay on the first round only; a block answers [true]
    only when its appearance genuinely is someone speaking mid-turn
    ([Operator_note], RFC-0366). A new constructor must declare its class
    here before it can ride a post-tool round. *)
