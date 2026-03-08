(** Chain Mermaid Parser - Parse Mermaid flowcharts into Chain AST

    Enables "Executable Documentation" - the same Mermaid diagram that
    renders beautifully on GitHub can be executed as a real workflow.

    ═══════════════════════════════════════════════════════════════════
    FULL 1:1 MAPPING: Mermaid ↔ Chain AST
    ═══════════════════════════════════════════════════════════════════

    ┌─────────────────────────────┬─────────────────────────────────────┐
    │ Mermaid Syntax              │ Chain AST Type                      │
    ├─────────────────────────────┼─────────────────────────────────────┤
    │ [LLM:model "prompt"]        │ Llm { model; prompt; tools=None }   │
    │ [LLM:model "prompt" +tools] │ Llm { model; prompt; tools=Some[] } │
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

    Example: LLM -> Pipeline -> Map -> Quorum
    {[
      graph LR
          A[LLM:gemini "Parse"] --> P[[Pipeline:step1,step2]]
          P --> M[[Map:format,result]]
          M --> Q{Quorum:2}
    ]}

    ═══════════════════════════════════════════════════════════════════
    NODE SHAPES
    ═══════════════════════════════════════════════════════════════════

    - [...]   = Rectangle: LLM or Tool nodes
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
    - LLM:, Tool:, Ref: (basic nodes)
    - Quorum:, Gate:, Merge: (decision nodes)
    - Pipeline:, Fanout:, Map:, Bind: (composition nodes)
    - Cache:, Batch:, Spawn: (execution nodes)
    - Threshold:, Evaluator:, GoalDriven:, MCTS: (advanced nodes)
    - StreamMerge:, FeedbackLoop: (streaming nodes)

    @param content The node content string to check
    @return true if content starts with a recognized type prefix *)
