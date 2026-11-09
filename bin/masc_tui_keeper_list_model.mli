(** Pure activity, grouping, and ordering decisions for the Keepers list. *)

type view = Plain | By_state | By_cause | By_runtime | Day_wall
(** How the Keepers list groups its rows (RFC-0515 §2.3). [Plain] and
    [Day_wall] do not group; [Day_wall] puts the rows with the most failed
    half-hours of the last day first. *)

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
val view_label : view -> string
val view_of_string : string -> view option
(** The labels are the values [tui-keepers.toml] stores under [view]. *)

val next_density : density -> density
val density_label : density -> string
val density_of_string : string -> density option
(** The labels are the values [tui-keepers.toml] stores under [density]. *)

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
  | Not_failing

type runtime_bucket =
  | Runtime_named of string  (** The roster row's current runtime id. *)
  | Runtime_unread  (** The roster did not read this Keeper. *)

type group =
  | Group_state of attention
  | Group_cause of cause_bucket
  | Group_runtime of runtime_bucket

val group_of_view : view -> row -> group option
(** The heading [row] sits under in [view]; [None] for a view that does not
    group. {!order_rows} keeps the rows of one group next to each other. *)

val failed_half_hours : now:float -> row -> int option
(** The half-hour slots that started within the last day and hold a failed
    turn. [None] when the roster carries no pulse for the row. *)

val order_clock_step : view -> float option
(** How often, in seconds, the clock alone can change the order of [view];
    [None] when only the readings change it. *)

val order_rows : view:view -> sort:sort -> now:float -> row list -> row list
(** The groups of [view] in a fixed order, and [sort] within each group.
    [Day_wall] orders by {!failed_half_hours}, most first, rows without a
    pulse last. The same order is used for drawing, navigation, and search. *)
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
