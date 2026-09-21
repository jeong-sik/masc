(** Which atoms of a keeper's saved history a Librarian round reads (RFC
    librarian-lifecycle §4.4, rows 1b, 2, 2a, 2c, 3, 3a, 3c, 3d, 5).

    Pure: no I/O and no clock. A round hands in what it read -- the lines of
    the turn-boundary log, taken {e before} the checkpoint was loaded, the
    progress file, and the messages of the checkpoint -- and gets back the
    range to read, or the reason there is none.

    The text a round reads always comes from the checkpoint. A line of the log
    is only a candidate for where to cut, and only when it matches that
    checkpoint, so a line that is ignored costs a cut point and never text.

    The rules assume that the turns of one keeper do not overlap (RFC §4.5):
    the Keeper Owner runs one child turn at a time. *)

type range =
  { history_start_boundary_line : int
      (** First boundary row in the selected history generation. *)
  ; start_atom : int
  ; end_atom : int  (** Exclusive. Greater than [start_atom]. *)
  ; last_atom_digest : string
      (** Of atom [end_atom - 1], as the line that is the cut point states it
          and as the checkpoint has it. *)
  }

(** How much of what is unread a round takes (row 3a). *)
type extent =
  | All_unread
  | To_first_cut_point
      (** What a round takes after one failed on a longer range. A caller does
          not have to know first whether the range held more than one cut
          point: on a range of one this returns that same range, which is the
          retry it wanted anyway. *)

type stop =
  | Unreadable_line of
      { line : int
      ; error : Keeper_turn_boundaries.read_error
      }
      (** Row 2c. A newline-terminated line the decoder refused. It is not
          dropped, because it may be a restart line, and not read as one,
          because that would be a convenient value for unknown input.

          The file is never rewritten, so a line that stops a round stops
          every later one as well, until a restart line of this trace is
          appended after it. From then on the refused line cannot change
          where a round starts -- a restart puts that at atom zero -- and the
          rounds go on. *)
  | Position_mismatch of
      { position : Keeper_librarian_progress.position
      ; atom_count : int
      }
      (** Row 5. The read position is not a place in this checkpoint and no
          restart line explains why. *)

type selection =
  | Read of
      { range : range
      ; boundary_lines_seen : int
      }
  | Baseline of
      { position : Keeper_librarian_progress.position
      ; boundary_lines_seen : int
      }
      (** Row 3, third case: no read position and no restart line, so the
          history predates the log. The smallest cut point becomes the
          position and nothing before it is read. *)
  | Nothing_to_read
      (** No cut point lies beyond the start. The progress file is not
          written: a restart that was seen but not yet read from must be seen
          again by the next round. *)
  | Position_in_other_trace of Keeper_librarian_progress.position
      (** Row 1b. The read position belongs to another trace than the one
          asked about; the caller decides which trace to read. *)
  | Stop of stop

