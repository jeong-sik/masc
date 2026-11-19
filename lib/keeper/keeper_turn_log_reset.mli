(** The one way a product path shrinks or changes a Keeper's head
    (RFC librarian-call-only-proposes §5.2, §5.6).

    A history clear and a purge that drops what follows a break both go
    through {!run}, in this order:

    + the path's own checks ([prepare]);
    + one save that closes the head's open messages, so the line can name
      them ({!Keeper_turn_log_closing});
    + the [Reset] line, [Announced];
    + the head change ([change]).

    The line goes first. A change that is refused, fails, or is cut by a
    kill leaves the same disk: a [Reset] and the head as it was. The next
    unit starts at the line's [after] either way, so the messages between
    [after] and [before] are named a second time and none is skipped. A
    count cannot tell the two cases apart, so {!run} does not try: after the
    line it has no error branch and returns the change's own result.

    Turns are kept out by the caller, which holds what an admission waits
    on: a history clear runs inside its owner's [begin_history_clear], a
    dashboard purge holds the Keeper's lifecycle key lock. *)

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
  (** The writer planned no line for the reset. Its plan always ends in the
      [Reset], so this is a fault of the writer. No change. *)

(** [after plan] gives the mark once the change is made, from the mark
    before it: only the stores the change touches differ. *)
val run
  :  at:float
  -> new_log_id:Keeper_turn_log.Log_id.t
  -> Keeper_turn_log_recorder.place
  -> cause:Keeper_turn_log.announced
  -> prepare:(unit -> ('plan, 'refused) result)
  -> after:('plan -> Keeper_turn_log.mark -> Keeper_turn_log.mark)
  -> change:('plan -> 'changed)
  -> ('changed, 'refused refusal) result

val refusal_to_string : ('refused -> string) -> 'refused refusal -> string
