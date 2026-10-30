(** Work / Tasks, Planning (Goals) and Schedules screen entry points, viewport
    calculators and shared schedule column helpers. *)

val task_detail_viewport : Masc_tui_types.state -> int * int
(** Wrapped physical row count and visible body height for the current Task
    reading, including its metadata and the actual split-pane width. *)

val planning_detail_viewport : Masc_tui_types.state -> int * int
(** Physical row count and reader height of the current Goal detail,
    including its pinned action rows and actual split-pane width. *)

val schedule_detail_viewport : Masc_tui_types.state -> int * int
(** Physical-row count and height of the current Schedule evidence reader. *)

val schedule_status_color : string -> string
val schedule_status_word_cells : int
val schedule_requested_clock_cells : int
val schedule_outcome_word : Masc_tui_types.schedule_row -> string
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