val may_have_unread :
  trace_id:string ->
  lines:
    (int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list ->
  progress:Keeper_librarian_progress.t option ->
  bool
(** Cheap conservative check before loading the checkpoint. [trace_id] is the
    current metadata trace; a cursor from another trace always returns [true]
    so the full selector can report the mismatch. [false] proves
    that the current restart segment contains no position beyond the durable
    cursor. Segment selection is shared with {!select}; already-seen restarts
    still exclude earlier histories. Unreadable complete rows, a shortened log, a later
    restart, or a new current-segment atom boundary returns [true]. Appended
    official-only rows do not require an atom checkpoint read. The full
    selector still validates unreadable lines and checkpoint digests. *)

(** [lines] is {!Keeper_turn_boundaries.read}'s answer. [messages] are the
    messages of the checkpoint of [trace_id], loaded after [lines] were read.
    Only lines of [trace_id] take part; a line that cannot be decoded stops the
    selection whatever trace it may have belonged to. A trailing fragment with
    no newline is not a line. *)
val select
  :  trace_id:string
  -> lines:
       (int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result)
         list
  -> progress:Keeper_librarian_progress.t option
  -> messages:Agent_core.Types.message list
  -> extent
  -> selection

(** How many finished turns of [trace_id] lie beyond the read position (RFC
    §4.9, invariant I4). Only [Turn_ended] lines whose endpoint matches the
    loaded checkpoint are counted (§4.4 row 2a): a line of a history that has
    been renumbered is not a turn this keeper can read. A restart line is not
    a turn. A refused line does not hide the turns that can be counted --
    that a round is stopped is what {!select} says, and the number is how far
    behind it is standing.

    [None] when the position names no atom of this checkpoint and no restart
    line explains it (row 5). Every line would then look unread, and the
    count would say the whole history is behind when what is wrong is the
    position.

    With no position, the smallest cut point becomes the baseline and nothing
    before it is read, so it is not counted as unread. *)
val unread_turns
  :  trace_id:string
  -> lines:
       (int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result)
         list
  -> progress:Keeper_librarian_progress.t option
  -> messages:Agent_core.Types.message list
  -> int option

(** What the progress file holds once the round that read [selection] has
    saved what it learned: [Some] for [Read] and [Baseline], [None] for every
    selection that reads nothing. [boundary_lines_seen] is the count taken
    from the lines handed to {!select}, never a later one. *)
val progress_after
  :  trace_id:string
  -> selection
  -> Keeper_librarian_progress.t option

(** The messages of the atoms in [range], in order, tool results included.
    [System] messages and extra-context messages belong to no atom and are
    left out.

    The list must be the one {!select} was given. A range is two atom numbers
    in that list's numbering, so another list slices without complaint and
    returns text the round never selected. The range carries the digest that
    tells the two apart and this function does not read it. *)
val slice : Agent_core.Types.message list -> range -> Agent_core.Types.message list

(** {1 Official-client turns (RFC §10-3)}

    An end line whose position is [No_atom_history] marks an official-client
    turn. It carries no cut point; what the turn said is read by its
    [turn_ref] from the history files of its trace
    ({!Keeper_turn_fragments}). The position among these lines is a line of
    the log ({!Keeper_librarian_official_progress}), not an atom, and it is
    independent of the atom position: neither waits for the other, and the
    consumer orders what both select by line number. *)

type official_line =
  { line : int
  ; turn_ref : Ids.Turn_ref.t
  ; recorded_at : float
  }

type official_selection =
  | Official_read of official_line list
      (** In line order, never empty. The last one is the cursor after the
          round commits. *)
  | Nothing_official
  | Official_stop of
      { line : int
      ; error : Keeper_turn_boundaries.read_error
      }
      (** Row 2c for these lines. A refused line beyond the cursor may be an
          official turn's end line; passing it would skip that turn (I3). No
          restart lifts it: a restart says where atoms begin again and
          nothing about these lines. The remedy is a purge of the keeper. *)

(** The [No_atom_history] end lines beyond [cursor], of every trace: a trace
    that ended still has fragments in its own session directory.
    [To_first_cut_point] takes the oldest one. *)
val select_official
  :  lines:
       (int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result)
         list
  -> cursor:Keeper_librarian_official_progress.t option
  -> extent
  -> official_selection

(** Official-client turns beyond the cursor (RFC §4.9). Refused lines are not
    counted and do not hide the candidates beside them. *)
val unread_official_turns
  :  lines:
       (int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result)
         list
  -> cursor:Keeper_librarian_official_progress.t option
  -> int

(** Whether {!select_official} could return anything but [Nothing_official]:
    a candidate or a refused line beyond the cursor. *)
val may_have_unread_official
  :  lines:
       (int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result)
         list
  -> cursor:Keeper_librarian_official_progress.t option
  -> bool

type atom_cut =
  { cut_line : int
  ; cut_end_atom : int
  ; cut_recorded_at : float
  ; cut_turn_ref : Ids.Turn_ref.t
  }

(** The cut points inside [range], in line order: every current-history line
    of [trace_id] whose position matches [messages] and whose [end_atom] lies
    in [(range.start_atom, range.end_atom]]. The consumer slices the range at
    these so a round hands the Librarian the turns in the order they ended,
    interleaved with official-client turns by line. [lines] and [messages]
    must be the ones {!select} was given; the range's own end is then among
    the cuts. *)
val cut_lines
  :  trace_id:string
  -> lines:
       (int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result)
         list
  -> messages:Agent_core.Types.message list
  -> range
  -> atom_cut list
