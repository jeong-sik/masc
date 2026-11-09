(** The memory fact age ladder as text (RFC-0515 §2.4.5, E25).

    The server counts a Keeper's ordinary facts into 24 bins by the time since
    each fact was first seen, at the health response's [generated_at]
    ({!Masc.Keeper_memory_age_bins}). This module owns every word, mark and
    edge the screens draw from those bins, so the age view, the Memory screen,
    the Story window, the Keepers second-row cell and the key sheet read one
    spelling.

    The ladder counts facts by age; it names no state. Pure: no clock, no
    terminal. *)

type bin = Masc.Keeper_memory_age_bins.bin

(** {1 Groups}

    The ladder's bins in four groups, oldest first. A bin's group is decided
    by where the bin starts: under a day back, under seven days back, or
    further. Bin 0 (under an hour) is a group of its own. The age view colours
    a cell by the group of the newest bin it holds; the words and the
    second-row strip count the facts per group. *)

type group =
  | Past_week  (** The bin starts seven days or more back. *)
  | Within_week  (** The bin starts a day to seven days back. *)
  | Within_day  (** The bin starts an hour to a day back. *)
  | Within_hour  (** Bin 0: under an hour. *)

val groups_oldest_first : group list

val group_of_bin : bin -> group

(** {1 The age view's column} *)

type merge
(** How many server bins one drawn cell adds: 1, 2 or 4. *)

val merge_of_column : int -> merge option
(** The merge for a pulse column of [cells] cells: 1 from 24 cells up, 2 from
    12 to 23, 4 from 6 to 11, [None] under 6 (the column draws no ladder). *)

val bins_per_cell : merge -> int

(** One drawn cell: the facts of the [merge] bins it adds and the group of the
    newest of them. *)
type cell =
  { count : int
  ; group : group
  }

val cells : merge -> Masc.Keeper_memory_age_bins.t -> cell list
(** [24 ÷ merge] cells, the oldest on the left. Cell [c] counted from the right
    adds the bins [c × merge] to [c × merge + merge − 1]. *)

val tick_line : column:int -> string
(** The column header: [1h 6h 1d 7d 30d] at the cells of their nearest bin
    edges, in a line of [column] cells. A tick that would run past the column
    or into the tick on its right is left out. Blank when the column draws no
    ladder. *)

(** {1 Words and the second-row strip} *)

(** What one group draws in the second-row strip. An empty group is [Empty],
    never the lowest bar, so "none" and "a few" differ. A bar's height is its
    count against the largest group of the same ladder. *)
type mark =
  | Empty
  | Bar of string

val marks : Masc.Keeper_memory_age_bins.t -> mark list
(** One mark per group, in {!groups_oldest_first} order. *)

val strip : Masc.Keeper_memory_age_bins.t -> string
(** The {!marks} as one mark per group: a bar, or [0] for a group with no
    facts. *)

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
(** The sentence the key sheet prints for the cell. It names the groups by
    their edges, says that a bar is relative to the largest group of the same
    strip, and spells the two marks that are not bars: [0] for a group with no
    facts and [?] for a ladder that was not measured. *)

val ages_clauses : ko:bool -> Masc.Keeper_memory_age_bins.t option -> string list
(** The facts per group, oldest first, each group named by the ages its bins
    span ("learned over 9d ago 68", "27h–9d 22", "1–27h 27", "under 1h 2"),
    or one clause saying the ages were not measured. *)

val keeper_clauses : ko:bool -> Masc.Keeper_memory_age_bins.t option -> string list
(** One Keeper's facts for a row with no count beside it: the fact count, then
    {!ages_clauses}. *)

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
