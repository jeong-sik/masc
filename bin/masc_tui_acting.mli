(** What the Acting surface draws for each event off the runtime feed.

    The feed carries every keeper's tool calls, turn boundaries, heartbeats,
    settlements, and projection pushes. The surface is the place to watch
    ten keepers act at once, so the questions here are presentation ones:
    which events an operator scanning for actions wants on screen, what one
    row says about an event, and how long a completed call took. Nothing
    here performs I/O or touches the TUI's state. *)

module Observer = Masc_tui_observer

(** Which events the surface shows. [Actions] is the default: what keepers
    did. [Everything] adds the events that say a keeper is still there or
    that a projection changed - heartbeats, composite and snapshot pushes,
    telemetry - which on the live runtime were more than half of the feed
    and said nothing a row could act on. *)
type filter =
  | Actions
  | Everything

val next_filter : filter -> filter
val filter_label : filter -> string

val visible : filter -> Observer.event -> bool
(** Whether an event draws under a filter. Under [Actions] the hidden kinds
    are named here, not guessed from volume: telemetry, heartbeats,
    composite and snapshot pushes. An event type this build was not taught
    always draws, so a new kind is noticed rather than filtered away. *)

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

val row_of_event : duration_ms:float option -> Observer.event -> row
(** One row per event. [duration_ms] is drawn on a completed call when the
    caller could pair it with its start; see {!duration_of_completion}. *)

val duration_of_completion :
  before:Observer.event list -> Observer.agent_core -> float option
(** How long a completed call took, from the most recent [Tool_called] in
    [before] (newest first) that carries the same tool-use id and agent.
    [None] when no such start is held - the feed opened after the call
    began, or the start has fallen off the end of what the TUI keeps. *)

val elapsed_text : float -> string
(** A duration in milliseconds as [32ms], [1.2s], or [2m05s]. *)
