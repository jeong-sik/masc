(** Deterministic offline checkpoint purge.

    Reduces a persisted AGENT_CORE checkpoint with two closed rules, neither of
    which involves an LLM, and neither of which removes a message that opens an
    atom:

    - Reasoning strip: unsigned [Thinking] and [ReasoningDetails] blocks are
      removed from assistant messages. A message the strip would leave empty
      is kept as it was.
    - Tool-result clear: [ToolResult] blocks in closed tool cycles have
      their content replaced by {!cleared_tool_result_content}, preserving the
      [tool_use_id]/[ToolUse] pairing (the cycle stays a valid closed unit).
      Failed results ([Tool_failed]) are exempt and pass through byte-exact:
      their payload is the feedback the keeper reads on later turns and the
      only error evidence the durable history carries. The exemption is a
      type-level distinction (the typed outcome), not content classification:
      the purge judges by type, integer, or byte comparison only.

    {2 The atom sequence is kept}

    Every [User] and [Assistant] message opens an atom
    ({!Runtime_model_input_tail_window.annotate}). No rule here removes an
    atom-opening message, and the last atom is returned whole along with the
    protected tail.

    {2 What the turn log has not named is kept}

    A Keeper's Memory writer reads each unit from its turn log (RFC
    librarian-call-only-proposes §5.6): a message a line names from the
    bundle the line points at, and the messages past the last unit's mark
    from the head. A purge that drops nothing therefore rewrites only the
    messages below that mark ({!Keeper_turn_log_writer.named}). The ones
    above it, closed or open, stay byte-exact for the next unit to read. A
    head replaced since the log's last line has none below the mark, so
    nothing in it is rewritten. With no turn log, the log a later turn
    starts begins at the head it finds. No line will name what the head
    holds now, so the turn log holds nothing back.

    Recovery from a structurally broken input drops the broken tail at the
    break, so its end moves by design; atoms are then counted on the history
    it returns. Its [Reset] line names everything the head holds before the
    tail goes ({!Keeper_turn_log_reset}), so on a recovery the turn log holds
    nothing back either. {!turn_log_line} asks for that line when the report's
    [messages_dropped_at_structural_break] is above 0, and the rule above is
    lifted on that same answer.

    Tool protocol cycles are never split, reordered, or dropped. The last
    [keep_recent_messages] messages and the structurally protected suffix
    from {!Keeper_transcript_unit.partition} are returned byte-exact. Signed
    thinking ([Thinking] with a signature and [RedactedThinking]) is never
    removed: providers replay it byte-exact on tool turns.

    Input and output are both validated with
    {!Keeper_transcript_unit.validate}: an input that fails is recovered as
    above, and an output that fails is an error. [session_id], [turn_count],
    and every other checkpoint field
    outside [messages] pass through unchanged, so
    [Keeper_checkpoint_store.save_agent_core_classified] accepts the result as an
    equal-watermark re-save.

    Applying the purge twice with the same config returns the first result
    unchanged (verified by test): the reasoning strip leaves nothing further
    to strip, and the tool-result clear is a fixed substitution. *)

type config =
  { keep_recent_messages : int (** byte-exact protected tail length, >= 0 *)
  ; strip_thinking : bool (** apply the reasoning strip *)
  ; clear_tool_results : bool (** apply the tool-result clear *)
  }

val default_config : config
(** [{ keep_recent_messages = 20; strip_thinking = true; clear_tool_results = true }]. *)

val cleared_tool_result_content : string
(** Replacement content for cleared [ToolResult] blocks. A fixed marker,
    not a classifier: nothing reads it back. *)

type report =
  { messages_before : int
  ; messages_after : int
  ; reasoning_blocks_stripped : int (** reasoning blocks removed; no message is removed *)
  ; tool_results_cleared : int (** tool-result blocks whose content was replaced *)
  ; messages_dropped_at_structural_break : int
      (** Messages discarded because the input transcript was already broken:
          the offending cycle and everything after it. Zero for a
          structurally sound input, which is every input that is not being
          recovered.

          Purge refused a broken transcript until 2026-09-01, which made it
          useless for the one case an operator reaches for it -- a keeper whose
          stored history carries a break cannot save a checkpoint, so it fails
          every turn at the same message until someone edits the JSON by hand.
          Preserving the break instead of dropping it would return a
          still-unsaveable transcript and report success, so recovery discards
          it and says how much. *)
  }

type purge_error =
  | Repetition_boundary_invalid of string
  | Invalid_config of string
  | Invalid_input_structure of Keeper_transcript_unit.structural_error
  | Invalid_output_structure of Keeper_transcript_unit.structural_error
      (** Defensive re-validation of our own output; reaching this is a bug in
          the transform, never a property of the input. *)
  | Atom_count_changed of
      { before : int
      ; after : int
      }
      (** The output has a different number of atoms than the history it
          keeps. No rule removes an atom, so this is a bug in the transform. *)

val purge_error_to_string : purge_error -> string

val purge_messages
  :  config:config
  -> named:Keeper_turn_log_writer.named
  -> Agent_core.Types.message list
  -> (Agent_core.Types.message list * report, purge_error) result
(** Pure message-list transform behind {!purge}. [named] is how far the
    keeper's turn log has named the head when the result is installed:
    messages past that mark stay byte-exact when no break is dropped.
    Exposed for tests. *)

val purge
  :  config:config
  -> named:Keeper_turn_log_writer.named
  -> Agent_core.Checkpoint.t
  -> (Agent_core.Checkpoint.t * report, purge_error) result
(** Apply {!purge_messages} to [ckpt.messages], resetting the repetition history generation in a copied context when
    recovery drops messages. Other fields and the input checkpoint are unchanged. *)

val turn_log_line : report -> Keeper_turn_log_reset.line
(** The turn log line the install of a purge needs, from the report {!purge}
    returned with it, for {!Keeper_turn_log_reset.run}: an [Announce] of a
    [Recovered] head that ends at [messages_after] closed messages when the
    purge dropped messages at a structural break, and [No_line] otherwise.
    {!purge_messages} lifts the turn-log rule on the same answer, so a purge
    whose line is [No_line] rewrote nothing above the mark. *)
