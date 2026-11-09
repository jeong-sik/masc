(** The refusal types, the Skill types and the schema-only tool rows of the
    composition surface.

    [owner_metadata_refusal] and [continuation_refusal] say why a continuation
    is refused; [continuation_refusal_to_json] renders them and
    [validate_original_producer_activation] checks that a named producer's
    activation is still recorded. [instruction_skill] and [composition_skill]
    are the Skills a Keeper carries, and [instruction_skill_description] and
    [carried_references_text] list them for the model. [schema_tool_name_rows]
    and [schema_tool_rows] list the rows of the schema-only tools, in one
    order, as names and as tools.
    [Keeper_tool_composition_surface] includes this module. *)

type owner_metadata_refusal =
  | Owner_metadata_missing
  | Owner_metadata_mismatch

type continuation_refusal =
  | Current_leaf_denied of Keeper_composition_draft.continuation_refusal
  | Original_producer_absent of Skill_reference.t
  | Original_producer_changed of Skill_reference.t
  | Original_owner_metadata_refused of owner_metadata_refusal

val continuation_refusal_to_json : continuation_refusal -> Yojson.Safe.t

val validate_original_producer_activation :
  config:Workspace_utils_backend_setup.config ->
  Keeper_tool_execution_journal.source -> (unit, string) result

val composition_run_summary_tool_name : string

val request_id_of_validated_input :
  [> `Assoc of (string * [> `String of 'a ]) list ] -> 'a option

val entry_description : Keeper_tool_composition_catalog.entry -> string

val skill_tool_schema : Types_core.tool_schema

type instruction_skill = {
  reference : Skill_reference.t;
  description : string;
  body : string;
  resource_location : resource_location option;
}
and resource_location = {
  source_root : string;
  directory : string;
  resource_read_max_bytes : Skill_source_config.resource_read_max_bytes;
}

type composition_skill =
  { reference : Skill_reference.t
  ; entry : Keeper_tool_composition_catalog.entry
  }

val instruction_skill_description : instruction_skill list -> string

val carried_references_text : instruction_skill list -> string

type 'evidence schema_tool_origin =
  | Declared_composition of 'evidence
  | Async_status
  | Async_cancel
  | Transient_run

val composition_schema_tool :
  Keeper_tool_composition_catalog.entry -> (Agent_core.Tool.t, Tool_bridge.schema_error) result

val schema_tool_name_rows :
  ?include_drafts:bool ->
  ?skill_compositions:(Keeper_tool_composition_catalog.entry * 'evidence) list ->
  unit ->
  ('evidence schema_tool_origin * string) list

val schema_tool_rows :
  ?include_drafts:bool ->
  ?skill_compositions:(Keeper_tool_composition_catalog.entry * 'evidence) list ->
  unit ->
  ('evidence schema_tool_origin * (Agent_core.Tool.t, Tool_bridge.schema_error) result) list
