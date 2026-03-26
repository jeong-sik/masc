(** Chain Mermaid Parser — Chain AST to Mermaid serialization and ASCII visualization.
    Parsing (Mermaid to Chain) is in Chain_mermaid_graph and sub-modules. *)

open Chain_types
include Chain_mermaid_graph

(* ═══════════════════════════════════════════════════════════════════
   REVERSE DIRECTION: Chain AST → Mermaid
   ═══════════════════════════════════════════════════════════════════ *)

(** Convert a node_type to Mermaid node ID suggestion *)
let node_type_to_id (nt : node_type) (fallback : string) : string =
  match nt with
  | Model { model; _ } -> model
  | Tool { name; _ } -> name
  | Quorum { consensus; _ } -> Printf.sprintf "quorum_%s" (Chain_types.consensus_mode_to_string consensus)
  | Gate { condition; _ } ->
      let safe_cond = Re.Str.global_replace (Re.Str.regexp "[^a-zA-Z0-9_]") "_" condition in
      Printf.sprintf "gate_%s" (String.sub safe_cond 0 (min 10 (String.length safe_cond)))
  | Merge _ -> "merge"
  | Pipeline _ -> "seq"
  | Fanout _ -> "par"
  | Map { func; _ } -> Printf.sprintf "map_%s" func
  | Bind { func; _ } -> Printf.sprintf "bind_%s" func
  | ChainRef ref_id -> Printf.sprintf "ref_%s" ref_id
  | Subgraph _ -> fallback
  | Threshold { metric; _ } -> Printf.sprintf "threshold_%s" metric
  | GoalDriven { goal_metric; _ } -> Printf.sprintf "goal_%s" goal_metric
  | Evaluator { scoring_func; _ } -> Printf.sprintf "eval_%s" scoring_func
  | Retry { max_attempts; _ } -> Printf.sprintf "retry_%d" max_attempts
  | Fallback _ -> "fallback"
  | Race _ -> "race"
  | ChainExec { chain_source; _ } -> Printf.sprintf "exec_%s" (String.sub chain_source 0 (min 8 (String.length chain_source)))
  | Adapter { input_ref; _ } -> Printf.sprintf "adapt_%s" (String.sub input_ref 0 (min 8 (String.length input_ref)))
  | Cache { key_expr; ttl_seconds; _ } -> Printf.sprintf "cache_%s_%d" (String.sub key_expr 0 (min 8 (String.length key_expr))) ttl_seconds
  | Batch { batch_size; _ } -> Printf.sprintf "batch_%d" batch_size
  | Spawn { clean; _ } -> Printf.sprintf "spawn_%s" (if clean then "clean" else "inherit")
  | Mcts { policy; max_iterations; _ } ->
      let policy_str = match policy with
        | UCB1 c -> Printf.sprintf "ucb1_%.2f" c
        | Greedy -> "greedy"
        | EpsilonGreedy e -> Printf.sprintf "eps_%.2f" e
        | Softmax t -> Printf.sprintf "softmax_%.2f" t
      in Printf.sprintf "mcts_%s_%d" policy_str max_iterations
  | StreamMerge { nodes; reducer; min_results; _ } ->
      let reducer_str = match reducer with
        | First -> "first" | Last -> "last" | Concat -> "concat"
        | WeightedAvg -> "weighted" | Custom s -> s
      in
      let min_str = match min_results with Some n -> Printf.sprintf "_%d" n | None -> "" in
      Printf.sprintf "stream_merge_%s_%d%s" reducer_str (List.length nodes) min_str
  | FeedbackLoop { evaluator_config; max_iterations; score_threshold; score_operator; _ } ->
      let op_str = match score_operator with
        | Gt -> "gt" | Gte -> "gte" | Lt -> "lt" | Lte -> "lte" | Eq -> "eq" | Neq -> "neq"
      in
      Printf.sprintf "feedback_%s_%d_%s%.2f" evaluator_config.scoring_func max_iterations op_str score_threshold
  | Masc_broadcast { message; _ } -> Printf.sprintf "masc_broadcast_%s" (String.sub message 0 (min 20 (String.length message)))
  | Masc_listen { timeout_sec; _ } -> Printf.sprintf "masc_listen_%.0fs" timeout_sec
  | Masc_claim { task_id; _ } -> Printf.sprintf "masc_claim_%s" (Option.value task_id ~default:"next")
  | Cascade { tiers; _ } -> Printf.sprintf "cascade_%d" (List.length tiers)

