(** Chain Mermaid Parser - Parse Mermaid flowcharts into Chain AST

    Enables "Executable Documentation" - the same Mermaid diagram that
    renders beautifully on GitHub can be executed as a real workflow.

    ═══════════════════════════════════════════════════════════════════
    FULL 1:1 MAPPING: Mermaid ↔ Chain AST
    ═══════════════════════════════════════════════════════════════════

    ┌─────────────────────────────┬─────────────────────────────────────┐
    │ Mermaid Syntax              │ Chain AST Type                      │
    ├─────────────────────────────┼─────────────────────────────────────┤
    │ [MODEL:model "prompt"]        │ Model { model; prompt; tools=None }   │
    │ [MODEL:model "prompt" +tools] │ Model { model; prompt; tools=Some[] } │
    │ [Tool:name]                 │ Tool { name; args }                 │
    │ [[Ref:chain_id]]            │ ChainRef chain_id                   │
    │ {Quorum:N}                  │ Quorum { required = N; nodes }      │
    │ {Gate:condition}            │ Gate { condition; then; else }      │
    │ {Merge:strategy}            │ Merge { strategy; nodes }           │
    │ [[Pipeline:a,b,c]]          │ Pipeline [a; b; c]                  │
    │ [[Fanout:a,b,c]]            │ Fanout [a; b; c]                    │
    │ [[Map:func,node]]           │ Map { func; inner }                 │
    │ [[Bind:func,node]]          │ Bind { func; inner }                │
    │ [[Cache:key,ttl,node]]      │ Cache { key_expr; ttl_seconds; ... }│
    │ [[Batch:size,parallel,node]]│ Batch { batch_size; parallel; ... } │
    └─────────────────────────────┴─────────────────────────────────────┘

    Merge strategies: weighted_avg, first, last, concat, or custom name
    Cache: ttl in seconds (0 = infinite), key can use {{input}} variables
    Batch: parallel=true for concurrent processing, collect_strategy=list|concat|first|last

    ═══════════════════════════════════════════════════════════════════
    COMPOSABILITY: All types can compose with each other
    ═══════════════════════════════════════════════════════════════════

    Example: MODEL -> Pipeline -> Map -> Quorum
    {[
      graph LR
          A[MODEL:gemini "Parse"] --> P[[Pipeline:step1,step2]]
          P --> M[[Map:format,result]]
          M --> Q{Quorum:2}
    ]}

    ═══════════════════════════════════════════════════════════════════
    NODE SHAPES
    ═══════════════════════════════════════════════════════════════════

    - [...]   = Rectangle: MODEL or Tool nodes
    - {...}   = Diamond: Quorum, Gate, or Merge nodes
    - [[...]] = Subroutine: Ref, Pipeline, Fanout, Map, Bind, Cache, Batch
*)

open Chain_types

(** Parsed node from Mermaid *)
type mermaid_node = {
  id : string;
  shape : [ `Rect | `Diamond | `Subroutine | `Trap | `Stadium | `Circle ];
  content : string;
}

(** Parsed edge from Mermaid *)
type mermaid_edge = {
  from_nodes : string list;  (* Multiple for merge: A & B --> C *)
  to_node : string;
  label : string option;     (* Edge label for Gate: -->|true| or -->|false| *)
}

(** Parsed Mermaid graph *)
type mermaid_graph = {
  direction : string;  (* LR, TB, etc. *)
  nodes : mermaid_node list;
  edges : mermaid_edge list;
}

(** GoalDriven node metadata *)
type goaldriven_meta = {
  gd_action_node_id : string option;
  gd_measure_func : string option;
  gd_strategy_hints : (string * string) list;
  gd_conversational : bool;
  gd_relay_models : string list;
}

