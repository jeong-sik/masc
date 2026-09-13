(** One character for what a keeper is doing, for the columns too narrow to
    carry a word.

    The mark used to come from a string match on the health label, with
    everything the match did not name falling to the healthy dot: a stale
    keeper, one whose status file would not decode, and one whose fiber had
    already ended all drew what a working keeper draws. Six readings now get
    six marks, and a seventh member of the health vocabulary is a compile
    error here rather than a keeper that looks fine. *)

val glyph : paused:bool -> Masc.Tui_decode.keeper_health_reading option -> string
(** [None] is a roster that was not read -- not a health nothing could name. *)

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
