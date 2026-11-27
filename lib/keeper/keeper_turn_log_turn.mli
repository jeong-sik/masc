(** One Keeper turn in the turn log: its [Opened] when the turn is taken up
    and its [Closed] on every way out
    (RFC librarian-call-only-proposes §5.2).

    {!around} is the only place that writes the two lines, so a turn that was
    opened in the log is closed in it exactly once however it ends: by
    returning, by raising, or by being cancelled. A line that cannot be
    written is counted ([TurnLogAppendFailures]) and the turn runs all the
    same. So is an end that finds the log no longer showing the turn open
    (its file was replaced under the turn): nothing is written then.

    A turn's messages are closed at its end whichever way it ends. A turn
    that completes on Agent Core makes the closing save itself
    ({!note_closing_save}). A turn that saved in its middle
    ({!note_open_save}) and ends without that save has its open messages
    closed by {!around}: before its [Closed] when it ended on Agent Core, so
    the line names them as the turn's own and the next turn's baseline lies
    after them, and after its [Closed] when an official client completed it
    ({!note_client_completion}). *)

(** A turn taken up. It carries whether its [Opened] is in the log. *)
type t

(** What the store answered to the save that closes the turn. *)
type closing_save =
  | Saved
  | Stale (** The history already held a later turn: nothing was written. *)
  | Failed

(** Said by the turn at its closing save. A turn that ends before that save,
    or has none, says nothing. *)
val note_closing_save : t -> closing_save -> unit

(** Said by the turn when a save in its middle was installed: the head now
    holds open messages of this turn. If the turn ends without a closing
    save, its end closes the head's open messages with one save
    ({!Keeper_turn_log_closing.close_open}) before its [Closed] is written.
    When that save fails the turn's [Closed] is labelled as a failed closing
    save, the failure is logged and counted ([TurnLogOpenCloseFailures]), and
    the messages stay open for the next save that closes.

    A turn that never says this leaves the head as it found it: what is open
    there is not the turn's. *)
val note_open_save : t -> unit

(** Said by the turn when an official client completed it. Such a turn has no
    closing save. If an Agent Core attempt of it saved before the client took
    over ({!note_open_save}), the turn's end closes those messages after the
    turn's [Closed] is written, not before. The line then names no message,
    so the turn's unit is read from the client's own files, which a unit is
    only while no slice of it names a message. The next unit names the
    messages among what was closed before its turn, and that part is read
    from every record. A save that fails is logged and counted and does not
    label the line. *)
val note_client_completion : t -> unit

(** How the turn's body ended. *)
type exit =
  | Returned_ok
  | Returned_error
  | Raised
  | Cancelled (** Its fiber was cancelled, or the operator interrupted it. *)

(** The label of the turn's [Closed]. A cancelled turn is [Cancelled] whatever
    its save did. Otherwise a closing save that failed or was stale names the
    turn, and only then the way the body ended. *)
val ending : exit -> closing_save option -> Keeper_turn_log_writer.ending

(** Capture the Task a turn ran for, as the turn log keeps it. A Goal is kept as
    the text of its phase and criterion, encoded by the Goal's own encoders. *)
val task_evidence
  :  config:Workspace.config
  -> (Keeper_id.Task_id.t option, string) result
  -> Keeper_turn_log.task_evidence

(** One entry of the Keeper's event queue as the turn log keeps it: its id
    and the names it carries. Every kind of entry has a line type of its
    own. *)
val stimulus : Keeper_event_queue.stimulus -> Keeper_turn_log.stimulus

(** [around ~place ~turn_ref ~runtime ~task ~stimuli ~succeeded body] writes
    the turn's [Opened], runs [body], and writes its [Closed] before the answer or the
    exception leaves. [succeeded] says whether a returned answer is a turn
    that completed. The one caller passes "the settlement's result is [Ok]",
    so [Completed] also labels a turn that settled without an error and has
    more to do (held at a gate, deferred to another runtime).

    The [Closed] is written even when the turn's fiber is cancelled, and so
    is the save that closes what the turn left open. Nothing the save or the
    write does replaces the body's answer or its exception. *)
val around
  :  place:Keeper_turn_log_recorder.place
  -> turn_ref:Ids.Turn_ref.t
  -> runtime:string
  -> task:Keeper_turn_log.task_evidence
  -> stimuli:Keeper_turn_log.stimulus list
  -> succeeded:('a -> bool)
  -> (t -> 'a)
  -> 'a
