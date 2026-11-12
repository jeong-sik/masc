type view =
  | Plain
  | By_state
  | By_cause
  | By_time
  | By_memory
  | By_age
  | By_runtime
  | Day_wall

type density = One_line | Two_lines
type sort = Priority | Recent | Oldest | Activity | Name
type attention = Attention | Failing | Active | Waiting | Inactive | Unobserved

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
  open_questions : int;
  async_requests : Masc.Tui_decode.async_request_row list;
  last_activity_at : float option;
}

let next_view = function
  | Plain -> By_state
  | By_state -> By_cause
  | By_cause -> By_time
  | By_time -> By_memory
  | By_memory -> By_age
  | By_age -> By_runtime
  | By_runtime -> Day_wall
  | Day_wall -> Plain

(* Read off the walk itself, so a list of the views cannot name one [v]
   skips. *)
let views =
  let rec walk view =
    let next = next_view view in
    view :: (if next = Plain then [] else walk next)
  in
  walk Plain

let view_label = function
  | Plain -> "list"
  | By_state -> "state"
  | By_cause -> "cause"
  | By_time -> "time"
  | By_memory -> "memory"
  | By_age -> "age"
  | By_runtime -> "runtime"
  | Day_wall -> "24h"

(* The name on the view row. [view_label] is the word the preference file
   stores and reads back, so it stays one spelling in both languages. *)
let view_title ~ko view =
  if not ko then view_label view
  else
    match view with
    | Plain -> "목록"
    | By_state -> "상태"
    | By_cause -> "원인"
    | By_time -> "시간"
    | By_memory -> "기억"
    | By_age -> "나이"
    | By_runtime -> "런타임"
    | Day_wall -> "24시간"

let view_of_string = function
  | "list" -> Some Plain
  | "state" -> Some By_state
  | "cause" -> Some By_cause
  | "time" -> Some By_time
  | "memory" -> Some By_memory
  | "age" -> Some By_age
  | "runtime" -> Some By_runtime
  | "24h" -> Some Day_wall
  | _ -> None

let next_density = function
  | One_line -> Two_lines
  | Two_lines -> One_line

let shows_portrait view density =
  match view, density with
  | Plain, Two_lines -> true
  | Plain, One_line -> false
  | (By_state | By_cause | By_time | By_memory | By_age | By_runtime | Day_wall),
    (One_line | Two_lines) -> false

let density_label = function
  | One_line -> "compact"
  | Two_lines -> "detailed"

let density_of_string = function
  | "compact" -> Some One_line
  | "detailed" -> Some Two_lines
  | _ -> None

let next_sort = function
  | Priority -> Recent
  | Recent -> Oldest
  | Oldest -> Activity
  | Activity -> Name
  | Name -> Priority

let sort_label = function
  | Priority -> "priority"
  | Recent -> "recent"
  | Oldest -> "oldest"
  | Activity -> "activity"
  | Name -> "name"

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

module Names = Set.Make (String)

type verification_holders = Names.t

(* [row.task] follows the producer's current task, and submitting a task clears
   it, so it cannot be relied on to find a task that awaits its verdict. The
   task list keeps that task with the producer as [assignee]. An empty list
   (backlog unread or failed) holds no one. *)
let verification_holders tasks =
  List.fold_left
    (fun holders { Masc.Tui_decode.status; _ } ->
      match status with
      | Masc_domain.AwaitingVerification { assignee; _ } -> Names.add assignee holders
      | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
      | Masc_domain.Done _ | Masc_domain.Cancelled _ -> holders)
    Names.empty tasks

let holds_awaiting_verification holders ~keeper_name = Names.mem keeper_name holders

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

(* What the Keeper is doing now. A failing health reading is not an activity:
   a failing Keeper that runs a probe turn is streaming, and [group_of_row]
   puts it in [Failing] through its trail. *)
