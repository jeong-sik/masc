(** Deterministic offline checkpoint purge (RFC-0351 S1).

    Reduces a persisted OAS checkpoint with three closed rules, none of which
    involves an LLM:

    - R1 duplicate collapse: byte-identical text-only messages repeated at
      least [dup_threshold] times keep their first and last occurrence.
    - R2 reasoning strip: unsigned [Thinking] and [ReasoningDetails] blocks are
      removed from assistant messages that carry no [ToolUse] block; a message
      left with no content is dropped.
    - R3 tool-result clear: [ToolResult] blocks in closed tool cycles have
      their content replaced by {!cleared_tool_result_content}, preserving the
      [tool_use_id]/[ToolUse] pairing (the cycle stays a valid closed unit).

    Tool protocol cycles are never split, reordered, or dropped. The last
    [keep_recent_messages] messages — and the structurally protected suffix
    from {!Keeper_compaction_unit.partition} — are returned byte-exact.
    Signed thinking ([Thinking] with a signature and [RedactedThinking]) is
    never removed: providers replay it byte-exact on tool turns.

    Input and output are both validated with
    {!Keeper_compaction_unit.validate}; a checkpoint that fails input
    validation is refused rather than repaired, because a structurally broken
    history has to be prevented at the write boundary that admitted it
    (#25443). [session_id], [turn_count], and every other checkpoint field
    outside [messages] pass through unchanged, so
    [Keeper_checkpoint_store.save_oas_classified] accepts the result as an
    equal-watermark re-save.

    Applying the purge twice with the same config returns the first result
    unchanged (verified by test): survivors of R1 number below
    [dup_threshold], R2 leaves nothing further to strip, and R3 is a fixed
    substitution. *)

type config =
  { dup_threshold : int (** minimum occurrences before R1 collapses, >= 2 *)
  ; keep_recent_messages : int (** byte-exact protected tail length, >= 0 *)
  ; strip_thinking : bool (** apply R2 *)
  ; clear_tool_results : bool (** apply R3 *)
  }

val default_config : config
(** [{ dup_threshold = 3; keep_recent_messages = 20; strip_thinking = true;
      clear_tool_results = true }] — the rule set measured on the analyst
    checkpoint (1,315 -> 579 messages, -28.0% bytes, next-turn input
    -26.0%). *)

val cleared_tool_result_content : string
(** Replacement content for R3-cleared [ToolResult] blocks. A fixed marker,
    not a classifier: nothing reads it back. *)

type report =
  { messages_before : int
  ; messages_after : int
  ; duplicates_dropped : int (** R1: middle occurrences removed *)
  ; reasoning_blocks_stripped : int (** R2: blocks removed from survivors *)
  ; reasoning_messages_dropped : int (** R2: messages left empty and dropped *)
  ; tool_results_cleared : int (** R3: blocks whose content was replaced *)
  }

type purge_error =
  | Invalid_config of string
  | Invalid_input_structure of Keeper_compaction_unit.structural_error
  | Invalid_output_structure of Keeper_compaction_unit.structural_error
      (** Defensive re-validation of our own output; reaching this is a bug in
          the transform, never a property of the input. *)

val purge_messages
  :  config:config
  -> Agent_sdk.Types.message list
  -> (Agent_sdk.Types.message list * report, purge_error) result
(** Pure message-list transform behind {!purge}. Exposed for tests. *)

val purge
  :  config:config
  -> Agent_sdk.Checkpoint.t
  -> (Agent_sdk.Checkpoint.t * report, purge_error) result
(** Apply {!purge_messages} to [ckpt.messages], leaving every other field
    unchanged. *)
