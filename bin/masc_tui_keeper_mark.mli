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