(** Metadata extracted from lossless comments *)
type mermaid_meta = {
  chain_id : string option;
  chain_output : string option;
  chain_timeout : int option;
  chain_trace : bool option;
  chain_max_depth : int option;
  chain_max_concurrency : int option;
  chain_json : Yojson.Safe.t option;
  chain_full_json : string option;
  node_input_mappings : (string, (string * string) list) Hashtbl.t;
  node_goaldriven_meta : (string, goaldriven_meta) Hashtbl.t;
}

(** Helper: trim whitespace *)
let trim s = String.trim s

(** Helper: strip surrounding quotes from content *)
let strip_quotes s =
  let s = trim s in
  let len = String.length s in
  if len >= 2 && (s.[0] = '"' || s.[0] = '\'') && s.[len-1] = s.[0] then
    String.sub s 1 (len - 2)
  else
    s

(** Helper: check if content starts with explicit type prefix.
    Used to determine parsing strategy: explicit prefix vs inferred type.

    Recognized prefixes (22 total):
    - MODEL:, Tool:, Ref: (basic nodes)
    - Quorum:, Gate:, Merge: (decision nodes)
    - Pipeline:, Fanout:, Map:, Bind: (composition nodes)
    - Cache:, Batch:, Spawn: (execution nodes)
    - Threshold:, Evaluator:, GoalDriven:, MCTS: (advanced nodes)
    - StreamMerge:, FeedbackLoop: (streaming nodes)

    @param content The node content string to check
    @return true if content starts with a recognized type prefix *)
let has_explicit_type_prefix content =
  let prefixes = [
    "MODEL:"; "Tool:"; "Ref:";
    "Quorum:"; "Gate:"; "Merge:";
    "Pipeline:"; "Fanout:"; "Map:"; "Bind:";
    "Cache:"; "Batch:"; "Spawn:";
    "Threshold:"; "Evaluator:"; "GoalDriven:"; "MCTS:";
    "StreamMerge:"; "FeedbackLoop:"
  ] in
  List.exists (fun prefix ->
    String.length content >= String.length prefix &&
    String.sub content 0 (String.length prefix) = prefix
  ) prefixes

(** Create empty metadata *)
let empty_meta () : mermaid_meta = {
  chain_id = None;
  chain_output = None;
  chain_timeout = None;
  chain_trace = None;
  chain_max_depth = None;
  chain_max_concurrency = None;
  chain_json = None;
  chain_full_json = None;
  node_input_mappings = Hashtbl.create 16;
  node_goaldriven_meta = Hashtbl.create 16;
}

(** Parse input_mapping from JSON: [[k1,v1],[k2,v2]] -> [(k1,v1);(k2,v2)] *)
let parse_input_mapping_json (json : Yojson.Safe.t) : (string * string) list =
  match json with
  | `List pairs ->
      List.filter_map (fun pair ->
        match pair with
        | `List [`String k; `String v] -> Some (k, v)
        | _ -> None
      ) pairs
  | _ -> []

(** Parse @chain metadata comment: %% @chain {"id":"...","output":"...",...} *)
let parse_chain_meta (json_str : string) (meta : mermaid_meta) : mermaid_meta =
  try
    let json = Yojson.Safe.from_string json_str in
    match json with
    | `Assoc fields ->
        let get_string key = match List.assoc_opt key fields with Some (`String s) -> Some s | _ -> None in
        let get_int key = match List.assoc_opt key fields with Some (`Int i) -> Some i | _ -> None in
        let get_bool key = match List.assoc_opt key fields with Some (`Bool b) -> Some b | _ -> None in
        {
          meta with
          chain_id = (match get_string "id" with Some v -> Some v | None -> meta.chain_id);
          chain_output = (match get_string "output" with Some v -> Some v | None -> meta.chain_output);
          chain_timeout = (match get_int "timeout" with Some v -> Some v | None -> meta.chain_timeout);
          chain_trace = (match get_bool "trace" with Some v -> Some v | None -> meta.chain_trace);
          chain_max_depth = (match get_int "max_depth" with Some v -> Some v | None -> meta.chain_max_depth);
          chain_max_concurrency = (match get_int "max_concurrency" with Some v -> Some v | None -> meta.chain_max_concurrency);
        }
    | _ -> meta
  with Yojson.Json_error _ -> meta  (* Invalid JSON in @chain comment *)

