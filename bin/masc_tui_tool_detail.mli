(** Masc_tui_tool_detail — the field tree drawn under one tool call in the
    Keeper chat's full-calls projection.

    Pure, so the promises the operator reads off the screen are testable
    without a terminal: a JSON payload arrives as structure rather than as one
    line, every label in one tree shares a separator column, and each part of
    a served document is drawn through its own role.

    The colours arrive as an argument rather than out of a theme module. That
    is what keeps this pure: a test passes markers and pins where each role
    lands, and the renderer passes the reader's own theme. *)

type palette = {
  branch : string;  (** the tree's own glyphs *)
  label : string;  (** a field's name *)
  separator : string;  (** the [·] between a name and its value *)
  key : string;  (** an object member's name inside a served document *)
  string_ : string;
  number : string;
  literal : string;  (** [true], [false], [null] *)
  punctuation : string;  (** braces, brackets, colons, commas *)
  reset : string;
}

val plain : palette
(** Every role empty: the text this module drew before it could be styled.
    Tests that pin layout rather than colour read better through it. *)

type value =
  | Text of string
      (** Drawn as it arrives, under the field's own [tone]. *)
  | Document of string
      (** A tool argument or result. Re-served with one member per line and
          each part drawn through its role; a payload that does not parse is
          drawn as [Text] would be, because a single line is already its best
          rendering. *)

type field = {
  fd_label : string;
  fd_value : value;
  fd_tone : string;
      (** The style a [Text] value is drawn in -- empty for the pane's own.
          A field whose value is a reading of state (an outcome, a dispatch
          disposition) names the status colour that reading deserves, which is
          why it is the caller's to choose and not this module's. *)
}

val structured : ?palette:palette -> string -> string
(** [structured value] re-serves a whole JSON object or array with one member
    per line, for reading rather than for parsing back:

    - a string value that is itself a JSON document is unfolded into that
      document, recursively, so a result that carries a result that carries
      a command's output shows the innermost value as structure instead of
      as three layers of escapes;
    - a string that spans lines or holds tabs is drawn as a block under a
      [|] marker, its lines raw and indented under the member that owns
      them, tabs shown as [┊].

    Anything else -- a scalar, a bare word, a payload that does not parse --
    is returned unchanged, because a single-line rendering is already its
    best one. *)

val tree : ?palette:palette -> field list -> string list
(** [tree fields] draws [fields] as one branch per field, in order, with the
    last field closing the tree. A value's own newlines are kept: its first
    line carries the label and the rest are indented under it, so a structured
    payload stays inside the branch that owns it.

    Labels are padded to the widest label in [fields], measured in terminal
    cells, so one tree's separators line up. The padding is per-call: a tree of
    short labels does not inherit another tree's width. *)
