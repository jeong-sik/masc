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
    - MASC_CHAIN_MAX_DEPTH (default: 20)
    - MASC_CHAIN_MAX_CONCURRENCY (default: 10)
    - MASC_CHAIN_MAX_NODES (default: 100)
    - MASC_CHAIN_MAX_FANOUT (default: 20)
*)

(* Fiber-safe random state for subgraph ID generation *)
let parser_rng = Random.State.make_self_init ()

open Chain_types

(** {1 Security Limits (P0.3)} *)

(** Maximum allowed chain depth to prevent stack overflow *)
let security_max_depth =
  Env_config.Chain.Limits.max_depth

let security_max_concurrency =
  Env_config.Chain.Limits.max_concurrency

let security_max_nodes =
  Env_config.Chain.Limits.max_nodes

let security_max_fanout =
  Env_config.Chain.Limits.max_fanout

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
      Log.Chain.warn "chain_parser: Field '%s' expected int, got %s, using default %d"
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
let template_var_re = Re.Pcre.re {|\{\{([^}]+)\}\}|} |> Re.compile

let extract_input_mappings (prompt : string) : (string * string) list =
  Re.all template_var_re prompt
  |> List.map (fun group -> Re.Group.get group 1)
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

