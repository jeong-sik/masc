(** Memory health readings and axis cells for Keeper secondary row (RFC-0511 A3). *)

type lag =
  | Lag_unmeasured
  | Lag of int

type gap =
  | No_gap
  | Gap of
      { first_atom : int
      ; past_last_atom : int
      }
  | Gap_unmeasured

type t =
  | Unknown
  | No_row
  | Refused of string
  | Row of
      { state : Masc_tui_types.memory_state
      ; lag : lag
      ; gap : gap
      ; digest_at : float option
      ; updated_at : float option
      ; added : int
      ; removed : int
      ; source_invalidations : int
      ; age_bins : Masc.Keeper_memory_age_bins.t option
      ; pass_end : Masc.Tui_decode_memory_health.memory_librarian_pass_end option
          (** How the librarian's last pass ended, from the same row. *)
      ; admission_wait : Masc.Keeper_librarian_pending.admission option
          (** What the last explicit-admission pass left unfinished, independent of the durable pass. *)
      }

type index

val unread_lag : Masc.Tui_decode_memory_health.memory_librarian_health -> int option

val index_of_snapshot : Masc.Tui_decode_memory_health.memory_health_snapshot option -> index

val find : index -> keeper_name:string -> t

val cells : now:float -> t -> Masc_tui_keeper_axis_cell.t list

val lag_cell : t -> Masc_tui_keeper_axis_cell.t option
(** The lag cell of {!cells}. A reading with no row has no lag, so it gives the
    cell that stands for the whole reading in {!cells}, or [None] for a
    snapshot with no row for the Keeper. *)

(** {1 Cells of the memory and age views} (RFC-0515 §2.4) *)

(** One value of a reading, or why there is none. *)
type 'a field =
  | Measured of 'a
  | Unmeasured  (** The Keeper's row came without the value: not measured. *)
  | No_snapshot  (** The row says the Keeper has no memory snapshot to have it. *)
  | Snapshot_unknown  (** The reading is {!Unknown}. *)
  | Row_absent  (** The reading is {!No_row}. *)
  | Row_refused  (** The reading is {!Refused}. *)

val pass_end : t -> Masc.Tui_decode_memory_health.memory_librarian_pass_end field
val digest_at : t -> float field

val updated_at : t -> float field
(** The server stamps an update exactly when the snapshot is present, so a row
    without one is {!No_snapshot}. *)

val age_bins : t -> Masc.Keeper_memory_age_bins.t field

val peak_lag : t list -> int
(** The most unread turns among the readings that measured them; 0 when none
    did. The caller passes the readings of the Keepers it draws, and the lag
    bars are drawn against it. *)

val pass_word : Masc.Tui_decode_memory_health.memory_librarian_pass_end -> string
(** How the librarian's last pass ended, in one word for the Memory pane and
    the memory view. *)

val pass_cell : t -> Masc_tui_keeper_axis_cell.t
val updated_cell : now:float -> t -> Masc_tui_keeper_axis_cell.t
val fact_ages_cell : t -> Masc_tui_keeper_axis_cell.t
(** The ● cell of the memory view (the pass end), the ● cell of the age view
    (how long ago the snapshot changed) and the ◂ cell of the age view (the
    age strip). A value the row came without draws
    {!Masc_tui_keeper_age_ladder.unmeasured_mark}. A Keeper without a memory
    snapshot, or without a row, draws the no-value mark; {!Unknown} draws
    [mem ?] and {!Refused} draws [mem !]. None draws a value in their place.
    The views draw their own value for a measured one and for a missing row. *)
