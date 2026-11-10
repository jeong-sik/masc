val change_count : Masc_tui_types.state -> keeper_name:string -> int

val summary_lines :
  Masc_tui_types.state -> cols:int -> max_lines:int -> now:float ->
  keeper_name:string -> string list
(** Compact preview using the shared facts reading and browser ordering.
    Its only controls open the corresponding shared Memory browser page. *)

val changes_lines :
  Masc_tui_types.state -> cols:int -> max_lines:int -> now:float ->
  keeper_name:string -> string list
(** Committed changes in the shared Memory browser. The first visible event
    is selected for the immutable full reading. Sources retain partial,
    stale, failed and missing observations independently. *)

val change_reading :
  Masc_tui_types.state -> keeper_name:string -> Masc_tui_detail_reading.t option
(** Complete prior and successor claims of the selected observed event.
    This is a captured reading; it never authorizes a memory mutation. *)
