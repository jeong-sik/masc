(** MCTS Tree — Monte Carlo Tree Search for speculative execution paths.

    Implements UCB1-based tree search (Kocsis & Szepesvári, 2006) adapted
    for agent task-path selection.  Each node represents a decision point
    (BRANCH instruction), edges are candidate approaches, and leaf values
    come from fast-LLM simulation + verifier verdict.

    Key adaptation from game-playing MCTS:
    - No adversarial opponent → single-player optimisation
    - Simulation = fast LLM call (not random rollout)
    - Reward = verifier verdict (PASS=1.0, WARN=0.5, FAIL=0.0)
    - Persistent tree across task executions (learning transfers)

    @since 2.80.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

(** Unique identifier for tree nodes. *)
type node_id = string

(** Verifier verdict mapped to numeric reward. *)
type verdict_reward =
  | Pass    (** 1.0 *)
  | Warn    (** 0.5 *)
  | Fail    (** 0.0 *)

let reward_of_verdict = function
  | Pass -> 1.0
  | Warn -> 0.5
  | Fail -> 0.0

let verdict_of_float f =
  if f >= 0.9 then Pass
  else if f >= 0.4 then Warn
  else Fail

let verdict_to_string = function
  | Pass -> "PASS" | Warn -> "WARN" | Fail -> "FAIL"

let verdict_to_yojson v = `String (verdict_to_string v)

let verdict_of_yojson = function
  | `String "PASS" -> Ok Pass
  | `String "WARN" -> Ok Warn
  | `String "FAIL" -> Ok Fail
  | _ -> Error "verdict_reward: expected PASS, WARN, or FAIL"

(** Simulation result from a fast LLM call. *)
type simulation_result = {
  output : string;           (** Raw LLM output *)
  verdict : verdict_reward;  (** Verifier assessment *)
  latency_ms : float;        (** Round-trip time *)
  model_used : string;       (** Which fast model was used *)
}

let simulation_result_to_yojson s =
  `Assoc [
    ("output", `String s.output);
    ("verdict", verdict_to_yojson s.verdict);
    ("latency_ms", `Float s.latency_ms);
    ("model_used", `String s.model_used);
  ]

(** A node in the MCTS tree.

    Invariants:
    - [visit_count >= 0]
    - [total_reward >= 0.0]
    - If [visit_count = 0] then [total_reward = 0.0] (unexplored)
    - [children] can be empty (leaf or unexpanded) *)
type node = {
  id : node_id;
  label : string;               (** Human-readable description of this path *)
  parent_id : node_id option;   (** None for root *)
  mutable children : node list;
  mutable visit_count : int;
  mutable total_reward : float;
  mutable last_simulation : simulation_result option;
  created_at : float;
}

(** The MCTS tree container with configuration and metrics. *)
type t = {
  root : node;
  mutable node_count : int;
  exploration_constant : float;  (** C in UCB1, default sqrt(2) *)
  (* Metrics *)
  mutable total_simulations : int;
  mutable total_selections : int;
  mutable total_expansions : int;
  mutable total_backpropagations : int;
}

(* ================================================================ *)
(* Construction                                                     *)
(* ================================================================ *)

let _node_counter = ref 0

let gen_node_id () =
  let n = !_node_counter in
  _node_counter := n + 1;
  Printf.sprintf "mcts-%d-%d"
    (int_of_float (Time_compat.now () *. 1000.0)) n

let make_node ?(parent_id = None) label =
  {
    id = gen_node_id ();
    label;
    parent_id;
    children = [];
    visit_count = 0;
    total_reward = 0.0;
    last_simulation = None;
    created_at = Time_compat.now ();
  }

let create ?(exploration_constant = sqrt 2.0) ~root_label () =
  let root = make_node root_label in
  {
    root;
    node_count = 1;
    exploration_constant;
    total_simulations = 0;
    total_selections = 0;
    total_expansions = 0;
    total_backpropagations = 0;
  }

(* ================================================================ *)
(* Tree Navigation                                                  *)
(* ================================================================ *)

(** Find a node by ID via DFS. Returns None if not found. *)
let find_node t node_id =
  let rec dfs node =
    if node.id = node_id then Some node
    else List.fold_left (fun acc child ->
      match acc with
      | Some _ -> acc
      | None -> dfs child
    ) None node.children
  in
  dfs t.root

