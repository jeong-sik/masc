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
    and how many were dropped. Events [visible Actions] spend [actions];
    everything else spends [quiet].

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
  | Turn_settled  (** [■] *)
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

val chunk_rows : traces:(string * string) list -> entry list -> row list
(** The [Turns] projection: entries (newest first) folded into one row per
    keeper turn, plus the rows that are not turn lifecycle (chat, approvals,
    server events, internal agent runs) unchanged. What [visible Turns] hides
    (composite pushes, heartbeats, stream frames, waiting-queue changes,
    snapshots) stays hidden here too; the fold never readmits it as a
    pass-through row. Rows come back newest
    first by latest activity. Events that carry a turn number key their
    chunk; the keeper-ledger events carry none and attach to the keeper's
    most recent chunk, which can misfile a ledger row that arrives after the
    next turn's ready - a display blemish, never a stored fact. A settled
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
