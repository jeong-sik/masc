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
    are intentionally excluded.

    [Skill_compositions] names the composition Skills carried by this turn's
    tool surface. It exists because nothing else says they are there to a model
    that does not read tool descriptions: keeper prompt blocks mentioned Skills
    only through [current_task.skills] / [held_task.skills], which render only
    when a task names one, and 0 of 292 recorded tasks ever did (RFC-0411 §1.5).
    Measured 2026-09, Skills were opened 250 times across 108,185 tool calls,
    and the busiest runtime opened none in 24,041 calls. *)

type t =
  | Keeper_instructions
  | Dynamic_context
  | Temporal_summary
  | Memory_os_recall
  | Operator_note
  | Skill_compositions

val equal : t -> t -> bool
val to_string : t -> string

val of_string : string -> (t, string) result
(** Decode the closed current wire vocabulary. Unknown names are rejected. *)

val all_known : t list
(** Every current producer-backed constructor, for exhaustive codec tests. *)

val cache_rank : t -> int
(** Where this block sits in the assembled extra system context: lower first.

    The assembly is a prefix the provider caches. A block that changes on
    almost every turn invalidates everything after it, so the order that costs
    least puts the blocks that rarely change in front of the blocks that
    always do — regardless of their size.

    Measured over 386 consecutive sangsu turns (2026-09-08), distinct contents
    per block: [skill_compositions] 1, [keeper_instructions] 5,
    [memory_os_recall] 65, [dynamic_context] 295, [temporal_summary] 306.
    Size runs the other way: [memory_os_recall] was 51,518 B of the 88,177 B
    assembled, sitting behind an 81 B clock line that changed nearly every
    turn. That turn reported 314,080 cache-creation tokens against 50,788
    cache reads.

    Equal ranks keep their assembly order, so this decides only what the
    measurement decided. A new constructor must choose a rank here; the
    exhaustive match is what makes that a decision rather than an accident. *)

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
