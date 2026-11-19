(** The turn log's step of a process start
    (RFC librarian-call-only-proposes §5.2, the table).

    It runs once in a process, after checkpoint tail recovery and before any
    Keeper turn, for every persisted Keeper:

    - a Keeper with no turn log gets its [Log_started];
    - a Keeper whose last [Opened] is open gets the [Closed] its turn did not
      write, with [Process_exited].

    The messages that turn saved on its way are open in the head, and a line
    names closed messages only. So when the last [Opened] is open the step
    first closes the head's open messages with one save, and the [Closed]
    names them as that turn's own. When the log shows no open turn the head
    is left as it is: its open messages belong to the turn admitted next (a
    Keeper's first save, a paused turn that is continued).

    Nothing here keeps the process from starting. A save that fails leaves
    the messages open, and the next turn's closing save closes them. A line
    that is not written is written by the next admission ([Close_missing]).
    Both are logged and counted. *)

module Recorder := Keeper_turn_log_recorder

(** What was done about the head's open messages. *)
type closing =
  | No_open_turn (** The log's last [Opened] is closed, or the log has none. *)
  | Closing of Keeper_turn_log_closing.t
  (** The log's last [Opened] is open: the closing save
      ({!Keeper_turn_log_closing.close_open}) ran. *)

type outcome =
  | No_metadata (** No durable metadata that this build reads. *)
  | Metadata_unread of string
  | Log_unread of Keeper_turn_log_store.read_error
  (** Whether a turn is open is not known. Nothing was closed or written. *)
  | Stepped of
      { closing : closing
      ; line : (Recorder.recorded, Recorder.not_recorded) result
      }
  | Raised of string (** A store raised. The next Keeper is still read. *)

type report =
  { examined : int
  ; closed_open : int (** Keepers whose open messages the step closed. *)
  ; failed : int
  (** Keepers with [Metadata_unread], [Log_unread], [Raised], a closing save
      that was [Not_closed], or a line that was not written. *)
  ; outcomes : (string * outcome) list (** In enumeration order. *)
  }

val run : Workspace.config -> report
