(** Navigation uses the same approval reading as the drawn badge and title. *)

val visible_surface_ring : Masc_tui_types.state -> (Masc_tui_types.surface * string) list
val surface_ring_family : Masc_tui_types.state -> Masc_tui_types.surface -> Masc_tui_types.surface
val visible_surface_ring_index : Masc_tui_types.state -> Masc_tui_types.surface -> int
