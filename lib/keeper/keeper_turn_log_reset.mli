(** The one way a product path shrinks, drops or changes a Keeper's head
    (RFC librarian-call-only-proposes §5.2, §5.6).

    A history clear, a purge that drops what follows a break and a stop that
    deletes the session go through {!run}, in this order:

    + the path's own checks ([prepare]), whose plan says which {!line} the
      change needs;
    + for an [Announce], one save that closes the head's open messages, so
      the line can name them ({!Keeper_turn_log_closing}), and the checks
      again when it closed any;
    + the line;
    + the head change ([change]).

    The line goes first. A change that is refused, fails, or is cut by a
    kill leaves the same disk: the line and the head as it was. The next
    unit starts at the line's [after] either way, so the messages between
    [after] and [before] are named a second time and none is skipped. A
    count cannot tell the two cases apart, so {!run} does not try: after the
    line it has no error branch and returns the change's own result.

    Turns are kept out by the caller, which holds what an admission waits
    on: a history clear runs inside its owner's [begin_history_clear], a
    dashboard purge holds the Keeper's lifecycle key lock. *)

(** The line a planned change needs. *)
type line =
  | No_line
  (** The change leaves nothing the log has to name: there was no head, or
      nothing changes. The change runs at once. *)
  | Announce of
      { cause : Keeper_turn_log.announced
      ; after : Keeper_turn_log.mark -> Keeper_turn_log.mark
      (** The mark once the change is made, from the mark before it: only
          the stores the change touches differ. *)
      }
  (** The change shrinks a head the log can read. The line names what was
      closed since the last unit, the open messages included once the
      closing save has closed them. *)
  | Drop of { after : Keeper_turn_log.mark -> Keeper_turn_log.mark }
  (** The change drops the head without the log reading it: a head this
      build cannot decode, or a session the stop deletes
      ({!Keeper_turn_log_writer.drop}). Nothing is closed first. *)

type 'refused refusal =
  | Path_refused of 'refused
  (** The path's checks refused. When the head held open messages the checks
      ran twice, before and after the closing save, so the change meets the
      head it was planned for. A refusal from the second run leaves those
      messages closed, as the next turn's closing save would have. *)
  | Open_not_closed of Keeper_turn_log_closing.not_closed
  (** The closing save failed. No line and no change: the change writes the
      same store and would fail too. *)
  | Line_not_written of Keeper_turn_log_recorder.not_recorded (** No change. *)
  | Line_not_planned
  (** The writer planned no line. Its plan for a reset always ends in the
      [Reset], so this is a fault of the writer. No change. *)

val run
  :  at:float
  -> new_log_id:Keeper_turn_log.Log_id.t
  -> Keeper_turn_log_recorder.place
  -> prepare:(unit -> ('plan, 'refused) result)
  -> line:('plan -> line)
  -> change:('plan -> 'changed)
  -> ('changed, 'refused refusal) result

val refusal_to_string : ('refused -> string) -> 'refused refusal -> string
