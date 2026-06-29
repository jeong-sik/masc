(** Keeper_tool_progress - tool progress classification helpers. *)

(** Keeper tool progress classes are shared by runtime receipts and liveness
    metrics. Keep these classes
    conservative: state/reporting tools do not count as productive progress,
    and claim tools only bind work; execution or completion tools are what
    prove the keeper is alive past task pickup. *)
type tool_progress_class =
  | Passive_status
  | Claim_context
  | Execution
  | Completion

let tool_progress_class_to_string = function
  | Passive_status -> "passive_status"
  | Claim_context -> "claim_context"
  | Execution -> "execution"
  | Completion -> "completion"
;;

(** [turn_effect] abstracts the 4 tool-progress classes into the 3 actual
    effects they have on the turn FSM. The existing 4-class classification
    collapses to 2 effects (increment streak / reset streak); we add a third
    for task-555 idle-loop prevention.

    - [Streak_increment]: Passive_status, Claim_context - read-only or
      context-binding turns that do not prove liveness.
    - [Streak_reset]: Execution, Completion - turns that materially advance or
      complete work.
    - [Streak_reset_and_empty_queue_sleep]: the keeper legitimately has no work
      to do (all tasks scope-excluded, no claimed task, etc.). Resets the
      streak and signals the phase gate to enter EmptyQueueSleep.

    @since task-555 *)
type turn_effect =
  | Streak_increment
  | Streak_reset
  | Streak_reset_and_empty_queue_sleep of {
      reason : empty_queue_reason;
    }

and empty_queue_reason =
  | No_eligible_tasks of {
      scope_excluded_count : int;
      all_goals_excluded : bool;
    }
  | No_work_to_report
;;

let effect_of_progress_class = function
  | Passive_status | Claim_context -> Streak_increment
  | Execution | Completion -> Streak_reset
;;

let claim_context_tool_names : string list =
  [ Keeper_tool_name.(to_string Task_claim) ]
;;

let completion_tool_names : string list =
  "masc_deliver"
  :: List.map
       Keeper_tool_name.to_string
       Keeper_tool_name.[ Task_done ]
;;

let is_claim_tool_name name =
  let name = Keeper_tool_resolution.canonical_tool_name name in
  List.mem name claim_context_tool_names
;;

let is_claim_context_tool_name name =
  let name = Keeper_tool_resolution.canonical_tool_name name in
  List.mem name claim_context_tool_names
;;

let is_completion_tool_name name =
  let name = Keeper_tool_resolution.canonical_tool_name name in
  List.mem name completion_tool_names
;;

let is_keeper_observation_alias name =
  match Keeper_tool_alias.strip_mcp_masc_prefix name with
  | "Grep" | "Read" -> true
  | _ -> false
;;

let effect_domain_for_tool_name name =
  Keeper_tool_descriptor_resolution.effect_domain_for_tool_name name
;;

let parse_tool_csv text =
  text
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun tool -> tool <> "")
  |> Keeper_types_profile_toml_normalizers.dedupe_keep_order
;;

let satisfying_tools_from_contract_violation_reason reason =
  let marker = "Satisfying tools for this contract: [" in
  match String_util.find_substring reason marker with
  | None -> []
  | Some marker_start ->
    let tools_start = marker_start + String.length marker in
    (match String_util.find_substring ~pos:tools_start reason "]" with
     | None -> []
     | Some tools_end ->
       String.sub reason tools_start (tools_end - tools_start) |> parse_tool_csv)
;;

let classify_tool_progress name =
  if is_keeper_observation_alias name
  then Passive_status
  else (
    let name = Keeper_tool_resolution.canonical_tool_name name in
    if is_completion_tool_name name
    then Completion
    else if is_claim_context_tool_name name
    then Claim_context
    else if
      Keeper_tool_capability_axis.supports Board_activity name
      ||
      match effect_domain_for_tool_name name with
      | Some (Tool_catalog.Playground_write | Tool_catalog.Host_repo_write) -> true
      | Some Tool_catalog.Masc_workspace | Some Tool_catalog.Read_only | None -> false
    then Execution
    else Passive_status)
;;

(** [classify_tool_progress_with_outcome] routes the legacy name-based
    classification through the typed-outcome channel when available.

    The critical path for task-555: a [Claim_context] tool such as
    [keeper_task_claim] that returns [No_progress (No_eligible_tasks _)] must
    produce [Streak_reset_and_empty_queue_sleep], not [Streak_increment].
    Without this override the keeper enters an idle loop of claim -> extend ->
    claim.

    @since task-555 *)
let classify_tool_progress_with_outcome name outcome =
  match outcome with
  | Some
      (Keeper_tool_outcome.No_progress
         { reason = No_eligible_tasks { scope_excluded_count; all_goals_excluded } }) ->
    Streak_reset_and_empty_queue_sleep
      { reason = No_eligible_tasks { scope_excluded_count; all_goals_excluded } }
  | Some (Keeper_tool_outcome.No_progress { reason = No_work_available }) ->
    Streak_reset_and_empty_queue_sleep { reason = No_work_to_report }
  | Some (Keeper_tool_outcome.No_progress { reason = Resource_conflict _ })
  | Some (Keeper_tool_outcome.Progress | Keeper_tool_outcome.Error _)
  | None -> effect_of_progress_class (classify_tool_progress name)
;;

let is_owned_task_progress_tool_name name =
  let name = Keeper_tool_resolution.canonical_tool_name name in
  if is_claim_context_tool_name name
  then false
  else if is_completion_tool_name name
  then true
  else if Keeper_tool_capability_axis.supports Board_activity name
  then true
  else (
    match effect_domain_for_tool_name name with
    | Some (Tool_catalog.Playground_write | Tool_catalog.Host_repo_write) -> true
    | Some Tool_catalog.Masc_workspace | Some Tool_catalog.Read_only | None -> false)
;;

let is_passive_status_tool_name name =
  match classify_tool_progress name with
  | Passive_status -> true
  | Claim_context | Execution | Completion -> false
;;

let is_execution_progress_tool_name name =
  match classify_tool_progress name with
  | Execution | Completion -> true
  | Passive_status | Claim_context -> false
;;

let result_text_for_progress_check output_text =
  match Tool_output.decode_from_oas output_text with
  | Tool_output.Stored { preview; _ } -> preview
  | Tool_output.Inline value -> value
;;

let tool_result_has_material_progress ~tool_name:_ ~(output_text : string) : bool =
  let output_text = result_text_for_progress_check output_text |> String.trim in
  not (String.equal output_text "")
;;
