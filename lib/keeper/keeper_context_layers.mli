(** Keeper_context_layers — the keeper world-state user message as an ordered
    set of typed context layers.

    Each layer owns exactly one observation signal and renders to [Some text]
    when its signal is present this turn, [None] when it carries nothing. The
    render order is a single declared SSOT ({!ordered}) rather than the implicit
    order of imperative buffer writes, so reordering or adding a section is a
    typed, reviewable change instead of an edit buried in a long procedure.

    The build is a pure fold: {!assemble} concatenates, in {!ordered} order, the
    [Some] renderings produced by a caller-supplied [content_of]. [content_of]
    is written as an exhaustive match on {!layer_id} at the call site, so adding
    a layer fails to compile until the producing site renders it. *)

type layer_id =
  | Active_goals
  | Current_task
  | Working_state
  | Connected_surfaces
  | Namespace_state
  | Context_health
  | Autonomous_trigger
  | Scheduled_automation
  | Continuity
  | Pending_mentions
  | Scope_messages
  | Claimable_work
  | Board_activity

val ordered : layer_id list
(** The canonical render order: larger, more stable sections first so providers
    can reuse a longer shared prefix across cycles (prefix-cache ordering);
    highly volatile reactive signals stay later. Every {!layer_id} appears
    exactly once — cross-checked against {!order_index} in
    [test_keeper_context_layers]. *)

val order_index : layer_id -> int
(** Position of a layer in {!ordered} (0-based). Exhaustive over {!layer_id}, so
    a new variant forces an arm here as well as in any [content_of]. *)

val assemble : content_of:(layer_id -> string option) -> string
(** [assemble ~content_of] renders each layer in {!ordered} via [content_of] and
    concatenates the [Some] results in order; a [None] layer contributes
    nothing. The concatenation is byte-exact — each [content_of] result is
    expected to carry its own header and trailing separators. *)
