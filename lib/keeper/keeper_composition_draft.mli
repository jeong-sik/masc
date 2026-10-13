(** Immutable transient plans bound to the preparing Keeper's frozen surface.
    Shared Skill publication is independent of this execution draft. *)

type t

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

val prepare_tool_name : string
val run_tool_name : string
val error_to_json : error -> Yojson.Safe.t
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
val preview : t -> Yojson.Safe.t

val record_invocation
  :  base_path:string
  -> composition_run_id:Keeper_tool_plan.Composition_run_id.t
  -> invocation:Agent_core.Tool_contract.Invocation.t
  -> t
  -> (Tool_output.artifact_ref, error) result
(** Persist the draft and source invocation binding before dispatch. This
    records one attempted run and does not execute or replay any plan node. *)