(** Collect all leaf nodes (nodes with no children). *)
let leaves t =
  let rec collect acc node =
    if node.children = [] then node :: acc
    else List.fold_left collect acc node.children
  in
  collect [] t.root

(** Depth of a node (root = 0). *)
let depth t node_id =
  let rec trace id d =
    match find_node t id with
    | None -> d
    | Some n ->
      match n.parent_id with
      | None -> d
      | Some pid -> trace pid (d + 1)
  in
  trace node_id 0

(* ================================================================ *)
(* UCB1 Selection                                                   *)
(* ================================================================ *)

(** UCB1 score for a child node given parent visit count.

    UCB1(n) = Q(n)/N(n) + C * sqrt(ln(N_parent) / N(n))

    Unvisited nodes get +infinity to ensure they are tried first. *)
let ucb1 ~exploration_constant ~parent_visits child =
  if child.visit_count = 0 then infinity
  else
    let exploitation =
      child.total_reward /. float_of_int child.visit_count
    in
    let exploration =
      exploration_constant
      *. sqrt (log (float_of_int parent_visits)
               /. float_of_int child.visit_count)
    in
    exploitation +. exploration

(** Select the best child of a node using UCB1.

    Returns None if the node has no children.
    When multiple children have equal UCB1 scores (e.g., all unvisited),
    the first one is chosen deterministically for reproducibility. *)
let select_child t node =
  match node.children with
  | [] -> None
  | children ->
    t.total_selections <- t.total_selections + 1;
    let parent_visits = max 1 node.visit_count in
    let scored = List.map (fun c ->
      (c, ucb1 ~exploration_constant:t.exploration_constant
              ~parent_visits c)
    ) children in
    let best = List.fold_left (fun (best_node, best_score) (n, s) ->
      if s > best_score then (n, s) else (best_node, best_score)
    ) (List.hd children, neg_infinity) scored in
    Some (fst best)

(** Select a path from root to a leaf using UCB1 at each level.

    This is the "Selection" phase of MCTS: repeatedly pick the
    best child until reaching a leaf or unexpanded node. *)
let select_path t =
  let rec descend node path =
    match select_child t node with
    | None -> List.rev (node :: path)
    | Some child -> descend child (node :: path)
  in
  descend t.root []

(* ================================================================ *)
(* Expansion                                                        *)
(* ================================================================ *)

(** Expand a node by adding candidate children.

    Each label represents a candidate approach for the task.
    Returns the list of newly created child nodes. *)
let expand t parent_id ~labels =
  match find_node t parent_id with
  | None -> Error (Printf.sprintf "Node %s not found" parent_id)
  | Some parent ->
    if parent.children <> [] then
      Error (Printf.sprintf "Node %s already expanded" parent_id)
    else begin
      let children = List.map (fun label ->
        make_node ~parent_id:(Some parent_id) label
      ) labels in
      parent.children <- children;
      let n = List.length children in
      t.node_count <- t.node_count + n;
      t.total_expansions <- t.total_expansions + 1;
      Ok children
    end

(** Add a single child to an existing node.  Unlike [expand], this
    does not require the parent to be childless — useful for
    incremental expansion (progressive widening). *)
let add_child t parent_id ~label =
  match find_node t parent_id with
  | None -> Error (Printf.sprintf "Node %s not found" parent_id)
  | Some parent ->
    let child = make_node ~parent_id:(Some parent_id) label in
    parent.children <- child :: parent.children;
    t.node_count <- t.node_count + 1;
    Ok child

(* ================================================================ *)
(* Simulation Recording                                             *)
(* ================================================================ *)

(** Record a simulation result on a leaf node.

    This is the "Simulation" phase: the actual fast-LLM call happens
    externally, and we record its result here.  The verdict is
    converted to a numeric reward for backpropagation. *)
let record_simulation t node_id result =
  match find_node t node_id with
  | None -> Error (Printf.sprintf "Node %s not found" node_id)
  | Some node ->
    node.last_simulation <- Some result;
    t.total_simulations <- t.total_simulations + 1;
    Ok (reward_of_verdict result.verdict)

(* ================================================================ *)
(* Backpropagation                                                  *)
(* ================================================================ *)

(** Backpropagate a reward from a leaf up to the root.

    Each ancestor node's visit_count and total_reward are updated.
    This is what makes UCB1 converge: good paths accumulate
    higher average reward, so they get selected more often. *)
