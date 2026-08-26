(** Materialize validated catalog entries as first-class Agent-Core tools,
    plus the always-present [keeper_plan_execute] tool that runs one
    model-defined inline plan through the same executor. *)

(** Model-visible name of the model-defined plan tool. Registered even when no
    composition catalog exists. *)
val plan_execute_tool_name : string

val composition_run_summary_tool_name : string
(** Internal durable row name for one terminal composition run. It is not a
    model-visible tool. *)

val plan_execute_input_schema : Yojson.Safe.t
(** The plan's input schema, beside its name because it is the same kind of
    fact: what the tool publishes, not how it is built.

    The four input template shapes are stated here as well as in the
    description. That tells the model the shape; it does not hold it to one --
    [Tool_input_validation.validate_args] reads [oneOf] and [properties] off
    the top-level schema only, and these sit inside [nodes.items]. The refusal
    still comes from [Keeper_tool_plan]. *)

(** Execution-semantics kind (RFC-0386) of the model-defined plan tool:
    [Keeper_tool_descriptor.Batch_plan_tool]. *)
val plan_execute_tool_kind : Keeper_tool_descriptor.tool_kind

type 'evidence schema_tool_origin =
  | Declared_composition of 'evidence
  | Plan_execute
  | Async_status
  | Async_cancel

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

val schema_tool_rows :
  ?skill_compositions:(Keeper_tool_composition_catalog.entry * 'evidence) list ->
  unit ->
  ('evidence schema_tool_origin * Agent_core.Tool.t) list
(** Handler-free schemas paired with caller-owned composition evidence. This
    preserves typed provenance through materialization instead of recovering it
    from a generated tool name. *)

val merge_instruction_skills :
  task:instruction_skill list ->
  global:instruction_skill list ->
  instruction_skill list
(** Preserve Task-selected order, then append globally discoverable exact
    entries that are not already selected. *)

val instruction_skill_schema_tool :
  instruction_skills:instruction_skill list ->
  Agent_core.Tool.t
(** Handler-free [keeper_skill] schema with the same exact Available
    description used by the executable tool. *)

val make_tools
  :  ?instruction_skills:instruction_skill list
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
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> ?record_gate_result:
       (operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> ?on_completed:(Keeper_tool_execution.terminal_effect_receipt option -> unit)
  -> ?on_deferred:(unit -> unit)
  -> ?on_external_effect_deferred:(unit -> unit)
  -> ?on_failed:(Keeper_tools_agent_core.terminal_effect_failure -> unit)
  -> ?on_externalization_error:(Tool_bridge.externalization_error -> unit)
  -> unit
  -> Agent_core.Tool.t list

module For_testing : sig
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
