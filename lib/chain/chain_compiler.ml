(** Chain Compiler - AST to Execution Plan conversion

    Transforms Chain_types.chain into an execution plan:
    - Topological sorting of nodes (DAG ordering)
    - Parallel group identification
    - Depth calculation for recursion limits
    - Dependency analysis
*)

open Chain_types

(** Helper: Result bind operator *)
let ( let* ) = Result.bind

(** Recursively collect all input_mapping dependencies from nested nodes *)
let rec collect_nested_dependencies (node : Chain_types.node) : string list =
  let mapping_deps = List.map snd node.input_mapping in
  (* depends_on is the primary dependency mechanism in JSON chains *)
  let explicit_deps = Option.value node.depends_on ~default:[] in
  let direct_deps = mapping_deps @ explicit_deps in
  let nested_deps = match node.node_type with
    | Chain_types.Pipeline nodes
    | Chain_types.Fanout nodes ->
        List.concat_map collect_nested_dependencies nodes
    | Chain_types.Quorum { nodes; _ }
    | Chain_types.Merge { nodes; _ } ->
        List.concat_map collect_nested_dependencies nodes
    | Chain_types.Gate { then_node; else_node; _ } ->
        let then_deps = collect_nested_dependencies then_node in
        let else_deps = match else_node with
          | Some n -> collect_nested_dependencies n
          | None -> []
        in
        then_deps @ else_deps
    | Chain_types.Subgraph c ->
        List.concat_map collect_nested_dependencies c.Chain_types.nodes
    | Chain_types.Map { inner; _ } | Chain_types.Bind { inner; _ } ->
        collect_nested_dependencies inner
    | Chain_types.Threshold { input_node; on_pass; on_fail; _ } ->
        let input_deps = collect_nested_dependencies input_node in
        let pass_deps = match on_pass with Some n -> collect_nested_dependencies n | None -> [] in
        let fail_deps = match on_fail with Some n -> collect_nested_dependencies n | None -> [] in
        input_deps @ pass_deps @ fail_deps
    | Chain_types.GoalDriven { action_node; _ } ->
        collect_nested_dependencies action_node
    | Chain_types.Evaluator { candidates; _ } ->
        List.concat_map collect_nested_dependencies candidates
    | Chain_types.Retry { node = inner_node; _ } ->
        collect_nested_dependencies inner_node
    | Chain_types.Fallback { primary; fallbacks; _ } ->
        collect_nested_dependencies primary @ List.concat_map collect_nested_dependencies fallbacks
    | Chain_types.Race { nodes; _ } ->
        List.concat_map collect_nested_dependencies nodes
    | Chain_types.Cache { inner; _ } ->
        collect_nested_dependencies inner
    | Chain_types.Batch { inner; _ } ->
        collect_nested_dependencies inner
    | Chain_types.Spawn { inner; _ } ->
        collect_nested_dependencies inner
    | Chain_types.Mcts { strategies; simulation; _ } ->
        List.concat_map collect_nested_dependencies strategies @
        collect_nested_dependencies simulation
    | Chain_types.StreamMerge { nodes; _ } ->
        List.concat_map collect_nested_dependencies nodes
    | Chain_types.FeedbackLoop { generator; _ } ->
        collect_nested_dependencies generator
    | Chain_types.Cascade { tiers; _ } ->
        List.concat_map (fun t -> collect_nested_dependencies t.Chain_types.tier_node) tiers
    | Chain_types.Llm _ | Chain_types.Tool _ | Chain_types.ChainRef _
    | Chain_types.ChainExec _ | Chain_types.Adapter _
    | Chain_types.Masc_broadcast _ | Chain_types.Masc_listen _ | Chain_types.Masc_claim _ ->
        []
  in
  direct_deps @ nested_deps
  |> List.sort_uniq String.compare

(** Build dependency graph from nodes *)
let build_dependency_graph (nodes : Chain_types.node list) : (string, string list) Hashtbl.t =
  let deps = Hashtbl.create (List.length nodes) in

  (* Initialize all nodes with empty deps *)
  List.iter (fun (n : Chain_types.node) -> Hashtbl.add deps n.id []) nodes;

  (* Collect all top-level node IDs for filtering external refs *)
  let top_level_ids = List.map (fun (n : Chain_types.node) -> n.id) nodes in

  (* Add dependencies from input mappings AND nested nodes *)
  List.iter (fun (n : Chain_types.node) ->
    (* Collect all dependencies including from nested nodes *)
    let all_deps = collect_nested_dependencies n in
    (* Filter to only top-level nodes that exist (external references) *)
    let external_deps = List.filter (fun ref_node ->
      List.mem ref_node top_level_ids && ref_node <> n.id
    ) all_deps in
    Hashtbl.replace deps n.id external_deps
  ) nodes;

  deps

