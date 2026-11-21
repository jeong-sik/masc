(** The words the Memory screen draws for one Keeper's Memory writer (RFC
    librarian-call-only-proposes §12.3): its state, the alarms on, and how
    its last asks ended. One sentence per constructor of
    {!Masc.Tui_decode_memory_writer}, in Korean and in English.

    The writer is the one that commits to a Keeper's Memory. The screen's
    [Librarian] readings are of the Librarian that ran before it. *)

module Writer = Masc.Tui_decode_memory_writer

val heading : ko:bool -> string
(** What the screen calls the writer. *)

val level_text : ko:bool -> Masc.Librarian_level.level -> string
val alarm_text : ko:bool -> Masc.Librarian_level.alarm -> string
(** The alarm's code and when it is on, as one sentence ([E1 ...]). *)

val state_text : ko:bool -> Writer.row -> string
(** What the writer is doing. A stopped store says why it stopped. *)

val unread_text : ko:bool -> Writer.row -> string option
(** Whether something is unread. [None] for a retired writer, which reads
    nothing more. A booting writer and a stopped store say that it cannot
    be told. *)

val slot_outcome_text : ko:bool -> Writer.slot_outcome -> string
val input_fault_text : ko:bool -> Writer.input_fault -> string
val ask_failure_text : ko:bool -> Writer.ask_failure -> string
val last_read_text : ko:bool -> Writer.last_read option -> string
val last_room_text : ko:bool -> Writer.last_room option -> string
val asked_text : ko:bool -> Writer.asked -> string
val position_text : ko:bool -> Writer.position -> string
val last_line_text : ko:bool -> Writer.last_line -> string
val stop_text : ko:bool -> Writer.stop -> string
val snapshot_file_text : ko:bool -> Writer.snapshot_file -> string

val card_clauses : ko:bool -> Writer.t -> string list
(** The clauses under {!heading} in the selected Keeper's reading: the
    state, what is unread, and how the last reading ask ended. A process
    without writers and a Keeper without one each say so in one clause. *)

type tone =
  | Tone_warn
  | Tone_error

val attention_rows : ko:bool -> Writer.t -> (tone * string) list
(** The rows that ask for a look, each led by {!heading}: one for every
    alarm on, and one when the answering process runs no writer. Empty for
    a writer with no alarm and for a Keeper that has no writer. *)

val detail_rows : ko:bool -> moment:(float -> string) -> Writer.t -> string list list
(** Every reading of the writer, a row of clauses each, the first clause
    naming the reading: the state row, a row for each alarm, the last
    reading ask with every slot's outcome, the last room ask, and where
    reading stands or why the store stopped. [moment] draws a wall-clock
    time. *)
