(** The tool that serves the instruction Skills a Keeper carries.

    [make_instruction_skill_tool] builds the tool. It validates the request,
    finds the one carried Skill that the reference names, and returns its body
    or one resource file of it; the optional [record_activation] records the
    activation, and [activation_failure] is the tool result of an activation
    record that failed. [instruction_skill] and [instruction_skills_of_catalog]
    make the carried Skills from a catalog, and
    [instruction_skill_schema_tool] is the schema-only tool that lists them.
    [Keeper_tool_composition_surface] includes this module. *)

open Keeper_tool_composition_surface_schema

val instruction_skill :
  ?resource_location:resource_location ->
  reference:Skill_reference.t ->
  description:string ->
  body:string ->
  unit ->
  instruction_skill

val instruction_skills_of_catalog : Keeper_skill_catalog.t -> instruction_skill list

val instruction_skill_schema_tool :
  instruction_skills:instruction_skill list ->
  (Agent_core.Tool.t, Tool_bridge.schema_error) result

val activation_failure :
  ?reference:Skill_reference.t ->
  tool_name:string ->
  start_time:Tool_timing.started ->
  Keeper_skill_activation_recorder.error -> Tool_result.result

val make_instruction_skill_tool :
  config:Workspace.config ->
  ?record_activation:
    (invocation:Agent_core.Tool_contract.Invocation.t ->
     content:Keeper_skill_activation_recorder.instruction_content ->
     Skill_reference.t ->
     (Keeper_skill_activation_ledger.record_outcome, Keeper_skill_activation_recorder.error) result) ->
  ?assess_applicability:(reference:Skill_reference.t -> body:string -> Typesafeai_skill_applicability.t) ->
  ?on_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  instruction_skills:instruction_skill list -> unit -> (Agent_core.Tool.t, Tool_bridge.schema_error) result
