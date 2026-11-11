(** Memory observations and fact explorer for the MASC TUI.

    Decomposed from masc_tui_render.ml.
    The selected Keeper is read through five independent axes: fact age,
    snapshot save, source invalidation, Librarian processing and workspace World.
    The overview and cursor share the same bounded row projection. Full input,
    source and processing evidence remains in the captured reading and facts.

    Pure by construction: no terminal I/O, no mutation, no unhandled exceptions. *)

open Masc_tui_types

type memory_state = Masc_tui_types.memory_state =
  | Memory_ordinary
  | Memory_warning
  | Memory_degraded
  | Memory_no_current
  | Memory_source_only
  | Memory_starving
  | Memory_read_error

(** #39831: the Librarian clauses in the block under the selected keeper on
    the Memory table, and whether the default view draws each one. A lag or a
    failure count above zero is shown; a zero waits behind the [d] detail
    toggle. A lag that could not be read ([Row_lag None]) is shown, never
    folded into zero. *)
type memory_row_kind =
  | Row_lag of int option
  | Row_librarian_failures of int

type memory_row_visibility =
  | Shown_by_default
  | Detail_only

val memory_row_visibility : memory_row_kind -> memory_row_visibility

val facts_keeper_label : ko:bool -> string option -> string
(** How the facts title names the keeper it is reading. The fleet view is asked
    for as "*" and read as a phrase. *)

type facts_reading =
  | Facts_unread of { reading : string }
  | Facts_loaded of
      { total : int
      ; filter_label : string
      ; query_label : string
      }

val facts_title :
  ko:bool ->
  cols:int ->
  screen:string ->
  keeper:string ->
  reading:facts_reading ->
  timestamp:string ->
  badge:string ->
  string
(** The facts title row of a frame [cols] wide. Its total counts the current
    filtered rows, including invalidation rows, rather than the stores' total
    knowledge. Category counts separately retain unknown store/fleet coverage.
    The breakdown and the sort belong to the row under it, which this
    module also draws. The title is the narrow line and the clock and the
    connection badge sit at its end, so a fact spelled here and there goes off
    the right edge. The clock and the badge are never shortened; the keeper's
    name folds to its floor and the counts and filters are cut before the name
    goes further ({!Masc_tui_ansi.detail_heading}). *)

val storage_size : int -> string
(** Observed rendered-knowledge bytes as B/KiB/MiB. Token mode separately
    marks its conversion as an estimate. *)

val memory_fact_age_label : float -> string
val memory_category_filter_text : ko:bool -> memory_category_filter -> string
val memory_fact_row_line : ko:bool -> ?is_fleet:bool -> ?sort:memory_sort_order -> cols:int -> memory_fact_row -> string
val memory_fact_detail_lines : ko:bool -> cols:int -> memory_fact_row -> string list
(** Full claim and provenance rows, wrapped to the frame of a [cols]-column
    terminal. Each returned row occupies one scrollable display row. *)

val memory_facts_scope_lines : ?full:bool -> cols:int -> state -> string list
(** Read failures, retained observations and partial store scope shared by
    the fact list and full fact reading. [full] wraps the complete causes;
    the list keeps each cause to one row. *)

val memory_fleet_header_rows : cols:int -> state -> string list
(** Full fleet observation rows for the diagnostic and captured reading:
    Ordinary, Source, Librarian and World retain their independent counts. *)

val memory_overview_reading : cols:int -> state -> Masc_tui_detail_reading.t
(** A captured, scrollable fleet summary and selected Keeper health reading.
    It does not follow later selection or refreshes. *)
val memory_action_reading :
  cols:int -> state -> action:Masc.Operator_action_reason.t -> Masc_tui_detail_reading.t option
(** Capture the exact observed Keeper health without moving the live cursor.
    Keep the original action beside this separate health observation.
    A missing exact Keeper observation and read errors remain in the capture;
    [None] means the action is not a Memory destination. *)

val memory_overview_scrolled : cols:int -> budget:int -> ?cursor:int -> state -> scrolled
(** The overview's scroll layout at [cols], with summary, rejected Keeper
    rows and selected Keeper cards limited to the same body [budget] used by
    the renderer. Short frames use the same compact cards for both counts. *)

val render_memory_body :
  cols:int ->
  budget:int ->
  state ->
  push:(string -> unit) ->
  push_styled:(style:string -> string -> unit) ->
  push_selected:(string -> unit) ->
  push_divider:(unit -> unit) ->
  push_empty:(unit -> unit) ->
  unit

val memory_fact_list_floor_rows : int
(** How many rows the fact list keeps before the detail below it takes any --
    one of which the window reading takes when the list overflows. A fact has
    no length limit, so without this floor one long fact left a browser of a
    few hundred facts showing a single row. *)

val memory_facts_content_height : cols:int -> budget:int -> cursor:int -> state -> int
val memory_facts_pane_cols : state -> int -> int
(** Fact-pane width shared by rendering and cursor/page geometry. *)
(** The fact list's height after reserving the selected detail, filters and
    errors. [budget] excludes the surrounding surface chrome. *)

val render_memory_facts_body :
  cols:int ->
  budget:int ->
  state ->
  push:(string -> unit) ->
  push_styled:(style:string -> string -> unit) ->
  push_selected:(string -> unit) ->
  push_divider:(unit -> unit) ->
  push_empty:(unit -> unit) ->
  unit
