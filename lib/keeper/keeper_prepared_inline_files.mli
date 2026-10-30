(** Producer-owned resource binding for exact instantiated file plans.
    These entry claims authorize neither effects nor replay. *)
type t
type operation =
  | Read of Keeper_tool_filesystem_runtime.prepared_read
  | Edit of Keeper_tool_filesystem_runtime.prepared_edit
  | Write of Keeper_tool_filesystem_runtime.prepared_write

val eligible : Keeper_tool_plan.t -> bool
(** At least one leaf is Edit or Write; every leaf is a canonical ordinary
    Read, Edit or Write with its original execution contract.
    Fixed inline children flattened to such leaves are included. Read-only
    plans, synthetic child targets, other effects and terminal leaves retain
    ordinary admission. Named inline Write plans can transfer their existing
    producer-owned resource claims to the outer SDK batch, just as Edit plans
    do; this changes neither async admission nor effect/replay authority. *)

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
    returning, including during cancellation. The aggregate retains its
    original ordered leaves and an immutable ID index of those same leaves;
    ID equality never substitutes for the member's physical identity. *)

val plan : t -> Keeper_tool_plan.t
val source : t -> Keeper_tool_call_log_context.turn_context
val scopes : t -> Agent_core.Tool_contract.Resource_scope.t list

type resource_ordering = private
  { dependency_layers : Keeper_tool_plan.node list list
  ; predecessors : (Keeper_tool_plan.Node_id.t * Keeper_tool_plan.Node_id.t list) list
  }
(** Immutable original layers and the resource predecessor lists derived from
    them. Only the producer constructs this value. Nodes retain their original
    plan templates; the record adds no capability, runtime input/result fields
    or effect/replay permission. *)

val resource_ordering
  : plan:Keeper_tool_plan.t
  -> t
  -> resource_ordering option
(** Earlier conflicting prepared leaves in dependency-layer order. Only the
    exact immutable plan has this ordering; [None] means a different plan.
    Disjoint siblings share no ordering edge. These edges grant neither
    authorization nor replay and do not replace the plan's dependencies.
    Shared source reads do not conflict; overlapping target writes still do.
    Within this call, comparisons reuse each original leaf's immutable scope
    list. This does not change the physical checks at file consumption.
    The executor shares these already-built layers with scheduling instead of
    rebuilding the same graph. Each call returns its own ordering only after
    the original plan/member checks; an unused preparation does not build one. *)

val for_node
  : plan:Keeper_tool_plan.t
  -> node:Keeper_tool_plan.node
  -> input:Yojson.Safe.t
  -> t
  -> (operation, string) result
(** The exact immutable plan, member node and model input must match. A
    mismatch is a pre-effect rejection, never an unprepared fallback under
    the old claims. Each file consumer rechecks owner and confinement. *)

module Ready : sig
  type t
  type binding

  val create
    : sw:Eio.Switch.t
    -> config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> source:Keeper_tool_call_log_context.turn_context option
    -> Keeper_tool_plan.t
    -> t option
  (** Original source-bound inline plans containing an Edit or Write, canonical
      Reads, ordinary Serial/Concurrent leaves and pure
      compiled child argument validation. Inputs may depend on upstream
      results. No file is opened until its node has a resolved, validated
      input. Write can bind existing physical parents, including a missing
      target; unprepared paths retain their original exclusive handler.
      Non-file ordinary leaves keep their original handlers and execution
      modes; unknown footprint orders against file mutations without inventing
      file claims. Terminal and async child submission/result targets remain
      ineligible. This does not widen the plan's admission or replay authority. *)

  val plan : t -> Keeper_tool_plan.t
  val dependency_layers : t -> Keeper_tool_plan.node list list
  (** Original immutable topological layers retained during successful Ready
      creation and used for its preparation barriers. The executor reuses them
      only after checking physical equality with [plan t]. They contain the
      original plan nodes, not resolved inputs, bindings, results or execution
      authority. Creation of another Ready object builds its own order. *)
  type ordering = No_order | Wait_for_settlement | Require_success
  val preparation_predecessors : t -> node:Keeper_tool_plan.node ->
    (Keeper_tool_plan.Node_id.t * ordering) list
  (** Earlier opaque effects/reads settle before a file mutation captures its
      physical bindings. Original Serial-to-Serial success requirements apply
      here too. Concurrent ordinary leaves and prepared file reads keep their
      original sharing. This immutable index is built once from the plan;
      file-only plans have no opaque preparation predecessors. The plan's
      explicit dependencies remain independent. Node membership and producer
      contracts are retained from the same immutable plan, separately from
      the ordered predecessor lists. *)
  val bind : t -> node:Keeper_tool_plan.node -> input:Yojson.Safe.t -> binding
  (** Opens capabilities owned by the call switch through the original file
      producer. Unsupported preparation retains the ordinary handler and
      conflicts conservatively with every other file operation. A prepared
      binding retains that same operation and its immutable scope list after
      input resolution/preparation; pair comparisons reuse it. The original
      consumer still rechecks release, owner, input and physical confinement. *)
  val operation : binding -> operation option
  val ordering : binding -> binding -> ordering
  (** Real file conflicts and original Serial-to-Serial dependencies require
      success. An opaque ordering barrier only waits for settlement under
      Continue_independent; Fail_fast still stops after its failed settlement.
      Ordinary concurrent leaves and prepared reads retain their sharing. *)
  val exclusive : binding -> bool
  (** Original ordinary Serial leaves and files without resource identity run alone.
      Pure argument validation has no file footprint. *)
end
