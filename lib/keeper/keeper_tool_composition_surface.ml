(* The items live in the Keeper_tool_composition_surface_* modules, included in
   the order below. Each module reads only the ones above it: the refusal and
   Skill types with the schema-only tool rows, the tool-call log rows, the
   plan execution steps, the status and cancel controls, the instruction Skill
   tool, the run outcome judgements, the asynchronous worker and submission,
   the continuation resume, and the tool list. *)

include Keeper_tool_composition_surface_schema
include Keeper_tool_composition_surface_observation
include Keeper_tool_composition_surface_execution
include Keeper_tool_composition_surface_request_control
include Keeper_tool_composition_surface_instruction_skill
include Keeper_tool_composition_surface_outcome
include Keeper_tool_composition_surface_async
include Keeper_tool_composition_surface_resume
include Keeper_tool_composition_surface_tools

open Keeper_tool_composition_projection

module For_testing = struct
  type nonrec recovery_decision = continuation_recovery =
    | Complete_original_result
    | Hold_original_authority of string
  let continuation_recovery_of_result = continuation_recovery_of_result
  let combine_recovery = combine_recovery
  let resume_continuation ?owner_metadata_refusal ~after_refusal_binding ~after_refusal_settled
      ~capability_surface ~continuation ~config ~meta ~publication_recovery
      ~ctx_snapshot ~turn_context ~invocation ?clock () =
    resume_continuation_with ?owner_metadata_refusal
      ~on_refusal_accepted:(fun request_id -> after_refusal_binding ~request_id; Ok ())
      ~observe_refusal_settlement:(fun _settlement -> after_refusal_settled ())
      ~capability_surface ~continuation ~config ~meta ~publication_recovery
      ~ctx_snapshot ~turn_context ~invocation ?clock ()

  let async_worker_result = async_worker_result
  let node_result_to_json = node_result_to_json
  let project_execution_result = project_execution_result
  let result_of_execution = result_of_execution
  let observe_node_result = observe_node_result
  let failure_payload = failure_payload
  let instruction_skill_description = instruction_skill_description
  let make_instruction_skill_tool = make_instruction_skill_tool
  let status_result = status_result
  let cancel_result = cancel_result
end

let make_tools ~capability_surface =
  make_tools_with_authority
    ~capability_authority:
      (Keeper_tool_runtime.Frozen_surface capability_surface)
    ~descriptors:(Keeper_capability_surface.descriptors capability_surface)
;;

module Compatibility = struct
  let make_tools ~descriptors =
    make_tools_with_authority
      ~capability_authority:Keeper_tool_runtime.Compatibility_meta
      ~descriptors
  ;;
end