let backpropagate t node_id reward =
  let rec propagate id =
    match find_node t id with
    | None -> ()
    | Some node ->
      node.visit_count <- node.visit_count + 1;
      node.total_reward <- node.total_reward +. reward;
      t.total_backpropagations <- t.total_backpropagations + 1;
      match node.parent_id with
      | None -> ()
      | Some pid -> propagate pid
  in
  propagate node_id

(* ================================================================ *)
(* Best Path Extraction                                             *)
(* ================================================================ *)

(** Select the best child by average reward (exploitation only).

    Used after all simulations are done to pick the final answer.
    Unlike UCB1 selection during search, this ignores exploration. *)
let best_child_by_reward node =
  match node.children with
  | [] -> None
  | children ->
    let best = List.fold_left (fun best c ->
      let avg = if c.visit_count = 0 then 0.0
        else c.total_reward /. float_of_int c.visit_count in
      let best_avg = if (fst best).visit_count = 0 then 0.0
        else (fst best).total_reward /. float_of_int (fst best).visit_count in
      if avg > best_avg then (c, avg) else best
    ) (List.hd children, 0.0) children in
    Some (fst best)

(** Extract the best path from root to leaf by following highest
    average-reward children at each level. *)
let best_path t =
  let rec descend node acc =
    match best_child_by_reward node with
    | None -> List.rev (node :: acc)
    | Some child -> descend child (node :: acc)
  in
  descend t.root []

(* ================================================================ *)
(* Pruning                                                          *)
(* ================================================================ *)

(** Prune children of a node whose average reward is below threshold.

    Returns the number of pruned subtrees.  Useful for focusing
    the tree after initial exploration. *)
let prune t parent_id ~min_avg_reward =
  match find_node t parent_id with
  | None -> Error (Printf.sprintf "Node %s not found" parent_id)
  | Some parent ->
    let rec count_subtree node =
      1 + List.fold_left (fun acc c -> acc + count_subtree c) 0 node.children
    in
    let kept, pruned_count = List.fold_left (fun (kept, pruned) child ->
      let avg = if child.visit_count = 0 then 0.0
        else child.total_reward /. float_of_int child.visit_count in
      if avg >= min_avg_reward then (child :: kept, pruned)
      else (kept, pruned + count_subtree child)
    ) ([], 0) parent.children in
    parent.children <- List.rev kept;
    t.node_count <- t.node_count - pruned_count;
    Ok pruned_count

(* ================================================================ *)
(* Serialization                                                    *)
(* ================================================================ *)

let rec node_to_yojson node =
  let avg_reward =
    if node.visit_count = 0 then 0.0
    else node.total_reward /. float_of_int node.visit_count
  in
  `Assoc [
    ("id", `String node.id);
    ("label", `String node.label);
    ("parent_id", match node.parent_id with
      | None -> `Null | Some p -> `String p);
    ("visit_count", `Int node.visit_count);
    ("total_reward", `Float node.total_reward);
    ("avg_reward", `Float avg_reward);
    ("last_simulation", match node.last_simulation with
      | None -> `Null | Some s -> simulation_result_to_yojson s);
    ("children_count", `Int (List.length node.children));
    ("children", `List (List.map node_to_yojson node.children));
  ]

let to_yojson t =
  `Assoc [
    ("root", node_to_yojson t.root);
    ("node_count", `Int t.node_count);
    ("exploration_constant", `Float t.exploration_constant);
    ("metrics", `Assoc [
      ("total_simulations", `Int t.total_simulations);
      ("total_selections", `Int t.total_selections);
      ("total_expansions", `Int t.total_expansions);
      ("total_backpropagations", `Int t.total_backpropagations);
    ]);
  ]

(** Compact summary (no recursive children) for dashboard/status. *)
let summary_to_yojson t =
  let best = best_path t in
  let best_labels = List.map (fun n -> `String n.label) best in
  let leaf_count = List.length (leaves t) in
  `Assoc [
    ("node_count", `Int t.node_count);
    ("leaf_count", `Int leaf_count);
    ("exploration_constant", `Float t.exploration_constant);
    ("best_path", `List best_labels);
    ("root_visits", `Int t.root.visit_count);
    ("root_avg_reward",
      `Float (if t.root.visit_count = 0 then 0.0
              else t.root.total_reward /. float_of_int t.root.visit_count));
    ("simulations", `Int t.total_simulations);
    ("selections", `Int t.total_selections);
  ]
