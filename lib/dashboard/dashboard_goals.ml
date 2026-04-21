(** Dashboard Goals — goal tree with task linkage and convergence indicators. *)

(** A tree node represents a goal with its child goals and linked tasks. *)
type tree_node = {
  goal : Goal_store.goal;
  children : tree_node list;
  tasks : Types.task list;
  convergence : float;  (** 0.0 .. 1.0 completion ratio *)
}

let task_is_linked_to_goal (task : Types.task) goal_id =
  (* Tasks created by goal dispatch embed [goal:<id>] in the title. *)
  let pattern = Printf.sprintf "[goal:%s]" goal_id in
  try
    let _ = Re.Str.search_forward (Re.Str.regexp_string pattern) task.title 0 in
    true
  with Not_found -> false

let task_assignee (task : Types.task) : string option =
  Types.task_assignee_of_status task.task_status

let task_status_label (task : Types.task) : string =
  match task.task_status with
  | Types.Todo -> "pending"
  | Types.Claimed _ -> "claimed"
  | Types.InProgress _ -> "in_progress"
  | Types.AwaitingVerification _ -> "awaiting_verification"
  | Types.Done _ -> "completed"
  | Types.Cancelled _ -> "cancelled"

let task_is_terminal (task : Types.task) : bool =
  Types.task_status_is_terminal task.task_status

let task_is_done (task : Types.task) : bool =
  Types.task_status_is_done task.task_status

let compute_convergence (goal : Goal_store.goal) linked_tasks children =
  (* Convergence = weighted average of own task completion + child convergence.
     If there are no tasks or children, use the goal status as the signal. *)
  let goal_done_weight =
    match goal.status with
    | Goal_store.Done -> 1.0
    | Goal_store.Active | Goal_store.Paused -> 0.0
    | Goal_store.Dropped -> 0.0
  in
  let task_count = List.length linked_tasks in
  let done_count =
    List.length (List.filter task_is_done linked_tasks)
  in
  let task_ratio =
    if task_count = 0 then goal_done_weight
    else float_of_int done_count /. float_of_int task_count
  in
  let child_ratios =
    List.map (fun (c : tree_node) -> c.convergence) children
  in
  let child_avg =
    match child_ratios with
    | [] -> task_ratio
    | rs ->
        let sum = List.fold_left ( +. ) 0.0 rs in
        sum /. float_of_int (List.length rs)
  in
  (* If we have both tasks and children, average them. *)
  if task_count > 0 && children <> [] then
    (task_ratio +. child_avg) /. 2.0
  else if children <> [] then
    child_avg
  else
    task_ratio

let rec build_tree goals all_tasks goal =
  let child_goals =
    List.filter
      (fun (g : Goal_store.goal) ->
        g.parent_goal_id = Some goal.Goal_store.id)
      goals
  in
  let linked_tasks =
    List.filter (fun t -> task_is_linked_to_goal t goal.Goal_store.id) all_tasks
  in
  let children = List.map (build_tree goals all_tasks) child_goals in
  let convergence = compute_convergence goal linked_tasks children in
  { goal; children; tasks = linked_tasks; convergence }

let build_forest ~goals ~tasks =
  (* Root goals = goals without a parent, or whose parent is not in the set. *)
  let goal_ids =
    List.map (fun (g : Goal_store.goal) -> g.id) goals
  in
  let is_root (g : Goal_store.goal) =
    match g.parent_goal_id with
    | None -> true
    | Some pid -> not (List.mem pid goal_ids)
  in
  let roots = List.filter is_root goals in
  List.map (build_tree goals tasks) roots

(* JSON serialization *)

let goal_status_color = function
  | Goal_store.Active -> "#4ade80"
  | Goal_store.Paused -> "#f59e0b"
  | Goal_store.Done -> "#60a5fa"
  | Goal_store.Dropped -> "#6b7280"

let task_status_color status_label =
  match status_label with
  | "pending" -> "#6b7280"
  | "claimed" -> "#f59e0b"
  | "in_progress" -> "#3b82f6"
  | "completed" -> "#4ade80"
  | "cancelled" -> "#ef4444"
  | _ -> "#888888"

let task_to_tree_json (task : Types.task) =
  let status = task_status_label task in
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("status", `String status);
      ("status_color", `String (task_status_color status));
      ("priority", `Int task.priority);
      ("assignee",
       match task_assignee task with
       | Some a -> `String a
       | None -> `Null);
      ("is_terminal", `Bool (task_is_terminal task));
      ("created_at", `String task.created_at);
    ]

let rec tree_node_to_json node =
  let g = node.goal in
  `Assoc
    [
      ("id", `String g.id);
      ("title", `String g.title);
      ("horizon", Goal_store.horizon_to_yojson g.horizon);
      ("status", Goal_store.goal_status_to_yojson g.status);
      ("status_color", `String (goal_status_color g.status));
      ("priority", `Int g.priority);
      ("metric",
       match g.metric with Some m -> `String m | None -> `Null);
      ("target_value",
       match g.target_value with Some v -> `String v | None -> `Null);
      ("due_date",
       match g.due_date with Some d -> `String d | None -> `Null);
      ("parent_goal_id",
       match g.parent_goal_id with Some pid -> `String pid | None -> `Null);
      ("convergence", `Float node.convergence);
      ("convergence_pct", `Int (int_of_float (node.convergence *. 100.0)));
      ("tasks", `List (List.map task_to_tree_json node.tasks));
      ("task_count", `Int (List.length node.tasks));
      ("task_done_count",
       `Int (List.length (List.filter task_is_done node.tasks)));
      ("children", `List (List.map tree_node_to_json node.children));
      ("child_count", `Int (List.length node.children));
      ("created_at", `String g.created_at);
      ("updated_at", `String g.updated_at);
    ]

let dashboard_goals_tree_json ~(config : Coord.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let tasks = Coord.get_tasks_safe config in
  let forest = build_forest ~goals ~tasks in
  let total_goals = List.length goals in
  let active_goals =
    List.length (List.filter (fun (g : Goal_store.goal) -> g.status = Active) goals)
  in
  let total_tasks = List.length tasks in
  let done_tasks =
    List.length (List.filter task_is_done tasks)
  in
  let overall_convergence =
    if total_goals = 0 then 0.0
    else
      let sum =
        List.fold_left (fun acc n -> acc +. n.convergence) 0.0 forest
      in
      sum /. float_of_int (List.length forest)
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("tree", `List (List.map tree_node_to_json forest));
      ("summary",
       `Assoc
         [
           ("total_goals", `Int total_goals);
           ("active_goals", `Int active_goals);
           ("total_tasks", `Int total_tasks);
           ("done_tasks", `Int done_tasks);
           ("overall_convergence", `Float overall_convergence);
           ("overall_convergence_pct",
            `Int (int_of_float (overall_convergence *. 100.0)));
         ]);
    ]
