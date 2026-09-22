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
(** The columns the narrow pane takes. *)

val wide_pane_cols : int
(** The columns the wide pane takes: the narrow pane's, plus eighteen that
    go to the fleet row's name column and the call row's age. *)

val reading_cells : int
(** The cells a fleet row's reading gets, after the mark, the name and the gap.
    Every reading fills it exactly -- the state, tool, calls and token columns
    add up to this and blank columns are spaces -- so the figures line up down
    the list. Exported so a test can hold that sum without restating it. *)

val threshold_cols : int
(** The width from which a surface can afford the pane beside it. The pane
    plus what the roster pane leaves a surface, so the two panes sharing one
    screen leave the surface no narrower than the roster alone would. *)

val wide_threshold_cols : int
(** The width from which a surface can afford the wide pane: the wide pane
    plus the same floor {!threshold_cols} leaves. *)

(** The reader's answer to how the pane should sit beside a surface. *)
type layout =
  | Narrow
  | Wide
  | Hidden

val drawn_cols : layout:layout -> cols:int -> int
(** The columns the pane takes beside a terminal [cols] wide: the layout the
    reader chose when the terminal holds it, the narrow pane when a wide
    choice meets a terminal that holds only the narrow one, and none when
    hidden or when not even the narrow pane fits. The choice survives the
    resize; a wider terminal draws it again. *)

val next_layout : layout:layout -> cols:int -> layout option
(** Ctrl-L: narrow, wide, hidden, in turn. A terminal that holds the narrow
    pane but not the wide one goes narrow to hidden. [None] below
    {!threshold_cols} leaves the choice untouched, so a key with no visible
    effect cannot surprise the reader after a later resize. *)

val layout_label : layout -> string

val content_cols : layout:layout -> cols:int -> int
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

(** The order the focus block lists the newest record's calls in. The two
    receipt orders are what the fold holds, forwards and backwards; the other
    two are stable sorts over receipt order, so ties keep it. A call still
    out has no duration and sorts after every call that has one. The heading
    over the calls names the order that is up. *)
type call_order =
  | Oldest_first
  | Newest_first
  | Longest_first
  | By_tool

val call_order_label : call_order -> string
val next_call_order : call_order -> call_order

type input = {
  now : float;
  tab : tab;
  scope : scope;
  feed : feed;
  keepers : keeper list option;
      (** [None] until this workspace's keeper files have been read: the header
          says the roster is not loaded rather than counting no keepers *)
  keepers_error : string option;
      (** A failed read makes the count unavailable. Retained rows remain
          usable for navigation; their presence does not prove a full count. *)
  selected : string option;
      (** the keeper the cursor is on; on the Recent tab the most recently
          observed keeper stands in when there is none *)
  approvals : approval list;  (** pending, any keeper *)
  chunks : Masc_tui_acting.chunk list;
      (** Event-derived projection, newest first; all presentation inputs above
          remain live independently of chunk reuse. Ignored on Changes. *)
  changes : changes;  (** the selected keeper's, for the changes tab *)
  call_order : call_order;
  expanded : (string * Masc_tui_acting.call_key) list;
      (** The calls whose detail is open, by keeper and call key. An open
          call draws three rows under its own: its disposition, receipt age
          and schedule in words, then the input and output previews the
          producer sent, one row each. *)
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
      (** an earlier-turn row in the focus block: the keeper whose calls it
          draws; a press opens that keeper's calls surface *)
  | Target_call of string * Masc_tui_acting.call_key
      (** a call row, or one of an open call's detail rows: the keeper and
          the call; a press opens the call's detail or closes it *)
  | Target_call_order  (** the heading over the calls: a press turns the order *)

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

    The focus block, under either scope, is the keeper's header, then --
    when the record names calls -- a heading naming their order, the calls
    in that order with an open call's three detail rows under it, then the
    earlier turns. A call row wears the record glyph, or the failure glyph
    when the ledger said the call failed, then two dispatch cells: [&] when
    it ran in a batch with others, [>] when it returned a deferral. At
    {!wide_pane_cols} and wider the call row ends with the call's age since
    receipt, six cells wide, and the fleet row's name column holds eighteen
    more cells.

    Under either receipt order, a record whose calls came from more than one
    model response brackets each response in the call rows' border cell:
    [\xe2\x94\x8c] beside its first call, [\xe2\x94\x82] beside the calls
    between, [\xe2\x94\x94] beside its last, the three plain over the dim
    edge, and a dim [\xe2\x94\x80] beside a response of one call, so a
    record of lone calls still reads as split. No row is added. A
    composition's calls sit with the response that asked for the
    composition. The response is the call's session ordinal, not its
    planned index. Call rows keep the plain edge under the two sorts, which
    interleave responses, for a single response, and when any call states
    no ordinal.

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

val legend : cols:int -> string
(** The legend row, as drawn at that width: the column names sit over the
    fleet row's columns, which start after the name column the width gives. *)

val age_text : now:float -> float -> string
(** How long ago, in the feed's own duration shape ([12.4s], [2m05s]). *)
