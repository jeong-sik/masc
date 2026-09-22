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

    {2 The messages a record names are kept}

    A position is an atom index and the digest of the message that opens
    that atom. Keeping the count is not enough: a completed turn usually ends
    on an assistant reply, the reasoning strip rewrites it, and the turn's
    boundary line would stop matching. With no working state that fits and
    no Librarian position that matches, the request front starts at the last
    completed turn that still matches, and at the oldest atom when none does.
    So these stay byte-exact:
    - the last atom, returned whole along with the tail. Every position at
      the history's end names it, the Librarian position included: a rewrite
      requires that position at the end ({!librarian_rebase}).
    - the opening message of the atom each completed turn of the trace ended
      on, which its [Turn_ended] line names. A failed turn can leave the
      checkpoint past the last such line, so the end alone does not cover
      it.
    - everything ahead of the end of a Librarian working state
      ({!Librarian_continuity_snapshot}) that fits the history. Once caught
      up, the turn sends that working state in place of the atoms it covers,
      and the snapshot holds a digest of their bytes; rewritten, the snapshot would
      stop fitting ([Prefix_changed]) and the Librarian would write it again
      from atom 0, one completed turn per round, with no working state in
      any request until it caught up; a snapshot still catching up would
      start over. Those atoms do not go out in a request, so leaving them
      only costs disk.
    {!purge_messages} checks all three against the history it returns — the
    atom count, each kept opener's digest, and the working state through
    {!Librarian_continuity_snapshot.restore} — and returns an error instead
    of a history they no longer describe.

    A carried-front seed ({!Keeper_carried_front}) names whatever atom a
    front moved to, and is not kept: when the purge rewrote that atom's
    opening message the seed no longer matches, and the request starts where
    the last completed turn ended.

    Recovery from a structurally broken input drops the broken tail, so its
    end moves by design; atoms are then counted on the history it returns.
    A working state that covers the dropped tail no longer fits, and the
    recovery is refused; with the server stopped, removing that working
    state (the keeper's [librarian-continuity.json]) lets it through, and
    the Librarian writes it again from atom 0.

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

(** What a purge does to the Librarian's atom position (RFC
    librarian-lifecycle §10-2). A purge of a sound transcript keeps every atom
    and the last one byte-exact, so the position is answered back unchanged.
    Recovery from a broken transcript drops its tail, and there the position
    moves to the new end. Either way it is only allowed when the position has
    nothing left to read: the rewrite clears tool results and reasoning, and
    in atoms the Librarian has not read yet that is content it would never
    absorb.

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
  | Atom_count_changed of
      { before : int
      ; after : int
      }
      (** The output has a different number of atoms than the history it
          keeps. No rule removes an atom, so this is a bug in the transform. *)
  | Kept_atom_rewritten of { atom : int }
      (** The message opening [atom], which the history's end or a boundary
          line names, came out different. A bug in the transform. *)
  | Continuity_no_longer_fits of Librarian_continuity_snapshot.error
      (** The Librarian working state fits the input and not the output. On a
          sound input this is a bug in the transform; on a recovery the
          dropped tail was part of what it covers. *)

val purge_error_to_string : purge_error -> string

type boundary_line =
  int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result
(** One line of {!Keeper_turn_boundaries.read}. *)

val purge_messages
  :  config:config
  -> trace_id:string
  -> boundary_lines:boundary_line list
  -> continuity:Librarian_continuity_snapshot.t option
  -> Agent_core.Types.message list
  -> (Agent_core.Types.message list * report, purge_error) result
(** Pure message-list transform behind {!purge}. [boundary_lines] is the
    keeper's turn-boundary log and [continuity] its saved Librarian working
    state, both as they are when the result is installed: they say which
    messages stay byte-exact. Exposed for tests. *)

val purge
  :  config:config
  -> trace_id:string
  -> boundary_lines:boundary_line list
  -> continuity:Librarian_continuity_snapshot.t option
  -> Agent_core.Checkpoint.t
  -> (Agent_core.Checkpoint.t * report, purge_error) result
(** Apply {!purge_messages} to [ckpt.messages], leaving every other field
    unchanged. *)
