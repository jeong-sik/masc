(** The Dashboard's readings as titled cards in two columns: what needs a
    decision and what to continue on the left, the status readings on the right
    and, under them, what the server says needs the operator.

    Every row is written out in full. A row is as many lines as its text takes
    at the card's width, so a long Keeper name or the note that a chat is saved
    only for this session is not cut off where the plain layout showed it
    whole. The selected row keeps its band on each of its lines.

    Generic over the action a row opens: the module only asks whether a row is
    the selected one. *)

val row_lines : cells:int -> string -> string list
(** The lines a row's text wraps to at [cells] cells, one at least. A row that
    takes more than one line hangs the later lines two cells in, so it reads as
    one row; a row that fits on a line is as it is, and so is one in a column
    too narrow to leave eight cells of text beside the indent. Nothing is
    dropped: the lines joined without their spaces are the text without its
    spaces, and no line is wider than [cells]. *)

type titles =
  { decisions : string
  ; continuation : string
  ; capacity : string
  ; actions : string
  }
(** The caller owns the language and observation scope of each heading. *)

val draw :
  titles:titles ->
  empty_decisions:string ->
  inner:int ->
  rows:int ->
  is_selected:('action -> bool) ->
  decisions:('action * string) list ->
  decisions_whole:bool ->
  continuation:('action * string) list ->
  status:(cells:int -> string list) ->
  actions:('action * string) list ->
  string list option
(** The cards as lines of exactly [inner] cells, or [None] when they do not fit
    and the caller draws the plain rows instead: [inner] holds fewer than two
    columns, the cards need more than [rows] lines, or [decisions_whole] is
    false. [decisions_whole] says the window holds every decision; a partial
    window uses the plain selectable list instead. The cards are as tall as
    their rows and the two columns end on the same line.

    [actions] are the reasons the server gives for needing the operator, one
    row each, drawn as a card under the status readings. With none, there is
    no card. An unfittable action card returns [None], so the plain window
    retains its selected destination instead of silently dropping the card. *)
