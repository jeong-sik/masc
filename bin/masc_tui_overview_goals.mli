(** The Overview's GOALS section. It answers one question: is the fleet's
    work moving any goal forward?

    The headline counts the active tasks (in progress or awaiting
    verification) and how many of them a drawn goal lists. Each drawn goal
    uses one line with its title, attention state, linked task count and due
    date. Proof and the Goal metric are in Planning detail. The
    task count is not a measure of Goal achievement. *)

module Tui_decode = Masc.Tui_decode

val drawn_phase : Goal_phase.t -> bool
(** All nonterminal phases, including [Paused] and [Blocked], so the operator
    can find suspended Goals and restore them. *)

val drawn_goals : Tui_decode.overview_goal list -> Tui_decode.overview_goal list
(** The goals in a {!drawn_phase}, by priority (lower number first), then by
    due date (earlier first, no or unreadable date last), then in server
    order. *)

type progress = {
  active : int;  (** Tasks in progress or awaiting verification. *)
  toward_goal : int;  (** How many of [active] a drawn goal lists. *)
}

val progress :
  goals:Tui_decode.overview_goal list -> tasks:Tui_decode.task list -> progress
(** [goals] is what the section draws ({!drawn_goals}). *)

val wanted_rows : Masc_tui_types.overview_goals_reading -> int
(** One headline plus one row per active Goal. Empty, unread and failed
    readings need one row. *)

val lines :
  now:float ->
  inner_width:int ->
  rows:int ->
  tasks:Masc_tui_overview_tasks.rows_reading ->
  Masc_tui_types.overview_goals_reading ->
  string list
(** At most [rows] lines, headline first. Goals past the budget are cut from
    the bottom and the headline says how many are drawn. [now] is the Unix
    time the due-date countdown counts from. A due date falls due at 23:59:59
    UTC of its day ({!Goal_due}), so the countdown counts UTC days whatever
    the operator's time zone is. [tasks] is the backlog the headline counts.
    Only rows that were read are counted; an unread or unavailable backlog is
    said instead. *)

val draw :
  Buffer.t ->
  cols:int ->
  rows:int ->
  now:float ->
  tasks:Masc_tui_overview_tasks.rows_reading ->
  Masc_tui_types.overview_goals_reading ->
  unit
(** The {!lines} as framed rows and the divider under them. Nothing when
    [rows] is zero. *)