(** Escape text for Mermaid node labels:
    - Newlines → space (Mermaid doesn't support \n in labels)
    - Double quotes → single quotes
    - Truncate very long text for readability *)
let escape_for_mermaid ?(max_len=100) (text : string) : string =
  (* Replace newlines with spaces, double quotes with single quotes *)
  let s1 = Re.Str.global_replace (Re.Str.regexp "\n") " " text in
  let s2 = Re.Str.global_replace (Re.Str.regexp {|"|}) {|'|} s1 in
  if String.length s2 > max_len then
    String.sub s2 0 (max_len - 3) ^ "..."
  else
    s2

(** Convert a node_type to Mermaid node text (lossless DSL syntax) *)
let node_type_to_text (nt : node_type) : string =
  match nt with
  | Model { model; prompt; tools; _ } ->
      let prompt_escaped = escape_for_mermaid prompt in
      let base = Printf.sprintf "MODEL:%s \"%s\"" model prompt_escaped in
      (match tools with
       | Some (`List ts) when ts <> [] ->
           let tool_names = List.filter_map (function
             | `String s -> Some s
             | `Assoc l -> (match List.assoc_opt "name" l with
                 | Some (`String n) -> Some n | _ -> None)
             | _ -> None) ts in
           if tool_names <> [] then Printf.sprintf "%s +%s" base (String.concat "," tool_names)
           else base
       | _ -> base)
  | Tool { name; args } ->
      (match args with
       | `Null | `Assoc [] -> Printf.sprintf "Tool:%s" name
       | json ->
           (* Base64 encode args for lossless roundtrip *)
           let json_str = Yojson.Safe.to_string json in
           let encoded = Base64.encode_string json_str in
           Printf.sprintf "Tool:%s %%{%s}" name encoded)
  | Quorum { consensus; _ } -> Printf.sprintf "Quorum:%s" (Chain_types.consensus_mode_to_string consensus)
  | Gate { condition; _ } -> Printf.sprintf "Gate:%s" condition
  | Merge { strategy; _ } ->
      let s = match strategy with
        | First -> "first" | Last -> "last" | Concat -> "concat"
        | WeightedAvg -> "weighted_avg" | Custom s -> s
      in Printf.sprintf "Merge:%s" s
  | Pipeline _ -> "Pipeline"  (* children handled separately *)
  | Fanout _ -> "Fanout"      (* children handled separately *)
  | Map { func; _ } -> Printf.sprintf "Map:%s" func
  | Bind { func; _ } -> Printf.sprintf "Bind:%s" func
  | ChainRef ref_id -> Printf.sprintf "Ref:%s" ref_id
  | Subgraph sub -> sub.id
  | Threshold { metric; operator; value; _ } ->
      let op = match operator with
        | Gt -> "gt" | Gte -> "gte" | Lt -> "lt" | Lte -> "lte" | Eq -> "eq" | Neq -> "neq"
      in Printf.sprintf "Threshold:%s:%s:%.2f" metric op value
  | GoalDriven { goal_metric; goal_operator; goal_value; max_iterations; _ } ->
      let op = match goal_operator with
        | Gt -> "gt" | Gte -> "gte" | Lt -> "lt" | Lte -> "lte" | Eq -> "eq" | Neq -> "neq"
      in Printf.sprintf "GoalDriven:%s:%s:%.2f:%d" goal_metric op goal_value max_iterations
  | Evaluator { scoring_func; select_strategy; _ } ->
      let s = match select_strategy with
        | Best -> "best" | Worst -> "worst" | WeightedRandom -> "weighted"
        | AboveThreshold t -> Printf.sprintf "above:%.2f" t
      in Printf.sprintf "Evaluator:%s:%s" scoring_func s
  | Retry { max_attempts; backoff; _ } ->
      let backoff_str = match backoff with
        | Constant s -> Printf.sprintf "const %.1fs" s
        | Exponential b -> Printf.sprintf "exp %.1fx" b
        | Linear b -> Printf.sprintf "linear %.1fx" b
        | Jitter (min_s, max_s) -> Printf.sprintf "jitter %.1f-%.1fs" min_s max_s
      in
      Printf.sprintf "Retry %dx (%s)" max_attempts backoff_str
  | Fallback { fallbacks; _ } ->
      Printf.sprintf "Fallback with %d alternatives" (List.length fallbacks)
  | Race { nodes; timeout; _ } ->
      let timeout_str = match timeout with Some t -> Printf.sprintf " (%.1fs)" t | None -> "" in
      Printf.sprintf "Race %d%s" (List.length nodes) timeout_str
  | ChainExec { chain_source; max_depth; sandbox; _ } ->
      let sandbox_str = if sandbox then " 🔒" else "" in
      Printf.sprintf "Exec {{%s}} (depth:%d)%s" chain_source max_depth sandbox_str
  | Adapter { input_ref; transform; _ } ->
      let transform_name = match transform with
        | Extract _ -> "extract" | Template _ -> "template" | Summarize _ -> "summarize"
        | Truncate _ -> "truncate" | JsonPath _ -> "jsonpath" | Regex _ -> "regex"
        | ValidateSchema _ -> "validate" | ParseJson -> "parse_json" | Stringify -> "stringify"
        | Chain _ -> "chain" | Conditional _ -> "conditional" | Split _ -> "split" | Custom n -> n
      in
      Printf.sprintf "Adapt[%s → %s]" input_ref transform_name
  | Cache { key_expr; ttl_seconds; inner } ->
      let ttl_str = if ttl_seconds > 0 then Printf.sprintf ",%d" ttl_seconds else "" in
      Printf.sprintf "Cache:%s%s,%s" key_expr ttl_str inner.id
  | Batch { batch_size; parallel; inner; _ } ->
      let parallel_str = if parallel then ",true" else ",false" in
      Printf.sprintf "Batch:%d%s,%s" batch_size parallel_str inner.id
  | Spawn { clean; inner; pass_vars; _ } ->
      let clean_str = if clean then "clean" else "inherit" in
      let vars_str = if pass_vars = [] then "" else "," ^ String.concat "|" pass_vars in
      Printf.sprintf "Spawn:%s%s,%s" clean_str vars_str inner.id
  | Mcts { policy; max_iterations; max_depth; evaluator; _ } ->
      let policy_str = match policy with
        | UCB1 c -> Printf.sprintf "ucb1:%.2f" c
        | Greedy -> "greedy"
        | EpsilonGreedy e -> Printf.sprintf "eps:%.2f" e
        | Softmax t -> Printf.sprintf "softmax:%.2f" t
      in Printf.sprintf "MCTS:%s:%d (depth:%d,eval:%s)" policy_str max_iterations max_depth evaluator
  | StreamMerge { reducer; min_results; timeout; _ } ->
      let reducer_str = match reducer with
        | First -> "first" | Last -> "last" | Concat -> "concat"
        | WeightedAvg -> "weighted" | Custom s -> s
      in
      (* Format: StreamMerge:reducer or StreamMerge:reducer,min or StreamMerge:reducer,min,timeout *)
      (match min_results, timeout with
       | None, None -> Printf.sprintf "StreamMerge:%s" reducer_str
       | Some m, None -> Printf.sprintf "StreamMerge:%s,%d" reducer_str m
       | Some m, Some t -> Printf.sprintf "StreamMerge:%s,%d,%.1f" reducer_str m t
       | None, Some t -> Printf.sprintf "StreamMerge:%s,1,%.1f" reducer_str t  (* default min=1 when only timeout *))
  | FeedbackLoop { evaluator_config; max_iterations; score_threshold; score_operator; _ } ->
      let op_sym = match score_operator with
        | Gt -> ">" | Gte -> ">=" | Lt -> "<" | Lte -> "<=" | Eq -> "=" | Neq -> "!="
      in
      Printf.sprintf "FeedbackLoop:%s,%d,%s%.2f" evaluator_config.scoring_func max_iterations op_sym score_threshold
  | Masc_broadcast { message; mention; _ } ->
      let mentions = if mention = [] then "" else " " ^ String.concat " " mention in
      Printf.sprintf "MASC:broadcast '%s'%s" (escape_for_mermaid ~max_len:30 message) mentions
  | Masc_listen { filter; timeout_sec; _ } ->
      let filter_str = Option.value filter ~default:"*" in
      Printf.sprintf "MASC:listen '%s' %.0fs" filter_str timeout_sec
  | Masc_claim { task_id; _ } ->
      Printf.sprintf "MASC:claim %s" (Option.value task_id ~default:"next")
  | Cascade { tiers; context_mode; default_threshold; _ } ->
      Printf.sprintf "Cascade:%.2g:%s (%d tiers)" default_threshold (Chain_types.context_mode_to_string context_mode) (List.length tiers)

(** Convert a node_type to Mermaid shape *)
let node_type_to_shape (nt : node_type) : string * string =
  match nt with
  | Model _ | Tool _ -> ("[", "]")
  | Quorum _ | Gate _ | Merge _ | Threshold _ | Evaluator _ | GoalDriven _ | FeedbackLoop _ -> ("{", "}")
  | Pipeline _ | Fanout _ | Map _ | Bind _ | ChainRef _ | Subgraph _ | Cache _ | Batch _ | Spawn _ -> ("[[", "]]")
  | Retry _ | Fallback _ | Race _ | Cascade _ -> ("(", ")")  (* Resilience nodes: rounded rectangle *)
  | ChainExec _ -> ("{{", "}}")  (* Meta nodes: hexagon *)
  | Adapter _ -> (">/", "/")  (* Adapter nodes: asymmetric shape *)
  | Mcts _ -> ("{", "}")  (* MCTS: diamond like decision nodes *)
  | StreamMerge _ -> ("[[", "]]")  (* StreamMerge: double brackets like Pipeline/Fanout *)
  | Masc_broadcast _ | Masc_listen _ | Masc_claim _ -> ("((", "))")  (* MASC: circle for coordination *)

(** Map node type to CSS class name for Mermaid styling *)
let node_type_to_class (nt : node_type) : string =
  match nt with
  | Model _ -> "model"
  | Tool _ -> "tool"
  | Quorum _ -> "quorum"
  | Gate _ -> "gate"
  | Merge _ -> "merge"
  | Threshold _ -> "threshold"
  | Evaluator _ -> "evaluator"
  | Pipeline _ -> "pipeline"
  | Fanout _ -> "fanout"
  | Map _ -> "map"
  | Bind _ -> "bind"
  | ChainRef _ -> "ref"
  | Subgraph _ -> "subgraph"
  | GoalDriven _ -> "goal"
  | Retry _ -> "retry"
  | Fallback _ -> "fallback"
  | Race _ -> "race"
  | ChainExec _ -> "meta"
  | Adapter _ -> "adapter"
  | Cache _ -> "cache"
  | Batch _ -> "batch"
  | Spawn _ -> "spawn"
  | Mcts _ -> "mcts"
  | StreamMerge _ -> "streammerge"
  | FeedbackLoop _ -> "feedbackloop"
  | Masc_broadcast _ | Masc_listen _ | Masc_claim _ -> "masc"
  | Cascade _ -> "cascade"

(** Mermaid classDef color scheme for node types *)
let mermaid_class_defs = {|    classDef model fill:#4ecdc4,stroke:#1a535c,color:#000
    classDef tool fill:#a8e6cf,stroke:#3d8b6e,color:#000
    classDef quorum fill:#ff6b6b,stroke:#c92a2a,color:#fff
    classDef gate fill:#ffd93d,stroke:#e6b800,color:#000
    classDef merge fill:#dda0dd,stroke:#9932cc,color:#000
    classDef threshold fill:#ffb347,stroke:#ff8c00,color:#000
    classDef evaluator fill:#87ceeb,stroke:#4682b4,color:#000
    classDef pipeline fill:#6c5ce7,stroke:#341f97,color:#fff
    classDef fanout fill:#fd79a8,stroke:#e84393,color:#000
    classDef map fill:#81ecec,stroke:#00b894,color:#000
    classDef bind fill:#74b9ff,stroke:#0984e3,color:#000
    classDef ref fill:#b2bec3,stroke:#636e72,color:#000
    classDef groupStyle fill:#dfe6e9,stroke:#b2bec3,color:#000
    classDef goal fill:#00b894,stroke:#00695c,color:#fff
    classDef retry fill:#fdcb6e,stroke:#f39c12,color:#000
    classDef fallback fill:#e17055,stroke:#d63031,color:#fff
    classDef race fill:#0984e3,stroke:#0652dd,color:#fff
    classDef meta fill:#9b59b6,stroke:#8e44ad,color:#fff
    classDef cache fill:#f8e71c,stroke:#d4af37,color:#000
    classDef batch fill:#7ed6df,stroke:#22a6b3,color:#000
    classDef spawn fill:#b8e994,stroke:#6ab04c,color:#000
    classDef mcts fill:#e056fd,stroke:#8e44ad,color:#fff
    classDef feedbackloop fill:#ff7f50,stroke:#cc5500,color:#fff
    classDef cascade fill:#00cec9,stroke:#00b894,color:#000
|}

(** Convert Chain AST to Mermaid text (standard-compliant, uses chain.config.direction) *)
(** Serialize input_mapping to JSON for metadata comment *)
let input_mapping_to_json (mapping : (string * string) list) : Yojson.Safe.t =
  `List (List.map (fun (k, v) -> `List [`String k; `String v]) mapping)