let has_explicit_type_prefix content =
  let prefixes = [
    "LLM:"; "Tool:"; "Ref:";
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

(** Known LLM model names *)
let llm_models = ["gemini"; "claude"; "codex"; "gpt"; "gpt4"; "gpt5"; "o1"; "o3"; "sonnet"; "opus"; "haiku"; "stub"]

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
        Ok (Evaluator { candidates = []; scoring_func = "llm_judge"; scoring_prompt = None; select_strategy = Best; min_score = None })
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
              Ok (Evaluator { candidates = []; scoring_func = "llm_judge"; scoring_prompt = None; select_strategy = Best; min_score = None })
        else
          (try
            (* P1.3: Extended Quorum syntax - Quorum:N, Quorum:majority, Quorum:unanimous, Quorum:weighted:T *)
            if String.length text > 7 && String.sub text 0 7 = "Quorum:" then
              let mode_str = String.sub text 7 (String.length text - 7) in
              let consensus = Chain_types.consensus_mode_of_string mode_str in
              Ok (Quorum { consensus; nodes = []; weights = [] })
            else
              Ok (Gate { condition = text; then_node = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None }; else_node = None })
          with _ ->
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
      (* Rectangle nodes: LLM or Tool *)
      (* First, check for explicit "llm:<model>\nprompt" or "LLM:<model>\nprompt" in content *)
      let llm_content_re = Str.regexp_case_fold {|^llm:\([a-z0-9_-]+\)[ \n\t]+\(.*\)$|} in
      let tool_content_re = Str.regexp_case_fold {|^tool:\([a-z0-9_-]+\)[ \n\t]*\(.*\)$|} in

      if Str.string_match llm_content_re text 0 then
        (* Explicit LLM syntax in content: llm:model\nprompt or llm:model\nprompt +tools *)
        let model = String.lowercase_ascii (Str.matched_group 1 text) in
        let raw_prompt = trim (Str.matched_group 2 text) in
        let (prompt_clean, has_tools) = extract_tools_flag raw_prompt in
        let prompt = if prompt_clean = "" then "{{input}}" else prompt_clean in
        let tools = make_tools_value has_tools in
        Ok (Llm { model; system = None; prompt; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })
      else if Str.string_match tool_content_re text 0 then
        (* Explicit Tool syntax in content: tool:name\nargs *)
        let name = Str.matched_group 1 text in
        let args_str = trim (Str.matched_group 2 text) in
        let args = if args_str = "" then `Null else
          try Yojson.Safe.from_string args_str with Yojson.Json_error _ -> `String args_str
        in
        Ok (Tool { name; args })
      else
        (* Fallback: Check if ID starts with known LLM model *)
        let is_llm = List.exists (fun model ->
          String.length id_lower >= String.length model &&
          String.sub id_lower 0 (String.length model) = model
        ) llm_models in

        if is_llm then
          (* Extract model from ID (e.g., "gemini_parse" -> "gemini") *)
          let model = match List.find_opt (fun m ->
            String.length id_lower >= String.length m &&
            String.sub id_lower 0 (String.length m) = m
          ) llm_models with
            | Some m -> m
            | None -> "gemini" (* fallback, shouldn't happen since is_llm is true *)
          in
          let (text_clean, has_tools) = extract_tools_flag text in
          let prompt = if text_clean = "" then "{{input}}" else text_clean in
          let tools = make_tools_value has_tools in
          Ok (Llm { model; system = None; prompt; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })
        else if List.mem id_lower known_tools then
          Ok (Tool { name = id; args = `Null })
        else
          (* Default: treat as LLM with "gemini" default model, text as prompt *)
          (* If ID is short (1-2 chars) or generic, use text as prompt *)
          let (text_clean, has_tools) = extract_tools_flag text in
          let prompt = if text_clean = "" then id else text_clean in
          let tools = make_tools_value has_tools in
          Ok (Llm { model = "gemini"; system = None; prompt; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })

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
          | t :: _ -> (try float_of_string t with _ -> 0.7)
          | [] -> 0.7) in
        let ctx_mode = (match parts with
          | _ :: cm :: _ -> Chain_types.context_mode_of_string cm
          | _ -> Chain_types.CM_Summary) in
        Ok (Cascade { tiers = []; confidence_prompt = None; max_escalations = 2; context_mode = ctx_mode; task_hint = None; default_threshold = threshold })
      else if text = "Cascade" then
        Ok (Cascade { tiers = []; confidence_prompt = None; max_escalations = 2; context_mode = Chain_types.CM_Summary; task_hint = None; default_threshold = 0.7 })
      else
        (* Unknown stadium text - treat as LLM with default model *)
        Ok (Llm { model = "gemini"; system = None; prompt = text; timeout = None; tools = None; prompt_ref = None; prompt_vars = []; thinking = false })

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

(** Mermaid labels coming from LLM JSON responses often escape inner quotes.
    Normalize those escapes before parsing the semantic node payload. *)
let normalize_label_content (content : string) : string =
  content
  |> Str.global_replace (Str.regexp {|\\\"|}) "\""
  |> Str.global_replace (Str.regexp {|\\'|}) "'"

(** Parse node content into Chain node_type *)
let parse_node_content (shape : [ `Rect | `Diamond | `Subroutine | `Trap | `Stadium | `Circle ]) (content : string)
    : (node_type, string) result =
  let content = content |> normalize_label_content |> trim in
  match shape with
  | `Subroutine ->
      (* [[Ref:chain_id]] or [[Pipeline:A,B,C]] or [[Fanout:A,B,C]] or [[Map:func,node]] or [[Bind:func,node]] *)
      if String.length content > 4 && String.sub content 0 4 = "Ref:" then
        let ref_id = trim (String.sub content 4 (String.length content - 4)) in
        Ok (ChainRef ref_id)
      else if String.length content > 9 && String.sub content 0 9 = "Pipeline:" then
        (* [[Pipeline:A,B,C]] - sequential execution *)
        let node_ids = String.sub content 9 (String.length content - 9)
          |> String.split_on_char ','
          |> List.map trim
          |> List.filter (fun s -> s <> "")
        in
        let placeholder_nodes = List.map (fun node_id ->
          { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }
        ) node_ids in
        Ok (Pipeline placeholder_nodes)
      else if String.length content > 7 && String.sub content 0 7 = "Fanout:" then
        (* [[Fanout:A,B,C]] - parallel execution *)
        let node_ids = String.sub content 7 (String.length content - 7)
          |> String.split_on_char ','
          |> List.map trim
          |> List.filter (fun s -> s <> "")
        in
        let placeholder_nodes = List.map (fun node_id ->
          { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }
        ) node_ids in
        Ok (Fanout placeholder_nodes)
      else if String.length content > 4 && String.sub content 0 4 = "Map:" then
        (* [[Map:func,node]] - transform output *)
        let parts = String.sub content 4 (String.length content - 4)
          |> String.split_on_char ','
          |> List.map trim
        in
        (match parts with
        | [func; node_id] ->
            Ok (Map { func; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } })
        | _ ->
            Error (Printf.sprintf "Map requires func,node format, got: %s" content))
      else if String.length content > 5 && String.sub content 0 5 = "Bind:" then
        (* [[Bind:func,node]] - dynamic routing *)
        let parts = String.sub content 5 (String.length content - 5)
          |> String.split_on_char ','
          |> List.map trim
        in
        (match parts with
        | [func; node_id] ->
            Ok (Bind { func; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } })
        | _ ->
            Error (Printf.sprintf "Bind requires func,node format, got: %s" content))
      else if String.length content > 6 && String.sub content 0 6 = "Cache:" then
        (* [[Cache:key_expr,ttl,node_id]] - cache results with TTL *)
        let parts = String.sub content 6 (String.length content - 6)
          |> String.split_on_char ','
          |> List.map trim
        in
        (match parts with
        | [key_expr; ttl_str; node_id] ->
            let ttl_seconds = Safe_parse.int ~context:"Cache:ttl" ~default:0 ttl_str in
            Ok (Cache { key_expr; ttl_seconds; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } })
        | [key_expr; node_id] ->
            (* Default TTL = 0 (infinite) *)
            Ok (Cache { key_expr; ttl_seconds = 0; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } })
        | _ ->
            Error (Printf.sprintf "Cache requires key,ttl,node or key,node format, got: %s" content))
      else if String.length content > 6 && String.sub content 0 6 = "Batch:" then
        (* [[Batch:size,parallel,node_id]] - batch processing *)
        let parts = String.sub content 6 (String.length content - 6)
          |> String.split_on_char ','
          |> List.map trim
        in
        (match parts with
        | [size_str; parallel_str; node_id] ->
            let batch_size = Safe_parse.int ~context:"Batch:size" ~default:10 size_str in
            let parallel = parallel_str = "true" || parallel_str = "parallel" in
            Ok (Batch { batch_size; parallel; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }; collect_strategy = `List })
        | [size_str; node_id] ->
            let batch_size = Safe_parse.int ~context:"Batch:size" ~default:10 size_str in
            Ok (Batch { batch_size; parallel = true; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }; collect_strategy = `List })
        | _ ->
            Error (Printf.sprintf "Batch requires size,parallel,node or size,node format, got: %s" content))
      else if String.length content > 6 && String.sub content 0 6 = "Spawn:" then
        (* [[Spawn:clean,node_id]] or [[Spawn:clean,pass_var1|pass_var2,node_id]] - clean context spawn *)
        let parts = String.sub content 6 (String.length content - 6)
          |> String.split_on_char ','
          |> List.map trim
        in
        (match parts with
        | [clean_str; node_id] ->
            let clean = clean_str = "true" || clean_str = "clean" in
            Ok (Spawn { clean; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }; pass_vars = []; inherit_cache = true })
        | [clean_str; pass_vars_str; node_id] ->
            let clean = clean_str = "true" || clean_str = "clean" in
            let pass_vars = String.split_on_char '|' pass_vars_str |> List.map trim in
            Ok (Spawn { clean; inner = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None }; pass_vars; inherit_cache = true })
        | _ ->
            Error (Printf.sprintf "Spawn requires clean,node or clean,pass_vars,node format, got: %s" content))
      else if String.length content > 12 && String.sub content 0 12 = "StreamMerge:" then
        (* [[StreamMerge:reducer,min_results,timeout]] - progressive result processing *)
        let parts = String.sub content 12 (String.length content - 12)
          |> String.split_on_char ','
          |> List.map trim
        in
        let parse_reducer s = match String.lowercase_ascii s with
          | "first" -> First | "last" -> Last | "concat" -> Concat
          | "weighted" | "weighted_avg" -> WeightedAvg
          | custom -> Custom custom
        in
        (match parts with
        | [reducer_str] ->
            Ok (StreamMerge {
              nodes = [];  (* filled from edges in post-process *)
              reducer = parse_reducer reducer_str;
              initial = "";
              min_results = None;
              timeout = None;
            })
        | [reducer_str; min_str] ->
            let min_results = Safe_parse.int_opt min_str in
            Ok (StreamMerge {
              nodes = [];
              reducer = parse_reducer reducer_str;
              initial = "";
              min_results;
              timeout = None;
            })
        | [reducer_str; min_str; timeout_str] ->
            let min_results = Safe_parse.int_opt min_str in
            let timeout = Safe_parse.float_opt timeout_str in
            Ok (StreamMerge {
              nodes = [];
              reducer = parse_reducer reducer_str;
              initial = "";
              min_results;
              timeout;
            })
        | _ ->
            Error (Printf.sprintf "StreamMerge format: reducer or reducer,min or reducer,min,timeout, got: %s" content))
      else if String.length content > 13 && String.sub content 0 13 = "FeedbackLoop:" then
        (* [[FeedbackLoop:scoring_func,max_iter,>=0.95]] - iterative quality improvement with explicit operator *)
        let parts = String.sub content 13 (String.length content - 13)
          |> String.split_on_char ','
          |> List.map trim
        in
        (* Generator placeholder - will be replaced during post-processing from incoming edges *)
        let gen_placeholder = { id = "feedback_gen"; node_type = ChainRef "feedback_gen"; input_mapping = []; output_key = None; depends_on = None } in
        (* Parse threshold with operator: ">=0.95", "<0.3", "0.7" (default >=) *)
        let parse_threshold_value str =
          let s = trim str in
          let parse_f sub = Safe_parse.float ~context:"FeedbackLoop:threshold" ~default:0.7 sub in
          if String.length s >= 2 && s.[0] = '>' && s.[1] = '=' then
            (Gte, parse_f (String.sub s 2 (String.length s - 2)))
          else if String.length s >= 2 && s.[0] = '<' && s.[1] = '=' then
            (Lte, parse_f (String.sub s 2 (String.length s - 2)))
          else if String.length s >= 2 && s.[0] = '!' && s.[1] = '=' then
            (Neq, parse_f (String.sub s 2 (String.length s - 2)))
          else if String.length s >= 1 && s.[0] = '>' then
            (Gt, parse_f (String.sub s 1 (String.length s - 1)))
          else if String.length s >= 1 && s.[0] = '<' then
            (Lt, parse_f (String.sub s 1 (String.length s - 1)))
          else if String.length s >= 1 && s.[0] = '=' then
            (Eq, parse_f (String.sub s 1 (String.length s - 1)))
          else
            (Gte, parse_f s)  (* default: >=value *)
        in
        (match parts with
        | [scoring_func; max_iter_str; threshold_str] ->
            let max_iterations = Safe_parse.int ~context:"FeedbackLoop:max_iter" ~default:3 max_iter_str in
            let (score_operator, score_threshold) = parse_threshold_value threshold_str in
            Ok (FeedbackLoop {
              generator = gen_placeholder;
              evaluator_config = {
                scoring_func;
                scoring_prompt = None;
                select_strategy = Best;
              };
              improver_prompt = "Improve the output based on this feedback: {{feedback}}\n\nPrevious output: {{previous_output}}";
              max_iterations;
              score_threshold;
              score_operator;
              conversational = false;
              relay_models = [];
            })
        | [scoring_func; max_iter_str] ->
            let max_iterations = Safe_parse.int ~context:"FeedbackLoop:max_iter" ~default:3 max_iter_str in
            Ok (FeedbackLoop {
              generator = gen_placeholder;
              evaluator_config = {
                scoring_func;
                scoring_prompt = None;
                select_strategy = Best;
              };
              improver_prompt = "Improve the output based on this feedback: {{feedback}}\n\nPrevious output: {{previous_output}}";
              max_iterations;
              score_threshold = 0.7;
              score_operator = Gte;
              conversational = false;
              relay_models = [];
            })
        | [scoring_func] ->
            Ok (FeedbackLoop {
              generator = gen_placeholder;
              evaluator_config = {
                scoring_func;
                scoring_prompt = None;
                select_strategy = Best;
              };
              improver_prompt = "Improve the output based on this feedback: {{feedback}}\n\nPrevious output: {{previous_output}}";
              max_iterations = 3;
              score_threshold = 0.7;
              score_operator = Gte;
              conversational = false;
              relay_models = [];
            })
        | _ ->
            Error (Printf.sprintf "FeedbackLoop format: func or func,max or func,max,>=0.95, got: %s" content))
      else
        Error (Printf.sprintf "Subroutine node must be Ref/Pipeline/Fanout/Map/Bind/Cache/Batch/Spawn/StreamMerge/FeedbackLoop, got: %s" content)

  | `Diamond ->
      (* P1.3: {Quorum:N}, {Quorum:majority}, {Quorum:unanimous}, {Quorum:weighted:T} or {Gate:condition} *)
      if String.length content > 7 && String.sub content 0 7 = "Quorum:" then
        let mode_str = trim (String.sub content 7 (String.length content - 7)) in
        let consensus = Chain_types.consensus_mode_of_string mode_str in
        (* Quorum nodes need their inputs filled in later from edges *)
        Ok (Quorum { consensus; nodes = []; weights = [] })
      else if String.length content > 5 && String.sub content 0 5 = "Gate:" then
        let condition = trim (String.sub content 5 (String.length content - 5)) in
        (* Gate needs then/else filled in from edges *)
        Ok (Gate { condition; then_node = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None }; else_node = None })
      else if String.length content > 6 && String.sub content 0 6 = "Merge:" then
        (* {Merge:strategy} - e.g., {Merge:weighted_average} *)
        let strategy_str = trim (String.sub content 6 (String.length content - 6)) in
        let strategy = match strategy_str with
          | "weighted_avg" | "weighted" -> WeightedAvg
          | "first" -> First
          | "last" -> Last
          | "concat" -> Concat
          | s -> Custom s  (* custom strategy name *)
        in
        (* Merge nodes need their inputs filled in later from edges *)
        Ok (Merge { strategy; nodes = [] })
      else if String.length content > 11 && String.sub content 0 11 = "GoalDriven:" then
        (* {GoalDriven:metric:op:value:max_iter} - e.g., {GoalDriven:coverage:gte:0.90:10} *)
        let rest = String.sub content 11 (String.length content - 11) in
        (* Format: metric:op:value:max_iter *)
        let goaldriven_re = Str.regexp {|^\([a-z_]+\):\([a-z]+\):\([0-9.]+\):\([0-9]+\)$|} in
        if Str.string_match goaldriven_re rest 0 then
          let metric = Str.matched_group 1 rest in
          let op_str = Str.matched_group 2 rest in
          let value = float_of_string (Str.matched_group 3 rest) in
          let max_iter = int_of_string (Str.matched_group 4 rest) in
          let operator = match op_str with
            | "gt" -> Gt | "gte" -> Gte | "lt" -> Lt | "lte" -> Lte | "eq" -> Eq | "neq" -> Neq
            | _ -> Gte  (* default *)
          in
          (* action_node is placeholder, filled from edges later *)
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
          Error (Printf.sprintf "Invalid GoalDriven format (expected metric:op:value:max_iter): %s" content)
      else if String.length content > 5 && String.sub content 0 5 = "MCTS:" then
        (* {MCTS:policy:iterations} - e.g., {MCTS:ucb1:1.41:10} or {MCTS:greedy:10} *)
        let rest = String.sub content 5 (String.length content - 5) in
        let parts = String.split_on_char ':' rest |> List.map trim in
        (match parts with
        | [policy_type; iter_str] when policy_type = "greedy" ->
            let max_iterations = Safe_parse.int ~context:"MCTS:iter" ~default:10 iter_str in
            (* Default simulation node - uses LLM to simulate outcomes *)
            let default_sim = { id = "_mcts_sim"; node_type = Llm { model = "gemini"; system = None; prompt = "Simulate and evaluate: {{input}}"; timeout = None; tools = None; prompt_ref = None; prompt_vars = []; thinking = false }; input_mapping = []; output_key = None; depends_on = None } in
            Ok (Mcts {
              strategies = [];  (* filled from edges in post-process *)
              simulation = default_sim;
              evaluator = "llm_judge";
              evaluator_prompt = None;
              policy = Greedy;
              max_iterations;
              max_depth = 5;
              expansion_threshold = 3;
              early_stop = None;
              parallel_sims = 1;
            })
        | [policy_type; param_str; iter_str] ->
            let max_iterations = Safe_parse.int ~context:"MCTS:iter" ~default:10 iter_str in
            let policy = match policy_type with
              | "ucb1" -> UCB1 (Safe_parse.float ~context:"MCTS:ucb1_param" ~default:1.41 param_str)
              | "eps" | "epsilon" -> EpsilonGreedy (Safe_parse.float ~context:"MCTS:epsilon" ~default:0.1 param_str)
              | "softmax" -> Softmax (Safe_parse.float ~context:"MCTS:softmax_temp" ~default:1.0 param_str)
              | _ -> UCB1 1.41  (* default *)
            in
            (* Default simulation node - uses LLM to simulate outcomes *)
            let default_sim = { id = "_mcts_sim"; node_type = Llm { model = "gemini"; system = None; prompt = "Simulate and evaluate: {{input}}"; timeout = None; tools = None; prompt_ref = None; prompt_vars = []; thinking = false }; input_mapping = []; output_key = None; depends_on = None } in
            Ok (Mcts {
              strategies = [];  (* filled from edges in post-process *)
              simulation = default_sim;
              evaluator = "llm_judge";
              evaluator_prompt = None;
              policy;
              max_iterations;
              max_depth = 5;
              expansion_threshold = 3;
              early_stop = None;
              parallel_sims = 1;
            })
        | _ ->
            Error (Printf.sprintf "Invalid MCTS format (expected policy:iterations or policy:param:iterations): %s" content))
      else if String.length content >= 10 && String.sub content 0 10 = "Evaluator:" then
        (* {Evaluator:scoring_func:select_strategy:min_score} - e.g., {Evaluator:llm_judge:best:0.7} *)
        let rest = String.sub content 10 (String.length content - 10) in
        let parts = String.split_on_char ':' rest |> List.map trim in
        (match parts with
        | [scoring_func; strategy_str; min_score_str] ->
            let select_strategy = match String.lowercase_ascii strategy_str with
              | "best" -> Best
              | "worst" -> Worst
              | "weighted" -> WeightedRandom
              | s when String.length s > 6 && String.sub s 0 6 = "above:" ->
                  let threshold = Safe_parse.float ~context:"Evaluator:above" ~default:0.5
                    (String.sub s 6 (String.length s - 6)) in
                  AboveThreshold threshold
              | _ -> Best
            in
            let min_score = Safe_parse.float_opt min_score_str in
            (* Candidates filled from edges in post-process *)
            Ok (Evaluator { candidates = []; scoring_func; scoring_prompt = None; select_strategy; min_score })
        | [scoring_func; strategy_str] ->
            let select_strategy = match String.lowercase_ascii strategy_str with
              | "best" -> Best
              | "worst" -> Worst
              | "weighted" -> WeightedRandom
              | s when String.length s > 6 && String.sub s 0 6 = "above:" ->
                  let threshold = Safe_parse.float ~context:"Evaluator:above" ~default:0.5
                    (String.sub s 6 (String.length s - 6)) in
                  AboveThreshold threshold
              | _ -> Best
            in
            Ok (Evaluator { candidates = []; scoring_func; scoring_prompt = None; select_strategy; min_score = None })
        | [scoring_func] ->
            Ok (Evaluator { candidates = []; scoring_func; scoring_prompt = None; select_strategy = Best; min_score = None })
        | _ ->
            Error (Printf.sprintf "Invalid Evaluator format (expected func or func:strategy or func:strategy:min_score): %s" content))
      else if String.length content > 10 && String.sub content 0 10 = "Threshold:" then
        (* {Threshold:>=0.8} or {Threshold:>0.5} or {Threshold:==1.0} etc. *)
        let rest = String.sub content 10 (String.length content - 10) in
        let parse_op_value s =
          if String.length s >= 2 && String.sub s 0 2 = ">=" then
            Some (Gte, String.sub s 2 (String.length s - 2))
          else if String.length s >= 2 && String.sub s 0 2 = "<=" then
            Some (Lte, String.sub s 2 (String.length s - 2))
          else if String.length s >= 2 && String.sub s 0 2 = "==" then
            Some (Eq, String.sub s 2 (String.length s - 2))
          else if String.length s >= 2 && String.sub s 0 2 = "!=" then
            Some (Neq, String.sub s 2 (String.length s - 2))
          else if String.length s >= 1 && String.sub s 0 1 = ">" then
            Some (Gt, String.sub s 1 (String.length s - 1))
          else if String.length s >= 1 && String.sub s 0 1 = "<" then
            Some (Lt, String.sub s 1 (String.length s - 1))
          else None
        in
        (match parse_op_value rest with
        | Some (operator, value_str) ->
            (try
              let value = float_of_string (trim value_str) in
              let placeholder_ref = { id = "_placeholder"; node_type = ChainRef "_"; input_mapping = []; output_key = None; depends_on = None } in
              Ok (Threshold { metric = "score"; operator; value; input_node = placeholder_ref; on_pass = None; on_fail = None })
            with Failure _ ->
              Error (Printf.sprintf "Invalid Threshold value: %s" value_str))
        | None ->
            Error (Printf.sprintf "Invalid Threshold operator (expected >=, >, <=, <, ==, !=): %s" content))
      else
        Error (Printf.sprintf "Diamond node must be Quorum:N, Gate:condition, Merge:strategy, GoalDriven:..., MCTS:..., Evaluator:..., or Threshold:op+value, got: %s" content)

  | `Rect ->
      (* [LLM:model "prompt"] or [LLM:model "prompt" +tools] or [Tool:name] *)
      (* First extract +tools flag from end of content *)
      let (content_clean, has_tools) = extract_tools_flag content in
      let tools = make_tools_value has_tools in
      if String.length content_clean > 4 && String.sub content_clean 0 4 = "LLM:" then
        let rest = String.sub content_clean 4 (String.length content_clean - 4) in
        (* Parse: model "prompt" or model 'prompt' or just model *)
        if Str.string_match quote_re rest 0 then
          let model = Str.matched_group 1 rest in
          let prompt = Str.matched_group 2 rest in
          Ok (Llm { model = trim model; system = None; prompt = trim prompt; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })
        else if Str.string_match single_quote_re rest 0 then
          let model = Str.matched_group 1 rest in
          let prompt = Str.matched_group 2 rest in
          Ok (Llm { model = trim model; system = None; prompt = trim prompt; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })
        else if Str.string_match simple_model_re rest 0 then
          let model = Str.matched_group 1 rest in
          Ok (Llm { model = trim model; system = None; prompt = "{{input}}"; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })
        else
          Error (Printf.sprintf "Invalid LLM format: %s" content)
      else if String.length content_clean > 5 && String.sub content_clean 0 5 = "Tool:" then
        let rest = String.sub content_clean 5 (String.length content_clean - 5) in
        (* Try Base64 encoded args first: "name %{base64}" *)
        let base64_re = Str.regexp {|^\([^ ]+\) *%{\([^}]+\)}$|} in
        if Str.string_match base64_re rest 0 then
          let name = trim (Str.matched_group 1 rest) in
          let encoded = Str.matched_group 2 rest in
          (try
             let decoded = Base64.decode_exn encoded in
             let args = Yojson.Safe.from_string decoded in
             Ok (Tool { name; args })
           with _ ->
             (* Fallback: if Base64 decode fails, store as-is *)
             Ok (Tool { name; args = `Assoc [("input", `String encoded)] }))
        (* Parse: name "args" or name 'args' or name {...json...} or just name *)
        else if Str.string_match quote_re rest 0 then
          let name = trim (Str.matched_group 1 rest) in
          let args_str = trim (Str.matched_group 2 rest) in
          (* Create args with "input" key holding the args string *)
          Ok (Tool { name; args = `Assoc [("input", `String args_str)] })
        else if Str.string_match single_quote_re rest 0 then
          let name = trim (Str.matched_group 1 rest) in
          let args_str = trim (Str.matched_group 2 rest) in
          Ok (Tool { name; args = `Assoc [("input", `String args_str)] })
        else
          (* Try to find name followed by JSON: "name {...}" *)
          let json_start = String.index_opt rest '{' in
          (match json_start with
           | Some idx when idx > 0 ->
               let name = trim (String.sub rest 0 idx) in
               let json_str = String.sub rest idx (String.length rest - idx) in
               (* Un-escape Mermaid quotes: \" -> " *)
               let json_unescaped = Str.global_replace (Str.regexp {|\\"|}) {|"|} json_str in
               (try
                  let args = Yojson.Safe.from_string json_unescaped in
                  Ok (Tool { name; args })
                with _ ->
                  (* If JSON parse fails, store as input *)
                  Ok (Tool { name; args = `Assoc [("input", `String json_unescaped)] }))
           | _ ->
               (* No JSON, try simple name *)
               if Str.string_match simple_model_re rest 0 then
                 let name = trim (Str.matched_group 1 rest) in
                 Ok (Tool { name; args = `Assoc [] })
               else
                 Error (Printf.sprintf "Invalid Tool format: %s" content))
      else
        (* Default: treat as LLM with content as prompt, model = gemini *)
        Ok (Llm { model = "gemini"; system = None; prompt = content_clean; timeout = None; tools; prompt_ref = None; prompt_vars = []; thinking = false })

  | `Trap ->
      (* Trapezoid: Adapter nodes, content format: "Adapt[input → template]" or similar *)
      (* Parse the content to extract input_ref and transform type *)
      if String.length content > 5 && String.sub content 0 5 = "Adapt" then
        (* Default adapter with template transform *)
        Ok (Adapter { input_ref = "input"; transform = Template content; on_error = `Fail })
      else
        (* Generic adapter using the content as template *)
        Ok (Adapter { input_ref = "input"; transform = Template content; on_error = `Fail })

  | `Stadium ->
      (* Stadium (rounded) nodes: Retry, Fallback, Race - same logic as infer_type_from_id *)
      if String.length content >= 6 && String.sub content 0 6 = "Retry:" then
        let max_attempts = Safe_parse.int ~context:"Retry:N" ~default:3
          (String.sub content 6 (String.length content - 6)) in
        let placeholder_node = { id = "_retry_inner"; node_type = ChainRef "_retry_inner"; input_mapping = []; output_key = None; depends_on = None } in
        Ok (Retry { max_attempts; backoff = Constant 1.0; retry_on = []; node = placeholder_node })
      else if content = "Fallback" || (String.length content >= 9 && String.sub content 0 9 = "Fallback:") then
        let placeholder_primary = { id = "_fallback_primary"; node_type = ChainRef "_fallback_primary"; input_mapping = []; output_key = None; depends_on = None } in
        Ok (Fallback { primary = placeholder_primary; fallbacks = [] })
      else if content = "Race" || (String.length content >= 5 && String.sub content 0 5 = "Race:") then
        Ok (Race { nodes = []; timeout = None })
      else if String.length content >= 8 && String.sub content 0 8 = "Cascade:" then
        let rest = String.sub content 8 (String.length content - 8) in
        let parts = String.split_on_char ':' rest in
        let threshold = (match parts with
          | t :: _ -> (try float_of_string t with _ -> 0.7)
          | [] -> 0.7) in
        let ctx_mode = (match parts with
          | _ :: cm :: _ -> Chain_types.context_mode_of_string cm
          | _ -> Chain_types.CM_Summary) in
        Ok (Cascade { tiers = []; confidence_prompt = None; max_escalations = 2; context_mode = ctx_mode; task_hint = None; default_threshold = threshold })
      else if content = "Cascade" then
        Ok (Cascade { tiers = []; confidence_prompt = None; max_escalations = 2; context_mode = Chain_types.CM_Summary; task_hint = None; default_threshold = 0.7 })
      else
        Ok (Llm { model = "gemini"; system = None; prompt = content; timeout = None; tools = None; prompt_ref = None; prompt_vars = []; thinking = false })

  | `Circle ->
      (* Circle nodes: MASC coordination - same logic as infer_type_from_id *)
      let content_lower = String.lowercase_ascii content in
      let stripped =
        if String.length content > 2 then
          try
            let masc_idx = Str.search_forward (Str.regexp_string "MASC:") content 0 in
            String.sub content masc_idx (String.length content - masc_idx)
          with Not_found -> content
        else content
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
      else
        (* keyword-based heuristic before character fallback *)
        let has_word w =
          let wl = String.length w and cl = String.length content_lower in
          if wl > cl then false
          else let found = ref false in
            for i = 0 to cl - wl do
              if not !found && String.sub content_lower i wl = w then found := true
            done; !found
        in
        if has_word "wait" || has_word "listen" then
          Ok (Masc_listen { room = None; filter = None; timeout_sec = 30.0 })
        else if has_word "claim" || has_word "grab" then
          Ok (Masc_claim { room = None; task_id = None })
        (* character-based fallback *)
        else if String.contains content_lower 'b' && String.contains content_lower 'r' then
          Ok (Masc_broadcast { room = None; message = content; mention = [] })
        else if String.contains content_lower 'l' && String.contains content_lower 'i' then
          Ok (Masc_listen { room = None; filter = None; timeout_sec = 30.0 })
        else if String.contains content_lower 'c' && String.contains content_lower 'l' then
          Ok (Masc_claim { room = None; task_id = None })
        else
          Ok (Masc_broadcast { room = None; message = content; mention = [] })

(** Parse edge line: A --> B or A & B --> C or A -->|label| B *)
let parse_edge_line (line : string) : mermaid_edge list =
  let line = trim line in

  (* Extract label from arrow if present: -->|label| becomes (-->, Some label) *)
  let extract_label_and_split s =
    (* Check for labeled edge pattern: A -->|label| B *)
    (* Use string search instead of complex regex to avoid Str.regexp | escaping issues *)
    match String.split_on_char '|' s with
    | [before_pipe; label_part; after_pipe] when String.length before_pipe > 0 ->
        (* Check if before_pipe ends with --> *)
        let before_trimmed = trim before_pipe in
        if String.length before_trimmed >= 3 &&
           String.sub before_trimmed (String.length before_trimmed - 3) 3 = "-->" then
          let from_part = String.sub before_trimmed 0 (String.length before_trimmed - 3) in
          (trim from_part, trim after_pipe, Some (trim label_part))
        else
          (* No --> before |, try simple arrow pattern *)
          (try
            if Str.string_match (Str.regexp {|^\([^-]*\)-->\(.*\)$|}) s 0 then
              let from_part = Str.matched_group 1 s in
              let to_part = Str.matched_group 2 s in
              (trim from_part, trim to_part, None)
            else
              (s, "", None)
          with Not_found -> (s, "", None))
    | _ ->
        (* Try pattern: A --> B (no label) *)
        (try
          if Str.string_match (Str.regexp {|^\([^-]*\)-->\(.*\)$|}) s 0 then
            let from_part = Str.matched_group 1 s in
            let to_part = Str.matched_group 2 s in
            (trim from_part, trim to_part, None)
          else
            (s, "", None)
        with Not_found -> (s, "", None))
  in

  let (from_part, to_part, label) = extract_label_and_split line in

  (* Check if to_part contains another --> (chained arrows like A --> B --> C) *)
  let has_chained_arrows =
    to_part <> "" &&
    (try let _ = Str.search_forward (Str.regexp "-->") to_part 0 in true
     with Not_found -> false)
  in

  if to_part = "" || has_chained_arrows then
    (* Fall back to original logic for complex multi-arrow lines *)
    let parts = Str.split arrow_re line in
    let rec build_edges acc = function
      | [] | [_] -> List.rev acc
      | from_part :: to_part :: rest ->
          let from_nodes =
            from_part
            |> Str.split ampersand_re
            |> List.map (fun s ->
                let s = trim s in
                match parse_node_definition s with
                | Some (id, _) -> id
                | None -> s)
          in
          let to_node =
            let s = trim to_part in
            match parse_node_definition s with
            | Some (id, _) -> id
            | None -> s
          in
          let edge = { from_nodes; to_node; label = None } in
          build_edges (edge :: acc) (to_part :: rest)
    in
    build_edges [] parts
  else
    (* Single labeled edge *)
    let from_nodes =
      from_part
      |> Str.split ampersand_re
      |> List.map (fun s ->
          let s = trim s in
          match parse_node_definition s with
          | Some (id, _) -> id
          | None -> s)
    in
    let to_node =
      match parse_node_definition to_part with
      | Some (id, _) -> id
      | None -> to_part
    in
    [{ from_nodes; to_node; label }]

(** Join lines that have unclosed brackets (handle multiline node content) *)
(* Parse state: (bracket_count, in_double_quote, in_single_quote) *)
let join_multiline_brackets (lines : string list) : string list =
  (* Update state by scanning a string, carrying over quote state *)
  let scan_string s (count, in_double, in_single) =
    let len = String.length s in
    let rec loop i count in_double in_single =
      if i >= len then (count, in_double, in_single)
      else
        let c = s.[i] in
        (* Handle escape: skip next char *)
        if c = '\\' && i + 1 < len then
          loop (i + 2) count in_double in_single
        (* Toggle double quote state (only if not in single) *)
        else if c = '"' && not in_single then
          loop (i + 1) count (not in_double) in_single
        (* Toggle single quote state (only if not in double) *)
        else if c = '\'' && not in_double then
          loop (i + 1) count in_double (not in_single)
        (* Count brackets only when not in any quoted string *)
        else if not in_double && not in_single then
          match c with
          | '[' -> loop (i + 1) (count + 1) in_double in_single
          | ']' -> loop (i + 1) (count - 1) in_double in_single
          | '{' -> loop (i + 1) (count + 1) in_double in_single
          | '}' -> loop (i + 1) (count - 1) in_double in_single
          | _ -> loop (i + 1) count in_double in_single
        else
          loop (i + 1) count in_double in_single
    in
    loop 0 count in_double in_single
  in

  let initial_state = (0, false, false) in

  let is_closed (count, in_double, in_single) =
    count <= 0 && not in_double && not in_single
  in

  let is_open (count, in_double, in_single) =
    count > 0 || in_double || in_single
  in

  let rec process acc pending_lines state = function
    | [] ->
        (* Flush any remaining pending lines *)
        if pending_lines = [] then List.rev acc
        else List.rev ((String.concat " " (List.rev pending_lines)) :: acc)
    | line :: rest ->
        let line = trim line in
        if line = "" then
          process acc pending_lines state rest
        else if is_open state then begin
          (* Continue collecting multiline content (unclosed brackets or quotes) *)
          let new_state = scan_string line state in
          let new_pending = line :: pending_lines in
          if is_closed new_state then
            (* All closed, flush the joined line *)
            let joined = String.concat " " (List.rev new_pending) in
            process (joined :: acc) [] initial_state rest
          else
            process acc new_pending new_state rest
        end
        else begin
          (* Check if this line opens unclosed brackets or quotes *)
          let new_state = scan_string line initial_state in
          if is_open new_state then
            (* Line has unclosed brackets/quotes, start collecting *)
            process acc [line] new_state rest
          else
            (* Normal complete line *)
            process (line :: acc) [] initial_state rest
        end
  in
  process [] [] initial_state lines

(** Parse full Mermaid graph text *)
(** Parse Mermaid text with metadata extraction (for lossless roundtrip) *)
let parse_mermaid_text_with_meta (text : string) : ((mermaid_graph * mermaid_meta), string) result =
  (* First join multiline bracket content *)
  let raw_lines = String.split_on_char '\n' text |> List.map trim in
  let lines = join_multiline_brackets raw_lines in

  (* Find graph direction *)
  let direction = ref "LR" in
  let nodes = Hashtbl.create 16 in
  let edges = ref [] in
  let meta = ref (empty_meta ()) in

  List.iter (fun line ->
    let line = trim line in
    (* Handle comments - extract metadata first, then skip *)
    if line = "" then ()
    else if String.length line > 0 && line.[0] = '%' then begin
      (* Try to extract metadata from comment *)
      meta := parse_meta_comment line !meta
    end
    (* Parse graph direction *)
    else if String.length line >= 5 && String.sub line 0 5 = "graph" then begin
      let rest = trim (String.sub line 5 (String.length line - 5)) in
      if rest <> "" then direction := rest
    end
    else if String.length line >= 9 && String.sub line 0 9 = "flowchart" then begin
      let rest = trim (String.sub line 9 (String.length line - 9)) in
      if rest <> "" then direction := rest
    end
    (* Skip subgraph/end for now *)
    else if String.length line >= 8 && String.sub line 0 8 = "subgraph" then ()
    else if line = "end" then ()
    (* Parse edges and collect nodes *)
    else begin
      (* Extract all node definitions from the line *)
      let parts = Str.split arrow_re line in
      List.iter (fun part ->
        let part = trim part in
        (* Split by & for multiple nodes *)
        let sub_parts = Str.split ampersand_re part in
        List.iter (fun sub ->
          match parse_node_definition (trim sub) with
          | Some (id, node) -> Hashtbl.replace nodes id node
          | None -> ()
        ) sub_parts
      ) parts;
      (* Parse edges *)
      let new_edges = parse_edge_line line in
      edges := !edges @ new_edges
    end
  ) lines;

  Ok ({
    direction = !direction;
    nodes = Hashtbl.fold (fun _ node acc -> node :: acc) nodes [];
    edges = !edges;
  }, !meta)

(** Parse full Mermaid graph text (backward compatible, discards metadata) *)
let parse_mermaid_text (text : string) : (mermaid_graph, string) result =
  match parse_mermaid_text_with_meta text with
  | Ok (graph, _meta) -> Ok graph
  | Error e -> Error e

(** Build dependency graph from edges (incoming: to_node -> [from_nodes]) *)
let build_dependency_graph (edges : mermaid_edge list) : (string, string list) Hashtbl.t =
  let deps = Hashtbl.create 16 in
  List.iter (fun edge ->
    let existing =
      match Hashtbl.find_opt deps edge.to_node with
      | Some l -> l
      | None -> []
    in
    Hashtbl.replace deps edge.to_node (existing @ edge.from_nodes)
  ) edges;
  deps

(** Build outgoing edges map with labels (from_node -> [(to_node, label option)]) *)
let build_outgoing_edges (edges : mermaid_edge list) : (string, (string * string option) list) Hashtbl.t =
  let outgoing = Hashtbl.create 16 in
  List.iter (fun edge ->
    List.iter (fun from_node ->
      let existing =
        match Hashtbl.find_opt outgoing from_node with
        | Some l -> l
        | None -> []
      in
      Hashtbl.replace outgoing from_node (existing @ [(edge.to_node, edge.label)])
    ) edge.from_nodes
  ) edges;
  outgoing

(** Find nodes with no outgoing edges (terminal nodes) *)
let find_output_nodes (graph : mermaid_graph) : string list =
  let has_outgoing = Hashtbl.create 16 in
  List.iter (fun edge ->
    List.iter (fun from_node ->
      Hashtbl.replace has_outgoing from_node true
    ) edge.from_nodes
  ) graph.edges;

  graph.nodes
  |> List.filter (fun node -> not (Hashtbl.mem has_outgoing node.id))
  |> List.map (fun node -> node.id)

(** Convert Mermaid graph to Chain AST *)
let mermaid_to_chain ?(id = "mermaid_chain") (graph : mermaid_graph) : (chain, string) result =
  let deps = build_dependency_graph graph.edges in

  (* Convert each mermaid node to chain node *)
  let node_map = Hashtbl.create 16 in

  let convert_result = ref (Ok ()) in

  List.iter (fun mnode ->
    match !convert_result with
    | Error _ -> ()
    | Ok () ->
        (* Try new inference-based parsing first, fall back to old explicit syntax *)
        let parse_result =
          (* Check if content uses explicit type prefix (LLM:, Tool:, etc.) *)
          (* Strip surrounding quotes that may be added by chain_to_mermaid *)
          let content = strip_quotes mnode.content in
          if has_explicit_type_prefix content then
            parse_node_content mnode.shape content
          else
            infer_type_from_id mnode.id mnode.shape content
        in
        match parse_result with
        | Error e -> convert_result := Error e
        | Ok node_type ->
            (* For Quorum, Merge, and StreamMerge nodes, we need to fill in the child nodes *)
            (* Use ChainRef with _ref suffix to avoid duplicate node ID issues *)
            let node_type = match node_type with
              | Quorum { consensus; nodes = _; weights } ->
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  (* Create ChainRef nodes for inputs with _ref suffix *)
                  let input_nodes = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  Quorum { consensus; nodes = input_nodes; weights }
              | Merge { strategy; nodes = _ } ->
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  let input_nodes = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  Merge { strategy; nodes = input_nodes }
              | StreamMerge { reducer; initial; min_results; timeout; nodes = _ } ->
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  let input_nodes = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  StreamMerge { reducer; initial; min_results; timeout; nodes = input_nodes }
              | Race { timeout; nodes = _ } ->
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  let input_nodes = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  Race { timeout; nodes = input_nodes }
              | Fallback { primary = _; fallbacks = _ } ->
                  (* First input is primary, rest are fallbacks *)
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  (match input_ids with
                  | primary_id :: fallback_ids ->
                      let primary = { id = primary_id ^ "_ref"; node_type = ChainRef primary_id; input_mapping = []; output_key = None; depends_on = None } in
                      let fallbacks = List.map (fun fb_id ->
                        { id = fb_id ^ "_ref"; node_type = ChainRef fb_id; input_mapping = []; output_key = None; depends_on = None }
                      ) fallback_ids in
                      Fallback { primary; fallbacks }
                  | [] ->
                      (* No inputs - keep placeholder *)
                      let placeholder = { id = "_fallback_primary"; node_type = ChainRef "_fallback_primary"; input_mapping = []; output_key = None; depends_on = None } in
                      Fallback { primary = placeholder; fallbacks = [] })
              | Retry { max_attempts; backoff; retry_on; node = _ } ->
                  (* First input is the node to retry *)
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  (match input_ids with
                  | node_id :: _ ->
                      let inner_node = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } in
                      Retry { max_attempts; backoff; retry_on; node = inner_node }
                  | [] ->
                      (* No inputs - keep placeholder *)
                      let placeholder = { id = "_retry_inner"; node_type = ChainRef "_retry_inner"; input_mapping = []; output_key = None; depends_on = None } in
                      Retry { max_attempts; backoff; retry_on; node = placeholder })
              | Cascade c ->
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  let incoming_nodes = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  let tiers = List.mapi (fun i source_node ->
                    { Chain_types.tier_node = source_node;
                      tier_index = i;
                      confidence_threshold = c.default_threshold;
                      cost_weight = float_of_int i;
                      pass_context = true }
                  ) incoming_nodes in
                  Cascade { c with tiers }
              | Evaluator { scoring_func; scoring_prompt; select_strategy; min_score; candidates = _ } ->
                  (* Candidates from incoming edges *)
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  let candidates = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  Evaluator { scoring_func; scoring_prompt; select_strategy; min_score; candidates }
              | other -> other
            in
            let input_mapping =
              match Hashtbl.find_opt deps mnode.id with
              | Some inputs ->
                  (* Map: key (for substitution pattern {{key}}) -> node_id (for ctx.outputs lookup)
                     Note: Don't wrap in {{}} - resolve_inputs expects plain node_id *)
                  List.map (fun inp -> (inp, inp)) inputs
              | None -> []
            in
            let node = { id = mnode.id; node_type; input_mapping;
                         output_key = None; depends_on = None } in
            Hashtbl.replace node_map mnode.id node
  ) graph.nodes;

  match !convert_result with
  | Error e -> Error e
  | Ok () ->
      (* Build node list *)
      let nodes = Hashtbl.fold (fun _ node acc -> node :: acc) node_map [] in

      (* Find output node *)
      let output_nodes = find_output_nodes graph in
      let output = match output_nodes with
        | [single] -> single
        | first :: _ -> first  (* Take first if multiple *)
        | [] ->
            (* No terminal node, use last defined *)
            match List.rev graph.nodes with
            | last :: _ -> last.id
            | [] -> "output"
      in

      Ok {
        id;
        nodes;
        output;
        config = { default_config with direction = direction_of_string graph.direction };
        name = None; description = None; version = None;
        input_schema = None; output_schema = None; metadata = None;
      }

(** Convert Mermaid graph to Chain AST with metadata (for lossless roundtrip) *)
let mermaid_to_chain_with_meta ?(id = "mermaid_chain") (graph : mermaid_graph) (meta : mermaid_meta) : (chain, string) result =
  let fallback () =
    let deps = build_dependency_graph graph.edges in
    let outgoing = build_outgoing_edges graph.edges in

    (* Convert each mermaid node to chain node *)
    let node_map = Hashtbl.create 16 in
    let convert_result = ref (Ok ()) in

    List.iter (fun mnode ->
      match !convert_result with
      | Error _ -> ()
      | Ok () ->
          let parse_result =
            (* Strip surrounding quotes that may be added by chain_to_mermaid *)
            let content = strip_quotes mnode.content in
            if has_explicit_type_prefix content then
              parse_node_content mnode.shape content
            else
              infer_type_from_id mnode.id mnode.shape content
          in
          match parse_result with
          | Error e -> convert_result := Error e
          | Ok node_type ->
              (* Use ChainRef with _ref suffix to avoid duplicate node ID issues *)
              let node_type = match node_type with
                | Quorum { consensus; nodes = _; weights } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let input_nodes = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    Quorum { consensus; nodes = input_nodes; weights }
                | Merge { strategy; nodes = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let input_nodes = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    Merge { strategy; nodes = input_nodes }
                | StreamMerge { reducer; initial; min_results; timeout; nodes = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let input_nodes = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    StreamMerge { reducer; initial; min_results; timeout; nodes = input_nodes }
                | Race { timeout; nodes = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let input_nodes = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    Race { timeout; nodes = input_nodes }
                | Fallback { primary = _; fallbacks = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    (match input_ids with
                    | primary_id :: fallback_ids ->
                        let primary = { id = primary_id ^ "_ref"; node_type = ChainRef primary_id; input_mapping = []; output_key = None; depends_on = None } in
                        let fallbacks = List.map (fun fb_id ->
                          { id = fb_id ^ "_ref"; node_type = ChainRef fb_id; input_mapping = []; output_key = None; depends_on = None }
                        ) fallback_ids in
                        Fallback { primary; fallbacks }
                    | [] ->
                        let placeholder = { id = "_fallback_primary"; node_type = ChainRef "_fallback_primary"; input_mapping = []; output_key = None; depends_on = None } in
                        Fallback { primary = placeholder; fallbacks = [] })
                | Retry { max_attempts; backoff; retry_on; node = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    (match input_ids with
                    | node_id :: _ ->
                        let inner_node = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } in
                        Retry { max_attempts; backoff; retry_on; node = inner_node }
                    | [] ->
                        let placeholder = { id = "_retry_inner"; node_type = ChainRef "_retry_inner"; input_mapping = []; output_key = None; depends_on = None } in
                        Retry { max_attempts; backoff; retry_on; node = placeholder })
                | Cascade c ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let incoming_nodes = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    let tiers = List.mapi (fun i source_node ->
                      { Chain_types.tier_node = source_node;
                        tier_index = i;
                        confidence_threshold = c.default_threshold;
                        cost_weight = float_of_int i;
                        pass_context = true }
                    ) incoming_nodes in
                    Cascade { c with tiers }
                | Evaluator { scoring_func; scoring_prompt; select_strategy; min_score; candidates = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let candidates = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    Evaluator { scoring_func; scoring_prompt; select_strategy; min_score; candidates }
                | GoalDriven gd ->
                    (* Apply metadata if available *)
                    (match Hashtbl.find_opt meta.node_goaldriven_meta mnode.id with
                    | Some gd_meta ->
                        (* Build action_node from metadata or edges *)
                        let action_node_id = match gd_meta.gd_action_node_id with
                          | Some id -> id
                          | None ->
                              (* Fall back to first edge source *)
                              match Hashtbl.find_opt deps mnode.id with
                              | Some (id :: _) -> id
                              | _ -> "_placeholder"
                        in
                        (* Use _ref suffix to avoid duplicate node ID *)
                        let action_node = { id = action_node_id ^ "_ref"; node_type = ChainRef action_node_id; input_mapping = []; output_key = None; depends_on = None } in
                        GoalDriven {
                          gd with
                          action_node;
                          measure_func = (match gd_meta.gd_measure_func with Some f -> f | None -> gd.measure_func);
                          strategy_hints = if gd_meta.gd_strategy_hints <> [] then gd_meta.gd_strategy_hints else gd.strategy_hints;
                          conversational = gd_meta.gd_conversational;
                          relay_models = if gd_meta.gd_relay_models <> [] then gd_meta.gd_relay_models else gd.relay_models;
                        }
                    | None ->
                        (* No metadata, use first edge as action_node *)
                        let action_node_id = match Hashtbl.find_opt deps mnode.id with
                          | Some (id :: _) -> id
                          | _ -> "_placeholder"
                        in
                        (* Use _ref suffix to avoid duplicate node ID *)
                        let action_node = { id = action_node_id ^ "_ref"; node_type = ChainRef action_node_id; input_mapping = []; output_key = None; depends_on = None } in
                        GoalDriven { gd with action_node })
                | other -> other
              in
              (* Use metadata input_mapping if available, otherwise infer from deps *)
              let input_mapping =
                match Hashtbl.find_opt meta.node_input_mappings mnode.id with
                | Some mapping -> mapping  (* Use metadata - preserves original keys! *)
                | None ->
                    (* Fall back to inferred mapping *)
                    match Hashtbl.find_opt deps mnode.id with
                    | Some inputs -> List.map (fun inp -> (inp, inp)) inputs
                    | None -> []
              in
              let node = { id = mnode.id; node_type; input_mapping;
                         output_key = None; depends_on = None } in
              Hashtbl.replace node_map mnode.id node
    ) graph.nodes;

    match !convert_result with
    | Error e -> Error e
    | Ok () ->
        let nodes_raw = Hashtbl.fold (fun _ node acc -> node :: acc) node_map [] in

        (* Post-process: Resolve node types that need edge information *)
        let nodes = List.map (fun (node : node) ->
          match node.node_type with
          | GoalDriven gd ->
              let action_node_id = gd.action_node.id in
              (match Hashtbl.find_opt node_map action_node_id with
               | Some actual_node ->
                   (* Replace ChainRef placeholder with actual node *)
                   { node with node_type = GoalDriven { gd with action_node = actual_node } }
               | None ->
                   (* Keep original if not found (will error at runtime) *)
                   node)
          | Mcts mcts ->
              (* Fill strategies from incoming edges - use ChainRef with _ref suffix *)
              let input_ids = match Hashtbl.find_opt deps node.id with
                | Some ids -> ids
                | None -> []
              in
              let strategies = List.map (fun id ->
                { id = id ^ "_ref"; node_type = ChainRef id; input_mapping = []; output_key = None; depends_on = None }
              ) input_ids in
              { node with node_type = Mcts { mcts with strategies } }
          | Gate gate ->
              (* Resolve then_node and else_node from outgoing edges with labels *)
              let out_edges = match Hashtbl.find_opt outgoing node.id with
                | Some edges -> edges
                | None -> []
              in
              (* Find edges labeled "true" and "false" *)
              let then_id = List.find_map (fun (to_node, label) ->
                match label with
                | Some l when String.lowercase_ascii l = "true" -> Some to_node
                | _ -> None
              ) out_edges in
              let else_id = List.find_map (fun (to_node, label) ->
                match label with
                | Some l when String.lowercase_ascii l = "false" -> Some to_node
                | _ -> None
              ) out_edges in
              (* If no labels, use first two edges (first=then, second=else) *)
              let (then_id, else_id) = match (then_id, else_id) with
                | (Some t, Some e) -> (Some t, Some e)
                | (None, None) ->
                    (* No labeled edges, use positional *)
                    (match out_edges with
                     | [(to1, _)] -> (Some to1, None)
                     | (to1, _) :: (to2, _) :: _ -> (Some to1, Some to2)
                     | [] -> (None, None))
                | other -> other
              in
              (* Use ChainRef instead of actual node to avoid duplicate node issues *)
              (* The executor will resolve these refs at runtime *)
              let then_node = match then_id with
                | Some id ->
                    { id = id ^ "_ref"; node_type = ChainRef id; input_mapping = []; output_key = None; depends_on = None }
                | None -> gate.then_node  (* Keep placeholder if not resolved *)
              in
              let else_node = match else_id with
                | Some id ->
                    Some { id = id ^ "_ref"; node_type = ChainRef id; input_mapping = []; output_key = None; depends_on = None }
                | None -> gate.else_node
              in
              { node with node_type = Gate { gate with then_node; else_node } }
          | _ -> node
        ) nodes_raw in

        (* Use metadata output if available, otherwise find output node *)
        let output_nodes = find_output_nodes graph in
        let output = match meta.chain_output with
          | Some out -> out  (* Use metadata *)
          | None ->
              match output_nodes with
              | [single] -> single
              | first :: _ -> first
              | [] ->
                  match List.rev graph.nodes with
                  | last :: _ -> last.id
                  | [] -> "output"
        in

        (* Use metadata chain_id if available *)
        let final_id = match meta.chain_id with
          | Some mid -> mid
          | None -> id
        in

        (* Build config with metadata values *)
        let config = {
          max_depth = (match meta.chain_max_depth with Some d -> d | None -> default_config.max_depth);
          max_concurrency = (match meta.chain_max_concurrency with Some c -> c | None -> default_config.max_concurrency);
          timeout = (match meta.chain_timeout with Some t -> t | None -> default_config.timeout);
          trace = (match meta.chain_trace with Some t -> t | None -> default_config.trace);
          direction = direction_of_string graph.direction;
        } in

        Ok { id = final_id; nodes; output; config;
             name = None; description = None; version = None;
             input_schema = None; output_schema = None; metadata = None }
  in
  match meta.chain_full_json with
  | Some json_str ->
      (try
         let json = Yojson.Safe.from_string json_str in
         Chain_parser.parse_chain json
       with Yojson.Json_error _ ->
         (match meta.chain_json with
          | Some json ->
              (match Chain_parser.parse_chain json with
               | Ok chain -> Ok chain
               | Error _ -> fallback ())
          | None -> fallback ()))
  | None ->
      (match meta.chain_json with
       | Some json ->
           (match Chain_parser.parse_chain json with
            | Ok chain -> Ok chain
            | Error _ -> fallback ())
       | None -> fallback ())

(** Parse Mermaid text into Chain with metadata (lossless roundtrip)

    This function preserves all metadata embedded in Mermaid comments:
    - %% @chain {"id":"...", "output":"...", "timeout":300, "trace":true, "max_depth":4, "max_concurrency":3}
    - %% @chain_json { ... full chain JSON ... }
    - %% @node:nodeid {"input_mapping":[["key1","val1"],["key2","val2"]]}

    Usage:
      let mermaid = chain_to_mermaid chain in
      match parse_mermaid_to_chain ~id:"fallback_id" mermaid with
      | Ok chain2 -> (* chain2 is identical to chain *)
      | Error e -> ...
*)
let extract_chain_full (text : string) : string option =
  let lines = String.split_on_char '\n' text in
  let rec find = function
    | [] -> None
    | line :: rest ->
        let line = trim line in
        if String.length line >= 2 && String.sub line 0 2 = "%%" then
          let rest_line = trim (String.sub line 2 (String.length line - 2)) in
          if String.length rest_line >= 11 && String.sub rest_line 0 11 = "@chain_full" then
            Some (trim (String.sub rest_line 11 (String.length rest_line - 11)))
          else if String.length rest_line >= 11 && String.sub rest_line 0 11 = "@chain_json" then
            Some (trim (String.sub rest_line 11 (String.length rest_line - 11)))
          else
            find rest
        else
          find rest
  in
  find lines

let parse_mermaid_to_chain ?(id = "mermaid_chain") (text : string) : (chain, string) result =
  match extract_chain_full text with
  | Some json_str ->
      (try
         let json = Yojson.Safe.from_string json_str in
         Chain_parser.parse_chain json
       with Yojson.Json_error msg ->
         Error (Printf.sprintf "chain_full JSON parse error: %s" msg))
  | None ->
      (match parse_mermaid_text_with_meta text with
      | Error e -> Error e
      | Ok (graph, meta) ->
          (match meta.chain_full_json with
          | Some json_str ->
              (try
                 let json = Yojson.Safe.from_string json_str in
                 Chain_parser.parse_chain json
               with Yojson.Json_error msg ->
                 Error (Printf.sprintf "chain_full JSON parse error: %s" msg))
          | None ->
              mermaid_to_chain_with_meta ~id graph meta))

(** Main entry point: Parse Mermaid text into Chain *)
let parse_chain (text : string) : (chain, string) result =
  parse_mermaid_to_chain text

(** Parse with custom chain ID *)
let parse_chain_with_id ~id (text : string) : (chain, string) result =
  parse_mermaid_to_chain ~id text

(* ═══════════════════════════════════════════════════════════════════
   REVERSE DIRECTION: Chain AST → Mermaid
   ═══════════════════════════════════════════════════════════════════ *)

(** Convert a node_type to Mermaid node ID suggestion *)
let node_type_to_id (nt : node_type) (fallback : string) : string =
  match nt with
  | Llm { model; _ } -> model
  | Tool { name; _ } -> name
  | Quorum { consensus; _ } -> Printf.sprintf "quorum_%s" (Chain_types.consensus_mode_to_string consensus)
  | Gate { condition; _ } ->
      let safe_cond = Str.global_replace (Str.regexp "[^a-zA-Z0-9_]") "_" condition in
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
  let s1 = Str.global_replace (Str.regexp "\n") " " text in
  let s2 = Str.global_replace (Str.regexp {|"|}) {|'|} s1 in
  if String.length s2 > max_len then
    String.sub s2 0 (max_len - 3) ^ "..."
  else
    s2

(** Convert a node_type to Mermaid node text (lossless DSL syntax) *)
let node_type_to_text (nt : node_type) : string =
  match nt with
  | Llm { model; prompt; tools; _ } ->
      let prompt_escaped = escape_for_mermaid prompt in
      let base = Printf.sprintf "LLM:%s \"%s\"" model prompt_escaped in
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
  | Llm _ | Tool _ -> ("[", "]")
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
  | Llm _ -> "llm"
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
let mermaid_class_defs = {|    classDef llm fill:#4ecdc4,stroke:#1a535c,color:#000
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
      let step1 = Str.global_replace (Str.regexp {|\\"|}) placeholder text in
      let step2 = Str.global_replace (Str.regexp {|"|}) {|'|} step1 in
      Str.global_replace (Str.regexp_string placeholder) {|\\"|} step2
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
      | Llm _ -> "🤖" | Tool _ -> "🔧" | Quorum _ -> "🗳️"
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
