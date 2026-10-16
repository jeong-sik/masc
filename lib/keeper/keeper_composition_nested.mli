(** Compile exact frozen Skill calls into one typed DAG without dispatch.
    Inline and async children may bind explicit upstream argument templates.
    Their private argument/submission contract validates resolved arguments
    before activation. *)

type arguments = Fixed of Yojson.Safe.t | Upstream of Keeper_tool_plan.Json_template.t

type scope =
  | Inline of
      { argument_node : Keeper_tool_plan.Node_id.t option
      ; mapping : (Keeper_tool_plan.Node_id.t * Keeper_tool_plan.Node_id.t) list
      }
  | Async of
      { submission : Keeper_tool_plan.Node_id.t
      ; result : Keeper_tool_plan.Node_id.t
      }

type call = private
  { alias : Keeper_tool_plan.Node_id.t
  ; reference : Skill_reference.t
  ; arguments : arguments
  ; scope : scope
  ; exports : Keeper_tool_plan.export list
  }

type t

type error =
  | Request_rejected of Keeper_tool_plan_request.error
  | Invalid_call_field of { index : int; field : string; detail : string }
  | Invalid_reference of { index : int; error : Skill_reference.decode_error }
  | Reference_unavailable of
      { alias : Keeper_tool_plan.Node_id.t
      ; reference : Skill_reference.t
      ; availability : Keeper_capability_surface.capability_availability option
      }
  | Instruction_reference of Keeper_tool_plan.Node_id.t
  | Async_child_requires_suspension of Keeper_tool_plan.Node_id.t
  | Child_policy_mismatch of Keeper_tool_plan.Node_id.t
  | Arguments_rejected of Keeper_tool_plan.Node_id.t * Tool_input_validation.rejection
  | Binding_rejected of Keeper_tool_plan.Node_id.t * Keeper_tool_composition_catalog.instantiation_error
  | Duplicate_alias of Keeper_tool_plan.Node_id.t
  | Unknown_alias of Keeper_tool_plan.Node_id.t
  | Child_output_requires_export of
      { alias : Keeper_tool_plan.Node_id.t; available_exports : string list }
  | Unknown_child_export of
      { alias : Keeper_tool_plan.Node_id.t; name : string; available_exports : string list }
  | Unsupported_leaf of { node_id : Keeper_tool_plan.Node_id.t; tool_name : string }
  | Inputs_rejected of Keeper_tool_plan.Node_id.t * Keeper_tool_plan.execution_error
  | Expanded_plan_rejected of Keeper_tool_plan.error

val input_schema : Yojson.Safe.t
(** Node alternatives share field definitions while preserving their own
    required and forbidden fields. The canonical compiler still validates
    references, templates, dependencies, capability and execution authority.
    Ordinary request nodes or [{id; skill_reference; args|input; after?}].
    [skill_reference] is the strict pinned identity JSON from Skill inventory;
    Exactly one of literal [args] or an explicit [input] template is required.
    [input] is supported for inline and async children. Child outputs are named exports,
    addressed by [/export-name/subpath]. *)

val compile :
  execution:Keeper_tool_composition_catalog.execution_mode ->
  capability_surface:Keeper_capability_surface.t -> Yojson.Safe.t -> (t, error) result
(** Resolve only exact admitted model-visible compositions. Child and
    parent failure policies must agree. Every reference or [after] dependency
    on a child waits for its complete expanded scope, so a successful exported
    branch cannot conceal a sibling failure. Final graph, descriptor authority,
    output pointers and fixed leaf inputs are revalidated before dispatch.
    Inline drafts admit the canonical owned-file Edit producer, including
    flattened inline children. Async scopes retain their durable read/launch
    admission; an ordinary file Edit has no replayable launch identity.

    When there are children, every node ID is the canonical JSON encoding of
    a path ([parent-id] or [child-alias; child-node-id]); arbitrary delimiter
    characters in IDs cannot collide. Async children require an async parent;
    their submission and whole-result barrier remain distinct typed targets. *)

val compile_for_refusal :
  execution:Keeper_tool_composition_catalog.execution_mode ->
  capability_surface:Keeper_capability_surface.t -> Yojson.Safe.t -> (t, error) result
(** Revalidate frozen contracts for refusal only, retaining exact descriptors
    whose current row is [Denied_by_profile]. It grants no dispatch admission;
    nested Skill visibility and every other admission check remain strict. *)

val plan : t -> Keeper_tool_plan.t
val calls : t -> call list
val call_to_json : call -> Yojson.Safe.t
val calls_to_json : t -> Yojson.Safe.t
(** Exact references, fixed arguments or explicit upstream templates and leaf mappings for durable
    draft/run evidence. Preparation does not constitute Skill activation. *)
val error_to_json : error -> Yojson.Safe.t
(** Export rejections include the exact admitted child's available export names
    and canonical public pointers. They expose no private expanded node IDs. *)
