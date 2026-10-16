(** Producer-owned resource binding for an exact instantiated Read/Edit plan.
    These entry claims authorize neither effects nor replay. *)
type t
type operation =
  | Read of Keeper_tool_filesystem_runtime.prepared_read
  | Edit of Keeper_tool_filesystem_runtime.prepared_edit

val eligible : Keeper_tool_plan.t -> bool
(** At least one leaf is Edit; every leaf is a canonical ordinary Read or Edit.
    Fixed inline children flattened to such leaves are included. Read-only
    plans, synthetic child targets, other effects and terminal leaves retain
    ordinary admission. *)

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
  (** Original source-bound inline Read/Edit/Write plans, including pure
      compiled child argument validation. Inputs may depend on upstream
      results. No file is opened until its node has a resolved, validated
      input. Write always binds its original exclusive ordinary handler;
      supported Read/Edit siblings retain their own prepared capabilities.
      Other effects and async child submission/result targets are ineligible. *)

  val plan : t -> Keeper_tool_plan.t
  val bind : t -> node:Keeper_tool_plan.node -> input:Yojson.Safe.t -> binding
  (** Opens capabilities owned by the call switch through the original file
      producer. Unsupported preparation retains the ordinary handler and
      conflicts conservatively with every other file operation. *)
  val operation : binding -> operation option
  val conflicts : binding -> binding -> bool
  val exclusive : binding -> bool
  (** Only a file operation without prepared resource identity runs alone.
      Pure argument validation has no file footprint. *)
end
