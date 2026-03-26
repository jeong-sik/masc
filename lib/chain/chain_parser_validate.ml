include Chain_parser_helpers
open Chain_types
open Result_syntax

let rec has_placeholder_in_node_type = function
  | ChainRef "_" -> true
  | Pipeline nodes | Fanout nodes -> List.exists has_placeholder_node nodes
  | Race { nodes; _ } -> List.exists has_placeholder_node nodes
  | Quorum { nodes; _ } -> List.exists has_placeholder_node nodes
  | Gate { then_node; else_node; _ } ->
      has_placeholder_node then_node ||
      (match else_node with Some n -> has_placeholder_node n | None -> false)
  | GoalDriven { action_node; _ } -> has_placeholder_node action_node
  | Retry { node; _ } -> has_placeholder_node node
  | Fallback { primary; fallbacks; _ } ->
      has_placeholder_node primary || List.exists has_placeholder_node fallbacks
  | Map { inner; _ } -> has_placeholder_node inner
  | Threshold { input_node; _ } -> has_placeholder_node input_node
  | Evaluator { candidates; _ } -> List.exists has_placeholder_node candidates
  | Mcts { strategies; simulation; _ } ->
      List.exists has_placeholder_node strategies || has_placeholder_node simulation
  | Cascade { tiers; _ } ->
      List.exists (fun (t : Chain_types.cascade_tier) -> has_placeholder_node t.tier_node) tiers
  | _ -> false

and has_placeholder_node (n : Chain_types.node) =
  n.id = "_placeholder" || has_placeholder_in_node_type n.node_type

