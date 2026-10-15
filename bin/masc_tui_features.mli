(** The feature sheet's rows and the lines [/features] draws.

    One list of what this TUI can do -- a feature, one sentence, and the
    door spelled the way you type it. Read by the command handler and by the
    test that checks every door against the machine that answers it. *)

type opener =
  | Command of string  (** the word after the slash; checked against the parser *)
  | Key of string  (** a key as the key table spells it *)
  | Surface of string  (** a route, named the way the help sheet names it *)
  | Token of string  (** a wire name or a code-block fence, proven outside the TUI *)

type row = {
  opener : opener;
  description : string;  (** one sentence; long rows wrap, never cut *)
}

val opener_text : opener -> string
(** The opener as it is typed or named, without decoration. *)

val opener_cells : int
(** The column the sentence starts at. A wider opener keeps the minimum two
    spaces and pushes its own sentence right, the way the help sheet's long
    usages do. *)

val sections : (string * row list) list
(** Named groups, drawn in order. *)

val all_rows : row list
(** Every row, for the test that checks the openers. *)

val lines : width:int -> string list
(** The sheet's body at [width] inner cells, as plain text (no ANSI escapes,
    so rows pass through [Keeper_chat.terminal_safe_text] unchanged): section
    headings with a leading diamond, openers and wrapped sentences after
    them. *)