let primary_activity_of_row row =
  let items = waiting_items row in
  let activity = turn_activity row in
  let health = health_reading row in
  let running, _, queued, cancelling = async_counts row.async_requests in
  if Option.is_some row.approval || waiting_has_source Waiting_source_hitl_pending items then
    Held_call
  else if row.open_questions > 0 then Question
  else if waiting_has_source Waiting_source_operator_pending_confirm items then Confirmation
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
    | Some Masc.Tui_decode.Keeper_activity_attempt_failed -> Attempt_failed

type person_wait =
  | Held_tool of Masc.Tui_decode.keeper_tool_approval
  | Held_item of Masc.Tui_decode.waiting_item
  | Open_questions of int
  | Confirmation_item of Masc.Tui_decode.waiting_item

(* The same readings, in the same order, as the first three tests of
   [primary_activity_of_row]. *)
let person_wait row =
  let item_of source =
    List.find_opt (fun item -> item.Masc.Tui_decode.kwi_source = source) (waiting_items row)
  in
  match primary_activity_of_row row with
  | Held_call -> (
      match row.approval with
      | Some approval -> Some (Held_tool approval)
      | None ->
          Option.map (fun item -> Held_item item) (item_of Waiting_source_hitl_pending))
  | Question -> Some (Open_questions row.open_questions)
  | Confirmation ->
      Option.map
        (fun item -> Confirmation_item item)
        (item_of Waiting_source_operator_pending_confirm)
  | Attempt_failed | Preparing | Streaming | Running | Async_working _ | Deferred
  | Tool_waiting | Model_waiting | Delegate_result | Verifying | External_waiting | Idle
  | Paused | Offline | Unknown -> None

let badges_of_row row =
  let items = waiting_items row in
  let running, ownership_unknown, queued, cancelling = async_counts row.async_requests in
  [ (if waiting_has_source Waiting_source_read_error items
        || waiting_has_source Waiting_source_observation_unavailable items
     then Some Badge_read_error else None)
  ; (if waiting_unavailable row then Some Badge_waiting_unavailable else None)
  ; (if running > 0 then Some (Badge_async { running; ownership_unknown }) else None)
  ; (if queued > 0 then Some (Badge_async_queued queued) else None)
  ; (if cancelling > 0 then Some (Badge_async_cancelling cancelling) else None)
  ; (if waiting_has_producer Wake_keeper_delegate items then Some Badge_delegate else None)
  ; (if waiting_has_producer Wake_completion_authority items || row.awaiting_verification then
       Some Badge_verification
     else None)
  ; (if waiting_has_source Waiting_source_schedule_waiting items then Some Badge_schedule else None)
  ; (if waiting_has_source Waiting_source_runtime_quota_spent items then Some Badge_quota_spent else None)
  ]
  |> List.filter_map Fun.id

let group_of_activity = function
  | Held_call | Question | Confirmation -> Attention
  | Attempt_failed -> Failing
  | Preparing | Streaming | Running | Async_working _ | Deferred -> Active
  | Tool_waiting | Model_waiting | Delegate_result | Verifying | External_waiting -> Waiting
  | Idle | Paused | Offline -> Inactive
  | Unknown -> Unobserved

let runtime_of_row row =
  match row.reading.Masc_tui_keeper_control.liveness with
  | Masc_tui_keeper_control.Present runtime -> Some runtime
  | Masc_tui_keeper_control.Absent | Masc_tui_keeper_control.Unobserved
  | Masc_tui_keeper_control.Invalid _ -> None

let trail_of_row row =
  Masc_tui_keeper_trail.of_readings
    ~health:(Masc_tui_keeper_control.health row.reading)
    ~runtime:(runtime_of_row row)

let trail_is_failed row =
  match trail_of_row row with
  | Masc_tui_keeper_trail.Trail_failed _ -> true
  | Masc_tui_keeper_trail.Trail_sound -> false

(* A person's decision outranks a failure, so [Attention] keeps its rows. Any
   other row whose trail is failed is in [Failing], whatever it is doing. *)
let group_of ~failing activity =
  match group_of_activity activity with
  | Attention -> Attention
  | Failing -> Failing
  | (Active | Waiting | Inactive | Unobserved) as group -> if failing then Failing else group

