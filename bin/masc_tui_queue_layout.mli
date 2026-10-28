(** Geometry for an active queue beside a read-only conversation preview.
    Dimensions are terminal cells and body rows, after shared chrome. *)
type preference = Adaptive | Expanded
type placement =
  | Full
  | Side of { context_cols : int; queue_cols : int }
  | Bottom of { context_rows : int; queue_rows : int }

val toggle : preference -> preference
val choose :
  preference -> has_context:bool -> cols:int -> body_rows:int ->
  queue_fixed_rows:int -> placement
(** Side panes each retain twice the chat's hard minimum width, giving prose
    room beyond the emergency viewport. Otherwise reserve a caption, three
    conversation rows and a divider above Queue, only when Queue can still
    show its fixed facts and three list rows. Detail always uses Full. *)
val queue_rows : body_rows:int -> placement -> int

val panes :
  placement -> cols:int -> first_row:int -> body_rows:int -> Masc_tui_pane_selection.layout
(** Separate copy rectangles for the conversation preview and the active queue,
    including the shared chrome's three leading and two trailing rows. *)