(** Topological sort using Kahn's algorithm *)
let topological_sort (deps : (string, string list) Hashtbl.t) : (string list, string) result =
  let in_degree = Hashtbl.create (Hashtbl.length deps) in
  let reverse_deps = Hashtbl.create (Hashtbl.length deps) in

  (* Initialize in-degrees and reverse dependency map *)
  Hashtbl.iter (fun node _ ->
    Hashtbl.add in_degree node 0;
    Hashtbl.add reverse_deps node []
  ) deps;

  (* Collect missing dependencies for error reporting *)
  let missing_deps = ref [] in

  (* Calculate in-degrees *)
  Hashtbl.iter (fun node node_deps ->
    List.iter (fun dep ->
      (* node depends on dep, so dep -> node in reverse *)
      (* Check if dep exists in the graph (not an external/missing reference) *)
      match Hashtbl.find_opt reverse_deps dep with
      | Some current ->
          Hashtbl.replace reverse_deps dep (node :: current);
          (* Increment in-degree of node *)
          let deg = Hashtbl.find_opt in_degree node |> Option.value ~default:0 in
          Hashtbl.replace in_degree node (deg + 1)
      | None ->
          (* dep is not a node in the graph - could be external input or error *)
          missing_deps := (node, dep) :: !missing_deps
    ) node_deps
  ) deps;

  (* Report missing dependencies if any *)
  if !missing_deps <> [] then
    let msg = !missing_deps
      |> List.map (fun (node, dep) -> Printf.sprintf "'%s' depends on unknown node '%s'" node dep)
      |> String.concat "; "
    in
    Error (Printf.sprintf "Missing dependencies: %s" msg)
  else

  (* Start with nodes that have no dependencies *)
  let queue = Queue.create () in
  Hashtbl.iter (fun node deg ->
    if deg = 0 then Queue.add node queue
  ) in_degree;

  let rec process acc =
    if Queue.is_empty queue then
      (* Check if we processed all nodes *)
      if List.length acc = Hashtbl.length deps then
        Ok (List.rev acc)
      else
        Error "Cycle detected in chain graph"
    else begin
      let node = Queue.pop queue in
      (* Decrement in-degree of all nodes that depend on this one *)
      let dependents = Hashtbl.find_opt reverse_deps node |> Option.value ~default:[] in
      List.iter (fun dependent ->
        let deg = Hashtbl.find_opt in_degree dependent |> Option.value ~default:0 in
        let new_deg = deg - 1 in
        Hashtbl.replace in_degree dependent new_deg;
        if new_deg = 0 then Queue.add dependent queue
      ) dependents;
      process (node :: acc)
    end
  in
  process []

(** Identify parallel groups (nodes that can execute concurrently) *)
let identify_parallel_groups
    (nodes : Chain_types.node list)
    (execution_order : string list)
    (deps : (string, string list) Hashtbl.t) : string list list =
  (* Group nodes by their "level" (max dependency depth) *)
  let levels = Hashtbl.create (List.length nodes) in

  List.iter (fun node_id ->
    let node_deps = Hashtbl.find_opt deps node_id |> Option.value ~default:[] in
    let level =
      if node_deps = [] then 0
      else
        1 + List.fold_left (fun max_level dep ->
          max max_level (try Hashtbl.find levels dep with Not_found -> 0)
        ) 0 node_deps
    in
    Hashtbl.add levels node_id level
  ) execution_order;

  (* Group by level *)
  let max_level = Hashtbl.fold (fun _ l acc -> max l acc) levels 0 in
  let groups = Array.make (max_level + 1) [] in

  Hashtbl.iter (fun node_id level ->
    groups.(level) <- node_id :: groups.(level)
  ) levels;

  Array.to_list groups
  |> List.filter (fun g -> g <> [])

(** Calculate maximum nesting depth *)
let rec calculate_depth (node : Chain_types.node) : int =
  match node.Chain_types.node_type with
  | Chain_types.Llm _ | Chain_types.Tool _ | Chain_types.ChainRef _ | Chain_types.Adapter _
  | Chain_types.Masc_broadcast _ | Chain_types.Masc_listen _ | Chain_types.Masc_claim _ -> 1
  | Chain_types.Pipeline nodes | Chain_types.Fanout nodes ->
      1 + List.fold_left (fun acc n -> max acc (calculate_depth n)) 0 nodes
  | Chain_types.Quorum { nodes; _ } | Chain_types.Merge { nodes; _ } ->
      1 + List.fold_left (fun acc n -> max acc (calculate_depth n)) 0 nodes
  | Chain_types.Gate { then_node; else_node; _ } ->
      let then_depth = calculate_depth then_node in
      let else_depth = match else_node with
        | Some n -> calculate_depth n
        | None -> 0
      in
      1 + max then_depth else_depth
  | Chain_types.Subgraph c ->
      1 + List.fold_left (fun acc n -> max acc (calculate_depth n)) 0 c.Chain_types.nodes
  | Chain_types.Map { inner; _ } | Chain_types.Bind { inner; _ } ->
      1 + calculate_depth inner
  | Chain_types.Threshold { input_node; on_pass; on_fail; _ } ->
      let input_depth = calculate_depth input_node in
      let pass_depth = Option.fold ~none:0 ~some:calculate_depth on_pass in
      let fail_depth = Option.fold ~none:0 ~some:calculate_depth on_fail in
      1 + max input_depth (max pass_depth fail_depth)
  | Chain_types.GoalDriven { action_node; _ } ->
      1 + calculate_depth action_node
  | Chain_types.Evaluator { candidates; _ } ->
      1 + List.fold_left (fun acc n -> max acc (calculate_depth n)) 0 candidates
  | Chain_types.Retry { node = inner_node; _ } ->
      1 + calculate_depth inner_node
  | Chain_types.Fallback { primary; fallbacks; _ } ->
      1 + max (calculate_depth primary) (List.fold_left (fun acc n -> max acc (calculate_depth n)) 0 fallbacks)
  | Chain_types.Race { nodes; _ } ->
      1 + List.fold_left (fun acc n -> max acc (calculate_depth n)) 0 nodes
  | Chain_types.ChainExec { max_depth; _ } ->
      1 + max_depth  (* Estimate: 1 for this node + max_depth for generated chain *)
  | Chain_types.Cache { inner; _ } ->
      1 + calculate_depth inner
  | Chain_types.Batch { inner; _ } ->
      1 + calculate_depth inner
  | Chain_types.Spawn { inner; _ } ->
      1 + calculate_depth inner
  | Chain_types.Mcts { strategies; simulation; max_depth; _ } ->
      (* MCTS depth: 1 + max of (strategies depth, simulation depth) + max_depth *)
      let strat_depth = List.fold_left (fun acc n -> max acc (calculate_depth n)) 0 strategies in
      let sim_depth = calculate_depth simulation in
      1 + max_depth + max strat_depth sim_depth
  | Chain_types.StreamMerge { nodes; _ } ->
      (* StreamMerge depth: 1 + max of inner nodes depth *)
      1 + List.fold_left (fun acc n -> max acc (calculate_depth n)) 0 nodes
  | Chain_types.Cascade { tiers; _ } ->
      1 + List.fold_left (fun acc t -> max acc (calculate_depth t.Chain_types.tier_node)) 0 tiers
  | Chain_types.FeedbackLoop { generator; max_iterations; _ } ->
      (* FeedbackLoop depth: 1 + generator depth * max_iterations (worst case) *)
      1 + (calculate_depth generator) * max_iterations

(** Main entry point: Compile chain to execution plan *)
let compile (c : Chain_types.chain) : (Chain_types.execution_plan, string) result =
  (* Validate the chain first *)
  let* () = Chain_parser.validate_chain c in

  (* Build dependency graph *)
  let deps = build_dependency_graph c.Chain_types.nodes in

  (* Topological sort *)
  let* execution_order = topological_sort deps in

  (* Identify parallel groups *)
  let parallel_groups = identify_parallel_groups c.Chain_types.nodes execution_order deps in

  (* Calculate max depth *)
  let depth = List.fold_left
    (fun acc n -> max acc (calculate_depth n))
    0 c.Chain_types.nodes
  in

  (* Check depth limit *)
  if depth > c.Chain_types.config.Chain_types.max_depth then
    Error (Printf.sprintf "Chain depth %d exceeds max_depth %d" depth c.Chain_types.config.Chain_types.max_depth)
  else
    Ok {
      Chain_types.chain = c;
      execution_order;
      parallel_groups;
      depth;
    }

(** Get node by ID from chain *)
let get_node (c : Chain_types.chain) (node_id : string) : Chain_types.node option =
  List.find_opt (fun (n : Chain_types.node) -> n.id = node_id) c.Chain_types.nodes

(** Get all dependencies of a node *)
let get_dependencies (node : Chain_types.node) : string list =
  let mapping_deps = List.map snd node.Chain_types.input_mapping in
  let explicit_deps = Option.value node.Chain_types.depends_on ~default:[] in
  mapping_deps @ explicit_deps
  |> List.sort_uniq String.compare

(** Check if node is ready to execute (all deps satisfied) *)
let is_ready (completed : string list) (node : Chain_types.node) : bool =
  let deps = get_dependencies node in
  List.for_all (fun dep -> List.mem dep completed) deps

(** Pretty print execution plan *)
let pp_plan (plan : Chain_types.execution_plan) : string =
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "Chain: %s\n" plan.Chain_types.chain.Chain_types.id);
  Buffer.add_string buf (Printf.sprintf "Depth: %d\n" plan.Chain_types.depth);
  Buffer.add_string buf (Printf.sprintf "Execution order: %s\n"
    (String.concat " -> " plan.Chain_types.execution_order));
  Buffer.add_string buf "Parallel groups:\n";
  List.iteri (fun i group ->
    Buffer.add_string buf (Printf.sprintf "  [%d] %s\n" i (String.concat ", " group))
  ) plan.Chain_types.parallel_groups;
  Buffer.contents buf
