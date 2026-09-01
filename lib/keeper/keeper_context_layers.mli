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
  | Approval_authority
  | Connected_surfaces
  | Namespace_state
  | Repository_freshness
      (** Where each playground checkout stands against its upstream default
          branch — semi-stable standing context: it moves when the keeper
          commits or upstream advances, not per cycle. *)
  | Autonomous_trigger
  | Scheduled_automation
  | Completion_authority
  | Task_cancellations
  | Pending_mentions
  | Scope_messages
  | Own_board_posts
  | Board_activity
  | Own_recent_actions
  | Fleet_messages

val ordered : layer_id list
(** The canonical render order: larger, more stable sections first so providers
    can reuse a longer shared prefix across cycles (prefix-cache ordering);
    highly volatile reactive signals stay later. Every {!layer_id} appears
    exactly once — cross-checked against {!order_index} in
    [test_keeper_context_layers]. *)

val order_index : layer_id -> int
(** Position of a layer in {!ordered} (0-based). Exhaustive over {!layer_id}, so
    a new variant forces an arm here as well as in any [content_of]. *)

type retention =
  | Required
      (** The section's row budget already bounds its bytes, because every row
          renders an identity or summary of fixed width. Nothing is withheld
          for budget. *)
  | Trimmable of int
      (** The section's rows can carry content the runtime does not bound, so
          counting them bounds nothing. Under budget pressure its oldest rows
          are withheld, lowest rank first. *)

val retention : layer_id -> retention
(** Which layers give up rows when the assembled message exceeds its budget,
    and in what order. Exhaustive over {!layer_id}, so a new variant forces a
    decision here rather than defaulting into either class.

    This is a second axis, not a reordering of {!ordered}: emission order
    serves the provider prefix cache and stays fixed whatever the budget does.

    Ranks are unique — cross-checked in [test_keeper_context_layers]. *)

type section =
  | Block of string
      (** One indivisible rendering. A [Required] layer must use this. *)
  | Rows of
      { rows : string list
        (** Oldest first. Rows are withheld from the head, so this order is
            what decides which row goes first — not the order [render] shows
            them in. *)
      ; render : string list -> string
        (** Renders the section from the rows that fit. [render rows] must
            equal the untrimmed rendering byte for byte, so an assembly under
            budget is identical to one with no budget at all.

            The withheld count is not passed: a section heading already counts
            what it shows, and stating "n older rows are missing" would be new
            model-facing prose, which belongs in [config/prompts] rather than
            in OCaml (RFC prompts-and-tool-definitions-outside-ocaml). *)
      }

val section_text : section -> string
(** The untrimmed rendering: a {!Block} as it stands, a {!Rows} with every row
    kept. Equal to what {!assemble} emits for that layer when the message fits
    its budget. *)

val assemble : ?budget_bytes:int -> content_of:(layer_id -> section option) -> unit -> string
(** [assemble ~content_of ()] renders each layer in {!ordered} via [content_of]
    and concatenates the [Some] results in order; a [None] layer contributes
    nothing. The concatenation is byte-exact — each [content_of] result is
    expected to carry its own header and trailing separators.

    [?budget_bytes] bounds the assembled message. Without it, or when the full
    rendering already fits, the result is exactly the concatenation described
    above. Over budget, {!Rows} layers withhold their oldest rows — by
    {!retention} rank, lowest first — until the whole message fits.

    The bound is bytes rather than a row or turn count because row weight is
    not uniform: a refused call replays its argument object verbatim, so one
    row can outweigh a hundred. #26551 established this for the conversation
    window; the briefing kept counting rows, and a keeper whose recent turns
    carried large arguments assembled a pinned block larger than its runtime's
    whole request cap (masc#29676: 141,937 bytes against 131,072, every turn
    refused for eight hours).

    Best effort: when every {!Rows} layer is empty and the message still
    exceeds the budget, the over-budget rendering is returned rather than a
    {!Required} layer being dropped. *)
