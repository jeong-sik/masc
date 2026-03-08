[@@@warning "-32"]
(** Chain Parser - JSON to Chain AST conversion

    Parses JSON DSL into Chain_types structures.
    Handles:
    - Node type detection and parsing
    - Input mapping with template syntax
    - Validation (cycle detection, depth limits)
    - Config defaults and overrides

    Security Limits (P0.3):
    To prevent DoS via malicious chain definitions:
    - max_depth: 20 (prevents stack overflow in nested subgraphs)
    - max_concurrency: 10 (prevents resource exhaustion)
    - max_nodes: 100 (prevents memory exhaustion)
    - max_fanout: 20 (prevents exponential explosion in parallel branches)

    These limits can be configured via environment variables:
    - LLM_MCP_CHAIN_MAX_DEPTH (default: 20)
    - LLM_MCP_CHAIN_MAX_CONCURRENCY (default: 10)
    - LLM_MCP_CHAIN_MAX_NODES (default: 100)
    - LLM_MCP_CHAIN_MAX_FANOUT (default: 20)
*)

(* Fiber-safe random state for subgraph ID generation *)
let parser_rng = Random.State.make_self_init ()

open Chain_types

(** {1 Security Limits (P0.3)} *)

(** Maximum allowed chain depth to prevent stack overflow *)
let security_max_depth =
  match Sys.getenv_opt "LLM_MCP_CHAIN_MAX_DEPTH" with
  | Some s -> (try max 1 (int_of_string s) with _ -> 20)
  | None -> 20

(** Maximum allowed concurrency to prevent resource exhaustion *)
let security_max_concurrency =
  match Sys.getenv_opt "LLM_MCP_CHAIN_MAX_CONCURRENCY" with
  | Some s -> (try max 1 (int_of_string s) with _ -> 10)
  | None -> 10

(** Maximum total nodes in a chain to prevent memory exhaustion *)
let security_max_nodes =
  match Sys.getenv_opt "LLM_MCP_CHAIN_MAX_NODES" with
  | Some s -> (try max 1 (int_of_string s) with _ -> 100)
  | None -> 100

(** Maximum nodes in a single fanout/parallel to prevent exponential explosion *)
let security_max_fanout =
  match Sys.getenv_opt "LLM_MCP_CHAIN_MAX_FANOUT" with
  | Some s -> (try max 1 (int_of_string s) with _ -> 20)
  | None -> 20

(** Helper: Result bind operator *)
let ( let* ) = Result.bind

(** {1 Safe JSON Parsing Helpers - Explicit Error Handling} *)

(** Parse float from JSON with explicit error message *)
let require_float json field_name =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | `Null -> Error (Printf.sprintf "Missing required field '%s'" field_name)
  | other -> Error (Printf.sprintf "Field '%s' must be a number, got: %s"
                      field_name (Yojson.Safe.to_string other))

(** Parse int with default, logging when fallback is used *)
let parse_int_with_default json field_name default =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `Int i -> i
  | `Null -> default  (* explicit null = use default *)
  | other ->
      (* Log unexpected type but continue with default *)
      Printf.eprintf "[WARN] chain_parser: Field '%s' expected int, got %s, using default %d\n%!"
        field_name (Yojson.Safe.to_string other) default;
      default

(** Parse bool with default *)
let parse_bool_with_default json field_name default =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `Bool b -> b
  | `Null -> default
  | _ -> default

(** Parse string list with default empty *)
let parse_string_list_opt json field_name =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `List items -> List.filter_map (function `String s -> Some s | _ -> None) items
  | `Null -> []
  | _ -> []

(** Parse assoc list as string pairs *)
let parse_string_assoc_opt json field_name =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `Assoc pairs -> List.filter_map (fun (k, v) ->
      match v with `String s -> Some (k, s) | _ -> None) pairs
  | `Null -> []
  | _ -> []

(** Parse string with default value *)
let parse_string_with_default json field_name default =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `String s -> s
  | `Null -> default
  | _ -> default

(** Parse optional string from JSON *)
let parse_string_opt json field_name =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `String s -> Some s
  | _ -> None

(** Parse optional int from JSON *)
let parse_int_opt json field_name =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `Int i -> Some i
  | _ -> None

(** Parse list with default empty - handles various JSON types *)
let parse_list_with_default json field_name =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `List l -> l
  | `Null -> []
  | _ -> []

(** Parse optional float from JSON *)
let parse_float_opt json field_name =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None

(** Parse MCTS policy from JSON *)
let parse_mcts_policy (json : Yojson.Safe.t) : (mcts_policy, string) result =
  let open Yojson.Safe.Util in
  match json |> member "type" |> to_string_option with
  | Some "ucb1" ->
      let c = match json |> member "c" with
        | `Float f -> f | `Int i -> float_of_int i | _ -> 1.41
      in Ok (UCB1 c)
  | Some "greedy" -> Ok Greedy
  | Some "epsilon_greedy" ->
      let eps = match json |> member "epsilon" with
        | `Float f -> f | `Int i -> float_of_int i | _ -> 0.1
      in Ok (EpsilonGreedy eps)
  | Some "softmax" ->
      let temp = match json |> member "temperature" with
        | `Float f -> f | `Int i -> float_of_int i | _ -> 1.0
      in Ok (Softmax temp)
  | Some t -> Error (Printf.sprintf "Unknown MCTS policy type: %s" t)
  | None -> Ok (UCB1 1.41)  (* default policy *)

(** Parse backoff strategy from JSON with sensible defaults *)
let parse_backoff_strategy json =
  let open Yojson.Safe.Util in
  match json |> member "backoff" with
  | `Null -> Exponential 1.0  (* sensible default *)
  | `String s ->
      (match String.split_on_char ':' s with
       | ["exponential"; v] -> (match float_of_string_opt v with Some f -> Exponential f | None -> Exponential 1.0)
       | ["constant"; v] -> (match float_of_string_opt v with Some f -> Constant f | None -> Constant 1.0)
       | ["linear"; v] -> (match float_of_string_opt v with Some f -> Linear f | None -> Linear 1.0)
       | _ -> Exponential 1.0)
  | `Float f -> Exponential f
  | `Int i -> Exponential (float_of_int i)
  | `Assoc _ as obj ->
      let typ = match obj |> member "type" with `String s -> s | _ -> "exponential" in
      let get_float key default = match obj |> member key with
        | `Float f -> f | `Int i -> float_of_int i | _ -> default
      in
      (match typ with
       | "constant" -> Constant (get_float "seconds" 1.0)
       | "exponential" -> Exponential (get_float "base" 2.0)
       | "linear" -> Linear (get_float "base" 1.0)
       | "jitter" -> Jitter (get_float "min" 0.5, get_float "max" 2.0)
       | _ -> Exponential 2.0)
  | _ -> Exponential 1.0

(** Parse merge strategy from string *)
let parse_merge_strategy = function
  | "first" -> Ok First
  | "last" -> Ok Last
  | "concat" -> Ok Concat
  | "weighted_average" | "weighted_avg" -> Ok WeightedAvg
  | s when String.length s > 7 && String.sub s 0 7 = "custom:" ->
      Ok (Custom (String.sub s 7 (String.length s - 7)))
  | s -> Error (Printf.sprintf "Unknown merge strategy: %s" s)

(** Parse threshold comparison operator from string *)
let parse_threshold_op = function
  | "gt" | ">" -> Ok Gt
  | "gte" | ">=" -> Ok Gte
  | "lt" | "<" -> Ok Lt
  | "lte" | "<=" -> Ok Lte
  | "eq" | "=" | "==" -> Ok Eq
  | "neq" | "!=" | "<>" -> Ok Neq
  | s -> Error (Printf.sprintf "Unknown threshold operator: %s" s)

(** Parse selection strategy from string/JSON *)
let parse_select_strategy json =
  match json with
  | `String s ->
      (match String.lowercase_ascii s with
       | "best" -> Ok Best
       | "worst" -> Ok Worst
       | "weighted_random" | "weightedrandom" -> Ok WeightedRandom
       | s when String.length s > 16 && String.sub s 0 16 = "above_threshold:" ->
           (try
             let threshold = float_of_string (String.sub s 16 (String.length s - 16)) in
             Ok (AboveThreshold threshold)
           with Failure _ -> Error (Printf.sprintf "Invalid threshold value in: %s" s))
       | "abovethreshold" -> Ok (AboveThreshold 0.5) (* default threshold *)
       | _ -> Error (Printf.sprintf "Unknown select strategy: %s" s))
  | `Assoc [("above_threshold", `Float f)] -> Ok (AboveThreshold f)
  | `Assoc [("above_threshold", `Int i)] -> Ok (AboveThreshold (float_of_int i))
  | `Assoc [("AboveThreshold", `Float f)] -> Ok (AboveThreshold f)
  | `Assoc [("AboveThreshold", `Int i)] -> Ok (AboveThreshold (float_of_int i))
  | other -> Error (Printf.sprintf "Unknown select strategy: %s" (Yojson.Safe.to_string other))

