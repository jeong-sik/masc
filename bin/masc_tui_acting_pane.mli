(** The Activity pane: recent observed keeper activity, beside whatever
    surface is up.

    The observer feed already reaches the TUI for the whole session, and the
    Activity surface draws it full-screen. This pane projects the same held
    events into a column on the right of any surface, so a reader in a keeper
    chat or on the board sees the fleet move without leaving.

    Two tabs. [Tab_fleet] is the feed: one row per keeper ordered by who acted
    last, then the keeper the cursor is on with the calls of its newest feed
    record and the records before it. [Tab_changes] is the files that keeper changed
    in its workspace, newest first, as the Changes surface lists them, kept
    current from the feed.

    Nothing here performs I/O or reads TUI state. The caller hands in the
    facts as it holds them and gets back rows of toned spans; the renderer
    paints tones through the theme. Width and visibility follow the roster
    pane's contract: the terminal measures, the reader decides, and a
    decision survives a resize. *)

val pane_cols : int
(** The columns the pane takes when it shows. *)

val reading_cells : int
(** The cells a fleet row's reading gets, after the mark, the name and the gap.
    Every reading fills it exactly -- the state, tool, calls and token columns
    add up to this and blank columns are spaces -- so the figures line up down
    the list. Exported so a test can hold that sum without restating it. *)

val threshold_cols : int
(** The width from which a surface can afford the pane beside it. The pane
    plus what the roster pane leaves a surface, so the two panes sharing one
    screen leave the surface no narrower than the roster alone would. *)

val shown : hidden:bool -> cols:int -> bool
(** [hidden] is the reader's answer, [cols] the terminal's. Both must agree. *)

val toggle_hidden : hidden:bool -> cols:int -> bool option
(** Toggle the reader's preference only where the pane can actually show.
    [None] below {!threshold_cols} leaves the preference untouched, so a key
    with no visible effect cannot surprise the reader after a later resize. *)

val content_cols : hidden:bool -> cols:int -> int
(** What the surface beside the pane lays out against. *)

