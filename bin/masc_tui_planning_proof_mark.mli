(** The marks the Planning list draws in its JUDGE column, and the words that
    say what to do about each one.

    Here rather than in the renderer so the column and its legend cannot drift:
    both read the same glyph from the same function, and a state added to
    {!Masc.Tui_decode.goal_proof} stops this module compiling until it is given
    a mark and a word. Colour is the caller's. *)

val glyph : Masc.Tui_decode.goal_proof -> string
(** The mark for one goal's verdict, uncoloured. An idle goal -- nothing asked
    of the judge -- gets a blank, so an unreviewed row carries no mark. *)

val tone : Masc.Tui_decode.goal_proof -> Masc_tui_value.Mark.t option
(** The status the mark stands for (RFC tui-one-screen-grammar 7.2), so the
    caller colours it with that status's tone; [None] for the idle blank. *)

val legend_for : ko:bool -> (string * string) list
(** Every mark that is not a blank, paired with its word, in the order a goal
    travels: asked, approved, refused, outrun by its own criterion, unreadable. *)

val legend_rows :
  ko:bool -> max_cells:int -> max_rows:int -> Masc.Tui_decode.goal_proof list -> string list
(** Complete, uncoloured legend rows, including the JUDGE label and continuation
    indent. Wraps within the frame's content-cell budget. Returns no rows when
    the full legend cannot fit the available height, the label leaves no room
    for text, or the verdicts need no legend. Never truncates an explanation. *)