(** Extract input mappings from prompt template *)
let extract_input_mappings (prompt : string) : (string * string) list =
  let regex = Str.regexp "{{\\([^}]+\\)}}" in
  let rec find_all pos acc =
    try
      let _ = Str.search_forward regex prompt pos in
      let matched = Str.matched_group 1 prompt in
      let next_pos = Str.match_end () in
      find_all next_pos (matched :: acc)
    with Not_found -> List.rev acc
  in
  find_all 0 []
  |> List.map (fun ref ->
      (* Split "node.output" or just use as-is *)
      match String.split_on_char '.' ref with
      | node_id :: _ -> (ref, node_id)
      | [] -> (ref, ref))

(** Extract input mappings from JSON arguments *)
let rec extract_json_mappings (json : Yojson.Safe.t) : (string * string) list =
  match json with
  | `String s -> extract_input_mappings s
  | `Assoc fields ->
      List.concat (List.map (fun (_k, v) -> extract_json_mappings v) fields)
  | `List items ->
      List.concat (List.map extract_json_mappings items)
  | _ -> []

(** Parse chain config from JSON *)
(** Parse chain config from JSON with security limits (P0.3) *)
let parse_config (json : Yojson.Safe.t) : chain_config =
  let open Yojson.Safe.Util in
  let get_int_opt key default =
    try json |> member key |> to_int
    with Type_error _ -> default
  in
  let get_bool_opt key default =
    try json |> member key |> to_bool
    with Type_error _ -> default
  in
  let get_direction_opt key default =
    match json |> member key with
    | `String s -> direction_of_string s
    | _ -> default
  in
  (* P0.3: Enforce security limits on parsed values *)
  let raw_depth = get_int_opt "max_depth" default_config.max_depth in
  let raw_concurrency = get_int_opt "max_concurrency" default_config.max_concurrency in
  {
    max_depth = min raw_depth security_max_depth;
    max_concurrency = min raw_concurrency security_max_concurrency;
    timeout = get_int_opt "timeout" default_config.timeout;
    trace = get_bool_opt "trace" default_config.trace;
    direction = get_direction_opt "direction" default_config.direction;
  }

(** Helper: Get required string field with better error messages *)
let require_string json field_name =
  let open Yojson.Safe.Util in
  match json |> member field_name with
  | `Null -> Error (Printf.sprintf "Missing required field '%s'" field_name)
  | `String s -> Ok s
  | other -> Error (Printf.sprintf "Field '%s' must be a string, got: %s"
                      field_name (Yojson.Safe.to_string other))

(** Parse adapter transform from JSON *)
let rec parse_adapter_transform (json : Yojson.Safe.t) : (adapter_transform, string) result =
  let open Yojson.Safe.Util in
  match json with
  | `String s ->
      (* Simple string format: "extract:data.field" or "truncate:100" *)
      (match String.split_on_char ':' s with
       | ["extract"; path] -> Ok (Extract path)
       | ["template"; tpl] -> Ok (Template tpl)
       | ["summarize"; n] -> (try Ok (Summarize (int_of_string n)) with _ -> Error "Invalid summarize value")
       | ["truncate"; n] -> (try Ok (Truncate (int_of_string n)) with _ -> Error "Invalid truncate value")
       | ["jsonpath"; path] -> Ok (JsonPath path)
       | ["parse_json"] | ["parse"] -> Ok ParseJson
       | ["stringify"] -> Ok Stringify
       | ["custom"; name] -> Ok (Custom name)
       | [simple] ->
           (* Handle simple keywords *)
           (match simple with
            | "parse_json" | "parse" -> Ok ParseJson
            | "stringify" -> Ok Stringify
            | _ -> Error (Printf.sprintf "Unknown simple transform: %s" simple))
       | _ -> Error (Printf.sprintf "Invalid transform string format: %s" s))
  | `Assoc _ ->
      (* Object format with "type" field *)
      let typ = parse_string_with_default json "type" "unknown" in
      (match typ with
       | "extract" ->
           let path = parse_string_with_default json "path" "." in
           Ok (Extract path)
       | "template" ->
           let tpl = parse_string_with_default json "template" "{{value}}" in
           Ok (Template tpl)
       | "summarize" ->
           let max_tokens = parse_int_with_default json "max_tokens" 500 in
           Ok (Summarize max_tokens)
       | "truncate" ->
           let max_chars = parse_int_with_default json "max_chars" 1000 in
           Ok (Truncate max_chars)
       | "jsonpath" ->
           let path = parse_string_with_default json "path" "$" in
           Ok (JsonPath path)
       | "regex" ->
           let pattern = parse_string_with_default json "pattern" ".*" in
           let replacement = parse_string_with_default json "replacement" "" in
           Ok (Regex (pattern, replacement))
       | "validate_schema" ->
           let schema = parse_string_with_default json "schema" "" in
           Ok (ValidateSchema schema)
       | "parse_json" | "parse" -> Ok ParseJson
       | "stringify" -> Ok Stringify
       | "chain" ->
           let transforms_json = parse_list_with_default json "transforms" in
           let* transforms = parse_adapter_transforms transforms_json in
           Ok (Chain transforms)
       | "conditional" ->
           let* condition =
             match parse_string_opt json "condition" with
             | Some s -> Ok s
             | None -> Error "Missing 'condition' in conditional transform"
           in
           let* on_true = parse_adapter_transform (json |> member "on_true") in
           let* on_false = parse_adapter_transform (json |> member "on_false") in
           Ok (Conditional { condition; on_true; on_false })
       | "custom" ->
           let name = parse_string_with_default json "name" "identity" in
           Ok (Custom name)
       | "unknown" ->
           (* No type field: treat the whole object as a template JSON *)
           (* Convert the object to a JSON template string *)
           let tpl = Yojson.Safe.to_string json in
           Ok (Template tpl)
       | unknown -> Error (Printf.sprintf "Unknown transform type: %s" unknown))
  | _ -> Error "Transform must be a string or object"

(** Parse list of adapter transforms *)
and parse_adapter_transforms (json_list : Yojson.Safe.t list) : (adapter_transform list, string) result =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | json :: rest ->
        match parse_adapter_transform json with
        | Ok t -> aux (t :: acc) rest
        | Error e -> Error e
  in
  aux [] json_list

