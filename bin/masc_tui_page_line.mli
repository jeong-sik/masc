(** A reading page as data. Each line says whether it is a title, a fact (a
    label and its value) or a note, and how much it matters; the screen alone
    decides what each looks like. *)

(** [Quiet] is background the reader may skip, [Plain] is the default,
    [Attention] is what the reader has to know before acting on the page, and
    [Failure] is something that broke and has to be fixed. *)
type tone = Quiet | Plain | Attention | Failure

type t =
  | Title of string
  | Fact of { label : string; value : string; tone : tone }
  | Note of { text : string; tone : tone }

val fact : ?tone:tone -> string -> string -> t
(** [fact label value]. *)

val note : ?tone:tone -> string -> t

val text : t -> string
(** The line as plain text. A fact reads [label: value]. *)
