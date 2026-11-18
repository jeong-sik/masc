(** Metrics built from observed runtime and durable task snapshots.
    Current work and outcomes are distinct from the Recent event feed.
    Missing telemetry stays unavailable; rendering does not scan task history. *)

open Masc_tui_types

type turn_counts = { running : int; idle : int; unavailable : int }
type metrics_kpis = {
  total_keepers : int;
  paused_keepers : int;
  (** How many of [total_keepers] an operator has paused. Counted rather than
      left as a difference: the row draws both numbers, and a reader who has
      to subtract one from the other reads whatever the subtraction happens
      to hold. *)
  turns : turn_counts option;
  tasks : Masc_tui_task_flow.counts option;
  gate_pending_count : int option;
  held_approvals_count : int option;
}

val calculate_kpis : state -> metrics_kpis

val identity_gap : state -> Masc_tui_value.Unknown.t
(** Why the cards have no GC or scheduler value from the server identity:
    [Unread] before a probe answers, [Read_failed] after the probe that
    cleared it failed, [Unreported] when the identity read did not carry the
    block. *)

val scheduler_probe_symbol :
  Masc.Tui_decode.scheduler_probe option -> Masc_tui_card.symbol
(** The scheduler card's status mark for the probe's state (RFC
    tui-one-screen-grammar section 7.2): [Running] is under way,
    [Not_started] waiting, [Cancelled] paused, and [Stopped], a probe that
    raised, failed. A word this build does not know, and no probe at all,
    are [?]. *)

val scheduler_probe_status :
  ko:bool -> tone:string -> Masc.Tui_decode.scheduler_probe option -> Masc_tui_card.status
(** The scheduler card's status: {!scheduler_probe_symbol} and the state's
    word. A stopped probe's word is the state alone; its reason is
    {!scheduler_stop_reason}, which the card writes in its body. *)

val scheduler_stop_reason : Masc.Tui_decode.scheduler_probe option -> string option
(** The exception a stopped probe raised, escaped to one line. [None] for any
    other state, and with no probe. *)

val section_pills_line : ko:bool -> cols:int -> active:metrics_section -> string

val engine_graph_capacity : cols:int -> state -> int option
(** How many [/health] samples the engine graphs keep at this terminal width
    ([Some]) while Telemetry's engine section is on screen and its cards draw
    them; [None] otherwise, when nothing is sampled (RFC tui-one-screen-grammar
    section 5.6). *)

type session_entry = {
  event : event;
  run : int;  (** How many identical neighbours folded into this one. *)
  rows : string list;
      (** Every row the event takes at the block's width. The sentence wraps
          under its first word rather than being cut at the edge, so a width
          that leaves room beside the clock and mark holds every row. *)
}

type session_block = {
  earlier : int;  (** Folded events left out, oldest first. *)
  kept : session_entry list;  (** Oldest first; the newest is last. *)
}

val session_block : width:int -> ?room:int -> event list -> session_block
(** Which TUI session events fit [room] rows, from the log as [state.events]
    holds it (newest first). Room is counted in rows, an event is kept or
    left out whole, and when any is left out one row of the room goes to
    counting them. The newest event is kept even when it alone does not fit
    beside that count. Without [room] every event is kept. *)

val render_section_fleet : ?session_rows:int -> cols:int -> state -> string list
(** [session_rows] bounds the TUI session block's rows, spent as
    {!session_block} decides: the kept events are drawn whole under a row
    that counts the earlier ones (["N earlier"], ["이전 N건"]). Without it
    every event is drawn. *)
val render_section_resources : cols:int -> state -> string list
val render_section_tools : cols:int -> state -> string list

val rebase_scroll_for_cards : scroll:int -> previous_cards:int option -> current_cards:int -> int

val render_metrics_body :
  cols:int ->
  budget:int ->
  suffix_lines:string list ->
  state ->
  report_scroll:(int -> int -> int -> unit) ->
  push:(string -> unit) ->
  push_styled:(style:string -> string -> unit) ->
  push_selected:(string -> unit) ->
  push_divider:(unit -> unit) ->
  push_empty:(unit -> unit) ->
  unit
(** [report_scroll] is handed the row the section actually started at. Only
    the drawing knows how many lines a section came to -- it formats them out
    of the readings -- so the keypress steps an unbounded value and this says
    where it landed. Without it the stored scroll climbed past the end and
    coming back took one press per step taken beyond it. *)
