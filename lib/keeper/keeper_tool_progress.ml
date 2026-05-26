(** Keeper_tool_progress - tool progress classification and required-action
    contract helpers. *)

(** Keeper tool progress classes are the shared contract between required-tool
    validation, runtime receipts, and liveness metrics. Keep these classes
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
  Tool_name.[ Masc Claim_next; Keeper Task_claim ] |> List.map Tool_name.to_string
;;

let completion_tool_names : string list =
  (* Stay_silent is the explicit "no work for me this turn" decisive no-op.
     LLM evaluates the situation via passive reads, then signals stay_silent to
     terminate the turn intentionally. Classifying it as Completion lets the
     contract accept the turn as satisfied; abuse is bounded separately by
     keeper_stay_silent_loop_detector (consecutive-stay metric + circuit
     breaker). Without this, 4+ events/day were rejected as passive_only even
     though the LLM had decided no fit (sangsu/janitor/taskmaster on 2026-04-27
     00:17-00:58 UTC, idle_seconds 28-40h, claimable_count 44-46). *)
  Tool_name.
    [ Masc Deliver
    ; Keeper Stay_silent
    ; Keeper Task_done
    ; Keeper Task_force_done
    ; Keeper Task_force_release
    ; Keeper Task_submit_for_verification
    ]
  |> List.map Tool_name.to_string
;;

let is_claim_tool_name name =
  let name = Keeper_tool_resolution.canonical_tool_name name in
  match Tool_name.of_string name with
  | Some (Keeper Task_claim) | Some (Masc Claim_next) -> true
  | _ -> false
;;

let is_claim_context_tool_name name =
  let name = Keeper_tool_resolution.canonical_tool_name name in
  let canonical_name =
    match Tool_name.of_string name with
    | Some tool -> Tool_name.to_string tool
    | None -> name
  in
  List.mem canonical_name claim_context_tool_names
;;

let is_completion_tool_name name =
  let name = Keeper_tool_resolution.canonical_tool_name name in
  let canonical_name =
    match Tool_name.of_string name with
    | Some tool -> Tool_name.to_string tool
    | None -> name
  in
  List.mem canonical_name completion_tool_names
;;

let is_stay_silent_tool_name name =
  let name = Keeper_tool_resolution.canonical_tool_name name in
  match Tool_name.of_string name with
  | Some (Keeper Stay_silent) -> true
  | _ -> false
;;

let is_keeper_observation_alias name =
  match Keeper_tool_alias.strip_mcp_masc_prefix name with
  | "SearchFiles" | "ReadFile" -> true
  | _ -> false
;;

let tool_name_can_satisfy_required_contract name =
  let observation_alias = is_keeper_observation_alias name in
  let name = Keeper_tool_resolution.canonical_tool_name name in
  (* Completion tools (stay_silent, release, done, etc.) intentionally satisfy
     the contract even though their effect_domain is Read_only. Without this
     exemption, analyst/janitor keepers that correctly call keeper_stay_silent
     alongside status reads trigger false contract violations - observed
     2026-04-28 when agent_code-spark returned stay_silent + keeper_task_list
     on an actionable signal. *)
  if observation_alias
  then false
  else if is_completion_tool_name name
  then true
  else (
    match Tool_catalog.effect_domain name with
    | Some Tool_catalog.Read_only -> false
    | Some
        ( Tool_catalog.Masc_coordination
        | Tool_catalog.Playground_write
        | Tool_catalog.Main_worktree_write ) -> true
    | None -> not (Tool_dispatch.is_read_only name))
;;

let required_tool_satisfaction ?(satisfying_tools : string list = [])
  (call : Agent_sdk.Completion_contract.tool_call)
  : (unit, string) result
  =
  let tool_name = Keeper_tool_resolution.canonical_tool_name call.name in
  (* Generic Require_tool_use is a required-action contract at the keeper
     boundary. Passive read/status/search tools can support a later action, but
     they must not satisfy the action predicate by themselves. *)
  if is_completion_tool_name tool_name
  then Ok ()
  else (
    let mutates =
      match Tool_catalog.effect_domain tool_name with
      | Some Tool_catalog.Read_only -> false
      | _ ->
        Keeper_exec_tools.has_mutating_side_effect_with_input ~tool_name ~input:call.input
    in
    if mutates
    then Ok ()
    else
      let base_msg =
        Printf.sprintf
          "tool '%s' is read-only/passive and cannot satisfy a required-tool contract"
          tool_name
      in
      match satisfying_tools with
      | [] -> Error base_msg
      | _ ->
        Error
          (Printf.sprintf
             "%s. Call one of these instead: [%s]"
             base_msg
             (String.concat "; " satisfying_tools)))
;;

let required_tool_satisfaction_for_required_names
      ?(satisfying_tools : string list = [])
      ~(required_tool_names : string list)
      (call : Agent_sdk.Completion_contract.tool_call)
  : (unit, string) result
  =
  let required_tool_names =
    required_tool_names
    |> List.map Keeper_tool_resolution.canonical_tool_name
    |> Keeper_types.dedupe_keep_order
  in
  let tool_name = Keeper_tool_resolution.canonical_tool_name call.name in
  if List.mem tool_name required_tool_names
  then Ok ()
  else required_tool_satisfaction ~satisfying_tools call
;;

let required_tool_satisfaction_for_turn
      ?(satisfying_tools : string list = [])
      ~(required_tool_names : string list)
      (call : Agent_sdk.Completion_contract.tool_call)
  : (unit, string) result
  =
  match required_tool_names with
  | [] -> Ok ()
  | _ -> required_tool_satisfaction_for_required_names ~satisfying_tools ~required_tool_names call
;;

let parse_tool_csv text =
  text
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun tool -> tool <> "")
  |> Keeper_types.dedupe_keep_order
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
    else if tool_name_can_satisfy_required_contract name
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
  | Some (Keeper_tool_outcome.No_progress { reason = Resource_conflict _ | No_work_available })
  | Some (Keeper_tool_outcome.Progress | Keeper_tool_outcome.Error _)
  | None -> effect_of_progress_class (classify_tool_progress name)