(** Which of the pane's two readings is up. *)
type tab =
  | Tab_fleet
  | Tab_changes

val tab_label : tab -> string
val next_tab : tab -> tab

(** The feed's state as the header states it. *)
type feed =
  | Feed_off  (** no server has answered yet *)
  | Feed_opening
  | Feed_live of int  (** frames received; only transport state is displayed *)
  | Feed_closed of string  (** why *)

(** One keeper as the fleet block draws it. [mark] is the one-cell health
    glyph the roster draws ({!Masc_tui_keeper_mark}); [mark_tone] is the
    colour the caller reads out of the same health. [health] is that same
    reading. A gone process marks an unsettled feed record with [!]; every
    other unsettled record wears [~], without asserting a current turn. *)
type keeper = {
  name : string;
  mark : string;
  mark_tone : tone;
  health : Masc.Tui_decode.keeper_health_reading option;
}

(** A colour the renderer resolves through the theme. Names a reading, never
    an SGR code. *)
and tone =
  | Plain
  | Dim
  | Accent
  | Ok
  | Warn
  | Bad
  | Info

type approval = {
  approval_keeper : string;
  approval_tool : string;
}

(** One file the selected keeper changed, as the Changes tab draws it. The
    caller reads it out of the server's file-change record: the address the
    Changes surface shows, what kind of write it was, whether it landed, and
    the line range the record carries when it carries one. *)
type file_kind =
  | File_edited
  | File_written

type file_row = {
  file_path : string;
  file_kind : file_kind;
  file_succeeded : bool;
  file_at : float;
  file_where : string option;  (** the range label, [L12-40], when known *)
}

(** What is known about the selected keeper's changes right now. The four
    states are the fetch helper's four, named here so the pane answers each
    without knowing the helper. *)
type changes =
  | Changes_absent  (** no keeper selected, or never asked *)
  | Changes_loading
  | Changes_failed of string
  | Changes_ready of {
      keeper : string;
      files : file_row list;  (** newest first *)
      fetched_at : float;
      window_hours : float;
      calls : int;  (** tool calls the window held, changes or not *)
      over_budget : int;  (** changes the log kept no text for *)
      malformed : int;
    }

(** How much of the fleet the Recent tab draws. Beside the Keepers roster
    every fleet row would be a roster row said twice, so there only the
    selected keeper's record draws, under the rows of keepers waiting on an
    approval, which the roster does not name; beside any other surface the
    whole fleet does. *)
type scope =
  | Whole_fleet
  | Selected_only

type input = {
  now : float;
  tab : tab;
  scope : scope;
  feed : feed;
  keepers : keeper list option;
      (** [None] until this workspace's keeper files have been read: the header
          says the roster is not loaded rather than counting no keepers *)
  selected : string option;
      (** the keeper the cursor is on; on the Recent tab the most recently
          observed keeper stands in when there is none *)
  approvals : approval list;  (** pending, any keeper *)
  chunks : Masc_tui_acting.chunk list;
      (** Event-derived projection, newest first; all presentation inputs above
          remain live independently of chunk reuse. Ignored on Changes. *)
  changes : changes;  (** the selected keeper's, for the changes tab *)
}

type span = {
  text : string;
  tone : tone;
}

type line = span list

(** What a mouse press on a drawn row can act on. The renderer keeps the
    targets of the last frame beside its rows, so a click answers what was
    on screen, not what a later frame would draw. *)
type row_target =
  | Target_none  (** legend, rule, indicators, padding, focus rows, status rows *)
  | Target_next_tab  (** the header row: a press shows the other tab *)
  | Target_keeper of string  (** a fleet row: the keeper it names *)
  | Target_more
      (** the fold line: the fleet rows the overview layout left out; a press
          scrolls into the full list *)
  | Target_file of int
      (** a changes row: the index of the file in [Changes_ready.files] *)
  | Target_calls of string
      (** a call row or an earlier-turn row in the focus block: the keeper
          whose calls it draws; a press opens that keeper's calls surface *)

type rendering = {
  rows : line list;
  targets : row_target list;  (** one per row, in the same order *)
  scroll_max : int;
      (** the largest [scroll] that still shows content: zero when everything
          fits, so a wheel over a short pane moves nothing *)
}

val lines : rows:int -> cols:int -> scroll:int -> input -> rendering
(** Exactly [rows] lines, each exactly [cols] display cells once its spans
    are joined: a line that would overflow is cut at the right edge, a short
    one is padded, and rows the content does not need are blank. The header
    row carries the two tabs and the feed's transport state on both tabs.
    The Recent tab reserves a second header row for {!legend}. Changes keeps
    its single header row.

    A row states less before it clips a figure: an earlier-turn row gives up
    its cost, then the token parts; the focus header gives up the long form
    of its state word.

    Recent tab under [Selected_only]: the fleet rows of keepers waiting on
    an approval, then the selected keeper's focus block, windowed like the
    Changes tab. The focus header names a settled turn by its number alone;
    an unsettled record spells its state. Under [Whole_fleet], two layouts.
    At [scroll = 0] the overview: the fleet takes at
    most half the rows below the header when the focus block has something to
    show, a fold line counts the keepers left out, and the focus block takes
    the rest. Any other [scroll] (clamped to [scroll_max]) is the full list --
    every fleet row, the rule, every focus row -- windowed from that offset,
    with an [↑ N more] row where content is above and a [↓ N more] row where
    it is below, when indicators leave room for content. A single available
    body row shows the selected content directly. When everything fits the two layouts are the same list and
    no fold or indicator draws.

    Changes tab: a status row for the keeper and the fetch, then one row per
    file, windowed the same way. *)

val keeper_state_text :
  health:Masc.Tui_decode.keeper_health_reading option ->
  approval:string option ->
  Masc_tui_acting.chunk option ->
  span list
(** The fleet row's recent observation: approval first, then the record's
    glyph ([~] unsettled, [!] unsettled with the process gone, the settled
    mark otherwise) and its words: the newest tool and the observed count
    ([4+ calls], [no calls yet]) before a settle, the settle's count
    ([12 calls]) and the tokens after. Unknown settled counts stay unknown.
    No clock: the age of the newest event is on the focus header. *)

val tokens_text : int option * int option -> string
(** Input and output tokens as two parts when both are known
    ([73.9k+358 tok]), one figure when one is ([412 tok]); empty when
    neither is. *)

val tokens_sum_text : int option * int option -> string
(** The same tokens summed ([74.2k tok]), for a row that cannot afford the
    parts. *)

val legend : string
(** The legend row, as drawn. *)

val age_text : now:float -> float -> string
(** How long ago, in the feed's own duration shape ([12.4s], [2m05s]). *)
