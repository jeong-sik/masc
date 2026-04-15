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

(* ================================================================ *)
(* Complexity Analyzer (deterministic, no LLM)                      *)
(* ================================================================ *)

(** Karpathy-inspired reversibility heuristic.
    Estimates how reversible a task is based on keyword patterns.
    0.0 = irreversible (deploy, delete), 1.0 = fully reversible (read, search). *)
let estimate_reversibility description =
  let desc = String.lowercase_ascii description in
  let has w =
    let wlen = String.length w in
    let dlen = String.length desc in
    if wlen > dlen then false
    else
      let found = ref false in
      for i = 0 to dlen - wlen do
        if not !found && String.sub desc i wlen = w then found := true
      done;
      !found
  in
  if has "deploy" || has "release" || has "publish" || has "production" then 0.1
  else if has "delete" || has "drop" || has "remove" || has "destroy" then 0.2
  else if has "migrate" || has "schema" || has "database" then 0.3
  else if has "config" || has "environment" || has "secret" then 0.6
  else if has "refactor" || has "implement" || has "code" || has "fix" then 0.8
  else if has "test" || has "lint" || has "format" then 0.9
  else if has "read" || has "search" || has "query" || has "list" || has "view" then 1.0
  else 0.7  (* unknown defaults to moderately reversible *)
  |> fun score ->
    Heuristic_metrics.record {
      module_name = "goal_orchestrator";
      site = "estimate_reversibility";
      raw_value = score;
      threshold = 0.5;
      triggered = score < 0.5;
      provenance = Reversibility (Printf.sprintf "%.1f" score);
      timestamp = Unix.gettimeofday ();
    };
    score

type task_complexity = {
  estimated_turns : int;
  reversibility : float;
}

(** Estimate task complexity from description.
    Uses word count as a proxy for scope, combined with reversibility. *)
let estimate_complexity description =
  let words = String.split_on_char ' ' description |> List.length in
  let estimated_turns = max 1 (words / 5) in
  let reversibility = estimate_reversibility description in
  { estimated_turns; reversibility }

(** Threshold above which tasks should be split.
    Tasks with estimated_turns above this are flagged for decomposition. *)
let needs_decomposition complexity =
  complexity.estimated_turns > 20

(* ================================================================ *)
(* Idempotent Task Dispatch                                         *)
(* ================================================================ *)

(** Check if a task with the same title prefix already exists in backlog.
    Prevents duplicate task creation when execute_plan is called multiple times. *)
let task_exists_in_backlog config ~title_prefix =
  let backlog = Coord.read_backlog config in
  List.exists (fun (t : Types.task) ->
    let tlen = String.length title_prefix in
    String.length t.title >= tlen && String.sub t.title 0 tlen = title_prefix
  ) backlog.tasks

(** Idempotent version of add_task.
    Skips creation if a task with matching title prefix already exists. *)
let add_task_safe config ~title ~description =
  let prefix = if String.length title > 40 then String.sub title 0 40 else title in
  if task_exists_in_backlog config ~title_prefix:prefix then
    Ok (Printf.sprintf "(skipped, already exists) %s" (String.sub title 0 (min 60 (String.length title))))
  else
    try
      let response = Coord.add_task config ~title ~priority:3 ~description in
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