(** Parse a single node from JSON *)
let rec parse_node (json : Yojson.Safe.t) : (node, string) result =
  let open Yojson.Safe.Util in
  try
    let* id = require_string json "id" in
    let* node_type_str = require_string json "type" in

    let* node_type = parse_node_type json node_type_str in

    (* Parse explicit input_mapping if provided, otherwise extract from prompt/args *)
    (* Helper for auto-extracting input mappings from node content *)
    let auto_extract_mappings () =
      match node_type with
      | Llm { prompt; _ } -> extract_input_mappings prompt
      | Tool { args; _ } -> extract_json_mappings args
      | _ -> []
    in
    (* Parse input_mapping: try "input_mapping" (list format) then "inputs" (assoc format) *)
    let input_mapping =
      match json |> member "input_mapping" with
      | `List pairs ->
          (* Legacy format: [["key", "source"], ...] *)
          List.filter_map (fun pair ->
            match pair with
            | `List [`String k; `String v] -> Some (k, v)
            | _ -> None
          ) pairs
      | `Null | `Bool false ->
          (* Try "inputs" format: {"key": "source", ...} - used by chain_to_json output *)
          (match json |> member "inputs" with
           | `Assoc pairs -> List.map (fun (k, v) ->
               match v with
               | `String s -> (k, s)
               | _ -> (k, Yojson.Safe.to_string v)
             ) pairs
           | `Null -> auto_extract_mappings ()
           | _ -> auto_extract_mappings ())
      | _ -> []
    in

    (* Parse "output_key" field (optional) *)
    let output_key = match json |> member "output_key" with
      | `String s -> Some s
      | _ -> None
    in

    (* Parse "depends_on" field as both string list and edges (common in real chain files) *)
    let depends_on_list, depends_on_mapping =
      match json |> member "depends_on" with
      | `List deps ->
          let parsed = List.filter_map (fun d ->
            match d with
            | `String dep_id -> Some dep_id
            | _ -> None
          ) deps in
          let mapping = List.map (fun dep_id -> ("_dep_" ^ dep_id, dep_id)) parsed in
          (Some parsed, mapping)
      | _ -> (None, [])
    in

    (* Ensure Adapter input_ref contributes to dependency ordering *)
    let input_mapping =
      match node_type with
      | Adapter { input_ref; _ } ->
          if List.exists (fun (k, _) -> k = input_ref) input_mapping then input_mapping
          else input_mapping @ [(input_ref, input_ref)]
      | _ -> input_mapping
    in

    (* Combine input_mapping with depends_on.
       Note: _dep_ prefix ensures no key collision with template-inferred mappings.
       E.g., template {{foo}} creates ("foo", "foo") while depends_on creates ("_dep_foo", "foo").
       Both coexist intentionally - _dep_ marks explicit dependencies for roundtrip preservation. *)
    let final_input_mapping = input_mapping @ depends_on_mapping in

    Ok { id; node_type; input_mapping = final_input_mapping;
         output_key; depends_on = depends_on_list }
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
      Error (Printf.sprintf "JSON type error: %s" msg)
  | exn ->
      Error (Printf.sprintf "Parse error: %s" (Printexc.to_string exn))

