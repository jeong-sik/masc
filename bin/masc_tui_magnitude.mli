(** Where a count sits in the distribution it belongs to.

    Several surfaces draw a row of counts that partition one whole -- the task
    backlog by status, the Board by hearth, the judge's verdicts by gate --
    and every entry was drawn in one tone. A reader had to compare the digits
    to find which one held most of it, on rows where the spread runs three
    orders of magnitude (1,983 against 3 on one live gate distribution).

    The bands are read off the distribution, not set against invented
    thresholds. [Below_even_share] is below what the entry would hold if the
    whole were split equally, which needs no constant because the split is the
    data. [Leading] is within reach of the largest entry -- at least half of
    it -- which is a comparison to what is there rather than to a number
    somebody chose.

    The tone never carries what the text does not. Each entry prints its own
    count beside it, so a terminal with no colour loses emphasis and no
    fact. *)

type band =
  | Leading  (** at least half the largest entry *)
  | Ordinary
  | Below_even_share  (** below [total / entries] *)

val band : value:int -> total:int -> entries:int -> largest:int -> band
(** [Ordinary] for every entry when the distribution cannot rank them: a
    non-positive total, fewer than two entries, or a largest that is not the
    largest. A single entry is not leading anything.

    [Ordinary] for every entry of a flat distribution too -- one whose largest
    is not even twice an equal split. Counts all of a size have nothing to
    point at, and marking most of them as leaders is emphasis with no reading
    behind it. *)

val of_counts : (string * int) list -> (string * int * band) list
(** Each labelled count with its band, in the order given. The total, the
    entry count and the largest are taken from the list itself, so a caller
    cannot band an entry against a whole it does not belong to. *)
