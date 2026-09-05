(** The Activity pane: what every keeper is doing right now, beside whatever
    surface is up.

    The observer feed already reaches the TUI for the whole session, and the
    Activity surface draws it full-screen. This pane projects the same held
    events into a column on the right of any surface, so a reader in a keeper
    chat or on the board sees the fleet move without leaving. Two blocks: the
    fleet, one row per keeper ordered by who acted last; then the keeper the
    cursor is on, with the calls of its current turn and the turns before it.

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

(** The feed's state as the header states it. *)
type feed =
  | Feed_off  (** no server has answered yet *)
  | Feed_opening
  | Feed_live of int  (** frames received on this stream *)
  | Feed_closed of string  (** why *)

(** One keeper as the fleet block draws it. [mark] is the one-cell health
    glyph the roster draws ({!Masc_tui_keeper_mark}); [mark_tone] is the
    colour the caller reads out of the same health, so this module never
    interprets health itself. [trace_id] resolves agent-core events, which
    name their runtime lane, back to the keeper. *)
type keeper = {
  name : string;
  mark : string;
  mark_tone : tone;
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

type input = {
  now : float;
  feed : feed;
  keepers : keeper list;
  selected : string option;
      (** the keeper the cursor is on; the most recently active keeper stands
          in when there is none *)
  approvals : approval list;  (** pending, any keeper *)
  entries : Masc_tui_acting.entry list;  (** newest first, as the TUI holds them *)
}

type span = {
  text : string;
  tone : tone;
}

type line = span list

val lines : rows:int -> cols:int -> input -> line list
(** Exactly [rows] lines, each exactly [cols] display cells once its spans
    are joined: a line that would overflow is cut at the right edge, a short
    one is padded, and rows the content does not need are blank. The fleet
    block takes at most half the rows when the focus block has something to
    show, so a wide fleet cannot push the current turn off the pane. *)

val keeper_state_text : now:float -> approval:string option ->
  Masc_tui_acting.chunk option -> span list
(** The fleet row's reading for one keeper: a pending approval outranks
    everything (the keeper is waiting on the reader), then the current turn's
    tool and call count, then the settled turn's calls and tokens, then
    [quiet] for a keeper the feed has not shown acting. *)

val tokens_text : int option * int option -> string
(** Input and output tokens as one compact figure ([38.2k tok], [412 tok]);
    empty when neither is known. *)

val age_text : now:float -> float -> string
(** How long ago, in the feed's own duration shape ([12.4s], [2m05s]). *)
