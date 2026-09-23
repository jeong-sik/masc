(** What the Acting surface draws for each event off the runtime feed.

    The feed carries every keeper's tool calls, turn boundaries, heartbeats,
    settlements, and projection pushes. The surface is the place to watch
    ten keepers act at once, so the questions here are presentation ones:
    which events an operator scanning for actions wants on screen, what one
    row says about an event, and how long a completed call took. Nothing
    here performs I/O or touches the TUI's state. *)

module Observer = Masc_tui_observer

(** Which events the surface shows. [Turns] is the default: one row per
    keeper turn, folded by {!chunk_rows} from the up-to-seven lifecycle rows
    a single tool call produces across the two reporting planes. [Actions]
    is the flat log of what keepers did. [Everything] adds the events that
    say a keeper is still there or that a projection changed - heartbeats,
    composite and snapshot pushes, telemetry - which on the live runtime
    were more than half of the feed and said nothing a row could act on. *)
type filter =
  | Turns
  | Actions
  | Everything

val next_filter : filter -> filter
val filter_label : filter -> string
val filter_explanation : filter -> string
(** Short in-frame scope legend. It names what the current projection folds or
    hides and explains the quiet rows that [Everything] adds. *)

type entry = {
  ae_at : float;  (** when the TUI received it *)
  ae_event : Observer.event;
}
(** One feed event as the screen holds it. The screen is a feed: entries are
    held and drawn in the order they arrived, so arrival is the clock the rows
    wear. *)

val visible : filter -> Observer.event -> bool
(** Whether an event draws under a filter. Under [Actions] the hidden kinds
    are named here, not guessed from volume: telemetry, heartbeats,
    composite and snapshot pushes. An event type this build was not taught
    always draws, so a new kind is noticed rather than filtered away. *)

val retain :
  actions:int ->
  quiet:int ->
  event_of:('a -> Observer.event) ->
  'a list ->
  'a list * int
(** Trim a newest-first ring to a budget per class, answering what was kept
    and how many were dropped. Events [visible Actions] and turn
    observations spend [actions] -- the Turns fold needs an observation
    exactly as long as the calls it numbers, so it leaves with them in
    arrival order; everything else spends [quiet].

    Trimming by arrival alone let one class evict the other: a chat stream
    sends one frame per token, so a single long reply spent the whole ring
    and the screen held about a second of the calls and settlements it was
    opened for. Order is preserved and nothing is dropped without being
    counted. *)

(** The glyph a row starts with. One vocabulary for the whole surface and
    the Keepers roster, so a column scans the same way on both. *)
type glyph =
  | Call_started  (** [▶] *)
  | Call_returned  (** [✓] *)
  | Turn_boundary  (** [●] *)
  | Turn_done  (** [■] *)
  | Failure  (** [✗] *)
  | Attention  (** [?] *)
  | Quiet  (** [·] the kinds [Everything] adds *)

val glyph_text : glyph -> string

type row = {
  at : float;  (** the event's own timestamp *)
  keeper : string;  (** who acted; the agent name as the feed gave it *)
  glyph : glyph;
  label : string;  (** what happened, one or two words *)
  detail : string;  (** what it happened to: the tool, the turn, the cost *)
}

val keeper_of_event :
  traces:(string * string) list -> Observer.event -> string
(** Who acted. The agent_core family names its runtime lane as the agent
    ([agent_core-glm-coding.glm-5-turbo] on the live runtime), not the
    keeper; the keeper is the one whose trace id the event's correlation id
    carries. [traces] is (keeper name, trace id) for every keeper the TUI
    knows. An event whose correlation matches none keeps its agent name. *)

val row_of_entry : duration_ms:float option -> entry -> row
(** The row an entry draws, wearing the entry's arrival clock. Render calls
    this rather than [row_of_event] so there is no clock argument at the call
    site to hand in the wrong value. *)

val row_of_event :
  at:float -> duration_ms:float option -> Observer.event -> row
(** [at] is the row's clock, given by the caller. The screen is a feed: rows
    are held and drawn in the order they arrived, so arrival is the clock that
    matches the order the operator scrolls through. Reading each event's own
    timestamp instead put two clocks on one screen, and the two event kinds
    that carry none showed [--:--:--] -- the column that would let an operator
    check the order was blank on 925 of 927 rows. *)
(** One row per event. [duration_ms] is drawn on a completed call when the
    caller could pair it with its start; see {!duration_of_completion}. *)

(** The turn fold as data, for a surface that draws it its own way. *)
type chunk_tool = {
  ct_tool : string;
  ct_duration_ms : float option;
  ct_at : float;  (** receipt clock of the row that named the call *)
  ct_tool_use_id : string option;
  ct_session_turn : int option;
      (** The agent session's ordinal of the provider call that asked for
          this one. The calls one model response asked for share it, as do
          the calls a composition runs for one of them, and the next response
          has the next ordinal, so equal neighbours are one response. A CLI
          lane runs a whole keeper turn as one provider call: all its calls
          share one. [None] when the frame stated none. *)
  ct_disposition : (Masc.Tui_decode.keeper_call_disposition, string) result option;
      (** The ledger's word for what became of the call. [None] on a call the
          wire plane stood in for: that plane reports no disposition. *)
  ct_schedule : (Agent_core.Tool_contract.schedule, string) result option;
      (** Where the runtime placed the call in the turn: its planned step,
          its batch and how many ran in that batch at once. [None] on the
          wire plane, an [Error] when the ledger row's schedule did not
          parse, kept beside the call rather than dropped. *)
  ct_input : string option;  (** producer-redacted preview *)
  ct_output : string option;  (** producer-redacted preview *)
}

(** How a press names one call across frames: the provider's call id when
    the row carried one, else the receipt clock and the tool name. *)
type call_key =
  | Call_by_id of string
  | Call_by_receipt of { at : float; tool : string }

val call_key : chunk_tool -> call_key
val call_key_equal : call_key -> call_key -> bool

type wire_tool = {
  wt_id : string option;
  wt_started : float;
  wt_tool : string;
  wt_duration_ms : float option;
  wt_session_turn : int option;
}

(** What the agent-core loop last said about this record's provider call:
    one was asked for, started, or came back. *)
type turn_marker =
  | Marker_ready
  | Marker_started
  | Marker_completed

type chunk = {
  ck_keeper : string;
  ck_turn : int option;
      (** The keeper's own number for the turn, from its settle or from the
          observation of any provider call inside it; [None] until either
          has arrived, and the row says so. *)
  ck_session_turns : int list;
      (** The agent session's ordinals for the provider calls this turn has
          absorbed, oldest first. The turn markers, the wire and the keeper
          ledger number their frames by the call; a row that states an
          ordinal no observation has named yet is filed by this list. *)
  ck_at : float;  (** newest member's arrival — the chunk's feed position *)
  ck_wire_tools : wire_tool list;  (** oldest-first, from the agent-core wire *)
  ck_ledger_tools : chunk_tool list;  (** oldest-first, from the keeper ledger *)
  ck_settled : bool;
  ck_marker : (turn_marker * float) option;
      (** The newest turn marker and the clock it arrived on. [Marker_started]
          with nothing after it is a provider call in flight: the model has
          the turn. A CLI lane sends no markers, so this stays [None] and the
          pane says nothing about what that keeper is doing between calls. *)
  ck_tokens : int option * int option;
  ck_cost_usd : float option;
  ck_calls : int option;
}

val chunks : traces:(string * string) list -> entry list -> chunk list
(** Every keeper's turns, newest activity first: the fold {!chunk_rows} draws,
    before it becomes rows. A running turn's wire calls carry their start and,
    once returned, their duration. *)

type chunk_projection
(** Immutable event-derived chunks retaining one source entry list and its
    ordered keeper/trace mapping. Time, health, approvals and selection are not
    part of this projection. *)

val refresh_projection :
  previous:chunk_projection option -> traces:(string * string) list ->
  entry list -> chunk_projection
(** Reuse only the identical immutable entry list with structurally equal,
    ordered traces. Append/trim/replacement and trace reassignment rebuild;
    mapping order retains the first-match attribution of {!chunks}. *)

val projection_chunks : chunk_projection -> chunk list

val chunk_tools : chunk -> chunk_tool list
(** The calls a chunk names: the ledger's when it reported, else the wire's. *)

val turn_number_text : int -> string
(** [turn 41]. *)

val turn_label : int option -> string
(** The event column's name for a turn: [turn 41], or [turn] when no settle
    in the held window numbered it. *)

val turn_detail : int option -> string
(** The same turn beside the figures: [turn 41], or nothing when no settle in
    the held window numbered it. *)

val chunk_rows : traces:(string * string) list -> entry list -> row list
(** The [Turns] projection: entries (newest first) folded into one row per
    keeper turn, plus the rows that are not turn lifecycle (chat, approvals,
    server events, internal agent runs) unchanged. What [visible Turns] hides
    (composite pushes, heartbeats, stream frames, waiting-queue changes,
    snapshots) stays hidden here too; the fold never readmits it as a
    pass-through row. Rows come back newest
    first by latest activity. A chunk is one keeper turn. A member that
    states the agent session's ordinal for its provider call goes to the
    keeper turn a retained turn observation gives that ordinal, even when it
    is reported after the next turn opened; a member that states no ordinal
    joins the keeper's newest chunk. A settled
    chunk names its tools (ledger plane preferred, wire plane standing in
    when the ledger is silent), tokens, and cost; a running one shows the
    calls so far. *)

val duration_of_completion :
  before:Observer.event list -> Observer.agent_core -> float option
(** How long a completed call took, from the most recent [Tool_called] in
    [before] (newest first) that carries the same tool-use id and agent.
    [None] when no such start is held - the feed opened after the call
    began, or the start has fallen off the end of what the TUI keeps. *)

val elapsed_text : float -> string
(** A duration in milliseconds as [32ms], [1.2s], or [2m05s]. *)

val evidence_fields : entry -> (string * string option) list
(** Producer references from one immutable observer event. Missing IDs and
    input/output are explicit; no matching by name, time, or neighbouring row. *)

type columns = private {
  keeper_cells : int;
  label_cells : int;
}
(** The Activity table's two measured columns, in display cells. Private so a
    row lays itself out on the widths {!columns} derived from the rows it
    draws, never on a pair of numbers assembled at the call site. *)

val columns : inner_width:int -> row list -> columns
(** How wide the keeper and event columns have to be for [rows].

    Both were literals of 16. The agent_core family names its runtime lane as
    the agent -- [agent_core-glm-coding.glm-5-turbo] is thirty cells -- so
    those rows drew a cut name at every width, including the ones where the
    detail column beside them was empty. Neither column goes under what it
    drew before, and the two together take at most half of what the frame
    leaves, because detail is the column that carries sentences. *)
