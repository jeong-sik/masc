(** The active conversation's portrait above the Keeper roster. The roster
    keeps at least four selectable rows; the conversation keeps every row. *)
type t = private {
  roster_rows : int;  (** Requested roster budget, including its chrome. *)
  picture_lines : string list;
  placement : Masc_tui_portrait_view.placement option;
}

val band_size : Masc_tui_portrait_view.display -> Masc_tui_keeper_portrait.band_size option
(** Conversation icon budget shared with the Keeper Info header. *)

val prepare :
  Masc_tui_keeper_portrait.cache ->
  display:Masc_tui_portrait_view.display ->
  project:(Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option) ->
  name:string -> portrait:Keeper_portrait_equipment.reading -> rows:int -> cols:int -> t option
(** [rows] is the entire left pane, including its frames. [None] keeps the
    full roster when the portrait cannot fit, its equipment reading is unavailable,
    or colour is disabled.
    [name] is the conversation owner, independently of the roster cursor.
    The caller draws one caption row, [picture_lines], one spacer row, then
    the roster. The placement row is nominal within the requested budget;
    the renderer anchors it to the actual line immediately after the caption,
    including the shared tab strip, before requesting pixels. *)

val shown : name:string -> portrait:Keeper_portrait_equipment.reading -> rows:int -> cols:int -> t option
(** Prepare against the negotiated terminal display and a session cache. *)
