type dispatch_node = {
  node_id : string;
  goal_id : string;
  title : string;
  depth : int;
  kind : string;
  priority : int;
  children : dispatch_node list;
}
[@@deriving yojson]

type dispatch_plan = {
  requested_depth : int;
  effective_depth : int;
  child_limit : int;
  grandchild_limit : int;
  estimated_actions : int;
  nodes : dispatch_node list;
}
[@@deriving yojson]

type execution_summary = {
  executed : bool;
  created_task_count : int;
  created_task_results : string list;
  errors : string list;
}
[@@deriving yojson]

type build_options = {
  requested_depth : int;
  effective_depth : int;
  child_limit : int;
  grandchild_limit : int;
  fanout_short : int;
  fanout_mid : int;
  fanout_long : int;
}

let rec take n xs =
  if n <= 0 then []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest

let filter_horizon horizon goals =
  List.filter (fun g -> g.Goal_store.horizon = horizon) goals

let selected_children goals opts =
  let short = filter_horizon Goal_store.Short goals |> take opts.fanout_short in
  let mid = filter_horizon Goal_store.Mid goals |> take opts.fanout_mid in
  let long = filter_horizon Goal_store.Long goals |> take opts.fanout_long in
  (short @ mid @ long) |> take opts.child_limit

let build_plan ~goals opts =
  let children = selected_children goals opts in
  let child_count = List.length children in
  let max_gc_per_child =
    if child_count = 0 then 0
    else max 1 (opts.grandchild_limit / child_count)
  in
  let nodes =
    children
    |> List.mapi (fun idx goal ->
           let child_id = Printf.sprintf "child-%03d" (idx + 1) in
           let grandchildren =
             if opts.effective_depth < 2 then []
             else
               List.init max_gc_per_child (fun n ->
                   {
                     node_id = Printf.sprintf "%s-gc-%02d" child_id (n + 1);
                     goal_id = goal.Goal_store.id;
                     title =
                       Printf.sprintf "%s / substep %d" goal.Goal_store.title
                         (n + 1);
                     depth = 2;
                     kind = "grandchild";
                     priority = goal.Goal_store.priority;
                     children = [];
                   })
           in
           {
             node_id = child_id;
             goal_id = goal.Goal_store.id;
             title = goal.Goal_store.title;
             depth = 1;
             kind = "child";
             priority = goal.Goal_store.priority;
             children = grandchildren;
           })
  in
  let estimated_actions =
    List.fold_left
      (fun acc node -> acc + 1 + List.length node.children)
      0 nodes
  in
  {
    requested_depth = opts.requested_depth;
    effective_depth = opts.effective_depth;
    child_limit = opts.child_limit;
    grandchild_limit = opts.grandchild_limit;
    estimated_actions;
    nodes;
  }

let add_task_safe config ~title ~description =
  try
    let response = Room.add_task config ~title ~priority:3 ~description in
    Ok response
  with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)

let execute_plan config ~agent_name:_ plan =
  let created = ref [] in
  let errors = ref [] in
  let push_result = function
    | Ok msg -> created := msg :: !created
    | Error err -> errors := err :: !errors
  in
  List.iter
    (fun node ->
      let child_title =
        Printf.sprintf "[goal:%s][child] %s" node.goal_id node.title
      in
      let child_desc =
        Printf.sprintf "Goal dispatch child node %s (depth=%d)" node.node_id
          node.depth
      in
      push_result (add_task_safe config ~title:child_title ~description:child_desc);
      List.iter
        (fun gc ->
          let gc_title =
            Printf.sprintf "[goal:%s][grandchild] %s" gc.goal_id gc.title
          in
          let gc_desc =
            Printf.sprintf
              "Goal dispatch grandchild node %s (parent=%s)"
              gc.node_id node.node_id
          in
          push_result (add_task_safe config ~title:gc_title ~description:gc_desc))
        node.children)
    plan.nodes;
  {
    executed = true;
    created_task_count = List.length !created;
    created_task_results = List.rev !created;
    errors = List.rev !errors;
  }
