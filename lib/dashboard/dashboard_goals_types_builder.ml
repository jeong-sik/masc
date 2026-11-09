(** Dashboard_goals_types_builder — pure builders that compose the
    lower-level projections into [build_tree], which produces a [tree_node]
    from a [build_context] snapshot.

    Depends on [Dashboard_goals_types_accessor],
    [Dashboard_goals_types_health], and on [Json_util] / [Masc_domain] for
    JSON and timestamp helpers (no state mutation). Re-included by
    [Dashboard_goals_types]. *)

open Dashboard_goals_types_accessor

module String_map = Map.Make (String)
module String_set = Set.Make (String)

type build_context = {
  now_ts : float;
  all_tasks : Masc_domain.task list;
  pending_approvals : Yojson.Safe.t list;
  keeper_metas : Keeper_meta_contract.keeper_meta list;
  latest_receipts : (string * Yojson.Safe.t) list;
  runtime_trust_of : string -> Yojson.Safe.t option;
  goal_task_index : (string, string list) Hashtbl.t;
}

let approval_goal_ids approval_json =
  let ids = Json_util.get_string_list approval_json "goal_ids" in
  let all_ids =
    match Json_util.get_string approval_json "goal_id" with
    | Some pending_goal_id -> pending_goal_id :: ids
    | None -> ids
  in
  String_set.of_list all_ids
;;

(* Goals are flat: every goal is a root, so [children] is always empty. The
   field stays on the node because the JSON shape and its consumers are
   unchanged.
   Pre-indexing [all_tasks], [pending_approvals], [keeper_metas], and
   [latest_receipts] once when [build_tree context] is partially applied
   turns forest construction from O(G * (T + A + K)) into
   O((T + A + K) log (G + K)). *)
let build_tree context =
  let tasks_by_goal_id =
    let rev_map =
      List.fold_left
        (fun acc (task : Masc_domain.task) ->
           let goal_ids =
             Option.value
               (Hashtbl.find_opt context.goal_task_index task.id)
               ~default:[]
             |> String_set.of_list
           in
           String_set.fold
             (fun goal_id inner_acc ->
                let existing =
                  Option.value (String_map.find_opt goal_id inner_acc) ~default:[]
                in
                String_map.add goal_id (task :: existing) inner_acc)
             goal_ids
             acc)
        String_map.empty
        context.all_tasks
    in
    String_map.map List.rev rev_map
  in
  let approvals_by_goal_id =
    let rev_map =
      List.fold_left
        (fun acc approval_json ->
           String_set.fold
             (fun goal_id inner_acc ->
                let existing =
                  Option.value (String_map.find_opt goal_id inner_acc) ~default:[]
                in
                String_map.add goal_id (approval_json :: existing) inner_acc)
             (approval_goal_ids approval_json)
             acc)
        String_map.empty
        context.pending_approvals
    in
    String_map.map List.rev rev_map
  in
  let keeper_name_set =
    List.fold_left
      (fun acc (meta : Keeper_meta_contract.keeper_meta) ->
         String_set.add meta.name acc)
      String_set.empty
      context.keeper_metas
  in
  let latest_receipts_by_keeper =
    List.fold_left
      (fun acc (keeper_name, receipt) ->
         String_map.update
           keeper_name
           (function
            | Some _ as existing -> existing
            | None -> Some receipt)
           acc)
      String_map.empty
      context.latest_receipts
  in
  fun goal ->
    let children = [] in
    let linked_tasks =
      Option.value
        (String_map.find_opt goal.Goal_store.id tasks_by_goal_id)
        ~default:[]
    in
    let direct_pending_approvals =
      Option.value
        (String_map.find_opt goal.Goal_store.id approvals_by_goal_id)
        ~default:[]
    in
    let direct_task_keeper_names =
      linked_tasks
      |> List.filter_map (fun (task : Masc_domain.task) ->
             match task_assignee task with
             | Some assignee when String_set.mem assignee keeper_name_set ->
               Some assignee
             | Some _ | None -> None)
    in
    let direct_linked_keeper_names = dedupe_sort direct_task_keeper_names in
    let direct_receipt_refs =
      direct_linked_keeper_names
      |> List.filter_map (fun keeper_name ->
             String_map.find_opt keeper_name latest_receipts_by_keeper
             |> Option.map (fun receipt -> (keeper_name, receipt)))
    in
    let direct_receipts =
      direct_receipt_refs |> List.map snd
    in
    let direct_runtime_trusts =
      direct_linked_keeper_names
      |> List.filter_map (fun keeper_name ->
             context.runtime_trust_of keeper_name
             |> Option.map (fun trust -> (keeper_name, trust)))
    in
    let task_activity_values =
      linked_tasks
      |> List.map (fun (task : Masc_domain.task) -> task_updated_at task)
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
            |> List.sort_uniq
                 (fun (left_keeper, left_turn) (right_keeper, right_turn) ->
                    let cmp = String.compare left_keeper right_keeper in
                    if cmp <> 0
                    then cmp
                    else Option.compare Int.compare left_turn right_turn)
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
      latest_keeper_ref;
      latest_turn_ref;
      activity_observation;
    }
