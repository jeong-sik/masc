(** A reading page as data. Each line says whether it is a title, a fact (a
    label and its value), a list or a note, and how much it matters; the screen
    alone decides what each looks like. *)

(** [Quiet] is background the reader may skip, [Plain] is the default,
    [Info] is something live or just done that the reader may want to follow,
    [Success] is a check that passed and says so, [Attention] is what the
    reader has to know before acting on the page, and [Failure] is something
    that broke and has to be fixed. *)
type tone = Quiet | Plain | Info | Success | Attention | Failure

type t =
  | Title of string
  | Fact of { label : string; value : string; tone : tone }
  | Note of { text : string; tone : tone }
  | Items of { label : string; values : string list; tone : tone }

val fact : ?tone:tone -> string -> string -> t
(** [fact label value]. *)

val note : ?tone:tone -> string -> t

val items : ?tone:tone -> string -> string list -> t
(** [items label values]: one numbered row per value under the label, so a long
    list can be counted and a row can be named by its number. A list with no
    values draws nothing. A list that has a word for none is a fact when it is
    empty. *)

val text : t -> string
(** The line as plain text. A fact reads [label: value] and a list reads the
    label and its values joined by commas. *)
