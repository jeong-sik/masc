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

type cursor_rows = { first_row : int; last_row : int }
(** Indexes in [lines] of the first and the last physical row of one run of
    rows: the same index for one row that fits the width, more than one when
    the run holds more rows or a row wraps. *)

type display =
  { lines : (string * string) list  (** What {!tools_display_lines} returns. *)
  ; cursor : cursor_rows option
        (** The rows of the Skill the list keys act on, on a pane that lists
            Skills: its own row and the rows that say why it was loaded. The
            key handler brings them into view instead of looking for the
            selection colour, and a row that wraps comes in whole. *)
  ; card : cursor_rows option
        (** The rows of the selected Skill's measurement card, under the
            Skill list, so a key that opens the measurements can bring the
            card into view. *)
  ; row_changes : (int * float) list
        (** Each row of [lines] whose time text was built without noting
            when it next reads differently, by its index in [lines], with
            that instant: the Async pane's request ages, on every row a
            request wraps into. Building the display notes none of them;
            the frame notes those it draws ({!drawn_change}). *)
  ; entries : (paged_list * int list) option
        (** The list the pane draws -- the Skill list on Available, the
            request list on Async while no request is open -- with the rows
            of [lines] each of its entries takes, in order: a Skill with its
            group heading and the rows that say why it was loaded, a request
            as it wraps. The first entry counts every row above it too, which
            the window brings in with it. [None] on a pane with no entry in
            such a list. The frame pages that list by {!drawn_page}. *)
  }

val tools_display : ?cols:int -> ?terminal_rows:int -> state -> display
(** {!tools_display_lines} with where the selected Skill's rows are and
    when the rows' deferred time text changes. *)

val drawn_page : display -> rows:int -> (paged_list * int) option
(** The list the pane draws and the page a key moves it by when the frame's
    window is [rows] rows tall: the fewest entries any such window holds
    whole ({!Masc_tui_scroll.items_always_shown}), since a Skill or a request
    can wrap and the cursor counts entries. The frame reports it as the
    list's drawn height. [None] when [entries] is. *)

val drawn_change : display -> (string * string) Masc_tui_rows.t -> float option
(** The earliest instant a row of [row_changes] that the window draws reads
    differently, [None] when the window draws none of them. The window is
    cut from the display's [lines]. The frame notes this instant
    ({!Masc_tui_value.Redraw.note_change_at}), so a row scrolled out of the
    window asks for no redraw. *)

val tools_diagnostics_copy_text : state -> string option
(** What the Available section's copy holds: the Keeper, its diagnostics
    with whole digests, and the selected Skill's identity with its whole
    revision, one per line. [None] while no Effective Keeper Surface is
    read. *)
