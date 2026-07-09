(** Dashboard_goals_types_builder — Stage 22 split (was inline in
    dashboard_goals_types.ml).

    Pure builders that compose the lower-level projections into
    higher-level structures: convergence ratio, verification policy
    nodes, runtime blocker / trust fallback JSON, and the recursive
    [build_tree] that produces a [tree_node] from a [build_context]
    snapshot.

    Depends on [Dashboard_goals_types_accessor],
    [Dashboard_goals_types_health], and on
    [Keeper_status_bridge] / [Time_compat] / [Json_util] /
    [Masc_domain] for the clock + JSON helpers (no state mutation).
    Re-included by [Dashboard_goals_types] so the public surface is
    unchanged. *)

open Dashboard_goals_types_accessor
open Dashboard_goals_types_health

let compute_convergence (goal : Goal_store.goal) linked_tasks children =
  let goal_done_weight =
    match goal.phase with
    | Goal_phase.Completed -> 1.0
    | Goal_phase.Executing
    | Goal_phase.Awaiting_verification
    | Goal_phase.Awaiting_approval
    | Goal_phase.Blocked
    | Goal_phase.Paused
    | Goal_phase.Dropped ->
        0.0
  in
  let task_count = List.length linked_tasks in
  let done_count =
    List.length
      (List.filter
         (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
         linked_tasks)
  in
  let task_ratio =
    if task_count = 0 then goal_done_weight
    else float_of_int done_count /. float_of_int task_count
  in
  let child_ratios =
    List.map (fun (child : tree_node) -> child.convergence) children
  in
  let child_avg =
    match child_ratios with
    | [] -> task_ratio
    | rs ->
        let sum = List.fold_left ( +. ) 0.0 rs in
        sum /. float_of_int (List.length rs)
  in
  if task_count > 0 && children <> [] then
    (task_ratio +. child_avg) /. 2.0
  else if children <> [] then
    child_avg
  else
    task_ratio

let goal_policy_nodes goals =
  List.map
    (fun (goal : Goal_store.goal) ->
      {
        Goal_verification.goal_id = goal.id;
        parent_goal_id = goal.parent_goal_id;
        verifier_policy = goal.verifier_policy;
      })
    goals

let runtime_blocker_event_from_meta ~config ~(meta : Keeper_meta_contract.keeper_meta) =
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let assoc_string_opt name =
    match List.assoc_opt name runtime_blocker_fields with
    | Some (`String s) -> Some s
    | _ -> None
  in
  let blocker_class = assoc_string_opt "runtime_blocker_class" in
  let blocker_summary = assoc_string_opt "runtime_blocker_summary" in
  let summary =
    match blocker_summary, blocker_class with
    | Some value, _ when String.trim value <> "" -> Some value
    | _, Some value when String.trim value <> "" -> Some value
    | _ -> None
  in
  match summary with
  | None -> None
  | Some summary ->
      let now_ts = Time_compat.now () in
      let now_iso = Masc_domain.now_iso () in
      Some
        (`Assoc
          [
            ("kind", `String "runtime_blocker");
            ("ts", `String now_iso);
            ("ts_unix", `Float now_ts);
            ("observed_at", `String now_iso);
            ("observed_at_unix", `Float now_ts);
            ("observation_only", `Bool true);
            ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
            ("keeper_turn_id", `Null);
            ("task_id", `Null);
            ( "goal_ids",
              `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids)
            );
            ("title", `String "Runtime Blocker");
            ("summary", `String summary);
            ( "severity",
              `String
                (match blocker_class with
                 | Some "runtime_exhausted"
                 | Some "completion_contract_violation" ->
                     "bad"
                 | _ -> "warn") );
            ("next_human_action", `String "inspect_runtime_blocker");
          ])

let runtime_trust_from_receipt_fallback ~config ~(meta : Keeper_meta_contract.keeper_meta)
    receipt =
  let disposition, disposition_reason, operator_disposition,
      operator_disposition_reason =
    display_disposition_of_receipt_json receipt
  in
  let ts =
    receipt_ended_at receipt
    |> Option.value ~default:meta.updated_at
  in
  let turn_id = receipt_turn_count receipt in
  let severity =
    match disposition with
    | "Pass" -> "ok"
    | "Blocked" -> "warn"
    | "Pause" -> "warn"
    | _ -> "bad"
  in
  let latest_event =
    `Assoc
      [
        ("kind", `String "execution_receipt");
        ("ts", `String ts);
        ("keeper_turn_id", Json_util.int_opt_to_json turn_id);
        ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
        ("title", `String "Keeper Execution Receipt");
        ("summary", `String disposition_reason);
        ("severity", `String severity);
      ]
  in
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let causal_timeline =
    let blocker_events =
      runtime_blocker_event_from_meta ~config ~meta
      |> Option.map (fun event -> [ event ])
      |> Option.value ~default:[]
    in
    `List (latest_event :: blocker_events)
  in
  `Assoc
    [
      ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      ("generation", `Int meta.runtime.generation);
      ("turn_id", Json_util.int_opt_to_json turn_id);
      ("phase", `Null);
      ("raw_phase", `Null);
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
      ("disposition", `String disposition);
      ("disposition_reason", `String disposition_reason);
      ("operator_disposition", `String operator_disposition);
      ("operator_disposition_reason", `String operator_disposition_reason);
      ("needs_attention", `Bool (not (String.equal disposition "Pass")));
      ("attention_reason", `Null);
      ("next_human_action", `Null);
      ( "approval",
        `Assoc
          [
            ("state", `String "idle");
            ("summary", `String "idle");
            ("pending_count", `Int 0);
          ] );
      ( "execution_summary",
        `Assoc
          [
            ( "completion_contract_result",
              (* Missing receipt field stays JSON null; this projection does
                 not invent a runtime contract outcome. *)
              (* sound-partial: allow *)
              Option.value ~default:`Null (Json_util.assoc_member_opt "completion_contract_result" receipt) );
            ("latest_receipt_at", `String ts);
          ] );
      ("runtime_blockers", `Assoc runtime_blocker_fields);
      ("latest_causal_event", latest_event);
      ("causal_timeline", causal_timeline);
      ("latest_receipt", receipt);
    ]

type build_context = {
  now_ts : float;
  all_tasks : Masc_domain.task list;
  pending_approvals : Yojson.Safe.t list;
  keeper_metas : Keeper_meta_contract.keeper_meta list;
  latest_receipts : (string * Yojson.Safe.t) list;
  latest_runtime_trusts : (string * Yojson.Safe.t) list;
  goal_task_index : (string, string list) Hashtbl.t;
}

let rec build_tree context goals goal =
  let child_goals =
    List.filter
      (fun (candidate : Goal_store.goal) ->
        candidate.parent_goal_id = Some goal.Goal_store.id)
      goals
  in
  let children = List.map (build_tree context goals) child_goals in
  let linked_tasks =
    context.all_tasks
    |> List.filter_map (fun task ->
           task_linkage_source_opt ~goal_task_index:context.goal_task_index task goal.Goal_store.id
           |> Option.map (fun source -> (task, source)))
  in
  let direct_linkage_source =
    linked_tasks |> List.map snd |> link_source_of_values
  in
  let direct_pending_approvals =
    context.pending_approvals
    |> List.filter (approval_matches_goal goal.Goal_store.id)
  in
  let direct_task_keeper_names =
    linked_tasks
    |> List.filter_map (fun ((task, _) : Masc_domain.task * string) ->
           match task_assignee task with
           | Some assignee ->
               keeper_name_of_assignee context.keeper_metas assignee
           | None -> None)
  in
  let direct_goal_keeper_names =
    context.keeper_metas
    |> List.filter (fun (meta : Keeper_meta_contract.keeper_meta) ->
           List.mem goal.Goal_store.id meta.active_goal_ids)
    |> List.map (fun (meta : Keeper_meta_contract.keeper_meta) -> meta.name)
  in
  let direct_linked_keeper_names =
    dedupe_sort (direct_task_keeper_names @ direct_goal_keeper_names)
  in
  let direct_receipt_refs =
    direct_linked_keeper_names
    |> List.filter_map (fun keeper_name ->
           List.assoc_opt keeper_name context.latest_receipts
           |> Option.map (fun receipt -> (keeper_name, receipt)))
  in
  let direct_receipts =
    direct_receipt_refs |> List.map snd
  in
  let direct_runtime_trusts =
    direct_linked_keeper_names
    |> List.filter_map (fun keeper_name ->
           List.assoc_opt keeper_name context.latest_runtime_trusts
           |> Option.map (fun trust -> (keeper_name, trust)))
  in
  let child_blocked =
    List.exists (fun (child : tree_node) -> String.equal child.health "blocked")
      children
  in
  let child_at_risk =
    List.exists
      (fun (child : tree_node) ->
        String.equal child.health "at_risk"
        || String.equal child.health "blocked")
      children
  in
  let task_activity_values =
    linked_tasks
    |> List.map (fun ((task, _) : Masc_domain.task * string) -> task_updated_at task)
  in
  let approval_activity_values =
    direct_pending_approvals
    |> List.filter_map (fun json ->
           Json_util.get_string json "requested_at_iso")
  in
  let receipt_activity_values =
    direct_receipts |> List.filter_map receipt_ended_at
  in
  let runtime_activity_values =
    direct_runtime_trusts
    |> List.filter_map (fun (_, trust) -> trust_latest_event_ts trust)
  in
  let direct_observed_activity_values =
    task_activity_values @ approval_activity_values @ receipt_activity_values
    @ runtime_activity_values
  in
  let direct_last_activity_values =
    goal.Goal_store.updated_at :: direct_observed_activity_values
  in
  let child_observed_activity_values =
    children
    |> List.filter_map (fun child ->
           if String.equal child.activity_observation "goal_metadata" then None
           else Some child.last_activity_at)
  in
  let child_last_activity_values =
    children |> List.map (fun child -> child.last_activity_at)
  in
  let last_activity_at =
    latest_iso
      ~fallback:goal.Goal_store.updated_at
      (direct_last_activity_values @ child_last_activity_values)
    |> Option.value ~default:goal.Goal_store.updated_at
  in
  let stagnation_seconds =
    int_of_float
      (max 0.0
         (context.now_ts
          -. Masc_domain.parse_iso8601 ~default_time:context.now_ts last_activity_at))
  in
  let direct_sandbox_risk =
    List.exists receipt_has_sandbox_risk direct_receipts
    || List.exists (fun (_, trust) -> trust_sandbox_risk trust) direct_runtime_trusts
  in
  let direct_runtime_risk =
    List.exists receipt_has_runtime_risk direct_receipts
    || List.exists (fun (_, trust) -> trust_runtime_risk trust) direct_runtime_trusts
  in
  let blocked_by_receipt =
    List.exists receipt_has_error direct_receipts
  in
  let direct_runtime_blocking_reason =
    direct_runtime_trusts
    |> List.find_map (fun (_keeper_name, trust) ->
           if trust_snapshot_unavailable trust && direct_receipts <> [] then
             None
           else
             match trust_disposition trust with
             | Some "Alert" ->
                 (match trust_attention_reason trust with
                  | Some _ as reason -> reason
                  | None -> trust_disposition_reason trust)
             | Some ("Blocked" | "Pause") when trust_needs_attention trust ->
                 (match trust_attention_reason trust with
                  | Some _ as reason -> reason
                  | None -> trust_disposition_reason trust)
             | _ -> None)
  in
  let direct_fsm_risk =
    List.exists
      (fun ((task, _) : Masc_domain.task * string) ->
        match task.task_status with
        | Masc_domain.AwaitingVerification _ -> true
        | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.Done _
        | Masc_domain.Cancelled _ | Masc_domain.Operator_blocked _ ->
            false)
      linked_tasks
  in
  let open_linked_task_count =
    linked_tasks
    |> List.filter (fun ((task, _) : Masc_domain.task * string) ->
           not (task_is_terminal task))
    |> List.length
  in
  let done_linked_task_count =
    linked_tasks
    |> List.filter (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
    |> List.length
  in
  let linkage_warning_reason =
    match goal.Goal_store.phase with
    | Goal_phase.Executing
    | Goal_phase.Awaiting_verification
    | Goal_phase.Awaiting_approval ->
        if linked_tasks = [] && children = [] && direct_linked_keeper_names = [] then
          Some "no_linked_tasks"
        else if linked_tasks <> [] && open_linked_task_count = 0
                && done_linked_task_count = 0 then
          Some "no_open_work"
        else if open_linked_task_count > 0 && direct_linked_keeper_names = [] then
          Some "unstaffed"
        else
          None
    | Goal_phase.Completed | Goal_phase.Blocked | Goal_phase.Paused
    | Goal_phase.Dropped ->
        None
  in
  let activity_observation =
    if runtime_activity_values <> [] || receipt_activity_values <> [] then
      "runtime"
    else if approval_activity_values <> [] then
      "approval"
    else if task_activity_values <> [] then
      "task"
    else if child_observed_activity_values <> [] then
      "child"
    else
      "goal_metadata"
  in
  let stale_by_threshold =
    stagnation_seconds >= stagnation_threshold_seconds
  in
  let observed_for_stagnation =
    not (String.equal activity_observation "goal_metadata")
  in
  let stalled = stale_by_threshold && observed_for_stagnation in
  let stagnation_status =
    if stalled then "stalled"
    else if stale_by_threshold then "unobserved"
    else "recent"
  in
  let direct_badges =
    tree_badges ~pending_approvals:(List.length direct_pending_approvals)
      ~sandbox_risk:direct_sandbox_risk ~runtime_risk:direct_runtime_risk
      ~fsm_risk:direct_fsm_risk ~stalled
      ~activity_unobserved:(String.equal stagnation_status "unobserved")
  in
  let direct_badges =
    match linkage_warning_reason with
    | Some reason -> reason :: direct_badges
    | None -> direct_badges
  in
  let badges =
    dedupe_sort
      (direct_badges
       @ List.concat_map (fun (child : tree_node) -> child.badges) children)
  in
  let pending_approval_count =
    List.length direct_pending_approvals
    + List.fold_left
        (fun acc (child : tree_node) -> acc + child.pending_approval_count)
        0 children
  in
  let direct_infra_risk_count =
    List.length
      (List.filter
         (fun json ->
           receipt_has_error json || receipt_has_sandbox_risk json
           || receipt_has_runtime_risk json)
         direct_receipts)
    + List.length
        (List.filter
           (fun (_, trust) ->
             if trust_snapshot_unavailable trust && direct_receipts <> [] then
               false
             else
               match trust_disposition trust with
               | Some "Alert" -> true
               | Some ("Blocked" | "Pause") -> trust_needs_attention trust
               | _ -> false)
           direct_runtime_trusts)
  in
  let infra_risk_count =
    direct_infra_risk_count
    + List.fold_left
        (fun acc (child : tree_node) -> acc + child.infra_risk_count)
        0 children
  in
  let linked_keeper_names =
    dedupe_sort
      (direct_linked_keeper_names
       @ List.concat_map
           (fun (child : tree_node) -> child.linked_keeper_names)
           children)
  in
  let linkage_source =
    link_source_of_values
      (direct_linkage_source
       :: List.map (fun (child : tree_node) -> child.linkage_source) children)
  in
  let linkage_warning_count =
    (if Option.is_some linkage_warning_reason then 1 else 0)
    + List.fold_left
        (fun acc (child : tree_node) -> acc + child.linkage_warning_count)
        0 children
  in
  let at_risk =
    pending_approval_count > 0
    || infra_risk_count > 0
    || Option.is_some direct_runtime_blocking_reason
    || direct_fsm_risk
    || Option.is_some linkage_warning_reason
    || stalled
    || child_at_risk
  in
  let health =
    tree_health ~goal_phase:goal.Goal_store.phase ~blocked_by_receipt
      ~child_blocked ~at_risk
  in
  let status_reason =
    goal_health_reason ~goal_phase:goal.Goal_store.phase ~blocked_by_receipt
      ~child_blocked ~pending_approvals:pending_approval_count
      ~sandbox_risk:direct_sandbox_risk ~runtime_risk:direct_runtime_risk
      ~fsm_risk:direct_fsm_risk ~stalled
      ~stagnation_seconds ~child_at_risk ~linkage_warning_reason
      ~activity_observation ~stagnation_status
  in
  let blocking_source, blocking_reason =
    match goal.Goal_store.phase with
    | Goal_phase.Blocked | Goal_phase.Dropped ->
        ("goal_phase", status_reason)
    | Goal_phase.Completed | Goal_phase.Paused | Goal_phase.Executing
    | Goal_phase.Awaiting_verification | Goal_phase.Awaiting_approval ->
        if child_blocked then
          ("child_goal", "A linked sub-goal is blocked.")
        else if pending_approval_count > 0 then
          ("approval", status_reason)
        else if Option.is_some direct_runtime_blocking_reason then
          ( "keeper_runtime",
            Option.value direct_runtime_blocking_reason ~default:status_reason )
        else if direct_fsm_risk then
          ("task_fsm", status_reason)
        else if Option.is_some linkage_warning_reason then
          ("goal_linkage", status_reason)
        else if stalled then
          ("stalled", status_reason)
        else
          ("none", status_reason)
  in
  let latest_receipt_ref =
    direct_receipt_refs
    |> List.sort (fun (_, left) (_, right) ->
           String.compare
             (Option.value ~default:"" (receipt_ended_at right))
             (Option.value ~default:"" (receipt_ended_at left)))
    |> function
    | (keeper_name, receipt) :: _ -> (Some keeper_name, receipt_turn_count receipt)
    | [] -> (None, None)
  in
  let latest_runtime_ref =
    direct_runtime_trusts
    |> List.filter (fun (_, trust) ->
           Option.is_some (trust_latest_event_ts_unix trust))
    |> List.sort (fun (_, left) (_, right) ->
           Float.compare
             (Option.value ~default:0.0 (trust_latest_event_ts_unix right))
             (Option.value ~default:0.0 (trust_latest_event_ts_unix left)))
    |> function
    | (keeper_name, trust) :: _ -> Some (Some keeper_name, trust_turn_id trust)
    | [] -> None
  in
  let latest_linked_keeper_ref =
    match direct_linked_keeper_names with
    | keeper_name :: _ -> (Some keeper_name, None)
    | [] -> (None, None)
  in
  let latest_keeper_ref, latest_turn_ref =
    match latest_runtime_ref with
    | Some latest -> latest
    | None -> (
        match latest_receipt_ref with
        | Some _, _ -> latest_receipt_ref
        | None, _ -> latest_linked_keeper_ref)
  in
  let stalled_since =
    if stalled then Some last_activity_at else None
  in
  let convergence = compute_convergence goal linked_tasks children in
  {
    goal;
    children;
    tasks = linked_tasks;
    convergence;
    health;
    badges;
    last_activity_at;
    stagnation_seconds;
    linked_keeper_names;
    pending_approval_count;
    infra_risk_count;
    linkage_source;
    linkage_warning_count;
    status_reason;
    blocking_source;
    blocking_reason;
    latest_keeper_ref;
    latest_turn_ref;
    stalled_since;
    activity_observation;
    stagnation_status;
  }
