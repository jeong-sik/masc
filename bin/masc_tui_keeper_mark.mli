(** One character for what a keeper is doing, for the columns too narrow to
    carry a word.

    The mark used to come from a string match on the health label, and every
    label the match did not name drew the healthy dot. Each reading now gets
    its own mark, and a new member of the health vocabulary is a compile
    error here rather than a keeper that looks fine. *)

val glyph : paused:bool -> Masc.Tui_decode.keeper_health_reading option -> string
(** [None] is a roster that was not read -- not a health nothing could name. *)

val activity_glyph : Masc_tui_keeper_list_model.activity -> string
(** The compact list's activity mark. The renderer adds the activity word and
    substitutes its existing animated mark for preparing/running turns. *)

val badge_glyph : Masc_tui_keeper_list_model.badge -> string
(** The mark beside a secondary activity badge; the badge always keeps its
    own text label and count where applicable. *)

val legend : (string * string) list
(** Each mark and the word the wide surfaces print beside it, in the order a
    reader meets them. *)

val activation_letter : Masc.Tui_decode.keeper_activation_mode -> string
(** The Mode letter the roster draws for how a keeper is started. *)

type sandbox = Masc.Keeper_types_profile.sandbox_profile =
  | Docker
  | Micro_vm
  | Remote_ssh

val sandbox_of_profile : string -> sandbox option
(** The sandbox a roster row's profile names, or [None] for a profile this
    build does not know. *)

val sandbox_letter : sandbox -> string
(** The S letter the roster draws for a known sandbox. *)

val column_legend : (string * string) list
(** The Keepers header words and the Mode S letters, each with what it means.
    The sheet prints it; the roster does not repeat it above its rows. *)