(** Parse @chain_full metadata: %% @chain_full { ...full chain JSON... } *)
let parse_chain_full (json_str : string) (meta : mermaid_meta) : mermaid_meta =
  { meta with chain_full_json = Some json_str }

(** Parse @node:id metadata comment: %% @node:mynode {"input_mapping":[[k,v],...]} *)
let parse_node_meta (node_id : string) (json_str : string) (meta : mermaid_meta) : mermaid_meta =
  try
    let json = Yojson.Safe.from_string json_str in
    match json with
    | `Assoc fields ->
        (* Parse input_mapping *)
        (match List.assoc_opt "input_mapping" fields with
        | Some mapping_json ->
            let mapping = parse_input_mapping_json mapping_json in
            Hashtbl.replace meta.node_input_mappings node_id mapping
        | None -> ());

        (* Parse GoalDriven-specific fields *)
        let get_string key = match List.assoc_opt key fields with
          | Some (`String s) -> Some s | _ -> None in
        let get_bool key = match List.assoc_opt key fields with
          | Some (`Bool b) -> b | _ -> false in
        let get_string_list key = match List.assoc_opt key fields with
          | Some (`List items) ->
              List.filter_map (function `String s -> Some s | _ -> None) items
          | _ -> [] in
        let get_string_pairs key = match List.assoc_opt key fields with
          | Some (`List items) ->
              List.filter_map (function
                | `List [`String k; `String v] -> Some (k, v)
                | _ -> None) items
          | _ -> [] in

        let action_node_id = get_string "action_node_id" in
        let measure_func = get_string "measure_func" in
        let strategy_hints = get_string_pairs "strategy_hints" in
        let conversational = get_bool "conversational" in
        let relay_models = get_string_list "relay_models" in

        (* Only store if any GoalDriven field is present *)
        if action_node_id <> None || measure_func <> None ||
           strategy_hints <> [] || conversational || relay_models <> [] then
          Hashtbl.replace meta.node_goaldriven_meta node_id {
            gd_action_node_id = action_node_id;
            gd_measure_func = measure_func;
            gd_strategy_hints = strategy_hints;
            gd_conversational = conversational;
            gd_relay_models = relay_models;
          };

        meta
    | _ -> meta
  with Yojson.Json_error _ -> meta  (* Invalid JSON in @node comment *)

(** Parse metadata from a comment line: %% @chain {...} or %% @node:id {...} *)
let parse_meta_comment (line : string) (meta : mermaid_meta) : mermaid_meta =
  let line = trim line in
  (* Check for %% prefix *)
  if String.length line < 2 || String.sub line 0 2 <> "%%" then meta
  else
    let rest = trim (String.sub line 2 (String.length line - 2)) in
    (* Check for @chain or @node: *)
    if String.length rest >= 11 && String.sub rest 0 11 = "@chain_json" then
      let json_str = trim (String.sub rest 11 (String.length rest - 11)) in
      let meta = parse_chain_full json_str meta in
      (try
         let json = Yojson.Safe.from_string json_str in
         { meta with chain_json = Some json }
       with Yojson.Json_error _ -> meta)
    else if String.length rest >= 11 && String.sub rest 0 11 = "@chain_full" then
      let json_str = trim (String.sub rest 11 (String.length rest - 11)) in
      parse_chain_full json_str meta
    else if String.length rest >= 7 && String.sub rest 0 7 = "@chain " then
      let json_str = String.sub rest 7 (String.length rest - 7) in
      parse_chain_meta json_str meta
    else if String.length rest >= 6 && String.sub rest 0 6 = "@node:" then
      (* Extract node_id and JSON *)
      let after_prefix = String.sub rest 6 (String.length rest - 6) in
      (* Find space between node_id and JSON *)
      (match String.index_opt after_prefix ' ' with
      | Some idx ->
          let node_id = String.sub after_prefix 0 idx in
          let json_str = String.sub after_prefix (idx + 1) (String.length after_prefix - idx - 1) in
          parse_node_meta node_id json_str meta
      | None -> meta)
    else meta

(* Pre-compiled regexes for better performance and reliability *)
(* Support both plain [text] and quoted ["text"] syntax *)
(* Node IDs can contain hyphens (kebab-case like vision-analyze, parse-url) *)
let rect_re = Str.regexp {|\([A-Za-z_][A-Za-z0-9_-]*\)\[\([^]]*\)\]|}
let diamond_re = Str.regexp {|\([A-Za-z_][A-Za-z0-9_-]*\){\([^}]*\)}|}
let subroutine_re = Str.regexp {|\([A-Za-z_][A-Za-z0-9_-]*\)\[\[\([^]]*\)\]\]|}
(* Stadium (rounded): (...) - used for Retry, Fallback, Race *)
let stadium_re = Str.regexp {|\([A-Za-z_][A-Za-z0-9_-]*\)(("\([^"]*\)"))|}
let stadium_noquote_re = Str.regexp {|\([A-Za-z_][A-Za-z0-9_-]*\)((\([^)]*\)))|}
(* Circle: ((...)) - used for MASC nodes - checked first due to double parens *)
let circle_re = Str.regexp {|\([A-Za-z_][A-Za-z0-9_-]*\)((("\([^"]*\)")))|}
let circle_noquote_re = Str.regexp {|\([A-Za-z_][A-Za-z0-9_-]*\)(((\([^)]*\))))|}
(* Simple stadium without double parens: ("...") *)
let stadium_simple_re = Str.regexp {|\([A-Za-z_][A-Za-z0-9_-]*\)("\([^"]*\)")|}
(* Trapezoid shape: id>/"content"/ used for Adapter nodes *)
let trap_re = Str.regexp {|\([A-Za-z_][A-Za-z0-9_-]*\)>/"\([^"]*\)"/|}
let arrow_re = Str.regexp {|[ ]*-->[ ]*|}
let ampersand_re = Str.regexp {|[ ]*&[ ]*|}
let quote_re = Str.regexp {|\([^ "]+\)[ ]*"\([^"]*\)"|}
let single_quote_re = Str.regexp {|\([^ ']+\)[ ]*'\([^']*\)'|}  (* Also accept single quotes *)
let simple_model_re = Str.regexp {|\([^ ]+\)|}
let quorum_id_re = Str.regexp {|quorum_\([0-9]+\)|}
let consensus_id_re = Str.regexp {|consensus_\([0-9]+\)|}

(** Known MODEL model names *)
let model_models = ["gemini"; "claude"; "codex"; "gpt"; "gpt4"; "gpt5"; "o1"; "o3"; "sonnet"; "opus"; "haiku"; "stub"]

(** Known tool names *)
let known_tools = ["eslint"; "tsc"; "prettier"; "jest"; "vitest"; "cargo"; "dune"; "make"; "npm"; "yarn"; "pnpm"]

(** Extract +tools flag from content. Returns (content_without_flag, has_tools) *)
let extract_tools_flag (s : string) : (string * bool) =
  let s = trim s in
  (* Check for +tools at end of string *)
  let tools_suffix = "+tools" in
  let suffix_len = String.length tools_suffix in
  let len = String.length s in
  if len > suffix_len then
    let end_part = String.sub s (len - suffix_len) suffix_len in
    if end_part = tools_suffix then
      let content = trim (String.sub s 0 (len - suffix_len)) in
      (content, true)
    else
      (s, false)
  else
    (s, false)

(** Make tools value based on flag: Some [] for tools-enabled, None otherwise *)
let make_tools_value (has_tools : bool) : Yojson.Safe.t option =
  if has_tools then Some (`List [])
  else None

