(** Immutable evidence of one prepared async result's physical handoff.
    The activation turn and transport turn are independent coordinates. *)
type presentation = Inline_result | Manifest_reference
type child_activation = { skill_tool_use_id : string; activation_sha256 : string }
type t = private
  { original_turn_ref : Ids.Turn_ref.t
  ; composition_run_id : Keeper_tool_plan.Composition_run_id.t
  ; logical_parent_tool_use_id : string
  ; request_id : string
  ; physical_turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; status_invocation : Agent_core.Tool_contract.Invocation.t
  ; boundary : Keeper_skill_activation_types.delivery_boundary
  ; receipt : Keeper_skill_activation_types.tool_result_receipt
  ; presentation : presentation
  ; child_activations : child_activation list
  ; observed_at : string
  }
val make : original_turn_ref:Ids.Turn_ref.t ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  logical_parent_tool_use_id:string -> request_id:string ->
  physical_turn_ref:Ids.Turn_ref.t -> runtime_id:string ->
  status_invocation:Agent_core.Tool_contract.Invocation.t ->
  boundary:Keeper_skill_activation_types.delivery_boundary ->
  receipt:Keeper_skill_activation_types.tool_result_receipt ->
  presentation:presentation -> child_activations:child_activation list ->
  observed_at:string -> (t, string) result
val invocation_to_json : Agent_core.Tool_contract.Invocation.t -> Yojson.Safe.t
val invocation_of_json : Yojson.Safe.t -> (Agent_core.Tool_contract.Invocation.t, string) result
val equal_invocation : Agent_core.Tool_contract.Invocation.t -> Agent_core.Tool_contract.Invocation.t -> bool
val validate_invocation : Agent_core.Tool_contract.Invocation.t -> (unit, string) result
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val identity : t -> string
(** Canonical physical handoff identity. Observation time is excluded so a
    replay preserves the first durable clock rather than adding another row. *)
