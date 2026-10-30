(** Pure activity, grouping, and ordering decisions for the Keepers list. *)

type layout = Compact | Detailed | Grouped
type sort = Priority | Recent | Oldest | Activity | Name
type attention = Attention | Active | Waiting | Inactive | Unobserved

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
  | Waiting_source_read_error

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
  | Wake_keeper_addon
  | Wake_read_model_reader

type activity =
  | Held_call
  | Question
  | Confirmation
  | Failure
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

val next_layout : layout -> layout
val next_sort : sort -> sort
val layout_label : layout -> string
val sort_label : sort -> string
val layout_of_string : string -> layout option
val sort_of_string : string -> sort option
val holds_awaiting_verification : keeper_name:string -> Masc.Tui_decode.task list -> bool
(** Whether [keeper_name] is the assignee of a task that awaits its verdict.
    The row's current task cannot be relied on for this, since submission
    clears it. An empty list, as when the backlog is unread or failed, gives
    false. *)
val primary_activity_of_row : row -> activity
val badges_of_row : row -> badge list
val group_of_row : row -> attention
val order_rows : layout:layout -> sort:sort -> row list -> row list
(** Grouped layout orders groups first and applies [sort] within each group.
    The same order is used for drawing, navigation, and search. *)
val group_counts : row list -> int * int * int * int * int
(** Counts in [Attention, Active, Waiting, Inactive, Unobserved] order. *)
val waiting_summary : row list -> waiting_summary
(** Count each primary waiting reason and, only for those rows, async running.
    Queued and cancelling async work, and async running on Active rows, does not
    contribute to [background]. *)
