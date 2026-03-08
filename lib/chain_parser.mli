(** Chain Parser - JSON to Chain AST conversion

    Parses JSON DSL into Chain_types structures.
    Handles:
    - Node type detection and parsing
    - Input mapping with \{\{node.output\}\} syntax
    - Validation (cycle detection, depth limits)
    - Config defaults and overrides

    @author Chain Engine
    @since 2026-01
*)

(** {1 Main Parsing Functions} *)

(** [parse_chain json] parses a complete chain from JSON.
    This is the main entry point for JSON → Chain conversion.

    @param json The JSON representation of a chain
    @return The parsed chain or an error message *)
val parse_chain : Yojson.Safe.t -> (Chain_types.chain, string) result

(** [parse_node json] parses a single node from JSON.

    @param json The JSON representation of a node
    @return The parsed node or an error message *)
val parse_node : Yojson.Safe.t -> (Chain_types.node, string) result

(** [parse_nodes json_list] parses a list of nodes from JSON.

    @param json_list List of JSON node representations
    @return The parsed nodes or an error message *)
val parse_nodes : Yojson.Safe.t list -> (Chain_types.node list, string) result

(** [parse_config json] parses chain configuration from JSON.
    Missing fields use default values from {!Chain_types.default_config}.

    @param json The JSON representation of config
    @return The parsed config *)
val parse_config : Yojson.Safe.t -> Chain_types.chain_config

(** {1 Validation} *)

(** [validate_chain chain] validates the chain structure (basic).
    Checks:
    - Output node exists
    - No duplicate node IDs (top-level)
    - No unresolved placeholder nodes

    @param chain The chain to validate
    @return Unit on success, error message on failure *)
val validate_chain : Chain_types.chain -> (unit, string) result

(** [validate_chain_strict chain] validates completeness + format.
    Checks:
    - Output node exists
    - No duplicate IDs across all nodes (including nested/subgraphs)
    - No unresolved placeholder nodes
    - Required fields and list sizes per node type
    - Input mapping references resolve to known nodes or allowed external vars
    - Config sanity (positive limits)

    @param chain The chain to validate
    @return Unit on success, error message on failure *)
val validate_chain_strict : Chain_types.chain -> (unit, string) result

(** [has_placeholder_node node] checks if a node contains unresolved placeholders.
    Placeholders are created during Mermaid parsing and should be resolved
    before execution.

    @param node The node to check
    @return true if unresolved placeholders exist *)
val has_placeholder_node : Chain_types.node -> bool

(** {1 Input Mapping Extraction} *)

(** [extract_input_mappings prompt] extracts input references from a prompt template.
    Finds all \{\{node.output\}\} patterns and returns mappings.

    @param prompt The prompt string with template variables
    @return List of (reference, node_id) pairs *)
val extract_input_mappings : string -> (string * string) list

(** [extract_json_mappings json] extracts input references from JSON arguments.
    Recursively searches through JSON structures for template variables.

    @param json The JSON to search
    @return List of (reference, node_id) pairs *)
val extract_json_mappings : Yojson.Safe.t -> (string * string) list

(** {1 Strategy Parsing} *)

(** [parse_merge_strategy str] parses a merge strategy from string.
    Supported values: "first", "last", "concat", "weighted_average", "custom:name"

    @param str The strategy string
    @return The parsed strategy or an error *)
val parse_merge_strategy : string -> (Chain_types.merge_strategy, string) result

(** [parse_threshold_op str] parses a threshold operator from string.
    Supported values: "gt", ">", "gte", ">=", "lt", "<", "lte", "<=", "eq", "=", "neq", "!="

    @param str The operator string
    @return The parsed operator or an error *)
val parse_threshold_op : string -> (Chain_types.threshold_op, string) result

(** [parse_select_strategy json] parses a selection strategy from JSON.
    Supports: "best", "worst", "weighted_random", \{above_threshold: float\}

    @param json The strategy as JSON
    @return The parsed strategy or an error *)
val parse_select_strategy : Yojson.Safe.t -> (Chain_types.select_strategy, string) result

(** [parse_backoff_strategy json] parses a backoff strategy from JSON.
    Supports various formats including string shortcuts and detailed objects.

    @param json The strategy as JSON
    @return The parsed strategy (never fails, uses defaults) *)
