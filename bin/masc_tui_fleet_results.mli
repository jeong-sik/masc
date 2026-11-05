(** The fleet stream's async answers and how each changes the reader.
    [apply] logs a reader that ended. These functions perform no terminal or
    network IO. *)

(** [Masc_tui_async_protocol.async_msg] carries these in [Fleet_msg]. *)
type msg =
  | Fleet_stream_view of Masc_tui_fleet_stream.view
      (** The reader's view, posted whenever it changes. *)
  | Fleet_stream_reader_ended of string
      (** The stream job ended, and why. The job reconnects by itself and
          ends only when withdrawn, so an end it reports is a failure. *)

(** The protocol and the loop decide by kind, not by answer: whether an answer
    is a read, whether it waits for input, whether it carries an operation
    receipt, what is left to clean up when its workspace has changed, and
    whether it is stamped with the workspace that asked. A new answer that
    takes an existing kind takes all of that kind's decisions without a
    compile error. An answer that needs another decision adds a kind, and
    then each match on the kind stops compiling until it decides. *)
type answer_kind =
  | Read  (** Reads the workspace that asked, and is stamped with it. *)

val answer_kind : msg -> answer_kind

val apply : Masc_tui_types.state -> msg -> unit
(** Apply one answer to the reader. A view from a job that is no longer
    followed changes nothing. A reader that ended is logged and left idle, so
    the next refresh starts another. *)
