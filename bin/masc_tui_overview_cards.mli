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
(** The lines a row's text wraps to at [cells] cells, one at least. Nothing is
    dropped: the lines joined without their spaces are the text without its
    spaces, and no line is wider than [cells]. *)

val reason_lines : cells:int -> string -> string list
(** One reason the server gives for needing the operator, as the lines it is
    drawn on: wrapped like {!row_lines}, each line in the warning colour. The
    Action needed card and the plain layout draw a reason through this. *)

val reasons_title : int -> string
(** The heading over the reasons, naming how many there are. *)

val plain_reasons :
  indent:string -> inner:int -> rows:int -> string list -> (string option * string) list
(** The reasons as the plain layout draws them, one element to a row: the
    heading {!reasons_title}, the lines of each reason that is drawn, and, when
    some are left out, a last row that says how many. A row is an optional
    style and its text; the lines of a reason carry their own colour. [indent]
    begins each reason line and the note, and a reason line is wrapped to
    [inner] cells with it, so none is wider.

    The reasons drawn are the first ones, whole and in order: as many as fit in
    [rows] rows together with the note. The length of the list is the height
    drawn. It is empty when there is no reason, or when not even the first fits
    under the heading with the note that follows it. *)

val draw :
  inner:int ->
  rows:int ->
  is_selected:('action -> bool) ->
  decisions:('action * string) list ->
  decisions_whole:bool ->
  continuation:('action * string) list ->
  status:(cells:int -> string list) ->
  actions:string list ->
  string list option
(** The cards as lines of exactly [inner] cells, or [None] when they do not fit
    and the caller draws the plain rows instead: [inner] holds fewer than two
    columns, the cards need more than [rows] lines, or [decisions_whole] is
    false. [decisions_whole] says the window holds every decision; a window
    that holds only some is named by its row range in the plain layout's
    heading, which the card title has no place for. The cards are as tall as
    their rows and the two columns end on the same line.

    [actions] are the reasons the server gives for needing the operator, one
    row each, drawn as a card under the status readings. With none, there is
    no card. When the card would make the cards need more than [rows] lines,
    the cards are drawn without it: the footer still counts the reasons. *)