;;

let is_owned_task_coordination_progress_tool_name name =
  let name = Keeper_tool_resolution.canonical_tool_name name in
  match Tool_name.of_string name with
  | Some (Tool_name.Keeper Tool_name.Keeper.Handoff) -> true
  | _ -> false
;;

let is_owned_task_progress_tool_name name =
  if is_stay_silent_tool_name name
  then false
  else (
    let name = Keeper_tool_resolution.canonical_tool_name name in
    if is_completion_tool_name name || is_owned_task_coordination_progress_tool_name name
    then true
    else (
      match Tool_catalog.effect_domain name with
      | Some (Tool_catalog.Playground_write | Tool_catalog.Main_worktree_write) -> true
      | Some Tool_catalog.Masc_coordination | Some Tool_catalog.Read_only | None -> false))
;;

let is_actionable_signal_progress_tool_name name =
  (not (is_stay_silent_tool_name name)) && tool_name_can_satisfy_required_contract name
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

(* #10091: record a [require_tool_use] contract violation with the labels the
   operator needs to fix the underlying cause (tool_preset mismatch vs.
   active-task refusal vs. cohort misconfiguration). Split out of
   [keeper_agent_run.ml] so the counter emission is directly testable without
   standing up a full OAS/Eio harness. [contract_status] is the same string
   already assigned to [receipt_tool_contract_result_ref] at the call site, so
   receipt JSON and fleet metric share one vocabulary. *)
let record_require_tool_use_violation
      ~(keeper_name : string)
      ~(has_current_task : bool)
      ~(contract_status : string)
  : unit
  =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_require_tool_use_violations
    ~labels:
      [ "keeper", keeper_name
      ; ("has_current_task", if has_current_task then "true" else "false")
      ; "contract_status", contract_status
      ]
    ()
;;

let actionable_signal_context_phrase = function
  | Keeper_contract_classifier.No_actionable_signal_context -> None
  | Keeper_contract_classifier.Turn_affordance_requires_tool ->
    Some "actionable keeper tool gate (turn_affordance_requires_tool)"
  | Keeper_contract_classifier.Keeper_world_signal signal ->
    Some
      (Printf.sprintf
         "actionable keeper signal (%s)"
         (Keeper_contract_classifier.actionable_signal_label signal))
;;

let actionable_tool_contract_violation_reason
      ~(claim_context_allowed : bool)
      ~(actionable_signal_context :
          Keeper_contract_classifier.actionable_signal_context)
      ~(tool_names : string list)
  : string option
  =
  match actionable_signal_context_phrase actionable_signal_context with
  | None -> None
  | Some context_phrase ->
    (match tool_names with
     | [] ->
       Some
         (Printf.sprintf "%s was present, but the model called no keeper tools"
            context_phrase)
     | names
       when List.exists
              (if claim_context_allowed
               then is_actionable_signal_progress_tool_name
               else is_owned_task_progress_tool_name)
              names -> None
     | names
       when (not claim_context_allowed)
            && not (List.exists is_owned_task_progress_tool_name names) ->
       Some
         (Printf.sprintf
            "%s was present for an owned active task, but the model only used \
             passive/claim/stay_silent tools without execution progress: %s"
            context_phrase
            (String.concat ", " names))
     | names when List.exists is_stay_silent_tool_name names ->
       Some
         (Printf.sprintf
            "%s was present, but the model used keeper_stay_silent without typed \
             no-work proof: %s"
            context_phrase
            (String.concat ", " names))
     | names
       when List.for_all
              (fun name -> not (tool_name_can_satisfy_required_contract name))
              names ->
       Some
         (Printf.sprintf
            "%s was present, but the model only used passive status/read tools: %s"
            context_phrase
            (String.concat ", " names))
     | names
       when (not claim_context_allowed) && List.for_all is_claim_context_tool_name names ->
       Some
         (Printf.sprintf
            "%s was present, but the model only used claim/context tools without \
             execution progress: %s"
            context_phrase
            (String.concat ", " names))
     | _ -> None)
;;
