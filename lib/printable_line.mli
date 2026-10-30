(** One line of text a record keeps for the readers that show it, to a
    screen, an operator or a model: printable ASCII, so that a reader in any
    language loads it and what it passes on is one bounded line. *)

(** What marks text cut at the limit. *)
val cut_mark : string

(** [text] as a record keeps it: a byte outside printable ASCII, and the
    backslash that marks one, written as [\xNN] with two upper-case hex
    digits; what would pass [limit] bytes left out, whole pieces at a time,
    and [cut_mark] after it. *)
val write : limit:int -> string -> string

(** Whether [raw] is text {!write} leaves at [limit]: its pieces, within the
    limit, or cut there and marked. A reader takes no other, so a backslash
    in it never runs into a quote set around it. *)
val written : limit:int -> string -> bool