let group_of_row row = group_of ~failing:(trail_is_failed row) (primary_activity_of_row row)

let attention_rank = function
  | Attention -> 0
  | Failing -> 1
  | Active -> 2
  | Waiting -> 3
  | Inactive -> 4
  | Unobserved -> 5

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
  | Held_call -> 0 | Question -> 1 | Confirmation -> 2 | Attempt_failed -> 3
  | Preparing -> 4 | Streaming -> 5 | Running -> 6 | Async_working _ -> 7
  | Deferred -> 8 | Tool_waiting -> 9 | Model_waiting -> 10 | Delegate_result -> 11
  | Verifying -> 12 | External_waiting -> 13 | Idle -> 14 | Paused -> 15
  | Offline -> 16 | Unknown -> 17

(* A row's activity reads all of its waiting items and async requests, so
   each row is ranked once before sorting and comparisons read the ranks. *)
type ranked = { row : row; activity : activity; group : attention }

let rank row =
  let activity = primary_activity_of_row row in
  { row; activity; group = group_of ~failing:(trail_is_failed row) activity }

type cause_bucket =
  | Cause_named of Masc_tui_keeper_trail.cause_group
  | Cause_unnamed
  | Cause_recovered
  | Not_failing
  | Cause_paused

type due =
  | Due_late
  | Due_held
  | Due_within_hour
  | Due_within_half_day
  | Due_later
  | Due_none
  | Due_unknown

type memory_follow =
  | Memory_refused
  | Memory_gap
  | Memory_lagging
  | Memory_following
  | Memory_unread

type memory_age =
  | Age_within_3h
  | Age_within_day
  | Age_within_3d
  | Age_older
  | Age_unknown

type outside = { due : due; follow : memory_follow; age : memory_age }

let outside_unread = { due = Due_unknown; follow = Memory_unread; age = Age_unknown }

type group =
  | Group_state of attention
  | Group_cause of cause_bucket
  | Group_due of due
  | Group_memory of memory_follow
  | Group_age of memory_age

let failing_cause_of_row row =
  match trail_of_row row with
  | Masc_tui_keeper_trail.Trail_sound -> Not_failing
  | Masc_tui_keeper_trail.Trail_failed
      { walk = Masc_tui_keeper_trail.Walk_ended { cause; _ }; _ } -> Cause_named cause
  | Masc_tui_keeper_trail.Trail_failed
      { walk =
          Masc_tui_keeper_trail.(
            Walk_no_terminal _ | Walk_no_candidate_failure | Walk_not_captured
            | Walk_unreadable | Walk_absent | Walk_not_applicable)
      ; _ } -> Cause_unnamed

let cause_bucket_of_row ~now row =
  match Masc_tui_keeper_verdict.of_runtime ~now (runtime_of_row row) with
  | Masc_tui_keeper_verdict.Failing _ -> failing_cause_of_row row
  | Masc_tui_keeper_verdict.Recovered -> Cause_recovered
  | Masc_tui_keeper_verdict.Paused -> Cause_paused
  | Masc_tui_keeper_verdict.Sound | Masc_tui_keeper_verdict.Other -> Not_failing

let keeper_name_of_row row = row.keeper.Masc.Tui_decode.k_name

let group_of_view ~now ~outside view row =
  match view with
  | Plain | Day_wall -> None
  | By_state -> Some (Group_state (group_of_row row))
  | By_cause -> Some (Group_cause (cause_bucket_of_row ~now row))
  | By_time -> Some (Group_due (outside ~keeper_name:(keeper_name_of_row row)).due)
  | By_memory -> Some (Group_memory (outside ~keeper_name:(keeper_name_of_row row)).follow)
  | By_age -> Some (Group_age (outside ~keeper_name:(keeper_name_of_row row)).age)
  | By_runtime -> Some (Group_cause (cause_bucket_of_row ~now row))

