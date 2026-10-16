(** Producer-owned resource binding for an exact instantiated Edit-only plan.
    These directory claims authorize neither effects nor replay. *)
type t

val eligible : Keeper_tool_plan.t -> bool
(** Every leaf must be a canonical ordinary Edit. Compiled children, other
    effects, readonly mixtures and terminal leaves retain ordinary admission. *)

val prepare
  : sw:Eio.Switch.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> source:Keeper_tool_call_log_context.turn_context option
  -> Keeper_tool_plan.t
  -> t option
(** Requires the original Keeper/Task/trace/turn source and completely resolved,
    validated model inputs. [None] retains Serial execution and its normal
    failure observations. All opened capabilities belong to [sw]. An aggregate
    that cannot transfer every node releases its earlier preparations before
    returning, including during cancellation. *)

val plan : t -> Keeper_tool_plan.t
val source : t -> Keeper_tool_call_log_context.turn_context
val scopes : t -> Agent_core.Tool_contract.Resource_scope.t list

val resource_dependencies
  : plan:Keeper_tool_plan.t
  -> t
  -> (Keeper_tool_plan.Node_id.t * Keeper_tool_plan.Node_id.t list) list option
(** Earlier conflicting prepared leaves in dependency-layer order. Only the
    exact immutable plan has this ordering; [None] means a different plan.
    Disjoint siblings share no ordering edge. These edges grant neither
    authorization nor replay and do not replace the plan's dependencies.
    Shared source reads do not conflict; overlapping target writes still do. *)

val for_node
  : plan:Keeper_tool_plan.t
  -> node:Keeper_tool_plan.node
  -> input:Yojson.Safe.t
  -> t
  -> (Keeper_tool_filesystem_runtime.prepared_edit, string) result
(** The exact immutable plan, member node and model input must match. A
    mismatch is a pre-effect rejection, never an unprepared fallback under
    the old claims. The ordinary Edit consumer rechecks owner and confinement. *)
