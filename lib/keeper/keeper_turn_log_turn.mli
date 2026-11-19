(** One Keeper turn in the turn log: its [Opened] when the turn is taken up
    and its [Closed] on every way out
    (RFC librarian-call-only-proposes §5.2).

    {!around} is the only place that writes the two lines, so a turn that was
    opened in the log is closed in it exactly once however it ends: by
    returning, by raising, or by being cancelled. A line that cannot be
    written is counted ([TurnLogAppendFailures]) and the turn runs all the
    same. *)

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

(** The Task a turn ran for, as the turn log keeps it. A Goal is kept as the
    text of its phase and criterion, encoded by the Goal's own encoders. *)
val task_evidence : Keeper_turn_task_context.t -> Keeper_turn_log.task_evidence

(** [around ~place ~turn_ref ~runtime ~task ~succeeded body] writes the turn's
    [Opened], runs [body], and writes its [Closed] before the answer or the
    exception leaves. [succeeded] says whether a returned answer is a turn
    that completed.

    The [Closed] is written even when the turn's fiber is cancelled. Nothing
    the write does replaces the body's answer or its exception. *)
val around
  :  place:Keeper_turn_log_recorder.place
  -> turn_ref:Ids.Turn_ref.t
  -> runtime:string
  -> task:Keeper_turn_log.task_evidence
  -> succeeded:('a -> bool)
  -> (t -> 'a)
  -> 'a
