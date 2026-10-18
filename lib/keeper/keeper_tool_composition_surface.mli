(** Materialize validated catalog entries as first-class Agent-Core tools,
    plus transient draft controls and durable async request controls when an entry is [Async]
    ({!Keeper_tool_composition_catalog.requires_async_controls}). Named inline
    compositions may overlap when all leaves are statically read-only,
    ordinary and concurrent, and mutable causal evidence can be forked.
    Inline Read/Edit plans bind actual producer-owned directory claims through
    their original executor calls. Upstream-dependent inputs bind when ready,
    including pure argument validation for exact nested inline children.
    This includes task recipes and named inline Skills;
    transient run calls retain their Serial outer descriptor. *)

val composition_run_summary_tool_name : string
(** Internal durable row name for one terminal composition run. It is not a
    model-visible tool. *)

type 'evidence schema_tool_origin =
  | Declared_composition of 'evidence
  | Async_status
  | Async_cancel
  | Transient_prepare
  | Transient_run

type instruction_skill =
  { reference : Skill_reference.t
  ; description : string
  ; body : string
  ; resource_location : resource_location option
  }

and resource_location =
  { source_root : string
  ; directory : string
  ; resource_read_max_bytes : Skill_source_config.resource_read_max_bytes
  }

type composition_skill =
  { reference : Skill_reference.t
  ; entry : Keeper_tool_composition_catalog.entry
  }

val instruction_skill :
  ?resource_location:resource_location ->
  reference:Skill_reference.t ->
  description:string ->
  body:string ->
  unit ->
  instruction_skill

val instruction_skills_of_catalog : Keeper_skill_catalog.t -> instruction_skill list
(** Readable instruction entries with the frozen exact references and resource roots. *)

val make_instruction_skill_tool :
  config:Workspace.config ->
  ?record_activation:
    (invocation:Agent_core.Tool_contract.Invocation.t ->
     content:Keeper_skill_activation_recorder.instruction_content ->
     Skill_reference.t ->
     (Keeper_skill_activation_ledger.record_outcome, Keeper_skill_activation_recorder.error) result) ->
  ?assess_applicability:(reference:Skill_reference.t -> body:string -> Typesafeai_skill_applicability.t) ->
  ?on_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  instruction_skills:instruction_skill list -> unit -> Agent_core.Tool.t
(** Read a frozen Skill body or bundled resource without a Keeper turn or
    composition execution. Native Agent-Core invocation identity is preserved. *)

val composition_schema_tool :
  Keeper_tool_composition_catalog.entry -> Agent_core.Tool.t
(** The single declared composition schema, without materializing async or
    transient controls. Its schema has the same description/parameters as its
    row in {!schema_tool_rows}; it cannot execute. *)

