(** One character for what a keeper is doing, for the columns too narrow to
    carry a word.

    The mark used to come from a string match on the health label, and every
    label the match did not name drew the healthy dot. Each reading now gets
    its own mark, and a new member of the health vocabulary is a compile
    error here rather than a keeper that looks fine. *)

val glyph : paused:bool -> Masc.Tui_decode.keeper_health_reading option -> string
(** [None] is a roster that was not read -- not a health nothing could name. *)

(** How a roster row's HEALTH mark reads while its keeper has a turn open.
    The word beside the mark is the health word in every case, the one the
    roster header counts; how long the turn has run is {!turn_clock}'s. *)
type open_turn =
  | Worked
      (** A moving mark in the working colour. *)
  | Worked_while_failing
      (** A moving mark in the keeper's next-action colour. The keepalive is
          running the next attempt, and the row still reads as failing where
          the roster header counts it. *)
  | Left_open
      (** A still mark in the failure colour. Nothing works the turn: the
          keeper behind it is offline. *)

val open_turn : Masc.Tui_decode.keeper_health_reading option -> open_turn
(** [None] is a roster that was not read; its open turn is drawn as worked,
    the turn reading being the only one there is. *)

(** Which instant a roster row's TURN cell counts from. *)
type turn_clock =
  | Open_turn_started of float
      (** A turn is open now; the cell is how long it has run. *)
  | Last_turn_recorded of float
      (** No turn is open; the cell is the time since the last recorded turn,
          which may have failed. *)
  | No_turn_recorded

val turn_clock :
  turn:Masc.Tui_decode.keeper_turn_state option -> last_turn_at:float option -> turn_clock
(** An open turn wins over the last recorded one. [turn] is [None] when the
    turns poll has no row for the keeper; an unavailable turn reading is not
    an open turn. *)

val legend : (string * string) list
(** Each mark and the word the wide surfaces print beside it, in the order a
    reader meets them. *)

val activation_letter : Masc.Tui_decode.keeper_activation_mode -> string
(** The Mode letter the roster draws for how a keeper is started. *)

type sandbox = Docker | Microvm | Local

val sandbox_of_profile : string -> sandbox option
(** The sandbox a roster row's profile names, or [None] for a profile this
    build does not know. *)

val sandbox_letter : sandbox -> string
(** The S letter the roster draws for a known sandbox. *)

val column_legend : (string * string) list
(** The Keepers header words and the Mode S letters, each with what it means.
    The sheet prints it; the roster does not repeat it above its rows. *)
