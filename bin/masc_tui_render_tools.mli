(** The Tools surface: what the selected Keeper's turn called, and what the
    process has registered.

    Two deliberately separate readings. A registered tool is not evidence
    that a Keeper can call it, so the surface never folds the catalog into
    the turn's own calls.

    Lifted whole out of masc_tui_render.ml. Twelve definitions moved; these
    two are what the rest of the renderer calls, and the rest of the module
    is reachable only through them. That is the point of the interface: the
    file it came from had 371 top-level definitions in one scope, so nothing
    stopped a helper written for one surface from being read by another. *)

open Masc_tui_types

val tools_pane_strip : state -> string
(** The pane selector drawn in the surface header, with the active pane
    marked. *)

val tools_display_lines : state -> (string * string) list
(** Every row the surface would draw, before scrolling narrows it, each as
    the style to draw it in paired with its text. The caller measures this
    list to lay the viewport out, so it counts rows rather than entries -- a
    tool whose evidence wraps is more than one row. *)
