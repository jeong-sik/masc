(** Standalone instruction Skill tool ([keeper_skill]).

    Reads frozen instruction [SKILL.md] bodies and bundled resource files
    directly from {!Keeper_skill_catalog}. Emits lightweight non-blocking
    telemetry via {!Otel_metric_store}, {!Log.Keeper}, and
    {!Tool_dispatch.run_dispatch_observers} without any blocking causal
    activation ledger I/O. *)

val skill_tool_name : string
(** Canonical model-facing tool name (["keeper_skill"]). *)

type resource_location =
  { source_root : string
  ; directory : string
  ; resource_read_max_bytes : Skill_source_config.resource_read_max_bytes
  }

type instruction_skill =
  { reference : Skill_reference.t
  ; description : string
  ; body : string
  ; resource_location : resource_location option
  }

val instruction_skill
  :  ?resource_location:resource_location
  -> reference:Skill_reference.t
  -> description:string
  -> body:string
  -> unit
  -> instruction_skill

val instruction_skills_of_catalog : Keeper_skill_catalog.t -> instruction_skill list
(** Extract readable instruction entries with their frozen exact references and
    resource roots from [skill_catalog]. *)

val instruction_skill_description : instruction_skill list -> string
(** Render the progressive-disclosure [keeper_skill] tool description listing
    carried skill identities and one-line descriptions. *)

val instruction_skill_schema_tool
  :  instruction_skills:instruction_skill list
  -> (Agent_core.Tool.t, Tool_bridge.schema_error) result
(** Handler-free [keeper_skill] schema tool with the exact same description and
    input schema as {!make_instruction_skill_tool}. *)

val make_instruction_skill_tool
  :  config:Workspace.config
  -> ?keeper_name:string
  -> ?assess_applicability:
       (reference:Skill_reference.t -> body:string -> Typesafeai_skill_applicability.t)
  -> ?on_result:(input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> instruction_skills:instruction_skill list
  -> unit
  -> (Agent_core.Tool.t, Tool_bridge.schema_error) result
(** Executable [keeper_skill] tool. Concurrent, read-only, full body returned
    inline up to the provider wire boundary and projected to a structured blob
    handle above it, lightweight telemetry only. *)