(** Serialize node metadata to JSON (for lossless roundtrip) *)
let node_meta_to_json (node : node) : Yojson.Safe.t option =
  (* Build list of fields to preserve *)
  let fields = ref [] in

  (* Always include input_mapping if non-empty *)
  if node.input_mapping <> [] then
    fields := ("input_mapping", input_mapping_to_json node.input_mapping) :: !fields;

  (* For GoalDriven nodes, include additional fields *)
  (match node.node_type with
  | GoalDriven { action_node; measure_func; strategy_hints; conversational; relay_models; _ } ->
      (* action_node reference *)
      fields := ("action_node_id", `String action_node.id) :: !fields;
      (* measure_func *)
      if measure_func <> "default" then
        fields := ("measure_func", `String measure_func) :: !fields;
      (* strategy_hints *)
      if strategy_hints <> [] then
        fields := ("strategy_hints", `List (List.map (fun (k, v) ->
          `List [`String k; `String v]) strategy_hints)) :: !fields;
      (* conversational *)
      if conversational then
        fields := ("conversational", `Bool true) :: !fields;
      (* relay_models *)
      if relay_models <> [] then
        fields := ("relay_models", `List (List.map (fun m -> `String m) relay_models)) :: !fields
  | _ -> ());

  (* Only emit if there's something to preserve *)
  if !fields = [] then None
  else Some (`Assoc !fields)

(** Serialize chain config to JSON (for lossless roundtrip) *)
let config_meta_to_json (chain : chain) : Yojson.Safe.t =
  `Assoc [
    ("id", `String chain.id);
    ("output", `String chain.output);
    ("timeout", `Int chain.config.timeout);
    ("trace", `Bool chain.config.trace);
    ("max_depth", `Int chain.config.max_depth);
    ("max_concurrency", `Int chain.config.max_concurrency);
  ]

let chain_to_mermaid ?(styled=true) (chain : chain) : string =
  let buf = Buffer.create 256 in
  let dir = direction_to_string chain.config.direction in
  Buffer.add_string buf (Printf.sprintf "graph %s\n" dir);

  (* Always emit lossless metadata as comments *)
  let full_json = Chain_parser.chain_to_json_string ~pretty:false ~include_empty_inputs:true chain in
  Buffer.add_string buf (Printf.sprintf "    %%%% @chain_full %s\n" full_json);
  Buffer.add_string buf (Printf.sprintf "    %%%% @chain_json %s\n" full_json);
  let config_json = Yojson.Safe.to_string (config_meta_to_json chain) in
  Buffer.add_string buf (Printf.sprintf "    %%%% @chain %s\n" config_json);
  (* Emit node metadata *)
  List.iter (fun (node : node) ->
    match node_meta_to_json node with
    | None -> ()
    | Some meta ->
        let meta_json = Yojson.Safe.to_string meta in
        Buffer.add_string buf (Printf.sprintf "    %%%% @node:%s %s\n" node.id meta_json)
  ) chain.nodes;

  (* Add classDef styles if styled=true *)
  if styled then Buffer.add_string buf mermaid_class_defs;

  (* Build edge map: target -> sources *)
  (* input_mapping is (param_name, source_node_id) - we need source_node_id for edges *)
  (* But source_node_id might be an output_key, not a node ID, so filter by actual node IDs *)
  let node_ids = List.map (fun (n : node) -> n.id) chain.nodes in
  let edges = Hashtbl.create 16 in
  List.iter (fun (node : node) ->
    List.iter (fun (_, src) ->
      (* Only add edge if src is an actual node ID *)
      if List.mem src node_ids then begin
        let existing = match Hashtbl.find_opt edges node.id with
          | Some l -> l
          | None -> []
        in
        (* Avoid duplicate edges *)
        if not (List.mem src existing) then
          Hashtbl.replace edges node.id (src :: existing)
      end
    ) node.input_mapping
  ) chain.nodes;

  (* Output nodes with class suffix *)
  List.iter (fun (node : node) ->
    let (shape_open, shape_close) = node_type_to_shape node.node_type in
    let text = node_type_to_text node.node_type in
    (* Escape double-quotes to single-quotes, but preserve backslash-escaped ones *)
    let text_escaped =
      let placeholder = "\x00ESCAPED_QUOTE\x00" in
      let step1 = Re.Str.global_replace (Re.Str.regexp {|\\"|}) placeholder text in
      let step2 = Re.Str.global_replace (Re.Str.regexp {|"|}) {|'|} step1 in
      Re.Str.global_replace (Re.Str.regexp_string placeholder) {|\\"|} step2
    in
    let class_suffix = if styled then ":::" ^ node_type_to_class node.node_type else "" in
    Buffer.add_string buf (Printf.sprintf "    %s%s\"%s\"%s%s\n"
      node.id shape_open text_escaped shape_close class_suffix)
  ) chain.nodes;

  (* Output edges *)
  Hashtbl.iter (fun target sources ->
    List.iter (fun src ->
      Buffer.add_string buf (Printf.sprintf "    %s --> %s\n" src target)
    ) sources
  ) edges;

  Buffer.contents buf

(** Round-trip test: parse and re-serialize *)
let round_trip (text : string) : (string, string) result =
  match parse_chain text with
  | Error e -> Error e
  | Ok chain -> Ok (chain_to_mermaid chain)

(** ASCII visualization of chain graph (terminal-friendly) *)
let chain_to_ascii (chain : chain) : string =
  let buf = Buffer.create 256 in
  let dir = chain.config.direction in

  (* Build adjacency map: source -> targets *)
  (* input_mapping is (param_name, source_node_id) - we need source_node_id for edges *)
  let adj = Hashtbl.create 16 in
  List.iter (fun (node : node) ->
    List.iter (fun (_, src) ->
      let targets = match Hashtbl.find_opt adj src with Some l -> l | None -> [] in
      Hashtbl.replace adj src (node.id :: targets)
    ) node.input_mapping
  ) chain.nodes;

  (* Find root nodes (no incoming edges) *)
  let all_targets = Hashtbl.fold (fun _ targets acc -> targets @ acc) adj [] in
  let roots = List.filter (fun (n : node) -> not (List.mem n.id all_targets)) chain.nodes in

  (* Node display *)
  let node_str (n : node) =
    let icon = match n.node_type with
      | Model _ -> "🤖" | Tool _ -> "🔧" | Quorum _ -> "🗳️"
      | Gate _ -> "🚦" | Merge _ -> "🔀" | Pipeline _ -> "▶️"
      | Fanout _ -> "⚡" | ChainRef _ -> "🔗" | GoalDriven _ -> "🎯"
      | Evaluator _ -> "⚖️" | Threshold _ -> "📊"
      | Map _ -> "📍" | Bind _ -> "🔄" | Subgraph _ -> "📦"
      | Retry _ -> "🔁" | Fallback _ -> "🛟" | Race _ -> "🏁"
      | ChainExec _ -> "🔮" | Adapter _ -> "🔌"
      | Cache _ -> "💾" | Batch _ -> "📦" | Spawn _ -> "🌱"
      | Mcts _ -> "🌳"
      | StreamMerge _ -> "🌊"
      | FeedbackLoop _ -> "🔄"
      | Masc_broadcast _ -> "📢"
      | Masc_listen _ -> "👂"
      | Masc_claim _ -> "✋"
      | Cascade _ -> "⏫"
    in
    let text = node_type_to_text n.node_type in
    let short_text = if String.length text > 30 then String.sub text 0 27 ^ "..." else text in
    Printf.sprintf "%s %s: %s" icon n.id short_text
  in

  (* Recursive tree print *)
  let rec print_tree prefix is_last node_id =
    let connector = if is_last then "└── " else "├── " in
    let node = List.find_opt (fun (n : node) -> n.id = node_id) chain.nodes in
    (match node with
     | Some n -> Buffer.add_string buf (Printf.sprintf "%s%s%s\n" prefix connector (node_str n))
     | None -> Buffer.add_string buf (Printf.sprintf "%s%s[%s]\n" prefix connector node_id));
    let child_prefix = prefix ^ (if is_last then "    " else "│   ") in
    let children = match Hashtbl.find_opt adj node_id with Some l -> l | None -> [] in
    let n = List.length children in
    List.iteri (fun i child ->
      print_tree child_prefix (i = n - 1) child
    ) children
  in

  (* Header *)
  let dir_str = match dir with LR -> "→" | RL -> "←" | TB -> "↓" | BT -> "↑" in
  Buffer.add_string buf (Printf.sprintf "╔══ Chain: %s (%s) ══╗\n" chain.id dir_str);
  Buffer.add_string buf (Printf.sprintf "║ Nodes: %d │ Output: %s\n" (List.length chain.nodes) chain.output);
  Buffer.add_string buf "╚════════════════════════════╝\n\n";

  (* Print from each root *)
  let n_roots = List.length roots in
  List.iteri (fun i (root : node) ->
    print_tree "" (i = n_roots - 1) root.id
  ) roots;

  Buffer.contents buf
