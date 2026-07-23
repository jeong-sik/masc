(** Dashboard_goals_types_builder — Stage 22 split (was inline in
    dashboard_goals_types.ml).

    Pure builders that compose the lower-level projections into
    the recursive [build_tree] that produces a [tree_node] from a
    [build_context] snapshot.

    Depends on [Dashboard_goals_types_accessor],
    [Dashboard_goals_types_health], and on [Json_util] / [Masc_domain]
    for JSON and timestamp helpers (no state mutation).
    Re-included by [Dashboard_goals_types] so the public surface is
    unchanged. *)

open Dashboard_goals_types_accessor
open Dashboard_goals_types_health

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
  let task_activity_values =
    linked_tasks
    |> List.map (fun ((task, _) : Masc_domain.task * string) -> task_updated_at task)
  in
  let approval_activity_values =
    direct_pending_approvals
    |> List.filter_map (fun json ->
           Json_util.get_float json "requested_at"
           |> Option.map Masc_domain.iso8601_of_unix_seconds)
  in
  let receipt_activity_values =
    direct_receipts |> List.filter_map receipt_ended_at
  in
  let runtime_activity_values =
    direct_runtime_trusts
    |> List.filter_map (fun (_, trust) -> trust_latest_event_ts trust)
  in
  let timestamped source values =
    values
    |> List.filter_map (fun raw ->
           Masc_domain.parse_iso8601_opt raw
           |> Option.map (fun ts -> (ts, raw, source)))
  in
  let activity_candidates =
    timestamped "task" task_activity_values
    @ timestamped "approval" approval_activity_values
    @ timestamped "runtime" (receipt_activity_values @ runtime_activity_values)
    @ timestamped "goal_metadata" [ goal.Goal_store.updated_at ]
    |> List.sort (fun (left, _, _) (right, _, _) -> Float.compare right left)
  in
  let last_activity_at, last_activity_ts, activity_observation =
    match activity_candidates with
    | [] -> (goal.Goal_store.updated_at, None, "unavailable")
    | (latest_ts, raw, source) :: rest ->
        let latest_sources =
          source
          :: (rest
              |> List.filter_map (fun (ts, _, candidate_source) ->
                     if Float.equal ts latest_ts then Some candidate_source
                     else None))
          |> dedupe_sort
        in
        ( raw,
          Some latest_ts,
          match latest_sources with
          | [ latest_source ] -> latest_source
          | _ -> "multiple" )
  in
  let stagnation_seconds =
    last_activity_ts
    |> Option.map (fun ts -> int_of_float (max 0.0 (context.now_ts -. ts)))
  in
  let receipt_ref_candidates =
    direct_receipt_refs
    |> List.filter_map (fun (keeper_name, receipt) ->
           Option.bind (receipt_ended_at receipt) Masc_domain.parse_iso8601_opt
           |> Option.map (fun ts -> (ts, keeper_name, receipt_turn_count receipt)))
  in
  let runtime_ref_candidates =
    direct_runtime_trusts
    |> List.filter_map (fun (keeper_name, trust) ->
           trust_latest_event_ts_unix trust
           |> Option.map (fun ts -> (ts, keeper_name, trust_turn_id trust)))
  in
  let latest_keeper_ref, latest_turn_ref =
    match
      receipt_ref_candidates @ runtime_ref_candidates
      |> List.sort (fun (left, _, _) (right, _, _) -> Float.compare right left)
    with
    | [] -> (None, None)
    | (latest_ts, keeper_name, turn_id) :: rest ->
        let latest_refs =
          (keeper_name, turn_id)
          :: (rest
              |> List.filter_map (fun (ts, candidate_keeper, candidate_turn) ->
                     if Float.equal ts latest_ts then
                       Some (candidate_keeper, candidate_turn)
                     else None))
          |> List.sort_uniq compare
        in
        (match latest_refs with
         | [ (latest_keeper, latest_turn) ] ->
             (Some latest_keeper, latest_turn)
         | _ -> (None, None))
  in
  {
    goal;
    children;
    tasks = linked_tasks;
    last_activity_at;
    stagnation_seconds;
    linked_keeper_names = direct_linked_keeper_names;
    pending_approval_count = List.length direct_pending_approvals;
    linkage_source = direct_linkage_source;
    latest_keeper_ref;
    latest_turn_ref;
    activity_observation;
  }
