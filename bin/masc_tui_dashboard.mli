(** Responsive operator Dashboard. A selection names a destination, never a
    row index into a changing snapshot. Rendering has no runtime effects. *)
type section = Attention | Work | Goals | Keepers | Usage
val sections : section list
val next : section -> section
val previous : section -> section
val label : section -> string

type card = {
  section : section;
  title : string;
  summary : string;
  details : string list;
  status : Masc_tui_theme.status;
}

val render :
  width:int -> height:int -> selected:section ->
  palette:Masc_tui_terminal_palette.t option -> card list -> string list
(** Wide viewports arrange two pairs and a Usage band. Compact viewports
    retain every destination and expand the selected card. Content is wrapped
    in terminal cells; omitted detail is counted, never presented as absent. *)
