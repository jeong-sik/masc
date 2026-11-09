(** The active conversation's portrait above the Keeper roster. The roster
    keeps at least four selectable rows; the conversation keeps every row. *)
type t = private {
  roster_rows : int;  (** Requested roster budget, including its chrome. *)
  picture_lines : string list;
  placement : Masc_tui_portrait_view.placement option;
}

type figure =
  | Face  (** The face-centred identity thumbnail (conversation header). *)
  | Whole_body  (** The whole figure with its outfit (Keepers list). *)

val band_size : Masc_tui_portrait_view.display -> Masc_tui_keeper_portrait.band_size option
(** The face's box, shared with the Keeper Info header. A [Whole_body]
    uses {!Masc_tui_keeper_portrait.whole_body_band_size}. *)

val prepare :
  Masc_tui_keeper_portrait.cache ->
  display:Masc_tui_portrait_view.display ->
  project:(Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option) ->
  figure:figure ->
  name:string -> portrait:Keeper_portrait_equipment.reading -> rows:int -> cols:int -> t option
(** [rows] is the entire left pane, including its frames. [None] keeps the
    full roster when the portrait cannot fit, its equipment reading is unavailable,
    or colour is disabled.
    [name] is whose portrait it is: for [Face] the conversation owner,
    independently of the roster cursor; for [Whole_body] the selected Keeper.
    The caller draws one caption row, [picture_lines], one spacer row, then
    the roster. The placement row is nominal within the requested budget;
    the renderer anchors it to the actual line immediately after the caption,
    including the shared tab strip, before requesting pixels. *)

val shown :
  figure:figure -> name:string -> portrait:Keeper_portrait_equipment.reading -> rows:int -> cols:int
  -> t option
(** Prepare against the negotiated terminal display and a session cache. *)
