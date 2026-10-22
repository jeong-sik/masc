(** Apply Resources responses on the UI state owner fiber. Read results retain their original
    immutable contents; terminal sanitization belongs to the renderer. Catalog keys and metadata remain immutable; terminal display sanitizes copies. Transport, scheduling,
    request clocks and terminal output remain caller-owned. *)

val begin_listing : Masc_tui_types.state -> unit ref
(** Allocate a fresh opaque owner and retire complete-count authority while
    preserving the last report/MCP rows. Call on the UI fiber before dispatch. *)

val listed :
  Masc_tui_types.state ->
  owner:unit ref ->
  (Masc_tui_resource_catalog.listing, string) result ->
  unit
(** Keep the open resource selected across a new listing, including a fixed
    report revision when its report is still listed. If it is absent, clamp the
    cursor and clear the reading that no longer has a listed resource. A report
    missing from a successful complete inventory leaves an explicit notice,
    including its previous read error, until another read or filter selection.
    Filtering alone does not claim server-side removal. A failed
    listing retains the previous inventory and records its error. Partial inventory and per-report diagnostics stay visible in the status line.
    Only the current pending owner may apply success or failure, once. *)

val checks_loaded : Masc_tui_types.state -> unit Masc_tui_fetched.request ->
  (Masc_tui_artifact_checks.inventory, string) result -> unit
(** Settle only the current shared-check read, independently of report bodies
    and MCP inventory. Never creates a confirmation or changes selection. *)

val begin_check : Masc_tui_types.state -> report:Masc_tui_resource_catalog.report ->
  (Masc_tui_artifact_check_action.request, string) result
(** Only a confirmed workspace, complete settled inventory and no pending write
    permit a toggle. Retire cached confirmation authority before dispatch. *)
val check_changed : Masc_tui_types.state -> Masc_tui_artifact_check_action.request ->
  bool
(** Consume the matching pending write once and require a fresh inventory read.
    A retired write cannot update a new owner's view. No receipt is adopted as
    inventory state. The caller reports the outcome and launches that read. *)

val read_done :
  Masc_tui_types.state -> request:Masc_tui_resource_catalog.read_request ->
  (Masc_tui_resource_catalog.reading, string) result -> unit
(** Only the pending key and exact request owner consume the response. Text, metadata and blob payloads remain byte-for-byte
    unchanged in the retained content list. A refused read retains the previous content. *)

val open_selected :
  Masc_tui_types.state -> read:(key:Masc_tui_resource_catalog.key -> unit) -> unit
(** With a selected resource, move focus to its content pane before [read].
    An empty or invalid selection leaves state unchanged and invokes no callback. *)

val select_next_unchecked : Masc_tui_types.state ->
  (Masc_tui_resource_catalog.key option, string) result
(** Select the next unchecked report in the current format/day projection.
    Preserve focus. Return its immutable key for the caller's existing read
    boundary when the detail is focused; this function does not fetch or confirm.
    Unknown authority, a pending check write or incomplete inventories leave
    selection and reading ownership unchanged. [Ok None] also leaves them unchanged. *)

val step_revision :
  Masc_tui_types.state -> direction:Masc_tui_resource_catalog.direction ->
  read:(key:Masc_tui_resource_catalog.key -> unit) -> unit
(** Request the adjacent validated revision of the open report. Does not admit
    a body, synthesize revisions or wrap at an end. MCP reads have no history. *)

val place_search_match : Masc_tui_types.state -> cols:int -> query:string -> count:int -> index:int -> unit
(** Retain the logical match separately from the rendered scroll, whose last
    page may clamp before that row. Record the current reading, query and actual
    pane width for its display mark. Missing or failed readings, invalid
    landings, empty queries and list focus do nothing. *)

val step_text_part : Masc_tui_types.state -> delta:int -> unit
(** Select an original text part for copying. Only focused, admitted Resources
    detail can move; selection clamps at either end and preserves reading state. *)

val select_scope : Masc_tui_types.state -> Masc_tui_resource_catalog.scope -> unit
(** Change the displayed inventory and reconcile selection/read ownership with
    that same projection. Hidden reads lose ownership; no network request. *)
val toggle_today : Masc_tui_types.state -> now:float -> unit
(** Capture today's local date when enabled. The selection stays on that date
    across midnight until toggled again, so cursor actions cannot drift. *)
val toggle_layout : Masc_tui_types.state -> unit
val toggle_presentation : Masc_tui_types.state -> unit
