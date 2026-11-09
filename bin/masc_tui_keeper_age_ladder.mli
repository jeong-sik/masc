(** The memory fact age ladder as text (RFC-0511 D2).

    The server counts a Keeper's ordinary facts into four bins by the time
    since each fact was first seen, at the health response's [generated_at]
    ({!Masc.Keeper_memory_age_bins}). This module owns every word, mark and
    edge the screens draw from those bins, so the Memory header, the selected
    Keeper's detail, the Keepers second-row cell and the key sheet read one
    spelling.

    The ladder counts facts by age; it names no state, and no bin has a tone.
    Pure: no clock, no terminal. *)

type bin = Masc.Keeper_memory_age_bins.bin

val oldest_first : bin list
(** The order the bins are drawn in: the oldest on the left, so the right end is
    the facts first seen most recently. *)

val edge_seconds : bin -> float option
(** Where the bin ends, in seconds of age; [None] for the open-ended oldest
    bin. The words on screen are made from the same three edges, and a test
    holds them to the edges {!Masc.Keeper_memory_age_bins.classify} counts
    with. *)

(** What one bin draws. An empty bin is [Empty], never the lowest bar, so
    "none" and "a few" differ. A bar's height is its count against the tallest
    bin of the same ladder, not an absolute count: the strip shows the shape.
    The header and the detail print the counts beside it, the cell prints the
    total. *)
type mark =
  | Empty
  | Bar of string

val marks : Masc.Keeper_memory_age_bins.t -> mark list
(** One mark per bin, in {!oldest_first} order. *)

val strip : Masc.Keeper_memory_age_bins.t -> string
(** The {!marks} as one mark per bin: a bar, or [0] for a bin with no facts. *)

val unmeasured_mark : string
(** What a ladder the server did not measure draws in place of its strip. *)

val cell_label : string
(** The word the second-row cell opens with. *)

val cell : Masc.Keeper_memory_age_bins.t option -> Masc_tui_keeper_axis_cell.t
(** The second-row cell: the label, the fact count and the strip, or the label
    and a [?] when the server did not measure the ladder (the snapshot is
    absent or its read failed). [None] is not a count of zero. Always
    {!Masc_tui_keeper_axis_cell.Quiet}. *)


val legend : string
(** The sentence the key sheet prints for the cell. It names the bins, says that
    a bar is relative to the tallest bin of the same strip, and spells the two
    marks that are not bars: [0] for a bin with no facts and [?] for a ladder
    that was not measured. The key sheet adds where the strip is drawn. *)

val keeper_clauses : ko:bool -> Masc.Keeper_memory_age_bins.t option -> string list
(** One Keeper's ladder as clauses for a packed row that has no label above it:
    "ordinary facts since first seen" with the strip, then a count per age
    range, or the same words with a [?]. *)

type fleet =
  | Nobody_measured of { keepers : int }
      (** At least one Keeper row, read or refused, and none of them carries a
          ladder. *)
  | Measured of
      { bins : Masc.Keeper_memory_age_bins.t
      ; unmeasured_keepers : int
      }
      (** The sum of the Keepers that carry a ladder. With no Keeper rows it is
          the zero ladder. *)

val fleet_of
  :  refused_rows:int
  -> Masc.Tui_decode_memory_health.memory_keeper_health list
  -> fleet
(** [refused_rows] is how many rows the server sent that this build refused
    ([mhs_refused_keepers]). The server's fact totals count those rows, so each
    one is a Keeper without a ladder here and is named in
    [unmeasured_keepers], not left out of both numbers. *)

val fleet_clauses : ko:bool -> fleet -> string list
(** The fleet's ladder as clauses for a row that already says "Ordinary".
    Keepers without a ladder are named in a closing clause, so a partial sum is
    not read as the whole. *)
