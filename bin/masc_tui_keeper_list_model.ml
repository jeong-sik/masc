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
  open_questions : int;
  async_requests : Masc.Tui_decode.async_request_row list;
  last_activity_at : float option;
}

let next_layout = function
  | Compact -> Detailed
  | Detailed -> Grouped
  | Grouped -> Compact

let next_sort = function
  | Priority -> Recent
  | Recent -> Oldest
  | Oldest -> Activity
  | Activity -> Name
  | Name -> Priority

let layout_label = function
  | Compact -> "compact"
  | Detailed -> "detailed"
  | Grouped -> "grouped"

let sort_label = function
  | Priority -> "priority"
  | Recent -> "recent"
  | Oldest -> "oldest"
  | Activity -> "activity"
  | Name -> "name"

let layout_of_string = function
  | "compact" -> Some Compact
  | "detailed" -> Some Detailed
  | "grouped" -> Some Grouped
  | _ -> None

let sort_of_string = function
  | "priority" -> Some Priority
  | "recent" -> Some Recent
  | "oldest" -> Some Oldest
  | "activity" -> Some Activity
  | "name" -> Some Name
  | _ -> None

let waiting_items row =
  match row.waiting with
  | Waiting_unobserved | Waiting_unavailable -> []
  | Waiting_observed waiting -> waiting.Masc.Tui_decode.kwr_waiting_on

let waiting_state row =
  match row.waiting with
  | Waiting_observed waiting -> Some waiting.Masc.Tui_decode.kwr_state
  | Waiting_unobserved | Waiting_unavailable -> None

let waiting_unavailable row =
  match row.waiting with
  | Waiting_unavailable -> true
  | Waiting_observed _ | Waiting_unobserved -> false

let waiting_has_source source items =
  List.exists (fun item -> item.Masc.Tui_decode.kwi_source = source) items

let waiting_has_producer producer items =
  List.exists (fun item -> item.Masc.Tui_decode.kwi_wake_producer = producer) items

let turn_activity row =
  Option.map Masc.Tui_decode.keeper_current_activity_of_turn row.turn

let health_reading row =
  Option.map Masc.Tui_decode.keeper_health_reading
    (Masc_tui_keeper_control.health row.reading)

(* [row.task] follows the producer's current task, and submitting a task clears
   it, so it cannot be relied on to find a task that awaits its verdict. The
   task list keeps that task with the producer as [assignee]. An empty list
   (backlog unread or failed) gives false. *)
let holds_awaiting_verification ~keeper_name tasks =
  List.exists
    (fun { Masc.Tui_decode.status; _ } ->
      match status with
      | Masc_domain.AwaitingVerification { assignee; _ } -> String.equal assignee keeper_name
      | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
      | Masc_domain.Done _ | Masc_domain.Cancelled _ -> false)
    tasks

let async_counts requests =
  List.fold_left
    (fun (running, ownership_unknown, queued, cancelling) request ->
      match request.Masc.Tui_decode.ar_phase with
      | Masc.Tui_decode.Async_running ->
          let ownership_unknown =
            match request.ar_ownership with
            | Masc.Tui_decode.Async_ownership_unknown -> ownership_unknown + 1
            | Masc.Tui_decode.Async_runtime_owned -> ownership_unknown
          in
          running + 1, ownership_unknown, queued, cancelling
      | Masc.Tui_decode.Async_queued -> running, ownership_unknown, queued + 1, cancelling
      | Masc.Tui_decode.Async_cancelling -> running, ownership_unknown, queued, cancelling + 1)
    (0, 0, 0, 0) requests

let primary_activity_of_row row =
  let items = waiting_items row in
  let activity = turn_activity row in
  let health = health_reading row in
  let running, _, queued, cancelling = async_counts row.async_requests in
  let failed =
    health = Some Masc.Tui_decode.Health_failing
    || activity = Some Masc.Tui_decode.Keeper_activity_attempt_failed
  in
  if Option.is_some row.approval || waiting_has_source Waiting_source_hitl_pending items then
    Held_call
  else if row.open_questions > 0 then Question
  else if waiting_has_source Waiting_source_operator_pending_confirm items then Confirmation
  else if failed then Failure
  else if row.reading.Masc_tui_keeper_control.paused then Paused
  else if health = Some Masc.Tui_decode.Health_offline then Offline
  else
    match activity with
    | Some Masc.Tui_decode.Keeper_activity_preparing -> Preparing
    | Some Masc.Tui_decode.Keeper_activity_streaming -> Streaming
    | Some Masc.Tui_decode.Keeper_activity_running -> Running
    | Some Masc.Tui_decode.Keeper_activity_tool -> Tool_waiting
    | Some Masc.Tui_decode.Keeper_activity_waiting -> Model_waiting
    | Some (Masc.Tui_decode.Keeper_activity_idle | Masc.Tui_decode.Keeper_activity_unknown)
    | None -> (
      if running > 0 then Async_working running
      else if waiting_state row = Some Keeper_waiting_deferred then Deferred
      else if waiting_state row = Some Keeper_waiting_busy then Running
      else if waiting_has_producer Wake_keeper_delegate items then Delegate_result
      else if waiting_has_producer Wake_completion_authority items || row.awaiting_verification then
        Verifying
      else if queued > 0 || cancelling > 0 then External_waiting
      else if waiting_state row = Some Keeper_waiting_blocked then External_waiting
      else if (activity = Some Masc.Tui_decode.Keeper_activity_idle
               && not (waiting_unavailable row))
              || waiting_state row = Some Keeper_waiting_idle then Idle
      else Unknown)
    | Some Masc.Tui_decode.Keeper_activity_attempt_failed -> Failure

