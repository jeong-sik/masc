(** Compile exact frozen inline Skill calls into one descriptor-owned DAG.
    No Skill source is reread and no Tool is dispatched. This first compiler
    binds fixed arguments; output-dependent child arguments require a runtime
    parameter-contract barrier and are outside this grammar. *)

type call = private
  { alias : Keeper_tool_plan.Node_id.t
  ; reference : Skill_reference.t
  ; args : Yojson.Safe.t
  ; node_mapping : (Keeper_tool_plan.Node_id.t * Keeper_tool_plan.Node_id.t) list
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
  | Child_output_requires_export of Keeper_tool_plan.Node_id.t
  | Unknown_child_export of { alias : Keeper_tool_plan.Node_id.t; name : string }
  | Unsupported_leaf of { node_id : Keeper_tool_plan.Node_id.t; tool_name : string }
  | Inputs_rejected of Keeper_tool_plan.Node_id.t * Keeper_tool_plan.execution_error
  | Expanded_plan_rejected of Keeper_tool_plan.error

val input_schema : Yojson.Safe.t
(** Ordinary request nodes or [{id; skill_reference; args; after?}].
    [skill_reference] is the strict pinned identity JSON from Skill inventory;
    [args] is the fixed argument object. Child outputs are named exports,
    addressed by [/export-name/subpath]. *)

val compile :
  capability_surface:Keeper_capability_surface.t -> Yojson.Safe.t -> (t, error) result
(** Resolve only exact admitted model-visible inline compositions. Child and
    parent failure policies must agree. Every reference or [after] dependency
    on a child waits for its complete expanded scope, so a successful exported
    branch cannot conceal a sibling failure. Final graph, descriptor authority,
    output pointers and fixed leaf inputs are revalidated before dispatch.

    When there are children, every node ID is the canonical JSON encoding of
    a path ([parent-id] or [child-alias; child-node-id]); arbitrary delimiter
    characters in IDs cannot collide. Child policy disagreement and async
    children are explicit refusals, rather than silent semantic changes. *)

val plan : t -> Keeper_tool_plan.t
val calls : t -> call list
val call_to_json : call -> Yojson.Safe.t
val calls_to_json : t -> Yojson.Safe.t
(** Exact references, bound arguments and explicit leaf mappings for durable
    draft/run evidence. Preparation does not constitute Skill activation. *)
val error_to_json : error -> Yojson.Safe.t
