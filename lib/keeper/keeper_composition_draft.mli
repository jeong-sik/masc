(** Immutable transient plans bound to the preparing Keeper's frozen surface.
    Shared Skill publication is independent of this execution draft. *)

type t
type authored_source = private
  { package_id : Skill_reference.package_id
  ; source_text : string
  }

type error =
  | Plan_rejected of Keeper_tool_plan_request.error
  | Inputs_rejected of Keeper_tool_plan.Node_id.t * Keeper_tool_plan.execution_error
  | Unsupported_node of { node_id : Keeper_tool_plan.Node_id.t; tool_name : string }
  | Storage_failed of string
  | Draft_read_failed of Tool_blob_store.fetch_error
  | Draft_not_found
  | Malformed_draft of string
  | Different_keeper
  | Capability_changed
  | Publication_rejected of Keeper_skill_catalog.authored_source_error
  | Skill_not_prepared
  | Different_package

val prepare_tool_name : string
val run_tool_name : string
val error_to_json : error -> Yojson.Safe.t
val failure_class : error -> Tool_result.tool_failure_class
val prepare_schema : Masc_domain.tool_schema
val run_schema : Masc_domain.tool_schema

val prepare
  :  base_path:string
  -> capability_surface:Keeper_capability_surface.t
  -> keeper_name:string
  -> execution:Keeper_tool_composition_catalog.execution_mode
  -> Yojson.Safe.t
  -> (t, error) result
(** Parse with the canonical JSON request codec, preflight every fixed input,
    and durably store the exact plan, owner, execution mode and tool contracts.
    Currently admits only static read-only ordinary nodes, in both modes. *)
(* Optional [skill] metadata freezes [package_id] and [description] into a
   validated SKILL.md using the exact parameter-free plan. No publication
   occurs. A task-only draft need not carry reusable Skill metadata. *)

val load
  :  base_path:string
  -> capability_surface:Keeper_capability_surface.t
  -> keeper_name:string
  -> sha256:string
  -> (t, error) result
(** Integrity-check the prepared artifact and revalidate all current contracts
    and inputs before effects. A changed owner/surface/schema is a rejection,
    not a rebind of the old preview. *)

val plan : t -> Keeper_tool_plan.t
val execution : t -> Keeper_tool_composition_catalog.execution_mode
val reference : t -> Tool_output.artifact_ref
val authored_source : t -> authored_source option
val load_authored
  :  base_path:string
  -> capability_surface:Keeper_capability_surface.t
  -> keeper_name:string
  -> package_id:Skill_reference.package_id
  -> sha256:string
  -> (authored_source, error) result
(** Load only the exact Skill source frozen in this owned draft. A task-only
    draft or a different package identity is refused before publication. *)
val preview : t -> Yojson.Safe.t
(** Immutable draft metadata, including dependencies, exports and authored
    source references. The public composition prepare boundary adds its
    [schedule_preview] through {!Keeper_composition_draft_preview.preview}. *)

val record_invocation
  :  base_path:string
  -> composition_run_id:Keeper_tool_plan.Composition_run_id.t
  -> invocation:Agent_core.Tool_contract.Invocation.t
  -> t
  -> (Tool_output.artifact_ref, error) result
(** Persist the draft and source invocation binding before dispatch. This
    records one attempted run and does not execute or replay any plan node.
    The caller passes this same [composition_run_id] to the executor and
    observers, so the durable binding and actual leaf invocations identify
    one attempted run. *)
