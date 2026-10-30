(** Pure core of the "advance until the screen settles" judgement. No machine,
    no ROM: the lane feeds it fingerprint strings (the coarse screen view) and
    reads back whether the screen is moving and when it has settled. *)

type config = {
  interval : int;  (** frames between fingerprints *)
  stable_needed : int;  (** consecutive equal fingerprints that mean "settled" *)
  cell_threshold : int;  (** differing cells at or below this count as "equal" *)
}

val default : config

(** Cells that differ between two fingerprints. Fingerprints of different
    lengths are different screens entirely. *)
val differing_cells : string -> string -> int

(** Folding state while the lane steps. *)
type fold = { last : string; stable_run : int; saw_change : bool }

val initial : string -> fold

(** Feed the next fingerprint: a difference above the threshold resets the
    stable run and marks movement; an equal-or-near-equal one grows it. *)
val feed : config -> fold -> string -> fold

(** Whether the fold has settled — the stop condition for the lane's loop. *)
val settled : config -> fold -> bool

(** Whether the screen ended up different from where the run started. False
    with a settled screen is the "this scene waits for a key" signal. *)
val changed : config -> string -> fold -> bool

(** Replay a whole fingerprint list through [feed] — the test surface. *)
val replay : config -> string list -> fold
