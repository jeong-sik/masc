(** One character for what a keeper is doing, for the columns too narrow to
    carry a word.

    The mark used to come from a string match on the health label, and every
    label the match did not name drew the healthy dot. Each reading now gets
    its own mark, and a new member of the health vocabulary is a compile
    error here rather than a keeper that looks fine. *)

val glyph : paused:bool -> Masc.Tui_decode.keeper_health_reading option -> string
(** [None] is a roster that was not read -- not a health nothing could name. *)

(** What a roster row's HEALTH cell draws while its keeper has a turn open. *)
type open_turn =
  | Worked
      (** A moving mark and how long the turn has run. *)
  | Worked_while_failing
      (** A moving mark and the health word. The keepalive is running the
          next attempt, and the row still reads as failing where the roster
          header counts it. *)
  | Left_open
      (** A still mark and how long the turn has been open. Nothing works
          it: the keeper behind it is offline. *)

val open_turn : Masc.Tui_decode.keeper_health_reading option -> open_turn
(** [None] is a roster that was not read; its open turn is drawn as worked,
    the turn reading being the only one there is. *)

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
