module Types = Keeper_social_model_types

type phase =
  | Advancing
  | Reactive
  | Stalled
  | Quiet

type event =
  | Progress_observed
  | Signals_pending
  | Goal_idle_timeout
  | All_quiet
  | Failure_observed

type input = {
  has_progress_evidence : bool;
  has_reactive_signal : bool;
  has_active_goals : bool;
  idle_seconds : int;
}

type snapshot = {
  phase : phase;
}

let initial = { phase = Quiet }
let all_phases = [ Advancing; Reactive; Stalled; Quiet ]
let all_events =
  [
    Progress_observed;
    Signals_pending;
    Goal_idle_timeout;
    All_quiet;
    Failure_observed;
  ]

let phase_to_string = function
  | Advancing -> "advancing"
  | Reactive -> "reactive"
  | Stalled -> "stalled"
  | Quiet -> "quiet"

let phase_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "advancing" -> Some Advancing
  | "reactive" -> Some Reactive
  | "stalled" -> Some Stalled
  | "quiet" -> Some Quiet
  | _ -> None

let event_to_string = function
  | Progress_observed -> "progress_observed"
  | Signals_pending -> "signals_pending"
  | Goal_idle_timeout -> "goal_idle_timeout"
  | All_quiet -> "all_quiet"
  | Failure_observed -> "failure_observed"

let event_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "progress_observed" -> Some Progress_observed
  | "signals_pending" -> Some Signals_pending
  | "goal_idle_timeout" -> Some Goal_idle_timeout
  | "all_quiet" -> Some All_quiet
  | "failure_observed" -> Some Failure_observed
  | _ -> None

let model_name = Types.model_id_to_string Types.Magentic_ledger_v1

let has_prefix s prefix =
  let s_len = String.length s and prefix_len = String.length prefix in
  s_len >= prefix_len && String.sub s 0 prefix_len = prefix

let belief_summary_field belief_summary field_name =
  let parts =
    String.split_on_char ';' belief_summary
    |> List.filter_map (fun raw_part ->
           let part = String.trim raw_part in
           let part =
             if has_prefix part "ledger:" then
               String.sub part 7 (String.length part - 7)
             else part
           in
           match String.index_opt part '=' with
           | None -> None
           | Some idx ->
               let key = String.sub part 0 idx |> String.trim in
               let value =
                 String.sub part (idx + 1) (String.length part - idx - 1)
                 |> String.trim
               in
               Some (key, value))
  in
  List.find_map
    (fun (key, value) -> if String.equal key field_name then Some value else None)
    parts

let phase_of_active_desire = function
  | Some "advance_task_progress" -> Some Advancing
  | Some "close_open_loop" -> Some Reactive
  | Some "recover_forward_motion" -> Some Stalled
  | Some "maintain_progress_ledger" -> Some Quiet
  | _ -> None

let phase_of_current_intention = function
  | Some "record_progress_evidence"
  | Some "publish_progress_update" ->
      Some Advancing
  | Some "capture_next_task" | Some "triage_open_signal" -> Some Reactive
  | Some "request_replan" | Some "repair_failed_turn" -> Some Stalled
  | Some "wait_for_delta" -> Some Quiet
  | _ -> None

let snapshot_of_social_state (state : Types.social_state) =
  if not (String.equal (Types.normalize_social_model state.social_model) model_name)
  then None
  else
    let phase =
      match belief_summary_field state.belief_summary "phase" with
      | Some phase -> phase_of_string phase
      | None -> None
    in
    let phase =
      match phase with
      | Some _ -> phase
      | None -> phase_of_active_desire state.active_desire
    in
    let phase =
      match phase with
      | Some _ -> phase
      | None -> phase_of_current_intention state.current_intention
    in
    Option.map (fun phase -> { phase }) phase

let classify_event ~previous (input : input) =
  if input.has_progress_evidence then Progress_observed
  else if input.has_reactive_signal then Signals_pending
  else if
    input.has_active_goals
    && (input.idle_seconds >= 300
       ||
       match previous with
       | Some { phase = Stalled } -> true
       | Some { phase = Advancing | Reactive | Quiet } | None -> false)
  then Goal_idle_timeout
  else All_quiet

let apply_event ~current:_ event =
  let phase =
    match event with
    | Progress_observed -> Advancing
    | Signals_pending -> Reactive
    | Goal_idle_timeout | Failure_observed -> Stalled
    | All_quiet -> Quiet
  in
  { phase }
