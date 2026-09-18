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
  { start_atom : int
  ; end_atom : int  (** Exclusive. Greater than [start_atom]. *)
  ; last_atom_digest : string
      (** Of atom [end_atom - 1], as the line that is the cut point states it
          and as the checkpoint has it. *)
  ; turns : int
      (** Finished turns whose end lies in [(start_atom, end_atom]]: the lines
          of the current history counted as read by this range. *)
  }

(** How much of what is unread a round takes (row 3a). *)
type extent =
  | All_unread
  | Oldest_turn_only
      (** After a round that failed on a range of several turns: up to the
          first cut point only. *)

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
    left out. *)
val slice : Agent_core.Types.message list -> range -> Agent_core.Types.message list
