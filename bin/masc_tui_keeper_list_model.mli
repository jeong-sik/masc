(** Pure activity, grouping, and ordering decisions for the Keepers list. *)

type view =
  | Plain
  | By_state
  | By_cause
  | By_time
  | By_memory
  | By_age
  | By_runtime
  | Day_wall
(** How the Keepers list groups its rows (RFC-0515 §2.3). [Plain] and
    [Day_wall] do not group; [Day_wall] puts the rows with the most failed
    half-hours of the last day first. [By_runtime] contains only failing rows,
    grouped by failure cause for the runtime cross-table. *)

type density = One_line | Two_lines
(** Whether each row also draws its second line (RFC-0515 §2.6). *)

type sort = Priority | Recent | Oldest | Activity | Name
type attention = Attention | Failing | Active | Waiting | Inactive | Unobserved
(** [Attention] holds what a person has to answer. [Failing] holds the other
    rows whose health is failing, whatever they are doing now, and the rows
    whose open turn failed an attempt. *)

type keeper_waiting_state = Masc.Tui_decode.keeper_waiting_state =
  | Keeper_waiting_idle
  | Keeper_waiting_busy
  | Keeper_waiting_blocked
  | Keeper_waiting_deferred

type waiting_source = Masc.Tui_decode.waiting_source =
  | Waiting_source_event_queue_pending
  | Waiting_source_chat_operation_queued
  | Waiting_source_chat_operation_running
  | Waiting_source_hitl_pending
  | Waiting_source_fusion_running
  | Waiting_source_schedule_waiting
  | Waiting_source_owner_shutdown
  | Waiting_source_operator_pending_confirm
  | Waiting_source_runtime_quota_spent
  | Waiting_source_read_error
  | Waiting_source_observation_unavailable

type wake_producer = Masc.Tui_decode.wake_producer =
  | Wake_board_dispatch
  | Wake_board_attention_judge
  | Wake_keeper_owner_actor
  | Wake_keeper_supervisor
  | Wake_fusion_sink
  | Wake_connector_attention_hook
  | Wake_hitl_resolution_hook
  | Wake_keeper_ask_answer
  | Wake_schedule_store
  | Wake_schedule_runner
  | Wake_operator_pending_confirm_store
  | Wake_completion_authority
  | Wake_keeper_task_cancellation
  | Wake_keeper_workspace_message
  | Wake_keeper_delegate
  | Wake_keeper_composition
  | Wake_keeper_job
  | Wake_read_model_reader

type activity =
  | Held_call
  | Question
  | Confirmation
  | Attempt_failed
      (** An attempt in the turn that is open now failed. A failing health
          reading is not an activity: that Keeper shows what it does now. *)
  | Preparing
  | Streaming
  | Running
  | Async_working of int
  | Deferred
  | Tool_waiting
  | Model_waiting
  | Delegate_result
      (** A delegated operation's terminal result is queued for this Keeper;
          this is not an observation of an in-progress delegation. *)
  | Verifying
  | External_waiting
  | Idle
  | Paused
  | Offline
  | Unknown

type badge =
  | Badge_read_error
  | Badge_waiting_unavailable
  | Badge_async of { running : int; ownership_unknown : int }
  | Badge_async_queued of int
  | Badge_async_cancelling of int
  | Badge_delegate
  | Badge_verification
  | Badge_schedule
  | Badge_quota_spent

type waiting_reading =
  | Waiting_observed of Masc.Tui_decode.keeper_waiting_row
  | Waiting_unobserved
  | Waiting_unavailable

type row = {
  keeper : Masc.Tui_decode.keeper;
  reading : Masc_tui_keeper_control.reading;
  turn : Masc.Tui_decode.keeper_turn_state option;
  waiting : waiting_reading;
  approval : Masc.Tui_decode.keeper_tool_approval option;
  task : Masc.Tui_decode.task option;
  awaiting_verification : bool;
      (** The Keeper submitted a task that still awaits its verdict. *)
  open_questions : int;
  async_requests : Masc.Tui_decode.async_request_row list;
  last_activity_at : float option;
}

