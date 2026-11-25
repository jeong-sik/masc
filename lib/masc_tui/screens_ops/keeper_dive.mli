(** Keeper Detail tab renderer shared between full-width Focus Mode
    ([model.nav.zoomed = true]) and the side-by-side right detail pane of
    [Screen_keepers].

    Tabs (6 consolidated tabs):
    1. [Keeper_chat]: [Origin_bare]/[Origin_inline]/[Origin_row] transcript via
       [Markdown] + [Code_lexer], 1-line folded Thinking, 1-line collapsible
       Tool Cards, honest pending transmission rows, and a single 1-line Keeper
       Status Strip.
    2. [Keeper_trace]: Consolidated 4-section trace inspector ([Trace_context]
       5-subtab per-turn context inspector, [Trace_tool_calls] tool execution
       history, [Trace_metrics_logs] live metrics & sandbox logs, and
       [Trace_runtime] runtime trace JSON tree) switched via [t] or [{]/[}].
    3. [Keeper_memory]: Scoped Temporal Memory Diff Scrubber ([24h]/[7d]/[30d]/rev),
       retrieval heat ([HOT]/[WARM]/[COLD]), and Librarian writer recovery acts.
    4. [Keeper_work_sandbox]: Assigned Tasks, Schedules (with last wake
       disposition), recent Board posts + quarantine recovery, Candle balance +
       decay gauge, Portrait Ornaments, and Sandbox summary ([p] Probe, [o]
       Infra > Sandboxes).
    5. [Keeper_config]: Scoped In-TUI Keeper Settings rendered via
       [Masc_tui_ui.Form] with masked secrets and TOML diff preview.
    6. [Keeper_identity]: OAuth attached tools and GitHub device/PAT identity. *)

type history_layout
(** Everything the chat history rows of one keeper depend on besides the
    messages: the keeper, the width, the theme, the language, the time zone,
    the origin mode, the tools mode, the thinking mode, the runtime names
    and the cut replies. *)

val history_layout_of :
  model:Masc_tui_store.Model.t ->
  keeper_name:string ->
  width:int ->
  history_layout

type transcript_row
(** One row of the chat transcript. *)

(** The history rows of the keepers whose chat was drawn last, one keeper
    per slot. [rows] lays the messages out the first time it is asked for a
    layout and messages, and returns the same rows while both are still
    equal. A frame that draws a chat therefore does not lay its stored
    messages out again; a new message, or another width, theme, language,
    time zone, origin mode, tools mode or thinking mode, lays them out again
    in that keeper's slot. A keeper that was not kept takes a slot and, when
    every slot is taken, the keeper drawn longest ago loses theirs
    ([evictions]). The program that runs the TUI creates one and hands it to
    {!render_tabs_body}. *)
module History_rows : sig
  type t

  type stats = {
    capacity : int;
    entries : int;
    hits : int;
    misses : int;
    evictions : int;
  }

  val default_capacity : int

  val create : ?capacity:int -> unit -> t

  val stats : t -> stats

  val rows :
    t ->
    layout:history_layout ->
    messages:Masc_tui_protocol.Wire_fleet.chat_message list ->
    transcript_row list
end

val render_tabs_body :
  ?history_rows:History_rows.t ->
  embedded:bool ->
  name:string ->
  tab:Masc_tui_core.Nav.keeper_tab ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
(** [~history_rows] keeps the chat history rows from one call to the next.
    Without it every call lays the history out again and draws the same. *)
