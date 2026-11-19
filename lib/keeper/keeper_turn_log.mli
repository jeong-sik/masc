(** The lines of a Keeper's turn log
    (RFC librarian-call-only-proposes §5.1 to §5.3).

    One append-only file per Keeper names the Librarian's input. A line does
    not say what a turn contained. It records where the input stores ended
    when it was written, a {!mark}, and content is what lies between two
    marks. So no line can leave a gap: whatever a store gained belongs to the
    next line that is written.

    A line holds only types of this module, ids and text. A value of a type
    another store owns is turned into one of these when the line is written,
    so a change to that store's type cannot make a written line unreadable.

    This module is the lines and what they mean in order. The wire shape is
    {!Keeper_turn_log_codec}. Neither reads or writes a file. *)

(** Names one turn log file. A new id is made each time a log is started, so
    a reader can tell a replaced file from the one it was reading. *)
module Log_id : sig
  type t = private string

  (** 32 lowercase hexadecimal characters. *)
  val of_string : string -> t option

  val to_string : t -> string
  val equal : t -> t -> bool
end

(** Where each input store ended at one moment. *)
type mark =
  { trace : string
  ; closed_messages : int
  (** Messages of the Agent-Core history that are closed. Open messages are
      not counted. Turns are not counted either: a purge can fold closed
      turns into one bundle, which changes their number and keeps the
      messages and their order. *)
  ; session : string
  ; history_bytes : int
  ; internal_bytes : int
  (** The two official-client files, each to the offset of its last line
      break, so a line caught half written is never split. *)
  ; chat_bytes : int
  ; external_rows : int
  }

(** [take] messages of one bundle after skipping [skip]. A bundle can hold the
    messages of two units after a purge, so its digest alone names no range. *)
type slice =
  { bundle : Agent_core.Checkpoint_objects.digest
  ; skip : int
  ; take : int
  }

type outcome =
  | Completed
  | Errored
  | Cancelled
  | Save_failed (** The closing save failed. *)
  | Stale_save (** The history does not hold this turn's messages. *)
  | Close_missing (** Closed by the next admission, not by the turn. *)
  | Process_exited (** Closed when the next process started. *)

type announced =
  | Cleared
  | Recovered

type reset_cause =
  | Announced of announced (** Written before the product path changed the head. *)
  | Unannounced
  (** What was closed in between is not known: the head was on another trace,
      below the last mark, or unreadable. *)

(** A Goal as text made when the turn was admitted. The Goal's own type is not
    stored, so a change to it leaves written lines readable. *)
type goal_shown =
  { goal : string
  ; shown : string
  }

type task_evidence =
  | No_task
  | Task_source_unavailable
  | Task of
      { task : Keeper_id.Task_id.t
      ; goals : goal_shown list option
      (** [None] when the Goals could not be read at admission. *)
      }

type line =
  | Log_started of
      { id : Log_id.t
      ; at : float
      ; mark : mark
      }
  | Opened of
      { at : float
      ; turn_ref : Ids.Turn_ref.t
      ; runtime : string
      ; task : task_evidence (** Taken at admission. [Closed] does not carry it. *)
      ; baseline : mark
      }
  | Closed of
      { turn : int (** Byte offset of this turn's [Opened] line. *)
      ; at : float
      ; outcome : outcome
      ; after : mark
      ; unattributed : slice list (** Closed before [baseline]. Shown without a Task. *)
      ; own : slice list
      }
  | Reset of
      { at : float
      ; cause : reset_cause
      ; before : mark
      ; after : mark
      ; closed_before : slice list
      }

(** {1 Units}

    A [Closed] line and a [Reset] line are each one unit. A unit's content
    lies between its own mark and the point the nearest unit before it left.
    The rule is the same for every store, so what was written between a
    [Closed] and the next [Opened] belongs to the next unit. *)

type boundary =
  | Starts_at of mark (** [Log_started]: no unit, the first one starts here. *)
  | Ends_unit of
      { through : mark
      ; next : mark (** Where the unit after this one starts. *)
      }
  | Moves_nothing (** [Opened]. *)

val boundary : line -> boundary

(** {1 Order}

    The one order a reader accepts:

    {v Log_started · ( Reset | Opened · Reset* · Closed )* v}

    and the file may end in [Opened · Reset*], a turn that is running. The
    writing rules produce no other order. An unclosed [Opened] is closed by
    the next admission in the same append, so two [Opened] never lie
    together.

    A [Reset] after a turn's [Opened] is remembered until its [Closed]: what
    was closed since is then not the turn's, so that [Closed] names nothing
    as [own] (RFC §5.3).

    The order is all {!step} checks. That a [Reset] starts at the mark the
    line before it left is the writer's rule; a reader takes the marks as
    they are written. *)

(** What the lines so far leave open. *)
type position =
  | Nothing_written
  | Between_turns
  | Turn_open of
      { opened : int (** Byte offset of the [Opened] line. *)
      ; reset_since : bool (** A [Reset] follows that [Opened]. *)
      }

type order_error =
  | Not_started (** A line before any [Log_started]. *)
  | Started_twice
  | Opened_while_open of { opened : int }
  | Closed_without_open
  | Closed_another_turn of
      { opened : int
      ; closed : int
      }
  | Own_after_reset of { opened : int }
  (** The turn's [Closed] names messages as its own after a [Reset]. *)

(** [offset] is the byte offset at which [line] starts. *)
val step : position -> offset:int -> line -> (position, order_error) result