(** Collect all placeholder node IDs for error reporting *)
let rec collect_placeholders_in_node_type acc = function
  | ChainRef "_" -> "_chainref" :: acc
  | Pipeline nodes | Fanout nodes ->
      List.fold_left collect_placeholders_in_node acc nodes
  | Race { nodes; _ } ->
      List.fold_left collect_placeholders_in_node acc nodes
  | Quorum { nodes; _ } ->
      List.fold_left collect_placeholders_in_node acc nodes
  | Gate { then_node; else_node; _ } ->
      let acc = collect_placeholders_in_node acc then_node in
      (match else_node with Some n -> collect_placeholders_in_node acc n | None -> acc)
  | GoalDriven { action_node; _ } ->
      collect_placeholders_in_node acc action_node
  | Retry { node; _ } ->
      collect_placeholders_in_node acc node
  | Fallback { primary; fallbacks; _ } ->
      let acc = collect_placeholders_in_node acc primary in
      List.fold_left collect_placeholders_in_node acc fallbacks
  | Map { inner; _ } ->
      collect_placeholders_in_node acc inner
  | Threshold { input_node; _ } ->
      collect_placeholders_in_node acc input_node
  | Evaluator { candidates; _ } ->
      List.fold_left collect_placeholders_in_node acc candidates
  | Mcts { strategies; simulation; _ } ->
      let acc = List.fold_left collect_placeholders_in_node acc strategies in
      collect_placeholders_in_node acc simulation
  | Cascade { tiers; _ } ->
      List.fold_left (fun acc' (t : Chain_types.cascade_tier) ->
        collect_placeholders_in_node acc' t.tier_node) acc tiers
  | _ -> acc

and collect_placeholders_in_node acc (n : Chain_types.node) =
  let acc = if n.id = "_placeholder" then n.id :: acc else acc in
  collect_placeholders_in_node_type acc n.node_type

(** Validate chain structure *)
let validate_chain (c : Chain_types.chain) : (unit, string) result =
  (* Check output node exists - can be either a node ID or an output_key alias *)
  let node_ids = List.map (fun (n : Chain_types.node) -> n.id) c.Chain_types.nodes in
  let output_keys = List.filter_map (fun (n : Chain_types.node) -> n.output_key) c.Chain_types.nodes in
  let valid_outputs = node_ids @ output_keys in
  if not (List.mem c.Chain_types.output valid_outputs) then
    Error (Printf.sprintf "Output node '%s' not found in chain" c.Chain_types.output)
  (* Check for duplicate IDs *)
  else
    let* () =
      let rec check_dups seen = function
        | [] -> Ok ()
        | id :: rest ->
            if List.mem id seen then
              Error (Printf.sprintf "Duplicate node ID: %s" id)
            else
              check_dups (id :: seen) rest
      in
      check_dups [] node_ids
    in
    (* Check for unresolved placeholder nodes *)
    let placeholders = List.fold_left collect_placeholders_in_node [] c.Chain_types.nodes in
    if placeholders <> [] then
      Error (Printf.sprintf "Unresolved placeholder nodes found: %s. This usually indicates incomplete Mermaid edge resolution."
               (String.concat ", " (List.sort_uniq String.compare placeholders)))
    else
      Ok ()

(* ============================================================================
   Strict Validation (Completeness + Format)
   ============================================================================ *)

let is_blank s = String.trim s = ""

let strip_braces (s : string) : string option =
  let t = String.trim s in
  if String.length t >= 4 &&
     String.sub t 0 2 = "{{" &&
     String.sub t (String.length t - 2) 2 = "}}" then
    Some (String.sub t 2 (String.length t - 4) |> String.trim)
  else
    None

let extract_ref_root ~known_ids (s : string) : string option =
  let t = String.trim s in
  if t = "" then None
  else
    let wrapped = strip_braces t in
    let has_dot = String.contains t '.' in
    if wrapped <> None || has_dot || List.mem t known_ids then
      let inner = match wrapped with Some v -> v | None -> t in
      if inner = "" then None
      else
        match String.split_on_char '.' inner with
        | id :: _ -> Some id
        | [] -> None
    else
      None

let extract_template_vars (s : string) : string list =
  let re = Re.Str.regexp "{{\\([^}]+\\)}}" in
  let rec loop pos acc =
    try
      let _ = Re.Str.search_forward re s pos in
      let var = Re.Str.matched_group 1 s |> String.trim in
      let next = Re.Str.match_end () in
      loop next (var :: acc)
    with Not_found -> List.rev acc
  in
  loop 0 []

let rec collect_template_vars_json acc (json : Yojson.Safe.t) =
  match json with
  | `String s -> extract_template_vars s @ acc
  | `List items -> List.fold_left collect_template_vars_json acc items
  | `Assoc fields ->
      List.fold_left (fun acc (_, v) -> collect_template_vars_json acc v) acc fields
  | _ -> acc

let rec collect_all_nodes (acc : Chain_types.node list) (n : Chain_types.node) : Chain_types.node list =
  let acc = n :: acc in
  match n.node_type with
  | Chain_types.Pipeline nodes
  | Chain_types.Fanout nodes
  | Chain_types.Race { nodes; _ }
  | Chain_types.StreamMerge { nodes; _ } ->
      List.fold_left collect_all_nodes acc nodes
  | Chain_types.Quorum { nodes; _ }
  | Chain_types.Merge { nodes; _ } ->
      List.fold_left collect_all_nodes acc nodes
  | Chain_types.Gate { then_node; else_node; _ } ->
      let acc = collect_all_nodes acc then_node in
      (match else_node with Some n2 -> collect_all_nodes acc n2 | None -> acc)
  | Chain_types.Subgraph c ->
      List.fold_left collect_all_nodes acc c.Chain_types.nodes
  | Chain_types.Map { inner; _ }
  | Chain_types.Bind { inner; _ }
  | Chain_types.Cache { inner; _ }
  | Chain_types.Batch { inner; _ }
  | Chain_types.Spawn { inner; _ } ->
      collect_all_nodes acc inner
  | Chain_types.Threshold { input_node; on_pass; on_fail; _ } ->
      let acc = collect_all_nodes acc input_node in
      let acc = match on_pass with Some n2 -> collect_all_nodes acc n2 | None -> acc in
      (match on_fail with Some n2 -> collect_all_nodes acc n2 | None -> acc)
  | Chain_types.GoalDriven { action_node; _ } ->
      collect_all_nodes acc action_node
  | Chain_types.Evaluator { candidates; _ } ->
      List.fold_left collect_all_nodes acc candidates
  | Chain_types.Retry { node; _ } ->
      collect_all_nodes acc node
  | Chain_types.Fallback { primary; fallbacks; _ } ->
      let acc = collect_all_nodes acc primary in
      List.fold_left collect_all_nodes acc fallbacks
  | Chain_types.Mcts { strategies; simulation; _ } ->
      let acc = List.fold_left collect_all_nodes acc strategies in
      collect_all_nodes acc simulation
  | Chain_types.FeedbackLoop { generator; _ } ->
      collect_all_nodes acc generator
  | Chain_types.Cascade { tiers; _ } ->
      List.fold_left (fun acc' t -> collect_all_nodes acc' t.Chain_types.tier_node) acc tiers
  | Chain_types.Model _
  | Chain_types.Tool _
  | Chain_types.ChainRef _
  | Chain_types.ChainExec _
  | Chain_types.Adapter _
  | Chain_types.Masc_broadcast _
  | Chain_types.Masc_listen _
  | Chain_types.Masc_claim _ ->
      acc

let validate_chain_strict (c : Chain_types.chain) : (unit, string) result =
  let errors = ref [] in
  let add_error msg = errors := msg :: !errors in
  let addf fmt = Printf.ksprintf add_error fmt in

  let all_nodes = List.fold_left collect_all_nodes [] c.Chain_types.nodes in
  let all_ids = List.map (fun (n : Chain_types.node) -> n.id) all_nodes in
  let top_ids = List.map (fun (n : Chain_types.node) -> n.id) c.Chain_types.nodes in
  let output_keys = List.filter_map (fun (n : Chain_types.node) -> n.output_key) c.Chain_types.nodes in
  let valid_outputs = top_ids @ output_keys in

  if is_blank c.Chain_types.id then
    add_error "Chain id is empty";

  if c.Chain_types.nodes = [] then
    add_error "Chain has no nodes";

  if not (List.mem c.Chain_types.output valid_outputs) then
    addf "Output node '%s' not found in chain nodes" c.Chain_types.output;

  (* Config sanity checks *)
  if c.Chain_types.config.max_depth <= 0 then
    add_error "config.max_depth must be > 0";
  if c.Chain_types.config.max_concurrency <= 0 then
    add_error "config.max_concurrency must be > 0";
  if c.Chain_types.config.timeout <= 0 then
    add_error "config.timeout must be > 0";

  (* P0.3: Security limit checks *)
  let total_nodes = List.length all_nodes in
  if total_nodes > security_max_nodes then
    addf "Chain exceeds maximum node limit: %d nodes (max: %d). Split into subchains or simplify."
      total_nodes security_max_nodes;

  if c.Chain_types.config.max_depth > security_max_depth then
    addf "config.max_depth (%d) exceeds security limit (%d)"
      c.Chain_types.config.max_depth security_max_depth;

  if c.Chain_types.config.max_concurrency > security_max_concurrency then
    addf "config.max_concurrency (%d) exceeds security limit (%d)"
      c.Chain_types.config.max_concurrency security_max_concurrency;

  (* Duplicate IDs across all nodes (including nested/subgraphs) *)
  let seen = Hashtbl.create (List.length all_ids) in
  List.iter (fun id ->
    if Hashtbl.mem seen id then
      addf "Duplicate node id detected: %s" id
    else
      Hashtbl.add seen id true
  ) all_ids;

  (* Placeholder checks across all nodes *)
  let placeholders = List.fold_left collect_placeholders_in_node [] all_nodes in
  if placeholders <> [] then
    addf "Unresolved placeholder nodes found: %s"
      (String.concat ", " (List.sort_uniq String.compare placeholders));

  (* Default allowed external variables for strict validation *)
  let allowed_external =
    ["input"; "parent"; "context"; "vars"; "env"; "secrets"]
  in

  let is_allowed_external id = List.mem id allowed_external in

  let validate_ref ~node_id ~key ~ref_str =
    match extract_ref_root ~known_ids:all_ids ref_str with
    | None -> ()
    | Some root ->
        if List.mem root all_ids then ()
        else if is_allowed_external root then ()
        else
          addf "Node '%s' input '%s' references unknown node '%s' (declare in input_schema or metadata.external_inputs)"
            node_id key root
  in

  let rec validate_node (path : string) (n : Chain_types.node) : unit =
    if is_blank n.id then
      addf "%s: node id is empty" path;

    (* Template refs inside prompts/args should resolve to known nodes or allowed externals *)
    (match n.node_type with
     | Chain_types.Model { prompt; system; _ } ->
         let vars = extract_template_vars prompt in
         let vars = match system with
           | Some s -> vars @ extract_template_vars s
           | None -> vars
         in
         List.iter (fun v ->
           let ref_str = Printf.sprintf "{{%s}}" v in
           validate_ref ~node_id:n.id ~key:"prompt" ~ref_str
         ) vars
     | Chain_types.Tool { args; _ } ->
         let vars = collect_template_vars_json [] args in
         List.iter (fun v ->
           let ref_str = Printf.sprintf "{{%s}}" v in
           validate_ref ~node_id:n.id ~key:"args" ~ref_str
         ) vars
     | _ -> ());

    (* input_mapping key uniqueness *)
    let keys = List.map fst n.input_mapping in
    let key_seen = Hashtbl.create (List.length keys) in
    List.iter (fun k ->
      if Hashtbl.mem key_seen k then
        addf "%s: duplicate input_mapping key '%s'" path k
      else
        Hashtbl.add key_seen k true
    ) keys;

    (* input_mapping references *)
    List.iter (fun (k, v) ->
      if String.length k >= 5 && String.sub k 0 5 = "_dep_" then
        (* depends_on must reference existing node *)
        (match extract_ref_root ~known_ids:all_ids v with
         | Some root when List.mem root all_ids -> ()
         | Some root -> addf "%s: depends_on references unknown node '%s'" path root
         | None -> addf "%s: depends_on reference is empty" path)
      else
        validate_ref ~node_id:n.id ~key:k ~ref_str:v
    ) n.input_mapping;

    (match n.node_type with
    | Chain_types.Model { model; prompt; _ } ->
        if is_blank model then addf "%s: model.model is empty" path;
        if is_blank prompt then addf "%s: model.prompt is empty" path
    | Chain_types.Tool { name; _ } ->
        if is_blank name then addf "%s: tool.name is empty" path
    | Chain_types.Pipeline nodes ->
        if nodes = [] then addf "%s: pipeline has no nodes" path;
        List.iter (fun n2 -> validate_node (path ^ "/pipeline") n2) nodes
    | Chain_types.Fanout nodes ->
        if nodes = [] then addf "%s: fanout has no nodes" path;
        (* P0.3: Security limit on parallel branches *)
        if List.length nodes > security_max_fanout then
          addf "%s: fanout exceeds maximum branches: %d (max: %d)"
            path (List.length nodes) security_max_fanout;
        List.iter (fun n2 -> validate_node (path ^ "/fanout") n2) nodes
    | Chain_types.Quorum { consensus; nodes; _ } ->
        if nodes = [] then addf "%s: quorum has no nodes" path;
        (* P1.3: Validate based on consensus mode *)
        (match consensus with
         | Chain_types.Count n ->
             if n <= 0 then addf "%s: quorum.count must be > 0" path;
             if n > List.length nodes then
               addf "%s: quorum.count (%d) exceeds node count (%d)" path n (List.length nodes)
         | Chain_types.Weighted threshold ->
             if threshold < 0.0 || threshold > 1.0 then
               addf "%s: quorum.weighted threshold must be in [0.0, 1.0]" path
         | Chain_types.Majority | Chain_types.Unanimous -> ());
        (* P0.3: Security limit on parallel branches *)
        if List.length nodes > security_max_fanout then
          addf "%s: quorum exceeds maximum branches: %d (max: %d)"
            path (List.length nodes) security_max_fanout;
        List.iter (fun n2 -> validate_node (path ^ "/quorum") n2) nodes
    | Chain_types.Gate { condition; then_node; else_node } ->
        if is_blank condition then addf "%s: gate.condition is empty" path;
        validate_node (path ^ "/gate/then") then_node;
        (match else_node with Some n2 -> validate_node (path ^ "/gate/else") n2 | None -> ())
    | Chain_types.Subgraph sub_chain ->
        if is_blank sub_chain.Chain_types.id then addf "%s: subgraph.id is empty" path;
        if sub_chain.Chain_types.nodes = [] then addf "%s: subgraph has no nodes" path;
        let sub_ids = List.map (fun (n2 : Chain_types.node) -> n2.id) sub_chain.Chain_types.nodes in
        if not (List.mem sub_chain.Chain_types.output sub_ids) then
          addf "%s: subgraph output '%s' not found" path sub_chain.Chain_types.output;
        List.iter (fun n2 -> validate_node (path ^ "/subgraph") n2) sub_chain.Chain_types.nodes
    | Chain_types.ChainRef ref_id ->
        if is_blank ref_id then addf "%s: chain_ref is empty" path
    | Chain_types.Map { func; inner } ->
        if is_blank func then addf "%s: map.func is empty" path;
        validate_node (path ^ "/map") inner
    | Chain_types.Bind { func; inner } ->
        if is_blank func then addf "%s: bind.func is empty" path;
        validate_node (path ^ "/bind") inner
    | Chain_types.Merge { nodes; _ } ->
        if List.length nodes < 2 then addf "%s: merge requires at least 2 nodes" path;
        (* P0.3: Security limit on parallel branches *)
        if List.length nodes > security_max_fanout then
          addf "%s: merge exceeds maximum branches: %d (max: %d)"
            path (List.length nodes) security_max_fanout;
        List.iter (fun n2 -> validate_node (path ^ "/merge") n2) nodes
    | Chain_types.Threshold { metric; input_node; on_pass; on_fail; _ } ->
        if is_blank metric then addf "%s: threshold.metric is empty" path;
        validate_node (path ^ "/threshold/input") input_node;
        (match on_pass with Some n2 -> validate_node (path ^ "/threshold/pass") n2 | None -> ());
        (match on_fail with Some n2 -> validate_node (path ^ "/threshold/fail") n2 | None -> ())
    | Chain_types.GoalDriven { goal_metric; measure_func; max_iterations; action_node; _ } ->
        if is_blank goal_metric then addf "%s: goal_driven.goal_metric is empty" path;
        if is_blank measure_func then addf "%s: goal_driven.measure_func is empty" path;
        if max_iterations <= 0 then addf "%s: goal_driven.max_iterations must be > 0" path;
        validate_node (path ^ "/goal_driven/action") action_node
    | Chain_types.Evaluator { candidates; scoring_func; _ } ->
        if candidates = [] then addf "%s: evaluator has no candidates" path;
        if is_blank scoring_func then addf "%s: evaluator.scoring_func is empty" path;
        List.iter (fun n2 -> validate_node (path ^ "/evaluator") n2) candidates
    | Chain_types.Retry { node; max_attempts; _ } ->
        if max_attempts <= 0 then addf "%s: retry.max_attempts must be > 0" path;
        validate_node (path ^ "/retry") node
    | Chain_types.Fallback { primary; fallbacks } ->
        if fallbacks = [] then addf "%s: fallback has no fallback nodes" path;
        validate_node (path ^ "/fallback/primary") primary;
        List.iter (fun n2 -> validate_node (path ^ "/fallback") n2) fallbacks
    | Chain_types.Race { nodes; _ } ->
        if nodes = [] then addf "%s: race has no nodes" path;
        (* P0.3: Security limit on parallel branches *)
        if List.length nodes > security_max_fanout then
          addf "%s: race exceeds maximum branches: %d (max: %d)"
            path (List.length nodes) security_max_fanout;
        List.iter (fun n2 -> validate_node (path ^ "/race") n2) nodes
    | Chain_types.ChainExec { chain_source; max_depth; context_inject; _ } ->
        if is_blank chain_source then addf "%s: chain_exec.chain_source is empty" path;
        if max_depth <= 0 then addf "%s: chain_exec.max_depth must be > 0" path;
        List.iter (fun (child_var, parent_src) ->
          if is_blank child_var then addf "%s: chain_exec.context_inject child_var is empty" path;
          validate_ref ~node_id:n.id ~key:child_var ~ref_str:parent_src
        ) context_inject;
        (* Also validate refs embedded in chain_source templates *)
        let refs = extract_input_mappings chain_source in
        List.iter (fun (k, v) -> validate_ref ~node_id:n.id ~key:k ~ref_str:v) refs
    | Chain_types.Adapter { input_ref; _ } ->
        validate_ref ~node_id:n.id ~key:"input_ref" ~ref_str:input_ref
    | Chain_types.Cache { key_expr; ttl_seconds; inner } ->
        if is_blank key_expr then addf "%s: cache.key_expr is empty" path;
        if ttl_seconds < 0 then addf "%s: cache.ttl_seconds must be >= 0" path;
        let refs = extract_input_mappings key_expr in
        List.iter (fun (k, v) -> validate_ref ~node_id:n.id ~key:k ~ref_str:v) refs;
        validate_node (path ^ "/cache") inner
    | Chain_types.Batch { batch_size; inner; _ } ->
        if batch_size <= 0 then addf "%s: batch.batch_size must be > 0" path;
        validate_node (path ^ "/batch") inner
    | Chain_types.Spawn { inner; pass_vars; _ } ->
        List.iter (fun v -> if is_blank v then addf "%s: spawn.pass_vars contains empty entry" path) pass_vars;
        validate_node (path ^ "/spawn") inner
    | Chain_types.Mcts { strategies; simulation; max_iterations; max_depth; expansion_threshold; parallel_sims; _ } ->
        if strategies = [] then addf "%s: mcts has no strategies" path;
        if max_iterations <= 0 then addf "%s: mcts.max_iterations must be > 0" path;
        if max_depth <= 0 then addf "%s: mcts.max_depth must be > 0" path;
        if expansion_threshold <= 0 then addf "%s: mcts.expansion_threshold must be > 0" path;
        if parallel_sims <= 0 then addf "%s: mcts.parallel_sims must be > 0" path;
        List.iter (fun n2 -> validate_node (path ^ "/mcts") n2) strategies;
        validate_node (path ^ "/mcts/simulation") simulation
    | Chain_types.StreamMerge { nodes; min_results; _ } ->
        if nodes = [] then addf "%s: stream_merge has no nodes" path;
        (match min_results with
         | Some m when m <= 0 -> addf "%s: stream_merge.min_results must be > 0" path
         | Some m when m > List.length nodes ->
             addf "%s: stream_merge.min_results (%d) exceeds node count (%d)"
               path m (List.length nodes)
         | _ -> ());
        (* P0.3: Security limit on parallel branches *)
        if List.length nodes > security_max_fanout then
          addf "%s: stream_merge exceeds maximum branches: %d (max: %d)"
            path (List.length nodes) security_max_fanout;
        List.iter (fun n2 -> validate_node (path ^ "/stream_merge") n2) nodes
    | Chain_types.FeedbackLoop { generator; max_iterations; score_threshold; _ } ->
        if max_iterations <= 0 then addf "%s: feedback_loop.max_iterations must be > 0" path;
        if score_threshold < 0.0 then addf "%s: feedback_loop.score_threshold must be >= 0" path;
        validate_node (path ^ "/feedback_loop") generator
    | Chain_types.Masc_broadcast { message; _ } ->
        if is_blank message then addf "%s: masc_broadcast.message is empty" path
    | Chain_types.Masc_listen { timeout_sec; _ } ->
        if timeout_sec <= 0.0 then addf "%s: masc_listen.timeout_sec must be > 0" path
    | Chain_types.Masc_claim _ -> ()  (* No validation needed for claim *)
    | Chain_types.Cascade { tiers; max_escalations; _ } ->
        if tiers = [] then addf "%s: cascade.tiers is empty" path;
        if max_escalations <= 0 then addf "%s: cascade.max_escalations must be > 0" path;
        List.iter (fun (t : Chain_types.cascade_tier) ->
          if t.confidence_threshold < 0.0 || t.confidence_threshold > 1.0 then
            addf "%s: cascade tier %d threshold out of range [0.0, 1.0]" path t.tier_index;
          validate_node (Printf.sprintf "%s/cascade/tier%d" path t.tier_index) t.tier_node
        ) tiers
    )
  in

  List.iter (fun (n : Chain_types.node) -> validate_node ("node:" ^ n.id) n) c.Chain_types.nodes;

  if !errors = [] then Ok ()
  else
    let items = List.rev !errors in
    let msg =
      match items with
      | [] -> "Strict validation failed"
      | _ ->
          "Strict validation failed:\n- " ^ String.concat "\n- " items
    in
    Error msg

(* ============================================================================
   Chain to JSON Serializer (for JSON <-> Mermaid round-trip)
   ============================================================================ *)

(** Serialize merge strategy to string *)
