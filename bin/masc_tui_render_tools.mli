(** The Tools surface: what the selected Keeper's turn called, and what the
    process has registered.

    Two deliberately separate readings. A registered tool is not evidence
    that a Keeper can call it, so the surface never folds the catalog into
    the turn's own calls.
 *)

open Masc_tui_types

val tools_pane_strip : cols:int -> state -> string
(** The pane selector drawn in the surface header, with the active pane
    marked. *)

val tools_selection_line : cols:int -> state -> string
(** Pinned action target, sharing the exact selection used by Enter/edit.
    The complete reference remains in the scrolling document. *)

val tools_display_lines : ?cols:int -> state -> (string * string) list
(** Every row the surface would draw, before scrolling narrows it, each as
    the style to draw it in paired with its text. The caller measures this
    list to lay the viewport out, so it counts rows rather than entries -- a
    tool whose evidence wraps is more than one row. [cols] defaults to 80;
    pass the viewport width for usage cards, complete metadata wrapping and
    matching physical-row scroll geometry. Rows that already fit retain their
    alignment and card borders; revisions and timestamps remain literal. *)
