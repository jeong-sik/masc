(** The Tools surface: what the selected Keeper's turn called, and what the
    process has registered.

    Two deliberately separate readings. A registered tool is not evidence
    that a Keeper can call it, so the surface never folds the catalog into
    the turn's own calls.
 *)

open Masc_tui_types

val tools_pane_strip : cols:int -> state -> string
(** The pane selector drawn in the surface header, with the active pane
    marked. The volume reading is a child of the catalog, not another tab. *)

val tools_selection_line : cols:int -> state -> string
(** Pinned action target, sharing the exact selection used by Enter/edit.
    The complete reference remains in the scrolling document. *)

val skill_source_picker_page : state -> terminal_rows:int -> int
(** The visible source rows after the existing Tools frame and the picker's
    own prefix. Rendering and selection use this same budget. *)

val tools_display_lines : ?cols:int -> ?terminal_rows:int -> state -> (string * string) list
(** Every row the surface would draw, before scrolling narrows it, each as
    the style to draw it in paired with its text. The caller measures this
    list to lay the viewport out, so it counts rows rather than entries -- a
    tool whose evidence wraps is more than one row. [cols] defaults to 80;
    pass the viewport width for usage cards, complete metadata wrapping and
    matching physical-row scroll geometry. Rows that already fit retain their
    alignment and card borders; revisions and timestamps remain literal,
    except on the Available section, which draws the selected Skill's
    revision and its diagnostics' digests by their first twelve characters.
    Each pane starts with its observed content and read notices. Static
    scope and column legends are in the Tools section's Help binding. *)

type display =
  { lines : (string * string) list  (** What {!tools_display_lines} returns. *)
  ; cursor_row : int option
        (** The index in [lines] where the Skill the list keys act on starts
            (its first row when it wraps), on a pane that lists Skills. The
            key handler brings this row into view instead of looking for the
            selection colour. *)
  }

val tools_display : ?cols:int -> ?terminal_rows:int -> state -> display
(** {!tools_display_lines} with where the selected Skill's row is. *)

val tools_diagnostics_copy_text : state -> string option
(** What the Available section's copy holds: the Keeper, its diagnostics
    with whole digests, and the selected Skill's identity with its whole
    revision, one per line. [None] while no Effective Keeper Surface is
    read. *)
