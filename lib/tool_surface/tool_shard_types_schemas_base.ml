(** Tool_shard_types_schemas_base — [base_tools] always-on schemas
    every keeper sees (time, context status, memory r/w,
    tool self-introspection). *)

open Tool_shard_types_enum_mirrors

let base_tools : Masc_domain.tool_schema list =
  [ (* Time *)
    Tool_shard_types_schemas_base_toml.time_now
  ; (* Context status *)
    Tool_shard_types_schemas_base_toml.context_status
  ; (* Memory *)
    Tool_shard_types_schemas_base_toml.memory_search
  ; (* Exact ordinary-current memory retraction with durable reason evidence. *)
    Tool_shard_types_schemas_base_toml.memory_retract
  ; (* Explicit memory write surface (docs/spec/05-keeper-agent.md 6 Memory Subsystem).
     Writes a durable claim
     into the Memory OS fact store (RFC keeper-memory-consolidation
     Stage 4: the turn-scoped bank is gone). *)
    Tool_shard_types_schemas_base_toml.memory_write
  ; (* Tool self-introspection — lets the keeper enumerate its own capabilities *)
    Tool_shard_types_schemas_base_toml.tools_list
  ; Tool_shard_types_schemas_base_toml.capability_search
  ]
;;
