(** Keeper Pulse's two header strips and the selected Keeper summary (RFC-0515 §2.8).
    The caller supplies one frame's clock and the roster before view filtering. *)
val header :
  ko:bool -> now:float -> cells:int -> view:Masc_tui_keeper_list_model.view ->
  selected:string option ->
  age:(Masc_tui_keeper_list_model.row -> Masc_tui_keeper_list_model.memory_age) ->
  Masc_tui_keeper_list_model.row list -> string
(** Seven fixed verdict/liveness groups (failing, config error, unexpected
    offline, recovered, sound, paused, expected/absent offline); unread
    readings keep an explicit [◌] count (age view uses five age buckets with
    [?]). Each non-empty group draws its status mark and count once without
    per-member glyph repetition. *)

type wake_style =
  | Keeper_wakes
      (** One Keeper's row: a wake mark per slot, receded like every small
          graph inside a list. *)
  | Wake_counts
      (** A group or the fleet: each slot's count as a level against the
          busiest slot, on the {!Masc_tui_theme.Wakes} ramp. *)

val wake_summary : ko:bool -> Masc_tui_keeper_next_run.wake_slot list -> string
(** State-view summary in the same width as the half-hour window. Counts
    only known wakes; a count beside an unknown slot is a lower bound ([3+]).
    A window with nothing reported is one [?] at its left, and a read window
    with no run is one [—] (RFC tui-one-screen-grammar 6.4). *)

val wake_strip :
  style:wake_style -> Masc_tui_keeper_next_run.wake_slot list -> string
(** One terminal cell per half hour. Mixed
    windows retain every position: positive known counts keep their wake
    glyph even when an unknown shares the slot. Unknown slots without known
    wakes use thin lines; known empty slots use spaces. Only [Wake_counts]
    scales known counts. {!wake_summary} retains the partial-count notice.
    An entirely unknown window is one [?] at its left, a known empty one a
    [—]. *)

val history_unknown_label : cells:int -> string
(** The past half-hour band when nothing in it was read: one [?] at the
    band's left, padded to its width, nothing for zero cells. *)

type fleet_cells = { name : string; pulse : string; strip : string; due : string }

val fleet_cells :
  ?summarize_wakes:bool -> ko:bool -> now:float -> grid:Masc_tui_keeper_grid.t ->
  wakes:(Masc_tui_keeper_list_model.row -> Masc_tui_keeper_next_run.wake_slot list) ->
  Masc_tui_keeper_list_model.row list -> fleet_cells option
(** Half-hour failed-Keeper counts, not failed-turn counts; rested counts as
    failure. Missing pulse readings draw the receded unknown strip mark; when
    no Keeper has any reading the pulse is {!history_unknown_label}. The wake
    strip uses {!wake_strip} (or a concise total count when
    [summarize_wakes] is [true]); an unknown maximum remains receded. Paused
    Keepers do not contribute wakes. Draw these fields on the shared grid.
    [None] when the grid has no band: the two maxima would scale cells that are
    not drawn. *)

val selected_summary :
  ko:bool -> now:float -> activity_cell:string ->
  next_run:Masc_tui_keeper_next_run.t -> recurrence:Schedule_domain.recurrence option ->
  memory:Masc_tui_keeper_memory_reading.t -> Masc_tui_keeper_list_model.row -> string
(** Activity age/since, next scheduled run with a decoded recurrence, lag and,
    for a failing Keeper, the independently observed next runtime path. *)