let failed_half_hours ~now row =
  match runtime_of_row row with
  | None -> None
  | Some runtime ->
      Option.map
        (fun (pulse : Masc.Keeper_turn_pulse.pulse) ->
          let newest = Masc.Keeper_turn_pulse.slot_start now in
          let oldest = newest - Masc.Keeper_turn_pulse.window_seconds + Masc.Keeper_turn_pulse.slot_seconds in
          pulse.slots
          |> List.filter (fun (slot : Masc.Keeper_turn_pulse.slot) ->
               slot.tally.failed + slot.tally.rested > 0 && slot.starts_at >= oldest)
          |> List.map (fun (slot : Masc.Keeper_turn_pulse.slot) -> min newest slot.starts_at)
          |> List.sort_uniq Int.compare |> List.length)
        runtime.Masc.Tui_decode.kr_recent_turns

let day_rank ~now row =
  match runtime_of_row row with
  | Some runtime when not runtime.Masc.Tui_decode.kr_paused &&
      Masc.Tui_decode.keeper_health_reading runtime.kr_health = Masc.Tui_decode.Health_failing -> 0
  | Some runtime when not runtime.Masc.Tui_decode.kr_paused &&
      (Masc.Tui_decode.keeper_health_reading runtime.kr_health = Masc.Tui_decode.Health_running ||
       Masc.Tui_decode.keeper_health_reading runtime.kr_health = Masc.Tui_decode.Health_idle) &&
      (match failed_half_hours ~now row with Some 0 -> true | None | Some _ -> false) -> 2
  | Some _ | None -> 1

(* A slot leaves the last day once every half hour; a due time and a
   snapshot age cross their bounds by the minute. *)
let order_clock_step = function
  | Plain | By_state | By_memory | By_runtime -> None
  | By_time | By_age -> Some 60.
  | By_cause | Day_wall -> Some (float_of_int Masc.Keeper_turn_pulse.slot_seconds)

let cause_rank = function
  | Cause_named cause ->
      (match cause with
       | Masc_tui_keeper_trail.Rate_limited -> 0
       | Masc_tui_keeper_trail.Connection -> 1
       | Masc_tui_keeper_trail.Provider -> 2
       | Masc_tui_keeper_trail.Configuration -> 3
       | Masc_tui_keeper_trail.Input -> 4
       | Masc_tui_keeper_trail.Unusable_reply -> 5
       | Masc_tui_keeper_trail.Effect_fenced -> 6
       | Masc_tui_keeper_trail.Recovery -> 7
       | Masc_tui_keeper_trail.Stopped -> 8
       | Masc_tui_keeper_trail.Server -> 9
       | Masc_tui_keeper_trail.Internal -> 10)
  | Cause_unnamed -> 11
  | Cause_recovered -> 12
  | Not_failing -> 13
  | Cause_paused -> 14

let due_rank = function
  | Due_late -> 0
  | Due_held -> 1
  | Due_within_hour -> 2
  | Due_within_half_day -> 3
  | Due_later -> 4
  | Due_none -> 5
  | Due_unknown -> 6

let follow_rank = function
  | Memory_refused -> 0
  | Memory_gap -> 1
  | Memory_lagging -> 2
  | Memory_following -> 3
  | Memory_unread -> 4

let age_rank = function
  | Age_within_3h -> 0
  | Age_within_day -> 1
  | Age_within_3d -> 2
  | Age_older -> 3
  | Age_unknown -> 4

(* What a view orders by before [sort]: a rank, then a name for the groups
   that are named by the reading itself. *)
let view_key ~now ~outside view ranked =
  match view with
  | Plain -> 0, ""
  | By_state -> attention_rank ranked.group, ""
  | By_cause -> cause_rank (cause_bucket_of_row ~now ranked.row), ""
  | By_time -> due_rank (outside ~keeper_name:(keeper_name_of_row ranked.row)).due, ""
  | By_memory -> follow_rank (outside ~keeper_name:(keeper_name_of_row ranked.row)).follow, ""
  | By_age -> age_rank (outside ~keeper_name:(keeper_name_of_row ranked.row)).age, ""
  | By_runtime -> cause_rank (cause_bucket_of_row ~now ranked.row), ""
  | Day_wall -> day_rank ~now ranked.row, ""

