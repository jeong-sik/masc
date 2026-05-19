(** Dashboard_goals_types_health — Stage 22 split (was inline in
    dashboard_goals_types.ml).

    Pure goal-phase health classification: health badges, health reason,
    approval matching, keeper assignee resolution, goal FSM state
    projection, and the operator-disposition normalizer.

    Depends on [Dashboard_goals_types_accessor] for the [tree_node]
    record + the [human_duration] helper. Re-included by
    [Dashboard_goals_types] so the public surface is unchanged. *)

open Yojson.Safe.Util
open Dashboard_goals_types_accessor

let goal_phase_to_health = function
  | Goal_phase.Completed -> Some "done"
  | Goal_phase.Paused -> Some "paused"
  | Goal_phase.Blocked | Goal_phase.Dropped -> Some "blocked"
  | Goal_phase.Executing
  | Goal_phase.Awaiting_verification
  | Goal_phase.Awaiting_approval ->
      None

let goal_health_reason ~goal_phase ~blocked_by_receipt ~child_blocked
    ~pending_approvals ~sandbox_risk ~cascade_risk ~fsm_risk ~stalled
    ~stagnation_seconds ~child_at_risk ~linkage_warning_reason
    ~activity_observation ~stagnation_status =
  match goal_phase_to_health goal_phase with
  | Some "done" -> "Goal phase is completed."
  | Some "paused" -> "Goal phase is paused."
  | Some "blocked" -> (
      match goal_phase with
      | Goal_phase.Blocked -> "Goal phase is blocked."
      | Goal_phase.Dropped -> "Goal phase is dropped."
      | Goal_phase.Completed | Goal_phase.Paused | Goal_phase.Executing
      | Goal_phase.Awaiting_verification | Goal_phase.Awaiting_approval ->
          "Goal is blocked.")
  | Some _ | None ->
      if blocked_by_receipt then "Recent keeper execution ended with an error."
      else if child_blocked then "A linked sub-goal is blocked."
      else if pending_approvals > 0 then
        Printf.sprintf "%d approval request(s) are still pending."
          pending_approvals
      else if sandbox_risk then
        "Linked keeper is constrained by the current sandbox or scope."
      else if cascade_risk then
        "Latest keeper run fell back within the configured cascade."
      else if fsm_risk then
        "Linked task is waiting on FSM verification or remediation."
      else if Option.is_some linkage_warning_reason then
        (match linkage_warning_reason with
         | Some "no_linked_tasks" ->
             "Goal has no linked tasks, child goals, or assigned keepers."
         | Some "no_open_work" ->
             "Linked tasks are terminal but none completed successfully."
         | Some "unstaffed" ->
             "Linked tasks exist, but no keeper is assigned or linked."
         | Some reason -> reason
         | None -> "Goal linkage needs attention.")
      else if stalled then
        Printf.sprintf "No linked activity for %s."
          (human_duration stagnation_seconds)
      else if String.equal stagnation_status "unobserved" then
        Printf.sprintf
          "Goal FSM is %s; activity freshness is based only on %s, so stalled is not asserted."
          (Goal_phase.to_string goal_phase) activity_observation
      else if child_at_risk then
        "A linked sub-goal is at risk."
      else
        "Linked tasks and keepers are progressing."

let tree_health ~goal_phase ~blocked_by_receipt ~child_blocked ~at_risk =
  match goal_phase_to_health goal_phase with
  | Some health -> health
  | None ->
      if blocked_by_receipt || child_blocked then "blocked"
      else if at_risk then "at_risk"
      else "on_track"

let tree_badges ~pending_approvals ~sandbox_risk ~cascade_risk ~fsm_risk ~stalled
    ~activity_unobserved =
  let badges = ref [] in
  if pending_approvals > 0 then badges := "awaiting_approval" :: !badges;
  if sandbox_risk then badges := "sandbox" :: !badges;
  if cascade_risk then badges := "cascade" :: !badges;
  if fsm_risk then badges := "task_verification_pending" :: !badges;
  if stalled then badges := "stalled" :: !badges;
  if activity_unobserved then badges := "activity_unobserved" :: !badges;
  List.rev !badges

let approval_matches_goal goal_id approval_json =
  let goal_ids =
    approval_json |> member "goal_ids" |> to_list
    |> List.filter_map to_string_option
  in
  List.mem goal_id goal_ids
  ||
  match approval_json |> member "goal_id" |> to_string_option with
  | Some pending_goal_id -> String.equal pending_goal_id goal_id
  | None -> false

let keeper_name_matches_meta metas name =
  List.exists (fun (meta : Keeper_types.keeper_meta) -> String.equal meta.name name) metas

