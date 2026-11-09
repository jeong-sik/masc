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