type waiting_summary = {
  tool : int;
  model : int;
  external_wait : int;
  delegate : int;
  verification : int;
  background : int;
}
(** Primary waiting reasons and actual background async running in that group. *)

val next_view : view -> view
val views : view list
(** Every view in the order {!next_view} walks them from [Plain]. *)
val view_label : view -> string
val view_of_string : string -> view option
(** The labels are the values [tui-keepers.toml] stores under [view]. *)

val view_title : ko:bool -> view -> string
(** The view's name on the view row, in the screen language. The English name
    is {!view_label}. *)

val next_density : density -> density
val density_label : density -> string
val density_of_string : string -> density option
(** The labels are the values [tui-keepers.toml] stores under [density]. *)

val shows_portrait : view -> density -> bool
(** Whether the list draws the selected Keeper's portrait above its rows:
    only the [Plain] view in [Two_lines]. The axis views spend those rows on
    Keepers (RFC-0515 E20). *)

val next_sort : sort -> sort
val sort_label : sort -> string
val sort_of_string : string -> sort option
type verification_holders
(** The assignees of tasks that await their verdict, read once from a task
    list so a roster of keepers can ask about each of them. *)

val verification_holders : Masc.Tui_decode.task list -> verification_holders
(** An empty list, as when the backlog is unread or failed, holds no one. *)

val holds_awaiting_verification : verification_holders -> keeper_name:string -> bool
(** Whether [keeper_name] is the assignee of a task that awaits its verdict.
    The row's current task cannot be relied on for this, since submission
    clears it. *)
val primary_activity_of_row : row -> activity