(** Infer node type from node ID and shape *)
let infer_type_from_id (id : string) (shape : [ `Rect | `Diamond | `Subroutine | `Trap | `Stadium | `Circle ]) (text : string)
    : (node_type, string) result =
  let id_lower = String.lowercase_ascii id in
  let text = strip_quotes text in

  match shape with
  | `Diamond ->
      (* Diamond nodes: Quorum, Gate, or Merge *)
      if Str.string_match quorum_id_re id_lower 0 then
        let n = int_of_string (Str.matched_group 1 id_lower) in
        Ok (Quorum { consensus = Count n; nodes = []; weights = [] })
      else if Str.string_match consensus_id_re id_lower 0 then
        let n = int_of_string (Str.matched_group 1 id_lower) in
        Ok (Quorum { consensus = Count n; nodes = []; weights = [] })
      else if String.length id_lower >= 5 && String.sub id_lower 0 5 = "gate_" then
        Ok (Gate { condition = text; then_node = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None }; else_node = None })
      else if String.length id_lower >= 6 && String.sub id_lower 0 6 = "merge_" then
        Ok (Merge { strategy = Concat; nodes = [] })
      else if String.length id_lower >= 5 && String.sub id_lower 0 5 = "goal_" then
        (* goal_metric node with text: "op:value:max_iter" e.g. "gte:0.90:10" *)
        let metric = String.sub id 5 (String.length id - 5) in
        let goal_text_re = Str.regexp {|^\([a-z]+\):\([0-9.]+\):\([0-9]+\)$|} in
        if Str.string_match goal_text_re text 0 then
          let op_str = Str.matched_group 1 text in
          let value = float_of_string (Str.matched_group 2 text) in
          let max_iter = int_of_string (Str.matched_group 3 text) in
          let operator = match op_str with
            | "gt" -> Gt | "gte" -> Gte | "lt" -> Lt | "lte" -> Lte | "eq" -> Eq | "neq" -> Neq
            | _ -> Gte
          in
          Ok (GoalDriven {
            goal_metric = metric;
            goal_operator = operator;
            goal_value = value;
            action_node = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None };
            measure_func = "default";
            max_iterations = max_iter;
            strategy_hints = [];
            conversational = false;
            relay_models = [];
          })
        else
          (* Fallback: use default values if text doesn't match pattern *)
          Ok (GoalDriven {
            goal_metric = metric;
            goal_operator = Gte;
            goal_value = 0.9;
            action_node = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None };
            measure_func = "default";
            max_iterations = 10;
            strategy_hints = [];
            conversational = false;
            relay_models = [];
          })
      else if String.length id_lower >= 5 && String.sub id_lower 0 5 = "eval_" then
        (* eval_ prefix: Evaluator node *)
        Ok (Evaluator { candidates = []; scoring_func = "model_judge"; scoring_prompt = None; select_strategy = Best; min_score = None })
      else
        (* Default diamond: try to parse old syntax or default to Quorum *)
        (* First try Evaluator: prefix in text *)
        if String.length text > 10 && String.sub text 0 10 = "Evaluator:" then
          let rest = String.sub text 10 (String.length text - 10) in
          let parts = String.split_on_char ':' rest |> List.map trim in
          match parts with
          | [scoring_func; strategy_str; min_score_str] ->
              let select_strategy = match String.lowercase_ascii strategy_str with
                | "best" -> Best | "worst" -> Worst | "weighted" -> WeightedRandom
                | _ -> Best
              in
              let min_score = Safe_parse.float_opt min_score_str in
              Ok (Evaluator { candidates = []; scoring_func; scoring_prompt = None; select_strategy; min_score })
          | [scoring_func; strategy_str] ->
              let select_strategy = match String.lowercase_ascii strategy_str with
                | "best" -> Best | "worst" -> Worst | "weighted" -> WeightedRandom
                | _ -> Best
              in
              Ok (Evaluator { candidates = []; scoring_func; scoring_prompt = None; select_strategy; min_score = None })
          | [scoring_func] ->
              Ok (Evaluator { candidates = []; scoring_func; scoring_prompt = None; select_strategy = Best; min_score = None })
          | _ ->
              Ok (Evaluator { candidates = []; scoring_func = "model_judge"; scoring_prompt = None; select_strategy = Best; min_score = None })
        else
          (try
            (* P1.3: Extended Quorum syntax - Quorum:N, Quorum:majority, Quorum:unanimous, Quorum:weighted:T *)
            if String.length text > 7 && String.sub text 0 7 = "Quorum:" then
              let mode_str = String.sub text 7 (String.length text - 7) in
              let consensus = Chain_types.consensus_mode_of_string mode_str in
              Ok (Quorum { consensus; nodes = []; weights = [] })
            else
              Ok (Gate { condition = text; then_node = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None }; else_node = None })
          with Invalid_argument _ ->
            Ok (Gate { condition = text; then_node = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None }; else_node = None }))

  | `Subroutine ->
      (* Subroutine nodes: Ref, Pipeline, Fanout, Map, Bind *)
      if String.length id_lower >= 4 && String.sub id_lower 0 4 = "ref_" then
        let ref_id = String.sub id (4) (String.length id - 4) in
        Ok (ChainRef ref_id)
      else if String.length id_lower >= 4 && String.sub id_lower 0 4 = "seq_" then
        Ok (Pipeline [])
      else if String.length id_lower >= 4 && String.sub id_lower 0 4 = "par_" then
        Ok (Fanout [])
      else if String.length id_lower >= 4 && String.sub id_lower 0 4 = "map_" then
        Ok (Map { func = text; inner = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None } })
      else
        (* Default subroutine: ChainRef using the content as chain ID *)
        let ref_id = if text = "" then id else text in
        Ok (ChainRef ref_id)

  | `Rect ->
      (* Rectangle nodes: MODEL or Tool *)
      (* First, check for explicit "model:<model>\nprompt" or "MODEL:<model>\nprompt" in content *)
      let model_content_re = Str.regexp_case_fold {|^model:\([a-z0-9_-]+\)[ \n\t]+\(.*\)$|} in
      let tool_content_re = Str.regexp_case_fold {|^tool:\([a-z0-9_-]+\)[ \n\t]*\(.*\)$|} in

      if Str.string_match model_content_re text 0 then
        (* Explicit MODEL syntax in content: model:model\nprompt or model:model\nprompt +tools *)
        let model = String.lowercase_ascii (Str.matched_group 1 text) in
        let raw_prompt = trim (Str.matched_group 2 text) in
        let (prompt_clean, has_tools) = extract_tools_flag raw_prompt in
        let prompt = if prompt_clean = "" then "{{input}}" else prompt_clean in
        let tools = make_tools_value has_tools in
        Ok (Model { model; system = None; prompt; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })
      else if Str.string_match tool_content_re text 0 then
        (* Explicit Tool syntax in content: tool:name\nargs *)
        let name = Str.matched_group 1 text in
        let args_str = trim (Str.matched_group 2 text) in
        let args = if args_str = "" then `Null else
          try Yojson.Safe.from_string args_str with Yojson.Json_error _ -> `String args_str
        in
        Ok (Tool { name; args })
      else
        (* Fallback: Check if ID starts with known MODEL model *)
        let is_model = List.exists (fun model ->
          String.length id_lower >= String.length model &&
          String.sub id_lower 0 (String.length model) = model
        ) model_models in

        if is_model then
          (* Extract model from ID (e.g., "gemini_parse" -> "gemini") *)
          let model = match List.find_opt (fun m ->
            String.length id_lower >= String.length m &&
            String.sub id_lower 0 (String.length m) = m
          ) model_models with
            | Some m -> m
            | None -> "gemini" (* fallback, shouldn't happen since is_model is true *)
          in
          let (text_clean, has_tools) = extract_tools_flag text in
          let prompt = if text_clean = "" then "{{input}}" else text_clean in
          let tools = make_tools_value has_tools in
          Ok (Model { model; system = None; prompt; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })
        else if List.mem id_lower known_tools then
          Ok (Tool { name = id; args = `Null })
        else
          (* Default: treat as MODEL with "gemini" default model, text as prompt *)
          (* If ID is short (1-2 chars) or generic, use text as prompt *)
          let (text_clean, has_tools) = extract_tools_flag text in
          let prompt = if text_clean = "" then id else text_clean in
          let tools = make_tools_value has_tools in
          Ok (Model { model = "gemini"; system = None; prompt; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })

  | `Trap ->
      (* Trapezoid nodes: Adapter - parse "Adapt[input_ref → transform_type]" or similar *)
      (* Default to Template adapter with the text as template *)
      Ok (Adapter { input_ref = "input"; transform = Template text; on_error = `Fail })

  | `Stadium ->
      (* Stadium (rounded) nodes: Retry, Fallback, Race *)
      (* Format: ("Retry:N") or ("Fallback") or ("Race") *)
      if String.length text >= 6 && String.sub text 0 6 = "Retry:" then
        let max_attempts = Safe_parse.int ~context:"Retry:N" ~default:3
          (String.sub text 6 (String.length text - 6)) in
        (* Retry wraps an inner node - will be resolved from edges *)
        let placeholder_node = { id = "_retry_inner"; node_type = ChainRef "_retry_inner"; input_mapping = []; output_key = None; depends_on = None } in
        Ok (Retry { max_attempts; backoff = Constant 1.0; retry_on = []; node = placeholder_node })
      else if text = "Fallback" || String.length text >= 9 && String.sub text 0 9 = "Fallback:" then
        (* Fallback wraps primary and fallback nodes - will be resolved from edges *)
        let placeholder_primary = { id = "_fallback_primary"; node_type = ChainRef "_fallback_primary"; input_mapping = []; output_key = None; depends_on = None } in
        Ok (Fallback { primary = placeholder_primary; fallbacks = [] })
      else if text = "Race" || String.length text >= 5 && String.sub text 0 5 = "Race:" then
        (* Race runs multiple nodes and returns first result *)
        Ok (Race { nodes = []; timeout = None })
      else if String.length text >= 8 && String.sub text 0 8 = "Cascade:" then
        (* Cascade:threshold:context_mode *)
        let rest = String.sub text 8 (String.length text - 8) in
        let parts = String.split_on_char ':' rest in
        let threshold = (match parts with
          | t :: _ -> (try float_of_string t with Failure _ -> 0.7)
          | [] -> 0.7) in
        let ctx_mode = (match parts with
          | _ :: cm :: _ -> Chain_types.context_mode_of_string cm
          | _ -> Chain_types.CM_Summary) in
        Ok (Cascade { tiers = []; confidence_prompt = None; max_escalations = 2; context_mode = ctx_mode; task_hint = None; default_threshold = threshold })
      else if text = "Cascade" then
        Ok (Cascade { tiers = []; confidence_prompt = None; max_escalations = 2; context_mode = Chain_types.CM_Summary; task_hint = None; default_threshold = 0.7 })
      else
        (* Unknown stadium text - treat as MODEL with default model *)
        Ok (Model { model = "gemini"; system = None; prompt = text; timeout = None; tools = None; prompt_ref = None; prompt_vars = []; thinking = false })

  | `Circle ->
      (* Circle nodes: MASC coordination (broadcast, listen, claim) *)
      (* Format: (("📢 MASC:broadcast")) or (("👂 MASC:listen")) or (("✋ MASC:claim")) *)
      let text_lower = String.lowercase_ascii text in
      (* Strip emoji prefix if present *)
      let stripped =
        if String.length text > 2 then
          (* Try to find MASC: prefix *)
          try
            let masc_idx = Str.search_forward (Str.regexp_string "MASC:") text 0 in
            String.sub text masc_idx (String.length text - masc_idx)
          with Not_found -> text
        else text
      in
      if String.length stripped >= 14 && String.sub (String.lowercase_ascii stripped) 0 14 = "masc:broadcast" then
        let message = if String.length stripped > 15 then String.sub stripped 15 (String.length stripped - 15) else "" in
        Ok (Masc_broadcast { room = None; message; mention = [] })
      else if String.length stripped >= 11 && String.sub (String.lowercase_ascii stripped) 0 11 = "masc:listen" then
        let filter = if String.length stripped > 12 then Some (String.sub stripped 12 (String.length stripped - 12)) else None in
        Ok (Masc_listen { room = None; filter; timeout_sec = 30.0 })
      else if String.length stripped >= 10 && String.sub (String.lowercase_ascii stripped) 0 10 = "masc:claim" then
        let task_id = if String.length stripped > 11 then Some (String.sub stripped 11 (String.length stripped - 11)) else None in
        Ok (Masc_claim { room = None; task_id })
      else if String.contains text_lower 'b' && String.contains text_lower 'r' then
        (* Heuristic: broadcast *)
        Ok (Masc_broadcast { room = None; message = text; mention = [] })
      else if String.contains text_lower 'l' && String.contains text_lower 'i' then
        (* Heuristic: listen *)
        Ok (Masc_listen { room = None; filter = None; timeout_sec = 30.0 })
      else if String.contains text_lower 'c' && String.contains text_lower 'l' then
        (* Heuristic: claim *)
        Ok (Masc_claim { room = None; task_id = None })
      else
        (* Default to broadcast *)
        Ok (Masc_broadcast { room = None; message = text; mention = [] })

