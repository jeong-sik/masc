(** Tool_output_validation — Deterministic output budget enforcement.

    Replaces heuristic [truncate_tool_output] with schema-aware validation.
    Each tool has a max output budget (in chars). Outputs exceeding the
    budget are truncated with structured metadata so the LLM knows
    information was elided.

    Array-aware: JSON arrays are truncated by removing items (preserving
    structure) rather than blind character slicing.

    @since Samchon deterministic harness — #5807 *)

(** Default output budget in chars.
    Reads from [MASC_KEEPER_MAX_TOOL_OUTPUT_CHARS] for backward compat. *)
val default_budget : int

(** Register a per-tool output budget. Tools without explicit budgets
    use [default_budget]. Call during server initialization. *)
val set_budget : tool_name:string -> max_chars:int -> unit

(** Validate and truncate a tool output string against its budget.
    Returns the original if within budget, or a truncated version with
    structured metadata appended.
    Use this directly from [keeper_tools_oas.ml] for keeper_* tools
    that bypass [Tool_dispatch]. *)
val validate_and_truncate : tool_name:string -> string -> string

(** Post-hook for [Tool_dispatch.register_post_hook].
    Catches [masc_*] tools that go through the dispatch pipeline. *)
val post_hook : Tool_result.t -> Tool_result.t

(** Install the post-hook into [Tool_dispatch]. Idempotent. *)
val install : unit -> unit