val schema_tool_name_rows :
  ?include_drafts:bool ->
  ?skill_compositions:(Keeper_tool_composition_catalog.entry * 'evidence) list ->
  unit ->
  ('evidence schema_tool_origin * string) list
(** Model names and typed caller provenance from the same row selection/order
    as {!schema_tool_rows}, without constructing Tool objects, descriptions or
    input schemas. Use this for membership checks, not schema inspection. *)

val schema_tool_rows :
  ?include_drafts:bool ->
  ?skill_compositions:(Keeper_tool_composition_catalog.entry * 'evidence) list ->
  unit ->
  ('evidence schema_tool_origin * Agent_core.Tool.t) list
(** Handler-free schemas paired with caller-owned composition evidence. This
    preserves typed provenance through materialization instead of recovering it
    from a generated tool name. The async controls are rows exactly when
    {!make_tools} would build them. Frozen surfaces also offer the transient
    prepare/run controls, so they can mint async requests without a shared
    Skill and carry status/cancel even without a named async composition.
    [include_drafts=false] is for descriptor-only compatibility surfaces. *)

val instruction_skill_schema_tool :
  instruction_skills:instruction_skill list ->
  Agent_core.Tool.t
(** Handler-free [keeper_skill] schema with the same exact Available
    description used by the executable tool. *)

type owner_metadata_refusal =
  | Owner_metadata_missing
  | Owner_metadata_mismatch

val resume_continuation
  :  ?on_recovery_held:(request_id:string -> reason:string -> unit)
  -> ?owner_metadata_refusal:owner_metadata_refusal
  -> capability_surface:Keeper_capability_surface.t
  -> continuation:Keeper_tool_execution_journal.continuation
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> turn_context:Keeper_tool_call_log_context.turn_context
  -> invocation:Agent_core.Tool_contract.Invocation.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> unit
  -> Tool_result.result
(** Explicit execution boundary for a sealed original prepared continuation.
    Strict result readiness and current exact node admission precede async
    acceptance. Not-ready results defer without a worker or backend operation.
    The existing journal owner/node CAS precedes all worker effects. Run, draft,
    source Task/turn/parent and completed sibling results stay original while
    physical execution observability uses the supplied context and schedule.
    [on_recovery_held] tells the automatic controller to hold this exact
    physical owner until explicit recovery advances it, including unavailable
    original draft/activation evidence before worker admission. It grants no effect
    authority and does not convert an unknown outcome into failure.
    This entrypoint does not discover candidates or install a controller. *)

val make_tools
  :  capability_surface:Keeper_capability_surface.t
  -> ?instruction_skills:instruction_skill list
       (** Instruction skills this keeper carries. Present ones get
           {!Keeper_tool_composition_catalog.skill_tool_name}, which serves a
           frozen body or one deferred bundled resource for a canonical
           exact-reference input. *)
  -> ?skill_compositions:composition_skill list
       (** Composition entries declared by skills
           ({!Keeper_skill_catalog.composition_entries}). Same validated type
           as catalog entries; materialized by the same closure. The caller
           that loaded both catalogs refuses cross-source name collisions. *)
  -> ?composition_plan_index:Keeper_tool_composition_plan_index.t
       (** The current turn's approval index. When present, every materialized
           composition records its node tools for that exact gate. *)
  -> ?record_instruction_activation:
       (invocation:Agent_core.Tool_contract.Invocation.t ->
        content:Keeper_skill_activation_recorder.instruction_content ->
        Skill_reference.t ->
        ( Keeper_skill_activation_ledger.record_outcome
        , Keeper_skill_activation_recorder.error )
          result)
  -> ?record_composition_activation:
       (invocation:Agent_core.Tool_contract.Invocation.t ->
        tool_name:string ->
        reference:Skill_reference.t ->
        ( Keeper_skill_activation_ledger.record_outcome
        , Keeper_skill_activation_recorder.error )
          result)
       (** Inline composition recording. Named async submissions record the
           original sealed [nested_activation_context] within their producer
           intent transaction, before broker entry. *)
  -> ?record_nested_composition_activation:Keeper_composition_nested_run.record_activation
  -> ?nested_activation_context:Keeper_skill_activation_recorder.t
       (** Required for a fresh named async invocation; existing original
           submissions retain their recorded context on replay. *)
  -> ?result_delivery:Keeper_composition_result_delivery.t
       (** The owning turn's typed status-result correlation registry. *)
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> ?turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_causal_context:Keeper_gate_causal_context.t
       (** The owning turn's causal cell. Concurrent read-only compositions
           fork it per invocation and append their results to both their own
           history and the turn's [record_gate_result] callback. *)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> ?record_gate_result:
       (operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> ?on_completed:
       (composition_tool:string ->
        Keeper_tool_execution.terminal_effect_receipt option ->
        unit)
  -> ?on_deferred:(unit -> unit)
  -> ?on_external_effect_deferred:(approval_id:string option -> unit)
  -> ?on_failed:(Keeper_tools_agent_core.terminal_effect_failure -> unit)
  -> ?on_externalization_error:(Tool_bridge.externalization_error -> unit)
  -> unit
  -> (Agent_core.Tool.t * Tool_definition_toml.loading * Tool_output.model_projection) list
(** Production materialization consumes the same immutable authority as direct
    dispatch. Its descriptor set cannot be supplied independently.

    Each tool comes with its declared loading: a Skill composition's
    [defer_loading] from its composition block, the Skill reader's and the
    request controls' from their own [config/tools/<name>.toml]. *)

module Compatibility : sig
  val make_tools
    :  descriptors:Keeper_tool_descriptor.t list
    -> ?instruction_skills:instruction_skill list
    -> ?skill_compositions:composition_skill list
    -> ?composition_plan_index:Keeper_tool_composition_plan_index.t
    -> ?record_instruction_activation:
         (invocation:Agent_core.Tool_contract.Invocation.t ->
          content:Keeper_skill_activation_recorder.instruction_content ->
          Skill_reference.t ->
          ( Keeper_skill_activation_ledger.record_outcome
          , Keeper_skill_activation_recorder.error )
            result)
    -> ?record_composition_activation:
         (invocation:Agent_core.Tool_contract.Invocation.t ->
          tool_name:string ->
          reference:Skill_reference.t ->
          ( Keeper_skill_activation_ledger.record_outcome
          , Keeper_skill_activation_recorder.error )
            result)
    -> ?record_nested_composition_activation:Keeper_composition_nested_run.record_activation
    -> ?nested_activation_context:Keeper_skill_activation_recorder.t
    -> ?result_delivery:Keeper_composition_result_delivery.t
    -> config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> publication_recovery:
         Keeper_publication_recovery_availability.turn_context
    -> ctx_snapshot:Keeper_types.working_context
    -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
    -> ?turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
    -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
    -> ?continuation_channel:Keeper_continuation_channel.t
    -> ?gate_context:(unit -> Keeper_gate.causal_context)
    -> ?gate_causal_context:Keeper_gate_causal_context.t
    -> ?gate_grant:Keeper_gate.cycle_grant
    -> ?record_gate_result:
         (operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit)
    -> ?on_completed:
         (composition_tool:string ->
          Keeper_tool_execution.terminal_effect_receipt option ->
          unit)
    -> ?on_deferred:(unit -> unit)
    -> ?on_external_effect_deferred:(approval_id:string option -> unit)
    -> ?on_failed:(Keeper_tools_agent_core.terminal_effect_failure -> unit)
    -> ?on_externalization_error:(Tool_bridge.externalization_error -> unit)
    -> unit
    -> (Agent_core.Tool.t * Tool_definition_toml.loading * Tool_output.model_projection) list
end
(** Explicit compatibility adapter for tests that supply a descriptor list
    without an enclosing Keeper turn. *)

module For_testing : sig
  type recovery_decision =
    | Complete_original_result
    | Hold_original_authority of string
  val continuation_recovery_of_result :
    effect_disposition:Tool_result.failure_effect_disposition option ->
    Tool_result.result -> recovery_decision
  val combine_recovery : recovery_decision -> recovery_decision -> recovery_decision
  val resume_continuation :
    ?owner_metadata_refusal:owner_metadata_refusal ->
    after_refusal_binding:(request_id:string -> unit) ->
    after_refusal_settled:(unit -> unit) ->
    capability_surface:Keeper_capability_surface.t ->
    continuation:Keeper_tool_execution_journal.continuation ->
    config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
    publication_recovery:Keeper_publication_recovery_availability.turn_context ->
    ctx_snapshot:Keeper_types.working_context ->
    turn_context:Keeper_tool_call_log_context.turn_context ->
    invocation:Agent_core.Tool_contract.Invocation.t ->
    ?clock:float Eio.Time.clock_ty Eio.Resource.t -> unit -> Tool_result.result
  (** The production resume and refusal worker. Inject only after an actual
      refusal successor binds, before its worker starts, and observe only after
      the production settlement callbacks finish. Ordinary resume is unchanged. *)

  val async_worker_result :
    composition_execution:Keeper_tool_composition_catalog.execution_mode ->
    tool_kind:Keeper_tool_descriptor.tool_kind ->
    ?skill_reference:Skill_reference.t ->
    ?nested_calls:Keeper_composition_nested.call list ->
    ?nested_activation:Keeper_skill_activation_recorder.bound_context ->
    ?continuation:Keeper_tool_execution_journal.continuation ->
    ?on_recovery_held:(request_id:string -> reason:string -> unit) ->
    ?after_child_submission:(Tool_result.result -> unit) ->
    ?before_child_dispatch:(unit -> unit) ->
    ?keeper_turn_id:(unit -> int option) ->
    ?before_plan_execution:(unit -> unit) ->
    ?after_node_observation:(Keeper_tool_plan_executor.node_result -> unit) ->
    ?before_child_result_publication:(unit -> unit) ->
    ?before_child_submission_publication:(unit -> unit) ->
    plan:Keeper_tool_plan.t ->
    ?journal:Keeper_tool_execution_journal.worker ->
    tool_name:string -> request_id:string ->
    composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
    source_invocation:Agent_core.Tool_contract.Invocation.t ->
    request_sw:Eio.Switch.t -> config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    capability_authority:Keeper_tool_runtime.capability_authority ->
    publication_recovery:Keeper_publication_recovery_availability.turn_context ->
    ctx_snapshot:Keeper_types.working_context ->
    turn_context:Keeper_tool_call_log_context.turn_context option ->
    ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
    unit -> Keeper_msg_async.worker_outcome
  (** The actual production worker, so a fixture can bind a real broker request
      and replace activation authority precisely after acceptance, before the
      worker restores it. The optional keeper-turn callback tests the actual
      handler's snapshot priority; production derives it from turn_context.
      No fabricated worker/journal or global fault hook. *)

  val node_result_to_json : Keeper_tool_plan_executor.node_result -> Yojson.Safe.t
  (** The canonical settlement representation used by the production surface
      when it persists Skill composition evidence. *)

  val project_execution_result :
    base_path:string ->
    plan:Keeper_tool_plan.t ->
    execution:(Keeper_tool_plan_executor.node_result list,
               Keeper_tool_plan_executor.failure) result ->
    Tool_result.result ->
    (Tool_result.result, Tool_bridge.externalization_error) result
  (** The production export selection and durable-manifest boundary shared by
      inline and asynchronous composition results. *)

  val result_of_execution :
    tool_name:string ->
    tool_kind:Keeper_tool_descriptor.tool_kind ->
    start_time:Tool_timing.started ->
    (Keeper_tool_plan_executor.node_result list, Keeper_tool_plan_executor.failure) result ->
    Tool_result.result

  val observe_node_result :
    ?on_receipt_committed:(Ids.Execution_id.t -> unit) ->
    composition_tool:string ->
    composition_execution:Keeper_tool_composition_catalog.execution_mode ->
    composition_tool_kind:Keeper_tool_descriptor.tool_kind ->
    composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
    parent_invocation:Agent_core.Tool_contract.Invocation.t ->
    meta:Keeper_meta_contract.keeper_meta ->
    turn_context:Keeper_tool_call_log_context.turn_context ->
    Keeper_tool_plan_executor.node_result -> (unit, string) result

  val failure_payload :
    tool_name:string ->
    tool_kind:Keeper_tool_descriptor.tool_kind ->
    cause:Yojson.Safe.t ->
    effect_disposition:string ->
    settled:Yojson.Safe.t list ->
    Yojson.Safe.t
  (** The durable payload of a failed composition, in the order it is written.

      Exposed because the order is the contract: the tool-call row is truncated
      on the serialized string at [Keeper_tool_call_log.max_output_len], and
      [settled] has no bound, so anything after it can be cut away. [cause] and
      [effect_disposition] precede it for that reason. *)

  val instruction_skill_description :
    instruction_skill list -> string

  val make_instruction_skill_tool :
    config:Workspace.config ->
    ?record_activation:
      (invocation:Agent_core.Tool_contract.Invocation.t ->
       content:Keeper_skill_activation_recorder.instruction_content ->
       Skill_reference.t ->
       ( Keeper_skill_activation_ledger.record_outcome
       , Keeper_skill_activation_recorder.error )
         result) ->
    ?assess_applicability:(reference:Skill_reference.t -> body:string -> Typesafeai_skill_applicability.t) ->
    ?on_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
    instruction_skills:instruction_skill list ->
    unit ->
    Agent_core.Tool.t

  val status_result :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    request_id:string ->
    Tool_result.result

  val cancel_result :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    request_id:string ->
    Tool_result.result
end
