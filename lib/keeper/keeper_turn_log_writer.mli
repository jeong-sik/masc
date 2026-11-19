(** Which lines a Keeper's turn path appends, and when
    (RFC librarian-call-only-proposes §5.2, the table).

    A pure decision. The tail that was read, where the head ends now and
    what is happening give the lines to append in one write. The caller reads
    the tail, asks, appends at the end it read, and asks again if the end had
    moved.

    Three things hold for every order of admissions, saves, endings, kills,
    lost appends and replaced heads. A test enumerates the orders:

    - the lines are in the one order a reader accepts;
    - every message a head held closed after the log started is named by
      exactly one slice, in order, once a [Closed] follows it;
    - a message is in a turn's [own] exactly when the log showed that turn
      open on this head when the message was closed.

    This module judges the Agent-Core history only: the trace and the count
    of closed messages. The other stores of a mark are carried as given,
    apart from the ones a reset says its path changes. *)

(** How a turn that reached its end ended. A turn nothing closed is closed by
    the next admission or the next process start, with an outcome of its
    own. *)
type ending =
  | Completed
  | Errored
  | Cancelled
  | Save_failed
  | Stale_save

(** What a turn's admission left in the log. The turn carries it to its end. *)
type admitted =
  | Recorded of { opened : int }
  (** Byte offset of the turn's [Opened]: [last_at] of the admission's
      append. *)
  | Not_recorded (** The tail was not read or the append failed. *)

type event =
  | Admit of
      { turn_ref : Ids.Turn_ref.t
      ; runtime : string
      ; task : Keeper_turn_log.task_evidence
      ; stimuli : Keeper_turn_log.stimulus list
      }
  (** The last line of the plan is the turn's [Opened]. *)
  | Finish of
      { admitted : admitted
      ; ending : ending
      }
  | Process_start (** After checkpoint tail recovery, before any turn. *)
  | Reset of
      { cause : Keeper_turn_log.announced
      ; after : Keeper_turn_log.mark -> Keeper_turn_log.mark
      (** The mark once the path has changed its stores, from the mark
          before. Only the stores the path changes differ. *)
      }
  (** A product path is about to shrink or change the head
      ({!Keeper_turn_log_reset}). The last line of the plan is the
      [Announced] reset: [before] is [now], [after] is [after now], and
      [closed_before] names what was closed since the last unit, so the
      messages the path drops are named before they go. An open turn is left
      open: its [Closed] then names nothing as its own. *)

(** [now] is where the stores end and [covered] is the closed turns of the
    same head. Open messages are not counted: a message is named by the
    first unit after the save that closed it. An admission leaves the head's
    open messages to its turn. When the last [Opened] is open at a process
    start, the caller ({!Keeper_turn_log_process_start}) closes them before
    it reads. A head that does not decode counts as an
    empty head on its trace. [new_log_id] is used only when nothing is
    written yet.

    An empty list means there is nothing to append. A turn whose [Opened] is
    not the open one in the log ends without a line, and what it closed
    belongs to the next unit.

    {b A replaced head.} When the head is on another trace than the last
    line saw, or holds fewer closed messages, what was closed in between is
    not known. The plan then starts with an [Unannounced] reset whose
    [after] is the empty mark of the head's trace. So the next unit names
    every closed message the head holds, from the first one: nothing a turn
    closed on the new head is skipped. The price is that a head that was cut
    short, with its front kept, has that front named a second time.

    With [now] and [covered] taken from one head the only error is
    [Starts_before_covered]: read the segment before and ask again. *)
val plan
  :  at:float
  -> new_log_id:Keeper_turn_log.Log_id.t
  -> tail:Keeper_turn_log_store.tail
  -> now:Keeper_turn_log.mark
  -> covered:Keeper_turn_log_marks.covered
  -> event
  -> (Keeper_turn_log.line list, Keeper_turn_log_marks.range_error) result

(** The one line a path writes before it drops the head without reading it:
    a history clear that removes a head this build cannot decode, or a stop
    that deletes the session.

    [before] is the last mark and [after] is [after] of it: the trace the
    path leaves, no closed message, and the other stores the path changes.
    [closed_before] is empty because what goes cannot be read. [now]'s
    history is not looked at; with nothing written yet, the line is the
    log's first, at [after now].

    The line is written every time, even when the last mark already counts
    no closed message. A turn whose [Opened] was not written can grow the
    next head back past the last mark, and no count would show the drop
    then. *)
val drop
  :  at:float
  -> new_log_id:Keeper_turn_log.Log_id.t
  -> tail:Keeper_turn_log_store.tail
  -> now:Keeper_turn_log.mark
  -> after:(Keeper_turn_log.mark -> Keeper_turn_log.mark)
  -> Keeper_turn_log.line