let badges_of_row row =
  let items = waiting_items row in
  let running, ownership_unknown, queued, cancelling = async_counts row.async_requests in
  [ (if waiting_has_source Waiting_source_read_error items then Some Badge_read_error else None)
  ; (if waiting_unavailable row then Some Badge_waiting_unavailable else None)
  ; (if running > 0 then Some (Badge_async { running; ownership_unknown }) else None)
  ; (if queued > 0 then Some (Badge_async_queued queued) else None)
  ; (if cancelling > 0 then Some (Badge_async_cancelling cancelling) else None)
  ; (if waiting_has_producer Wake_keeper_delegate items then Some Badge_delegate else None)
  ; (if waiting_has_producer Wake_completion_authority items || row.awaiting_verification then
       Some Badge_verification
     else None)
  ; (if waiting_has_source Waiting_source_schedule_waiting items then Some Badge_schedule else None)
  ]
  |> List.filter_map Fun.id

let group_of_row row =
  match primary_activity_of_row row with
  | Held_call | Question | Confirmation | Failure -> Attention
  | Preparing | Streaming | Running | Async_working _ | Deferred -> Active
  | Tool_waiting | Model_waiting | Delegate_result | Verifying | External_waiting -> Waiting
  | Idle | Paused | Offline -> Inactive
  | Unknown -> Unobserved

let attention_rank = function
  | Attention -> 0
  | Active -> 1
  | Waiting -> 2
  | Inactive -> 3
  | Unobserved -> 4

let compare_name left right =
  String.compare left.keeper.Masc.Tui_decode.k_name right.keeper.Masc.Tui_decode.k_name

let compare_recent left right =
  match left.last_activity_at, right.last_activity_at with
  | Some left_at, Some right_at ->
      let order = Float.compare right_at left_at in
      if order = 0 then compare_name left right else order
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> compare_name left right

let compare_oldest left right =
  match left.last_activity_at, right.last_activity_at with
  | Some left_at, Some right_at ->
      let order = Float.compare left_at right_at in
      if order = 0 then compare_name left right else order
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> compare_name left right

let activity_rank = function
  | Held_call -> 0 | Question -> 1 | Confirmation -> 2 | Failure -> 3
  | Preparing -> 4 | Streaming -> 5 | Running -> 6 | Async_working _ -> 7
  | Deferred -> 8 | Tool_waiting -> 9 | Model_waiting -> 10 | Delegate_result -> 11
  | Verifying -> 12 | External_waiting -> 13 | Idle -> 14 | Paused -> 15
  | Offline -> 16 | Unknown -> 17

let order_rows ~layout ~sort rows =
  List.stable_sort
    (fun left right ->
      let group_order =
        match layout with
        | Grouped -> Int.compare (attention_rank (group_of_row left)) (attention_rank (group_of_row right))
        | Compact | Detailed -> 0
      in
      if group_order <> 0 then group_order
      else match sort with
        | Name -> compare_name left right
        | Recent -> compare_recent left right
        | Oldest -> compare_oldest left right
        | Activity ->
            let order = Int.compare (activity_rank (primary_activity_of_row left))
                (activity_rank (primary_activity_of_row right)) in
            if order = 0 then compare_recent left right else order
        | Priority ->
            let order = Int.compare (attention_rank (group_of_row left)) (attention_rank (group_of_row right)) in
            if order = 0 then compare_recent left right else order)
    rows

let group_counts rows =
  List.fold_left
    (fun (attention, active, waiting, inactive, unobserved) row ->
      match group_of_row row with
      | Attention -> attention + 1, active, waiting, inactive, unobserved
      | Active -> attention, active + 1, waiting, inactive, unobserved
      | Waiting -> attention, active, waiting + 1, inactive, unobserved
      | Inactive -> attention, active, waiting, inactive + 1, unobserved
      | Unobserved -> attention, active, waiting, inactive, unobserved + 1)
    (0, 0, 0, 0, 0) rows

type waiting_summary = {
  tool : int;
  model : int;
  external_wait : int;
  delegate : int;
  verification : int;
  background : int;
}

let waiting_summary rows =
  List.fold_left
    (fun summary row ->
      let running, _, _, _ = async_counts row.async_requests in
      let background = summary.background + running in
      match primary_activity_of_row row with
      | Tool_waiting -> { summary with tool = summary.tool + 1; background }
      | Model_waiting -> { summary with model = summary.model + 1; background }
      | External_waiting -> { summary with external_wait = summary.external_wait + 1; background }
      | Delegate_result -> { summary with delegate = summary.delegate + 1; background }
      | Verifying -> { summary with verification = summary.verification + 1; background }
      | Held_call | Question | Confirmation | Failure | Preparing | Streaming | Running
      | Async_working _ | Deferred | Idle | Paused | Offline | Unknown -> summary)
    { tool = 0; model = 0; external_wait = 0; delegate = 0; verification = 0; background = 0 }
    rows
