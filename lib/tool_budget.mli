(** Tool description budget limiter.

    Ranks tools by usage frequency,
    then truncates the list when the estimated token cost of descriptions
    exceeds the given budget.

    Token estimation: 1 token per 4 characters of description text. *)

val estimate_tokens : string -> int
(** Estimate the token count for a description string (~4 chars/token). *)

val filter_by_budget :
  budget_tokens:int ->
  usage_counts:(string -> int) ->
  tool_schemas:Types.tool_schema list ->
  Types.tool_schema list
(** Keep highest-priority tools within [budget_tokens].
    Higher-usage tools rank first, with name ordering as a stable tiebreaker.
    [usage_counts] returns call count for a tool name (0 if unknown). *)

val default_budget : unit -> int option
(** Read [MASC_TOOL_DESCRIPTION_BUDGET] env var. [None] means no limit. *)
