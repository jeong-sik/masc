(* Dashboard planning + goals JSON.

   - [dashboard_planning_http_json]: planning view that rolls up goals
     + task backlog status counts + coordination FSM snapshot.
   - [dashboard_goals_tree_http_json]: tree view (delegates to
     [Dashboard_goals]).
   - [dashboard_goals_snapshot_json]: composite (planning + tree).

   Extracted from [Server_dashboard_http] (godfile decomp). Pure
   projection over goal store + backlog reader. *)

let dashboard_planning_http_json ~(config : Coord.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let rollup = Goal_store.compute_rollup goals in
  let task_rollup =
    Server_dashboard_http_core_entities.dashboard_tasks_safe config
    |> List.fold_left
         (fun (todo, claimed, running, done_count, cancelled) (task : Masc_domain.task) ->
            match task.task_status with
            | Todo -> todo + 1, claimed, running, done_count, cancelled
            | Claimed _ -> todo, claimed + 1, running, done_count, cancelled
            | InProgress _ | AwaitingVerification _ ->
              todo, claimed, running + 1, done_count, cancelled
            | Done _ -> todo, claimed, running, done_count + 1, cancelled
            | Cancelled _ -> todo, claimed, running, done_count, cancelled + 1)
         (0, 0, 0, 0, 0)
  in
  let todo_count, claimed_count, running_count, done_count, cancelled_count =
    task_rollup
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "goals", `List (List.map Goal_store.goal_to_yojson goals)
    ; "rollup", Goal_store.rollup_to_yojson rollup
    ; ( "task_backlog"
      , `Assoc
          [ "todo", `Int todo_count
          ; "claimed", `Int claimed_count
          ; "in_progress", `Int running_count
          ; "done", `Int done_count
          ; "cancelled", `Int cancelled_count
          ] )
    ; "coordination_fsm", Coordination_product_snapshot.safe_build_tool_yojson config
    ]
;;

let dashboard_goals_tree_http_json ~(config : Coord.config) : Yojson.Safe.t =
  Dashboard_goals.dashboard_goals_tree_json ~config
;;

let dashboard_goals_snapshot_json ~(config : Coord.config) : Yojson.Safe.t =
  `Assoc
    [ "planning", dashboard_planning_http_json ~config
    ; "tree", dashboard_goals_tree_http_json ~config
    ]
;;