let compare_view_key (left_rank, left_name) (right_rank, right_name) =
  let order = Int.compare left_rank right_rank in
  if order <> 0 then order else String.compare left_name right_name

let compare_sorted sort left right =
  match sort with
  | Name -> compare_name left.row right.row
  | Recent -> compare_recent left.row right.row
  | Oldest -> compare_oldest left.row right.row
  | Activity ->
      let order = Int.compare (activity_rank left.activity) (activity_rank right.activity) in
      if order = 0 then compare_recent left.row right.row else order
  | Priority ->
      let order = Int.compare (attention_rank left.group) (attention_rank right.group) in
      if order = 0 then compare_recent left.row right.row else order

let order_rows ~view ~sort ~now ~outside rows =
  let rows = match view with
    | By_runtime -> List.filter (fun row ->
        match Masc_tui_keeper_verdict.of_runtime ~now (runtime_of_row row) with
        | Masc_tui_keeper_verdict.Failing _ -> true
        | Masc_tui_keeper_verdict.Paused | Masc_tui_keeper_verdict.Recovered
        | Masc_tui_keeper_verdict.Sound | Masc_tui_keeper_verdict.Other -> false) rows
    | Plain | By_state | By_cause | By_time | By_memory | By_age | Day_wall -> rows
  in
  List.map (fun row -> let ranked = rank row in ranked, view_key ~now ~outside view ranked) rows
  |> List.stable_sort (fun (left, left_key) (right, right_key) ->
    let order = compare_view_key left_key right_key in
    if order <> 0 then order else
    let day_order = match view with
      | Day_wall -> compare (failed_half_hours ~now right.row) (failed_half_hours ~now left.row)
      | Plain | By_state | By_cause | By_time | By_memory | By_age | By_runtime -> 0 in
    if day_order <> 0 then day_order else compare_sorted sort left right)
  |> List.map (fun (ranked, _) -> ranked.row)

type stop =
  | Stop_world
  | Stop_heading of group
  | Stop_row of int

type heading_focus = { heading : group; cursor_at : int }

type focus = Focus_heading of heading_focus | Focus_world

let has_world = function
  | By_memory | By_age -> true
  | Plain | By_state | By_cause | By_time | By_runtime | Day_wall -> false

let keeper_position = function
  | Some (Stop_row position) -> Some position
  | Some (Stop_world | Stop_heading _) | None -> None

type group_direction = Previous_group | Next_group

type fold_change = Fold | Unfold

(* [groups] holds the group of each ordered row, and the rows of one group
   are next to each other, so a heading opens each run. *)
let stops ~view ~folded groups =
  let rec walk previous position acc = function
    | [] -> List.rev acc
    | None :: rest -> walk None (position + 1) (Stop_row position :: acc) rest
    | (Some group as current) :: rest ->
        let acc = if current = previous then acc else Stop_heading group :: acc in
        let acc = if List.mem group folded then acc else Stop_row position :: acc in
        walk current (position + 1) acc rest
  in
  let rows = walk None 0 [] groups in
  if has_world view then Stop_world :: rows else rows

let current_stop ~view ~folded ~focus ~cursor groups =
  if has_world view && focus = Some Focus_world then Some Stop_world
  else match groups with
  | [] -> if has_world view then Some Stop_world else None
  | _ :: _ ->
      let position = max 0 (min cursor (List.length groups - 1)) in
      (match List.nth groups position, focus with
       | Some group, Some (Focus_heading { heading; cursor_at })
         when cursor_at = cursor && group = heading -> Some (Stop_heading heading)
       | Some group, (Some (Focus_heading _ | Focus_world) | None) when List.mem group folded -> Some (Stop_heading group)
       | (Some _ | None), (Some (Focus_heading _ | Focus_world) | None) -> Some (Stop_row position))

