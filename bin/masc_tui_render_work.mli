(** Work / Tasks, Planning (Goals) and Schedules screen entry points, viewport
    calculators and shared schedule column helpers. *)

val task_detail_viewport : Masc_tui_types.state -> int * int
(** Wrapped physical row count and visible body height for the current Task
    reading, including its metadata and the actual split-pane width. *)

val planning_detail_viewport : Masc_tui_types.state -> int * int
(** Physical row count and reader height of the current Goal detail,
    including its pinned action rows and actual split-pane width. *)

val planning_detail_candle_scroll :
  Masc_tui_types.state -> Masc_tui_types.planning_goal -> int
(** Locate the Candle section in the same wrapped content the detail draws. *)

val planning_missing_goal_notice : Masc_tui_types.state -> goal_id:string -> bool
(** Whether a missing Goal is shown as a Home request rather than a list. *)

val schedule_detail_viewport : Masc_tui_types.state -> int * int
(** Physical-row count and height of the current Schedule evidence reader. *)

type schedule_status_reading = { word : string; tone : string; mark : string }
(** A schedule's [sch_status] as the screen draws it: the word in the
    screen's language, its colour and its status mark (RFC
    tui-one-screen-grammar §7.2). A word the contract does not name is the
    word as received, with no colour and a plain dot. *)

val schedule_status_reading : ko:bool -> string -> schedule_status_reading

val schedule_status_word_cells : ko:bool -> int
(** The widest status word the screen draws in that language. *)

val schedule_requested_clock_cells : int

val schedule_outcome : ko:bool -> Masc_tui_types.schedule_row -> (string * string) option
(** What the last occurrence came to, as the word and its colour; [None]
    when there is no outcome to draw. *)
val schedule_status_is_terminal : string -> bool

val planning_confirmation_view :
  Masc_tui_types.state ->
  goal_id:string ->
  [ `Inspect of Masc_tui_planning_detail.confirmation Masc_tui_fetched.view
  | `Submitting ]

val render_task_detail :
  Masc_tui_types.state -> Masc_domain.task ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_work_tasks :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_planning_list :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val planning_summary_reading :
  cols:int -> Masc_tui_types.state -> Masc_tui_detail_reading.t
(** A captured, read-only Goal and global Task summary, including the two
    server snapshot timestamps used for its changes. *)

val render_planning_detail :
  Masc_tui_types.state ->
  armed:Goal_phase.Public_action.t option ->
  confirmation:
    [ `Inspect of Masc_tui_planning_detail.confirmation Masc_tui_fetched.view
    | `Submitting ] ->
  Masc_tui_types.planning_goal ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_planning :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_schedules :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
