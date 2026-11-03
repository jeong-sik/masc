(** RFC-0233 §2.2 — closed identity for keeper prompt-assembly blocks.

    Each constructor names one injection site of the per-turn context
    assembly. Adding a new injection site without extending this variant
    is a compile-time error at the TurnRecord write site — that is the
    leverage that keeps the record honest.

    [Keeper_instructions] is the rendered system prompt (keeper_prompt.ml).
    [Active_goals] is the renderer-attributed Goal snapshot split from the
    per-turn world context, including current criterion and measurement.
    [Completion_authority] is the existing completion-authority renderer's
    Task approval/rejection event observations with their correlation keys.
    [Admitted_scheduled_input] is an exact turn-entry admission observation,
    including known-empty or unknown source data. It is not a permission grant.
    [Dynamic_context] is the remaining composite soft-context string built by
    keeper_turn.ml/keeper_run_prompt.ml (continuity snapshot, skill
    route, worktree, telemetry feedback, turn instructions, recent
    failure memory). This is a closed current contract:
    constructors without a producer and forward-compatible catch-alls
    are intentionally excluded.

    [Librarian_working_context] names the small working-context artifact index.
    It changes independently of the ordinary facts in [Memory_os_recall], so
    official-client resumes compare and deliver these two blocks separately.

    [Recalled_memory_status] and [Recalled_memory] are the two texts of a recall
    judgment (docs/rfc/RFC-keeper-recall-reaches-the-turn.md, section 4.4). The
    status line says what the judgment came to, names its turn and lists the
    ids it carried. The body holds those memories and exists only when the
    judgment carried some. A Keeper whose recall judgment is off has neither.

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
  | Active_goals
  | Completion_authority
  | Admitted_scheduled_input
  | Temporal_summary
  | Memory_os_recall
  | Librarian_working_context
  | Recalled_memory
  | Recalled_memory_status
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

    Measured over 386 consecutive one measured Keeper turns (2026-09-08), distinct contents
    per block: [skill_compositions] 1, [keeper_instructions] 5,
    [memory_os_recall] 65, [dynamic_context] 295, [temporal_summary] 306.
    Size runs the other way: [memory_os_recall] was 51,518 B of the 88,177 B
    assembled, sitting behind an 81 B clock line that changed nearly every
    turn. That turn reported 314,080 cache-creation tokens against 50,788
    cache reads.

    [recalled_memory] and [recalled_memory_status] have not been measured yet:
    the body is placed in front of [dynamic_context] because it changes only
    when the carried set does, and the status line behind it because it names
    its turn and so changes on every turn. The canary measures both and the
    ranks follow.

    Equal ranks keep their assembly order, so this decides only what the
    measurement decided. A new constructor must choose a rank here; the
    exhaustive match is what makes that a decision rather than an accident. *)

val injected_on_post_tool_round : t -> bool
(** Whether the per-turn context assembly re-injects this block on a
    provider round that follows tool results.

    Extra context rides the wire as a trailing User-role message, so on a
    post-tool round it reads to the model as "someone spoke again" — the
    documented DeepSeek and GLM tool loops end such a request with the tool
    result instead, and re-broadcasting the world state there made models
    re-answer it on every round (task-514, 2026-08-24). Recurring state
    blocks therefore stay on the first round only. [Active_goals] is the
    separately produced immutable Goal snapshot. [Completion_authority] carries
    this turn's approval/rejection correlation keys. Both remain in the System
    carrier after tools without rebroadcasting Task, Gate, Lane or other inbox
    state. Operator
    speech remains [Operator_note] (RFC-0366). A new constructor must declare
    its class here before it can ride a post-tool round.

    [Recalled_memory] and [Recalled_memory_status] are first-round blocks as
    well: the judgment is made once, before the turn's first request.

    [Temporal_summary] is one of those first-round blocks for the same
    reason, so the clock a Keeper reads is the one rendered for its turn's
    first provider request: a round that follows tool results carries no
    [[Temporal]] line, however long those tools ran. An official client gets
    the assembly once per dispatch, and its own tool loop runs on that one
    reading. *)

val resent_when_held : t -> bool
(** Whether a resumed official-client session is sent this block again when
    the bytes it holds from an earlier turn are the same.

    A resumed vendor session stores every prompt it was sent as conversation
    history, so a block re-sent unchanged on every resume grew the session by
    one copy per turn. Recurring state blocks answer [false]: an unchanged copy
    adds nothing the session does not already hold. [Operator_note] answers
    [true]: a note is someone speaking, and an operator repeating the same
    words is a new utterance, not a copy of the earlier one. A new constructor
    must declare its class here.

    [Completion_authority] and [Admitted_scheduled_input] also answer [true],
    preserving their producer layers' [Sent_every_resume] semantics even when
    the session saw identical bytes. Entry facts name their own exact turn;
    later empty/unknown observations do not erase historical transcript rows.

    [Recalled_memory_status] answers [true]: each turn's line names its own
    turn, so an unchanged copy is still a new line, and the session reads the
    lines over turns. [Recalled_memory] answers [false]: the session keeps the
    body it holds, and the status line says which of its memories this turn
    carries.

    [Dynamic_context] answers for the block as one text. When the renderer's
    partition of the block is known, a resume compares its World State
    sections one at a time instead, each with its own class
    ([Keeper_context_layers.resend_on_resume]). *)