let placement ~view groups = function
  | Stop_world -> if has_world view then Some (Some Focus_world, 0) else None
  | Stop_row position -> Some (None, position)
  | Stop_heading heading ->
      Option.map
        (fun first -> Some (Focus_heading { heading; cursor_at = first }), first)
        (List.find_index (( = ) (Some heading)) groups)

let step_stop ~delta stops current =
  Option.bind (List.find_index (( = ) current) stops) (fun index ->
    List.nth_opt stops (max 0 (min (List.length stops - 1) (index + delta))))

let group_jump direction stops current =
  let is_heading = function Stop_heading _ -> true | Stop_world | Stop_row _ -> false in
  Option.bind (List.find_index (( = ) current) stops) (fun index ->
    List.find_opt is_heading
      (match direction with
       | Previous_group -> List.rev (List.take index stops)
       | Next_group -> List.drop (index + 1) stops))

let refold change group folded =
  let others = List.filter (fun other -> other <> group) folded in
  match change with
  | Fold -> group :: others
  | Unfold -> others

let initially_folded ~count = function
  | Group_cause Cause_recovered | Group_cause Cause_paused
  | Group_due Due_none | Group_memory Memory_following | Group_memory Memory_unread
  | Group_age Age_within_day | Group_age Age_unknown -> true
  | Group_cause Not_failing -> count > 4
  | Group_cause (Cause_named _ | Cause_unnamed) | Group_state _
  | Group_due (Due_late | Due_held | Due_within_hour | Due_within_half_day | Due_later | Due_unknown)
  | Group_memory (Memory_refused | Memory_gap | Memory_lagging)
  | Group_age (Age_within_3h | Age_within_3d | Age_older) -> false

let first_folds ~seen ~folded groups =
  List.fold_left (fun (seen, folded) -> function
    | None -> seen, folded
    | Some group ->
        if List.mem group seen then seen, folded
        else
          let count = List.length (List.filter (( = ) (Some group)) groups) in
          group :: seen, (if initially_folded ~count group then refold Fold group folded else folded))
    (seen, folded) groups

type group_counts = {
  attention_rows : int;
  failing_rows : int;
  active_rows : int;
  waiting_rows : int;
  inactive_rows : int;
  unobserved_rows : int;
}

let group_counts rows =
  List.fold_left
    (fun counts row ->
      match group_of_row row with
      | Attention -> { counts with attention_rows = counts.attention_rows + 1 }
      | Failing -> { counts with failing_rows = counts.failing_rows + 1 }
      | Active -> { counts with active_rows = counts.active_rows + 1 }
      | Waiting -> { counts with waiting_rows = counts.waiting_rows + 1 }
      | Inactive -> { counts with inactive_rows = counts.inactive_rows + 1 }
      | Unobserved -> { counts with unobserved_rows = counts.unobserved_rows + 1 })
    { attention_rows = 0; failing_rows = 0; active_rows = 0; waiting_rows = 0
    ; inactive_rows = 0; unobserved_rows = 0 }
    rows

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
      let activity = primary_activity_of_row row in
      match group_of ~failing:(trail_is_failed row) activity with
      | Attention | Failing | Active | Inactive | Unobserved -> summary
      | Waiting -> (
          let running, _, _, _ = async_counts row.async_requests in
          let background = summary.background + running in
          match activity with
          | Tool_waiting -> { summary with tool = summary.tool + 1; background }
          | Model_waiting -> { summary with model = summary.model + 1; background }
          | External_waiting ->
              { summary with external_wait = summary.external_wait + 1; background }
          | Delegate_result -> { summary with delegate = summary.delegate + 1; background }
          | Verifying -> { summary with verification = summary.verification + 1; background }
          | Held_call | Question | Confirmation | Attempt_failed | Preparing | Streaming
          | Running | Async_working _ | Deferred | Idle | Paused | Offline | Unknown -> summary))
    { tool = 0; model = 0; external_wait = 0; delegate = 0; verification = 0; background = 0 }
    rows