(** Parse node type based on type string *)
and parse_node_type (json : Yojson.Safe.t) (type_str : string) : (node_type, string) result =
  let open Yojson.Safe.Util in
  match type_str with
  | "llm" ->
      (* Support both flat and nested format:
         Flat:   {"type":"llm","model":"gemini","prompt":"..."}
         Nested: {"type":"llm","llm":{"model":"gemini","prompt":"..."}}
      *)
      let llm_json = match json |> member "llm" with
        | `Assoc _ as llm_obj -> llm_obj
        | _ -> json
      in
      let* model = require_string llm_json "model" in
      let system = parse_string_opt llm_json "system" in
      let timeout = parse_int_opt llm_json "timeout" in
      let tools =
        match llm_json |> member "tools" with
        | `Null -> None
        | v -> Some v
      in
      (* Prompt Registry support: prompt_ref takes precedence *)
      let prompt_ref = parse_string_opt llm_json "prompt_ref" in
      let prompt_vars =
        match llm_json |> member "prompt_vars" with
        | `Assoc pairs ->
            List.filter_map (fun (k, v) ->
              match v with `String s -> Some (k, s) | _ -> None) pairs
        | _ -> []
      in
      (* Phase 6: Parse thinking field for GLM reasoning mode *)
      let thinking = parse_bool_with_default llm_json "thinking" false in
      (* If prompt_ref is set, load from registry; otherwise require prompt field *)
      let* prompt =
        match prompt_ref with
        | Some ref ->
            (* Parse ref format: "id" or "id@version" *)
            let (id, version) = match String.split_on_char '@' ref with
              | [id; ver] -> (id, Some ver)
              | [id] -> (id, None)
              | _ -> (ref, None)
            in
            (match Prompt_registry.get ~id ?version () with
             | Some entry ->
                 (* Apply prompt_vars to the template *)
                 (match Prompt_registry.render_template ~template:entry.template ~vars:prompt_vars () with
                  | Ok rendered -> Ok rendered
                  | Error e -> Error (Printf.sprintf "Failed to render prompt_ref '%s': %s" ref e))
             | None ->
                 (* If prompt_ref not found, fall back to prompt field if present *)
                 match parse_string_opt llm_json "prompt" with
                 | Some p -> Ok p
                 | None -> Error (Printf.sprintf "Prompt '%s' not found in registry and no fallback prompt" ref))
        | None ->
            require_string llm_json "prompt"
      in
      Ok (Llm { model; system; prompt; timeout; tools; prompt_ref; prompt_vars; thinking })

  | "tool" ->
      (* Support both flat and nested format:
         Flat:   {"type":"tool","name":"eslint","args":{...}}
         Nested: {"type":"tool","tool":{"server":"figma","name":"parse_url","args":{...}}}
      *)
      (match json |> member "tool" with
       | `Assoc _ as tool_obj ->
           (* Nested format: extract from "tool" object *)
           let server_opt = tool_obj |> member "server" |> to_string_option in
           let* name = require_string tool_obj "name" in
           let args = match tool_obj |> member "args" with
             | `Null -> `Assoc []
             | v -> v
           in
           (* Encode server in name if present: "figma:parse_url" *)
           let full_name = match server_opt with
             | Some s -> Printf.sprintf "%s:%s" s name
             | None -> name
           in
           Ok (Tool { name = full_name; args })
       | _ ->
           (* Flat format: direct fields *)
           let* name = require_string json "name" in
           let args = match json |> member "args" with
             | `Null -> `Assoc []
             | v -> v
           in
           Ok (Tool { name; args }))

  | "pipeline" ->
      let nodes_json = json |> member "nodes" |> to_list in
      let* nodes = parse_nodes nodes_json in
      Ok (Pipeline nodes)

  | "fanout" ->
      (* Try "branches" first, fallback to "nodes" *)
      let branches_json =
        match json |> member "branches" with
        | `List l -> l
        | _ -> parse_list_with_default json "nodes"
      in
      let* nodes = parse_nodes branches_json in
      Ok (Fanout nodes)

  | "quorum" ->
      (* P1.3: Support consensus modes - "consensus" field or fallback to "required" *)
      let consensus =
        match json |> member "consensus" with
        | `String s -> Chain_types.consensus_mode_of_string s
        | `Null ->
            (* Backward compat: use "required" as Count *)
            let required = json |> member "required" |> to_int in
            Chain_types.Count required
        | _ ->
            let required = json |> member "required" |> to_int in
            Chain_types.Count required
      in
      let weights =
        match json |> member "weights" with
        | `Assoc pairs ->
            List.filter_map (fun (k, v) ->
              match v with
              | `Float f -> Some (k, f)
              | `Int i -> Some (k, float_of_int i)
              | _ -> None
            ) pairs
        | _ -> []
      in
      (* Try "nodes" first, fallback to "inputs" *)
      let nodes_json =
        match json |> member "nodes" with
        | `List l -> l
        | _ -> parse_list_with_default json "inputs"
      in
      let* nodes = parse_nodes nodes_json in
      Ok (Quorum { consensus; nodes; weights })

  | "gate" ->
      let* condition = require_string json "condition" in
      (* Support both embedded node object (then/else) and string ID reference (then_node/else_node) *)
      let* then_node =
        match json |> member "then" with
        | `Null ->
            (* Try then_node as string ID *)
            (match json |> member "then_node" with
             | `String id -> Ok { id = "_ref_" ^ id; node_type = ChainRef id; input_mapping = []; output_key = None; depends_on = None }
             | _ -> Error "Gate requires 'then' (node object) or 'then_node' (string ID)")
        | then_json -> parse_node then_json
      in
      let else_node =
        match json |> member "else" with
        | `Null ->
            (* Try else_node as string ID *)
            (match json |> member "else_node" with
             | `String id -> Some { id = "_ref_" ^ id; node_type = ChainRef id; input_mapping = []; output_key = None; depends_on = None }
             | _ -> None)
        | else_json ->
            (match parse_node else_json with
             | Ok n -> Some n
             | Error _ -> None)
      in
      Ok (Gate { condition; then_node; else_node })

  | "subgraph" ->
      let graph_json = json |> member "graph" in
      let* chain = parse_chain_inner graph_json in
      Ok (Subgraph chain)

  | "chain_ref" ->
      let* ref_id = require_string json "ref" in
      Ok (ChainRef ref_id)

  | "map" ->
      let* func = require_string json "func" in
      let inner_json = json |> member "inner" in
      let* inner = parse_node inner_json in
      Ok (Map { func; inner })

  | "bind" ->
      let* func = require_string json "func" in
      let inner_json = json |> member "inner" in
      let* inner = parse_node inner_json in
      Ok (Bind { func; inner })

  | "merge" ->
      let strategy_str = parse_string_with_default json "strategy" "concat" in
      let* strategy = parse_merge_strategy strategy_str in
      (* Try "nodes" first, fallback to "inputs" *)
      let nodes_json =
        match json |> member "nodes" with
        | `List l -> l
        | _ -> parse_list_with_default json "inputs"
      in
      let* nodes = parse_nodes nodes_json in
      Ok (Merge { strategy; nodes })

  | "threshold" ->
      let* metric = require_string json "metric" in
      let* operator_str = require_string json "operator" in
      let* operator = parse_threshold_op operator_str in
      let* value = require_float json "value" in  (* Now explicit error on missing/invalid *)
      let input_json = json |> member "input_node" in
      let* input_node = parse_node input_json in
      let on_pass =
        match json |> member "on_pass" with
        | `Null -> None
        | pass_json -> (match parse_node pass_json with Ok n -> Some n | Error _ -> None)
      in
      let on_fail =
        match json |> member "on_fail" with
        | `Null -> None
        | fail_json -> (match parse_node fail_json with Ok n -> Some n | Error _ -> None)
      in
      Ok (Threshold { metric; operator; value; input_node; on_pass; on_fail })

  | "goal_driven" ->
      let* goal_metric = require_string json "goal_metric" in
      let* goal_operator_str = require_string json "goal_operator" in
      let* goal_operator = parse_threshold_op goal_operator_str in
      let* goal_value = require_float json "goal_value" in  (* Explicit error on missing *)
      let action_json = json |> member "action_node" in
      let* action_node = parse_node action_json in
      let* measure_func = require_string json "measure_func" in
      let max_iterations = parse_int_with_default json "max_iterations" 10 in
      let strategy_hints = parse_string_assoc_opt json "strategy_hints" in
      let conversational = parse_bool_with_default json "conversational" false in
      let relay_models = parse_string_list_opt json "relay_models" in
      Ok (GoalDriven {
        goal_metric; goal_operator; goal_value;
        action_node; measure_func; max_iterations; strategy_hints;
        conversational; relay_models
      })

  | "evaluator" ->
      (* Support both top-level fields AND nested evaluator_config for consistency with feedback_loop *)
      let config = match json |> member "evaluator_config" with
        | `Null -> json  (* fallback to top-level fields *)
        | cfg -> cfg
      in
      (* Candidates can be either:
         - String array: ["node_id1", "node_id2"] -> ChainRef nodes
         - Node object array: [{...}, {...}] -> parse as nodes *)
      let candidates_json = match config |> member "candidates" with
        | `List l -> l | `Null -> [] | _ -> []
      in
      let* candidates =
        let is_string_list = List.for_all (function `String _ -> true | _ -> false) candidates_json in
        if is_string_list then
          (* Convert string IDs to ChainRef nodes *)
          Ok (List.filter_map (function
            | `String id -> Some { id = id ^ "_ref"; node_type = ChainRef id;
                                   input_mapping = []; output_key = None; depends_on = None }
            | _ -> None
          ) candidates_json)
        else
          parse_nodes candidates_json
      in
      let* scoring_func = require_string config "scoring_func" in
      let scoring_prompt = match config |> member "scoring_prompt" with
        | `String s -> Some s | _ -> None
      in
      let select_strategy_json = match config |> member "select_strategy" with
        | `Null -> `String "best" | v -> v
      in
      let* select_strategy = parse_select_strategy select_strategy_json in
      let min_score = match config |> member "min_score" with
        | `Float f -> Some f
        | `Int i -> Some (float_of_int i)
        | `String "threshold" -> (* support min_threshold alias *)
            (match config |> member "min_threshold" with
             | `Float f -> Some f
             | `Int i -> Some (float_of_int i)
             | _ -> None)
        | _ ->
            (* Also check min_threshold as alias *)
            (match config |> member "min_threshold" with
             | `Float f -> Some f
             | `Int i -> Some (float_of_int i)
             | _ -> None)
      in
      Ok (Evaluator { candidates; scoring_func; scoring_prompt; select_strategy; min_score })

  (* Resilience Nodes *)
  | "retry" ->
      let* input_node = parse_node (json |> member "node") in
      let max_attempts = parse_int_with_default json "max_attempts" 3 in
      let backoff = parse_backoff_strategy json in
      let retry_on = parse_string_list_opt json "retry_on" in
      Ok (Retry { node = input_node; max_attempts; backoff; retry_on })

  | "fallback" ->
      let* primary = parse_node (json |> member "primary") in
      let fallbacks_json = match json |> member "fallbacks" with
        | `List l -> l | _ -> []
      in
      let* fallbacks = parse_nodes fallbacks_json in
      Ok (Fallback { primary; fallbacks })

  | "race" ->
      let nodes_json = match json |> member "nodes" with
        | `List l -> l | _ -> []
      in
      let* nodes = parse_nodes nodes_json in
      let timeout = match json |> member "timeout" with
        | `Float f -> Some f
        | `Int i -> Some (float_of_int i)
        | _ -> None
      in
      Ok (Race { nodes; timeout })

  | "chain_exec" | "chainexec" | "meta" ->
      (* Meta-chain: execute a dynamically generated chain *)
      let chain_source = match json |> member "chain_source" with
        | `String s -> s
        | `Null -> (match json |> member "source" with `String s -> s | _ -> "{{input}}")
        | _ -> "{{input}}"
      in
      let validate = parse_bool_with_default json "validate" true in
      let max_depth = parse_int_with_default json "max_depth" 3 in
      let sandbox = parse_bool_with_default json "sandbox" true in
      let context_inject = parse_string_assoc_opt json "context_inject" in
      let pass_outputs = parse_bool_with_default json "pass_outputs" true in
      Ok (ChainExec { chain_source; validate; max_depth; sandbox; context_inject; pass_outputs })

  (* Data Transformation Node *)
  | "adapter" ->
      (* input_ref is optional, defaults to "input" *)
      let input_ref = parse_string_with_default json "input_ref" "input" in
      let* transform = parse_adapter_transform (json |> member "transform") in
      let on_error =
        match json |> member "on_error" with
        | `String "fail" -> `Fail
        | `String "passthrough" -> `Passthrough
        | `String s when String.length s > 8 && String.sub s 0 8 = "default:" ->
            `Default (String.sub s 8 (String.length s - 8))
        | `Assoc [("default", `String s)] -> `Default s
        | _ -> `Fail
      in
      Ok (Adapter { input_ref; transform; on_error })

  (* Performance Optimization Nodes *)
  | "cache" ->
      let key_expr = parse_string_with_default json "key_expr" "{{input}}" in
      let ttl_seconds = parse_int_with_default json "ttl_seconds" 0 in
      let* inner = parse_node (json |> member "inner") in
      Ok (Cache { key_expr; ttl_seconds; inner })

  | "batch" ->
      let batch_size = parse_int_with_default json "batch_size" 10 in
      let parallel = parse_bool_with_default json "parallel" false in
      let* inner = parse_node (json |> member "inner") in
      let collect_strategy = match parse_string_opt json "collect_strategy" with
        | Some "concat" -> `Concat
        | Some "first" -> `First
        | Some "last" -> `Last
        | _ -> `List
      in
      Ok (Batch { batch_size; parallel; inner; collect_strategy })

  | "spawn" ->
      (* Clean Context Spawn - execute inner with isolated context *)
      let clean = parse_bool_with_default json "clean" true in  (* default: clean *)
      let* inner = parse_node (json |> member "inner") in
      let pass_vars = match json |> member "pass_vars" with
        | `List items -> List.filter_map (function `String s -> Some s | _ -> None) items
        | _ -> []
      in
      let inherit_cache = parse_bool_with_default json "inherit_cache" true in
      Ok (Spawn { clean; inner; pass_vars; inherit_cache })

  | "mcts" ->
      (* MCTS - Monte Carlo Tree Search for multi-strategy exploration *)
      let strategies_json = parse_list_with_default json "strategies" in
      let* strategies = parse_nodes strategies_json in
      let* simulation = parse_node (json |> member "simulation") in
      let evaluator = parse_string_with_default json "evaluator" "llm_judge" in
      let evaluator_prompt = parse_string_opt json "evaluator_prompt" in
      let* policy = parse_mcts_policy (json |> member "policy") in
      let max_iterations = parse_int_with_default json "max_iterations" 10 in
      let max_depth = parse_int_with_default json "max_depth" 5 in
      let expansion_threshold = parse_int_with_default json "expansion_threshold" 3 in
      let early_stop = parse_float_opt json "early_stop" in
      let parallel_sims = parse_int_with_default json "parallel_sims" 1 in
      Ok (Mcts {
        strategies; simulation; evaluator; evaluator_prompt; policy;
        max_iterations; max_depth; expansion_threshold; early_stop; parallel_sims
      })

  | "stream_merge" ->
      (* StreamMerge - progressive result processing from parallel nodes *)
      let nodes_json = parse_list_with_default json "nodes" in
      let* nodes = parse_nodes nodes_json in
      let reducer = match json |> member "reducer" with
        | `String "first" -> First
        | `String "last" -> Last
        | `String "concat" -> Concat
        | `String "weighted_avg" -> WeightedAvg
        | `Assoc pairs -> (
            match List.assoc_opt "name" pairs with
            | Some (`String name) -> Custom name
            | _ -> Concat  (* default *)
          )
        | `String s -> Custom s  (* treat unknown as custom *)
        | _ -> Concat
      in
      let initial = parse_string_with_default json "initial" "" in
      let min_results = parse_int_opt json "min_results" in
      let timeout = parse_float_opt json "timeout" in
      Ok (StreamMerge { nodes; reducer; initial; min_results; timeout })

  | "feedback_loop" ->
      (* FeedbackLoop - iterative quality improvement with evaluator feedback *)
      let generator_json = json |> member "generator" in
      let* generator = parse_node generator_json in
      (* Parse evaluator_config *)
      let evaluator_config_json = json |> member "evaluator_config" in
      let scoring_func = parse_string_with_default evaluator_config_json "scoring_func" "llm_judge" in
      let scoring_prompt = parse_string_opt evaluator_config_json "scoring_prompt" in
      let select_strategy = match evaluator_config_json |> member "select_strategy" with
        | `String "best" -> Best
        | `String "worst" -> Worst
        | `String "weighted_random" -> WeightedRandom
        | `List [`String "above_threshold"; `Float t] -> AboveThreshold t
        | `List [`String "above_threshold"; `Int t] -> AboveThreshold (float_of_int t)
        | _ -> Best  (* default *)
      in
      let evaluator_config = { scoring_func; scoring_prompt; select_strategy } in
      let improver_prompt = parse_string_with_default json "improver_prompt"
        "Improve the output based on this feedback: {{feedback}}\n\nPrevious output: {{previous_output}}" in
      let max_iterations = parse_int_with_default json "max_iterations" 3 in
      (* score_threshold + score_operator (backward compatible: default gte) *)
      let score_threshold = Option.value (parse_float_opt json "score_threshold")
        ~default:(Option.value (parse_float_opt json "min_score") ~default:0.7) in
      let score_operator_str = parse_string_with_default json "score_operator" "gte" in
      let* score_operator = parse_threshold_op score_operator_str in
      let conversational = parse_bool_with_default json "conversational" false in
      let relay_models = parse_string_list_opt json "relay_models" in
      Ok (FeedbackLoop {
        generator; evaluator_config; improver_prompt;
        max_iterations; score_threshold; score_operator;
        conversational; relay_models
      })

  (* MASC Coordination Nodes *)
  | "masc_broadcast" ->
      let* message = require_string json "message" in
      let room = parse_string_opt json "room" in
      let mention = parse_string_list_opt json "mention" in
      Ok (Masc_broadcast { message; room; mention })

  | "masc_listen" ->
      let filter = parse_string_opt json "filter" in
      let timeout_sec = Option.value (parse_float_opt json "timeout_sec") ~default:30.0 in
      let room = parse_string_opt json "room" in
      Ok (Masc_listen { filter; timeout_sec; room })

  | "masc_claim" ->
      let task_id = parse_string_opt json "task_id" in
      let room = parse_string_opt json "room" in
      Ok (Masc_claim { task_id; room })

  | "cascade" ->
      let open Yojson.Safe.Util in
      let default_threshold = match parse_float_opt json "default_threshold" with Some v -> v | None -> 0.7 in
      let tiers_json = json |> member "tiers" |> to_list in
      let* tiers =
        let parse_tier (j : Yojson.Safe.t) (idx : int) : (Chain_types.cascade_tier, string) result =
          (* Backward-compatible with Chain_parser.chain_to_json output (derived yojson). *)
          match Chain_types.cascade_tier_of_yojson j with
          | Ok t -> Ok t
          | Error _ ->
              (* Chain file format: tier_node is a regular node object with "type" (not "node_type"). *)
              let* tier_node =
                match j |> member "tier_node" with
                | `Null -> Error "Missing required field 'tier_node'"
                | tn ->
                    (match tn |> member "type" with
                     | `String _ -> parse_node tn
                     | _ ->
                         (match Chain_types.node_of_yojson tn with
                          | Ok n -> Ok n
                          | Error e -> Error (Printf.sprintf "Invalid tier_node: %s" e)))
              in
              let tier_index = parse_int_with_default j "tier_index" idx in
              let confidence_threshold =
                match parse_float_opt j "confidence_threshold" with
                | Some f -> f
                | None -> default_threshold
              in
              let cost_weight =
                match parse_float_opt j "cost_weight" with
                | Some f -> f
                | None -> 0.0
              in
              let pass_context = parse_bool_with_default j "pass_context" true in
              Ok { Chain_types.tier_node; tier_index; confidence_threshold; cost_weight; pass_context }
        in
        let rec aux acc idx = function
          | [] -> Ok (List.rev acc)
          | j :: rest ->
              (match parse_tier j idx with
               | Ok t -> aux (t :: acc) (idx + 1) rest
               | Error e -> Error (Printf.sprintf "Invalid cascade tier: %s" e))
        in
        aux [] 0 tiers_json
      in
      let confidence_prompt = parse_string_opt json "confidence_prompt" in
      let max_escalations = parse_int_with_default json "max_escalations" 2 in
      let context_mode =
        match parse_string_opt json "context_mode" with
        | Some s -> Chain_types.context_mode_of_string s
        | None -> Chain_types.CM_Summary
      in
      let task_hint = parse_string_opt json "task_hint" in
      Ok (Cascade { tiers; confidence_prompt; max_escalations; context_mode; task_hint; default_threshold })

  | unknown ->
      Error (Printf.sprintf "Unknown node type: %s" unknown)

(** Parse a list of nodes *)
and parse_nodes (json_list : Yojson.Safe.t list) : (node list, string) result =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | json :: rest ->
        match parse_node json with
        | Ok node -> aux (node :: acc) rest
        | Error e -> Error e
  in
  aux [] json_list

(** Parse inner chain (for subgraph) *)
and parse_chain_inner (json : Yojson.Safe.t) : (chain, string) result =
  let open Yojson.Safe.Util in
  try
    let id =
      parse_string_with_default json "id"
        (Printf.sprintf "subgraph_%d" (Random.State.int parser_rng 10000))
    in
    let nodes_json = json |> member "nodes" |> to_list in
    let* nodes = parse_nodes nodes_json in
    let* output = require_string json "output" in
    let config =
      match json |> member "config" with
      | `Null -> default_config
      | cfg -> parse_config cfg
    in
    (* Extract optional preset metadata fields *)
    let name = match json |> member "name" with
      | `String s -> Some s | _ -> None in
    let description = match json |> member "description" with
      | `String s -> Some s | _ -> None in
    let version = match json |> member "version" with
      | `String s -> Some s | _ -> None in
    let input_schema = match json |> member "input_schema" with
      | `Null -> None | v -> Some v in
    let output_schema = match json |> member "output_schema" with
      | `Null -> None | v -> Some v in
    let metadata = match json |> member "metadata" with
      | `Null -> None | v -> Some v in
    Ok { id; nodes; output; config; name; description; version;
         input_schema; output_schema; metadata }
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
      Error (Printf.sprintf "Chain JSON type error: %s" msg)
  | exn ->
      Error (Printf.sprintf "Chain parse error: %s" (Printexc.to_string exn))

(** Main entry point: Parse complete chain from JSON *)
let parse_chain (json : Yojson.Safe.t) : (chain, string) result =
  parse_chain_inner json

(** Check if a node_type contains unresolved placeholder references *)
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
  let re = Str.regexp "{{\\([^}]+\\)}}" in
  let rec loop pos acc =
    try
      let _ = Str.search_forward re s pos in
      let var = Str.matched_group 1 s |> String.trim in
      let next = Str.match_end () in
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
  | Chain_types.Llm _
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
     | Chain_types.Llm { prompt; system; _ } ->
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
    | Chain_types.Llm { model; prompt; _ } ->
        if is_blank model then addf "%s: llm.model is empty" path;
        if is_blank prompt then addf "%s: llm.prompt is empty" path
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
let merge_strategy_to_string = function
  | First -> "first"
  | Last -> "last"
  | Concat -> "concat"
  | WeightedAvg -> "weighted_average"
  | Custom s -> "custom:" ^ s

(** Serialize threshold operator to string *)
let threshold_op_to_string = function
  | Gt -> "gt" | Gte -> "gte" | Lt -> "lt" | Lte -> "lte" | Eq -> "eq" | Neq -> "neq"

(** Serialize select strategy to JSON *)
let select_strategy_to_json = function
  | Best -> `String "best"
  | Worst -> `String "worst"
  | WeightedRandom -> `String "weighted_random"
  | AboveThreshold f -> `Assoc [("above_threshold", `Float f)]

(** Serialize backoff strategy to JSON *)
let backoff_to_json = function
  | Constant s -> `Assoc [("type", `String "constant"); ("seconds", `Float s)]
  | Exponential b -> `Assoc [("type", `String "exponential"); ("base", `Float b)]
  | Linear b -> `Assoc [("type", `String "linear"); ("base", `Float b)]
  | Jitter (min_s, max_s) -> `Assoc [("type", `String "jitter"); ("min", `Float min_s); ("max", `Float max_s)]

(** Serialize adapter transform to JSON *)
let rec adapter_transform_to_json = function
  | Extract path -> `Assoc [("type", `String "extract"); ("path", `String path)]
  | Template tpl -> `Assoc [("type", `String "template"); ("template", `String tpl)]
  | Summarize tokens -> `Assoc [("type", `String "summarize"); ("max_tokens", `Int tokens)]
  | Truncate chars -> `Assoc [("type", `String "truncate"); ("max_chars", `Int chars)]
  | JsonPath path -> `Assoc [("type", `String "jsonpath"); ("path", `String path)]
  | Regex (pattern, replacement) ->
      `Assoc [("type", `String "regex"); ("pattern", `String pattern); ("replacement", `String replacement)]
  | ValidateSchema schema -> `Assoc [("type", `String "validate_schema"); ("schema", `String schema)]
  | ParseJson -> `String "parse_json"
  | Stringify -> `String "stringify"
  | Chain transforms ->
      `Assoc [("type", `String "chain"); ("transforms", `List (List.map adapter_transform_to_json transforms))]
  | Conditional { condition; on_true; on_false } ->
      `Assoc [
        ("type", `String "conditional");
        ("condition", `String condition);
        ("on_true", adapter_transform_to_json on_true);
        ("on_false", adapter_transform_to_json on_false);
      ]
  | Split { delimiter; chunk_size; overlap } ->
      `Assoc [
        ("type", `String "split");
        ("delimiter", `String delimiter);
        ("chunk_size", `Int chunk_size);
        ("overlap", `Int overlap);
      ]
  | Custom name -> `Assoc [("type", `String "custom"); ("func", `String name)]

(** Serialize on_error policy to JSON *)
let on_error_to_json = function
  | `Fail -> `String "fail"
  | `Passthrough -> `String "passthrough"
  | `Default s -> `Assoc [("default", `String s)]

(** Serialize config to JSON *)
let config_to_json (cfg : chain_config) : Yojson.Safe.t =
  `Assoc [
    ("max_depth", `Int cfg.max_depth);
    ("max_concurrency", `Int cfg.max_concurrency);
    ("timeout", `Int cfg.timeout);
    ("trace", `Bool cfg.trace);
  ]

(** Serialize node to JSON *)
let rec node_to_json_with (include_empty_inputs : bool) (n : node) : Yojson.Safe.t =
  let base = [("id", `String n.id)] in
  (* For lossless roundtrip, preserve ALL input_mapping entries including _dep_ prefixed ones.
     Previously we filtered out _dep_ prefix entries, but this caused information loss
     during JSON → Mermaid → JSON roundtrip. The _dep_ prefix is a semantic marker for
     explicit dependencies (vs template-inferred), and must survive serialization. *)
  let filtered_mapping =
    match n.node_type with
    | Adapter { input_ref; _ } ->
        (* Only filter the implicit input_ref, not _dep_ entries *)
        List.filter (fun (k, _) -> k <> input_ref) n.input_mapping
    | _ ->
        n.input_mapping  (* Preserve all, including _dep_ prefixed entries *)
  in
  let input_mapping =
    if filtered_mapping = [] then
      if include_empty_inputs then [("inputs", `Assoc [])] else []
    else
      [("inputs", `Assoc (List.map (fun (k, v) -> (k, `String v)) filtered_mapping))]
  in
  let type_fields = match n.node_type with
    | Llm { model; system; prompt; timeout; tools; prompt_ref; prompt_vars; thinking } ->
        let fields = [
          ("type", `String "llm");
          ("model", `String model);
          ("prompt", `String prompt);
        ] in
        let fields = match system with
          | Some s -> fields @ [("system", `String s)]
          | None -> fields
        in
        let fields = match timeout with
          | Some t -> fields @ [("timeout", `Int t)]
          | None -> fields
        in
        let fields = match tools with
          | Some t -> fields @ [("tools", t)]
          | None -> fields
        in
        let fields = match prompt_ref with
          | Some r -> fields @ [("prompt_ref", `String r)]
          | None -> fields
        in
        let fields = if prompt_vars <> [] then
          fields @ [("prompt_vars", `Assoc (List.map (fun (k, v) -> (k, `String v)) prompt_vars))]
        else fields
        in
        (* Phase 6: Serialize thinking field for GLM reasoning mode *)
        let fields = if thinking then
          fields @ [("thinking", `Bool true)]
        else fields
        in
        fields

    | Tool { name; args } ->
        (* Restore nested structure if server prefix exists: "figma:parse_url" -> tool.server + tool.name *)
        if String.contains name ':' then
          let idx = String.index name ':' in
          let server = String.sub name 0 idx in
          let tool_name = String.sub name (idx + 1) (String.length name - idx - 1) in
          let tool_obj = `Assoc [
            ("server", `String server);
            ("name", `String tool_name);
            ("args", args)
          ] in
          [("type", `String "tool"); ("tool", tool_obj)]
        else
          [("type", `String "tool"); ("name", `String name); ("args", args)]

    | Pipeline nodes ->
        [("type", `String "pipeline"); ("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes))]

    | Fanout nodes ->
        [("type", `String "fanout"); ("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes))]

    | Quorum { consensus; nodes; weights } ->
        (* P1.3: Serialize consensus mode *)
        let consensus_field = match consensus with
          | Chain_types.Count n -> [("required", `Int n)]  (* backward compat *)
          | _ -> [("consensus", `String (Chain_types.consensus_mode_to_string consensus))]
        in
        let weights_field = if weights = [] then []
          else [("weights", `Assoc (List.map (fun (k, v) -> (k, `Float v)) weights))]
        in
        [("type", `String "quorum")]
        @ consensus_field
        @ weights_field
        @ [("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes))]

    | Gate { condition; then_node; else_node } ->
        let fields = [
          ("type", `String "gate");
          ("condition", `String condition);
          ("then", node_to_json_with include_empty_inputs then_node);
        ] in
        (match else_node with
         | Some en -> fields @ [("else", node_to_json_with include_empty_inputs en)]
         | None -> fields)

    | Subgraph c ->
        [("type", `String "subgraph"); ("graph", chain_to_json_inner_with include_empty_inputs c)]

    | ChainRef ref_id ->
        [("type", `String "chain_ref"); ("ref", `String ref_id)]

    | Map { func; inner } ->
        [("type", `String "map"); ("func", `String func); ("inner", node_to_json_with include_empty_inputs inner)]

    | Bind { func; inner } ->
        [("type", `String "bind"); ("func", `String func); ("inner", node_to_json_with include_empty_inputs inner)]

    | Merge { strategy; nodes } ->
        [
          ("type", `String "merge");
          ("strategy", `String (merge_strategy_to_string strategy));
          ("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes));
        ]

    | Threshold { metric; operator; value; input_node; on_pass; on_fail } ->
        let fields = [
          ("type", `String "threshold");
          ("metric", `String metric);
          ("operator", `String (threshold_op_to_string operator));
          ("value", `Float value);
          ("input_node", node_to_json_with include_empty_inputs input_node);
        ] in
        let fields = match on_pass with Some n -> fields @ [("on_pass", node_to_json_with include_empty_inputs n)] | None -> fields in
        let fields = match on_fail with Some n -> fields @ [("on_fail", node_to_json_with include_empty_inputs n)] | None -> fields in
        fields

    | GoalDriven { goal_metric; goal_operator; goal_value; action_node;
                    measure_func; max_iterations; strategy_hints; conversational; relay_models } ->
        let fields = [
          ("type", `String "goal_driven");
          ("goal_metric", `String goal_metric);
          ("goal_operator", `String (threshold_op_to_string goal_operator));
          ("goal_value", `Float goal_value);
          ("action_node", node_to_json_with include_empty_inputs action_node);
          ("measure_func", `String measure_func);
          ("max_iterations", `Int max_iterations);
          ("conversational", `Bool conversational);
        ] in
        let fields = if strategy_hints = [] then fields
          else fields @ [("strategy_hints", `Assoc (List.map (fun (k, v) -> (k, `String v)) strategy_hints))]
        in
        let fields = if relay_models = [] then fields
          else fields @ [("relay_models", `List (List.map (fun s -> `String s) relay_models))]
        in
        fields

    | Evaluator { candidates; scoring_func; scoring_prompt; select_strategy; min_score } ->
        let fields = [
          ("type", `String "evaluator");
          ("candidates", `List (List.map (node_to_json_with include_empty_inputs) candidates));
          ("scoring_func", `String scoring_func);
          ("select_strategy", select_strategy_to_json select_strategy);
        ] in
        let fields = match scoring_prompt with
          | Some p -> fields @ [("scoring_prompt", `String p)]
          | None -> fields
        in
        let fields = match min_score with
          | Some s -> fields @ [("min_score", `Float s)]
          | None -> fields
        in
        fields

    | Retry { node = inner; max_attempts; backoff; retry_on } ->
        [
          ("type", `String "retry");
          ("node", node_to_json_with include_empty_inputs inner);
          ("max_attempts", `Int max_attempts);
          ("backoff", backoff_to_json backoff);
          ("retry_on", `List (List.map (fun s -> `String s) retry_on));
        ]

    | Fallback { primary; fallbacks } ->
        [
          ("type", `String "fallback");
          ("primary", node_to_json_with include_empty_inputs primary);
          ("fallbacks", `List (List.map (node_to_json_with include_empty_inputs) fallbacks));
        ]

    | Race { nodes; timeout } ->
        let fields = [
          ("type", `String "race");
          ("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes));
        ] in
        (match timeout with
         | Some t -> fields @ [("timeout", `Float t)]
         | None -> fields)

    | ChainExec { chain_source; validate; max_depth; sandbox; context_inject; pass_outputs } ->
        let base_fields = [
          ("type", `String "chain_exec");
          ("chain_source", `String chain_source);
          ("validate", `Bool validate);
          ("max_depth", `Int max_depth);
          ("sandbox", `Bool sandbox);
          ("pass_outputs", `Bool pass_outputs);
        ] in
        let inject_fields =
          if context_inject = [] then []
          else [("context_inject", `Assoc (List.map (fun (k, v) -> (k, `String v)) context_inject))]
        in
        base_fields @ inject_fields

    | Adapter { input_ref; transform; on_error } ->
        [
          ("type", `String "adapter");
          ("input_ref", `String input_ref);
          ("transform", adapter_transform_to_json transform);
          ("on_error", on_error_to_json on_error);
        ]

    | Cache { key_expr; ttl_seconds; inner } ->
        [
          ("type", `String "cache");
          ("key_expr", `String key_expr);
          ("ttl_seconds", `Int ttl_seconds);
          ("inner", node_to_json_with include_empty_inputs inner);
        ]

    | Batch { batch_size; parallel; inner; collect_strategy } ->
        let strategy_str = match collect_strategy with
          | `List -> "list" | `Concat -> "concat" | `First -> "first" | `Last -> "last"
        in
        [
          ("type", `String "batch");
          ("batch_size", `Int batch_size);
          ("parallel", `Bool parallel);
          ("inner", node_to_json_with include_empty_inputs inner);
          ("collect_strategy", `String strategy_str);
        ]
    | Spawn { clean; inner; pass_vars; inherit_cache } ->
        [
          ("type", `String "spawn");
          ("clean", `Bool clean);
          ("inner", node_to_json_with include_empty_inputs inner);
          ("pass_vars", `List (List.map (fun v -> `String v) pass_vars));
          ("inherit_cache", `Bool inherit_cache);
        ]
    | Mcts { strategies; simulation; evaluator; evaluator_prompt; policy;
             max_iterations; max_depth; expansion_threshold; early_stop; parallel_sims } ->
        let policy_json = match policy with
          | UCB1 c -> `Assoc [("type", `String "ucb1"); ("c", `Float c)]
          | Greedy -> `Assoc [("type", `String "greedy")]
          | EpsilonGreedy e -> `Assoc [("type", `String "epsilon_greedy"); ("epsilon", `Float e)]
          | Softmax t -> `Assoc [("type", `String "softmax"); ("temperature", `Float t)]
        in
        [
          ("type", `String "mcts");
          ("strategies", `List (List.map (node_to_json_with include_empty_inputs) strategies));
          ("simulation", node_to_json_with include_empty_inputs simulation);
          ("evaluator", `String evaluator);
          ("evaluator_prompt", match evaluator_prompt with Some p -> `String p | None -> `Null);
          ("policy", policy_json);
          ("max_iterations", `Int max_iterations);
          ("max_depth", `Int max_depth);
          ("expansion_threshold", `Int expansion_threshold);
          ("early_stop", match early_stop with Some s -> `Float s | None -> `Null);
          ("parallel_sims", `Int parallel_sims);
        ]
    | StreamMerge { nodes; reducer; initial; min_results; timeout } ->
        let reducer_json = match reducer with
          | First -> `String "first"
          | Last -> `String "last"
          | Concat -> `String "concat"
          | WeightedAvg -> `String "weighted_avg"
          | Custom s -> `Assoc [("type", `String "custom"); ("name", `String s)]
        in
        [
          ("type", `String "stream_merge");
          ("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes));
          ("reducer", reducer_json);
          ("initial", `String initial);
          ("min_results", match min_results with Some n -> `Int n | None -> `Null);
          ("timeout", match timeout with Some t -> `Float t | None -> `Null);
        ]
    | FeedbackLoop { generator; evaluator_config; improver_prompt; max_iterations; score_threshold; score_operator; conversational; relay_models } ->
        let select_strategy_json = match evaluator_config.select_strategy with
          | Best -> `String "best"
          | Worst -> `String "worst"
          | WeightedRandom -> `String "weighted_random"
          | AboveThreshold t -> `List [`String "above_threshold"; `Float t]
        in
        let evaluator_config_json = `Assoc [
          ("scoring_func", `String evaluator_config.scoring_func);
          ("scoring_prompt", match evaluator_config.scoring_prompt with Some p -> `String p | None -> `Null);
          ("select_strategy", select_strategy_json);
        ] in
        let operator_str = match score_operator with
          | Gt -> "gt" | Gte -> "gte" | Lt -> "lt" | Lte -> "lte" | Eq -> "eq" | Neq -> "neq"
        in
        let fields = [
          ("type", `String "feedback_loop");
          ("generator", node_to_json_with include_empty_inputs generator);
          ("evaluator_config", evaluator_config_json);
          ("improver_prompt", `String improver_prompt);
          ("max_iterations", `Int max_iterations);
          ("score_threshold", `Float score_threshold);
          ("score_operator", `String operator_str);
          ("conversational", `Bool conversational);
        ] in
        let fields = if relay_models = [] then fields
          else fields @ [("relay_models", `List (List.map (fun s -> `String s) relay_models))]
        in
        fields
    | Masc_broadcast { message; room; mention } ->
        let fields = [
          ("type", `String "masc_broadcast");
          ("message", `String message);
          ("mention", `List (List.map (fun s -> `String s) mention));
        ] in
        (match room with Some r -> fields @ [("room", `String r)] | None -> fields)
    | Masc_listen { filter; timeout_sec; room } ->
        let fields = [
          ("type", `String "masc_listen");
          ("timeout_sec", `Float timeout_sec);
        ] in
        let fields = match filter with Some f -> fields @ [("filter", `String f)] | None -> fields in
        (match room with Some r -> fields @ [("room", `String r)] | None -> fields)
    | Masc_claim { task_id; room } ->
        let fields = [("type", `String "masc_claim")] in
        let fields = match task_id with Some t -> fields @ [("task_id", `String t)] | None -> fields in
        (match room with Some r -> fields @ [("room", `String r)] | None -> fields)
    | Cascade { tiers; confidence_prompt; max_escalations; context_mode; task_hint; default_threshold } ->
        let tier_json = `List (List.map Chain_types.cascade_tier_to_yojson tiers) in
        let fields = [
          ("type", `String "cascade");
          ("tiers", tier_json);
          ("max_escalations", `Int max_escalations);
          ("context_mode", `String (Chain_types.context_mode_to_string context_mode));
          ("default_threshold", `Float default_threshold);
        ] in
        let fields = match confidence_prompt with Some p -> ("confidence_prompt", `String p) :: fields | None -> fields in
        let fields = match task_hint with Some h -> ("task_hint", `String h) :: fields | None -> fields in
        fields
  in
  `Assoc (base @ type_fields @ input_mapping)

(** Serialize chain to JSON (inner) *)
and chain_to_json_inner_with (include_empty_inputs : bool) (c : chain) : Yojson.Safe.t =
  `Assoc [
    ("id", `String c.id);
    ("nodes", `List (List.map (node_to_json_with include_empty_inputs) c.nodes));
    ("output", `String c.output);
    ("config", config_to_json c.config);
  ]

let node_to_json (n : node) : Yojson.Safe.t =
  node_to_json_with false n

(** Main entry point: Serialize chain to JSON *)
let chain_to_json ?(include_empty_inputs = false) (c : chain) : Yojson.Safe.t =
  chain_to_json_inner_with include_empty_inputs c

(** Serialize chain to JSON string (pretty-printed) *)
let chain_to_json_string ?(pretty=true) ?(include_empty_inputs = false) (c : chain) : string =
  let json = chain_to_json ~include_empty_inputs c in
  if pretty then Yojson.Safe.pretty_to_string json
  else Yojson.Safe.to_string json
