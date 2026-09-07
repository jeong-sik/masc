(** The Activity pane: what every keeper is doing right now, beside whatever
    surface is up.

    The observer feed already reaches the TUI for the whole session, and the
    Activity surface draws it full-screen. This pane projects the same held
    events into a column on the right of any surface, so a reader in a keeper
    chat or on the board sees the fleet move without leaving.

    Two tabs. [Tab_fleet] is the feed: one row per keeper ordered by who acted
    last, then the keeper the cursor is on with the calls of its current turn
    and the turns before it. [Tab_changes] is the files that keeper changed
    in its workspace, newest first, as the Changes surface lists them, kept
    current from the feed.

    Nothing here performs I/O or reads TUI state. The caller hands in the
    facts as it holds them and gets back rows of toned spans; the renderer
    paints tones through the theme. Width and visibility follow the roster
    pane's contract: the terminal measures, the reader decides, and a
    decision survives a resize. *)

val pane_cols : int
(** The columns the pane takes when it shows. *)

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
  | Feed_live of int  (** frames received on this stream *)
  | Feed_closed of string  (** why *)

(** One keeper as the fleet block draws it. [mark] is the one-cell health
    glyph the roster draws ({!Masc_tui_keeper_mark}); [mark_tone] is the
    colour the caller reads out of the same health. [health] is that same
    reading, and it decides one thing here: whether a turn that has not
    settled can still end. [trace_id] resolves agent-core events, which name
    their runtime lane, back to the keeper. *)
type keeper = {
  name : string;
  mark : string;
  mark_tone : tone;
  health : Masc.Tui_decode.keeper_health_reading option;
  trace_id : string;
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

type input = {
  now : float;
  tab : tab;
  feed : feed;
  keepers : keeper list;
  selected : string option;
      (** the keeper the cursor is on; on the fleet tab the most recently
          active keeper stands in when there is none *)
  approvals : approval list;  (** pending, any keeper *)
  entries : Masc_tui_acting.entry list;  (** newest first, as the TUI holds them *)
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
  | Target_none  (** rule, indicators, padding, focus rows, status rows *)
  | Target_next_tab  (** the header row: a press shows the other tab *)
  | Target_keeper of string  (** a fleet row: the keeper it names *)
  | Target_more
      (** the fold line: the fleet rows the overview layout left out; a press
          scrolls into the full list *)
  | Target_file of int
      (** a changes row: the index of the file in [Changes_ready.files] *)

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
    row carries the two tabs and the feed's state on both tabs.

    Fleet tab, two layouts. At [scroll = 0] the overview: the fleet takes at
    most half the rows below the header when the focus block has something to
    show, a fold line counts the keepers left out, and the focus block takes
    the rest. Any other [scroll] (clamped to [scroll_max]) is the full list --
    every fleet row, the rule, every focus row -- windowed from that offset,
    with an [↑ N more] row where content is above and a [↓ N more] row where
    it is below. When everything fits the two layouts are the same list and
    no fold or indicator draws.

    Changes tab: a status row for the keeper and the fetch, then one row per
    file, windowed the same way. *)

val keeper_state_text :
  now:float ->
  health:Masc.Tui_decode.keeper_health_reading option ->
  approval:string option ->
  Masc_tui_acting.chunk option ->
  span list
(** The fleet row's reading for one keeper: a pending approval outranks
    everything (the keeper is waiting on the reader), then the current turn's
    tool and call count, then the settled turn's calls and tokens, then
    [quiet] for a keeper the feed has not shown acting. A turn that has not
    settled reads as [running] while its keeper can still end it; for a
    keeper whose process is gone it reads as [unfinished], because the end
    event died with the keeper. *)

val tokens_text : int option * int option -> string
(** Input and output tokens as one compact figure ([38.2k tok], [412 tok]);
    empty when neither is known. *)

val age_text : now:float -> float -> string
(** How long ago, in the feed's own duration shape ([12.4s], [2m05s]). *)
