(** The Overview's GOALS section. It answers one question: is the fleet's
    work moving any goal forward?

    The headline counts the active tasks (in progress or awaiting
    verification) and how many of them a drawn goal lists. One row per drawn
    goal follows: its title, a bar of its done tasks over its linked tasks,
    how long it has been idle and, when it has a due date, a D-N countdown.

    The bar measures tasks, not the goal's metric: a goal carries a metric and
    a target but no measured value, and this section does not make one up. *)

module Tui_decode = Masc.Tui_decode

val drawn_phase : Goal_phase.t -> bool
(** [Executing], [Verifying] and [Awaiting_confirmation]: the phases a goal
    still takes work in. *)

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
(** Rows the section asks the Overview budget for, headline included. A
    reading not made yet or failed wants its one explaining line; a reading
    with no drawn goal wants the headline and a line saying so. *)

val lines :
  now:float ->
  inner_width:int ->
  rows:int ->
  tasks:(Tui_decode.task list, string) result ->
  Masc_tui_types.overview_goals_reading ->
  string list
(** At most [rows] lines, headline first. Goals past the budget are cut from
    the bottom and the headline says how many are drawn. [now] is the Unix
    time the due-date countdown counts from, in UTC days. [tasks] is the
    backlog the headline counts; its read error replaces the count. *)

val draw :
  Buffer.t ->
  cols:int ->
  rows:int ->
  now:float ->
  tasks:(Tui_decode.task list, string) result ->
  Masc_tui_types.overview_goals_reading ->
  unit
(** The {!lines} as framed rows and the divider under them. Nothing when
    [rows] is zero. *)