let keeper_name_of_assignee metas assignee =
  match Keeper_types.canonical_keeper_name_from_agent_name assignee with
  | Some keeper_name -> Some keeper_name
  | None ->
      if keeper_name_matches_meta metas assignee then Some assignee
      else None

let goal_fsm_state_kind = function
  | Goal_phase.Executing -> "executing"
  | Goal_phase.Awaiting_verification -> "verification_gate"
  | Goal_phase.Awaiting_approval -> "approval_gate"
  | Goal_phase.Blocked -> "blocked"
  | Goal_phase.Paused -> "paused"
  | Goal_phase.Completed -> "completed"
  | Goal_phase.Dropped -> "dropped"

let goal_fsm_next_actions ~goal_phase ~has_effective_verifier_policy
    ~require_completion_approval =
  [
    Goal_phase.Request_complete;
    Goal_phase.Approve_completion;
    Goal_phase.Reject_completion;
    Goal_phase.Pause;
    Goal_phase.Resume;
    Goal_phase.Operator_block;
    Goal_phase.Operator_unblock;
    Goal_phase.Drop;
    Goal_phase.Reopen;
  ]
  |> List.filter (fun action ->
         match
           Goal_phase.decide_transition ~phase:goal_phase ~action
             ~has_effective_verifier_policy ~require_completion_approval
         with
         | Ok _ -> true
         | Error _ -> false)
  |> List.map Goal_phase.action_to_string

let goal_fsm_to_json ~effective_policy (goal : Goal_store.goal)
    (node : tree_node) =
  `Assoc
    [
      ("state", Goal_phase.to_yojson goal.phase);
      ("source", `String "goal.phase");
      ("state_kind", `String (goal_fsm_state_kind goal.phase));
      ( "next_actions",
        `List
          (goal_fsm_next_actions ~goal_phase:goal.phase
             ~has_effective_verifier_policy:(Option.is_some effective_policy)
             ~require_completion_approval:goal.require_completion_approval
          |> List.map (fun action -> `String action)) );
      ("activity_observation", `String node.activity_observation);
      ("stagnation_status", `String node.stagnation_status);
    ]

let display_disposition_of_receipt_json receipt =
  (* Previously this defaulted to the literal "unknown", which then hit
     the [| "unknown" -> "Alert"/"unmapped_cascade_state"] arm below.
     That conflated two distinct producer-side failure modes:
     (1) missing [operator_disposition] field — the receipt was emitted
         without the disposition at all (producer bug);
     (2) [operator_disposition = "unknown"] — the producer explicitly
         declared the state unmapped at the cascade layer.

     Using a bracketed sentinel as the default lets the match below
     fall through to the [_ -> "Alert"/"unmapped_operator_disposition"]
     catch-all, which is the more accurate classification for case (1).
     Both cases still surface as "Alert" severity (no operator-visible
     regression in alerting), but the reason label now distinguishes
     them so the operator can chase the right producer fix. *)
  let operator_disposition =
    receipt |> member "operator_disposition" |> to_string_option
    |> Option.value ~default:"<missing operator_disposition field>"
  in
  let operator_disposition_reason =
    receipt |> member "operator_disposition_reason" |> to_string_option
    |> Option.value ~default:""
  in
  let reason fallback =
    match String.trim operator_disposition_reason with
    | "" -> fallback
    | value -> value
  in
  match String.lowercase_ascii operator_disposition with
  | "pass" -> ("Pass", "healthy", operator_disposition, operator_disposition_reason)
  | "skipped" ->
      ("Pass", "phase_skipped", operator_disposition, operator_disposition_reason)
  | "pass_next_model" ->
      ("Pass", "cascade_fallback", operator_disposition, operator_disposition_reason)
  | "blocked" | "blocked_runtime" ->
      ( "Blocked",
        reason "runtime_blocked",
        operator_disposition,
        operator_disposition_reason )
  | "pause_human" ->
      ( "Blocked",
        reason "needs_human_attention",
        operator_disposition,
        operator_disposition_reason )
  | "fail_open_next_cascade" ->
      ( "Blocked",
        reason "degraded_retry",
        operator_disposition,
        operator_disposition_reason )
  | "user_cancelled" ->
      ("Blocked", reason "cancelled", operator_disposition, operator_disposition_reason)
  | "alert_exhausted" ->
      ("Alert", reason "cascade_exhausted", operator_disposition, operator_disposition_reason)
  | "unknown" ->
      ( "Alert",
        reason "unmapped_cascade_state",
        operator_disposition,
        operator_disposition_reason )
  | _ ->
      ( "Alert",
        reason "unmapped_operator_disposition",
        operator_disposition,
        operator_disposition_reason )