(** What a Keeper waits on a person for. *)
type person_wait =
  | Held_tool of Masc.Tui_decode.keeper_tool_approval  (** The tool call held for approval. *)
  | Held_item of Masc.Tui_decode.waiting_item
      (** The human-in-the-loop wait, when the row carries no tool approval. *)
  | Open_questions of int  (** The questions the Keeper asked and nobody answered. *)
  | Confirmation_item of Masc.Tui_decode.waiting_item
      (** The wait for an operator's confirmation. *)

val person_wait : row -> person_wait option
(** The reading that makes the row's activity [Held_call], [Question] or
    [Confirmation]: the held tool call, else the item whose source is the
    human-in-the-loop wait; the open questions; the item whose source is the
    operator's pending confirmation. Never another item of the same row.
    [None] for every other activity. *)
val badges_of_row : row -> badge list
val group_of_row : row -> attention
val trail_of_row : row -> Masc_tui_keeper_trail.trail
(** What the row last failed at. [Trail_failed] exactly when its health reading
    is failing. A row without a human decision is in the [Failing] group when
    its trail is failed, and also when its activity is [Attempt_failed]; that
    second kind has no failure sentence unless its health is failing too. *)
type cause_bucket =
  | Cause_named of Masc_tui_keeper_trail.cause_group
      (** The trail is failed and its last receipt names the cause. *)
  | Cause_unnamed  (** The trail is failed and no receipt names a cause. *)
  | Cause_recovered (** Non-failing/non-paused, with a failed half hour in 12h. *)
  | Not_failing (** No current failure; unread rows make no claim of healthy status. *)
  | Cause_paused (** Pause wins even when the health reading is failing. *)

type due =
  | Due_late  (** A due run has not started. *)
  | Due_held  (** The schedule runner holds the next run. *)
  | Due_within_hour
  | Due_within_half_day
  | Due_later
  | Due_none  (** No active schedule. *)
  | Due_unknown  (** The schedules were not read, or the next time is unknown. *)

type memory_follow =
  | Memory_refused  (** The memory reading refused this Keeper. *)
  | Memory_gap  (** The librarian stalled on a gap. *)
  | Memory_lagging  (** Turns the librarian has not read yet. *)
  | Memory_following
  | Memory_unread  (** No memory reading for this Keeper. *)

type memory_age =
  | Age_within_3h
  | Age_within_day
  | Age_within_3d
  | Age_older
  | Age_unknown  (** No snapshot update time. *)

type outside = { due : due; follow : memory_follow; age : memory_age }
(** The readings a row does not carry: the next scheduled run and the memory
    snapshot. A caller that sees the schedules and memory health reduces them
    to these closed values. *)

val outside_unread : outside
(** Every value unknown, for a caller that has not read them. *)

type group =
  | Group_state of attention
  | Group_cause of cause_bucket
  | Group_due of due
  | Group_memory of memory_follow
  | Group_age of memory_age

val group_of_view : now:float -> outside:(keeper_name:string -> outside) -> view -> row -> group option
(** The heading [row] sits under in [view]; [None] for a view that does not
    group. {!order_rows} keeps the rows of one group next to each other. *)

val failed_half_hours : now:float -> row -> int option
(** The half-hour slots that started within the last day and hold a failed
    turn. [None] when the roster carries no pulse for the row. *)

val order_clock_step : view -> float option
(** How often, in seconds, the clock alone can change the order of [view];
    [None] when only the readings change it. *)

val order_rows :
  view:view -> sort:sort -> now:float -> outside:(keeper_name:string -> outside) ->
  row list -> row list
(** The groups of [view] in a fixed order, and [sort] within each group.
    [Day_wall] orders by {!failed_half_hours}, most first, rows without a
    pulse last. [By_runtime] removes rows without a failing health reading before ordering
    them by cause. The same rows are used for drawing, navigation, and search. *)

(** {1 Stops} (RFC-0515 §2.6, E12)

    The places [j] and [k] land on. [groups] is the group of each row
    {!order_rows} returned, in that order; a stop names a row by its
    position there. *)

type stop =
  | Stop_world
  | Stop_heading of group
  | Stop_row of int

type heading_focus = { heading : group; cursor_at : int }
(** The heading the cursor stands on, and the row cursor it was placed with.
    The cursor rests on the group's first row, so a cursor moved by any
    other path leaves the heading. *)

type focus = Focus_heading of heading_focus | Focus_world

val has_world : view -> bool
val keeper_position : stop option -> int option
(** Only a real Keeper stop has an actionable row position. *)

type group_direction = Previous_group | Next_group
type fold_change = Fold | Unfold

val stops : view:view -> folded:group list -> group option list -> stop list
(** The stops in drawing order: a heading for each group, then its rows
    unless the group is [folded]. A row of a view that does not group is a
    stop of its own. Memory and age views begin with [Stop_world]. *)

val current_stop :
  view:view -> folded:group list -> focus:focus option -> cursor:int -> group option list ->
  stop option
(** The stop the cursor is on: the focused heading while the cursor still
    rests where the focus placed it inside that group; else the row at
    [cursor], clamped to the list, or its group's heading when that group is
    folded. An empty memory/age view still selects [Stop_world]. *)

val placement : view:view -> group option list -> stop -> (focus option * int) option
(** The focus and row cursor a stop is placed with. A heading rests the
    cursor on its group's first row; [None] for a heading no row is under. *)

val step_stop : delta:int -> stop list -> stop -> stop option
(** The stop [delta] places from [current], held at either end. [None] when
    [current] is not one of [stops]. *)

val group_jump : group_direction -> stop list -> stop -> stop option
(** The nearest heading before or after [current]; [None] past the first or
    last one, and in a view without headings. *)

val refold : fold_change -> group -> group list -> group list
(** The folded groups after folding or unfolding [group]. *)

val first_folds :
  seen:group list -> folded:group list -> group option list -> group list * group list
(** Apply E26 defaults only when a group is first observed in this session.
    Returns the seen groups and folded groups. Later refreshes retain the
    reader's explicit fold/unfold choices, including newly arriving groups. *)

type group_counts = {
  attention_rows : int;
  failing_rows : int;
  active_rows : int;
  waiting_rows : int;
  inactive_rows : int;
  unobserved_rows : int;
}
(** The number of rows in each {!attention} group. *)

val group_counts : row list -> group_counts
val waiting_summary : row list -> waiting_summary
(** Count each primary waiting reason and, only for those rows, async running.
    Only rows in the [Waiting] group count: a failing row that waits on a tool
    is in [Failing]. Queued and cancelling async work, and async running on
    other rows, does not contribute to [background]. *)
