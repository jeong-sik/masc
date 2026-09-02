(** Masc_tui_tool_detail — the field tree drawn under one tool call in the
    Keeper chat's full-calls projection.

    Pure, so the two promises the operator reads off the screen are testable
    without a terminal: a JSON payload arrives as structure rather than as one
    line, and every label in one tree shares a separator column. *)

val structured : string -> string
(** [structured value] re-serves a whole JSON object or array with one member
    per line. Anything else -- a scalar, a bare word, a payload that does not
    parse -- is returned unchanged, because a single-line rendering is already
    its best one. *)

val tree : (string * string) list -> string list
(** [tree fields] draws [fields] as one branch per field, in order, with the
    last field closing the tree. A value's own newlines are kept: its first
    line carries the label and the rest are indented under it, so a structured
    payload stays inside the branch that owns it.

    Labels are padded to the widest label in [fields], measured in terminal
    cells, so one tree's separators line up. The padding is per-call: a tree of
    short labels does not inherit another tree's width. *)
