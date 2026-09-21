(** Whether an offline checkpoint purge may rewrite a keeper's saved history,
    and where the Librarian's read position goes afterwards (RFC
    librarian-lifecycle section 10, second decision; model
    [specs/bug-models/LibrarianRead.tla], action [PurgeTrimAtEnd]).

    The purge drops messages from anywhere in the history and renumbers every
    atom after them, so a read position counted against the old numbering
    names a different atom afterwards. The rule that holds is stated over
    atoms, not turns: the rewrite is allowed only when the read position is
    the end of the history being rewritten. Afterwards the position's end
    moves to the end of the rewritten history, its digest to that atom's, and
    [boundary_lines_seen] stays what it was. A purge may move where a round
    reads next; it may not decide what a round has already seen: a restart
    line beyond the counted lines still sends the next round back to atom
    zero, which re-reads the rewritten history and loses nothing. *)

type refusal =
  | Not_read_yet of { atom_count : int }
      (** Turn-boundary lines or a progress file exist, but no read position
          for this trace: every one of the [atom_count] atoms is unread. *)
  | Unread_atoms of
      { end_atom : int
      ; atom_count : int
      }
      (** The position stops before the end: atoms [[end_atom, atom_count)]
          are unread. *)
  | Position_off_history of
      { end_atom : int
      ; atom_count : int
      }
      (** The position claims an end this history does not have: beyond it,
          or with another digest at it. It describes some other history. *)
  | Rewrite_empties_history
      (** The rewritten history would hold no atom, and a position needs one.
          Purging a history down to nothing gains nothing. *)

val refusal_to_string : refusal -> string

type decision =
  | Allowed of Keeper_librarian_progress.t option
      (** The purge may go ahead. [Some rebased] is the progress to write
          after the rewritten checkpoint is installed; [None] when there is
          no read position to move. *)
  | Refused of refusal

val decide
  :  trace_id:string
  -> boundary_lines_present:bool
  -> progress:Keeper_librarian_progress.t option
  -> before:Agent_core.Types.message list
  -> after:Agent_core.Types.message list
  -> (decision, string) result
(** [decide ~trace_id ~boundary_lines_present ~progress ~before ~after] for
    the keeper whose current trace is [trace_id], whose turn-boundary log
    exists iff [boundary_lines_present], whose progress file reads as
    [progress], and whose saved messages the purge would turn from [before]
    into [after]. Pure. [Error] when an endpoint cannot be computed
    ({!Keeper_turn_boundaries.position_of_messages}). *)
