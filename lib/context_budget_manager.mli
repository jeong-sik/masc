(** Context Budget Manager — session-level context window budget tracking.

    Tracks accumulated token usage across tool schemas and conversation turns,
    and determines compression phase based on usage ratio against a maximum budget.

    Phase thresholds:
    - 0-50%:  None_phase      — full descriptions, no compression
    - 50-70%: Compact_tools   — one-line tool descriptions
    - 70-85%: Drop_low        — drop low-importance messages
    - 85%+:   Summarize       — summarize old turns

    Default max budget from [MASC_CONTEXT_BUDGET_MAX] env var (fallback: 100000).

    @since 2.128.0 *)

type compression_phase =
  | None_phase
  | Compact_tools
  | Drop_low
  | Summarize

val show_compression_phase : compression_phase -> string
(** Human-readable phase name. *)

type t
(** Abstract budget state. *)

val create : ?max_budget:int -> unit -> t
(** Create a budget tracker.
    [max_budget] defaults to [MASC_CONTEXT_BUDGET_MAX] env var, or 100000. *)

val record_tool_schemas : t -> count:int -> estimated_tokens:int -> unit
(** Record token cost of tool schemas sent to the model. *)

val record_turn : t -> estimated_tokens:int -> unit
(** Record token cost of a conversation turn (user + assistant). *)

val current_phase : t -> compression_phase
(** Determine compression phase from current usage ratio. *)

val tool_budget_for_phase : t -> int option
(** Suggested tool description token budget for current phase.
    [None] at [None_phase] (no limit). *)

val usage_ratio : t -> float
(** Current usage as a fraction of max budget (0.0 to 1.0+). *)

val total_tokens : t -> int
(** Total accumulated tokens (tool schemas + turns). *)

val max_budget : t -> int
(** Maximum budget configured for this tracker. *)

val summary : t -> string
(** Human-readable status line. *)