(** Parse node shape and extract content *)
let parse_node_definition (s : string) : (string * mermaid_node) option =
  let s = trim s in
  if s = "" then None
  (* Try subroutine first (more specific pattern: [[...]]) *)
  else if Str.string_match subroutine_re s 0 then
    let id = Str.matched_group 1 s in
    let content = Str.matched_group 2 s in
    Some (id, { id; shape = `Subroutine; content = trim content })
  (* Trapezoid: >/"..."/ used for Adapter nodes *)
  else if Str.string_match trap_re s 0 then
    let id = Str.matched_group 1 s in
    let content = Str.matched_group 2 s in
    Some (id, { id; shape = `Trap; content = trim content })
  (* Then diamond: {...} *)
  else if Str.string_match diamond_re s 0 then
    let id = Str.matched_group 1 s in
    let content = Str.matched_group 2 s in
    Some (id, { id; shape = `Diamond; content = trim content })
  (* Stadium (rounded): ("...") - used for Retry, Fallback, Race *)
  else if Str.string_match stadium_simple_re s 0 then
    let id = Str.matched_group 1 s in
    let content = Str.matched_group 2 s in
    Some (id, { id; shape = `Stadium; content = trim content })
  else if Str.string_match stadium_re s 0 then
    let id = Str.matched_group 1 s in
    let content = Str.matched_group 2 s in
    Some (id, { id; shape = `Stadium; content = trim content })
  else if Str.string_match stadium_noquote_re s 0 then
    let id = Str.matched_group 1 s in
    let content = Str.matched_group 2 s in
    Some (id, { id; shape = `Stadium; content = trim content })
  (* Circle: (((...))) - used for MASC nodes *)
  else if Str.string_match circle_re s 0 then
    let id = Str.matched_group 1 s in
    let content = Str.matched_group 2 s in
    Some (id, { id; shape = `Circle; content = trim content })
  else if Str.string_match circle_noquote_re s 0 then
    let id = Str.matched_group 1 s in
    let content = Str.matched_group 2 s in
    Some (id, { id; shape = `Circle; content = trim content })
  (* Finally rectangle: [...] *)
  else if Str.string_match rect_re s 0 then
    let id = Str.matched_group 1 s in
    let content = Str.matched_group 2 s in
    Some (id, { id; shape = `Rect; content = trim content })
  else
    None

