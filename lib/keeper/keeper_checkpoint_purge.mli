(** Deterministic offline checkpoint purge (RFC-0351 S1).

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
      type-level distinction (the typed outcome), not content classification,
      so it stays inside RFC-0351 §2's "judge by type, integer, or byte
      comparison only" rule.

    {2 The atom sequence is kept}

    Every [User] and [Assistant] message opens an atom
    ({!Runtime_model_input_tail_window.annotate}), and four stores count in
    atoms: the turn-boundary log, the Librarian position, the continuity
    snapshot and the carried-front seed. A purge that removed an atom would
    renumber every one after it, and each of those stores would describe a
    history that is no longer there. goo-yang-bong's purge on 2026-09-22
    dropped 825 repeated wake cues and 6 reasoning-only replies, the history
    went from 13,550 atoms to 12,719, nothing that counted in atoms matched
    it any more, and every turn sent the whole 16 MB history until one
    finally completed. So no rule here removes an atom-opening message.

    The last atom is returned byte-exact along with the tail, so the
    history's end — its atom count and the digest of the message that opens
    the last atom — is the same after the purge as before. That end is what a
    position at the end of the history is keyed by, so the Librarian
    position, the latest turn-boundary line and the request front all still
    match. {!purge_messages} checks it and returns {!History_end_moved}
    rather than a history whose end moved. The exception is a structurally
    broken input: recovery drops the broken tail, so its end moves by design.

    Tool protocol cycles are never split, reordered, or dropped. The last
    [keep_recent_messages] messages, the whole last atom, and the structurally
    protected suffix from {!Keeper_transcript_unit.partition} are returned
    byte-exact. Signed thinking ([Thinking] with a signature and
    [RedactedThinking]) is never removed: providers replay it byte-exact on
    tool turns.

    The rewritten bytes still differ from what a continuity snapshot hashed
    (its [prefix_sha256]), so whoever installs a purged checkpoint discards
    that snapshot first ({!Keeper_librarian_continuity.discard}); left in
    place, it would refuse every Agent-Core turn with [Prefix_changed].

    Input and output are both validated with
    {!Keeper_transcript_unit.validate}; a checkpoint that fails input
    validation is refused rather than repaired, because a structurally broken
    history has to be prevented at the write boundary that admitted it
    (#25443). [session_id], [turn_count], and every other checkpoint field
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

(** What a purge does to the Librarian's atom position (RFC
    librarian-lifecycle §10-2). A purge of a sound transcript keeps every atom
    and the last one byte-exact, so the position is answered back unchanged.
    Recovery from a broken transcript drops its tail, and there the position
    moves to the new end. Either way it is only allowed when the position has
    nothing left to read: the reasoning strip rewrites the messages that open earlier atoms, so
    a position short of the end would no longer match the message it names.

    [boundary_lines_seen] is left as it is. It says which lines of the
    boundary log a round had already counted, so that a restart line beyond
    it is taken as new; raising it to the log's current length would pass
    over a restart no round has seen yet
    ([specs/bug-models/LibrarianRead-purge-trim-counting-lines-buggy.cfg]).
    The official-turn position is a line of that log and is not touched. *)
type rebase =
  | No_progress  (** No position: nothing to move. *)
  | Rebased of
      { before : Keeper_librarian_progress.t
      ; after : Keeper_librarian_progress.t
          (** [before] with the position's [end_atom] and [last_atom_digest]
              taken from the rewritten history. *)
      }

type refusal =
  | Unread_atoms_present of
      { end_atom : int
      ; atom_count : int
      }
      (** The position stops short of the history's end
          ([specs/bug-models/LibrarianRead-purge-trim-buggy.cfg]). *)
  | Position_beyond_history of
      { end_atom : int
      ; atom_count : int
      }
      (** The position lies past the history's end: it is not a place in
          this checkpoint, so there is nothing to move. The next round stops
          on it; the way out is the keeper's Librarian purge. *)
  | Position_in_other_trace of string
      (** The position belongs to another trace than the checkpoint's. *)
  | Position_in_other_history of
      { held : string
      ; history : string
      }
      (** The position has the checkpoint's atom count but its final digest
          belongs to another history. *)
  | Rewrite_leaves_no_atoms
      (** The rewritten history has no atom to hold a position in. *)
  | Position_unreadable of string
      (** A position could not be computed from the messages. *)
  | Position_invariant_violation of string
      (** [position_of_messages] returned a turn-end-only result. This is an
          internal contract violation rather than unreadable input. *)

val refusal_to_string : refusal -> string

val librarian_rebase
  :  progress:Keeper_librarian_progress.t option
  -> trace_id:string
  -> before:Agent_core.Types.message list
  -> after:Agent_core.Types.message list
  -> (rebase, refusal) result
(** The position to write once [after] is installed in place of [before],
    or why the rewrite must not be installed. Pure. *)

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
          the offending cycle and everything after it. Zero for a structurally
          sound input, which is every input that is not being recovered.

          Purge refused a broken transcript until 2026-09-01, which made it
          useless for the one case an operator reaches for it -- a keeper whose
          stored history carries a break cannot save a checkpoint, so it fails
          every turn at the same message until someone edits the JSON by hand.
          Preserving the break instead of dropping it would return a
          still-unsaveable transcript and report success, so recovery discards
          it and says how much. *)
  }

type purge_error =
  | Invalid_config of string
  | Invalid_input_structure of Keeper_transcript_unit.structural_error
  | Invalid_output_structure of Keeper_transcript_unit.structural_error
      (** Defensive re-validation of our own output; reaching this is a bug in
          the transform, never a property of the input. *)
  | History_end_unreadable of string
      (** {!Keeper_turn_boundaries.position_of_messages} could not name the end
          of the input or of the output. *)
  | History_end_moved of
      { before : Keeper_turn_boundaries.position
      ; after : Keeper_turn_boundaries.position
      }
      (** A sound input came out with a different atom count or a different
          message opening its last atom. The rules above keep both, so this is
          a bug in the transform; the rewrite is refused rather than installed
          under positions it would no longer match. *)

val purge_error_to_string : purge_error -> string

val purge_messages
  :  config:config
  -> Agent_core.Types.message list
  -> (Agent_core.Types.message list * report, purge_error) result
(** Pure message-list transform behind {!purge}. Exposed for tests. *)

val purge
  :  config:config
  -> Agent_core.Checkpoint.t
  -> (Agent_core.Checkpoint.t * report, purge_error) result
(** Apply {!purge_messages} to [ckpt.messages], leaving every other field
    unchanged. *)