val parse_backoff_strategy : Yojson.Safe.t -> Chain_types.backoff_strategy

(** [parse_adapter_transform json] parses an adapter transform from JSON.
    Supports string shortcuts (e.g., "extract:path") and detailed objects.

    @param json The transform as JSON
    @return The parsed transform or an error *)
val parse_adapter_transform : Yojson.Safe.t -> (Chain_types.adapter_transform, string) result

(** {1 JSON Serialization} *)

(** [chain_to_json ?include_empty_inputs chain] serializes a chain to JSON.
    This is the inverse of {!parse_chain}.

    @param include_empty_inputs Emit empty "inputs": {} for nodes with no input_mapping (default: false)
    @param chain The chain to serialize
    @return The JSON representation *)
val chain_to_json : ?include_empty_inputs:bool -> Chain_types.chain -> Yojson.Safe.t

(** [chain_to_json_string ?pretty ?include_empty_inputs chain] serializes a chain to a JSON string.

    @param pretty Whether to pretty-print (default: true)
    @param include_empty_inputs Emit empty "inputs": {} for nodes with no input_mapping (default: false)
    @param chain The chain to serialize
    @return The JSON string *)
val chain_to_json_string : ?pretty:bool -> ?include_empty_inputs:bool -> Chain_types.chain -> string

(** [node_to_json node] serializes a node to JSON.

    @param node The node to serialize
    @return The JSON representation *)
val node_to_json : Chain_types.node -> Yojson.Safe.t

(** [config_to_json config] serializes chain config to JSON.

    @param config The config to serialize
    @return The JSON representation *)
val config_to_json : Chain_types.chain_config -> Yojson.Safe.t

(** {1 Strategy Serialization} *)

(** [merge_strategy_to_string strategy] converts a merge strategy to string. *)
val merge_strategy_to_string : Chain_types.merge_strategy -> string

(** [threshold_op_to_string op] converts a threshold operator to string. *)
val threshold_op_to_string : Chain_types.threshold_op -> string

(** [select_strategy_to_json strategy] converts a select strategy to JSON. *)
val select_strategy_to_json : Chain_types.select_strategy -> Yojson.Safe.t

(** [backoff_to_json backoff] converts a backoff strategy to JSON. *)
val backoff_to_json : Chain_types.backoff_strategy -> Yojson.Safe.t

(** [adapter_transform_to_json transform] converts an adapter transform to JSON. *)
val adapter_transform_to_json : Chain_types.adapter_transform -> Yojson.Safe.t

(** {1 JSON Parsing Helpers}

    These helpers provide safe JSON parsing with explicit error handling. *)

(** [require_string json field] extracts a required string field. *)
val require_string : Yojson.Safe.t -> string -> (string, string) result

(** [require_float json field] extracts a required float field. *)
val require_float : Yojson.Safe.t -> string -> (float, string) result

(** [parse_string_opt json field] extracts an optional string field. *)
val parse_string_opt : Yojson.Safe.t -> string -> string option

(** [parse_int_opt json field] extracts an optional int field. *)
val parse_int_opt : Yojson.Safe.t -> string -> int option

(** [parse_float_opt json field] extracts an optional float field. *)
val parse_float_opt : Yojson.Safe.t -> string -> float option

(** [parse_string_with_default json field default] extracts a string with fallback. *)
val parse_string_with_default : Yojson.Safe.t -> string -> string -> string

(** [parse_int_with_default json field default] extracts an int with fallback. *)
val parse_int_with_default : Yojson.Safe.t -> string -> int -> int

(** [parse_bool_with_default json field default] extracts a bool with fallback. *)
val parse_bool_with_default : Yojson.Safe.t -> string -> bool -> bool

(** [parse_list_with_default json field] extracts a list with empty fallback. *)
val parse_list_with_default : Yojson.Safe.t -> string -> Yojson.Safe.t list

(** [parse_string_list_opt json field] extracts an optional string list. *)
val parse_string_list_opt : Yojson.Safe.t -> string -> string list

(** [parse_string_assoc_opt json field] extracts an optional string association list. *)
val parse_string_assoc_opt : Yojson.Safe.t -> string -> (string * string) list
