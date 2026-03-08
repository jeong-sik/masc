(** Chain Compiler - AST to Execution Plan conversion

    Transforms Chain_types.chain into an execution plan:
    - Topological sorting of nodes (DAG ordering)
    - Parallel group identification
    - Depth calculation for recursion limits
    - Dependency analysis

    @author Chain Engine
    @since 2026-01
*)

(** {1 Main Compilation} *)

(** [compile chain] compiles a chain into an execution plan.

    This is the main entry point. It:
    1. Validates the chain structure
    2. Builds a dependency graph
    3. Performs topological sort
    4. Identifies parallel execution groups
    5. Calculates maximum nesting depth

    @param chain The chain to compile
    @return The execution plan or an error message *)
val compile : Chain_types.chain -> (Chain_types.execution_plan, string) result

(** {1 Node Access} *)

(** [get_node chain node_id] retrieves a node by its ID.

    @param chain The chain to search
    @param node_id The ID of the node to find
    @return The node if found *)
val get_node : Chain_types.chain -> string -> Chain_types.node option

(** [get_dependencies node] returns all node IDs that this node depends on.

    @param node The node to analyze
    @return List of dependency node IDs *)
val get_dependencies : Chain_types.node -> string list

(** [is_ready completed node] checks if a node can be executed.

    A node is ready when all its dependencies have been completed.

    @param completed List of completed node IDs
    @param node The node to check
    @return true if all dependencies are satisfied *)
val is_ready : string list -> Chain_types.node -> bool

(** {1 Graph Analysis} *)

(** [build_dependency_graph nodes] constructs a dependency graph.

    Maps each node ID to the list of node IDs it depends on.
    Handles both direct input_mapping dependencies and nested node dependencies.

    @param nodes The list of nodes to analyze
    @return A hashtable mapping node IDs to their dependencies *)
val build_dependency_graph : Chain_types.node list -> (string, string list) Hashtbl.t

(** [topological_sort deps] performs topological sort using Kahn's algorithm.

    Returns an error if:
    - A cycle is detected
    - A node depends on a non-existent node

    @param deps The dependency graph
    @return Ordered list of node IDs or an error *)
val topological_sort : (string, string list) Hashtbl.t -> (string list, string) result

(** [identify_parallel_groups nodes execution_order deps] groups nodes by execution level.

    Nodes in the same group have no dependencies on each other and can execute
    in parallel. This enables the Fanout pattern optimization.

    @param nodes The list of nodes
    @param execution_order The topological order
    @param deps The dependency graph
    @return List of parallel groups (each group is a list of node IDs) *)
val identify_parallel_groups :
  Chain_types.node list ->
  string list ->
  (string, string list) Hashtbl.t ->
  string list list

(** {1 Depth Calculation} *)

(** [calculate_depth node] calculates the maximum nesting depth of a node.

    Used to enforce {!Chain_types.chain_config.max_depth} limits and prevent
    infinite recursion in subgraph/chain_ref nodes.

    @param node The node to analyze
    @return The maximum nesting depth *)
val calculate_depth : Chain_types.node -> int

(** [collect_nested_dependencies node] collects all dependency references.

    Recursively traverses nested nodes to find all {{node.output}} references.
    Used by {!build_dependency_graph}.

    @param node The node to analyze
    @return List of dependency node IDs *)
val collect_nested_dependencies : Chain_types.node -> string list

(** {1 Debug Output} *)

(** [pp_plan plan] pretty-prints an execution plan for debugging.

    Shows chain ID, depth, execution order, and parallel groups.

    @param plan The plan to format
    @return Human-readable string representation *)
val pp_plan : Chain_types.execution_plan -> string
